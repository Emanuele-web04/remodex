// FILE: CodexService+Messages.swift
// Purpose: Owns per-thread message timelines, streaming merge logic, and persistence.
// Layer: Service
// Exports: CodexService message APIs
// Depends on: CodexMessage, JSONValue

import Foundation
import UIKit

private enum CanonicalHistoryReconcileRetryPolicy {
    static let initialDelayNanoseconds: UInt64 = 1_500_000_000
    static let maximumDelayNanoseconds: UInt64 = 60_000_000_000

    // Giant histories can take tens of seconds per attempt. Exponential spacing
    // keeps recovery persistent without hammering the bridge forever.
    static func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        var delay = initialDelayNanoseconds
        for _ in 1..<max(1, min(attempt, 7)) {
            delay = min(delay * 2, maximumDelayNanoseconds)
        }
        return delay
    }
}

private enum StreamingDeltaCoalescingPolicy {
    // Show the first system row quickly so the user sees immediate progress.
    static let initialFlushDelayNanoseconds: UInt64 = 16_000_000
    // System rows often parse markdown/tool summaries; a slightly slower cadence keeps
    // them readable without invalidating the timeline on every transport chunk.
    static let flushDelayNanoseconds: UInt64 = 50_000_000
    // Assistant prose gets one quick first paint, then a calmer cadence once text is visible.
    static let assistantInitialFlushDelayNanoseconds: UInt64 = 50_000_000
    static let assistantStreamingFlushDelayNanoseconds: UInt64 = 80_000_000
    static let assistantLargeStreamingFlushDelayNanoseconds: UInt64 = 100_000_000
    static let assistantLargePendingDeltaByteCount = 12_000
    static let assistantLargeVisibleTextByteCount = 32_000
    // System/tool rows still rebuild heavier timeline content; back them off while
    // gestures/typing own the main thread. Assistant prose uses a lighter fast path.
    static let interactionFlushDelayNanoseconds: UInt64 = 250_000_000
}

private enum MessageTextProcessingPolicy {
    static let largeTextByteLimit = 64_000
}

private enum DesktopMirroredRunningPolicy {
    static let staleSnapshotGraceCount = 3
    static let recentActivityGraceInterval: TimeInterval = 20
}

private extension Array where Element == CodexMessage {
    func messageIndexByID() -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(count)
        for (index, message) in enumerated() {
            result[message.id] = index
        }
        return result
    }

    /// Sorts by `orderIndex`, but only when the array isn't already ordered.
    /// Streaming text deltas and monotonic appends leave `orderIndex` ordered, so
    /// the common per-flush case is an O(n) check instead of an O(n log n) sort.
    /// Result is identical to `sort { $0.orderIndex < $1.orderIndex }` (orderIndex
    /// is unique, so there are no ties whose relative order could differ).
    mutating func sortByOrderIndexIfNeeded() {
        guard count > 1 else { return }
        var isOrdered = true
        for index in 1..<count where self[index].orderIndex < self[index - 1].orderIndex {
            isOrdered = false
            break
        }
        guard !isOrdered else { return }
        sort { $0.orderIndex < $1.orderIndex }
    }
}

extension CodexService {
    enum ThreadHistoryLoadOutcome: Equatable {
        case alreadyHydrated
        case notMaterialized
        case skippedForRunningThread
        case loadedCanonicalHistory
        case loadedRecentWindow
        case loadedPaginatedWindow
        case loadedProvisionalPaginatedWindow
        case deferredAfterTimeout
        case deferredAfterEmptyPage
        case deferredAfterUnavailablePage

        var didCompleteCanonicalReconcile: Bool {
            self == .loadedCanonicalHistory
        }

        var needsCanonicalRetry: Bool {
            self == .loadedRecentWindow
                || self == .loadedProvisionalPaginatedWindow
                || self == .skippedForRunningThread
                || self == .deferredAfterTimeout
                || self == .deferredAfterEmptyPage
                || self == .deferredAfterUnavailablePage
        }
    }

    enum ThreadDisplayPhase: Equatable {
        case loading
        case empty
        case ready
    }

    // Returns the full persisted timeline for a single thread.
    func messages(for threadId: String) -> [CodexMessage] {
        messagesByThread[threadId] ?? []
    }

    // Centralizes first-open display state so reconnect jitter does not bounce
    // an existing chat between loading and the empty placeholder.
    func threadDisplayPhase(threadId: String) -> ThreadDisplayPhase {
        threadDisplayPhase(
            threadId: threadId,
            hasVisibleMessages: !messages(for: threadId).isEmpty,
            isThreadRunning: threadHasActiveOrRunningTurn(threadId)
        )
    }

    // Variant for active SwiftUI views that already hold a per-thread render snapshot.
    // It avoids subscribing that view to the global messagesByThread dictionary.
    func threadDisplayPhase(
        threadId: String,
        hasVisibleMessages: Bool,
        isThreadRunning: Bool
    ) -> ThreadDisplayPhase {
        if hasVisibleMessages || isThreadRunning {
            return .ready
        }

        if loadingThreadIDs.contains(threadId) {
            return .loading
        }

        let shouldShowBlankComposer = shouldShowImmediateEmptyPlaceholder(
            threadId: threadId,
            hasVisibleMessages: hasVisibleMessages,
            isThreadRunning: isThreadRunning
        )
        if supportsTurnPagination,
           !initialTurnsLoadedByThreadID.contains(threadId),
           !shouldShowBlankComposer {
            return .loading
        }

        if shouldSkipInitialDisplayHydration(
            threadId: threadId,
            hasVisibleMessages: hasVisibleMessages,
            isThreadRunning: isThreadRunning
        ) || shouldShowBlankComposer {
            return .empty
        }

        if !hydratedThreadIDs.contains(threadId) {
            return .loading
        }

        return .empty
    }

    // Treats placeholder-only chats as intentionally blank so the UI does not flash
    // a loading state before the thread-open preparation path can confirm the skip.
    func shouldShowImmediateEmptyPlaceholder(threadId: String) -> Bool {
        shouldShowImmediateEmptyPlaceholder(
            threadId: threadId,
            hasVisibleMessages: !messages(for: threadId).isEmpty,
            isThreadRunning: threadHasActiveOrRunningTurn(threadId)
        )
    }

    func shouldShowImmediateEmptyPlaceholder(
        threadId: String,
        hasVisibleMessages: Bool,
        isThreadRunning: Bool
    ) -> Bool {
        guard !isThreadRunning,
              !hasVisibleMessages,
              let thread = thread(for: threadId),
              thread.syncState == .live else {
            return false
        }

        let preview = thread.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard preview.isEmpty else {
            return false
        }

        // Keep a brand-new blank chat on the empty composer even if a hydration
        // race briefly toggled the thread into a loading state behind the scenes.
        return thread.displayTitle == CodexThread.defaultDisplayTitle
    }

    // An empty page is only a recovery signal when local metadata proves that
    // content should exist. A never-prompted thread may have a custom title, so
    // the title itself must not turn its legitimate empty page into a retry loop.
    func shouldDeferEmptyThreadHistoryPage(
        threadId: String,
        loadedViaPagination: Bool
    ) -> Bool {
        let hasPendingSourceReplacement = pendingCanonicalSourceReplacementThreadIDs.contains(threadId)
        guard loadedViaPagination || hasPendingSourceReplacement else {
            return false
        }

        if hasPendingSourceReplacement || messagesByThread[threadId]?.isEmpty == false {
            return true
        }

        let preview = (thread(for: threadId)?.preview ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !preview.isEmpty
    }

    // Returns a lightweight per-thread revision token for any message timeline mutation.
    func messageRevision(for threadId: String) -> Int {
        messageRevisionByThread[threadId] ?? 0
    }

    // Returns the service-owned timeline state for a single thread.
    func timelineState(for threadId: String) -> ThreadTimelineState {
        if let existing = threadTimelineStateByThread[threadId] {
            return existing
        }

        let state = ThreadTimelineState(threadID: threadId)
        threadTimelineStateByThread[threadId] = state
        refreshThreadTimelineState(for: threadId)
        return state
    }

    // Prunes service-owned render caches so removed/archived threads do not keep stale snapshots alive.
    func removeThreadTimelineState(for threadId: String) {
        threadTimelineStateByThread.removeValue(forKey: threadId)
        stoppedTurnIDsByThread.removeValue(forKey: threadId)
        projectedTerminalStateByThreadID.removeValue(forKey: threadId)
        messageIndexCacheByThread.removeValue(forKey: threadId)
        latestAssistantOutputByThread.removeValue(forKey: threadId)
        latestAssistantMessageIDByThread.removeValue(forKey: threadId)
        latestRepoAffectingMessageSignalByThread.removeValue(forKey: threadId)
        assistantRevertStateCacheByThread.removeValue(forKey: threadId)
        cancelPendingStreamingDeltaFlushes(for: threadId)
        threadsPendingCompletionHaptic.remove(threadId)
        threadsNeedingCanonicalHistoryReconcile.remove(threadId)
        pendingCanonicalSourceReplacementThreadIDs.remove(threadId)
        pendingReconnectRunContinuityThreadIDs.remove(threadId)
        displacedActiveTurnIDsByThread.removeValue(forKey: threadId)
        supersededTurnIDsByIDLessRunByThread.removeValue(forKey: threadId)
        provisionalIDLessTurnIDByThread.removeValue(forKey: threadId)
        runStartGenerationByThread.removeValue(forKey: threadId)
        lastRunStartTurnIDByThread.removeValue(forKey: threadId)
        provisionalPaginatedHistoryThreadIDs.remove(threadId)
        threadsWithSatisfiedDeferredHistoryHydration.remove(threadId)
        olderThreadHistoryCursorByThreadID.removeValue(forKey: threadId)
        exhaustedOlderThreadHistoryCursorByThreadID.removeValue(forKey: threadId)
        loadingOlderThreadHistoryIDs.remove(threadId)
        threadTimelineProjectionLimitByThreadID.removeValue(forKey: threadId)
        initialTurnsLoadedByThreadID.remove(threadId)
        threadsWithAuthoritativeLocalHistoryStart.remove(threadId)
        olderHistoryLoadErrorByThreadID.removeValue(forKey: threadId)
        persistThreadHistoryPaginationState()
        canonicalHistoryReconcileTaskByThreadID[threadId]?.cancel()
        canonicalHistoryReconcileTaskByThreadID.removeValue(forKey: threadId)
        canonicalHistoryReconcileRetryTaskByThreadID[threadId]?.cancel()
        canonicalHistoryReconcileRetryTaskByThreadID.removeValue(forKey: threadId)
        canonicalHistoryReconcileRetryAttemptByThreadID.removeValue(forKey: threadId)
        timelineCatchUpFlushTaskByThreadID[threadId]?.cancel()
        timelineCatchUpFlushTaskByThreadID.removeValue(forKey: threadId)
        timelineCatchUpBurstThreadIDs.remove(threadId)
        replayCatchUpBurstThreadIDs.remove(threadId)
        cancelPerThreadRefreshWork(for: threadId)
    }

    // Clears every service-owned timeline cache during global teardown.
    func removeAllThreadTimelineState(preserveRunLifecycle: Bool = false) {
        threadTimelineStateByThread.removeAll()
        stoppedTurnIDsByThread.removeAll()
        projectedTerminalStateByThreadID.removeAll()
        messageIndexCacheByThread.removeAll()
        latestAssistantOutputByThread.removeAll()
        latestAssistantMessageIDByThread.removeAll()
        latestRepoAffectingMessageSignalByThread.removeAll()
        assistantRevertStateCacheByThread.removeAll()
        cancelAllPendingStreamingDeltaFlushes()
        threadsNeedingCanonicalHistoryReconcile.removeAll()
        pendingCanonicalSourceReplacementThreadIDs.removeAll()
        if !preserveRunLifecycle {
            pendingReconnectRunContinuityThreadIDs.removeAll()
            displacedActiveTurnIDsByThread.removeAll()
            supersededTurnIDsByIDLessRunByThread.removeAll()
            provisionalIDLessTurnIDByThread.removeAll()
            runStartGenerationByThread.removeAll()
            lastRunStartTurnIDByThread.removeAll()
        }
        provisionalPaginatedHistoryThreadIDs.removeAll()
        threadsWithSatisfiedDeferredHistoryHydration.removeAll()
        olderThreadHistoryCursorByThreadID.removeAll()
        exhaustedOlderThreadHistoryCursorByThreadID.removeAll()
        loadingOlderThreadHistoryIDs.removeAll()
        threadTimelineProjectionLimitByThreadID.removeAll()
        initialTurnsLoadedByThreadID.removeAll()
        threadsWithAuthoritativeLocalHistoryStart.removeAll()
        olderHistoryLoadErrorByThreadID.removeAll()
        persistThreadHistoryPaginationState()
        canonicalHistoryReconcileTaskByThreadID.values.forEach { $0.cancel() }
        canonicalHistoryReconcileTaskByThreadID.removeAll()
        canonicalHistoryReconcileRetryTaskByThreadID.values.forEach { $0.cancel() }
        canonicalHistoryReconcileRetryTaskByThreadID.removeAll()
        canonicalHistoryReconcileRetryAttemptByThreadID.removeAll()
        timelineCatchUpFlushTaskByThreadID.values.forEach { $0.cancel() }
        timelineCatchUpFlushTaskByThreadID.removeAll()
        timelineCatchUpBurstThreadIDs.removeAll()
        replayCatchUpBurstThreadIDs.removeAll()
        cancelAllPerThreadRefreshWork()
    }

    // Refreshes the derived output cache and bumps the thread timeline revision.
    func updateCurrentOutput(for threadId: String) {
        noteMessagesChanged(for: threadId)

        // During a replay burst every replayed event lands here through its append
        // path; the O(messages) latest-output scan and the snapshot rebuild are
        // deferred to the single settle in finishTimelineCatchUpBurst. Live-mirror
        // micro-bursts stay on this path (only the reducer rebuild below defers)
        // so mirrored text keeps streaming into the visible output.
        if replayCatchUpBurstThreadIDs.contains(threadId) {
            return
        }

        let latestAssistantText = syncLatestAssistantOutputCache(for: threadId)
        refreshThreadTimelineState(for: threadId)

        guard activeThreadId == threadId else {
            return
        }

        currentOutput = latestAssistantText
    }

    // Fast-paths plain assistant text streaming so one delta does not rebuild every derived row cache.
    // Falls back to the full projection path whenever the visible snapshot shape changed underneath us.
    func updateStreamingAssistantOutput(for threadId: String, messageId: String, rawMessageIndex: Int? = nil) {
        noteMessagesChanged(for: threadId)

        // During a replay burst nothing may touch the visible snapshot: both the
        // O(messages) latest-output scan and the fast-path snapshot patch below are
        // deferred to the single settle in finishTimelineCatchUpBurst. (The raw
        // message data is already updated by the caller; replay dedup is covered by
        // the reducer at projection time.) Live-mirror micro-bursts deliberately
        // skip this gate: the fast-path patch is what keeps mirrored assistant
        // text streaming instead of materializing as one block at settle.
        if replayCatchUpBurstThreadIDs.contains(threadId) {
            return
        }

        // Keep the visible output anchored to the latest assistant bubble, even if a late
        // delta updates an older item inside the same turn.
        let latestAssistantText = syncLatestAssistantOutputCache(for: threadId)
        if activeThreadId == threadId {
            currentOutput = latestAssistantText
        }

        guard let state = threadTimelineStateByThread[threadId],
              let rawMessages = messagesByThread[threadId],
              let updatedMessageIndex = resolvedMessageIndex(
                  threadId: threadId,
                  messageId: messageId,
                  preferredIndex: rawMessageIndex,
                  in: rawMessages
              ),
              rawMessages.indices.contains(updatedMessageIndex),
              rawMessages[updatedMessageIndex].id == messageId,
              let projectedIndex = state.renderSnapshot.messageIndexByID[messageId],
              state.renderSnapshot.messages.indices.contains(projectedIndex),
              state.renderSnapshot.messages[projectedIndex].id == messageId else {
            refreshThreadTimelineState(for: threadId)
            return
        }
        let updatedMessage = rawMessages[updatedMessageIndex]
        if updatedMessage.role == .assistant,
           let terminalMessageId = assistantReplayTargetMessageId(
               in: rawMessages,
               threadId: threadId,
               turnId: updatedMessage.turnId,
               itemId: updatedMessage.itemId,
               text: updatedMessage.text,
               excludingMessageID: messageId
           ) {
            var nextRawMessages = rawMessages
            nextRawMessages.remove(at: updatedMessageIndex)
            messagesByThread[threadId] = nextRawMessages
            removeAssistantStreamingLookups(messageId: messageId)
            if let turnId = updatedMessage.turnId {
                noteAssistantMessage(threadId: threadId, turnId: turnId, assistantMessageId: terminalMessageId)
            }
            persistMessages()
            updateCurrentOutput(for: threadId)
            return
        }

        let revision = messageRevisionByThread[threadId] ?? 0
        var projectedMessages = state.renderSnapshot.messages
        projectedMessages[projectedIndex] = updatedMessage

        state.messages = rawMessages
        state.messageRevision = revision
        state.renderSnapshot = TurnTimelineRenderSnapshot(
            threadID: threadId,
            messages: projectedMessages,
            messageIndexByID: state.renderSnapshot.messageIndexByID,
            planMatchingMessages: state.renderSnapshot.planMatchingMessages,
            timelineChangeToken: revision,
            activeTurnID: state.renderSnapshot.activeTurnID,
            isThreadRunning: state.renderSnapshot.isThreadRunning,
            runStartGeneration: state.renderSnapshot.runStartGeneration,
            latestTurnTerminalState: state.renderSnapshot.latestTurnTerminalState,
            completedTurnIDs: state.renderSnapshot.completedTurnIDs,
            stoppedTurnIDs: state.renderSnapshot.stoppedTurnIDs,
            assistantRevertStatesByMessageID: state.renderSnapshot.assistantRevertStatesByMessageID,
            repoRefreshSignal: state.renderSnapshot.repoRefreshSignal,
            hasOlderHistory: state.renderSnapshot.hasOlderHistory,
            hasRemoteOlderHistory: state.renderSnapshot.hasRemoteOlderHistory,
            hasLocallyProjectedOlderHistory: state.renderSnapshot.hasLocallyProjectedOlderHistory,
            usesPaginatedHistory: state.renderSnapshot.usesPaginatedHistory,
            isLoadingOlderHistory: state.renderSnapshot.isLoadingOlderHistory,
            initialTurnsLoaded: state.renderSnapshot.initialTurnsLoaded,
            olderHistoryLoadErrorMessage: state.renderSnapshot.olderHistoryLoadErrorMessage
        )
    }

    // Patches an already-projected streaming system row without rerunning the reducer.
    func updateStreamingSystemOutput(for threadId: String, messageId: String, rawMessageIndex: Int? = nil) {
        noteMessagesChanged(for: threadId)

        // Mirror of updateStreamingAssistantOutput: during a replay burst the
        // snapshot settles once at flush, so the fast-path patch must not run.
        // Live-mirror micro-bursts keep streaming through this fast path.
        if replayCatchUpBurstThreadIDs.contains(threadId) {
            return
        }

        if activeThreadId == threadId {
            currentOutput = latestAssistantOutputByThread[threadId] ?? syncLatestAssistantOutputCache(for: threadId)
        }

        guard let state = threadTimelineStateByThread[threadId],
              let rawMessages = messagesByThread[threadId],
              let updatedMessageIndex = resolvedMessageIndex(
                  threadId: threadId,
                  messageId: messageId,
                  preferredIndex: rawMessageIndex,
                  in: rawMessages
              ),
              rawMessages.indices.contains(updatedMessageIndex),
              rawMessages[updatedMessageIndex].id == messageId,
              let projectedIndex = state.renderSnapshot.messageIndexByID[messageId],
              state.renderSnapshot.messages.indices.contains(projectedIndex),
              state.renderSnapshot.messages[projectedIndex].id == messageId else {
            refreshThreadTimelineState(for: threadId)
            return
        }

        let revision = messageRevisionByThread[threadId] ?? 0
        var projectedMessages = state.renderSnapshot.messages
        projectedMessages[projectedIndex] = rawMessages[updatedMessageIndex]

        state.messages = rawMessages
        state.messageRevision = revision
        state.renderSnapshot = TurnTimelineRenderSnapshot(
            threadID: threadId,
            messages: projectedMessages,
            messageIndexByID: state.renderSnapshot.messageIndexByID,
            planMatchingMessages: state.renderSnapshot.planMatchingMessages,
            timelineChangeToken: revision,
            activeTurnID: state.renderSnapshot.activeTurnID,
            isThreadRunning: state.renderSnapshot.isThreadRunning,
            runStartGeneration: state.renderSnapshot.runStartGeneration,
            latestTurnTerminalState: state.renderSnapshot.latestTurnTerminalState,
            completedTurnIDs: state.renderSnapshot.completedTurnIDs,
            stoppedTurnIDs: state.renderSnapshot.stoppedTurnIDs,
            assistantRevertStatesByMessageID: state.renderSnapshot.assistantRevertStatesByMessageID,
            repoRefreshSignal: state.renderSnapshot.repoRefreshSignal,
            hasOlderHistory: state.renderSnapshot.hasOlderHistory,
            hasRemoteOlderHistory: state.renderSnapshot.hasRemoteOlderHistory,
            hasLocallyProjectedOlderHistory: state.renderSnapshot.hasLocallyProjectedOlderHistory,
            usesPaginatedHistory: state.renderSnapshot.usesPaginatedHistory,
            isLoadingOlderHistory: state.renderSnapshot.isLoadingOlderHistory,
            initialTurnsLoaded: state.renderSnapshot.initialTurnsLoaded,
            olderHistoryLoadErrorMessage: state.renderSnapshot.olderHistoryLoadErrorMessage
        )
    }

    // Returns the currently running turn id for a specific thread, if any.
    func activeTurnID(for threadId: String) -> String? {
        activeTurnIdByThread[threadId]
    }

    // Updates the per-thread active turn mapping and refreshes dependent repo/timeline state.
    func setActiveTurnID(_ turnId: String?, for threadId: String) {
        if let turnId, !turnId.isEmpty {
            activeTurnIdByThread[threadId] = turnId
        } else {
            activeTurnIdByThread.removeValue(forKey: threadId)
        }
        refreshBusyRepoRootsAndDependentTimelineStates()
        refreshThreadTimelineState(for: threadId)
    }

    // Toggles the fallback running marker for pre-turn activity while keeping repo-busy state in sync.
    func setProtectedRunningFallback(_ isActive: Bool, for threadId: String) {
        if isActive {
            protectedRunningFallbackThreadIDs.insert(threadId)
        } else {
            protectedRunningFallbackThreadIDs.remove(threadId)
        }
        refreshBusyRepoRootsAndDependentTimelineStates()
        refreshThreadTimelineState(for: threadId)
    }

    // Marks a rollout-mirrored run for extra thread/resume catch-up until a real
    // assistant delta arrives or the turn completes.
    func markMirroredRunningCatchupNeeded(for threadId: String) {
        mirroredRunningCatchupThreadIDs.insert(threadId)
        lastMirroredRunningCatchupAtByThread.removeValue(forKey: threadId)
    }

    // Stops extra catch-up polling once a live assistant stream exists or the run ends.
    func clearMirroredRunningCatchupNeeded(for threadId: String) {
        mirroredRunningCatchupThreadIDs.remove(threadId)
        lastMirroredRunningCatchupAtByThread.removeValue(forKey: threadId)
    }

    // Keeps desktop-origin rollout runs authoritative across short stale server snapshots.
    func markDesktopMirroredRunning(for threadId: String) {
        desktopMirroredRunningThreadIDs.insert(threadId)
        desktopMirroredRunningStaleSnapshotCountsByThread[threadId] = 0
        desktopMirroredRunningLastActivityAtByThread[threadId] = Date()
    }

    func isDesktopMirroredRunning(_ threadId: String) -> Bool {
        desktopMirroredRunningThreadIDs.contains(threadId)
    }

    func noteDesktopMirroredRunningActivity(for threadId: String) {
        guard desktopMirroredRunningThreadIDs.contains(threadId) else {
            return
        }

        desktopMirroredRunningStaleSnapshotCountsByThread[threadId] = 0
        desktopMirroredRunningLastActivityAtByThread[threadId] = Date()
    }

    func shouldPreserveDesktopMirroredRunningAfterStaleSnapshot(for threadId: String) -> Bool {
        guard desktopMirroredRunningThreadIDs.contains(threadId) else {
            return false
        }

        let staleCount = desktopMirroredRunningStaleSnapshotCountsByThread[threadId] ?? 0
        let lastActivityAt = desktopMirroredRunningLastActivityAtByThread[threadId] ?? Date()
        let hasRecentMirrorActivity = Date().timeIntervalSince(lastActivityAt)
            <= DesktopMirroredRunningPolicy.recentActivityGraceInterval
        guard staleCount < DesktopMirroredRunningPolicy.staleSnapshotGraceCount || hasRecentMirrorActivity else {
            desktopMirroredRunningThreadIDs.remove(threadId)
            desktopMirroredRunningStaleSnapshotCountsByThread.removeValue(forKey: threadId)
            desktopMirroredRunningLastActivityAtByThread.removeValue(forKey: threadId)
            return false
        }

        desktopMirroredRunningStaleSnapshotCountsByThread[threadId] = staleCount + 1
        return true
    }

    // Clears running/fallback flags together when a thread finishes or disappears.
    func clearRunningState(for threadId: String) {
        runningThreadIDs.remove(threadId)
        protectedRunningFallbackThreadIDs.remove(threadId)
        pendingReconnectRunContinuityThreadIDs.remove(threadId)
        displacedActiveTurnIDsByThread.removeValue(forKey: threadId)
        supersededTurnIDsByIDLessRunByThread.removeValue(forKey: threadId)
        provisionalIDLessTurnIDByThread.removeValue(forKey: threadId)
        desktopMirroredRunningThreadIDs.remove(threadId)
        desktopMirroredRunningStaleSnapshotCountsByThread.removeValue(forKey: threadId)
        desktopMirroredRunningLastActivityAtByThread.removeValue(forKey: threadId)
        clearMirroredRunningCatchupNeeded(for: threadId)
        refreshBusyRepoRootsAndDependentTimelineStates()
        refreshThreadTimelineState(for: threadId)
        scheduleCanonicalHistoryReconcileIfNeeded(for: threadId)
    }

    // Clears every running marker during disconnect/cleanup so stale repo-busy state cannot leak.
    func clearAllRunningState() {
        runningThreadIDs.removeAll()
        protectedRunningFallbackThreadIDs.removeAll()
        displacedActiveTurnIDsByThread.removeAll()
        supersededTurnIDsByIDLessRunByThread.removeAll()
        provisionalIDLessTurnIDByThread.removeAll()
        desktopMirroredRunningThreadIDs.removeAll()
        desktopMirroredRunningStaleSnapshotCountsByThread.removeAll()
        desktopMirroredRunningLastActivityAtByThread.removeAll()
        mirroredRunningCatchupThreadIDs.removeAll()
        lastMirroredRunningCatchupAtByThread.removeAll()
        refreshBusyRepoRootsAndDependentTimelineStates()
        // Always refresh all threads: threads without a gitWorkingDirectory won't appear in
        // changedRoots but still need their isThreadRunning flag updated after clearing.
        refreshAllThreadTimelineStates()
        for threadId in threadsNeedingCanonicalHistoryReconcile {
            scheduleCanonicalHistoryReconcileIfNeeded(for: threadId)
        }
    }

    // Schedules one full reconcile after a lightweight running catch-up once the thread settles.
    func scheduleCanonicalHistoryReconcileIfNeeded(for threadId: String) {
        // A provisional JSONL page needs its canonical replacement even while the turn is
        // running. The merge is revision-guarded below; deferring it until completion leaves a
        // reopen showing only a partial tail for the entire active turn.
        let mayReconcileDuringActiveTurn = provisionalPaginatedHistoryThreadIDs.contains(threadId)
        guard threadsNeedingCanonicalHistoryReconcile.contains(threadId),
              canonicalHistoryReconcileTaskByThreadID[threadId] == nil,
              canonicalHistoryReconcileRetryTaskByThreadID[threadId] == nil,
              isConnected,
              (mayReconcileDuringActiveTurn || !threadHasActiveOrRunningTurn(threadId)),
              thread(for: threadId)?.syncState == .live else {
            return
        }

        canonicalHistoryReconcileTaskByThreadID[threadId] = Task { @MainActor [weak self] in
            var shouldRetry = false
            var retryDelayNanoseconds: UInt64 = 0
            defer {
                self?.canonicalHistoryReconcileTaskByThreadID.removeValue(forKey: threadId)
                if shouldRetry {
                    self?.canonicalHistoryReconcileRetryTaskByThreadID[threadId]?.cancel()
                    self?.canonicalHistoryReconcileRetryTaskByThreadID[threadId] = Task { @MainActor [weak self] in
                        defer {
                            self?.canonicalHistoryReconcileRetryTaskByThreadID.removeValue(forKey: threadId)
                        }
                        if retryDelayNanoseconds > 0 {
                            try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                        }
                        guard !Task.isCancelled else {
                            return
                        }
                        // Release this timer's single-flight slot before asking
                        // the scheduler to create the next reconcile attempt.
                        self?.canonicalHistoryReconcileRetryTaskByThreadID.removeValue(forKey: threadId)
                        self?.scheduleCanonicalHistoryReconcileIfNeeded(for: threadId)
                    }
                }
            }

            guard let self,
                  self.threadsNeedingCanonicalHistoryReconcile.contains(threadId),
                  self.isConnected,
                  (self.provisionalPaginatedHistoryThreadIDs.contains(threadId)
                      || !self.threadHasActiveOrRunningTurn(threadId)),
                  self.thread(for: threadId)?.syncState == .live else {
                return
            }

            do {
                let outcome = try await self.loadThreadHistoryIfNeeded(threadId: threadId, forceRefresh: true)
                guard !Task.isCancelled else { return }
                if outcome.didCompleteCanonicalReconcile {
                    self.markThreadCanonicalHistoryReconciled(threadId)
                } else if outcome == .loadedPaginatedWindow {
                    self.markThreadPaginatedHistorySatisfied(threadId)
                } else if outcome.needsCanonicalRetry,
                          self.threadsNeedingCanonicalHistoryReconcile.contains(threadId),
                          self.isConnected,
                          (self.provisionalPaginatedHistoryThreadIDs.contains(threadId)
                              || !self.threadHasActiveOrRunningTurn(threadId)),
                          self.thread(for: threadId)?.syncState == .live {
                    shouldRetry = true
                    if outcome == .deferredAfterTimeout
                        || outcome == .deferredAfterEmptyPage
                        || outcome == .deferredAfterUnavailablePage {
                        retryDelayNanoseconds = self.nextCanonicalHistoryReconcileRetryDelay(for: threadId)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if self.shouldTreatAsThreadNotFound(error) {
                    self.threadsNeedingCanonicalHistoryReconcile.remove(threadId)
                    self.threadsWithSatisfiedDeferredHistoryHydration.remove(threadId)
                    self.canonicalHistoryReconcileRetryAttemptByThreadID.removeValue(forKey: threadId)
                    self.handleMissingThread(threadId)
                } else if self.threadsNeedingCanonicalHistoryReconcile.contains(threadId),
                          self.isConnected,
                          (self.provisionalPaginatedHistoryThreadIDs.contains(threadId)
                              || !self.threadHasActiveOrRunningTurn(threadId)),
                          self.thread(for: threadId)?.syncState == .live {
                    shouldRetry = true
                    retryDelayNanoseconds = self.nextCanonicalHistoryReconcileRetryDelay(for: threadId)
                }
            }
        }
    }

    private func nextCanonicalHistoryReconcileRetryDelay(for threadId: String) -> UInt64 {
        let nextAttempt = min((canonicalHistoryReconcileRetryAttemptByThreadID[threadId] ?? 0) + 1, 7)
        canonicalHistoryReconcileRetryAttemptByThreadID[threadId] = nextAttempt
        return CanonicalHistoryReconcileRetryPolicy.delayNanoseconds(forAttempt: nextAttempt)
    }

    // Marks a large chat as "local-first for now, but still needs one authoritative server merge".
    func markThreadNeedingCanonicalHistoryReconcile(
        _ threadId: String,
        requestImmediateSync: Bool = false
    ) {
        threadsWithSatisfiedDeferredHistoryHydration.remove(threadId)
        let inserted = threadsNeedingCanonicalHistoryReconcile.insert(threadId).inserted
        if inserted {
            canonicalHistoryReconcileRetryAttemptByThreadID.removeValue(forKey: threadId)
        }
        scheduleCanonicalHistoryReconcileIfNeeded(for: threadId)

        guard requestImmediateSync else {
            return
        }

        requestImmediateActiveThreadSync(threadId: threadId)
    }

    // Clears the deferred-hydration pending flag only after a full canonical merge succeeds.
    func markThreadCanonicalHistoryReconciled(_ threadId: String) {
        guard threadsNeedingCanonicalHistoryReconcile.contains(threadId)
                || threadsWithSatisfiedDeferredHistoryHydration.contains(threadId)
                || hasLargePersistedTranscript(threadId: threadId) else {
            threadsNeedingCanonicalHistoryReconcile.remove(threadId)
            threadsWithSatisfiedDeferredHistoryHydration.remove(threadId)
            canonicalHistoryReconcileRetryAttemptByThreadID.removeValue(forKey: threadId)
            return
        }

        threadsNeedingCanonicalHistoryReconcile.remove(threadId)
        threadsWithSatisfiedDeferredHistoryHydration.insert(threadId)
        canonicalHistoryReconcileRetryAttemptByThreadID.removeValue(forKey: threadId)
    }

    // With turn pagination, the cursor-backed store replaces one-shot full-history reconciliation.
    func markThreadPaginatedHistorySatisfied(_ threadId: String) {
        threadsNeedingCanonicalHistoryReconcile.remove(threadId)
        canonicalHistoryReconcileRetryAttemptByThreadID.removeValue(forKey: threadId)
    }

    // Returns the latest real terminal outcome seen for a thread.
    func latestTurnTerminalState(for threadId: String) -> CodexTurnTerminalState? {
        latestTurnTerminalStateByThread[threadId]
    }

    // Returns the terminal outcome for a specific turn when known.
    func turnTerminalState(
        for turnId: String?,
        threadId: String? = nil
    ) -> CodexTurnTerminalState? {
        guard let turnId else { return nil }
        if CodexSyntheticIdentifiers.isProjectedDesktopTurnID(turnId),
           let threadId {
            return projectedTerminalStateByThreadID[threadId]?[turnId]
        }
        return terminalStateByTurnID[turnId]
    }

    // Returns turn ids that ended via interruption so copy actions can stay hidden.
    func stoppedTurnIDs(for threadId: String) -> Set<String> {
        stoppedTurnIDsByThread[threadId] ?? []
    }

    // Returns sidebar-only chat badge state. This intentionally stays separate from
    // per-turn runtime truth so "chat finished unread" does not leak into timeline logic.
    func threadRunBadgeState(for threadId: String) -> CodexThreadRunBadgeState? {
        if threadHasActiveOrRunningTurn(threadId) {
            return .running
        }
        // Goal lifecycle outranks stale ready/failed dots: an active goal keeps
        // working on its own and attention states need the user to intervene.
        if let goal = goalByThreadID[threadId] {
            switch goal.status {
            case .active:
                return .goalActive
            case .blocked, .usageLimited, .budgetLimited:
                return .goalAttention
            case .paused, .complete:
                break
            }
        }
        if failedThreadIDs.contains(threadId) {
            return .failed
        }
        if readyThreadIDs.contains(threadId) {
            return .ready
        }
        return nil
    }

    // Clears "ready/failed" badges when the user has opened a thread.
    func markThreadAsViewed(_ threadId: String) {
        clearRunningThreadWatch(threadId)
        clearOutcomeBadge(for: threadId)
        if threadCompletionBanner?.threadId == threadId {
            threadCompletionBanner = nil
        }
    }

    // Marks thread as actively running while ensuring stale outcomes are cleared.
    func markThreadAsRunning(_ threadId: String) {
        // Streaming deltas re-assert running on every chunk; when nothing would
        // change, skip the busy-roots rebuild and timeline refresh entirely so
        // token streaming stays O(1) instead of O(threads) per delta.
        if runningThreadIDs.contains(threadId),
           threadsPendingCompletionHaptic.contains(threadId),
           latestTurnTerminalStateByThread[threadId] == nil,
           !readyThreadIDs.contains(threadId),
           !failedThreadIDs.contains(threadId) {
            return
        }
        runningThreadIDs.insert(threadId)
        threadsPendingCompletionHaptic.insert(threadId)
        latestTurnTerminalStateByThread.removeValue(forKey: threadId)
        clearOutcomeBadge(for: threadId)
        refreshBusyRepoRootsAndDependentTimelineStates()
        refreshThreadTimelineState(for: threadId)
        updateBackgroundRunGraceTask()
    }

    // Drops the eager runtime-running flag after a stop attempt proves the server still
    // has not published a usable turn id, while keeping protected fallback recovery alive.
    func demoteVisibleRunningStateToProtectedFallback(for threadId: String) {
        runningThreadIDs.remove(threadId)
        refreshBusyRepoRootsAndDependentTimelineStates()
        refreshThreadTimelineState(for: threadId)
        updateBackgroundRunGraceTask()
    }

    // Removes outcome badges while preserving the active-running state.
    func clearOutcomeBadge(for threadId: String) {
        readyThreadIDs.remove(threadId)
        failedThreadIDs.remove(threadId)
    }

    // Marks a chat as ready for sidebar presentation only when it completed off-screen.
    func markReadyIfUnread(threadId: String) {
        clearRunningThreadWatch(threadId)
        let wasAlreadyReady = readyThreadIDs.contains(threadId)
        clearOutcomeBadge(for: threadId)
        guard activeThreadId != threadId else {
            return
        }
        readyThreadIDs.insert(threadId)
        // Show the banner only on the first unread completion, not on every later sync refresh.
        if !wasAlreadyReady {
            presentThreadCompletionBannerIfNeeded(threadId: threadId)
        }
    }

    // Marks a thread as failed only when the user is not already viewing it.
    func markFailedIfUnread(threadId: String) {
        clearRunningThreadWatch(threadId)
        clearOutcomeBadge(for: threadId)
        guard activeThreadId != threadId else {
            return
        }
        failedThreadIDs.insert(threadId)
    }

    // Promotes a thread to the post-run sidebar state from an external completion signal.
    func applyRunCompletionBadgeState(threadId: String, result: CodexRunCompletionResult) {
        switch result {
        case .completed:
            markReadyIfUnread(threadId: threadId)
        case .failed:
            markFailedIfUnread(threadId: threadId)
        }
    }

    // Records the final run outcome so UI can distinguish completed vs interrupted turns.
    func recordTurnTerminalState(
        threadId: String,
        turnId: String?,
        state: CodexTurnTerminalState,
        updatesThreadState: Bool = true
    ) {
        let previousState = latestTurnTerminalStateByThread[threadId]
        if updatesThreadState {
            latestTurnTerminalStateByThread[threadId] = state
        }
        // Desktop snapshots synthesize `ipc-turn-N` per thread, so the same id
        // can exist in many conversations. Keep those outcomes thread-scoped;
        // persisting them in the global turn-id map poisons unrelated threads.
        if let turnId {
            if CodexSyntheticIdentifiers.isProjectedDesktopTurnID(turnId) {
                projectedTerminalStateByThreadID[threadId, default: [:]][turnId] = state
            } else if terminalStateByTurnID[turnId] != state {
                terminalStateByTurnID[turnId] = state
                persistTurnTerminalStates()
            }
        }
        refreshThreadTimelineState(for: threadId)
        if updatesThreadState {
            triggerRunCompletionHapticIfNeeded(
                threadId: threadId,
                state: state,
                previousState: previousState
            )
        }
    }

    // Sets the active thread and lazily hydrates old messages from server history.
    @discardableResult
    func prepareThreadForDisplay(threadId: String) async -> Bool {
        activeThreadId = threadId
        markThreadAsViewed(threadId)
        // Opening a thread mid-mirror-batch must render immediately: settle any
        // open catch-up burst so the initial updateCurrentOutput below is not
        // deferred to the batch flush (finish is idempotent when no burst is open).
        finishTimelineCatchUpBurst(threadId: threadId)
        updateCurrentOutput(for: threadId)
        var didRefreshRunningState = false
        var shouldRequestImmediateSync = true

        guard isConnected else {
            return true
        }

        // Freshly created empty chats do not need an immediate resume/read pass.
        // Skipping that first hydration avoids extra RPC contention when another
        // thread is already running and the user simply wants a blank composer.
        if shouldSkipInitialDisplayHydration(threadId: threadId) {
            return true
        }

        // Reopening a huge, already-materialized chat should prefer local persisted rows over
        // an immediate full resume/read pass, otherwise one tap can freeze the app on-device.
        if shouldDeferHeavyDisplayHydration(threadId: threadId) {
            // Large chats still need one lightweight turn-state ping so reconnect can rediscover
            // a live run before we decide to trust the local persisted transcript.
            didRefreshRunningState = await refreshInFlightTurnState(threadId: threadId)
            guard !Task.isCancelled else {
                return false
            }
            if shouldTrustClosedStateAfterTurnRefresh(
                threadId: threadId,
                didRefreshTurnState: didRefreshRunningState
            ) {
                markThreadNeedingCanonicalHistoryReconcile(
                    threadId,
                    requestImmediateSync: activeThreadId == threadId
                )
                return true
            }
        }

        do {
            try await ensureThreadResumed(threadId: threadId)
        } catch {
            if shouldTreatAsThreadNotFound(error) {
                handleMissingThread(threadId)
            }
            return false
        }
        guard !Task.isCancelled else {
            return false
        }

        let catchupOutcome = await catchUpRunningThreadIfNeeded(
            threadId: threadId,
            shouldForceResume: true,
            didRefreshTurnState: didRefreshRunningState
        )
        guard !Task.isCancelled else {
            return false
        }

        if catchupOutcome.isRunning {
            // When reopening a running thread, force a fresh resume snapshot so the
            // timeline catches up with output produced while the thread was off-screen.
            // Keep a sync fallback only when the shared catch-up pipeline skipped
            // the forced resume for throttling or a transient refresh failure. With
            // pagination, resume intentionally sends `excludeTurns: true`, so it only
            // refreshes lifecycle metadata and a separate history sync must still load
            // the complete current turn instead of leaving only the latest live delta.
            if catchupOutcome.didRunForcedResume {
                shouldRequestImmediateSync = shouldRequestImmediateHistorySyncAfterRunningCatchup(
                    didRunForcedResume: true
                )
            }
            updateCurrentOutput(for: threadId)
        }
        guard !Task.isCancelled, activeThreadId == threadId else {
            return false
        }
        if shouldRequestImmediateSync {
            requestImmediateActiveThreadSync(threadId: threadId, forceHistoryRefresh: true)
        }
        return true
    }

    func shouldRequestImmediateHistorySyncAfterRunningCatchup(
        didRunForcedResume: Bool
    ) -> Bool {
        !didRunForcedResume || supportsTurnPagination
    }

    // Detects a brand-new local thread that has no timeline to hydrate yet.
    func shouldSkipInitialDisplayHydration(threadId: String) -> Bool {
        shouldSkipInitialDisplayHydration(
            threadId: threadId,
            hasVisibleMessages: !messages(for: threadId).isEmpty,
            isThreadRunning: threadHasActiveOrRunningTurn(threadId)
        )
    }

    func shouldSkipInitialDisplayHydration(
        threadId: String,
        hasVisibleMessages: Bool,
        isThreadRunning: Bool
    ) -> Bool {
        guard resumedThreadIDs.contains(threadId),
              !hydratedThreadIDs.contains(threadId),
              !isThreadRunning,
              !hasVisibleMessages,
              thread(for: threadId)?.syncState == .live else {
            return false
        }

        return true
    }

    // A freshly started thread has metadata but no server history until the
    // first user message materializes it. Treat that as an empty composer state.
    func shouldTreatAsEmptyUnmaterializedThreadHistory(
        _ error: CodexServiceError,
        threadId: String,
        markHydratedWhenNotMaterialized: Bool
    ) -> Bool {
        guard case .rpcError(let rpcError) = error else {
            return false
        }

        let message = rpcError.message.lowercased()
        guard message.contains("not materialized")
                && message.contains("before first user message")
                && shouldShowImmediateEmptyPlaceholder(
                    threadId: threadId,
                    hasVisibleMessages: !messages(for: threadId).isEmpty,
                    isThreadRunning: threadHasActiveOrRunningTurn(threadId)
                ) else {
            return false
        }

        if markHydratedWhenNotMaterialized
            && !deferHydratedMarkForNotMaterializedThreadIDs.contains(threadId) {
            hydratedThreadIDs.insert(threadId)
            initialTurnsLoadedByThreadID.insert(threadId)
        }
        olderHistoryLoadErrorByThreadID.removeValue(forKey: threadId)
        if activeThreadId == threadId {
            lastErrorMessage = nil
        }
        refreshThreadTimelineState(for: threadId)
        return true
    }

    // The first turn can be running before Codex has persisted a readable
    // history page. During that window, live events own the timeline.
    func shouldDeferRunningThreadHistoryHydration(threadId: String, forceRefresh: Bool) -> Bool {
        guard threadHasActiveOrRunningTurn(threadId) else {
            return false
        }
        guard forceRefresh else {
            return true
        }

        let threadMessages = messagesByThread[threadId] ?? []
        let userMessageCount = threadMessages.filter { $0.role == .user }.count
        let hasAssistantOutput = threadMessages.contains { message in
            message.role == .assistant
                && message.kind != .thinking
                && Self.hasMeaningfulHistoryText(message.text)
        }

        return initialTurnsLoadedByThreadID.contains(threadId)
            && !hasRemoteOlderThreadHistoryCursor(threadId: threadId)
            && !hasKnownLocalHistoryStart(threadId: threadId)
            && userMessageCount <= 1
            && !hasAssistantOutput
    }

    // Prefers the locally persisted transcript when a non-running thread is already huge.
    // The active sync loop can still refresh lighter chats, but giant histories should not
    // block first paint or crash the device just because the user tapped the row.
    func shouldDeferHeavyDisplayHydration(threadId: String) -> Bool {
        guard !threadHasActiveOrRunningTurn(threadId) else {
            return false
        }

        if threadsNeedingCanonicalHistoryReconcile.contains(threadId) {
            return false
        }

        if threadsWithSatisfiedDeferredHistoryHydration.contains(threadId) {
            return true
        }

        guard hasLargePersistedTranscript(threadId: threadId) else {
            return false
        }

        return true
    }

    // Centralizes the "large chat" threshold so deferred hydration only applies to heavy transcripts.
    func hasLargePersistedTranscript(threadId: String) -> Bool {
        messages(for: threadId).count > TurnTimelineProjectionPolicy.eagerHydrationMessageLimit
    }

    // Only trust a "thread is closed" decision when the turn-state refresh actually succeeded.
    // A failed ping means "unknown", so callers should fall back instead of bailing out early.
    func shouldTrustClosedStateAfterTurnRefresh(threadId: String, didRefreshTurnState: Bool) -> Bool {
        didRefreshTurnState && !threadHasActiveOrRunningTurn(threadId)
    }

    // Prevents repeated forced resumes when the user rapidly switches between running chats.
    func takeForcedRunningResumePermit(
        for threadId: String,
        minInterval: TimeInterval = 1.0,
        now: Date = Date()
    ) -> Bool {
        if let lastRefreshAt = lastForcedRunningResumeAtByThread[threadId],
           now.timeIntervalSince(lastRefreshAt) < minInterval {
            return false
        }

        lastForcedRunningResumeAtByThread[threadId] = now
        return true
    }

    // Starts a short-lived watch for a running thread that just went off-screen.
    func watchRunningThreadIfNeeded(_ threadId: String?, ttl: TimeInterval = 30) {
        guard let threadId = normalizedInterruptIdentifier(threadId),
              threadId != activeThreadId,
              threadHasActiveOrRunningTurn(threadId) else {
            return
        }

        runningThreadWatchByID[threadId] = CodexRunningThreadWatch(
            threadId: threadId,
            expiresAt: Date().addingTimeInterval(ttl)
        )
    }

    func clearRunningThreadWatch(_ threadId: String?) {
        guard let threadId = normalizedInterruptIdentifier(threadId) else {
            return
        }
        runningThreadWatchByID.removeValue(forKey: threadId)
    }

    // Keeps a just-left running thread observable for a short time without polling everything.
    func handleDisplayedThreadChange(from previousThreadId: String?, to nextThreadId: String?) {
        let normalizedPrevious = normalizedInterruptIdentifier(previousThreadId)
        let normalizedNext = normalizedInterruptIdentifier(nextThreadId)

        guard normalizedPrevious != normalizedNext else {
            return
        }

        watchRunningThreadIfNeeded(normalizedPrevious)
        clearRunningThreadWatch(normalizedNext)
        resetThreadTimelineProjectionWindow(for: normalizedPrevious)
    }

    // Collapses a grown "load earlier" render window once the user leaves the thread, so
    // recurring timeline refreshes stop paying reducer cost for history nobody is reading.
    func resetThreadTimelineProjectionWindow(for threadId: String?) {
        guard let threadId,
              threadTimelineProjectionLimitByThreadID.removeValue(forKey: threadId) != nil else {
            return
        }
        refreshThreadTimelineState(for: threadId)
    }

    // Loads the recent history page once per thread, leaving older pages behind a cursor.
    @discardableResult
    func loadThreadHistoryIfNeeded(
        threadId: String,
        forceRefresh: Bool = false,
        markHydratedWhenNotMaterialized: Bool = true,
        allowForceRefreshRetry: Bool = true
    ) async throws -> ThreadHistoryLoadOutcome {
        if forceRefresh {
            forcedHistoryLoadThreadIDs.insert(threadId)
        }
        if shouldShowImmediateEmptyPlaceholder(
            threadId: threadId,
            hasVisibleMessages: !messages(for: threadId).isEmpty,
            isThreadRunning: threadHasActiveOrRunningTurn(threadId)
        ) {
            forcedHistoryLoadThreadIDs.remove(threadId)
            hydratedThreadIDs.insert(threadId)
            initialTurnsLoadedByThreadID.insert(threadId)
            olderHistoryLoadErrorByThreadID.removeValue(forKey: threadId)
            refreshThreadTimelineState(for: threadId)
            return .alreadyHydrated
        }
        repairEmptyThreadHistoryLoadStateIfNeeded(threadId: threadId)
        if !forceRefresh,
           hydratedThreadIDs.contains(threadId),
           hasSatisfiedInitialThreadHistoryLoad(threadId: threadId) {
            return .alreadyHydrated
        }
        if !markHydratedWhenNotMaterialized {
            deferHydratedMarkForNotMaterializedThreadIDs.insert(threadId)
        }

        if let existingTask = threadHistoryLoadTaskByThreadID[threadId] {
            let outcome = try await existingTask.value
            if forceRefresh,
               allowForceRefreshRetry,
               outcome == .skippedForRunningThread,
               threadHasActiveOrRunningTurn(threadId) {
                forcedHistoryLoadThreadIDs.insert(threadId)
                return try await loadThreadHistoryIfNeeded(
                    threadId: threadId,
                    forceRefresh: true,
                    markHydratedWhenNotMaterialized: markHydratedWhenNotMaterialized,
                    allowForceRefreshRetry: false
                )
            }
            return outcome
        }

        let refreshGeneration = currentPerThreadRefreshGeneration(for: threadId)
        let task = Task<ThreadHistoryLoadOutcome, Error> { @MainActor in
            let hadInitialTurnsLoadedBeforeRefresh = initialTurnsLoadedByThreadID.contains(threadId)
            let hadAuthoritativeLocalStartBeforeRefresh = hasAuthoritativeLocalHistoryStart(threadId: threadId)
            let hadProvisionalPaginatedHistoryBeforeRefresh = provisionalPaginatedHistoryThreadIDs.contains(threadId)
            let requiresCanonicalPaginatedHistory = hadProvisionalPaginatedHistoryBeforeRefresh
                || threadsNeedingCanonicalHistoryReconcile.contains(threadId)
            var initialTurnsTask: Task<ThreadTurnsHistoryPage, Error>?
            loadingThreadIDs.insert(threadId)
            defer {
                initialTurnsTask?.cancel()
                // Only clear bookkeeping for the latest refresh generation.
                if isPerThreadRefreshCurrent(for: threadId, generation: refreshGeneration) {
                    loadingThreadIDs.remove(threadId)
                    threadHistoryLoadTaskByThreadID.removeValue(forKey: threadId)
                    forcedHistoryLoadThreadIDs.remove(threadId)
                    deferHydratedMarkForNotMaterializedThreadIDs.remove(threadId)
                }
            }

            let shouldForceRefresh = forceRefresh || forcedHistoryLoadThreadIDs.contains(threadId)

            // A turn may have started while chat-open work was in flight. Normal background
            // history loads should still stay out of the way, but forced refreshes are
            // used when reopening a running thread and need to merge the latest snapshot.
            if shouldDeferRunningThreadHistoryHydration(
                threadId: threadId,
                forceRefresh: shouldForceRefresh
            ) {
                hydratedThreadIDs.insert(threadId)
                if !supportsTurnPagination {
                    initialTurnsLoadedByThreadID.insert(threadId)
                }
                return .skippedForRunningThread
            }

            if supportsTurnPagination {
                initialTurnsTask = Task { @MainActor in
                    try await self.fetchInitialThreadTurnsHistoryPage(
                        threadId: threadId,
                        requireCanonical: requiresCanonicalPaginatedHistory
                    )
                }
            }

            var loadedViaPagination = false
            var loadedProvisionalJsonlFallback = false
            var paginatedNextCursor: JSONValue?
            var shouldSeedPaginatedInitialCursor = false
            var decodedThreadFromHistory: CodexThread?
            var threadObject: RPCObject
            if supportsTurnPagination {
                do {
                    let turnsPage: ThreadTurnsHistoryPage
                    if let initialTurnsTask {
                        turnsPage = try await initialTurnsTask.value
                    } else {
                        turnsPage = try await fetchInitialThreadTurnsHistoryPage(
                            threadId: threadId,
                            requireCanonical: requiresCanonicalPaginatedHistory
                        )
                    }
                    loadedViaPagination = true
                    loadedProvisionalJsonlFallback = turnsPage.isProvisionalJsonlFallback
                    let shouldSeedInitialCursor = !hadInitialTurnsLoadedBeforeRefresh
                        || hadProvisionalPaginatedHistoryBeforeRefresh
                        || (
                            !hasRemoteOlderThreadHistoryCursor(threadId: threadId)
                                && !hadAuthoritativeLocalStartBeforeRefresh
                        )
                    paginatedNextCursor = turnsPage.nextCursor
                    shouldSeedPaginatedInitialCursor = shouldSeedInitialCursor
                    threadObject = [
                        "id": .string(threadId),
                        "turns": .array(chronologicalTurnsFromDescendingPage(turnsPage.turns)),
                    ]
                } catch let error as CodexServiceError {
                    if shouldTreatAsEmptyUnmaterializedThreadHistory(
                        error,
                        threadId: threadId,
                        markHydratedWhenNotMaterialized: markHydratedWhenNotMaterialized
                    ) {
                        return .notMaterialized
                    }
                    if case .rpcError(let rpcError) = error, rpcError.code == -32600 {
                        let shouldMarkHydrated = markHydratedWhenNotMaterialized
                            && !deferHydratedMarkForNotMaterializedThreadIDs.contains(threadId)
                        if shouldMarkHydrated {
                            hydratedThreadIDs.insert(threadId)
                            initialTurnsLoadedByThreadID.insert(threadId)
                        }
                        return .notMaterialized
                    }
                    if shouldDeferThreadHistoryAfterTimeout(error) {
                        markThreadHistoryDeferredAfterTimeout(threadId: threadId)
                        debugSyncLog("thread/turns/list timed out for thread=\(threadId); showing local timeline while history is deferred")
                        return .deferredAfterTimeout
                    }
                    if shouldDeferThreadHistoryAfterBridgeFailure(error) {
                        markThreadHistoryDeferredAfterUnavailablePage(threadId: threadId)
                        debugSyncLog("bridge could not supply thread/turns/list for thread=\(threadId); keeping local timeline while history retries")
                        return .deferredAfterUnavailablePage
                    }
                    if consumeUnsupportedTurnPagination(error, attemptedMethod: "thread/turns/list") {
                        do {
                            threadObject = try await fetchLegacyThreadHistoryObject(threadId: threadId)
                        } catch let legacyError as CodexServiceError {
                            if case .rpcError(let rpcError) = legacyError, rpcError.code == -32600 {
                                let shouldMarkHydrated = markHydratedWhenNotMaterialized
                                    && !deferHydratedMarkForNotMaterializedThreadIDs.contains(threadId)
                                if shouldMarkHydrated {
                                    hydratedThreadIDs.insert(threadId)
                                    initialTurnsLoadedByThreadID.insert(threadId)
                                }
                                return .notMaterialized
                            }
                            if shouldDeferThreadHistoryAfterTimeout(legacyError) {
                                markThreadHistoryDeferredAfterTimeout(threadId: threadId)
                                debugSyncLog("legacy thread/read timed out for thread=\(threadId); showing local timeline while history is deferred")
                                return .deferredAfterTimeout
                            }
                            throw legacyError
                        }
                        extractContextWindowUsageIfAvailable(threadId: threadId, threadObject: threadObject)
                        if let threadData = try? JSONEncoder().encode(JSONValue.object(threadObject)),
                           let decoded = try? JSONDecoder().decode(CodexThread.self, from: threadData) {
                            decodedThreadFromHistory = decoded
                        }
                    } else {
                        throw error
                    }
                }
            } else {
                do {
                    threadObject = try await fetchLegacyThreadHistoryObject(threadId: threadId)
                } catch let error as CodexServiceError {
                    if shouldTreatAsEmptyUnmaterializedThreadHistory(
                        error,
                        threadId: threadId,
                        markHydratedWhenNotMaterialized: markHydratedWhenNotMaterialized
                    ) {
                        return .notMaterialized
                    }
                    if case .rpcError(let rpcError) = error, rpcError.code == -32600 {
                        let shouldMarkHydrated = markHydratedWhenNotMaterialized
                            && !deferHydratedMarkForNotMaterializedThreadIDs.contains(threadId)
                        if shouldMarkHydrated {
                            hydratedThreadIDs.insert(threadId)
                            initialTurnsLoadedByThreadID.insert(threadId)
                        }
                        return .notMaterialized
                    }
                    if shouldDeferThreadHistoryAfterTimeout(error) {
                        markThreadHistoryDeferredAfterTimeout(threadId: threadId)
                        debugSyncLog("legacy thread/read timed out for thread=\(threadId); showing local timeline while history is deferred")
                        return .deferredAfterTimeout
                    }
                    throw error
                }
                extractContextWindowUsageIfAvailable(threadId: threadId, threadObject: threadObject)
                if let threadData = try? JSONEncoder().encode(JSONValue.object(threadObject)),
                   let decoded = try? JSONDecoder().decode(CodexThread.self, from: threadData) {
                    decodedThreadFromHistory = decoded
                }
            }

            let historyMessages = decodeMessagesFromThreadRead(threadId: threadId, threadObject: threadObject)
            let isSuspiciousEmptyHistory = historyMessages.isEmpty
                && shouldDeferEmptyThreadHistoryPage(
                    threadId: threadId,
                    loadedViaPagination: loadedViaPagination
                )
            if isSuspiciousEmptyHistory {
                markThreadHistoryDeferredAfterEmptyPage(threadId: threadId)
                debugSyncLog("thread history returned no visible rows despite prior-content evidence thread=\(threadId); keeping cached timeline and retrying")
                return .deferredAfterEmptyPage
            }

            if let decodedThreadFromHistory {
                upsertThread(decodedThreadFromHistory, treatAsServerState: true)
            }
            // Only an accepted canonical or paginated response confirms that
            // an active cached-only sidebar row is a real server thread.
            restoredThreadSnapshotIDs.remove(threadId)

            if loadedViaPagination,
               !loadedProvisionalJsonlFallback,
               let paginatedNextCursor {
                updateOlderThreadHistoryCursorFromInitialPage(
                    threadId: threadId,
                    cursor: paginatedNextCursor,
                    isFreshInitialLoad: shouldSeedPaginatedInitialCursor
                )
            }

            let historyTerminalStates = decodeTurnTerminalStatesFromThreadRead(threadObject)
            let didUpdateTerminalStates = mergeHistoryTurnTerminalStates(
                threadId: threadId,
                terminalStatesByTurnID: historyTerminalStates
            )
            registerSubagentThreads(from: historyMessages, parentThreadId: threadId)
            if loadedViaPagination {
                seedThreadTimelineProjectionForPaginatedHistory(
                    threadId: threadId,
                    decodedMessageCount: historyMessages.count
                )
                initialTurnsLoadedByThreadID.insert(threadId)
            } else {
                updateThreadTimelineProjectionForEmbeddedHistory(threadId: threadId, decodedMessageCount: historyMessages.count)
            }
            var outcome: ThreadHistoryLoadOutcome = loadedViaPagination
                ? (loadedProvisionalJsonlFallback
                    ? .loadedProvisionalPaginatedWindow
                    : .loadedPaginatedWindow)
                : .loadedCanonicalHistory
            if !historyMessages.isEmpty {
                var cachedMessages = messagesByThread[threadId] ?? []
                var cachedMessageRevision = messageRevision(for: threadId)
                let replacesMirroredSourceEpoch = !loadedProvisionalJsonlFallback
                    && pendingCanonicalSourceReplacementThreadIDs.contains(threadId)
                func preparedExistingMessages(
                    _ cached: [CodexMessage],
                    shouldRepairMirroredCanonicalTail: Bool
                ) -> [CodexMessage] {
                    return shouldRepairMirroredCanonicalTail
                        ? Self.existingMessagesForCanonicalSourceReplacement(
                            cached,
                            history: historyMessages
                        )
                        : cached
                }
                var existingMessages = preparedExistingMessages(
                    cachedMessages,
                    shouldRepairMirroredCanonicalTail: replacesMirroredSourceEpoch
                        || !threadHasActiveOrRunningTurn(threadId)
                )
                var usedRecentWindow = !replacesMirroredSourceEpoch
                    && shouldForceRefresh
                    && threadHasActiveOrRunningTurn(threadId)
                    && Self.shouldPreferRecentHistoryWindow(
                        existingCount: existingMessages.count,
                        historyCount: historyMessages.count
                    )
                if loadedViaPagination,
                   shouldTrustExistingCacheAsPrePaginationFullHistory(
                    threadId: threadId,
                    existingMessages: existingMessages,
                    paginatedMessages: historyMessages,
                    hadInitialTurnsLoadedBeforeRefresh: hadInitialTurnsLoadedBeforeRefresh,
                    hadAuthoritativeLocalStartBeforeRefresh: hadAuthoritativeLocalStartBeforeRefresh
                   ) {
                    markThreadLocalHistoryStartAuthoritative(threadId, clearRemoteCursor: true)
                    debugSyncLog("thread history migrated pre-pagination full cache thread=\(threadId) local=\(existingMessages.count) firstPage=\(historyMessages.count)")
                } else if !loadedViaPagination, !usedRecentWindow {
                    markThreadLocalHistoryStartAuthoritative(threadId, clearRemoteCursor: true)
                }
                var merged = try await mergeHistoryMessagesOffMainActor(
                    existing: existingMessages,
                    history: historyMessages,
                    activeThreadIDs: Set(activeTurnIdByThread.keys),
                    activeTurnIDs: Set(activeTurnIdByThread.values),
                    runningThreadIDs: runningThreadIDs,
                    preferRecentWindow: usedRecentWindow
                )
                guard !Task.isCancelled,
                      isPerThreadRefreshCurrent(for: threadId, generation: refreshGeneration) else {
                    throw CancellationError()
                }
                if messageRevision(for: threadId) != cachedMessageRevision {
                    // A detached merge must never write an older snapshot over a
                    // delta that arrived while it was working. Rebase once on the
                    // latest timeline; if it changes again, leave live state alone
                    // and let the canonical reconcile scheduler retry when quiet.
                    cachedMessages = messagesByThread[threadId] ?? []
                    cachedMessageRevision = messageRevision(for: threadId)
                    existingMessages = preparedExistingMessages(
                        cachedMessages,
                        shouldRepairMirroredCanonicalTail: replacesMirroredSourceEpoch
                            || !threadHasActiveOrRunningTurn(threadId)
                    )
                    usedRecentWindow = !replacesMirroredSourceEpoch
                        && shouldForceRefresh
                        && threadHasActiveOrRunningTurn(threadId)
                        && Self.shouldPreferRecentHistoryWindow(
                            existingCount: existingMessages.count,
                            historyCount: historyMessages.count
                        )
                    merged = try await mergeHistoryMessagesOffMainActor(
                        existing: existingMessages,
                        history: historyMessages,
                        activeThreadIDs: Set(activeTurnIdByThread.keys),
                        activeTurnIDs: Set(activeTurnIdByThread.values),
                        runningThreadIDs: runningThreadIDs,
                        preferRecentWindow: usedRecentWindow
                    )
                    guard !Task.isCancelled,
                          isPerThreadRefreshCurrent(for: threadId, generation: refreshGeneration) else {
                        throw CancellationError()
                    }
                    guard messageRevision(for: threadId) == cachedMessageRevision else {
                        markThreadNeedingCanonicalHistoryReconcile(threadId)
                        hydratedThreadIDs.insert(threadId)
                        return .skippedForRunningThread
                    }
                }
                if usedRecentWindow {
                    markThreadNeedingCanonicalHistoryReconcile(threadId)
                }
                guard shouldForceRefresh || !threadHasActiveOrRunningTurn(threadId) else {
                    hydratedThreadIDs.insert(threadId)
                    return .skippedForRunningThread
                }
                if replacesMirroredSourceEpoch {
                    pendingCanonicalSourceReplacementThreadIDs.remove(threadId)
                }

                if loadedProvisionalJsonlFallback {
                    provisionalPaginatedHistoryThreadIDs.insert(threadId)
                    markThreadNeedingCanonicalHistoryReconcile(threadId)
                } else if loadedViaPagination {
                    provisionalPaginatedHistoryThreadIDs.remove(threadId)
                }

                // Litter keeps any already-hydrated local transcript and merges pages into it.
                // Do not shrink a legacy/full local cache down to only the first 5-turn page.
                let nextMessages = merged
                if nextMessages != cachedMessages {
                    messagesByThread[threadId] = nextMessages
                    persistMessages()
                    updateCurrentOutput(for: threadId)
                } else if didUpdateTerminalStates {
                    refreshThreadTimelineState(for: threadId)
                }
                if usedRecentWindow {
                    outcome = .loadedRecentWindow
                    if !threadHasActiveOrRunningTurn(threadId) {
                        scheduleCanonicalHistoryReconcileIfNeeded(for: threadId)
                    }
                } else if outcome.didCompleteCanonicalReconcile, !threadHasActiveOrRunningTurn(threadId) {
                    markThreadCanonicalHistoryReconciled(threadId)
                }
            } else if didUpdateTerminalStates {
                refreshThreadTimelineState(for: threadId)
            }

            guard !Task.isCancelled,
                  isPerThreadRefreshCurrent(for: threadId, generation: refreshGeneration) else {
                throw CancellationError()
            }
            if outcome == .loadedPaginatedWindow, !threadHasActiveOrRunningTurn(threadId) {
                markThreadPaginatedHistorySatisfied(threadId)
            } else if outcome.didCompleteCanonicalReconcile, !threadHasActiveOrRunningTurn(threadId) {
                markThreadCanonicalHistoryReconciled(threadId)
            }
            clearDeferredThreadHistoryErrorIfNeeded(threadId: threadId)
            initialTurnsLoadedByThreadID.insert(threadId)
            hydratedThreadIDs.insert(threadId)
            refreshThreadTimelineState(for: threadId)
            return outcome
        }

        threadHistoryLoadTaskByThreadID[threadId] = task
        return try await task.value
    }

    // Extracts context window usage from thread/read response if the runtime includes it.
    func extractContextWindowUsageIfAvailable(threadId: String, threadObject: [String: JSONValue]) {
        guard let usage = extractContextWindowUsage(from: threadObject) else { return }
        contextWindowUsageByThread[threadId] = usage
    }

    // Appends a user message immediately so UI feels instant before server events arrive.
    @discardableResult
    func appendUserMessage(
        threadId: String,
        text: String,
        turnId: String? = nil,
        attachments: [CodexImageAttachment] = [],
        fileMentions: [String] = [],
        skillMentions: [String] = [],
        pluginMentions: [String] = []
    ) -> String {
        let trimmedText = Self.normalizedMessageText(text)
        guard Self.hasMeaningfulHistoryText(trimmedText)
                || !attachments.isEmpty
                || !skillMentions.isEmpty
                || !pluginMentions.isEmpty else {
            return ""
        }

        let message = CodexMessage(
            threadId: threadId,
            role: .user,
            text: trimmedText,
            fileMentions: fileMentions,
            skillMentions: skillMentions,
            pluginMentions: pluginMentions,
            turnId: turnId,
            isStreaming: false,
            deliveryState: .pending,
            attachments: attachments
        )
        appendMessage(message)
        return message.id
    }

    // Upserts a confirmed user row mirrored from a desktop-origin rollout so
    // reopened threads can display the remote prompt immediately without
    // disturbing the phone-native pending-send path.
    func appendConfirmedMirroredUserMessage(
        threadId: String,
        turnId: String?,
        text: String,
        fileMentions: [String] = [],
        itemId: String? = nil,
        createdAt: Date? = nil
    ) {
        let trimmedText = Self.normalizedMessageText(text)
        guard Self.hasMeaningfulHistoryText(trimmedText) else {
            return
        }

        let normalizedItemId = Self.normalizedHistoryIdentifier(itemId)
        if let existingIndex = messagesByThread[threadId]?.lastIndex(where: { candidate in
            guard candidate.role == .user else {
                return false
            }
            if let normalizedItemId,
               Self.normalizedHistoryIdentifier(candidate.itemId) == normalizedItemId {
                return true
            }
            return Self.userMessageMatchesTextForHistory(candidate, text: trimmedText)
                && Self.mirroredUserTurnIdentityAllowsMerge(candidate.turnId, turnId)
        }) {
            var didMutate = false
            if messagesByThread[threadId]?[existingIndex].deliveryState != .confirmed {
                messagesByThread[threadId]?[existingIndex].deliveryState = .confirmed
                didMutate = true
            }
            if let turnId {
                let existingTurnId = messagesByThread[threadId]?[existingIndex].turnId
                if existingTurnId == nil
                    || (Self.isSyntheticDesktopTurnIdentifier(existingTurnId)
                        && !Self.isSyntheticDesktopTurnIdentifier(turnId)) {
                    messagesByThread[threadId]?[existingIndex].turnId = turnId
                    didMutate = true
                }
            }
            if let normalizedItemId {
                let existingItemId = Self.normalizedHistoryIdentifier(messagesByThread[threadId]?[existingIndex].itemId)
                if existingItemId == nil
                    || (Self.isSyntheticDesktopUserItemIdentifier(existingItemId)
                        && !Self.isSyntheticDesktopUserItemIdentifier(normalizedItemId)) {
                    messagesByThread[threadId]?[existingIndex].itemId = normalizedItemId
                    didMutate = true
                }
            }
            if (messagesByThread[threadId]?[existingIndex].fileMentions.isEmpty ?? true), !fileMentions.isEmpty {
                messagesByThread[threadId]?[existingIndex].fileMentions = fileMentions
                didMutate = true
            }
            if let createdAt,
               CodexTimestampParser.isTrustworthyServerDate(createdAt),
               let existingCreatedAt = messagesByThread[threadId]?[existingIndex].createdAt,
               (!CodexTimestampParser.isTrustworthyServerDate(existingCreatedAt)
                    || abs(existingCreatedAt.timeIntervalSince(createdAt)) > 0.5) {
                messagesByThread[threadId]?[existingIndex].createdAt = createdAt
                didMutate = true
            }
            if moveMirroredOpeningUserBeforeTurnOutputIfNeeded(
                threadId: threadId,
                turnId: turnId,
                messageIndex: existingIndex
            ) {
                didMutate = true
            }
            guard didMutate else {
                return
            }
            messagesByThread[threadId]?.sortByOrderIndexIfNeeded()
            persistMessages()
            updateCurrentOutput(for: threadId)
            return
        }

        let orderIndex = reserveMirroredOpeningUserOrderIndex(threadId: threadId, turnId: turnId)
        appendMessage(
            CodexMessage(
                threadId: threadId,
                role: .user,
                text: trimmedText,
                fileMentions: fileMentions,
                createdAt: createdAt ?? Date(),
                turnId: turnId,
                itemId: normalizedItemId,
                deliveryState: .confirmed,
                orderIndex: orderIndex
            )
        )
    }

    // Desktop rollout mirrors can deliver assistant output before the opening user event.
    // Reserve the first same-turn slot so the phone timeline matches the Mac transcript.
    private func reserveMirroredOpeningUserOrderIndex(threadId: String, turnId: String?) -> Int? {
        guard let turnAnchor = mirroredOpeningUserAnchor(threadId: threadId, turnId: turnId) else {
            return nil
        }

        guard let indices = messagesByThread[threadId]?.indices else {
            return turnAnchor
        }

        for index in indices {
            guard let currentOrder = messagesByThread[threadId]?[index].orderIndex,
                  currentOrder >= turnAnchor else {
                continue
            }
            messagesByThread[threadId]?[index].orderIndex = currentOrder + 1
        }
        // Only this thread's indices moved; other threads cannot raise the max.
        CodexMessageOrderCounter.seed(fromThreadMessages: messagesByThread[threadId] ?? [])
        return turnAnchor
    }

    // Repositions an already-created mirrored opener without moving real steer prompts.
    private func moveMirroredOpeningUserBeforeTurnOutputIfNeeded(
        threadId: String,
        turnId: String?,
        messageIndex: Int
    ) -> Bool {
        guard let threadMessages = messagesByThread[threadId],
              threadMessages.indices.contains(messageIndex),
              let turnAnchor = mirroredOpeningUserAnchor(
                threadId: threadId,
                turnId: turnId,
                existingMessageID: threadMessages[messageIndex].id
              ),
              threadMessages[messageIndex].orderIndex > turnAnchor else {
            return false
        }

        let previousOrder = threadMessages[messageIndex].orderIndex
        for index in threadMessages.indices where index != messageIndex {
            guard let currentOrder = messagesByThread[threadId]?[index].orderIndex,
                  currentOrder >= turnAnchor,
                  currentOrder < previousOrder else {
                continue
            }
            messagesByThread[threadId]?[index].orderIndex = currentOrder + 1
        }
        messagesByThread[threadId]?[messageIndex].orderIndex = turnAnchor
        return true
    }

    // Returns the first output slot only when this turn has no other user row.
    // Multiple user rows mean an in-turn steer, where chronological order is intentional.
    private func mirroredOpeningUserAnchor(
        threadId: String,
        turnId: String?,
        existingMessageID: String? = nil
    ) -> Int? {
        guard let turnId, !turnId.isEmpty,
              let threadMessages = messagesByThread[threadId] else {
            return nil
        }

        var firstOutputOrder: Int?
        for message in threadMessages where message.turnId == turnId {
            if message.id == existingMessageID {
                continue
            }
            if message.role == .user {
                return nil
            }
            firstOutputOrder = min(firstOutputOrder ?? message.orderIndex, message.orderIndex)
        }
        return firstOutputOrder
    }

    // Appends a system message in the current thread timeline.
    func appendSystemMessage(
        threadId: String,
        text: String,
        turnId: String? = nil,
        itemId: String? = nil,
        kind: CodexMessageKind = .chat,
        isStreaming: Bool = false
    ) {
        let trimmedText = Self.normalizedMessageText(text)
        let effectiveIsStreaming = isStreaming && !isApplyingReplayedBridgeEvent
        guard Self.hasMeaningfulHistoryText(trimmedText) || effectiveIsStreaming else {
            return
        }
        let resolvedTurnId = turnId ?? activeTurnIdByThread[threadId]

        if kind == .fileChange,
           let resolvedTurnId, !resolvedTurnId.isEmpty,
           var threadMessages = messagesByThread[threadId] {
            let incomingPathKeys = normalizedFileChangePathKeys(from: trimmedText)
            let isSnapshotPayload = isFileChangeSnapshotPayload(trimmedText)

            var targetIndex: Int?
            if !incomingPathKeys.isEmpty {
                targetIndex = threadMessages.indices.reversed().first(where: { index in
                    let candidate = threadMessages[index]
                    guard candidate.role == .system,
                          candidate.kind == .fileChange,
                          (candidate.turnId == resolvedTurnId
                              || (candidate.turnId == nil
                                  && turnlessFileChangeRowBelongsToTurn(candidate, threadId: threadId, turnId: resolvedTurnId))) else {
                        return false
                    }
                    let candidatePathKeys = normalizedFileChangePathKeys(from: candidate.text)
                    return !candidatePathKeys.isDisjoint(with: incomingPathKeys)
                })
            } else if isSnapshotPayload,
                      let existingID = uniqueFileChangeMessageIDForTurn(
                          threadId: threadId,
                          turnId: resolvedTurnId,
                          allowsTurnlessFallback: true
                      ) {
                targetIndex = threadMessages.firstIndex(where: { $0.id == existingID })
            }

            if targetIndex == nil {
                targetIndex = threadMessages.indices.reversed().first(where: { index in
                    let candidate = threadMessages[index]
                    return candidate.role == .system
                        && candidate.kind == .fileChange
                        && candidate.turnId == resolvedTurnId
                        && candidate.text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit
                        && Self.normalizedMessageText(candidate.text) == trimmedText
                })
            }

            if let targetIndex {
                let existingText = threadMessages[targetIndex].text
                let nextText: String
                if isSnapshotPayload {
                    nextText = trimmedText
                } else {
                    nextText = mergeAssistantDelta(existingText: existingText, incomingDelta: trimmedText)
                }
                threadMessages[targetIndex].text = nextText
                threadMessages[targetIndex].isStreaming = effectiveIsStreaming
                threadMessages[targetIndex].turnId = resolvedTurnId
                if threadMessages[targetIndex].itemId == nil {
                    threadMessages[targetIndex].itemId = itemId
                }
                pruneDuplicateSystemRows(
                    in: &threadMessages,
                    keepIndex: targetIndex,
                    kind: .fileChange,
                    turnId: resolvedTurnId,
                    fileChangePathKeys: incomingPathKeys
                )
                // Preserve the row's original timeline slot. The render reducer handles
                // trailing file-change cards inside their own turn without crossing later users.
                threadMessages.sortByOrderIndexIfNeeded()
                messagesByThread[threadId] = threadMessages
                persistMessages()
                updateCurrentOutput(for: threadId)
                return
            }
        }

        appendMessage(
            CodexMessage(
                threadId: threadId,
                role: .system,
                kind: kind,
                text: trimmedText,
                turnId: resolvedTurnId,
                itemId: itemId,
                isStreaming: effectiveIsStreaming,
                deliveryState: .confirmed
            )
        )
    }

    // Upserts the inline plan card so streamed deltas and final plan text stay on one row.
    func upsertPlanMessage(
        threadId: String,
        turnId: String?,
        itemId: String?,
        text: String? = nil,
        explanation: String? = nil,
        steps: [CodexPlanStep]? = nil,
        isStreaming: Bool,
        planPresentation: CodexPlanPresentation
    ) {
        preparePlanItemIdentityForUpsert(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            planPresentation: planPresentation
        )

        if let itemId, !itemId.isEmpty {
            upsertStreamingSystemItemMessage(
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                kind: .plan,
                text: text ?? "",
                isStreaming: isStreaming
            )
        } else if let turnId, !turnId.isEmpty {
            upsertStreamingSystemTurnMessage(
                threadId: threadId,
                turnId: turnId,
                kind: .plan,
                text: text ?? "",
                isStreaming: isStreaming
            )
        } else {
            appendSystemMessage(
                threadId: threadId,
                text: text ?? "",
                turnId: turnId,
                itemId: itemId,
                kind: .plan,
                isStreaming: isStreaming
            )
        }

        guard let messageIndex = findLatestPlanMessageIndex(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            planPresentation: planPresentation
        ) else {
            return
        }

        var planState = messagesByThread[threadId]?[messageIndex].planState ?? CodexPlanState()
        if let explanation {
            let trimmedExplanation = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            planState.explanation = trimmedExplanation.isEmpty ? nil : trimmedExplanation
        }
        if let steps {
            planState.steps = steps
        }
        messagesByThread[threadId]?[messageIndex].planState = planState
        messagesByThread[threadId]?[messageIndex].planPresentation = resolvedPlanPresentation(
            requested: planPresentation,
            turnId: turnId,
            threadId: threadId
        )
        refreshDerivedPlanMetadata(threadId: threadId, messageIndex: messageIndex)
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    // Progress is one mutable plan snapshot per turn. Canonical history can
    // promote its identity while replay still emits an older placeholder/call id,
    // so bind every known alias to the one surviving row without downgrading the
    // canonical todo-list identity.
    private func preparePlanItemIdentityForUpsert(
        threadId: String,
        turnId: String?,
        itemId: String?,
        planPresentation: CodexPlanPresentation
    ) {
        guard let resolvedTurnId = normalizedStreamingItemID(turnId) else {
            return
        }

        let syntheticItemId = syntheticStreamingItemId(turnId: resolvedTurnId, kind: .plan)
        let syntheticKey = streamingItemMessageKey(threadId: threadId, itemId: syntheticItemId)

        guard planPresentation == .progress else {
            // A result-plan item is a separate row. Do not let a progress alias
            // capture it merely because both items belong to the same turn.
            if let mappedID = streamingSystemMessageByItemID[syntheticKey],
               let mappedIndex = findMessageIndex(threadId: threadId, messageId: mappedID),
               messagesByThread[threadId]?[mappedIndex].resolvedPlanPresentation == .progress {
                streamingSystemMessageByItemID.removeValue(forKey: syntheticKey)
            }
            return
        }

        let candidateIndices = messagesByThread[threadId]?.indices.filter { index in
            guard let candidate = messagesByThread[threadId]?[index] else {
                return false
            }
            return candidate.role == .system
                && candidate.kind == .plan
                && normalizedStreamingItemID(candidate.turnId) == resolvedTurnId
                && candidate.resolvedPlanPresentation == .progress
        } ?? []
        guard candidateIndices.count == 1,
              let candidateIndex = candidateIndices.first,
              let candidate = messagesByThread[threadId]?[candidateIndex] else {
            // A synthetic alias owned by a result row (or one ambiguous progress
            // row among several) must not capture this progress update.
            streamingSystemMessageByItemID.removeValue(forKey: syntheticKey)
            return
        }

        let incomingItemId = normalizedStreamingItemID(itemId)
        let existingItemId = normalizedStreamingItemID(candidate.itemId)
        if let existingItemId {
            streamingSystemMessageByItemID[
                streamingItemMessageKey(threadId: threadId, itemId: existingItemId)
            ] = candidate.id
        }
        if let incomingItemId {
            streamingSystemMessageByItemID[
                streamingItemMessageKey(threadId: threadId, itemId: incomingItemId)
            ] = candidate.id
        }
        streamingSystemMessageByItemID[syntheticKey] = candidate.id

        guard let incomingItemId,
              incomingItemId != existingItemId,
              shouldAdoptIncomingProgressPlanItemID(
                existingItemId: existingItemId,
                incomingItemId: incomingItemId
              ) else {
            return
        }
        messagesByThread[threadId]?[candidateIndex].itemId = incomingItemId
    }

    private func shouldAdoptIncomingProgressPlanItemID(
        existingItemId: String?,
        incomingItemId: String
    ) -> Bool {
        guard let existingItemId else {
            return true
        }
        if incomingItemId.hasPrefix("todo-list-") {
            return !existingItemId.hasPrefix("todo-list-")
        }
        return Self.isProvisionalSystemItemIdentifier(existingItemId)
            && !Self.isProvisionalSystemItemIdentifier(incomingItemId)
    }

    // Completes a streamed plan without creating a placeholder or replacing its
    // meaningful delta text when the terminal lifecycle payload is empty.
    @discardableResult
    func finalizeExistingPlanMessage(
        threadId: String,
        turnId: String?,
        itemId: String?
    ) -> Bool {
        guard let messageIndex = findLatestPlanMessageIndex(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            planPresentation: .resultStreaming
        ),
        let message = messagesByThread[threadId]?[messageIndex],
        message.role == .system,
        message.kind == .plan else {
            return false
        }

        messagesByThread[threadId]?[messageIndex].isStreaming = false
        messagesByThread[threadId]?[messageIndex].planPresentation = resolvedPlanPresentation(
            requested: .resultCompletedItem,
            turnId: turnId,
            threadId: threadId
        )
        refreshDerivedPlanMetadata(threadId: threadId, messageIndex: messageIndex)

        // One row can be reachable through both a synthetic turn key and a real
        // item key, so clear every alias once its lifecycle is complete.
        streamingSystemMessageByItemID = streamingSystemMessageByItemID.filter { _, messageID in
            messageID != message.id
        }
        persistMessages()
        updateCurrentOutput(for: threadId)
        return true
    }

    // Keeps multi-agent orchestration events on a single structured timeline row.
    func upsertSubagentActionMessage(
        threadId: String,
        turnId: String?,
        itemId: String?,
        action: CodexSubagentAction,
        isStreaming: Bool
    ) {
        let summaryText = action.summaryText
        registerSubagentThreads(action: action, parentThreadId: threadId)
        let resolvedItemId = resolvedSubagentActionItemId(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            action: action
        )

        if let resolvedItemId, !resolvedItemId.isEmpty {
            upsertStreamingSystemItemMessage(
                threadId: threadId,
                turnId: turnId,
                itemId: resolvedItemId,
                kind: .subagentAction,
                text: summaryText,
                isStreaming: isStreaming
            )
        } else {
            appendSystemMessage(
                threadId: threadId,
                text: summaryText,
                turnId: turnId,
                itemId: resolvedItemId,
                kind: .subagentAction,
                isStreaming: isStreaming
            )
        }

        guard let messageIndex = findLatestSubagentActionMessageIndex(
            threadId: threadId,
            turnId: turnId,
            itemId: resolvedItemId
        ) else {
            return
        }

        messagesByThread[threadId]?[messageIndex].text = summaryText
        messagesByThread[threadId]?[messageIndex].subagentAction = action
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    private func resolvedSubagentActionItemId(
        threadId: String,
        turnId: String?,
        itemId: String?,
        action: CodexSubagentAction
    ) -> String? {
        if let itemId = normalizedStreamingItemID(itemId) {
            if let turnId = normalizedStreamingItemID(turnId), !turnId.isEmpty {
                rebindMatchingSyntheticSubagentActionMessageIfNeeded(
                    threadId: threadId,
                    turnId: turnId,
                    realItemId: itemId,
                    action: action
                )
            }
            return itemId
        }

        guard let turnId = normalizedStreamingItemID(turnId), !turnId.isEmpty else {
            return nil
        }

        if let existingItemId = matchingSubagentActionMessage(
            threadId: threadId,
            turnId: turnId,
            action: action
        )?.itemId {
            return existingItemId
        }

        return nextSyntheticSubagentActionItemId(threadId: threadId, turnId: turnId)
    }

    private func matchingSubagentActionMessage(
        threadId: String,
        turnId: String,
        action: CodexSubagentAction
    ) -> CodexMessage? {
        let incomingPrompt = normalizedIdentifier(action.prompt)
        let incomingModel = normalizedIdentifier(action.model)

        return messagesByThread[threadId]?.reversed().first(where: { candidate in
            guard candidate.role == .system,
                  candidate.kind == .subagentAction,
                  candidate.turnId == turnId,
                  let candidateAction = candidate.subagentAction,
                  candidateAction.normalizedTool == action.normalizedTool else {
                return false
            }

            guard candidate.isStreaming,
                  candidate.text == action.summaryText else {
                return false
            }

            let candidatePrompt = normalizedIdentifier(candidateAction.prompt)
            let candidateModel = normalizedIdentifier(candidateAction.model)
            if let incomingPrompt, incomingPrompt == candidatePrompt {
                return true
            }
            if incomingPrompt == nil,
               let incomingModel,
               incomingModel == candidateModel {
                return true
            }

            return false
        })
    }

    private func nextSyntheticSubagentActionItemId(threadId: String, turnId: String) -> String {
        let prefix = syntheticSubagentActionItemIdPrefix(turnId: turnId)
        let existingCount = messagesByThread[threadId]?.reduce(into: 0) { count, candidate in
            guard candidate.role == .system,
                  candidate.kind == .subagentAction,
                  candidate.turnId == turnId,
                  candidate.itemId?.hasPrefix(prefix) == true else {
                return
            }
            count += 1
        } ?? 0

        return "\(prefix)\(existingCount + 1)"
    }

    private func rebindMatchingSyntheticSubagentActionMessageIfNeeded(
        threadId: String,
        turnId: String,
        realItemId: String,
        action: CodexSubagentAction
    ) {
        let realKey = streamingItemMessageKey(threadId: threadId, itemId: realItemId)
        guard streamingSystemMessageByItemID[realKey] == nil,
              let existing = matchingSubagentActionMessage(threadId: threadId, turnId: turnId, action: action),
              let existingItemId = normalizedStreamingItemID(existing.itemId),
              existingItemId.hasPrefix(syntheticSubagentActionItemIdPrefix(turnId: turnId)),
              let messageIndex = findMessageIndex(threadId: threadId, messageId: existing.id) else {
            return
        }

        let existingKey = streamingItemMessageKey(threadId: threadId, itemId: existingItemId)
        messagesByThread[threadId]?[messageIndex].itemId = realItemId
        if let existingMessageId = streamingSystemMessageByItemID[existingKey] {
            streamingSystemMessageByItemID[realKey] = existingMessageId
            streamingSystemMessageByItemID.removeValue(forKey: existingKey)
        }
    }

    // Adds or refreshes an inline structured question card for plan mode clarification requests.
    func upsertStructuredUserInputPrompt(
        threadId: String,
        turnId: String?,
        itemId: String,
        request: CodexStructuredUserInputRequest
    ) {
        let fallbackText = request.questions
            .map { question in
                let header = question.header.trimmingCharacters(in: .whitespacesAndNewlines)
                let prompt = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
                if header.isEmpty {
                    return prompt
                }
                return "\(header)\n\(prompt)"
            }
            .joined(separator: "\n\n")

        if let existingIndex = messagesByThread[threadId]?.indices.reversed().first(where: { index in
            let candidate = messagesByThread[threadId]?[index]
            return candidate?.role == .system
                && candidate?.kind == .userInputPrompt
                && candidate?.structuredUserInputRequest?.requestID == request.requestID
        }) {
            messagesByThread[threadId]?[existingIndex].text = fallbackText
            messagesByThread[threadId]?[existingIndex].turnId = turnId ?? messagesByThread[threadId]?[existingIndex].turnId
            messagesByThread[threadId]?[existingIndex].itemId = itemId
            messagesByThread[threadId]?[existingIndex].structuredUserInputRequest = request
            persistMessages()
            updateCurrentOutput(for: threadId)
            return
        }

        appendMessage(
            CodexMessage(
                threadId: threadId,
                role: .system,
                kind: .userInputPrompt,
                text: fallbackText,
                turnId: turnId,
                itemId: itemId,
                structuredUserInputRequest: request
            )
        )
    }

    // Removes resolved inline prompt cards once the server confirms the request lifecycle ended.
    func removeStructuredUserInputPrompt(requestID: JSONValue, threadIdHint: String? = nil) {
        let threadIDs = threadIdHint.map { [$0] } ?? Array(messagesByThread.keys)
        var didMutate = false

        for threadId in threadIDs {
            guard var threadMessages = messagesByThread[threadId] else {
                continue
            }

            let previousCount = threadMessages.count
            threadMessages.removeAll { message in
                message.kind == .userInputPrompt
                    && message.structuredUserInputRequest?.requestID == requestID
            }

            if threadMessages.count != previousCount {
                messagesByThread[threadId] = threadMessages
                didMutate = true
            }
        }

        guard didMutate else {
            return
        }

        persistMessages()
        if let activeThreadId {
            updateCurrentOutput(for: activeThreadId)
        }
    }

    // Clears all unresolved structured prompts in a thread when the user exits native plan mode.
    func removeAllStructuredUserInputPrompts(threadId: String) {
        guard var threadMessages = messagesByThread[threadId] else {
            return
        }

        let previousCount = threadMessages.count
        threadMessages.removeAll { message in
            message.kind == .userInputPrompt
        }

        guard threadMessages.count != previousCount else {
            return
        }

        messagesByThread[threadId] = threadMessages
        persistMessages()
        if let activeThreadId {
            updateCurrentOutput(for: activeThreadId)
        }
    }

    // Persists a hidden push-reset marker across all threads bound to the same repo.
    func appendHiddenPushResetMarkers(
        threadId: String,
        workingDirectory: String?,
        branch: String,
        remote: String?
    ) {
        let normalizedThreadID = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty else {
            return
        }

        let normalizedWorkingDirectory = normalizeWorkingDirectoryForPushReset(workingDirectory)
        let relatedThreadIDs: [String]
        if let normalizedWorkingDirectory {
            relatedThreadIDs = threads
                .filter { normalizeWorkingDirectoryForPushReset($0.gitWorkingDirectory) == normalizedWorkingDirectory }
                .map(\.id)
        } else {
            relatedThreadIDs = []
        }

        let targetThreadIDs = Set(relatedThreadIDs + [normalizedThreadID])
        for targetThreadID in targetThreadIDs {
            appendSystemMessage(
                threadId: targetThreadID,
                text: TurnSessionDiffResetMarker.text(branch: branch, remote: remote),
                itemId: TurnSessionDiffResetMarker.manualPushItemID
            )
        }
    }

    // Appends one concise activity line into the active thinking row for a turn.
    func appendThinkingActivityLine(
        threadId: String,
        turnId: String?,
        line: String
    ) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return
        }
        let isTurnActive = isTurnActiveForThinkingActivity(threadId: threadId, turnId: turnId)

        let existingMessages = messagesByThread[threadId] ?? []
        let targetIndex = thinkingActivityTargetIndex(
            in: existingMessages,
            turnId: turnId
        )

        // Late activity lines can arrive after turn/completed without turnId.
        // If there is no existing thinking row to merge into, ignore them instead
        // of creating a new trailing thinking block below the final assistant reply.
        let hasExplicitTurnId = turnId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !isTurnActive, targetIndex == nil, !hasExplicitTurnId {
            return
        }

        if let targetIndex {
            var threadMessages = existingMessages
            guard threadMessages[targetIndex].text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
                return
            }
            let existingText = Self.normalizedMessageText(threadMessages[targetIndex].text)
            guard !containsCaseInsensitiveLine(trimmedLine, in: existingText) else {
                return
            }

            let updatedText = existingText.isEmpty
                ? trimmedLine
                : "\(existingText)\n\(trimmedLine)"
            threadMessages[targetIndex].text = updatedText
            threadMessages[targetIndex].isStreaming = threadMessages[targetIndex].isStreaming || isTurnActive
            if threadMessages[targetIndex].turnId == nil, let turnId, !turnId.isEmpty {
                threadMessages[targetIndex].turnId = turnId
            }
            messagesByThread[threadId] = threadMessages
            persistMessages()
            updateStreamingSystemOutput(
                for: threadId,
                messageId: threadMessages[targetIndex].id,
                rawMessageIndex: targetIndex
            )
            return
        }

        appendSystemMessage(
            threadId: threadId,
            text: trimmedLine,
            turnId: turnId,
            kind: .thinking,
            isStreaming: isTurnActive
        )
    }

    // Routes generic technical activity through its own compact system row instead of thinking.
    func appendToolActivityLine(
        threadId: String,
        turnId: String?,
        line: String
    ) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return
        }

        let isTurnActive = isTurnActiveForThinkingActivity(threadId: threadId, turnId: turnId)
        let existingMessages = messagesByThread[threadId] ?? []
        let targetIndex = toolActivityTargetIndex(in: existingMessages, turnId: turnId)

        let hasExplicitTurnId = turnId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if !isTurnActive, targetIndex == nil, !hasExplicitTurnId {
            return
        }

        if let targetIndex {
            var threadMessages = existingMessages
            let existingText = threadMessages[targetIndex].text
            let mergedText = mergeToolActivityText(
                existing: existingText,
                incoming: trimmedLine,
                isStreaming: isTurnActive
            )
            guard mergedText != existingText else {
                return
            }

            threadMessages[targetIndex].text = mergedText
            threadMessages[targetIndex].isStreaming = threadMessages[targetIndex].isStreaming || isTurnActive
            if threadMessages[targetIndex].turnId == nil, let turnId, !turnId.isEmpty {
                threadMessages[targetIndex].turnId = turnId
            }
            messagesByThread[threadId] = threadMessages
            persistMessages()
            updateCurrentOutput(for: threadId)
            return
        }

        appendSystemMessage(
            threadId: threadId,
            text: trimmedLine,
            turnId: turnId,
            kind: .toolActivity,
            isStreaming: isTurnActive
        )
    }

    // Reuses only the latest tool-activity row inside the current system segment so
    // late legacy events do not rewrite rows that now sit above assistant content.
    func toolActivityTargetIndex(in messages: [CodexMessage], turnId: String?) -> Int? {
        for index in messages.indices.reversed() {
            let candidate = messages[index]
            if candidate.role == .assistant || candidate.role == .user {
                break
            }

            guard candidate.role == .system, candidate.kind == .toolActivity else {
                continue
            }

            if let turnId, !turnId.isEmpty {
                if candidate.turnId == turnId || candidate.turnId == nil {
                    return index
                }
                continue
            }

            if candidate.isStreaming {
                return index
            }
        }

        return nil
    }

    private func normalizeWorkingDirectoryForPushReset(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed == "/" {
            return trimmed
        }

        var normalized = trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        return normalized.isEmpty ? "/" : normalized
    }

    // Creates/updates a streaming system item message (thinking/toolActivity/fileChange/commandExecution).
    func upsertStreamingSystemItemMessage(
        threadId: String,
        turnId: String?,
        itemId: String,
        kind: CodexMessageKind,
        text: String,
        isStreaming: Bool
    ) {
        let effectiveIsStreaming = isStreaming && !isApplyingReplayedBridgeEvent
        let resolvedTurnId = turnId ?? activeTurnIdByThread[threadId]
        let key = streamingItemMessageKey(threadId: threadId, itemId: itemId)
        let syntheticItemId = resolvedTurnId.map { syntheticStreamingItemId(turnId: $0, kind: kind) }
        let syntheticKey = syntheticItemId.map { streamingItemMessageKey(threadId: threadId, itemId: $0) }
        let incomingFileChangePathKeys = kind == .fileChange
            ? normalizedFileChangePathKeys(from: text)
            : Set<String>()
        let incomingCommandKey = kind == .commandExecution
            ? commandExecutionPreviewKey(from: text)
            : nil
        let incomingToolActivityKey = kind == .toolActivity
            ? toolActivityPreviewKey(from: text)
            : nil
        if let mappedID = streamingSystemMessageByItemID[key],
           findMessageIndex(threadId: threadId, messageId: mappedID) == nil {
            streamingSystemMessageByItemID.removeValue(forKey: key)
        }
        if let syntheticKey,
           let mappedID = streamingSystemMessageByItemID[syntheticKey],
           findMessageIndex(threadId: threadId, messageId: mappedID) == nil {
            streamingSystemMessageByItemID.removeValue(forKey: syntheticKey)
        }
        let messageID: String?
        if let existingMessageID = streamingSystemMessageByItemID[key] {
            messageID = existingMessageID
        } else if let normalizedIncomingItemID = normalizedStreamingItemID(itemId),
                  let persistedMessage = messagesByThread[threadId]?
                    .filter({ candidate in
                        guard candidate.role == .system,
                              candidate.kind == kind || candidate.kind == .chat,
                              let candidateItemID = normalizedStreamingItemID(candidate.itemId) else {
                            return false
                        }
                        return candidateItemID == normalizedIncomingItemID
                    })
                    .min(by: { $0.orderIndex < $1.orderIndex }) {
            // Process relaunch clears the in-memory item lookup, but persisted
            // provider identity is still exact. Rehydrate it before any semantic
            // fallback so replayed completions update the original row in place.
            streamingSystemMessageByItemID[key] = persistedMessage.id
            if let syntheticKey {
                streamingSystemMessageByItemID[syntheticKey] = persistedMessage.id
            }
            messageID = persistedMessage.id
        } else if let syntheticKey,
                  kind != .commandExecution,
                  let migratedMessageID = streamingSystemMessageByItemID[syntheticKey],
                  canReuseSyntheticSystemItemAlias(
                    threadId: threadId,
                    messageId: migratedMessageID,
                    incomingItemId: itemId,
                    kind: kind
                  ) {
            // Rebind the synthetic turn key to the real item id once the server starts sending it.
            streamingSystemMessageByItemID[key] = migratedMessageID
            streamingSystemMessageByItemID.removeValue(forKey: syntheticKey)
            messageID = migratedMessageID
        } else if kind == .commandExecution,
                  let resolvedTurnId, !resolvedTurnId.isEmpty,
                  let incomingCommandKey {
            let matchingRows = (messagesByThread[threadId] ?? []).filter { candidate in
                guard candidate.role == .system,
                      candidate.kind == .commandExecution,
                      candidate.turnId == resolvedTurnId,
                      Self.isProvisionalSystemItemIdentifier(candidate.itemId)
                        || Self.isProvisionalSystemItemIdentifier(itemId),
                      let candidateKey = commandExecutionPreviewKey(from: candidate.text) else {
                    return false
                }
                return candidateKey == incomingCommandKey
            }
            if matchingRows.count == 1, let existingMessageID = matchingRows.first?.id {
                streamingSystemMessageByItemID[key] = existingMessageID
                if let syntheticKey {
                    streamingSystemMessageByItemID[syntheticKey] = existingMessageID
                }
                messageID = existingMessageID
            } else {
                messageID = nil
            }
        } else if kind == .toolActivity,
                  let resolvedTurnId, !resolvedTurnId.isEmpty,
                  let incomingToolActivityKey {
            let matchingRows = (messagesByThread[threadId] ?? []).filter { candidate in
                guard candidate.role == .system,
                      candidate.kind == .toolActivity,
                      candidate.turnId == resolvedTurnId,
                      let candidateKey = toolActivityPreviewKey(from: candidate.text),
                      canReuseLiveToolActivityRow(candidate, incomingItemId: itemId) else {
                    return false
                }
                return candidateKey == incomingToolActivityKey
            }

            if matchingRows.count == 1, let existingMessageID = matchingRows.first?.id {
                streamingSystemMessageByItemID[key] = existingMessageID
                if let syntheticKey {
                    streamingSystemMessageByItemID[syntheticKey] = existingMessageID
                }
                messageID = existingMessageID
            } else {
                messageID = nil
            }
        } else if kind == .fileChange,
                  let resolvedTurnId, !resolvedTurnId.isEmpty,
                  !incomingFileChangePathKeys.isEmpty,
                  let existingMessageID = messagesByThread[threadId]?.reversed().first(where: { candidate in
                      guard candidate.role == .system,
                            candidate.kind == .fileChange,
                            (candidate.turnId == resolvedTurnId
                                || (candidate.turnId == nil
                                    && turnlessFileChangeRowBelongsToTurn(candidate, threadId: threadId, turnId: resolvedTurnId))) else {
                          return false
                      }
                      let candidateKeys = normalizedFileChangePathKeys(from: candidate.text)
                      return !candidateKeys.isDisjoint(with: incomingFileChangePathKeys)
                  })?.id {
            // Some runtimes emit multiple file-change item ids for the same file in one turn.
            // Rebind them to one UI row keyed by path to avoid duplicate "Edited/Diff/Push" cards.
            streamingSystemMessageByItemID[key] = existingMessageID
            if let syntheticKey {
                streamingSystemMessageByItemID[syntheticKey] = existingMessageID
            }
            messageID = existingMessageID
        } else if kind == .fileChange,
                  let resolvedTurnId, !resolvedTurnId.isEmpty,
                  incomingFileChangePathKeys.isEmpty,
                  isFileChangeSnapshotPayload(text),
                  let existingMessageID = uniqueFileChangeMessageIDForTurn(
                      threadId: threadId,
                      turnId: resolvedTurnId,
                      allowsTurnlessFallback: true
                  ) {
            // Fallback: if payload has no extractable path and there's only one file-change row
            // in this turn, treat it as the same row instead of creating duplicates.
            streamingSystemMessageByItemID[key] = existingMessageID
            if let syntheticKey {
                streamingSystemMessageByItemID[syntheticKey] = existingMessageID
            }
            messageID = existingMessageID
        } else if kind == .thinking,
                  let resolvedTurnId, !resolvedTurnId.isEmpty,
                  let existingMessageID = uniqueProvisionalThinkingRowID(
                      threadId: threadId,
                      turnId: resolvedTurnId
                  ) {
            // Rollout mirrors aggregate a turn's reasoning under one synthetic
            // "rollout-thinking:" id while IPC mirrors stream real per-item ids.
            // When the live sources alternate mid-turn, rebind instead of
            // stacking a second "Thinking..." row for the same turn.
            streamingSystemMessageByItemID[key] = existingMessageID
            if let syntheticKey {
                streamingSystemMessageByItemID[syntheticKey] = existingMessageID
            }
            messageID = existingMessageID
        } else {
            messageID = nil
        }

        if let messageID,
           let index = findMessageIndex(threadId: threadId, messageId: messageID) {
            let incoming = text
            let incomingTrimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
            let isFileChangeSnapshot = kind == .fileChange
                && isFileChangeSnapshotPayload(incomingTrimmed)
            if !incomingTrimmed.isEmpty {
                let existing = messagesByThread[threadId]?[index].text ?? ""
                let existingTrimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
                if kind == .commandExecution {
                    // Command status rows are snapshots ("running" -> "completed"), not deltas.
                    messagesByThread[threadId]?[index].text = incomingTrimmed
                } else if kind == .toolActivity {
                    messagesByThread[threadId]?[index].text = mergeToolActivityText(
                        existing: existing,
                        incoming: incoming,
                        isStreaming: effectiveIsStreaming
                    )
                } else {
                    if isStreamingPlaceholder(incomingTrimmed, for: kind)
                        && !existingTrimmed.isEmpty
                        && !isStreamingPlaceholder(existingTrimmed, for: kind) {
                        // Ignore completion placeholders when we already have real streamed content.
                    } else if isStreamingPlaceholder(existingTrimmed, for: kind) {
                        // Replace placeholder labels with real content.
                        messagesByThread[threadId]?[index].text = incoming
                    } else if !effectiveIsStreaming || isFileChangeSnapshot {
                        // Completed item payloads are authoritative snapshots; replace streamed deltas.
                        messagesByThread[threadId]?[index].text = incoming
                    } else {
                        let merged = mergeAssistantDelta(existingText: existing, incomingDelta: incoming)
                        messagesByThread[threadId]?[index].text = merged
                    }
                }
            }

            messagesByThread[threadId]?[index].kind = kind
            messagesByThread[threadId]?[index].isStreaming = effectiveIsStreaming
            if let resolvedTurnId, messagesByThread[threadId]?[index].turnId == nil {
                messagesByThread[threadId]?[index].turnId = resolvedTurnId
            }
            if let syntheticItemId,
               messagesByThread[threadId]?[index].itemId == syntheticItemId {
                messagesByThread[threadId]?[index].itemId = itemId
            } else if messagesByThread[threadId]?[index].itemId == nil {
                messagesByThread[threadId]?[index].itemId = itemId
            } else if kind == .thinking,
                      Self.isProvisionalThinkingIdentifier(messagesByThread[threadId]?[index].itemId),
                      !Self.isProvisionalThinkingIdentifier(itemId) {
                // Adopt the real reasoning identity so a later real section opens
                // its own row instead of overwriting this one through the fallback.
                messagesByThread[threadId]?[index].itemId = itemId
            } else if kind == .commandExecution,
                      Self.isProvisionalSystemItemIdentifier(messagesByThread[threadId]?[index].itemId),
                      !Self.isProvisionalSystemItemIdentifier(itemId) {
                messagesByThread[threadId]?[index].itemId = itemId
            }
            if var threadMessages = messagesByThread[threadId],
               let refreshedIndex = threadMessages.indices.first(where: { threadMessages[$0].id == messageID }) {
                let keepID = threadMessages[refreshedIndex].id
                var finalRawIndex: Int?
                if let resolvedTurnId {
                    if kind == .fileChange {
                        pruneDuplicateSystemRows(
                            in: &threadMessages,
                            keepIndex: refreshedIndex,
                            kind: .fileChange,
                            turnId: resolvedTurnId,
                            fileChangePathKeys: incomingFileChangePathKeys,
                            isAuthoritativeFileChangeSnapshot: isFileChangeSnapshot
                        )
                    } else if kind == .commandExecution,
                              let incomingCommandKey {
                        pruneDuplicateSystemRows(
                            in: &threadMessages,
                            keepIndex: refreshedIndex,
                            kind: .commandExecution,
                            turnId: resolvedTurnId,
                            commandKey: incomingCommandKey
                        )
                    } else if kind == .toolActivity,
                              let incomingToolActivityKey {
                        pruneDuplicateSystemRows(
                            in: &threadMessages,
                            keepIndex: refreshedIndex,
                            kind: .toolActivity,
                            turnId: resolvedTurnId,
                            toolActivityKey: incomingToolActivityKey
                        )
                    }
                }
                if let normalizedIncomingItemID = normalizedStreamingItemID(itemId) {
                    let duplicateRows = threadMessages.filter { candidate in
                        guard candidate.id != keepID,
                              candidate.role == .system,
                              candidate.kind == kind || candidate.kind == .chat,
                              let candidateItemID = normalizedStreamingItemID(candidate.itemId) else {
                            return false
                        }
                        return candidateItemID == normalizedIncomingItemID
                    }
                    if let keepIndex = threadMessages.firstIndex(where: { $0.id == keepID }) {
                        let shouldSalvageDuplicateText = incomingTrimmed.isEmpty
                            || isStreamingPlaceholder(incomingTrimmed, for: kind)
                        for duplicate in duplicateRows {
                            if shouldSalvageDuplicateText,
                               duplicate.text.utf8.count > threadMessages[keepIndex].text.utf8.count {
                                threadMessages[keepIndex].text = duplicate.text
                            }
                            let keeperPlanCount = threadMessages[keepIndex].planState?.steps.count ?? 0
                            let duplicatePlanCount = duplicate.planState?.steps.count ?? 0
                            if duplicate.planState != nil,
                               (threadMessages[keepIndex].planState == nil
                                || duplicatePlanCount > keeperPlanCount) {
                                threadMessages[keepIndex].planState = duplicate.planState
                                threadMessages[keepIndex].planPresentation = duplicate.planPresentation
                                threadMessages[keepIndex].proposedPlan = duplicate.proposedPlan
                            }
                            if threadMessages[keepIndex].attachments.isEmpty,
                               !duplicate.attachments.isEmpty {
                                threadMessages[keepIndex].attachments = duplicate.attachments
                            }
                        }
                    }
                    threadMessages.removeAll { candidate in
                        guard candidate.id != keepID,
                              candidate.role == .system,
                              candidate.kind == kind || candidate.kind == .chat,
                              let candidateItemID = normalizedStreamingItemID(candidate.itemId) else {
                            return false
                        }
                        return candidateItemID == normalizedIncomingItemID
                    }
                }
                if let finalIndex = threadMessages.indices.first(where: { threadMessages[$0].id == keepID }) {
                    // Keep refreshed file-change rows anchored to their original turn.
                    // Intra-turn rendering still trails them after the assistant answer.
                    finalRawIndex = finalIndex
                }
                threadMessages.sortByOrderIndexIfNeeded()
                finalRawIndex = threadMessages.indices.first(where: { threadMessages[$0].id == keepID }) ?? finalRawIndex
                messagesByThread[threadId] = threadMessages
                persistMessages()
                if kind == .thinking, effectiveIsStreaming, let finalRawIndex {
                    updateStreamingSystemOutput(for: threadId, messageId: keepID, rawMessageIndex: finalRawIndex)
                } else {
                    updateCurrentOutput(for: threadId)
                }
                return
            }
            persistMessages()
            updateCurrentOutput(for: threadId)
            return
        }

        let initialText = text
        let initialTrimmed = initialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackText: String
        if !initialTrimmed.isEmpty {
            fallbackText = initialText
        } else {
            fallbackText = streamingPlaceholderText(for: kind)
        }

        let message = CodexMessage(
            threadId: threadId,
            role: .system,
            kind: kind,
            text: fallbackText,
            turnId: resolvedTurnId,
            itemId: itemId,
            isStreaming: effectiveIsStreaming,
            deliveryState: .confirmed
        )

        streamingSystemMessageByItemID[key] = message.id
        appendMessage(message)
    }

    private func normalizedFileChangePathKeys(from text: String) -> Set<String> {
        guard text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return []
        }
        let inlineTotalsRegex = try? NSRegularExpression(
            pattern: #"\s*[+\u{FF0B}]\s*\d+\s*[-\u{2212}\u{2013}\u{2014}\u{FE63}\u{FF0D}]\s*\d+\s*$"#
        )
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var keys: Set<String> = []

        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if trimmed.lowercased().hasPrefix("path:") {
                let rawPath = trimmed.dropFirst("Path:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                keys.formUnion(normalizedFileChangePathAliases(from: rawPath))
                continue
            }

            if trimmed.hasPrefix("+++ ") || trimmed.hasPrefix("--- ") {
                let rawPath = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                keys.formUnion(normalizedFileChangePathAliases(from: rawPath))
                continue
            }

            if trimmed.hasPrefix("diff --git ") {
                let components = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if components.count >= 4 {
                    keys.formUnion(normalizedFileChangePathAliases(from: String(components[3])))
                }
                continue
            }

            let lowercased = trimmed.lowercased()
            let actionVerbs = [
                "edited ",
                "updated ",
                "added ",
                "created ",
                "deleted ",
                "removed ",
                "renamed ",
                "moved ",
            ]
            if let verb = actionVerbs.first(where: { lowercased.hasPrefix($0) }) {
                var rawPath = String(trimmed.dropFirst(verb.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let inlineTotalsRegex {
                    let range = NSRange(location: 0, length: (rawPath as NSString).length)
                    rawPath = inlineTotalsRegex.stringByReplacingMatches(
                        in: rawPath,
                        range: range,
                        withTemplate: ""
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                keys.formUnion(normalizedFileChangePathAliases(from: rawPath))
            }
        }

        return keys
    }

    private func normalizedFileChangePathAliases(from rawPath: String) -> Set<String> {
        guard let normalized = normalizeFileChangePathKey(rawPath) else {
            return Set<String>()
        }

        var aliases: Set<String> = [normalized]
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        if let workspaceIndex = components.firstIndex(where: { $0 == "workspace" }),
           components.count > workspaceIndex + 2 {
            let relative = components[(workspaceIndex + 2)...].joined(separator: "/")
            if !relative.isEmpty {
                aliases.insert(relative)
            }
        }
        return aliases
    }

    private func normalizeFileChangePathKey(_ rawPath: String) -> String? {
        var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return nil }
        if normalized == "/dev/null" { return nil }

        normalized = normalized.replacingOccurrences(of: "`", with: "")
        normalized = normalized.replacingOccurrences(of: "\"", with: "")
        normalized = normalized.replacingOccurrences(of: "'", with: "")
        if normalized.hasPrefix("("), normalized.hasSuffix(")"), normalized.count > 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }

        if normalized.hasPrefix("a/") || normalized.hasPrefix("b/") {
            normalized = String(normalized.dropFirst(2))
        }
        if normalized.hasPrefix("./") {
            normalized = String(normalized.dropFirst(2))
        }
        if let range = normalized.range(
            of: #":\d+(?::\d+)?$"#,
            options: .regularExpression
        ) {
            normalized.removeSubrange(range)
        }

        while let last = normalized.last, ",.;".contains(last) {
            normalized.removeLast()
        }

        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return normalized.lowercased()
    }

    private func commandExecutionPreviewKey(from text: String) -> String? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2 else {
            return nil
        }
        let phase = tokens[0].lowercased()
        guard phase == "running"
            || phase == "completed"
            || phase == "failed"
            || phase == "stopped" else {
            return nil
        }
        let command = tokens.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return command.isEmpty ? nil : command
    }

    // Uses normalized visible lines so live/history tool rows can rebind without
    // relying on fragile placeholder text or raw item ids.
    private func toolActivityPreviewKey(from text: String) -> String? {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty
                    && !isStreamingPlaceholder($0, for: .toolActivity)
            }
            .map { $0.lowercased() }

        guard !lines.isEmpty else {
            return nil
        }

        return lines.joined(separator: "\n")
    }

    // A stable reasoning id that misses exact lookup may only adopt one clearly
    // provisional row. Two stable sections, or multiple provisional candidates,
    // are distinct/ambiguous and must not overwrite one another.
    private func uniqueProvisionalThinkingRowID(
        threadId: String,
        turnId: String
    ) -> String? {
        let candidates = (messagesByThread[threadId] ?? []).filter { message in
            message.role == .system
                && message.kind == .thinking
                && message.turnId == turnId
                && Self.isProvisionalThinkingIdentifier(message.itemId)
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }
        return candidate.id
    }

    // A turn-scoped synthetic alias can bridge a provisional reasoning row to a
    // real id, but it must never redirect one stable reasoning section into a
    // different stable item. Command rows use their stricter semantic fallback.
    private func canReuseSyntheticSystemItemAlias(
        threadId: String,
        messageId: String,
        incomingItemId: String,
        kind: CodexMessageKind
    ) -> Bool {
        guard kind == .thinking else {
            return true
        }
        guard let index = findMessageIndex(threadId: threadId, messageId: messageId),
              let candidate = messagesByThread[threadId]?[index],
              candidate.role == .system,
              candidate.kind == .thinking || candidate.kind == .chat else {
            return false
        }

        let candidateItemId = normalizedStreamingItemID(candidate.itemId)
        let incomingItemId = normalizedStreamingItemID(incomingItemId)
        if let candidateItemId, let incomingItemId, candidateItemId == incomingItemId {
            return true
        }
        guard Self.isProvisionalThinkingIdentifier(candidateItemId) else {
            return false
        }
        let provisionalCandidates = (messagesByThread[threadId] ?? []).filter { message in
            message.role == .system
                && message.kind == .thinking
                && message.turnId == candidate.turnId
                && Self.isProvisionalThinkingIdentifier(message.itemId)
        }
        return provisionalCandidates.count == 1 && provisionalCandidates[0].id == candidate.id
    }

    // Allows text-based reuse only for provisional rows; stable item ids must stay distinct.
    private func canReuseLiveToolActivityRow(_ candidate: CodexMessage, incomingItemId: String) -> Bool {
        let candidateItemId = normalizedStreamingItemID(candidate.itemId)
        let incomingItemId = normalizedStreamingItemID(incomingItemId)

        if let candidateItemId, let incomingItemId, candidateItemId == incomingItemId {
            return true
        }

        return !Self.hasStableToolActivityIdentity(candidateItemId)
    }

    private func isFileChangeSnapshotPayload(_ text: String) -> Bool {
        guard text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("status:") {
            return true
        }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hasPath = false
        var hasKind = false
        var hasTotals = false
        var hasDiffFence = false
        var hasDiffHeader = false

        for line in lines {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = candidate.lowercased()
            if lower.hasPrefix("path:") { hasPath = true }
            if lower.hasPrefix("kind:") { hasKind = true }
            if lower.hasPrefix("totals:") { hasTotals = true }
            if candidate.hasPrefix("```diff") || candidate == "```" { hasDiffFence = true }
            if candidate.hasPrefix("diff --git ")
                || candidate.hasPrefix("+++ ")
                || candidate.hasPrefix("--- ")
                || candidate.hasPrefix("@@ ") {
                hasDiffHeader = true
            }
        }

        if hasPath && hasKind {
            return true
        }
        if hasPath && (hasTotals || hasDiffFence || hasDiffHeader) {
            return true
        }
        if hasDiffFence && hasDiffHeader {
            return true
        }

        return false
    }

    // Coalesces generic tool activity lines so the timeline keeps one stable row per tool item.
    func mergeToolActivityText(existing: String, incoming: String, isStreaming: Bool) -> String {
        let existingTrimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTrimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        if incomingTrimmed.isEmpty {
            return existingTrimmed
        }
        if existingTrimmed.isEmpty || isStreamingPlaceholder(existingTrimmed, for: .toolActivity) {
            return incomingTrimmed
        }
        if isStreamingPlaceholder(incomingTrimmed, for: .toolActivity) {
            return existingTrimmed
        }

        let incomingLines = incomingTrimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !incomingLines.isEmpty else {
            return existingTrimmed
        }

        var mergedLines = existingTrimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in incomingLines where !mergedLines.contains(where: {
            $0.caseInsensitiveCompare(line) == .orderedSame
        }) {
            if !isStreaming,
               let existingIndex = mergedLines.firstIndex(where: { candidate in
                   let existingTokens = candidate.split(whereSeparator: \.isWhitespace)
                   let incomingTokens = line.split(whereSeparator: \.isWhitespace)
                   guard existingTokens.count >= 2, incomingTokens.count >= 2 else {
                       return false
                   }
                   return existingTokens.dropFirst().joined(separator: " ")
                       .caseInsensitiveCompare(incomingTokens.dropFirst().joined(separator: " ")) == .orderedSame
               }) {
                mergedLines[existingIndex] = line
            } else {
                mergedLines.append(line)
            }
        }

        return mergedLines.isEmpty ? incomingTrimmed : mergedLines.joined(separator: "\n")
    }

    private func uniqueFileChangeMessageIDForTurn(
        threadId: String,
        turnId: String,
        allowsTurnlessFallback: Bool = false
    ) -> String? {
        let candidates = (messagesByThread[threadId] ?? []).filter { candidate in
            candidate.role == .system
                && candidate.kind == .fileChange
                && (
                    candidate.turnId == turnId
                        || (allowsTurnlessFallback
                            && candidate.turnId == nil
                            && turnlessFileChangeRowBelongsToTurn(candidate, threadId: threadId, turnId: turnId))
                )
        }
        guard candidates.count == 1 else {
            return nil
        }
        return candidates[0].id
    }

    // A turnless file-change row is claimable inside one contiguous turn block.
    // Before the opening turn row lands, only a single bootstrap row may bind.
    // The shared rule lives in turnlessFileChangeRowIsClaimable (History).
    private func turnlessFileChangeRowBelongsToTurn(
        _ candidate: CodexMessage,
        threadId: String,
        turnId: String
    ) -> Bool {
        guard let messages = messagesByThread[threadId],
              let candidateIndex = messages.firstIndex(where: { $0.id == candidate.id }) else {
            return false
        }
        return Self.turnlessFileChangeRowIsClaimable(
            in: messages,
            candidateIndex: candidateIndex,
            turnId: turnId,
            turnBlockRange: Self.contiguousTurnBlockRange(in: messages, turnId: turnId)
        )
    }

    private func pruneDuplicateSystemRows(
        in threadMessages: inout [CodexMessage],
        keepIndex: Int,
        kind: CodexMessageKind,
        turnId: String,
        fileChangePathKeys: Set<String> = Set<String>(),
        isAuthoritativeFileChangeSnapshot: Bool = false,
        commandKey: String? = nil,
        toolActivityKey: String? = nil
    ) {
        guard threadMessages.indices.contains(keepIndex) else { return }
        let keepID = threadMessages[keepIndex].id
        let keepText = Self.normalizedMessageText(threadMessages[keepIndex].text)
        // Turnless rows outside this turn block belong to adjacent turns; an
        // authoritative snapshot must not delete those repeated path tables.
        let turnBlockRange = Self.contiguousTurnBlockRange(in: threadMessages, turnId: turnId)
        let prunableTurnlessIDs = Set(threadMessages.indices.compactMap { index -> String? in
            guard let turnBlockRange,
                  turnBlockRange.contains(index),
                  threadMessages[index].turnId == nil else {
                return nil
            }
            return threadMessages[index].id
        })

        threadMessages.removeAll { candidate in
            guard candidate.id != keepID,
                  candidate.role == .system,
                  candidate.kind == kind else {
                return false
            }

            if kind == .fileChange {
                let sameTurn = candidate.turnId == turnId
                let canPruneTurnlessFallback = isAuthoritativeFileChangeSnapshot
                    && candidate.turnId == nil
                    && prunableTurnlessIDs.contains(candidate.id)
                guard sameTurn || canPruneTurnlessFallback else {
                    return false
                }

                if !fileChangePathKeys.isEmpty {
                    let candidateKeys = normalizedFileChangePathKeys(from: candidate.text)
                    if isAuthoritativeFileChangeSnapshot {
                        return candidateKeys.isSubset(of: fileChangePathKeys)
                    }
                    return !candidateKeys.isDisjoint(with: fileChangePathKeys)
                }
                guard candidate.text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit,
                      keepText.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
                    return false
                }
                return Self.normalizedMessageText(candidate.text) == keepText
            }

            guard candidate.turnId == turnId else {
                return false
            }

            if kind == .commandExecution, let commandKey {
                return commandExecutionPreviewKey(from: candidate.text) == commandKey
            }

            if kind == .toolActivity, let toolActivityKey {
                return toolActivityPreviewKey(from: candidate.text) == toolActivityKey
            }

            return false
        }
    }

    // Appends deltas to an existing system item message.
    func appendStreamingSystemItemDelta(
        threadId: String,
        turnId: String?,
        itemId: String,
        kind: CodexMessageKind,
        delta: String
    ) {
        // Preserve token-leading spaces from server deltas (for example Markdown words split by stream).
        guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        enqueueStreamingSystemItemDelta(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            kind: kind,
            delta: delta
        )
    }

    // Buffers reasoning/system deltas so thinking rows do not force one UI refresh per token.
    private func enqueueStreamingSystemItemDelta(
        threadId: String,
        turnId: String?,
        itemId: String,
        kind: CodexMessageKind,
        delta: String
    ) {
        let key = streamingItemMessageKey(threadId: threadId, itemId: itemId)
        let shouldFlushInitialDeltaQuickly = streamingSystemMessageByItemID[key] == nil
        let isReplay = isApplyingReplayedBridgeEvent
        if pendingSystemDeltasByKey[key] == nil {
            pendingSystemDeltasByKey[key] = PendingSystemStreamingDeltas(
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                kind: kind,
                isReplay: isReplay,
                deltas: []
            )
        } else {
            let existingIsReplay = pendingSystemDeltasByKey[key]?.isReplay ?? true
            pendingSystemDeltasByKey[key]?.isReplay = existingIsReplay && isReplay
        }
        pendingSystemDeltasByKey[key]?.deltas.append(delta)

        guard systemDeltaFlushTasksByKey[key] == nil else { return }
        let flushDelay = shouldFlushInitialDeltaQuickly
            ? StreamingDeltaCoalescingPolicy.initialFlushDelayNanoseconds
            : StreamingDeltaCoalescingPolicy.flushDelayNanoseconds
        systemDeltaFlushTasksByKey[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: flushDelay)
            guard !Task.isCancelled else { return }
            await Self.deferFlushWhileInteractionIsActive()
            guard !Task.isCancelled else { return }
            self?.flushPendingSystemDeltas(forKey: key)
        }
    }

    private func applyStreamingSystemDeltas(_ pending: PendingSystemStreamingDeltas) {
        let previousReplayScope = isApplyingReplayedBridgeEvent
        isApplyingReplayedBridgeEvent = pending.isReplay
        defer { isApplyingReplayedBridgeEvent = previousReplayScope }

        upsertStreamingSystemItemMessage(
            threadId: pending.threadId,
            turnId: pending.turnId,
            itemId: pending.itemId,
            kind: pending.kind,
            text: pending.deltas.joined(),
            isStreaming: !pending.isReplay
        )
    }

    func flushPendingSystemDeltas(threadId: String, itemId: String) {
        flushPendingSystemDeltas(forKey: streamingItemMessageKey(threadId: threadId, itemId: itemId))
    }

    func flushPendingSystemDeltasForTurn(threadId: String, turnId: String?) {
        let keys = pendingSystemDeltasByKey
            .filter { _, pending in
                guard pending.threadId == threadId else { return false }
                guard let turnId else { return true }
                return pending.turnId == turnId
            }
            .map(\.key)
        for key in keys {
            flushPendingSystemDeltas(forKey: key)
        }
    }

    private func flushPendingSystemDeltas(forKey key: String) {
        systemDeltaFlushTasksByKey[key]?.cancel()
        systemDeltaFlushTasksByKey.removeValue(forKey: key)
        guard let pending = pendingSystemDeltasByKey.removeValue(forKey: key) else {
            return
        }
        applyStreamingSystemDeltas(pending)
    }

    func flushAllPendingStreamingDeltas() {
        flushPendingAssistantDeltas()
        for key in Array(pendingSystemDeltasByKey.keys) {
            flushPendingSystemDeltas(forKey: key)
        }
    }

    func cancelPendingStreamingDeltaFlushes(for threadId: String) {
        let assistantStreamIDs = pendingAssistantDeltaContextByStreamID
            .filter { $0.value.threadId == threadId }
            .map(\.key)
        for streamID in assistantStreamIDs {
            pendingAssistantDeltaByStreamID.removeValue(forKey: streamID)
            pendingAssistantDeltaContextByStreamID.removeValue(forKey: streamID)
            pendingAssistantDeltaStreamOrder.removeAll { $0 == streamID }
        }
        if pendingAssistantDeltaByStreamID.isEmpty {
            pendingAssistantDeltaFlushTask?.cancel()
            pendingAssistantDeltaFlushTask = nil
        }

        let systemKeys = pendingSystemDeltasByKey
            .filter { $0.value.threadId == threadId }
            .map(\.key)
        for key in systemKeys {
            systemDeltaFlushTasksByKey[key]?.cancel()
            systemDeltaFlushTasksByKey.removeValue(forKey: key)
            pendingSystemDeltasByKey.removeValue(forKey: key)
        }
    }

    func cancelAllPendingStreamingDeltaFlushes() {
        pendingAssistantDeltaFlushTask?.cancel()
        pendingAssistantDeltaFlushTask = nil
        pendingAssistantDeltaByStreamID.removeAll()
        pendingAssistantDeltaContextByStreamID.removeAll()
        pendingAssistantDeltaStreamOrder.removeAll()
        systemDeltaFlushTasksByKey.values.forEach { $0.cancel() }
        systemDeltaFlushTasksByKey.removeAll()
        pendingSystemDeltasByKey.removeAll()
    }

    // Merges a late reasoning delta into an existing thinking row without reopening streaming state.
    // Returns true when a matching row was found and updated.
    func mergeLateReasoningDeltaIfPossible(
        threadId: String,
        turnId: String?,
        itemId: String?,
        delta: String
    ) -> Bool {
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDelta.isEmpty,
              var threadMessages = messagesByThread[threadId] else {
            return false
        }

        let normalizedTurnId = turnId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedItemId = itemId?.trimmingCharacters(in: .whitespacesAndNewlines)

        let targetIndex: Int? = {
            if let normalizedItemId, !normalizedItemId.isEmpty {
                if let index = threadMessages.indices.reversed().first(where: { index in
                    let candidate = threadMessages[index]
                    return candidate.role == .system
                        && candidate.kind == .thinking
                        && candidate.itemId == normalizedItemId
                }) {
                    return index
                }
            }

            if let normalizedTurnId, !normalizedTurnId.isEmpty {
                let provisionalMatches = threadMessages.indices.filter { index in
                    let candidate = threadMessages[index]
                    return candidate.role == .system
                        && candidate.kind == .thinking
                        && candidate.turnId == normalizedTurnId
                        && Self.isProvisionalThinkingIdentifier(candidate.itemId)
                }
                if provisionalMatches.count == 1 {
                    return provisionalMatches[0]
                }
            }

            return nil
        }()

        guard let targetIndex else {
            return false
        }

        let existingText = threadMessages[targetIndex].text
        threadMessages[targetIndex].text = mergeAssistantDelta(
            existingText: existingText,
            incomingDelta: delta
        )
        threadMessages[targetIndex].isStreaming = false
        if threadMessages[targetIndex].turnId == nil,
           let normalizedTurnId, !normalizedTurnId.isEmpty {
            threadMessages[targetIndex].turnId = normalizedTurnId
        }
        if let normalizedItemId, !normalizedItemId.isEmpty,
           Self.isProvisionalThinkingIdentifier(threadMessages[targetIndex].itemId) {
            threadMessages[targetIndex].itemId = normalizedItemId
        }

        messagesByThread[threadId] = threadMessages
        persistMessages()
        updateCurrentOutput(for: threadId)
        return true
    }

    // Uses a stable synthetic item id when server deltas miss itemId.
    func appendStreamingSystemTurnDelta(
        threadId: String,
        turnId: String,
        kind: CodexMessageKind,
        delta: String
    ) {
        appendStreamingSystemItemDelta(
            threadId: threadId,
            turnId: turnId,
            itemId: syntheticStreamingItemId(turnId: turnId, kind: kind),
            kind: kind,
            delta: delta
        )
    }

    // Upserts synthetic turn-based stream entries when no itemId exists.
    func upsertStreamingSystemTurnMessage(
        threadId: String,
        turnId: String,
        kind: CodexMessageKind,
        text: String,
        isStreaming: Bool
    ) {
        upsertStreamingSystemItemMessage(
            threadId: threadId,
            turnId: turnId,
            itemId: syntheticStreamingItemId(turnId: turnId, kind: kind),
            kind: kind,
            text: text,
            isStreaming: isStreaming
        )
    }

    // Finalizes a system item message when the item completes.
    func completeStreamingSystemItemMessage(
        threadId: String,
        turnId: String?,
        itemId: String,
        kind: CodexMessageKind,
        text: String?
    ) {
        flushPendingSystemDeltas(threadId: threadId, itemId: itemId)
        let key = streamingItemMessageKey(threadId: threadId, itemId: itemId)
        let completedMessageID = streamingSystemMessageByItemID[key]
        upsertStreamingSystemItemMessage(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            kind: kind,
            text: text ?? "",
            isStreaming: false
        )

        if let messageID = completedMessageID ?? streamingSystemMessageByItemID[key],
           let index = findMessageIndex(threadId: threadId, messageId: messageID) {
            messagesByThread[threadId]?[index].isStreaming = false
            messagesByThread[threadId]?[index].kind = kind

            if kind == .toolActivity,
               let finalText = messagesByThread[threadId]?[index].text,
               isStreamingPlaceholder(finalText, for: .toolActivity) {
                messagesByThread[threadId]?.removeAll { $0.id == messageID }
                updateCurrentOutput(for: threadId)
            }

            persistMessages()
        }

        if let completedMessageID = completedMessageID ?? streamingSystemMessageByItemID[key] {
            streamingSystemMessageByItemID = streamingSystemMessageByItemID.filter { _, value in
                value != completedMessageID
            }
        } else {
            streamingSystemMessageByItemID.removeValue(forKey: key)
        }
    }

    // Completes synthetic turn-based stream entries when no itemId exists.
    func completeStreamingSystemTurnMessage(
        threadId: String,
        turnId: String,
        kind: CodexMessageKind,
        text: String?
    ) {
        completeStreamingSystemItemMessage(
            threadId: threadId,
            turnId: turnId,
            itemId: syntheticStreamingItemId(turnId: turnId, kind: kind),
            kind: kind,
            text: text
        )
    }

    // Creates a streaming assistant placeholder for a turn/item if missing.
    func beginAssistantMessage(
        threadId: String,
        turnId: String,
        itemId: String? = nil,
        assistantPhase: String? = nil
    ) {
        let turnStreamingKey = streamingMessageKey(threadId: threadId, turnId: turnId)
        let normalizedItemId = normalizedStreamingItemID(itemId)
        let normalizedPhase = normalizedAssistantPhase(assistantPhase)
        let itemStreamingKey = normalizedItemId.map {
            assistantStreamingMessageKey(threadId: threadId, turnId: turnId, itemId: $0)
        }

        if let itemStreamingKey,
           let messageID = streamingAssistantMessageByItemKey[itemStreamingKey],
           let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) {
            // Item-scoped late events must not steal the turn fallback pointer from
            // a newer assistant item that is still receiving turn-scoped deltas.
            applyAssistantPhaseIfNeeded(
                threadId: threadId,
                messageIndex: messageIndex,
                assistantPhase: normalizedPhase
            )
            return
        }

        if let messageID = streamingAssistantFallbackMessageByTurnID[turnStreamingKey],
           let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) {
            if let normalizedItemId {
                let existingItemId = normalizedStreamingItemID(messagesByThread[threadId]?[messageIndex].itemId)
                if existingItemId == nil {
                    messagesByThread[threadId]?[messageIndex].itemId = normalizedItemId
                    applyAssistantPhaseIfNeeded(
                        threadId: threadId,
                        messageIndex: messageIndex,
                        assistantPhase: normalizedPhase
                    )
                    if let itemStreamingKey {
                        streamingAssistantMessageByItemKey[itemStreamingKey] = messageID
                    }
                    persistMessages()
                    updateCurrentOutput(for: threadId)
                    return
                }
                if existingItemId == normalizedItemId {
                    applyAssistantPhaseIfNeeded(
                        threadId: threadId,
                        messageIndex: messageIndex,
                        assistantPhase: normalizedPhase
                    )
                    if let itemStreamingKey {
                        streamingAssistantMessageByItemKey[itemStreamingKey] = messageID
                    }
                    return
                }

                // New assistant item started inside the same turn: preserve the previous bubble.
                messagesByThread[threadId]?[messageIndex].isStreaming = false
                streamingAssistantFallbackMessageByTurnID.removeValue(forKey: turnStreamingKey)
                persistMessages()
                updateCurrentOutput(for: threadId)
            } else {
                return
            }
        } else {
            streamingAssistantFallbackMessageByTurnID.removeValue(forKey: turnStreamingKey)
        }

        _ = createAssistantMessage(
            threadId: threadId,
            turnId: turnId,
            itemId: normalizedItemId,
            assistantPhase: normalizedPhase,
            isStreaming: true,
            promoteTurnFallback: true
        )
    }

    // Streams assistant delta chunks into the message linked to a turn.
    func appendAssistantDelta(
        threadId: String,
        turnId: String,
        itemId: String?,
        assistantPhase: String? = nil,
        delta: String,
        isReplay: Bool = false
    ) {
        guard !delta.isEmpty else {
            return
        }

        enqueueAssistantDelta(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            assistantPhase: assistantPhase,
            delta: delta,
            isReplay: isReplay
        )
    }

    // Applies one already-coalesced assistant delta batch to the active timeline.
    private func applyAssistantDeltaBatch(
        threadId: String,
        turnId: String,
        itemId: String?,
        assistantPhase: String?,
        delta: String,
        isReplay: Bool = false
    ) {
        guard !delta.isEmpty else {
            return
        }

        // Replayed batches append catch-up text as closed history, not live output.
        let previousReplayScope = isApplyingReplayedBridgeEvent
        isApplyingReplayedBridgeEvent = isReplay
        defer { isApplyingReplayedBridgeEvent = previousReplayScope }

        if applyLateTerminalAssistantDelta(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            assistantPhase: assistantPhase,
            delta: delta
        ) {
            return
        }

        let messageID = ensureStreamingAssistantMessage(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            assistantPhase: assistantPhase,
            createStreamingMessage: !isReplay
        )
        guard let messageID,
              let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) else {
            return
        }

        let currentText = messagesByThread[threadId]?[messageIndex].text ?? ""
        let nextText = mergeAssistantDelta(
            existingText: currentText,
            incomingDelta: delta
        )
        let didResolveItemId = messagesByThread[threadId]?[messageIndex].itemId == nil && itemId != nil

        guard nextText != currentText
                || !(messagesByThread[threadId]?[messageIndex].isStreaming ?? false)
                || didResolveItemId else {
            return
        }

        messagesByThread[threadId]?[messageIndex].text = nextText
        messagesByThread[threadId]?[messageIndex].isStreaming = !isReplay
        applyAssistantPhaseIfNeeded(
            threadId: threadId,
            messageIndex: messageIndex,
            assistantPhase: assistantPhase
        )
        if messagesByThread[threadId]?[messageIndex].itemId == nil, let itemId {
            messagesByThread[threadId]?[messageIndex].itemId = itemId
        }
        refreshDerivedPlanMetadata(threadId: threadId, messageIndex: messageIndex)

        persistMessages()
        updateStreamingAssistantOutput(for: threadId, messageId: messageID, rawMessageIndex: messageIndex)
    }

    // Late replay deltas for a closed turn should patch the closed assistant row, not reopen streaming.
    private func applyLateTerminalAssistantDelta(
        threadId: String,
        turnId: String,
        itemId: String?,
        assistantPhase: String?,
        delta: String
    ) -> Bool {
        let normalizedTurnId = turnId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTurnId.isEmpty,
              turnTerminalState(for: normalizedTurnId, threadId: threadId) != nil,
              activeTurnIdByThread[threadId] != normalizedTurnId,
              var threadMessages = messagesByThread[threadId] else {
            return false
        }

        let normalizedItemId = normalizedStreamingItemID(itemId)
        let targetIndex: Int? = {
            if let normalizedItemId {
                return threadMessages.indices.reversed().first { index in
                    let candidate = threadMessages[index]
                    return candidate.role == .assistant
                        && candidate.turnId == normalizedTurnId
                        && (candidate.itemId == normalizedItemId || candidate.itemId == nil)
                }
            }

            return threadMessages.indices.reversed().first { index in
                let candidate = threadMessages[index]
                return candidate.role == .assistant
                    && candidate.turnId == normalizedTurnId
                    && !candidate.isStreaming
            }
        }()

        guard let targetIndex else {
            // Closed turns must not be reopened by late status/progress replay chunks.
            return true
        }

        let currentText = threadMessages[targetIndex].text
        let nextText = mergeAssistantDelta(existingText: currentText, incomingDelta: delta)
        let didResolveItemId = threadMessages[targetIndex].itemId == nil && normalizedItemId != nil

        guard nextText != currentText || threadMessages[targetIndex].isStreaming || didResolveItemId else {
            return true
        }

        threadMessages[targetIndex].text = nextText
        threadMessages[targetIndex].isStreaming = false
        if threadMessages[targetIndex].assistantPhase == nil, let assistantPhase {
            threadMessages[targetIndex].assistantPhase = normalizedAssistantPhase(assistantPhase)
        }
        if didResolveItemId {
            threadMessages[targetIndex].itemId = normalizedItemId
        }
        messagesByThread[threadId] = threadMessages
        refreshDerivedPlanMetadata(threadId: threadId, messageIndex: targetIndex)
        persistMessages()
        updateCurrentOutput(for: threadId)
        return true
    }

    // Finalizes assistant text when item/completed carries the canonical message body.
    func completeAssistantMessage(
        threadId: String,
        turnId: String?,
        itemId: String?,
        sourceItemKey: String? = nil,
        assistantPhase: String? = nil,
        text: String
    ) {
        let trimmedText = Self.normalizedMessageText(text)
        guard Self.hasMeaningfulHistoryText(trimmedText) else {
            return
        }

        let now = Date()
        let normalizedPhase = normalizedAssistantPhase(assistantPhase)
        var resolvedAssistantMessageId: String?
        let explicitTurnId = normalizedStreamingItemID(turnId)
        let explicitItemId = normalizedStreamingItemID(itemId)
        let normalizedSourceItemKey = normalizedStreamingItemID(sourceItemKey)
        let activeTurnIdForThread = activeTurnIdByThread[threadId]
        let hasExplicitIdentity = explicitTurnId != nil || explicitItemId != nil

        if explicitTurnId == nil,
           explicitItemId == nil,
           shouldIgnoreIdentifierlessAssistantCompletion(
               threadId: threadId,
               text: trimmedText,
               activeTurnId: activeTurnIdForThread,
               now: now
           ) {
            return
        }

        if !hasExplicitIdentity,
           activeTurnIdForThread != nil || threadHasActiveOrRunningTurn(threadId) {
            // t3code never assigns turn-less completions to the newest active turn.
            // Late legacy payloads are ambiguous, so do not let them overwrite the current answer.
            assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)
            return
        }

        let resolvedTurnId = explicitTurnId
            ?? explicitItemId.flatMap { knownAssistantTurnId(threadId: threadId, itemId: $0) }
            ?? (explicitItemId == nil ? nil : activeTurnIdForThread)
        if let resolvedTurnId {
            threadIdByTurnID[resolvedTurnId] = threadId
        }
        flushPendingAssistantDeltas(for: threadId, turnId: resolvedTurnId, itemId: explicitItemId)

        // The bridge can replay one assistant item as a JSONL/rollout row and later as an
        // item with Codex's provider id. The alias is generated per turn, so it is safe to use
        // as an exact source identity here and avoids text-only reconciliation across handoffs.
        if let normalizedSourceItemKey,
           let resolvedTurnId {
            let eligibleAliasIndices = (messagesByThread[threadId] ?? []).indices.filter { index in
                let candidate = messagesByThread[threadId]![index]
                return candidate.role == .assistant
                    && candidate.turnId == resolvedTurnId
                    && candidate.sourceItemKey == normalizedSourceItemKey
                    && Self.sourceItemIdentityAllowsReconcile(candidate.itemId, explicitItemId)
            }
            if eligibleAliasIndices.count == 1, let aliasMatchIndex = eligibleAliasIndices.first {
                let existingAliasText = messagesByThread[threadId]?[aliasMatchIndex].text ?? ""
                // Buffered/rollout replay is older than a still-streaming local row. Do not let a
                // shorter stale copy replace live text or close its stream just because its source
                // alias matches.
                if isApplyingReplayedBridgeEvent,
                   messagesByThread[threadId]?[aliasMatchIndex].isStreaming == true,
                   existingAliasText.utf8.count > trimmedText.utf8.count {
                    return
                }
                messagesByThread[threadId]?[aliasMatchIndex].text = Self.assistantCompletionTextPreservingImages(
                    existingText: existingAliasText,
                    canonicalText: trimmedText
                )
                messagesByThread[threadId]?[aliasMatchIndex].isStreaming = false
                applyAssistantPhaseIfNeeded(
                    threadId: threadId,
                    messageIndex: aliasMatchIndex,
                    assistantPhase: normalizedPhase
                )
                if let explicitItemId,
                   (messagesByThread[threadId]?[aliasMatchIndex].itemId == nil
                       || messagesByThread[threadId]?[aliasMatchIndex].itemId.map(CodexSyntheticIdentifiers.isMirrorMintedItemID) == true) {
                    promoteAssistantItemIdentity(
                        threadId: threadId,
                        turnId: resolvedTurnId,
                        messageIndex: aliasMatchIndex,
                        providerItemId: explicitItemId
                    )
                }
                refreshDerivedPlanMetadata(threadId: threadId, messageIndex: aliasMatchIndex)
                resolvedAssistantMessageId = messagesByThread[threadId]?[aliasMatchIndex].id
                assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)
                if let resolvedAssistantMessageId {
                    persistMessages()
                    noteAssistantMessage(
                        threadId: threadId,
                        turnId: resolvedTurnId,
                        assistantMessageId: resolvedAssistantMessageId
                    )
                    updateCurrentOutput(for: threadId)
                }
                return
            }
        }

        if resolvedTurnId == nil, explicitItemId == nil,
           let fingerprint = assistantCompletionFingerprintByThread[threadId],
           fingerprint.text == trimmedText,
           now.timeIntervalSince(fingerprint.timestamp) <= 45 {
            return
        }

        if let replayTerminalMessageId = absorbAssistantBlockReplayCompletion(
            threadId: threadId,
            turnId: resolvedTurnId,
            itemId: explicitItemId,
            text: trimmedText
        ) {
            applyAssistantPhaseIfNeeded(
                threadId: threadId,
                messageId: replayTerminalMessageId,
                assistantPhase: normalizedPhase
            )
            if let replayTerminalMessageIndex = findMessageIndex(
                threadId: threadId,
                messageId: replayTerminalMessageId
            ) {
                applyAssistantSourceItemKeyIfNeeded(
                    threadId: threadId,
                    messageIndex: replayTerminalMessageIndex,
                    sourceItemKey: normalizedSourceItemKey
                )
            }
            assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)
            _ = mergeGeneratedImageArtifactsIntoAssistantMessage(
                threadId: threadId,
                turnId: resolvedTurnId,
                assistantMessageId: replayTerminalMessageId
            )
            persistMessages()
            if let resolvedTurnId {
                noteAssistantMessage(
                    threadId: threadId,
                    turnId: resolvedTurnId,
                    assistantMessageId: replayTerminalMessageId
                )
            }
            updateCurrentOutput(for: threadId)
            return
        }

        if let resolvedTurnId,
           let imagePreviewIndex = imagePreviewAssistantCompletionIndex(
               threadId: threadId,
               turnId: resolvedTurnId,
               itemId: explicitItemId,
               text: trimmedText
           ) {
            let existingText = messagesByThread[threadId]?[imagePreviewIndex].text ?? ""
            messagesByThread[threadId]?[imagePreviewIndex].text = Self.assistantCompletionTextPreservingImages(
                existingText: existingText,
                canonicalText: trimmedText
            )
            messagesByThread[threadId]?[imagePreviewIndex].isStreaming = false
            applyAssistantPhaseIfNeeded(
                threadId: threadId,
                messageIndex: imagePreviewIndex,
                assistantPhase: normalizedPhase
            )
            if messagesByThread[threadId]?[imagePreviewIndex].itemId == nil, let explicitItemId {
                messagesByThread[threadId]?[imagePreviewIndex].itemId = explicitItemId
            }
            applyAssistantSourceItemKeyIfNeeded(
                threadId: threadId,
                messageIndex: imagePreviewIndex,
                sourceItemKey: normalizedSourceItemKey
            )
            refreshDerivedPlanMetadata(threadId: threadId, messageIndex: imagePreviewIndex)
            let messageId = messagesByThread[threadId]?[imagePreviewIndex].id
            assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)
            if let messageId {
                _ = mergeGeneratedImageArtifactsIntoAssistantMessage(
                    threadId: threadId,
                    turnId: resolvedTurnId,
                    assistantMessageId: messageId
                )
                persistMessages()
                noteAssistantMessage(
                    threadId: threadId,
                    turnId: resolvedTurnId,
                    assistantMessageId: messageId
                )
                updateCurrentOutput(for: threadId)
            }
            return
        }

        if let resolvedTurnId,
           explicitItemId == nil,
           let duplicateIndex = completedAssistantMessageIndices(
               threadId: threadId,
               turnId: resolvedTurnId
           ).last(where: { index in
               Self.normalizedMessageText(messagesByThread[threadId]?[index].text ?? "") == trimmedText
           }) {
            messagesByThread[threadId]?[duplicateIndex].isStreaming = false
            applyAssistantPhaseIfNeeded(
                threadId: threadId,
                messageIndex: duplicateIndex,
                assistantPhase: normalizedPhase
            )
            applyAssistantSourceItemKeyIfNeeded(
                threadId: threadId,
                messageIndex: duplicateIndex,
                sourceItemKey: normalizedSourceItemKey
            )
            refreshDerivedPlanMetadata(threadId: threadId, messageIndex: duplicateIndex)
            assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)
            if let resolvedAssistantMessageId = messagesByThread[threadId]?[duplicateIndex].id {
                _ = mergeGeneratedImageArtifactsIntoAssistantMessage(
                    threadId: threadId,
                    turnId: resolvedTurnId,
                    assistantMessageId: resolvedAssistantMessageId
                )
                persistMessages()
                noteAssistantMessage(
                    threadId: threadId,
                    turnId: resolvedTurnId,
                    assistantMessageId: resolvedAssistantMessageId
                )
                updateCurrentOutput(for: threadId)
            }
            return
        }

        if let resolvedTurnId,
           explicitItemId == nil,
           !threadHasActiveOrRunningTurn(threadId) {
            let completedAssistantIndices = completedAssistantMessageIndices(
                threadId: threadId,
                turnId: resolvedTurnId
            )

            if completedAssistantIndices.count == 1,
               let targetIndex = completedAssistantIndices.first {
                let currentAssistant = messagesByThread[threadId]?[targetIndex]
                if let currentAssistant,
                   Self.shouldReplaceClosedAssistantMessage(
                        currentAssistant,
                        with: CodexMessage(
                            threadId: threadId,
                            role: .assistant,
                            text: trimmedText,
                            turnId: resolvedTurnId,
                            itemId: nil,
                            isStreaming: false,
                            deliveryState: .confirmed,
                            orderIndex: currentAssistant.orderIndex
                        )
                   ) {
                    messagesByThread[threadId]?[targetIndex].text = Self.assistantCompletionTextPreservingImages(
                        existingText: currentAssistant.text,
                        canonicalText: trimmedText
                    )
                    messagesByThread[threadId]?[targetIndex].isStreaming = false
                    applyAssistantPhaseIfNeeded(
                        threadId: threadId,
                        messageIndex: targetIndex,
                        assistantPhase: normalizedPhase
                    )
                    if messagesByThread[threadId]?[targetIndex].turnId == nil {
                        messagesByThread[threadId]?[targetIndex].turnId = resolvedTurnId
                    }
                    applyAssistantSourceItemKeyIfNeeded(
                        threadId: threadId,
                        messageIndex: targetIndex,
                        sourceItemKey: normalizedSourceItemKey
                    )
                    refreshDerivedPlanMetadata(threadId: threadId, messageIndex: targetIndex)
                    resolvedAssistantMessageId = messagesByThread[threadId]?[targetIndex].id
                }
                assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)
                if let resolvedAssistantMessageId {
                    _ = mergeGeneratedImageArtifactsIntoAssistantMessage(
                        threadId: threadId,
                        turnId: resolvedTurnId,
                        assistantMessageId: resolvedAssistantMessageId
                    )
                    persistMessages()
                    noteAssistantMessage(
                        threadId: threadId,
                        turnId: resolvedTurnId,
                        assistantMessageId: resolvedAssistantMessageId
                    )
                    updateCurrentOutput(for: threadId)
                }
                return
            }

            if !completedAssistantIndices.isEmpty {
                // Late legacy completions without item identity are ambiguous once a closed
                // turn already has assistant bubbles. Ignore them instead of appending a duplicate.
                assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)
                return
            }
        }

        if let resolvedTurnId,
           let messageID = ensureStreamingAssistantMessage(
               threadId: threadId,
               turnId: resolvedTurnId,
               itemId: explicitItemId,
               assistantPhase: normalizedPhase,
               promoteTurnFallback: explicitItemId == nil,
               createStreamingMessage: explicitItemId == nil
           ),
           let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) {
            let existingText = messagesByThread[threadId]?[messageIndex].text ?? ""
            let completedText = Self.assistantCompletionTextPreservingImages(
                existingText: existingText,
                canonicalText: trimmedText
            )

            if !Self.hasMeaningfulHistoryText(existingText) {
                messagesByThread[threadId]?[messageIndex].text = completedText
            } else if existingText != completedText {
                messagesByThread[threadId]?[messageIndex].text = completedText
            }

            messagesByThread[threadId]?[messageIndex].isStreaming = false
            applyAssistantPhaseIfNeeded(
                threadId: threadId,
                messageIndex: messageIndex,
                assistantPhase: normalizedPhase
            )
            if messagesByThread[threadId]?[messageIndex].itemId == nil, let explicitItemId {
                messagesByThread[threadId]?[messageIndex].itemId = explicitItemId
            }
            if messagesByThread[threadId]?[messageIndex].turnId == nil {
                messagesByThread[threadId]?[messageIndex].turnId = resolvedTurnId
            }
            applyAssistantSourceItemKeyIfNeeded(
                threadId: threadId,
                messageIndex: messageIndex,
                sourceItemKey: normalizedSourceItemKey
            )
            refreshDerivedPlanMetadata(threadId: threadId, messageIndex: messageIndex)
            resolvedAssistantMessageId = messagesByThread[threadId]?[messageIndex].id
        } else {
            if let explicitItemId,
               let existingItemIndex = messagesByThread[threadId]?.lastIndex(where: { candidate in
                   candidate.role == .assistant && candidate.itemId == explicitItemId
               }) {
                let existingText = messagesByThread[threadId]?[existingItemIndex].text ?? ""
                messagesByThread[threadId]?[existingItemIndex].text = Self.assistantCompletionTextPreservingImages(
                    existingText: existingText,
                    canonicalText: trimmedText
                )
                messagesByThread[threadId]?[existingItemIndex].isStreaming = false
                applyAssistantPhaseIfNeeded(
                    threadId: threadId,
                    messageIndex: existingItemIndex,
                    assistantPhase: normalizedPhase
                )
                if messagesByThread[threadId]?[existingItemIndex].turnId == nil {
                    messagesByThread[threadId]?[existingItemIndex].turnId = resolvedTurnId
                }
                applyAssistantSourceItemKeyIfNeeded(
                    threadId: threadId,
                    messageIndex: existingItemIndex,
                    sourceItemKey: normalizedSourceItemKey
                )
                refreshDerivedPlanMetadata(threadId: threadId, messageIndex: existingItemIndex)
                resolvedAssistantMessageId = messagesByThread[threadId]?[existingItemIndex].id
            } else if let duplicateIndex = messagesByThread[threadId]?.lastIndex(where: { candidate in
                candidate.role == .assistant
                    && Self.normalizedMessageText(candidate.text) == trimmedText
                    && (
                        candidate.isStreaming
                            || (resolvedTurnId != nil && candidate.turnId == resolvedTurnId)
                            || (explicitItemId != nil && candidate.itemId == explicitItemId)
                    )
            }) {
                // Drop duplicated completion payloads that carry the same final assistant text.
                messagesByThread[threadId]?[duplicateIndex].isStreaming = false
                applyAssistantPhaseIfNeeded(
                    threadId: threadId,
                    messageIndex: duplicateIndex,
                    assistantPhase: normalizedPhase
                )
                if messagesByThread[threadId]?[duplicateIndex].itemId == nil, let explicitItemId {
                    messagesByThread[threadId]?[duplicateIndex].itemId = explicitItemId
                }
                if messagesByThread[threadId]?[duplicateIndex].turnId == nil {
                    messagesByThread[threadId]?[duplicateIndex].turnId = resolvedTurnId
                }
                applyAssistantSourceItemKeyIfNeeded(
                    threadId: threadId,
                    messageIndex: duplicateIndex,
                    sourceItemKey: normalizedSourceItemKey
                )
                refreshDerivedPlanMetadata(threadId: threadId, messageIndex: duplicateIndex)
                resolvedAssistantMessageId = messagesByThread[threadId]?[duplicateIndex].id
            } else {
                let newMessage = CodexMessage(
                    id: Self.stableAssistantMessageID(threadId: threadId, turnId: resolvedTurnId, itemId: explicitItemId) ?? UUID().uuidString,
                    threadId: threadId,
                    role: .assistant,
                    assistantPhase: normalizedPhase,
                    text: trimmedText,
                    turnId: resolvedTurnId,
                    itemId: explicitItemId,
                    sourceItemKey: normalizedSourceItemKey,
                    isStreaming: false,
                    deliveryState: .confirmed
                )
                appendMessage(newMessage)
                resolvedAssistantMessageId = newMessage.id
            }
        }

        assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)

        if let resolvedAssistantMessageId {
            _ = mergeGeneratedImageArtifactsIntoAssistantMessage(
                threadId: threadId,
                turnId: resolvedTurnId,
                assistantMessageId: resolvedAssistantMessageId
            )
        }

        persistMessages()
        if let resolvedAssistantMessageId {
            noteAssistantMessage(
                threadId: threadId,
                turnId: resolvedTurnId,
                assistantMessageId: resolvedAssistantMessageId
            )
        }
        updateCurrentOutput(for: threadId)
    }

    // Keep the bridge alias once it has been proven for this row. It is intentionally
    // write-once: a different alias in the same turn is a distinct assistant item.
    func applyAssistantSourceItemKeyIfNeeded(
        threadId: String,
        messageIndex: Int,
        sourceItemKey: String?
    ) {
        guard let sourceItemKey,
              !sourceItemKey.isEmpty,
              messagesByThread[threadId]?[messageIndex].sourceItemKey == nil else {
            return
        }
        messagesByThread[threadId]?[messageIndex].sourceItemKey = sourceItemKey
    }

    // A canonical provider id replaces a synthetic mirror id. Move every live lookup and queued
    // delta to the new identity in the same mutation so a late chunk cannot revive a second row.
    func promoteAssistantItemIdentity(
        threadId: String,
        turnId: String,
        messageIndex: Int,
        providerItemId: String
    ) {
        guard let oldItemId = messagesByThread[threadId]?[messageIndex].itemId,
              oldItemId != providerItemId else {
            messagesByThread[threadId]?[messageIndex].itemId = providerItemId
            return
        }
        messagesByThread[threadId]?[messageIndex].itemId = providerItemId

        let oldLookupKey = assistantStreamingMessageKey(
            threadId: threadId,
            turnId: turnId,
            itemId: oldItemId
        )
        let newLookupKey = assistantStreamingMessageKey(
            threadId: threadId,
            turnId: turnId,
            itemId: providerItemId
        )
        if let messageID = streamingAssistantMessageByItemKey.removeValue(forKey: oldLookupKey) {
            streamingAssistantMessageByItemKey[newLookupKey] = messageID
        }

        migratePendingAssistantDelta(
            threadId: threadId,
            turnId: turnId,
            sourceItemId: oldItemId,
            destinationItemId: providerItemId
        )
    }

    // Renders image-generation artifacts as assistant image previews without embedding image bytes.
    func appendGeneratedImageReference(
        threadId: String,
        turnId: String?,
        itemId: String?,
        imagePath: String
    ) {
        let trimmedPath = imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return
        }

        let resolvedTurnId = normalizedStreamingItemID(turnId) ?? activeTurnIdByThread[threadId]
        let resolvedItemId = normalizedStreamingItemID(itemId)
        if let resolvedTurnId {
            threadIdByTurnID[resolvedTurnId] = threadId
        }

        let markdown = "![Generated image](\(Self.markdownImagePath(trimmedPath)))"
        if var threadMessages = messagesByThread[threadId],
           let mergeTarget = generatedImageMergeTarget(
               in: threadMessages,
               turnId: resolvedTurnId,
               itemId: resolvedItemId,
               imagePath: trimmedPath,
               markdown: markdown
            ) {
            let existingIndex = mergeTarget.index
            var existing = threadMessages[existingIndex]
            if existing.text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit,
               !existing.text.contains(trimmedPath),
               !existing.text.contains(markdown) {
                existing.text = !Self.hasMeaningfulHistoryText(existing.text)
                    ? markdown
                    : "\(existing.text)\n\n\(markdown)"
            }
            existing.isStreaming = false
            if existing.turnId == nil {
                existing.turnId = resolvedTurnId
            }
            if mergeTarget.canAdoptImageItemId, existing.itemId == nil {
                existing.itemId = resolvedItemId
            }
            threadMessages[existingIndex] = existing
            messagesByThread[threadId] = threadMessages
            refreshDerivedPlanMetadata(threadId: threadId, messageIndex: existingIndex)
        } else {
            let message = CodexMessage(
                id: Self.stableAssistantMessageID(threadId: threadId, turnId: resolvedTurnId, itemId: resolvedItemId)
                    ?? UUID().uuidString,
                threadId: threadId,
                role: .assistant,
                text: markdown,
                turnId: resolvedTurnId,
                itemId: resolvedItemId,
                isStreaming: false,
                deliveryState: .confirmed
            )
            appendMessage(message)
            return
        }

        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    private struct GeneratedImageMergeTarget {
        let index: Int
        let canAdoptImageItemId: Bool
    }

    private func generatedImageMergeTarget(
        in threadMessages: [CodexMessage],
        turnId: String?,
        itemId: String?,
        imagePath: String,
        markdown: String
    ) -> GeneratedImageMergeTarget? {
        if let sameItemIndex = threadMessages.indices.reversed().first(where: { index in
            let candidate = threadMessages[index]
            return candidate.role == .assistant && itemId != nil && candidate.itemId == itemId
        }) {
            return GeneratedImageMergeTarget(index: sameItemIndex, canAdoptImageItemId: true)
        }

        if let sameImageIndex = threadMessages.indices.reversed().first(where: { index in
            let candidate = threadMessages[index]
            return candidate.role == .assistant
                && candidate.text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit
                && (candidate.text.contains(imagePath) || candidate.text.contains(markdown))
        }) {
            return GeneratedImageMergeTarget(index: sameImageIndex, canAdoptImageItemId: false)
        }

        // Late image-generation events can arrive after the final prose item, so attach them
        // to the visible assistant answer without stealing that row's item-scoped identity.
        guard let turnId else {
            return nil
        }
        guard let fallbackIndex = threadMessages.indices.reversed().first(where: { index in
            let candidate = threadMessages[index]
            return candidate.role == .assistant
                && candidate.kind == .chat
                && candidate.turnId == turnId
                && Self.isFinalAnswerAssistantPhase(candidate.assistantPhase)
                && !candidate.isStreaming
                && !Self.isGeneratedImageArtifactOnly(candidate.text)
                && Self.hasMeaningfulHistoryText(candidate.text)
        }) else {
            return nil
        }
        return GeneratedImageMergeTarget(index: fallbackIndex, canAdoptImageItemId: false)
    }

    // Folds image-generation artifact rows into the final assistant text for the same turn.
    private func mergeGeneratedImageArtifactsIntoAssistantMessage(
        threadId: String,
        turnId: String?,
        assistantMessageId: String
    ) -> Bool {
        guard let resolvedTurnId = turnId,
              var threadMessages = messagesByThread[threadId],
              let targetIndex = threadMessages.firstIndex(where: { $0.id == assistantMessageId }) else {
            return false
        }

        let artifactMessages = threadMessages.filter { candidate in
            candidate.id != assistantMessageId
                && candidate.role == .assistant
                && candidate.turnId == resolvedTurnId
                && Self.isGeneratedImageArtifactOnly(candidate.text)
        }
        guard !artifactMessages.isEmpty else {
            return false
        }

        var targetMessage = threadMessages[targetIndex]
        guard targetMessage.text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return false
        }
        var mergedText = Self.normalizedMessageText(targetMessage.text)
        for artifact in artifactMessages {
            let artifactText = Self.normalizedMessageText(artifact.text)
            guard Self.hasMeaningfulHistoryText(artifactText), !mergedText.contains(artifactText) else {
                continue
            }
            mergedText = mergedText.isEmpty ? artifactText : "\(mergedText)\n\n\(artifactText)"
        }
        targetMessage.text = mergedText
        targetMessage.isStreaming = false
        if targetMessage.turnId == nil {
            targetMessage.turnId = resolvedTurnId
        }

        let artifactIds = Set(artifactMessages.map(\.id))
        threadMessages.removeAll { artifactIds.contains($0.id) }
        guard let updatedTargetIndex = threadMessages.firstIndex(where: { $0.id == assistantMessageId }) else {
            return false
        }
        threadMessages[updatedTargetIndex] = targetMessage
        messagesByThread[threadId] = threadMessages
        refreshDerivedPlanMetadata(threadId: threadId, messageIndex: updatedTargetIndex)
        return true
    }

    private static func isGeneratedImageArtifactOnly(_ text: String) -> Bool {
        let imageReferences = AssistantMarkdownImageReferenceParser.references(in: text)
        guard !imageReferences.isEmpty,
              imageReferences.allSatisfy(\.isCodexGeneratedImage) else {
            return false
        }

        return AssistantMarkdownImageReferenceParser
            .visibleTextRemovingImageSyntax(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private static func isFinalAnswerAssistantPhase(_ phase: String?) -> Bool {
        phase == "final_answer"
    }

    @discardableResult
    private func applyAssistantPhaseIfNeeded(
        threadId: String,
        messageId: String,
        assistantPhase: String?
    ) -> Bool {
        guard let messageIndex = findMessageIndex(threadId: threadId, messageId: messageId) else {
            return false
        }
        return applyAssistantPhaseIfNeeded(
            threadId: threadId,
            messageIndex: messageIndex,
            assistantPhase: assistantPhase
        )
    }

    @discardableResult
    private func applyAssistantPhaseIfNeeded(
        threadId: String,
        messageIndex: Int,
        assistantPhase: String?
    ) -> Bool {
        guard let phase = normalizedAssistantPhase(assistantPhase),
              messagesByThread[threadId]?.indices.contains(messageIndex) == true,
              messagesByThread[threadId]?[messageIndex].role == .assistant else {
            return false
        }

        let currentPhase = messagesByThread[threadId]?[messageIndex].assistantPhase
        guard currentPhase == nil || Self.isFinalAnswerAssistantPhase(phase) else {
            return false
        }

        messagesByThread[threadId]?[messageIndex].assistantPhase = phase
        return true
    }

    // Canonical item completions replace prose, but turn-scoped image previews may
    // already be visible in the same bubble and must survive that replacement.
    private static func assistantCompletionTextPreservingImages(
        existingText: String,
        canonicalText: String
    ) -> String {
        let trimmedCanonicalText = Self.normalizedMessageText(canonicalText)
        guard existingText.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit,
              trimmedCanonicalText.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return trimmedCanonicalText
        }
        let existingImageReferences = AssistantMarkdownImageReferenceParser.references(in: existingText)
            .filter(\.isCodexGeneratedImage)
        guard !existingImageReferences.isEmpty else {
            return trimmedCanonicalText
        }

        var preservedText = trimmedCanonicalText
        let canonicalImagePaths = Set(
            AssistantMarkdownImageReferenceParser.references(in: trimmedCanonicalText).map(\.path)
        )
        var appendedImagePaths = canonicalImagePaths

        for reference in existingImageReferences where !appendedImagePaths.contains(reference.path) {
            let altText = reference.altText.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = altText.isEmpty ? "Generated image" : altText
            let markdown = "![\(label)](\(Self.markdownImagePath(reference.path)))"
            preservedText = preservedText.isEmpty ? markdown : "\(preservedText)\n\n\(markdown)"
            appendedImagePaths.insert(reference.path)
        }

        return preservedText
    }

    // Suppresses completion replays that resend the whole assistant block already shown around tool rows.
    private func absorbAssistantBlockReplayCompletion(
        threadId: String,
        turnId: String?,
        itemId: String?,
        text: String
    ) -> String? {
        guard var threadMessages = messagesByThread[threadId] else {
            return nil
        }

        if let exactReplayIndex = AssistantReplayDeduper.exactReplayMessageIndex(
            in: threadMessages,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            text: text
        ) {
            var didMutate = false
            if threadMessages[exactReplayIndex].isStreaming {
                threadMessages[exactReplayIndex].isStreaming = false
                didMutate = true
            }
            if threadMessages[exactReplayIndex].turnId == nil, let turnId {
                threadMessages[exactReplayIndex].turnId = turnId
                didMutate = true
            }
            if didMutate {
                messagesByThread[threadId] = threadMessages
            }
            return threadMessages[exactReplayIndex].id
        }

        if let imageMergedReplay = imageMergedReplayMessage(
            in: threadMessages,
            threadId: threadId,
            turnId: turnId,
            text: text
        ) {
            let existingText = threadMessages[imageMergedReplay.index].text
            let canonicalText = Self.canonicalTextRemovingReplayedImagePreview(
                text,
                previewText: imageMergedReplay.previewText
            )
            threadMessages[imageMergedReplay.index].text = Self.assistantCompletionTextPreservingImages(
                existingText: existingText,
                canonicalText: canonicalText
            )
            threadMessages[imageMergedReplay.index].isStreaming = false
            if threadMessages[imageMergedReplay.index].turnId == nil, let turnId {
                threadMessages[imageMergedReplay.index].turnId = turnId
            }
            messagesByThread[threadId] = threadMessages
            refreshDerivedPlanMetadata(threadId: threadId, messageIndex: imageMergedReplay.index)
            return threadMessages[imageMergedReplay.index].id
        }

        guard let assistantIndices = AssistantReplayDeduper.blockReplayMessageIndices(
            in: threadMessages,
            threadId: threadId,
            turnId: turnId,
            text: text
        ),
        let terminalIndex = assistantIndices.last else {
            return nil
        }

        var didMutate = false
        for index in assistantIndices where threadMessages[index].isStreaming {
            threadMessages[index].isStreaming = false
            didMutate = true
        }
        if threadMessages[terminalIndex].turnId == nil, let turnId {
            threadMessages[terminalIndex].turnId = turnId
            didMutate = true
        }
        if didMutate {
            messagesByThread[threadId] = threadMessages
        }
        return threadMessages[terminalIndex].id
    }

    // Image generation can finish on a preparatory assistant row before the final
    // completion replays that same prose plus the terminal answer.
    private func imageMergedReplayMessage(
        in messages: [CodexMessage],
        threadId: String,
        turnId: String?,
        text: String
    ) -> (index: Int, previewText: String)? {
        guard text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return nil
        }
        let replayText = Self.normalizedMessageText(text)
        guard !replayText.isEmpty else {
            return nil
        }

        let normalizedTurnId = normalizedStreamingItemID(turnId)
        for index in messages.indices.reversed() {
            let candidate = messages[index]
            guard candidate.text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
                continue
            }
            let imageReferences = AssistantMarkdownImageReferenceParser.references(in: candidate.text)
            guard candidate.role == .assistant,
                  candidate.threadId == threadId,
                  Self.hasMeaningfulHistoryText(candidate.text),
                  !imageReferences.isEmpty,
                  imageReferences.allSatisfy(\.isCodexGeneratedImage) else {
                continue
            }

            if let normalizedTurnId,
               let candidateTurnId = normalizedStreamingItemID(candidate.turnId),
               candidateTurnId != normalizedTurnId {
                continue
            }

            let candidateTextWithoutImages = AssistantMarkdownImageReferenceParser
                .visibleTextRemovingImageSyntax(from: candidate.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidateTextWithoutImages.count >= 24 else {
                continue
            }

            if replayText.contains(Self.normalizedMessageText(candidateTextWithoutImages)) {
                return (index, candidateTextWithoutImages)
            }
        }
        return nil
    }

    private static func canonicalTextRemovingReplayedImagePreview(_ text: String, previewText: String) -> String {
        guard text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit,
              previewText.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return Self.normalizedMessageText(text)
        }
        let trimmedText = Self.normalizedMessageText(text)
        let trimmedPreview = Self.normalizedMessageText(previewText)
        guard !trimmedText.isEmpty,
              !trimmedPreview.isEmpty,
              let range = trimmedText.range(of: trimmedPreview) else {
            return trimmedText
        }

        let prunedText = (trimmedText[..<range.lowerBound] + trimmedText[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prunedText.isEmpty ? trimmedText : prunedText
    }

    private func imagePreviewAssistantCompletionIndex(
        threadId: String,
        turnId: String,
        itemId: String?,
        text: String
    ) -> Int? {
        guard itemId == nil else {
            return nil
        }
        guard text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return nil
        }

        let normalizedText = Self.normalizedMessageText(text)
        guard !normalizedText.isEmpty,
              let threadMessages = messagesByThread[threadId] else {
            return nil
        }

        return threadMessages.indices.reversed().first { index in
            let candidate = threadMessages[index]
            guard candidate.text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
                return false
            }
            let imageReferences = AssistantMarkdownImageReferenceParser.references(in: candidate.text)
            guard candidate.role == .assistant,
                  candidate.threadId == threadId,
                  candidate.turnId == turnId,
                  !candidate.isStreaming,
                  Self.normalizedMessageText(candidate.text) != normalizedText,
                  !imageReferences.isEmpty,
                  imageReferences.allSatisfy(\.isCodexGeneratedImage) else {
                return false
            }

            if let itemId,
               let candidateItemId = normalizedStreamingItemID(candidate.itemId),
               candidateItemId == itemId {
                return false
            }

            return true
        }
    }

    private func removeAssistantStreamingLookups(messageId: String) {
        streamingAssistantFallbackMessageByTurnID = streamingAssistantFallbackMessageByTurnID.filter { $0.value != messageId }
        streamingAssistantMessageByItemKey = streamingAssistantMessageByItemKey.filter { $0.value != messageId }
    }

    // The live fast path removes a streaming assistant row as soon as its text turns
    // out to replay an already-present terminal row (see updateStreamingAssistantOutput).
    // During a catch-up burst that fast path is gated, so the settle runs one bounded
    // pass with the same semantics before the snapshot rebuild.
    func pruneStreamingAssistantReplayRowsAfterCatchUp(threadId: String) {
        guard let messages = messagesByThread[threadId], !messages.isEmpty else {
            return
        }

        var nextMessages = messages
        var removedMessageIDs: [String] = []
        // Newest-first keeps earlier indices valid while removing.
        for index in nextMessages.indices.reversed() {
            let message = nextMessages[index]
            guard message.role == .assistant, message.isStreaming else {
                continue
            }
            guard let terminalMessageId = assistantReplayTargetMessageId(
                in: nextMessages,
                threadId: threadId,
                turnId: message.turnId,
                itemId: message.itemId,
                text: message.text,
                excludingMessageID: message.id
            ) else {
                continue
            }

            nextMessages.remove(at: index)
            removedMessageIDs.append(message.id)
            if let turnId = message.turnId {
                noteAssistantMessage(
                    threadId: threadId,
                    turnId: turnId,
                    assistantMessageId: terminalMessageId
                )
            }
        }

        guard !removedMessageIDs.isEmpty else {
            return
        }
        messagesByThread[threadId] = nextMessages
        for messageId in removedMessageIDs {
            removeAssistantStreamingLookups(messageId: messageId)
        }
        persistMessages()
    }

    private func assistantReplayTargetMessageId(
        in messages: [CodexMessage],
        threadId: String,
        turnId: String?,
        itemId: String?,
        text: String,
        excludingMessageID: String
    ) -> String? {
        if let exactReplayIndex = AssistantReplayDeduper.exactReplayMessageIndex(
            in: messages,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            text: text,
            excludingMessageID: excludingMessageID
        ) {
            return messages[exactReplayIndex].id
        }

        guard let replayIndices = AssistantReplayDeduper.blockReplayMessageIndices(
            in: messages,
            threadId: threadId,
            turnId: turnId,
            text: text,
            excludingMessageID: excludingMessageID
        ) else {
            return nil
        }
        return replayIndices.last.map { messages[$0].id }
    }

    func knownAssistantTurnId(threadId: String, itemId: String) -> String? {
        messagesByThread[threadId]?.reversed().first(where: { message in
            message.role == .assistant
                && message.itemId == itemId
                && !(message.turnId ?? "").isEmpty
        })?.turnId
    }

    // Supplies a stable, non-actionable identity while the runtime has not yet
    // attached a canonical turn id. This lets turn-less item deltas share one
    // timeline row without making Stop send a synthetic id to app-server.
    func provisionalIDLessTurnID(for threadId: String, startsNewRun: Bool) -> String {
        if !startsNewRun, let existing = provisionalIDLessTurnIDByThread[threadId] {
            return existing
        }
        let provisionalTurnID = CodexSyntheticIdentifiers.provisionalIDLessTurnID()
        provisionalIDLessTurnIDByThread[threadId] = provisionalTurnID
        threadIdByTurnID[provisionalTurnID] = threadId
        return provisionalTurnID
    }

    // Canonical lifecycle can arrive after item output. Rebind the provisional
    // rows and volatile lookup keys before later deltas use the real identity.
    func promoteProvisionalIDLessTurnIfNeeded(threadId: String, canonicalTurnID: String) {
        guard let provisionalTurnID = provisionalIDLessTurnIDByThread.removeValue(forKey: threadId),
              provisionalTurnID != canonicalTurnID else {
            return
        }

        flushPendingAssistantDeltas(for: threadId, turnId: provisionalTurnID)
        flushPendingSystemDeltasForTurn(threadId: threadId, turnId: provisionalTurnID)

        if var threadMessages = messagesByThread[threadId] {
            var didMutate = false
            for index in threadMessages.indices where threadMessages[index].turnId == provisionalTurnID {
                threadMessages[index].turnId = canonicalTurnID
                didMutate = true
            }
            if didMutate {
                messagesByThread[threadId] = threadMessages
                persistMessages()
                updateCurrentOutput(for: threadId)
            }
        }

        let provisionalTurnKey = streamingMessageKey(threadId: threadId, turnId: provisionalTurnID)
        let canonicalTurnKey = streamingMessageKey(threadId: threadId, turnId: canonicalTurnID)
        if let messageID = streamingAssistantFallbackMessageByTurnID.removeValue(forKey: provisionalTurnKey) {
            streamingAssistantFallbackMessageByTurnID[canonicalTurnKey] = messageID
        }
        let provisionalItemPrefix = "\(provisionalTurnKey)|item:"
        let provisionalItemKeys = streamingAssistantMessageByItemKey.keys.filter {
            $0.hasPrefix(provisionalItemPrefix)
        }
        for provisionalKey in provisionalItemKeys {
            guard let messageID = streamingAssistantMessageByItemKey.removeValue(forKey: provisionalKey) else {
                continue
            }
            let itemSuffix = provisionalKey.dropFirst(provisionalTurnKey.count)
            streamingAssistantMessageByItemKey[canonicalTurnKey + itemSuffix] = messageID
        }
        threadIdByTurnID.removeValue(forKey: provisionalTurnID)
        threadIdByTurnID[canonicalTurnID] = threadId
    }

    func markMessageDeliveryState(
        threadId: String,
        messageId: String,
        state: CodexMessageDeliveryState,
        turnId: String? = nil
    ) {
        guard !messageId.isEmpty,
              let messageIndex = findMessageIndex(threadId: threadId, messageId: messageId) else {
            return
        }

        messagesByThread[threadId]?[messageIndex].deliveryState = state
        if let turnId, messagesByThread[threadId]?[messageIndex].turnId == nil {
            messagesByThread[threadId]?[messageIndex].turnId = turnId
        }
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    func confirmLatestPendingUserMessage(threadId: String, turnId: String) {
        guard !turnId.isEmpty,
              var threadMessages = messagesByThread[threadId] else {
            return
        }

        guard let index = threadMessages.indices.reversed().first(where: { idx in
            let candidate = threadMessages[idx]
            return candidate.role == .user
                && candidate.deliveryState == .pending
                && (candidate.turnId == nil || candidate.turnId == turnId)
        }) else {
            return
        }

        threadMessages[index].deliveryState = .confirmed
        threadMessages[index].turnId = turnId
        messagesByThread[threadId] = threadMessages
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    func removeLatestFailedUserMessage(
        threadId: String,
        matchingText: String,
        matchingAttachments: [CodexImageAttachment] = []
    ) {
        let normalizedText = Self.normalizedMessageText(matchingText)
        let matchingAttachmentSignature = matchingAttachments
            .map(\.stableIdentityKey)
            .joined(separator: "|")

        guard (!normalizedText.isEmpty || !matchingAttachmentSignature.isEmpty),
              var threadMessages = messagesByThread[threadId] else {
            return
        }

        guard let index = threadMessages.indices.reversed().first(where: { index in
            let message = threadMessages[index]
            let messageAttachmentSignature = message.attachments
                .map(\.stableIdentityKey)
                .joined(separator: "|")
            let matchesText = normalizedText.isEmpty
                || Self.historyTextsMatch(message.text, matchingText)
            let matchesAttachments = matchingAttachmentSignature.isEmpty
                || messageAttachmentSignature == matchingAttachmentSignature
            return message.role == .user
                && message.deliveryState == .failed
                && matchesText
                && matchesAttachments
        }) else {
            return
        }

        threadMessages.remove(at: index)
        messagesByThread[threadId] = threadMessages
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    // Removes a known optimistic user row when text matching is not reliable, such as mention-only sends.
    @discardableResult
    func removeUserMessage(threadId: String, messageId: String) -> Bool {
        guard !messageId.isEmpty,
              var threadMessages = messagesByThread[threadId],
              let index = findMessageIndex(threadId: threadId, messageId: messageId),
              threadMessages.indices.contains(index),
              threadMessages[index].role == .user else {
            return false
        }

        threadMessages.remove(at: index)
        messagesByThread[threadId] = threadMessages
        messageIndexCacheByThread[threadId] = nil
        persistMessages()
        updateCurrentOutput(for: threadId)
        return true
    }

    // Marks streaming assistant state complete once turn/completed arrives.
    func markTurnCompleted(threadId: String, turnId: String?) {
        let resolvedTurnId = turnId
            ?? activeTurnIdByThread[threadId]
            ?? provisionalIDLessTurnIDByThread[threadId]
        promoteDisplacedActiveTurnIfNeeded(
            threadId: threadId,
            completedTurnId: resolvedTurnId
        )
        let currentActiveTurnId = activeTurnIdByThread[threadId]
        flushPendingAssistantDeltas(for: threadId, turnId: resolvedTurnId)
        flushPendingSystemDeltasForTurn(threadId: threadId, turnId: resolvedTurnId)

        // Desktop can report a late terminal event for turn A after turn B has
        // already become the thread's active turn. Completing A must not clear
        // B's running badge and then wait for a later state probe to restore it.
        let completesCurrentThreadRun = turnCompletionMatchesCurrentThreadRun(
            threadId: threadId,
            completedTurnId: resolvedTurnId,
            currentActiveTurnId: currentActiveTurnId
        )
        if completesCurrentThreadRun {
            clearRunningState(for: threadId)
            clearRunningThreadWatch(threadId)
        }
        let shouldFinalizePlanSteps: Bool = {
            if let resolvedTurnId {
                return turnTerminalState(for: resolvedTurnId, threadId: threadId) == .completed
            }
            return latestTurnTerminalStateByThread[threadId] == .completed
        }()

        if let resolvedTurnId {
            clearAssistantStreamingState(threadId: threadId, turnId: resolvedTurnId)
        }

        if let resolvedTurnId,
           currentActiveTurnId == resolvedTurnId {
            setActiveTurnID(nil, for: threadId)
        } else if resolvedTurnId == nil {
            setActiveTurnID(nil, for: threadId)
        }

        if let resolvedTurnId,
           activeTurnId == resolvedTurnId {
            activeTurnId = nil
        }

        updateBackgroundRunGraceTask()

        // Some servers never emit explicit item/completed for reasoning/fileChange.
        // Close both turn-bound and orphan system stream rows, but keep reasoning content visible.
        if var threadMessages = messagesByThread[threadId] {
            var didMutate = false
            let belongsToCompletedTurn: (CodexMessage) -> Bool = { message in
                if let resolvedTurnId {
                    return message.turnId == resolvedTurnId
                        || (completesCurrentThreadRun && message.turnId == nil)
                }
                return completesCurrentThreadRun && message.isStreaming
            }

            for index in threadMessages.indices where threadMessages[index].role == .system
                && threadMessages[index].isStreaming {
                let belongsToTurn = belongsToCompletedTurn(threadMessages[index])
                guard belongsToTurn else { continue }
                threadMessages[index].isStreaming = false
                if var review = threadMessages[index].autoApprovalReview,
                   review.status == .inProgress {
                    review.status = .aborted
                    review.completedAtMs = Int(Date().timeIntervalSince1970 * 1_000)
                    threadMessages[index].autoApprovalReview = review
                }
                didMutate = true
            }

            for index in threadMessages.indices where threadMessages[index].role == .system
                && threadMessages[index].kind == .plan {
                let belongsToTurn = belongsToCompletedTurn(threadMessages[index])
                guard belongsToTurn else { continue }

                switch threadMessages[index].resolvedPlanPresentation {
                case .resultCompletedItem:
                    let nextPresentation: CodexPlanPresentation = shouldFinalizePlanSteps ? .resultReady : .resultClosed
                    if threadMessages[index].planPresentation != nextPresentation {
                        threadMessages[index].planPresentation = nextPresentation
                    }
                    refreshDerivedPlanMetadata(in: &threadMessages, index: index)
                    didMutate = true
                case .resultStreaming:
                    if threadMessages[index].planPresentation != .resultClosed {
                        threadMessages[index].planPresentation = .resultClosed
                        threadMessages[index].proposedPlan = nil
                        didMutate = true
                    }
                default:
                    break
                }
            }

            // Successful completions can land before the server publishes a final
            // "all steps completed" plan snapshot, so normalize stale progress steps here.
            if shouldFinalizePlanSteps {
                let fallbackPlanIndex: Int? = {
                    guard resolvedTurnId == nil else { return nil }
                    return threadMessages.indices.reversed().first(where: { index in
                        let candidate = threadMessages[index]
                        return candidate.role == .system
                            && candidate.kind == .plan
                            && candidate.resolvedPlanPresentation == .progress
                            && candidate.planState?.steps.contains(where: { $0.status != .completed }) == true
                    })
                }()

                for index in threadMessages.indices where threadMessages[index].role == .system
                    && threadMessages[index].kind == .plan {
                    let belongsToTurn = belongsToCompletedTurn(threadMessages[index])
                        || fallbackPlanIndex == index
                    guard belongsToTurn,
                          threadMessages[index].resolvedPlanPresentation == .progress,
                          let planState = threadMessages[index].planState,
                          !planState.steps.isEmpty,
                          planState.steps.contains(where: { $0.status != .completed }) else {
                        continue
                    }

                    threadMessages[index].planState = CodexPlanState(
                        explanation: planState.explanation,
                        steps: planState.steps.map { step in
                            CodexPlanStep(id: step.id, step: step.step, status: .completed)
                        }
                    )
                    didMutate = true
                }
            }

            let priorCount = threadMessages.count
            if let resolvedTurnId {
                threadMessages.removeAll {
                    $0.role == .system
                        && $0.kind == .thinking
                        && ($0.turnId == resolvedTurnId
                            || (completesCurrentThreadRun && $0.turnId == nil))
                        && shouldPruneThinkingRowAfterTurnCompletion($0)
                }
            } else if completesCurrentThreadRun {
                threadMessages.removeAll {
                    $0.role == .system
                        && $0.kind == .thinking
                        && shouldPruneThinkingRowAfterTurnCompletion($0)
                }
            }
            if threadMessages.count != priorCount {
                didMutate = true
            }

            if didMutate {
                messagesByThread[threadId] = threadMessages
            }
        }

        let completedThreadItemKeyPrefix = "\(threadId)|item:"
        streamingSystemMessageByItemID = streamingSystemMessageByItemID.filter { key, messageId in
            guard key.hasPrefix(completedThreadItemKeyPrefix) else {
                return true
            }
            guard let index = findMessageIndex(threadId: threadId, messageId: messageId),
                  let message = messagesByThread[threadId]?[index] else {
                return false
            }
            guard message.role == .system else {
                return true
            }
            if message.kind == .thinking {
                if let resolvedTurnId {
                    return message.turnId != resolvedTurnId
                        && (!completesCurrentThreadRun || message.turnId != nil)
                }
                return !completesCurrentThreadRun
            }
            if let resolvedTurnId {
                return message.turnId != resolvedTurnId
                    && (!completesCurrentThreadRun || message.turnId != nil)
            }
            return !completesCurrentThreadRun || !message.isStreaming
        }

        // Keep turn->thread mapping after completion to support late-arriving
        // notifications (e.g. turn/diff/updated emitted right after turn/completed).
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    // Promotes an older overlapping run when the newest identified turn finishes.
    // The snapshot refresh remains authoritative, but this prevents the running UI
    // and Stop control from dropping during the recovery round trip.
    @discardableResult
    func promoteDisplacedActiveTurnIfNeeded(threadId: String, completedTurnId: String?) -> Bool {
        guard let completedTurnId else {
            return false
        }

        displacedActiveTurnIDsByThread[threadId]?.remove(completedTurnId)
        guard activeTurnIdByThread[threadId] == completedTurnId,
              let promotedTurnId = displacedActiveTurnIDsByThread[threadId]?.popFirst() else {
            if displacedActiveTurnIDsByThread[threadId]?.isEmpty == true {
                displacedActiveTurnIDsByThread.removeValue(forKey: threadId)
            }
            return false
        }

        if displacedActiveTurnIDsByThread[threadId]?.isEmpty == true {
            displacedActiveTurnIDsByThread.removeValue(forKey: threadId)
        }
        setActiveTurnID(promotedTurnId, for: threadId)
        threadIdByTurnID[promotedTurnId] = threadId
        markThreadAsRunning(threadId)
        setProtectedRunningFallback(false, for: threadId)
        if activeTurnId == completedTurnId {
            activeTurnId = promotedTurnId
        }
        return true
    }

    // An identified completion displaced by a newer id-less start belongs to the
    // older run even though there is temporarily no current active turn id.
    func turnCompletionMatchesCurrentThreadRun(
        threadId: String,
        completedTurnId: String?,
        currentActiveTurnId: String?
    ) -> Bool {
        guard let completedTurnId else {
            return true
        }
        if let currentActiveTurnId {
            return completedTurnId == currentActiveTurnId
        }
        if supersededTurnIDsByIDLessRunByThread[threadId]?.contains(completedTurnId) == true,
           (protectedRunningFallbackThreadIDs.contains(threadId)
                || pendingReconnectRunContinuityThreadIDs.contains(threadId)) {
            return false
        }
        return true
    }

    // Converts all pending streaming bubbles to completed state after transport failures.
    func finalizeAllStreamingState(preserveRunLifecycle: Bool = false) {
        flushAllPendingStreamingDeltas()
        var didMutate = false

        let preservedThreadIDs: Set<String> = preserveRunLifecycle
            ? runningThreadIDs
                .union(protectedRunningFallbackThreadIDs)
                .union(activeTurnIdByThread.keys)
            : []

        for threadId in messagesByThread.keys {
            guard var threadMessages = messagesByThread[threadId] else { continue }

            if preservedThreadIDs.contains(threadId) {
                continue
            }

            var localChanged = false
            for index in threadMessages.indices where threadMessages[index].isStreaming {
                threadMessages[index].isStreaming = false
                if var review = threadMessages[index].autoApprovalReview,
                   review.status == .inProgress {
                    review.status = .aborted
                    review.completedAtMs = Int(Date().timeIntervalSince1970 * 1_000)
                    threadMessages[index].autoApprovalReview = review
                }
                localChanged = true
            }

            if localChanged {
                messagesByThread[threadId] = threadMessages
                didMutate = true
            }
        }

        // A reconnect can re-announce the same in-flight turn after these
        // volatile running flags are cleared. Preserve one continuity claim so
        // its start event does not look like a brand-new run generation.
        pendingReconnectRunContinuityThreadIDs.formUnion(runningThreadIDs)
        pendingReconnectRunContinuityThreadIDs.formUnion(protectedRunningFallbackThreadIDs)
        pendingReconnectRunContinuityThreadIDs.formUnion(activeTurnIdByThread.keys)

        if !preserveRunLifecycle {
            activeTurnId = nil
            activeTurnIdByThread.removeAll()
            threadsPendingCompletionHaptic.removeAll()
            clearAllRunningState()
            displacedActiveTurnIDsByThread.removeAll()
            supersededTurnIDsByIDLessRunByThread.removeAll()
            provisionalIDLessTurnIDByThread.removeAll()
        }
        if preserveRunLifecycle {
            let preservedMessageIDs = Set(preservedThreadIDs.flatMap { threadID in
                (messagesByThread[threadID] ?? []).filter(\.isStreaming).map(\.id)
            })
            streamingAssistantFallbackMessageByTurnID = streamingAssistantFallbackMessageByTurnID.filter {
                preservedMessageIDs.contains($0.value)
            }
            streamingAssistantMessageByItemKey = streamingAssistantMessageByItemKey.filter {
                preservedMessageIDs.contains($0.value)
            }
            streamingSystemMessageByItemID = streamingSystemMessageByItemID.filter {
                preservedMessageIDs.contains($0.value)
            }
        } else {
            streamingAssistantFallbackMessageByTurnID.removeAll()
            streamingAssistantMessageByItemKey.removeAll()
            streamingSystemMessageByItemID.removeAll()
        }
        pendingAssistantDeltaByStreamID.removeAll()
        pendingAssistantDeltaContextByStreamID.removeAll()
        pendingAssistantDeltaStreamOrder.removeAll()
        pendingAssistantDeltaFlushTask?.cancel()
        pendingAssistantDeltaFlushTask = nil
        if !preserveRunLifecycle {
            threadIdByTurnID.removeAll()
        }

        if didMutate {
            persistCurrentMacMessages()
            if let activeThreadId {
                updateCurrentOutput(for: activeThreadId)
            }
        }
    }
}

extension CodexService {
    func persistMessages() {
        messagePersistenceDebounceTask?.cancel()
        messagePersistenceDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }

            let snapshot = self.messagesByThread
            let macDeviceId = self.currentMacScopedPersistenceDeviceId
            self.messagePersistenceDebounceTask = nil

            Task.detached { [messagePersistence] in
                messagePersistence.save(snapshot, macDeviceId: macDeviceId)
            }
        }
    }

    // Persists per-turn terminal state so completed-turn grouping survives app relaunch.
    func persistTurnTerminalStates() {
        guard !suspendAutomaticMacScopedPersistence, !isApplyingMacScopedState else {
            return
        }

        let persistableStates = terminalStateByTurnID.filter { turnId, _ in
            !CodexSyntheticIdentifiers.isProjectedDesktopTurnID(turnId)
        }
        if persistableStates.count != terminalStateByTurnID.count {
            terminalStateByTurnID = persistableStates
        }

        guard !persistableStates.isEmpty else {
            defaults.removeObject(forKey: macScopedDefaultsKey(Self.turnTerminalStatesDefaultsKey))
            return
        }

        guard let data = try? encoder.encode(persistableStates) else {
            defaults.removeObject(forKey: macScopedDefaultsKey(Self.turnTerminalStatesDefaultsKey))
            return
        }

        defaults.set(data, forKey: macScopedDefaultsKey(Self.turnTerminalStatesDefaultsKey))
    }
}

// ─── Private helpers ──────────────────────────────────────────

extension CodexService {
    private func enqueueAssistantDelta(
        threadId: String,
        turnId: String,
        itemId: String?,
        assistantPhase: String?,
        delta: String,
        isReplay: Bool
    ) {
        let normalizedItemId = normalizedStreamingItemID(itemId)
        let normalizedPhase = normalizedAssistantPhase(assistantPhase)
        let streamID = assistantDeltaStreamID(threadId: threadId, turnId: turnId, itemId: normalizedItemId)

        if normalizedItemId != nil {
            migratePendingTurnFallbackDelta(
                threadId: threadId,
                turnId: turnId,
                normalizedItemId: normalizedItemId
            )
        }

        // A batch stays replay-only if every coalesced delta was replayed; one live
        // delta makes the whole batch live so running state recovers immediately.
        let existingIsReplay = pendingAssistantDeltaContextByStreamID[streamID]?.isReplay ?? true
        pendingAssistantDeltaContextByStreamID[streamID] = (
            threadId: threadId,
            turnId: turnId.trimmingCharacters(in: .whitespacesAndNewlines),
            itemId: normalizedItemId,
            assistantPhase: normalizedPhase,
            isReplay: existingIsReplay && isReplay
        )
        if pendingAssistantDeltaByStreamID[streamID] == nil,
           !pendingAssistantDeltaStreamOrder.contains(streamID) {
            pendingAssistantDeltaStreamOrder.append(streamID)
        }
        pendingAssistantDeltaByStreamID[streamID] = mergeAssistantDelta(
            existingText: pendingAssistantDeltaByStreamID[streamID] ?? "",
            incomingDelta: delta
        )
        schedulePendingAssistantDeltaFlushIfNeeded()
    }

    private func migratePendingTurnFallbackDelta(
        threadId: String,
        turnId: String,
        normalizedItemId: String?
    ) {
        migratePendingAssistantDelta(
            threadId: threadId,
            turnId: turnId,
            sourceItemId: nil,
            destinationItemId: normalizedItemId
        )
    }

    // One identity migration path for turn-scoped fallback -> item and synthetic item ->
    // provider item. It preserves the stream queue order, concatenates pending text once, and
    // keeps a batch replay-only only when both sides were replay-only.
    private func migratePendingAssistantDelta(
        threadId: String,
        turnId: String,
        sourceItemId: String?,
        destinationItemId: String?
    ) {
        let sourceStreamID = assistantDeltaStreamID(threadId: threadId, turnId: turnId, itemId: sourceItemId)
        let destinationStreamID = assistantDeltaStreamID(threadId: threadId, turnId: turnId, itemId: destinationItemId)
        guard sourceStreamID != destinationStreamID,
              let sourceDelta = pendingAssistantDeltaByStreamID.removeValue(forKey: sourceStreamID) else {
            return
        }

        let sourceContext = pendingAssistantDeltaContextByStreamID.removeValue(forKey: sourceStreamID)
        pendingAssistantDeltaStreamOrder.removeAll { $0 == sourceStreamID }
        if !pendingAssistantDeltaStreamOrder.contains(destinationStreamID) {
            pendingAssistantDeltaStreamOrder.append(destinationStreamID)
        }
        pendingAssistantDeltaByStreamID[destinationStreamID] = mergeAssistantDelta(
            existingText: pendingAssistantDeltaByStreamID[destinationStreamID] ?? "",
            incomingDelta: sourceDelta
        )
        let destinationIsReplay = pendingAssistantDeltaContextByStreamID[destinationStreamID]?.isReplay ?? true
        pendingAssistantDeltaContextByStreamID[destinationStreamID] = (
            threadId: threadId,
            turnId: turnId.trimmingCharacters(in: .whitespacesAndNewlines),
            itemId: destinationItemId,
            assistantPhase: sourceContext?.assistantPhase,
            isReplay: destinationIsReplay && (sourceContext?.isReplay ?? true)
        )
    }

    private func schedulePendingAssistantDeltaFlushIfNeeded() {
        guard pendingAssistantDeltaFlushTask == nil else { return }

        let flushDelayNanoseconds = pendingAssistantDeltaFlushDelayNanoseconds()
        pendingAssistantDeltaFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: flushDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self.flushPendingAssistantDeltas()
        }
    }

    // A drag or typing burst can start after the flush timer was armed; wait it out in
    // interaction-cadence slices (bounded, so a long flick chain cannot starve the stream).
    static func deferFlushWhileInteractionIsActive() async {
        var remainingDeferrals = 8
        while !Task.isCancelled,
              remainingDeferrals > 0,
              StreamingUIInteractionMonitor.isInteractionActive() {
            remainingDeferrals -= 1
            try? await Task.sleep(
                nanoseconds: StreamingDeltaCoalescingPolicy.interactionFlushDelayNanoseconds
            )
        }
    }

    private func pendingAssistantDeltaFlushDelayNanoseconds() -> UInt64 {
        var largestVisibleByteCount = 0
        for streamID in pendingAssistantDeltaStreamOrder {
            guard let visibleByteCount = visibleAssistantTextByteCount(forPendingAssistantStreamID: streamID) else {
                return StreamingDeltaCoalescingPolicy.assistantInitialFlushDelayNanoseconds
            }
            largestVisibleByteCount = max(largestVisibleByteCount, visibleByteCount)
        }

        let pendingDeltaByteCount = pendingAssistantDeltaByStreamID.values.reduce(0) { total, delta in
            total + delta.utf8.count
        }
        let isLargeStream = pendingDeltaByteCount >= StreamingDeltaCoalescingPolicy.assistantLargePendingDeltaByteCount
            || largestVisibleByteCount >= StreamingDeltaCoalescingPolicy.assistantLargeVisibleTextByteCount

        return isLargeStream
            ? StreamingDeltaCoalescingPolicy.assistantLargeStreamingFlushDelayNanoseconds
            : StreamingDeltaCoalescingPolicy.assistantStreamingFlushDelayNanoseconds
    }

    // Treat streams with no painted text as first-block work so sends still feel immediate.
    private func visibleAssistantTextByteCount(forPendingAssistantStreamID streamID: String) -> Int? {
        guard let context = pendingAssistantDeltaContextByStreamID[streamID],
              let messageID = streamingAssistantMessageID(
                threadId: context.threadId,
                turnId: context.turnId,
                itemId: context.itemId
              ),
              let messageIndex = findMessageIndex(threadId: context.threadId, messageId: messageID),
              let message = messagesByThread[context.threadId]?[messageIndex],
              hasRenderableAssistantOutputText(message.text) else {
            return nil
        }

        return message.text.utf8.count
    }

    private func streamingAssistantMessageID(threadId: String, turnId: String, itemId: String?) -> String? {
        if let itemId,
           let messageID = streamingAssistantMessageByItemKey[
            assistantStreamingMessageKey(threadId: threadId, turnId: turnId, itemId: itemId)
           ] {
            return messageID
        }

        return streamingAssistantFallbackMessageByTurnID[
            streamingMessageKey(threadId: threadId, turnId: turnId)
        ]
    }

    func flushPendingAssistantDeltas(
        for threadId: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil
    ) {
        let normalizedTurnId = turnId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedItemId = normalizedStreamingItemID(itemId)
        let streamIDsToFlush = pendingAssistantDeltaStreamOrder.filter { streamID in
            guard let context = pendingAssistantDeltaContextByStreamID[streamID] else {
                return true
            }
            if let threadId, context.threadId != threadId {
                return false
            }
            if let normalizedTurnId, context.turnId != normalizedTurnId {
                return false
            }
            if let normalizedItemId {
                return context.itemId == normalizedItemId || context.itemId == nil
            }
            return true
        }
        if !streamIDsToFlush.isEmpty {
            let flushedStreamIDs = Set(streamIDsToFlush)

            for streamID in streamIDsToFlush {
                guard let context = pendingAssistantDeltaContextByStreamID[streamID],
                      let delta = pendingAssistantDeltaByStreamID[streamID] else {
                    pendingAssistantDeltaByStreamID.removeValue(forKey: streamID)
                    pendingAssistantDeltaContextByStreamID.removeValue(forKey: streamID)
                    continue
                }

                pendingAssistantDeltaByStreamID.removeValue(forKey: streamID)
                pendingAssistantDeltaContextByStreamID.removeValue(forKey: streamID)
                applyAssistantDeltaBatch(
                    threadId: context.threadId,
                    turnId: context.turnId,
                    itemId: context.itemId,
                    assistantPhase: context.assistantPhase,
                    delta: delta,
                    isReplay: context.isReplay
                )
            }
            pendingAssistantDeltaStreamOrder.removeAll { flushedStreamIDs.contains($0) }
        }

        if pendingAssistantDeltaByStreamID.isEmpty {
            pendingAssistantDeltaStreamOrder.removeAll()
            pendingAssistantDeltaFlushTask?.cancel()
            pendingAssistantDeltaFlushTask = nil
        } else if pendingAssistantDeltaFlushTask == nil {
            schedulePendingAssistantDeltaFlushIfNeeded()
        }
    }

    private func assistantDeltaStreamID(threadId: String, turnId: String, itemId: String?) -> String {
        let normalizedTurnId = turnId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedItemId = itemId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemComponent: String
        if let normalizedItemId, !normalizedItemId.isEmpty {
            itemComponent = normalizedItemId
        } else {
            itemComponent = "__turn__"
        }
        return "\(threadId)|\(normalizedTurnId)|\(itemComponent)"
    }

    // Reuses the sidebar "ready" signal to surface a lightweight in-app banner for off-screen chats.
    func presentThreadCompletionBannerIfNeeded(threadId: String) {
        guard let thread = thread(for: threadId), !thread.isSubagent else {
            return
        }

        threadCompletionBanner = CodexThreadCompletionBanner(
            threadId: threadId,
            title: thread.displayTitle
        )
    }

    // Bumps a thread-local revision whenever its message timeline changes.
    func noteMessagesChanged(for threadId: String) {
        messageRevisionByThread[threadId, default: 0] &+= 1
    }

    // Keeps the "latest output" cache in sync for both full refreshes and lightweight streaming updates.
    func syncLatestAssistantOutputCache(for threadId: String) -> String {
        guard let messages = messagesByThread[threadId] else {
            latestAssistantOutputByThread[threadId] = ""
            latestAssistantMessageIDByThread.removeValue(forKey: threadId)
            return ""
        }

        if let cachedMessageID = latestAssistantMessageIDByThread[threadId],
           let cachedIndex = findMessageIndex(threadId: threadId, messageId: cachedMessageID),
           messages.indices.contains(cachedIndex) {
            for index in messages[cachedIndex...].indices.reversed() {
                let candidate = messages[index]
                guard candidate.role == .assistant,
                      hasRenderableAssistantOutputText(candidate.text) else {
                    continue
                }
                latestAssistantOutputByThread[threadId] = candidate.text
                latestAssistantMessageIDByThread[threadId] = candidate.id
                return candidate.text
            }
        }

        let latestAssistant = messages
            .last(where: { $0.role == .assistant && hasRenderableAssistantOutputText($0.text) })
        let latestAssistantText = latestAssistant?.text ?? ""
        latestAssistantOutputByThread[threadId] = latestAssistantText
        latestAssistantMessageIDByThread[threadId] = latestAssistant?.id
        return latestAssistantText
    }

    // Streaming calls hit this on every delta; avoid allocating a trimmed copy for normal prose.
    func hasRenderableAssistantOutputText(_ text: String) -> Bool {
        guard let first = text.first else {
            return false
        }
        if !first.isWhitespace {
            return true
        }
        return text.contains { !$0.isWhitespace }
    }

    // Rebuilds one thread's render snapshot from service-owned caches after any timeline mutation.
    func refreshThreadTimelineState(for threadId: String) {
        // While a catch-up burst is applying replayed history, defer the rebuild
        // so the reopened thread settles in one pass at flush time
        // (finishTimelineCatchUpBurst always rebuilds unconditionally).
        if timelineCatchUpBurstThreadIDs.contains(threadId) {
            return
        }
        let state = timelineState(for: threadId)
        let messages = messagesByThread[threadId] ?? []
        let revision = messageRevisionByThread[threadId] ?? 0
        let activeTurnID = activeTurnIdByThread[threadId]
        let isThreadRunning = threadHasActiveOrRunningTurn(threadId)
        let runStartGeneration = runStartGenerationByThread[threadId] ?? 0
        let usesPaginatedHistory = supportsTurnPagination && initialTurnsLoadedByThreadID.contains(threadId)
        let projectionSourceMessages = snapshotProjectionSourceMessages(
            threadId: threadId,
            from: messages,
            usesPaginatedHistory: usesPaginatedHistory
        )
        let stoppedTurnIDs = rebuildStoppedTurnIDs(for: threadId, messages: projectionSourceMessages)
        let latestTurnTerminalState = latestTurnTerminalStateByThread[threadId]
        let projectedMessages = TurnTimelineReducer.project(messages: projectionSourceMessages).messages
        let planMatchingMessages = projectionSourceMessages.filter { $0.kind == .userInputPrompt }
        let completedTurnIDs = Set(
            projectedMessages.compactMap { message -> String? in
                guard let turnId = message.turnId,
                      turnTerminalState(for: turnId, threadId: threadId) == .completed else {
                    return nil
                }
                return turnId
            }
        )
        let repoRefreshSignal = buildRepoRefreshSignal(for: projectionSourceMessages)
        latestRepoAffectingMessageSignalByThread[threadId] = repoRefreshSignal
        let assistantRevertStates = assistantRevertStates(
            for: threadId,
            projectedMessages: projectedMessages,
            workingDirectory: gitWorkingDirectory(for: threadId),
            messageRevision: revision,
            revertStateRevision: assistantRevertStateRevision
        )
        let hasLocallyProjectedOlderHistory = hasLocallyProjectedEarlierThreadHistory(threadId: threadId)
        let hasRemoteOlderHistory = hasRemoteOlderThreadHistoryCursor(threadId: threadId)
            && !hasKnownLocalHistoryStart(threadId: threadId)
        let hasOlderHistory = hasRemoteOlderHistory || hasLocallyProjectedOlderHistory
        let isLoadingOlderHistory = loadingOlderThreadHistoryIDs.contains(threadId)
        let initialTurnsLoaded = !supportsTurnPagination || initialTurnsLoadedByThreadID.contains(threadId)
        let olderHistoryLoadErrorMessage = olderHistoryLoadErrorByThreadID[threadId]

        state.messages = messages
        state.messageRevision = revision
        state.activeTurnID = activeTurnID
        state.isThreadRunning = isThreadRunning
        state.runStartGeneration = runStartGeneration
        state.latestTurnTerminalState = latestTurnTerminalState
        state.completedTurnIDs = completedTurnIDs
        state.stoppedTurnIDs = stoppedTurnIDs
        state.repoRefreshSignal = repoRefreshSignal
        state.hasOlderHistory = hasOlderHistory
        state.hasRemoteOlderHistory = hasRemoteOlderHistory
        state.hasLocallyProjectedOlderHistory = hasLocallyProjectedOlderHistory
        state.usesPaginatedHistory = usesPaginatedHistory
        state.isLoadingOlderHistory = isLoadingOlderHistory
        state.initialTurnsLoaded = initialTurnsLoaded
        state.olderHistoryLoadErrorMessage = olderHistoryLoadErrorMessage
        state.renderSnapshot = TurnTimelineRenderSnapshot(
            threadID: threadId,
            messages: projectedMessages,
            messageIndexByID: projectedMessages.messageIndexByID(),
            planMatchingMessages: planMatchingMessages,
            timelineChangeToken: revision,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning,
            runStartGeneration: runStartGeneration,
            latestTurnTerminalState: latestTurnTerminalState,
            completedTurnIDs: completedTurnIDs,
            stoppedTurnIDs: stoppedTurnIDs,
            assistantRevertStatesByMessageID: assistantRevertStates,
            repoRefreshSignal: repoRefreshSignal,
            hasOlderHistory: hasOlderHistory,
            hasRemoteOlderHistory: hasRemoteOlderHistory,
            hasLocallyProjectedOlderHistory: hasLocallyProjectedOlderHistory,
            usesPaginatedHistory: usesPaginatedHistory,
            isLoadingOlderHistory: isLoadingOlderHistory,
            initialTurnsLoaded: initialTurnsLoaded,
            olderHistoryLoadErrorMessage: olderHistoryLoadErrorMessage
        )
    }

    // Both paginated and legacy threads use the same bounded render window. Paginated fetches
    // prepend pages into the backing cache, then this projection reveals them deliberately.
    //
    // The newest materialized turn is an exception: it is the turn a user just opened and it
    // must remain coherent even while running metadata catches up after reconnect. In particular,
    // never render just the final 80 tool/reasoning rows of a 500-row turn without its prompt.
    func snapshotProjectionSourceMessages(
        threadId: String,
        from messages: [CodexMessage],
        usesPaginatedHistory _: Bool
    ) -> [CodexMessage] {
        let limit = max(
            TurnTimelineProjectionPolicy.initialMessageLimit,
            threadTimelineProjectionLimitByThreadID[threadId] ?? TurnTimelineProjectionPolicy.initialMessageLimit
        )
        guard messages.count > limit else {
            return messages
        }

        let shouldKeepCompleteNewestTurn = threadHasActiveOrRunningTurn(threadId)
            || pendingReconnectRunContinuityThreadIDs.contains(threadId)
            || desktopMirroredRunningThreadIDs.contains(threadId)
        let visibleStartIndex = shouldKeepCompleteNewestTurn
            ? (newestMaterializedTurnStartIndex(in: messages) ?? (messages.count - limit))
            : (messages.count - limit)
        let visibleTail = Array(messages[visibleStartIndex...])
        return visibleTailPreservingTurnArtifacts(
            visibleTail: visibleTail,
            omittedPrefix: messages[..<visibleStartIndex]
        )
    }

    // Finds the opener for the newest turn represented by the local backing cache instead of
    // trusting lifecycle state alone. `turn/started` and reconnect replay can be late, stale, or
    // turnless; the newest concrete turn in chronological history is the only safe first-paint
    // anchor. Prefer its user opener, then fall back to the contiguous item block when a source
    // omitted that opener.
    func newestMaterializedTurnStartIndex(in messages: [CodexMessage]) -> Int? {
        var newestTurnID: String?
        for message in messages.reversed() {
            guard let turnID = message.turnId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !turnID.isEmpty else {
                continue
            }
            newestTurnID = turnID
            break
        }
        guard let newestTurnID else {
            return messages.lastIndex(where: { $0.role == .user })
        }

        if let openerIndex = messages.firstIndex(where: { message in
            message.role == .user
                && message.turnId?.trimmingCharacters(in: .whitespacesAndNewlines) == newestTurnID
        }) {
            return openerIndex
        }

        guard let newestItemIndex = messages.lastIndex(where: {
            $0.turnId?.trimmingCharacters(in: .whitespacesAndNewlines) == newestTurnID
        }) else {
            return messages.lastIndex(where: { $0.role == .user })
        }
        var startIndex = newestItemIndex
        while startIndex > messages.startIndex,
              messages[messages.index(before: startIndex)].turnId?
                .trimmingCharacters(in: .whitespacesAndNewlines) == newestTurnID {
            startIndex = messages.index(before: startIndex)
        }
        return startIndex
    }

    // Preserve the visible turn's prompt and durable artifacts when its tool-heavy
    // tail is larger than the 80-message first-paint window.
    func visibleTailPreservingTurnArtifacts(
        visibleTail: [CodexMessage],
        omittedPrefix: ArraySlice<CodexMessage>
    ) -> [CodexMessage] {
        let visibleTurnIDs = Set(visibleTail.compactMap { message -> String? in
            guard let turnId = message.turnId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !turnId.isEmpty else {
                return nil
            }
            return turnId
        })

        let preservedArtifactKinds: Set<CodexMessageKind> = [.fileChange, .plan]
        let visibleMessageIDs = Set(visibleTail.map(\.id))
        let missingVisibleTurnContext = omittedPrefix.filter { message in
            guard (message.role == .user || isPreservableTurnArtifact(message, kinds: preservedArtifactKinds)),
                  let turnId = message.turnId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  visibleTurnIDs.contains(turnId),
                  !visibleMessageIDs.contains(message.id) else {
                return false
            }
            return true
        }

        // Never borrow plan/file-change rows from an omitted *different* turn. That creates an
        // orphan card above the prompt and makes a partial source look like a corrupted timeline.
        let preservedContext = Array(missingVisibleTurnContext)
        guard !preservedContext.isEmpty else {
            return visibleTail
        }

        return (preservedContext + visibleTail)
            .sorted { $0.orderIndex < $1.orderIndex }
    }

    func isPreservableTurnArtifact(
        _ message: CodexMessage,
        kinds: Set<CodexMessageKind>
    ) -> Bool {
        message.role == .system && kinds.contains(message.kind)
    }

    // Refreshes every known timeline state when repo-busy status changes across threads.
    func refreshAllThreadTimelineStates() {
        for threadId in threadTimelineStateByThread.keys {
            refreshThreadTimelineState(for: threadId)
        }
    }

    // Recomputes which repos are currently busy so revert buttons update without scanning all threads per row.
    // Returns true if busy-roots actually changed and dependent timelines were refreshed.
    @discardableResult
    func refreshBusyRepoRootsAndDependentTimelineStates() -> Bool {
        let previousBusyRepoRoots = busyRepoRoots
        let nextBusyRepoRoots = Set(
            threads.compactMap { thread -> String? in
                guard runningThreadIDs.contains(thread.id)
                    || activeTurnIdByThread[thread.id] != nil
                    || protectedRunningFallbackThreadIDs.contains(thread.id) else {
                    return nil
                }

                return canonicalRepoIdentifier(for: thread.gitWorkingDirectory) ?? thread.gitWorkingDirectory
            }
        )

        guard nextBusyRepoRoots != previousBusyRepoRoots else {
            return false
        }

        busyRepoRoots = nextBusyRepoRoots
        busyRepoRootsRevision &+= 1

        // Only refresh threads whose repo is in the changed set, not all threads.
        let changedRoots = previousBusyRepoRoots.symmetricDifference(nextBusyRepoRoots)
        let workingDirByThread: [String: String?] = Dictionary(
            uniqueKeysWithValues: threads.map { ($0.id, $0.gitWorkingDirectory) }
        )
        for threadId in threadTimelineStateByThread.keys {
            let workingDir = workingDirByThread[threadId] ?? nil
            let repoId = canonicalRepoIdentifier(for: workingDir) ?? workingDir
            guard let repoId, changedRoots.contains(repoId) else { continue }
            refreshThreadTimelineState(for: threadId)
        }
        return true
    }

    // Keeps stopped-turn lookup thread-local so scroll/render code never rescans full transcripts.
    func rebuildStoppedTurnIDs(for threadId: String, messages: [CodexMessage]) -> Set<String> {
        let stoppedTurnIDs = Set(
            messages.compactMap(\.turnId)
                .filter { turnTerminalState(for: $0, threadId: threadId) == .stopped }
        )
        stoppedTurnIDsByThread[threadId] = stoppedTurnIDs
        return stoppedTurnIDs
    }

    // Merges terminal states decoded from thread/read without firing haptics or unread badges.
    @discardableResult
    func mergeHistoryTurnTerminalStates(
        threadId: String,
        terminalStatesByTurnID historyStates: [String: CodexTurnTerminalState]
    ) -> Bool {
        guard !historyStates.isEmpty else {
            return false
        }

        var didChange = false
        var didChangePersistedState = false
        for (turnId, state) in historyStates {
            // Desktop-projected ids are only unique within their thread. Hydrate
            // their volatile thread-scoped cache without poisoning persistence.
            if CodexSyntheticIdentifiers.isProjectedDesktopTurnID(turnId) {
                guard projectedTerminalStateByThreadID[threadId]?[turnId] != state else { continue }
                projectedTerminalStateByThreadID[threadId, default: [:]][turnId] = state
                didChange = true
                continue
            }
            guard terminalStateByTurnID[turnId] != state else { continue }
            terminalStateByTurnID[turnId] = state
            didChange = true
            didChangePersistedState = true
        }

        if didChangePersistedState {
            persistTurnTerminalStates()
        }
        return didChange
    }

    // Tracks the latest repo-affecting system row so git refresh logic can stay out of the view body.
    func buildRepoRefreshSignal(for messages: [CodexMessage]) -> String? {
        guard let latestRepoMessage = messages.last(where: { message in
            guard message.role == .system else { return false }
            return message.kind == .fileChange || message.kind == .commandExecution
        }) else {
            return nil
        }

        return "\(latestRepoMessage.id)|\(latestRepoMessage.text.count)|\(latestRepoMessage.isStreaming)"
    }

    // Reuses a thread-local cache so assistant revert buttons only rebuild when timeline or repo-busy state changes.
    func assistantRevertStates(
        for threadId: String,
        projectedMessages: [CodexMessage],
        workingDirectory: String?,
        messageRevision: Int,
        revertStateRevision: Int
    ) -> [String: AssistantRevertPresentation] {
        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheWorkingDirectory = trimmedWorkingDirectory?.isEmpty == false ? trimmedWorkingDirectory : nil
        if let cached = assistantRevertStateCacheByThread[threadId],
           cached.messageRevision == messageRevision,
           cached.busyRepoRevision == busyRepoRootsRevision,
           cached.revertStateRevision == revertStateRevision,
           cached.workingDirectory == cacheWorkingDirectory {
            return cached.statesByMessageID
        }

        let statesByMessageID = projectedMessages.reduce(into: [String: AssistantRevertPresentation]()) {
            partialResult, message in
            if let presentation = assistantRevertPresentation(
                for: message,
                workingDirectory: workingDirectory
            ) {
                partialResult[message.id] = presentation
            }
        }

        assistantRevertStateCacheByThread[threadId] = AssistantRevertStateCacheEntry(
            messageRevision: messageRevision,
            busyRepoRevision: busyRepoRootsRevision,
            revertStateRevision: revertStateRevision,
            workingDirectory: cacheWorkingDirectory,
            statesByMessageID: statesByMessageID
        )
        return statesByMessageID
    }

    // Invalidates revert presentations globally because sibling threads can change file-overlap risk.
    func invalidateAssistantRevertStates() {
        invalidateAssistantRevertStatesWithoutRefresh()
        scheduleCoalescedRevertRefresh()
    }

    // Bumps the revert revision and clears cache without triggering a full timeline refresh.
    // Callers that already perform their own refresh (e.g. rememberRepoRoot) use this to avoid double work.
    func invalidateAssistantRevertStatesWithoutRefresh() {
        assistantRevertStateRevision &+= 1
        assistantRevertStateCacheByThread.removeAll(keepingCapacity: true)
    }

    // Coalesces multiple revert invalidation calls within the same run loop tick into a single
    // refreshAllThreadTimelineStates(). The Task yields once, so back-to-back callers collapse.
    func scheduleCoalescedRevertRefresh() {
        coalescedRevertRefreshTask?.cancel()
        coalescedRevertRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.refreshAllThreadTimelineStates()
        }
    }

    // Mirrors the stop-button teardown moment with a single success haptic when a live run really finishes.
    func triggerRunCompletionHapticIfNeeded(
        threadId: String,
        state: CodexTurnTerminalState,
        previousState: CodexTurnTerminalState?
    ) {
        // Always consume the pending marker so stopped/failed turns don't leak.
        let wasPending = threadsPendingCompletionHaptic.remove(threadId) != nil
        guard state == .completed,
              previousState != .completed,
              isAppInForeground,
              wasPending else {
            return
        }

        HapticFeedback.shared.triggerNotificationFeedback(type: .success)
    }

    // Late activity notifications can arrive after turn/completed.
    // Keep thinking rows in streaming mode only while the turn is still active.
    func isTurnActiveForThinkingActivity(threadId: String, turnId: String?) -> Bool {
        if let turnId, !turnId.isEmpty {
            if activeTurnIdByThread[threadId] == turnId {
                return true
            }
            return activeTurnIdByThread[threadId] == nil && runningThreadIDs.contains(threadId)
        }
        return activeTurnIdByThread[threadId] != nil || runningThreadIDs.contains(threadId)
    }

    func thinkingActivityTargetIndex(in messages: [CodexMessage], turnId: String?) -> Int? {
        messages.indices.reversed().first { index in
            let candidate = messages[index]
            guard candidate.role == .system, candidate.kind == .thinking else {
                return false
            }

            if let turnId, !turnId.isEmpty {
                return candidate.turnId == turnId || candidate.turnId == nil
            }

            return candidate.isStreaming
        }
    }

    // Avoids temporary array allocations from split/map when deduping activity lines.
    func containsCaseInsensitiveLine(_ candidateLine: String, in text: String) -> Bool {
        var found = false
        text.enumerateLines { line, stop in
            if line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(candidateLine) == .orderedSame {
                found = true
                stop = true
            }
        }
        return found
    }

    func appendMessage(_ message: CodexMessage) {
        var normalizedMessage = message
        if isApplyingReplayedBridgeEvent {
            normalizedMessage.isStreaming = false
        }
        normalizedMessage.proposedPlan = derivedProposedPlan(for: normalizedMessage)
        if normalizedMessage.isStreaming {
            // Keep sidebar run state independent from timeline scanning cost.
            // Replayed catch-up batches append text without reviving running state.
            markThreadAsRunning(normalizedMessage.threadId)
        }
        if normalizedMessage.role == .assistant,
           let existingIndex = existingMessageIndexForAppend(
               threadId: message.threadId,
               messageId: normalizedMessage.id
           ),
           let existingMessage = messagesByThread[message.threadId]?[existingIndex] {
            let activeThreadIDs = Set(activeTurnIdByThread.keys)
            let activeTurnIDs = Set(activeTurnIdByThread.values)
            let merged = Self.reconcileExistingMessage(
                existingMessage,
                with: normalizedMessage,
                activeThreadIDs: activeThreadIDs,
                activeTurnIDs: activeTurnIDs,
                runningThreadIDs: runningThreadIDs
            )
            messagesByThread[message.threadId]?[existingIndex] = merged
            persistMessages()
            updateCurrentOutput(for: message.threadId)
            return
        }
        messagesByThread[message.threadId, default: []].append(normalizedMessage)
        messagesByThread[message.threadId]?.sortByOrderIndexIfNeeded()
        persistMessages()
        updateCurrentOutput(for: message.threadId)
    }

    // O(1) probe through the shared index cache for the assistant reconcile branch of
    // appendMessage. findMessageIndex is unsuitable there: a brand-new id (the common
    // append case) would trigger a full index rebuild per append. Cache hits are
    // verified by id; a miss falls back to one linear scan and backfills the cache so
    // repeated updates to the same row (replay bursts) stay O(1).
    private func existingMessageIndexForAppend(threadId: String, messageId: String) -> Int? {
        guard let messages = messagesByThread[threadId], !messages.isEmpty else {
            return nil
        }

        if let cachedIndex = messageIndexCacheByThread[threadId]?[messageId],
           messages.indices.contains(cachedIndex),
           messages[cachedIndex].id == messageId {
            return cachedIndex
        }

        guard let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return nil
        }
        if messageIndexCacheByThread[threadId] != nil {
            messageIndexCacheByThread[threadId]?[messageId] = index
        }
        return index
    }

    private func refreshDerivedPlanMetadata(threadId: String, messageIndex: Int) {
        guard let message = messagesByThread[threadId]?[messageIndex] else {
            return
        }

        messagesByThread[threadId]?[messageIndex].proposedPlan = derivedProposedPlan(for: message)
    }

    private func refreshDerivedPlanMetadata(in messages: inout [CodexMessage], index: Int) {
        guard messages.indices.contains(index) else {
            return
        }

        messages[index].proposedPlan = derivedProposedPlan(for: messages[index])
    }

    private func derivedProposedPlan(for message: CodexMessage) -> CodexProposedPlan? {
        guard message.text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return nil
        }

        if message.role == .system && message.kind == .plan {
            guard let presentation = message.resolvedPlanPresentation,
                  presentation == .resultCompletedItem || presentation == .resultReady else {
                return nil
            }

            return CodexProposedPlanParser.parsePlanItem(from: message.text)
        }

        return CodexProposedPlanParser.parse(from: message.text)
    }

    func findMessageIndex(threadId: String, messageId: String) -> Int? {
        guard let messages = messagesByThread[threadId] else {
            return nil
        }

        if let cachedIndex = messageIndexCacheByThread[threadId]?[messageId],
           messages.indices.contains(cachedIndex),
           messages[cachedIndex].id == messageId {
            return cachedIndex
        }

        // Cache miss/stale. A freshly appended row sits at the tail: patch just that
        // entry in place and keep the rest of the (append-stable) cache — O(1), the
        // streaming hot path. Any other miss means the array shifted (mid insert/remove)
        // or the thread has no cache yet, so rebuild the whole index once; that keeps
        // later lookups in the same operation (e.g. markTurnCompleted's filter loop after
        // it prunes thinking rows) O(1) hits instead of repeated O(n) self-heals.
        if messageIndexCacheByThread[threadId] != nil,
           let last = messages.last,
           last.id == messageId {
            let index = messages.count - 1
            messageIndexCacheByThread[threadId]?[messageId] = index
            return index
        }

        let rebuiltIndex = messages.messageIndexByID()
        messageIndexCacheByThread[threadId] = rebuiltIndex
        return rebuiltIndex[messageId]
    }

    // Reuses a caller-provided index when still valid, otherwise falls back to the cached lookup map.
    func resolvedMessageIndex(
        threadId: String,
        messageId: String,
        preferredIndex: Int?,
        in messages: [CodexMessage]
    ) -> Int? {
        if let preferredIndex,
           messages.indices.contains(preferredIndex),
           messages[preferredIndex].id == messageId {
            return preferredIndex
        }

        return findMessageIndex(threadId: threadId, messageId: messageId)
    }

    func findLatestPlanMessageIndex(
        threadId: String,
        turnId: String?,
        itemId: String?,
        planPresentation: CodexPlanPresentation
    ) -> Int? {
        if let itemId, !itemId.isEmpty {
            if let directIndex = messagesByThread[threadId]?.indices.reversed().first(where: { index in
                let candidate = messagesByThread[threadId]?[index]
                return candidate?.role == .system
                    && candidate?.kind == .plan
                    && candidate?.itemId == itemId
            }) {
                return directIndex
            }
        }

        if let turnId, !turnId.isEmpty {
            return messagesByThread[threadId]?.indices.reversed().first(where: { index in
                let candidate = messagesByThread[threadId]?[index]
                return candidate?.role == .system
                    && candidate?.kind == .plan
                    && candidate?.turnId == turnId
                    && candidate?.resolvedPlanPresentation == planPresentation
            })
        }

        return messagesByThread[threadId]?.indices.reversed().first(where: { index in
            let candidate = messagesByThread[threadId]?[index]
            return candidate?.role == .system
                && candidate?.kind == .plan
                && candidate?.resolvedPlanPresentation == planPresentation
        })
    }

    private func resolvedPlanPresentation(
        requested: CodexPlanPresentation,
        turnId: String?,
        threadId: String
    ) -> CodexPlanPresentation {
        guard requested == .resultCompletedItem else {
            return requested
        }

        switch turnTerminalState(for: turnId, threadId: threadId) {
        case .completed:
            return .resultReady
        case .failed, .stopped:
            return .resultClosed
        case nil:
            return .resultCompletedItem
        }
    }

    func findLatestSubagentActionMessageIndex(threadId: String, turnId: String?, itemId: String?) -> Int? {
        if let itemId, !itemId.isEmpty {
            if let directIndex = messagesByThread[threadId]?.indices.reversed().first(where: { index in
                let candidate = messagesByThread[threadId]?[index]
                return candidate?.role == .system
                    && candidate?.kind == .subagentAction
                    && candidate?.itemId == itemId
            }) {
                return directIndex
            }
        }

        if let turnId, !turnId.isEmpty {
            return messagesByThread[threadId]?.indices.reversed().first(where: { index in
                let candidate = messagesByThread[threadId]?[index]
                return candidate?.role == .system
                    && candidate?.kind == .subagentAction
                    && candidate?.turnId == turnId
            })
        }

        return messagesByThread[threadId]?.indices.reversed().first(where: { index in
            let candidate = messagesByThread[threadId]?[index]
            return candidate?.role == .system && candidate?.kind == .subagentAction
        })
    }

    func ensureStreamingAssistantMessage(
        threadId: String,
        turnId: String,
        itemId: String?,
        assistantPhase: String? = nil,
        promoteTurnFallback: Bool = true,
        createStreamingMessage: Bool = true
    ) -> String? {
        let turnStreamingKey = streamingMessageKey(threadId: threadId, turnId: turnId)
        let normalizedItemId = normalizedStreamingItemID(itemId)
        let normalizedPhase = normalizedAssistantPhase(assistantPhase)
        let itemStreamingKey = normalizedItemId.map {
            assistantStreamingMessageKey(threadId: threadId, turnId: turnId, itemId: $0)
        }

        if let itemStreamingKey,
           let messageID = streamingAssistantMessageByItemKey[itemStreamingKey],
           let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) {
            // Keep turn-scoped fallback deltas anchored to the newest assistant item.
            // Late updates for older item ids should patch that item only.
            applyAssistantPhaseIfNeeded(
                threadId: threadId,
                messageIndex: messageIndex,
                assistantPhase: normalizedPhase
            )
            return messageID
        }

        // Transport recovery clears the volatile lookup maps after closing live rows. Buffered
        // replay can then resume with the same provider item id; reconnect that identity to the
        // persisted row instead of creating a second assistant bubble for the replayed delta.
        if let normalizedItemId,
           let itemStreamingKey,
           let persistedMessage = messagesByThread[threadId]?
               .filter({ candidate in
                   guard candidate.role == .assistant,
                         normalizedStreamingItemID(candidate.itemId) == normalizedItemId else {
                       return false
                   }
                   return candidate.turnId == turnId || candidate.turnId == nil
               })
               .min(by: { $0.orderIndex < $1.orderIndex }),
           let messageIndex = findMessageIndex(threadId: threadId, messageId: persistedMessage.id) {
            if messagesByThread[threadId]?[messageIndex].turnId == nil {
                messagesByThread[threadId]?[messageIndex].turnId = turnId
            }
            applyAssistantPhaseIfNeeded(
                threadId: threadId,
                messageIndex: messageIndex,
                assistantPhase: normalizedPhase
            )
            streamingAssistantMessageByItemKey[itemStreamingKey] = persistedMessage.id
            return persistedMessage.id
        }

        if let turnMessageID = streamingAssistantFallbackMessageByTurnID[turnStreamingKey],
           let messageIndex = findMessageIndex(threadId: threadId, messageId: turnMessageID) {
            if let normalizedItemId {
                let existingItemId = normalizedStreamingItemID(messagesByThread[threadId]?[messageIndex].itemId)

                if existingItemId == nil {
                    messagesByThread[threadId]?[messageIndex].itemId = normalizedItemId
                    applyAssistantPhaseIfNeeded(
                        threadId: threadId,
                        messageIndex: messageIndex,
                        assistantPhase: normalizedPhase
                    )
                    if let itemStreamingKey {
                        streamingAssistantMessageByItemKey[itemStreamingKey] = turnMessageID
                    }
                    persistMessages()
                    updateCurrentOutput(for: threadId)
                    return turnMessageID
                }

                if existingItemId == normalizedItemId {
                    applyAssistantPhaseIfNeeded(
                        threadId: threadId,
                        messageIndex: messageIndex,
                        assistantPhase: normalizedPhase
                    )
                    if let itemStreamingKey {
                        streamingAssistantMessageByItemKey[itemStreamingKey] = turnMessageID
                    }
                    return turnMessageID
                }

                guard promoteTurnFallback else {
                    return createAssistantMessage(
                        threadId: threadId,
                        turnId: turnId,
                        itemId: normalizedItemId,
                        assistantPhase: normalizedPhase,
                        isStreaming: createStreamingMessage,
                        promoteTurnFallback: false
                    )
                }

                // New assistant item in the same turn: close previous row and start a new bubble.
                messagesByThread[threadId]?[messageIndex].isStreaming = false
                streamingAssistantFallbackMessageByTurnID.removeValue(forKey: turnStreamingKey)
                persistMessages()
                updateCurrentOutput(for: threadId)

                beginAssistantMessage(
                    threadId: threadId,
                    turnId: turnId,
                    itemId: normalizedItemId,
                    assistantPhase: normalizedPhase
                )
                if let itemStreamingKey,
                   let messageID = streamingAssistantMessageByItemKey[itemStreamingKey] {
                    streamingAssistantFallbackMessageByTurnID[turnStreamingKey] = messageID
                    return messageID
                }
                return streamingAssistantFallbackMessageByTurnID[turnStreamingKey]
            }

            return turnMessageID
        } else {
            streamingAssistantFallbackMessageByTurnID.removeValue(forKey: turnStreamingKey)
        }

        let messageID = createAssistantMessage(
            threadId: threadId,
            turnId: turnId,
            itemId: normalizedItemId,
            assistantPhase: normalizedPhase,
            isStreaming: createStreamingMessage,
            promoteTurnFallback: promoteTurnFallback
        )
        return messageID
    }

    // Creates one assistant bubble and records item/turn lookup keys without letting
    // late item-specific completions overwrite the active turn fallback.
    func createAssistantMessage(
        threadId: String,
        turnId: String,
        itemId: String?,
        assistantPhase: String? = nil,
        isStreaming: Bool,
        promoteTurnFallback: Bool
    ) -> String {
        let effectiveIsStreaming = isStreaming && !isApplyingReplayedBridgeEvent
        let turnStreamingKey = streamingMessageKey(threadId: threadId, turnId: turnId)
        let itemStreamingKey = itemId.map {
            assistantStreamingMessageKey(threadId: threadId, turnId: turnId, itemId: $0)
        }
        let message = CodexMessage(
            id: Self.stableAssistantMessageID(threadId: threadId, turnId: turnId, itemId: itemId) ?? UUID().uuidString,
            threadId: threadId,
            role: .assistant,
            assistantPhase: normalizedAssistantPhase(assistantPhase),
            text: "",
            turnId: turnId,
            itemId: itemId,
            isStreaming: effectiveIsStreaming
        )

        threadIdByTurnID[turnId] = threadId
        if promoteTurnFallback {
            streamingAssistantFallbackMessageByTurnID[turnStreamingKey] = message.id
        }
        if let itemStreamingKey {
            streamingAssistantMessageByItemKey[itemStreamingKey] = message.id
        }
        appendMessage(message)
        return message.id
    }

    // Clears assistant stream lookup state for one turn and closes each touched bubble once.
    func clearAssistantStreamingState(threadId: String, turnId: String) {
        let turnStreamingKey = streamingMessageKey(threadId: threadId, turnId: turnId)
        let itemStreamingPrefix = "\(turnStreamingKey)|item:"

        var closedMessageIDs: Set<String> = []
        if let messageID = streamingAssistantFallbackMessageByTurnID.removeValue(forKey: turnStreamingKey) {
            closedMessageIDs.insert(messageID)
            if let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) {
                messagesByThread[threadId]?[messageIndex].isStreaming = false
            }
        }

        let itemKeysToClear = streamingAssistantMessageByItemKey.keys.filter { key in
            key.hasPrefix(itemStreamingPrefix)
        }
        for key in itemKeysToClear {
            guard let messageID = streamingAssistantMessageByItemKey.removeValue(forKey: key) else { continue }
            guard closedMessageIDs.insert(messageID).inserted else {
                continue
            }
            if let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) {
                messagesByThread[threadId]?[messageIndex].isStreaming = false
            }
        }
    }

    func streamingMessageKey(threadId: String, turnId: String) -> String {
        "\(threadId)|\(turnId)"
    }

    func assistantStreamingMessageKey(threadId: String, turnId: String, itemId: String) -> String {
        "\(streamingMessageKey(threadId: threadId, turnId: turnId))|item:\(itemId)"
    }

    func completedAssistantMessageIndices(threadId: String, turnId: String) -> [Int] {
        guard let threadMessages = messagesByThread[threadId] else {
            return []
        }

        return threadMessages.indices.filter { index in
            let candidate = threadMessages[index]
            return candidate.role == .assistant
                && candidate.turnId == turnId
                && !candidate.isStreaming
        }
    }

    // Identifier-less completion events can arrive after the next turn already became active.
    // If they exactly match a closed prior assistant row, treat them as late replay.
    func shouldIgnoreIdentifierlessAssistantCompletion(
        threadId: String,
        text: String,
        activeTurnId: String?,
        now: Date
    ) -> Bool {
        if let fingerprint = assistantCompletionFingerprintByThread[threadId],
           fingerprint.text == text,
           now.timeIntervalSince(fingerprint.timestamp) <= 45 {
            return true
        }

        guard let activeTurnId = normalizedStreamingItemID(activeTurnId),
              let threadMessages = messagesByThread[threadId] else {
            return false
        }

        let activeTurnHasSameAssistant = threadMessages.contains { candidate in
            candidate.role == .assistant
                && candidate.turnId == activeTurnId
                && Self.normalizedMessageText(candidate.text) == text
        }
        if activeTurnHasSameAssistant {
            return false
        }

        guard let latestActiveUserOrder = threadMessages
            .filter({ $0.role == .user && $0.turnId == activeTurnId })
            .map(\.orderIndex)
            .max() else {
            return false
        }

        return threadMessages.contains { candidate in
            candidate.role == .assistant
                && candidate.turnId != activeTurnId
                && !candidate.isStreaming
                && candidate.orderIndex < latestActiveUserOrder
                && Self.normalizedMessageText(candidate.text) == text
        }
    }

    func streamingItemMessageKey(threadId: String, itemId: String) -> String {
        "\(threadId)|item:\(itemId)"
    }

    func normalizedStreamingItemID(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func syntheticStreamingItemId(turnId: String, kind: CodexMessageKind) -> String {
        CodexSyntheticIdentifiers.placeholderItemID(turnId: turnId, kind: kind)
    }

    func syntheticSubagentActionItemIdPrefix(turnId: String) -> String {
        CodexSyntheticIdentifiers.placeholderItemID(turnId: turnId, kind: .subagentAction) + "|action:"
    }

    func streamingPlaceholderText(for kind: CodexMessageKind) -> String {
        switch kind {
        case .thinking:
            return ""
        case .toolActivity:
            return "Working…"
        case .fileChange:
            return "Applying file changes..."
        case .commandExecution:
            return "Running command"
        case .subagentAction:
            return "Coordinating agents..."
        case .plan:
            return "Planning..."
        case .userInputPrompt:
            return "Waiting for input..."
        case .autoApprovalReview:
            return "Reviewing approval..."
        case .chat:
            return "Updating..."
        }
    }

    func isStreamingPlaceholder(_ text: String, for kind: CodexMessageKind) -> Bool {
        guard text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return false
        }
        return Self.normalizedMessageText(text)
            .caseInsensitiveCompare(streamingPlaceholderText(for: kind)) == .orderedSame
    }

    // Prunes only empty/placeholder thinking rows, preserving real reasoning text.
    func shouldPruneThinkingRowAfterTurnCompletion(_ message: CodexMessage) -> Bool {
        guard Self.hasMeaningfulHistoryText(message.text) else {
            return true
        }
        guard message.text.utf8.count <= MessageTextProcessingPolicy.largeTextByteLimit else {
            return false
        }
        let trimmedText = Self.normalizedMessageText(message.text)

        if isStreamingPlaceholder(trimmedText, for: .thinking) {
            return true
        }

        let withoutPrefix = trimmedText.replacingOccurrences(
            of: #"(?is)^\s*thinking(?:\.\.\.)?\s*"#,
            with: "",
            options: .regularExpression
        )
        return withoutPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Supports both incremental deltas ("+ token") and cumulative snapshots
    // ("full content so far"), while discarding duplicate chunks.
    func mergeAssistantDelta(existingText: String, incomingDelta: String) -> String {
        if existingText.isEmpty {
            return incomingDelta
        }

        if incomingDelta == existingText {
            return existingText
        }

        if existingText.hasSuffix(incomingDelta) {
            return existingText
        }

        if incomingDelta.count > existingText.count, incomingDelta.hasPrefix(existingText) {
            return incomingDelta
        }

        if existingText.count > incomingDelta.count, existingText.hasPrefix(incomingDelta) {
            return existingText
        }

        // Preserve reconnect/replay correctness by checking the full overlap window.
        let maxOverlap = min(existingText.count, incomingDelta.count)
        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                if existingText.suffix(overlap) == incomingDelta.prefix(overlap) {
                    return existingText + incomingDelta.dropFirst(overlap)
                }
            }
        }

        return existingText + incomingDelta
    }

}
