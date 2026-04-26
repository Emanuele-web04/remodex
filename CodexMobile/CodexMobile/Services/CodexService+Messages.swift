// FILE: CodexService+Messages.swift
// Purpose: Owns per-thread message timelines, streaming merge logic, and persistence.
// Layer: Service
// Exports: CodexService message APIs
// Depends on: CodexMessage, JSONValue

import Foundation
import UIKit

private enum TurnTimelineProjectionPolicy {
    // Long chats can contain thousands of persisted rows. Keep initial/open-chat projection
    // bounded to the recent tail so selecting one thread does not freeze the whole screen.
    static let rawMessageLimit = 400
    static let eagerHydrationMessageLimit = 400
}

private enum CanonicalHistoryReconcileRetryPolicy {
    // Transient thread/read failures should self-heal, but with a small delay so we do not
    // spin aggressively when the bridge or socket is still recovering.
    static let transientErrorDelayNanoseconds: UInt64 = 1_500_000_000
}

private enum StreamingDeltaCoalescingPolicy {
    // One display-frame worth of buffering keeps streaming lively while reducing UI invalidations.
    static let flushDelayNanoseconds: UInt64 = 16_000_000
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
}

extension CodexService {
    enum ThreadHistoryLoadOutcome: Equatable {
        case alreadyHydrated
        case notMaterialized
        case skippedForRunningThread
        case loadedCanonicalHistory
        case loadedRecentWindow

        var didCompleteCanonicalReconcile: Bool {
            self == .loadedCanonicalHistory
        }

        var needsCanonicalRetry: Bool {
            self == .loadedRecentWindow || self == .skippedForRunningThread
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

        if shouldSkipInitialDisplayHydration(
            threadId: threadId,
            hasVisibleMessages: hasVisibleMessages,
            isThreadRunning: isThreadRunning
        ) || shouldShowImmediateEmptyPlaceholder(
            threadId: threadId,
            hasVisibleMessages: hasVisibleMessages,
            isThreadRunning: isThreadRunning
        ) {
            return .empty
        }

        if loadingThreadIDs.contains(threadId) {
            return .loading
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
        messageIndexCacheByThread.removeValue(forKey: threadId)
        latestAssistantOutputByThread.removeValue(forKey: threadId)
        latestAssistantMessageIDByThread.removeValue(forKey: threadId)
        latestRepoAffectingMessageSignalByThread.removeValue(forKey: threadId)
        assistantRevertStateCacheByThread.removeValue(forKey: threadId)
        cancelPendingStreamingDeltaFlushes(for: threadId)
        threadsPendingCompletionHaptic.remove(threadId)
        threadsNeedingCanonicalHistoryReconcile.remove(threadId)
        threadsWithSatisfiedDeferredHistoryHydration.remove(threadId)
        canonicalHistoryReconcileTaskByThreadID[threadId]?.cancel()
        canonicalHistoryReconcileTaskByThreadID.removeValue(forKey: threadId)
        canonicalHistoryReconcileRetryTaskByThreadID[threadId]?.cancel()
        canonicalHistoryReconcileRetryTaskByThreadID.removeValue(forKey: threadId)
        cancelPerThreadRefreshWork(for: threadId)
    }

    // Clears every service-owned timeline cache during global teardown.
    func removeAllThreadTimelineState() {
        threadTimelineStateByThread.removeAll()
        stoppedTurnIDsByThread.removeAll()
        messageIndexCacheByThread.removeAll()
        latestAssistantOutputByThread.removeAll()
        latestAssistantMessageIDByThread.removeAll()
        latestRepoAffectingMessageSignalByThread.removeAll()
        assistantRevertStateCacheByThread.removeAll()
        cancelAllPendingStreamingDeltaFlushes()
        threadsNeedingCanonicalHistoryReconcile.removeAll()
        threadsWithSatisfiedDeferredHistoryHydration.removeAll()
        canonicalHistoryReconcileTaskByThreadID.values.forEach { $0.cancel() }
        canonicalHistoryReconcileTaskByThreadID.removeAll()
        canonicalHistoryReconcileRetryTaskByThreadID.values.forEach { $0.cancel() }
        canonicalHistoryReconcileRetryTaskByThreadID.removeAll()
        cancelAllPerThreadRefreshWork()
    }

    // Refreshes the derived output cache and bumps the thread timeline revision.
    func updateCurrentOutput(for threadId: String) {
        noteMessagesChanged(for: threadId)

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
            latestTurnTerminalState: state.renderSnapshot.latestTurnTerminalState,
            completedTurnIDs: state.renderSnapshot.completedTurnIDs,
            stoppedTurnIDs: state.renderSnapshot.stoppedTurnIDs,
            assistantRevertStatesByMessageID: state.renderSnapshot.assistantRevertStatesByMessageID,
            repoRefreshSignal: state.renderSnapshot.repoRefreshSignal
        )
    }

    // Patches an already-projected streaming system row without rerunning the reducer.
    func updateStreamingSystemOutput(for threadId: String, messageId: String, rawMessageIndex: Int? = nil) {
        noteMessagesChanged(for: threadId)

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
            latestTurnTerminalState: state.renderSnapshot.latestTurnTerminalState,
            completedTurnIDs: state.renderSnapshot.completedTurnIDs,
            stoppedTurnIDs: state.renderSnapshot.stoppedTurnIDs,
            assistantRevertStatesByMessageID: state.renderSnapshot.assistantRevertStatesByMessageID,
            repoRefreshSignal: state.renderSnapshot.repoRefreshSignal
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

    // Clears running/fallback flags together when a thread finishes or disappears.
    func clearRunningState(for threadId: String) {
        runningThreadIDs.remove(threadId)
        protectedRunningFallbackThreadIDs.remove(threadId)
        clearMirroredRunningCatchupNeeded(for: threadId)
        refreshBusyRepoRootsAndDependentTimelineStates()
        refreshThreadTimelineState(for: threadId)
        scheduleCanonicalHistoryReconcileIfNeeded(for: threadId)
    }

    // Clears every running marker during disconnect/cleanup so stale repo-busy state cannot leak.
    func clearAllRunningState() {
        runningThreadIDs.removeAll()
        protectedRunningFallbackThreadIDs.removeAll()
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
        guard threadsNeedingCanonicalHistoryReconcile.contains(threadId),
              canonicalHistoryReconcileTaskByThreadID[threadId] == nil,
              canonicalHistoryReconcileRetryTaskByThreadID[threadId] == nil,
              isConnected,
              !threadHasActiveOrRunningTurn(threadId),
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
                        self?.scheduleCanonicalHistoryReconcileIfNeeded(for: threadId)
                    }
                }
            }

            guard let self,
                  self.threadsNeedingCanonicalHistoryReconcile.contains(threadId),
                  self.isConnected,
                  !self.threadHasActiveOrRunningTurn(threadId),
                  self.thread(for: threadId)?.syncState == .live else {
                return
            }

            do {
                let outcome = try await self.loadThreadHistoryIfNeeded(threadId: threadId, forceRefresh: true)
                guard !Task.isCancelled else { return }
                if outcome.didCompleteCanonicalReconcile {
                    self.markThreadCanonicalHistoryReconciled(threadId)
                } else if outcome.needsCanonicalRetry,
                          self.threadsNeedingCanonicalHistoryReconcile.contains(threadId),
                          self.isConnected,
                          !self.threadHasActiveOrRunningTurn(threadId),
                          self.thread(for: threadId)?.syncState == .live {
                    shouldRetry = true
                }
            } catch is CancellationError {
                return
            } catch {
                if self.shouldTreatAsThreadNotFound(error) {
                    self.threadsNeedingCanonicalHistoryReconcile.remove(threadId)
                    self.threadsWithSatisfiedDeferredHistoryHydration.remove(threadId)
                    self.handleMissingThread(threadId)
                } else if self.threadsNeedingCanonicalHistoryReconcile.contains(threadId),
                          self.isConnected,
                          !self.threadHasActiveOrRunningTurn(threadId),
                          self.thread(for: threadId)?.syncState == .live {
                    shouldRetry = true
                    retryDelayNanoseconds = CanonicalHistoryReconcileRetryPolicy.transientErrorDelayNanoseconds
                }
            }
        }
    }

    // Marks a large chat as "local-first for now, but still needs one authoritative server merge".
    func markThreadNeedingCanonicalHistoryReconcile(
        _ threadId: String,
        requestImmediateSync: Bool = false
    ) {
        threadsWithSatisfiedDeferredHistoryHydration.remove(threadId)
        threadsNeedingCanonicalHistoryReconcile.insert(threadId)
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
            return
        }

        threadsNeedingCanonicalHistoryReconcile.remove(threadId)
        threadsWithSatisfiedDeferredHistoryHydration.insert(threadId)
    }

    // Returns the latest real terminal outcome seen for a thread.
    func latestTurnTerminalState(for threadId: String) -> CodexTurnTerminalState? {
        latestTurnTerminalStateByThread[threadId]
    }

    // Returns the terminal outcome for a specific turn when known.
    func turnTerminalState(for turnId: String?) -> CodexTurnTerminalState? {
        guard let turnId else { return nil }
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
        state: CodexTurnTerminalState
    ) {
        let previousState = latestTurnTerminalStateByThread[threadId]
        latestTurnTerminalStateByThread[threadId] = state
        if let turnId {
            terminalStateByTurnID[turnId] = state
        }
        refreshThreadTimelineState(for: threadId)
        triggerRunCompletionHapticIfNeeded(
            threadId: threadId,
            state: state,
            previousState: previousState
        )
    }

    // Sets the active thread and lazily hydrates old messages from server history.
    @discardableResult
    func prepareThreadForDisplay(threadId: String) async -> Bool {
        activeThreadId = threadId
        markThreadAsViewed(threadId)
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
            // the forced resume for throttling or a transient refresh failure.
            if catchupOutcome.didRunForcedResume {
                shouldRequestImmediateSync = false
            }
            updateCurrentOutput(for: threadId)
        }
        guard !Task.isCancelled, activeThreadId == threadId else {
            return false
        }
        if shouldRequestImmediateSync {
            requestImmediateActiveThreadSync(threadId: threadId)
        }
        return true
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
    }

    // Loads thread/read(includeTurns=true) once per thread to backfill old messages.
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
        if !forceRefresh, hydratedThreadIDs.contains(threadId) {
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
            loadingThreadIDs.insert(threadId)
            defer {
                // Only clear bookkeeping for the latest refresh generation.
                if isPerThreadRefreshCurrent(for: threadId, generation: refreshGeneration) {
                    loadingThreadIDs.remove(threadId)
                    threadHistoryLoadTaskByThreadID.removeValue(forKey: threadId)
                    forcedHistoryLoadThreadIDs.remove(threadId)
                    deferHydratedMarkForNotMaterializedThreadIDs.remove(threadId)
                }
            }

            // First try with includeTurns to get full history.
            // Falls back without includeTurns if the thread has no messages yet
            // (server returns -32600 "not materialized yet").
            let paramsWithTurns: JSONValue = .object([
                "threadId": .string(threadId),
                "includeTurns": .bool(true),
            ])

            let response: RPCMessage
            do {
                response = try await sendRequest(method: "thread/read", params: paramsWithTurns)
            } catch let error as CodexServiceError {
                if case .rpcError(let rpcError) = error, rpcError.code == -32600 {
                    // Sidebar/timeline metadata fetches should keep retrying while the child thread
                    // is still materializing, but full history hydration can stop here.
                    let shouldMarkHydrated = markHydratedWhenNotMaterialized
                        && !deferHydratedMarkForNotMaterializedThreadIDs.contains(threadId)
                    if shouldMarkHydrated {
                        hydratedThreadIDs.insert(threadId)
                    }
                    return .notMaterialized
                }
                throw error
            }

            guard !Task.isCancelled,
                  isPerThreadRefreshCurrent(for: threadId, generation: refreshGeneration) else {
                throw CancellationError()
            }

            guard let resultObject = response.result?.objectValue,
                  let threadObject = resultObject["thread"]?.objectValue else {
                throw CodexServiceError.invalidResponse("thread/read response missing thread payload")
            }

            extractContextWindowUsageIfAvailable(threadId: threadId, threadObject: threadObject)

            // Upsert thread metadata (name, agentNickname, agentRole, model, etc.)
            // so subagent identity resolves without navigating into the child thread.
            if let threadData = try? JSONEncoder().encode(JSONValue.object(threadObject)),
               let decoded = try? JSONDecoder().decode(CodexThread.self, from: threadData) {
                upsertThread(decoded, treatAsServerState: true)
            }

            let shouldForceRefresh = forceRefresh || forcedHistoryLoadThreadIDs.contains(threadId)

            // A turn may have started while thread/read was in flight. Normal background
            // history loads should still stay out of the way, but forced refreshes are
            // used when reopening a running thread and need to merge the latest snapshot.
            if threadHasActiveOrRunningTurn(threadId) && !shouldForceRefresh {
                hydratedThreadIDs.insert(threadId)
                return .skippedForRunningThread
            }

            let historyMessages = decodeMessagesFromThreadRead(threadId: threadId, threadObject: threadObject)
            registerSubagentThreads(from: historyMessages, parentThreadId: threadId)
            var outcome: ThreadHistoryLoadOutcome = .loadedCanonicalHistory
            if !historyMessages.isEmpty {
                let existingMessages = messagesByThread[threadId] ?? []
                let activeThreadIDs = Set(activeTurnIdByThread.keys)
                let runningIDs = runningThreadIDs
                let usedRecentWindow = shouldForceRefresh
                    && threadHasActiveOrRunningTurn(threadId)
                    && Self.shouldPreferRecentHistoryWindow(
                        existingCount: existingMessages.count,
                        historyCount: historyMessages.count
                    )
                if usedRecentWindow {
                    markThreadNeedingCanonicalHistoryReconcile(threadId)
                }
                let merged = try await mergeHistoryMessagesOffMainActor(
                    existing: existingMessages,
                    history: historyMessages,
                    activeThreadIDs: activeThreadIDs,
                    runningThreadIDs: runningIDs,
                    preferRecentWindow: usedRecentWindow
                )
                guard !Task.isCancelled,
                      isPerThreadRefreshCurrent(for: threadId, generation: refreshGeneration) else {
                    throw CancellationError()
                }
                guard shouldForceRefresh || !threadHasActiveOrRunningTurn(threadId) else {
                    hydratedThreadIDs.insert(threadId)
                    return .skippedForRunningThread
                }
                if merged != existingMessages {
                    messagesByThread[threadId] = merged
                    persistMessages()
                    updateCurrentOutput(for: threadId)
                }
                if usedRecentWindow {
                    outcome = .loadedRecentWindow
                    if !threadHasActiveOrRunningTurn(threadId) {
                        scheduleCanonicalHistoryReconcileIfNeeded(for: threadId)
                    }
                } else if !threadHasActiveOrRunningTurn(threadId) {
                    markThreadCanonicalHistoryReconciled(threadId)
                }
            }

            guard !Task.isCancelled,
                  isPerThreadRefreshCurrent(for: threadId, generation: refreshGeneration) else {
                throw CancellationError()
            }
            if outcome.didCompleteCanonicalReconcile, !threadHasActiveOrRunningTurn(threadId) {
                markThreadCanonicalHistoryReconciled(threadId)
            }
            hydratedThreadIDs.insert(threadId)
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
        fileMentions: [String] = []
    ) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !attachments.isEmpty else {
            return ""
        }

        let message = CodexMessage(
            threadId: threadId,
            role: .user,
            text: trimmedText,
            fileMentions: fileMentions,
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
        fileMentions: [String] = []
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIncomingText = Self.normalizedMessageText(trimmedText)
        guard !trimmedText.isEmpty else {
            return
        }

        if let existingIndex = messagesByThread[threadId]?.lastIndex(where: { candidate in
            candidate.role == .user
                && Self.normalizedMessageText(candidate.text) == normalizedIncomingText
                && (
                    (turnId != nil && (candidate.turnId == nil || candidate.turnId == turnId))
                        || (turnId == nil && candidate.turnId == nil)
                )
        }) {
            var didMutate = false
            if messagesByThread[threadId]?[existingIndex].deliveryState != .confirmed {
                messagesByThread[threadId]?[existingIndex].deliveryState = .confirmed
                didMutate = true
            }
            if messagesByThread[threadId]?[existingIndex].turnId == nil {
                messagesByThread[threadId]?[existingIndex].turnId = turnId
                didMutate = true
            }
            // Optional chaining turns `isEmpty` into `Bool?`, so compare explicitly here.
            if messagesByThread[threadId]?[existingIndex].fileMentions.isEmpty == true, !fileMentions.isEmpty {
                messagesByThread[threadId]?[existingIndex].fileMentions = fileMentions
                didMutate = true
            }
            guard didMutate else {
                return
            }
            persistMessages()
            updateCurrentOutput(for: threadId)
            return
        }

        appendMessage(
            CodexMessage(
                threadId: threadId,
                role: .user,
                text: trimmedText,
                fileMentions: fileMentions,
                turnId: turnId,
                deliveryState: .confirmed
            )
        )
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
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || isStreaming else {
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
                          (candidate.turnId == resolvedTurnId || candidate.turnId == nil) else {
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
                        && candidate.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedText
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
                threadMessages[targetIndex].isStreaming = isStreaming
                threadMessages[targetIndex].turnId = resolvedTurnId
                if threadMessages[targetIndex].itemId == nil {
                    threadMessages[targetIndex].itemId = itemId
                }
                let keepID = threadMessages[targetIndex].id
                pruneDuplicateSystemRows(
                    in: &threadMessages,
                    keepIndex: targetIndex,
                    kind: .fileChange,
                    turnId: resolvedTurnId,
                    fileChangePathKeys: incomingPathKeys
                )
                if let refreshedIndex = threadMessages.indices.first(where: { threadMessages[$0].id == keepID }) {
                    threadMessages[refreshedIndex].orderIndex = CodexMessageOrderCounter.next()
                }
                threadMessages.sort(by: { $0.orderIndex < $1.orderIndex })
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
                isStreaming: isStreaming,
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
            turnId: turnId
        )
        refreshDerivedPlanMetadata(threadId: threadId, messageIndex: messageIndex)
        persistMessages()
        updateCurrentOutput(for: threadId)
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
            let existingText = threadMessages[targetIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let messageID: String?
        if let existingMessageID = streamingSystemMessageByItemID[key] {
            messageID = existingMessageID
        } else if let syntheticKey,
                  let migratedMessageID = streamingSystemMessageByItemID[syntheticKey] {
            // Rebind the synthetic turn key to the real item id once the server starts sending it.
            streamingSystemMessageByItemID[key] = migratedMessageID
            streamingSystemMessageByItemID.removeValue(forKey: syntheticKey)
            messageID = migratedMessageID
        } else if kind == .commandExecution,
                  let resolvedTurnId, !resolvedTurnId.isEmpty,
                  let incomingCommandKey,
                  let existingMessageID = messagesByThread[threadId]?.reversed().first(where: { candidate in
                      guard candidate.role == .system,
                            candidate.kind == .commandExecution,
                            candidate.turnId == resolvedTurnId,
                            let candidateKey = commandExecutionPreviewKey(from: candidate.text) else {
                          return false
                      }
                      return candidateKey == incomingCommandKey
                  })?.id {
            streamingSystemMessageByItemID[key] = existingMessageID
            if let syntheticKey {
                streamingSystemMessageByItemID[syntheticKey] = existingMessageID
            }
            messageID = existingMessageID
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
                            (candidate.turnId == resolvedTurnId || candidate.turnId == nil) else {
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
                        isStreaming: isStreaming
                    )
                } else {
                    if isStreamingPlaceholder(incomingTrimmed, for: kind)
                        && !existingTrimmed.isEmpty
                        && !isStreamingPlaceholder(existingTrimmed, for: kind) {
                        // Ignore completion placeholders when we already have real streamed content.
                    } else if isStreamingPlaceholder(existingTrimmed, for: kind) {
                        // Replace placeholder labels ("Thinking...") with real content.
                        messagesByThread[threadId]?[index].text = incoming
                    } else if !isStreaming || isFileChangeSnapshot {
                        // Completed item payloads are authoritative snapshots; replace streamed deltas.
                        messagesByThread[threadId]?[index].text = incoming
                    } else {
                        let merged = mergeAssistantDelta(existingText: existing, incomingDelta: incoming)
                        messagesByThread[threadId]?[index].text = merged
                    }
                }
            }

            messagesByThread[threadId]?[index].kind = kind
            messagesByThread[threadId]?[index].isStreaming = isStreaming
            if let resolvedTurnId, messagesByThread[threadId]?[index].turnId == nil {
                messagesByThread[threadId]?[index].turnId = resolvedTurnId
            }
            if let syntheticItemId,
               messagesByThread[threadId]?[index].itemId == syntheticItemId {
                messagesByThread[threadId]?[index].itemId = itemId
            } else if messagesByThread[threadId]?[index].itemId == nil {
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
                if let finalIndex = threadMessages.indices.first(where: { threadMessages[$0].id == keepID }) {
                    threadMessages[finalIndex].orderIndex = CodexMessageOrderCounter.next()
                    finalRawIndex = finalIndex
                }
                threadMessages.sort(by: { $0.orderIndex < $1.orderIndex })
                finalRawIndex = threadMessages.indices.first(where: { threadMessages[$0].id == keepID }) ?? finalRawIndex
                messagesByThread[threadId] = threadMessages
                persistMessages()
                if kind == .thinking, isStreaming, let finalRawIndex {
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
            isStreaming: isStreaming,
            deliveryState: .confirmed
        )

        streamingSystemMessageByItemID[key] = message.id
        appendMessage(message)
    }

    private func normalizedFileChangePathKeys(from text: String) -> Set<String> {
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
                        || (allowsTurnlessFallback && candidate.turnId == nil)
                )
        }
        guard candidates.count == 1 else {
            return nil
        }
        return candidates[0].id
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
        let keepText = threadMessages[keepIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)

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
                return candidate.text.trimmingCharacters(in: .whitespacesAndNewlines) == keepText
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
        if pendingSystemDeltasByKey[key] == nil {
            pendingSystemDeltasByKey[key] = PendingSystemStreamingDeltas(
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                kind: kind,
                deltas: []
            )
        }
        pendingSystemDeltasByKey[key]?.deltas.append(delta)

        guard systemDeltaFlushTasksByKey[key] == nil else { return }
        systemDeltaFlushTasksByKey[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: StreamingDeltaCoalescingPolicy.flushDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushPendingSystemDeltas(forKey: key)
        }
    }

    private func applyStreamingSystemDeltas(_ pending: PendingSystemStreamingDeltas) {
        upsertStreamingSystemItemMessage(
            threadId: pending.threadId,
            turnId: pending.turnId,
            itemId: pending.itemId,
            kind: pending.kind,
            text: pending.deltas.joined(),
            isStreaming: true
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
                return threadMessages.indices.reversed().first(where: { index in
                    let candidate = threadMessages[index]
                    return candidate.role == .system
                        && candidate.kind == .thinking
                        && candidate.turnId == normalizedTurnId
                })
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
        if threadMessages[targetIndex].itemId == nil,
           let normalizedItemId, !normalizedItemId.isEmpty {
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
    func beginAssistantMessage(threadId: String, turnId: String, itemId: String? = nil) {
        let turnStreamingKey = streamingMessageKey(threadId: threadId, turnId: turnId)
        let normalizedItemId = normalizedStreamingItemID(itemId)
        let itemStreamingKey = normalizedItemId.map {
            assistantStreamingMessageKey(threadId: threadId, turnId: turnId, itemId: $0)
        }

        if let itemStreamingKey,
           let messageID = streamingAssistantMessageByTurnID[itemStreamingKey],
           findMessageIndex(threadId: threadId, messageId: messageID) != nil {
            streamingAssistantMessageByTurnID[turnStreamingKey] = messageID
            return
        }

        if let messageID = streamingAssistantMessageByTurnID[turnStreamingKey],
           let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) {
            if let normalizedItemId {
                let existingItemId = normalizedStreamingItemID(messagesByThread[threadId]?[messageIndex].itemId)
                if existingItemId == nil {
                    messagesByThread[threadId]?[messageIndex].itemId = normalizedItemId
                    if let itemStreamingKey {
                        streamingAssistantMessageByTurnID[itemStreamingKey] = messageID
                    }
                    persistMessages()
                    updateCurrentOutput(for: threadId)
                    return
                }
                if existingItemId == normalizedItemId {
                    if let itemStreamingKey {
                        streamingAssistantMessageByTurnID[itemStreamingKey] = messageID
                    }
                    return
                }

                // New assistant item started inside the same turn: preserve the previous bubble.
                messagesByThread[threadId]?[messageIndex].isStreaming = false
                streamingAssistantMessageByTurnID.removeValue(forKey: turnStreamingKey)
                persistMessages()
                updateCurrentOutput(for: threadId)
            } else {
                return
            }
        } else {
            streamingAssistantMessageByTurnID.removeValue(forKey: turnStreamingKey)
        }

        let message = CodexMessage(
            threadId: threadId,
            role: .assistant,
            text: "",
            turnId: turnId,
            itemId: normalizedItemId,
            isStreaming: true
        )

        threadIdByTurnID[turnId] = threadId
        streamingAssistantMessageByTurnID[turnStreamingKey] = message.id
        if let itemStreamingKey {
            streamingAssistantMessageByTurnID[itemStreamingKey] = message.id
        }
        appendMessage(message)
    }

    // Streams assistant delta chunks into the message linked to a turn.
    func appendAssistantDelta(threadId: String, turnId: String, itemId: String?, delta: String) {
        guard !delta.isEmpty else {
            return
        }

        enqueueAssistantDelta(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            delta: delta
        )
    }

    // Applies one already-coalesced assistant delta batch to the active timeline.
    private func applyAssistantDeltaBatch(threadId: String, turnId: String, itemId: String?, delta: String) {
        guard !delta.isEmpty else {
            return
        }

        let messageID = ensureStreamingAssistantMessage(threadId: threadId, turnId: turnId, itemId: itemId)
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
        messagesByThread[threadId]?[messageIndex].isStreaming = true
        if messagesByThread[threadId]?[messageIndex].itemId == nil, let itemId {
            messagesByThread[threadId]?[messageIndex].itemId = itemId
        }
        refreshDerivedPlanMetadata(threadId: threadId, messageIndex: messageIndex)

        persistMessages()
        updateStreamingAssistantOutput(for: threadId, messageId: messageID, rawMessageIndex: messageIndex)
    }

    // Finalizes assistant text when item/completed carries the canonical message body.
    func completeAssistantMessage(threadId: String, turnId: String?, itemId: String?, text: String) {
        let resolvedTurnId = turnId ?? activeTurnIdByThread[threadId]
        flushPendingAssistantDeltas(for: threadId, turnId: resolvedTurnId, itemId: itemId)

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }

        let now = Date()
        var resolvedAssistantMessageId: String?

        if resolvedTurnId == nil, itemId == nil,
           let fingerprint = assistantCompletionFingerprintByThread[threadId],
           fingerprint.text == trimmedText,
           now.timeIntervalSince(fingerprint.timestamp) <= 45 {
            return
        }

        if let resolvedTurnId,
           itemId == nil,
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
                    messagesByThread[threadId]?[targetIndex].text = trimmedText
                    messagesByThread[threadId]?[targetIndex].isStreaming = false
                    if messagesByThread[threadId]?[targetIndex].turnId == nil {
                        messagesByThread[threadId]?[targetIndex].turnId = resolvedTurnId
                    }
                    refreshDerivedPlanMetadata(threadId: threadId, messageIndex: targetIndex)
                    resolvedAssistantMessageId = messagesByThread[threadId]?[targetIndex].id
                }
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

            if !completedAssistantIndices.isEmpty {
                // Late legacy completions without item identity are ambiguous once a closed
                // turn already has assistant bubbles. Ignore them instead of appending a duplicate.
                assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)
                return
            }
        }

        if let resolvedTurnId,
           let messageID = ensureStreamingAssistantMessage(threadId: threadId, turnId: resolvedTurnId, itemId: itemId),
           let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) {
            let existingText = messagesByThread[threadId]?[messageIndex].text ?? ""

            if existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messagesByThread[threadId]?[messageIndex].text = trimmedText
            } else if existingText != trimmedText {
                messagesByThread[threadId]?[messageIndex].text = trimmedText
            }

            messagesByThread[threadId]?[messageIndex].isStreaming = false
            if messagesByThread[threadId]?[messageIndex].itemId == nil, let itemId {
                messagesByThread[threadId]?[messageIndex].itemId = itemId
            }
            if messagesByThread[threadId]?[messageIndex].turnId == nil {
                messagesByThread[threadId]?[messageIndex].turnId = resolvedTurnId
            }
            refreshDerivedPlanMetadata(threadId: threadId, messageIndex: messageIndex)
            resolvedAssistantMessageId = messagesByThread[threadId]?[messageIndex].id
        } else {
            if let itemId,
               let existingItemIndex = messagesByThread[threadId]?.lastIndex(where: { candidate in
                   candidate.role == .assistant && candidate.itemId == itemId
               }) {
                messagesByThread[threadId]?[existingItemIndex].text = trimmedText
                messagesByThread[threadId]?[existingItemIndex].isStreaming = false
                if messagesByThread[threadId]?[existingItemIndex].turnId == nil {
                    messagesByThread[threadId]?[existingItemIndex].turnId = resolvedTurnId
                }
                refreshDerivedPlanMetadata(threadId: threadId, messageIndex: existingItemIndex)
                resolvedAssistantMessageId = messagesByThread[threadId]?[existingItemIndex].id
            } else if let duplicateIndex = messagesByThread[threadId]?.lastIndex(where: { candidate in
                candidate.role == .assistant
                    && Self.normalizedMessageText(candidate.text) == trimmedText
                    && (
                        candidate.isStreaming
                            || (resolvedTurnId != nil && candidate.turnId == resolvedTurnId)
                            || (itemId != nil && candidate.itemId == itemId)
                    )
            }) {
                // Drop duplicated completion payloads that carry the same final assistant text.
                messagesByThread[threadId]?[duplicateIndex].isStreaming = false
                if messagesByThread[threadId]?[duplicateIndex].itemId == nil, let itemId {
                    messagesByThread[threadId]?[duplicateIndex].itemId = itemId
                }
                if messagesByThread[threadId]?[duplicateIndex].turnId == nil {
                    messagesByThread[threadId]?[duplicateIndex].turnId = resolvedTurnId
                }
                refreshDerivedPlanMetadata(threadId: threadId, messageIndex: duplicateIndex)
                resolvedAssistantMessageId = messagesByThread[threadId]?[duplicateIndex].id
            } else {
                let newMessage = CodexMessage(
                    threadId: threadId,
                    role: .assistant,
                    text: trimmedText,
                    turnId: resolvedTurnId,
                    itemId: itemId,
                    isStreaming: false,
                    deliveryState: .confirmed
                )
                appendMessage(newMessage)
                resolvedAssistantMessageId = newMessage.id
            }
        }

        assistantCompletionFingerprintByThread[threadId] = (text: trimmedText, timestamp: now)

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
        let normalizedText = matchingText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                || message.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText
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

    // Marks streaming assistant state complete once turn/completed arrives.
    func markTurnCompleted(threadId: String, turnId: String?) {
        let resolvedTurnId = turnId ?? activeTurnIdByThread[threadId]
        flushPendingAssistantDeltas(for: threadId, turnId: resolvedTurnId)
        flushPendingSystemDeltasForTurn(threadId: threadId, turnId: resolvedTurnId)

        clearRunningState(for: threadId)
        clearRunningThreadWatch(threadId)
        let shouldFinalizePlanSteps: Bool = {
            if let resolvedTurnId {
                return terminalStateByTurnID[resolvedTurnId] == .completed
            }
            return latestTurnTerminalStateByThread[threadId] == .completed
        }()

        if let resolvedTurnId {
            let turnStreamingKey = streamingMessageKey(threadId: threadId, turnId: resolvedTurnId)
            let itemStreamingPrefix = "\(turnStreamingKey)|item:"
            let keysToClear = streamingAssistantMessageByTurnID.keys.filter { key in
                key == turnStreamingKey || key.hasPrefix(itemStreamingPrefix)
            }

            var closedMessageIDs: Set<String> = []
            for key in keysToClear {
                guard let messageID = streamingAssistantMessageByTurnID.removeValue(forKey: key) else {
                    continue
                }
                guard closedMessageIDs.insert(messageID).inserted else {
                    continue
                }
                if let messageIndex = findMessageIndex(threadId: threadId, messageId: messageID) {
                    messagesByThread[threadId]?[messageIndex].isStreaming = false
                }
            }
        }

        if let resolvedTurnId,
           activeTurnIdByThread[threadId] == resolvedTurnId {
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
                    return message.turnId == resolvedTurnId || message.turnId == nil
                }
                return message.isStreaming
            }

            for index in threadMessages.indices where threadMessages[index].role == .system
                && threadMessages[index].isStreaming {
                let belongsToTurn = belongsToCompletedTurn(threadMessages[index])
                guard belongsToTurn else { continue }
                threadMessages[index].isStreaming = false
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
                        && ($0.turnId == resolvedTurnId || $0.turnId == nil)
                        && shouldPruneThinkingRowAfterTurnCompletion($0)
                }
            } else {
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

        streamingSystemMessageByItemID = streamingSystemMessageByItemID.filter { _, messageId in
            guard let index = findMessageIndex(threadId: threadId, messageId: messageId),
                  let message = messagesByThread[threadId]?[index] else {
                return false
            }
            guard message.role == .system else {
                return true
            }
            if message.kind == .thinking {
                return false
            }
            if let resolvedTurnId {
                return message.turnId != resolvedTurnId
            }
            return !message.isStreaming
        }

        // Keep turn->thread mapping after completion to support late-arriving
        // notifications (e.g. turn/diff/updated emitted right after turn/completed).
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    // Converts all pending streaming bubbles to completed state after transport failures.
    func finalizeAllStreamingState() {
        flushAllPendingStreamingDeltas()
        var didMutate = false

        for threadId in messagesByThread.keys {
            guard var threadMessages = messagesByThread[threadId] else { continue }

            var localChanged = false
            for index in threadMessages.indices where threadMessages[index].isStreaming {
                threadMessages[index].isStreaming = false
                localChanged = true
            }

            if localChanged {
                messagesByThread[threadId] = threadMessages
                didMutate = true
            }
        }

        activeTurnId = nil
        activeTurnIdByThread.removeAll()
        threadsPendingCompletionHaptic.removeAll()
        clearAllRunningState()
        streamingAssistantMessageByTurnID.removeAll()
        streamingSystemMessageByItemID.removeAll()
        pendingAssistantDeltaByStreamID.removeAll()
        pendingAssistantDeltaContextByStreamID.removeAll()
        pendingAssistantDeltaStreamOrder.removeAll()
        pendingAssistantDeltaFlushTask?.cancel()
        pendingAssistantDeltaFlushTask = nil
        threadIdByTurnID.removeAll()

        if didMutate {
            messagePersistence.save(messagesByThread)
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
            self.messagePersistenceDebounceTask = nil

            Task.detached { [messagePersistence] in
                messagePersistence.save(snapshot)
            }
        }
    }
}

// ─── Private helpers ──────────────────────────────────────────

extension CodexService {
    private func enqueueAssistantDelta(threadId: String, turnId: String, itemId: String?, delta: String) {
        let normalizedItemId = normalizedStreamingItemID(itemId)
        let streamID = assistantDeltaStreamID(threadId: threadId, turnId: turnId, itemId: normalizedItemId)

        if normalizedItemId != nil {
            migratePendingTurnFallbackDelta(
                threadId: threadId,
                turnId: turnId,
                destinationStreamID: streamID,
                normalizedItemId: normalizedItemId
            )
        }

        pendingAssistantDeltaContextByStreamID[streamID] = (
            threadId: threadId,
            turnId: turnId.trimmingCharacters(in: .whitespacesAndNewlines),
            itemId: normalizedItemId
        )
        if pendingAssistantDeltaByStreamID[streamID] == nil,
           !pendingAssistantDeltaStreamOrder.contains(streamID) {
            pendingAssistantDeltaStreamOrder.append(streamID)
        }
        pendingAssistantDeltaByStreamID[streamID, default: ""].append(delta)
        schedulePendingAssistantDeltaFlushIfNeeded()
    }

    private func migratePendingTurnFallbackDelta(
        threadId: String,
        turnId: String,
        destinationStreamID: String,
        normalizedItemId: String?
    ) {
        let fallbackStreamID = assistantDeltaStreamID(threadId: threadId, turnId: turnId, itemId: nil)
        guard fallbackStreamID != destinationStreamID,
              let fallbackDelta = pendingAssistantDeltaByStreamID.removeValue(forKey: fallbackStreamID) else {
            return
        }

        pendingAssistantDeltaContextByStreamID.removeValue(forKey: fallbackStreamID)
        pendingAssistantDeltaStreamOrder.removeAll { $0 == fallbackStreamID }
        if pendingAssistantDeltaByStreamID[destinationStreamID] == nil,
           !pendingAssistantDeltaStreamOrder.contains(destinationStreamID) {
            pendingAssistantDeltaStreamOrder.append(destinationStreamID)
        }
        pendingAssistantDeltaByStreamID[destinationStreamID, default: ""].append(fallbackDelta)
        pendingAssistantDeltaContextByStreamID[destinationStreamID] = (
            threadId: threadId,
            turnId: turnId.trimmingCharacters(in: .whitespacesAndNewlines),
            itemId: normalizedItemId
        )
    }

    private func schedulePendingAssistantDeltaFlushIfNeeded() {
        guard pendingAssistantDeltaFlushTask == nil else { return }

        pendingAssistantDeltaFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: assistantDeltaBatchIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            self.flushPendingAssistantDeltas()
        }
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

        for streamID in streamIDsToFlush {
            guard let context = pendingAssistantDeltaContextByStreamID[streamID],
                  let delta = pendingAssistantDeltaByStreamID[streamID] else {
                pendingAssistantDeltaByStreamID.removeValue(forKey: streamID)
                pendingAssistantDeltaContextByStreamID.removeValue(forKey: streamID)
                pendingAssistantDeltaStreamOrder.removeAll { $0 == streamID }
                continue
            }

            pendingAssistantDeltaByStreamID.removeValue(forKey: streamID)
            pendingAssistantDeltaContextByStreamID.removeValue(forKey: streamID)
            pendingAssistantDeltaStreamOrder.removeAll { $0 == streamID }
            applyAssistantDeltaBatch(
                threadId: context.threadId,
                turnId: context.turnId,
                itemId: context.itemId,
                delta: delta
            )
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
                      !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                latestAssistantOutputByThread[threadId] = candidate.text
                latestAssistantMessageIDByThread[threadId] = candidate.id
                return candidate.text
            }
        }

        let latestAssistant = messages
            .last(where: { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let latestAssistantText = latestAssistant?.text ?? ""
        latestAssistantOutputByThread[threadId] = latestAssistantText
        latestAssistantMessageIDByThread[threadId] = latestAssistant?.id
        return latestAssistantText
    }

    // Rebuilds one thread's render snapshot from service-owned caches after any timeline mutation.
    func refreshThreadTimelineState(for threadId: String) {
        let state = timelineState(for: threadId)
        let messages = messagesByThread[threadId] ?? []
        let revision = messageRevisionByThread[threadId] ?? 0
        let activeTurnID = activeTurnIdByThread[threadId]
        let isThreadRunning = threadHasActiveOrRunningTurn(threadId)
        let projectionSourceMessages = snapshotProjectionSourceMessages(from: messages)
        let stoppedTurnIDs = rebuildStoppedTurnIDs(for: threadId, messages: projectionSourceMessages)
        let latestTurnTerminalState = latestTurnTerminalStateByThread[threadId]
        let projectedMessages = TurnTimelineReducer.project(messages: projectionSourceMessages).messages
        let planMatchingMessages = messages.filter { $0.kind == .userInputPrompt }
        let completedTurnIDs = Set(
            projectedMessages.compactMap { message -> String? in
                guard let turnId = message.turnId,
                      terminalStateByTurnID[turnId] == .completed else {
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

        state.messages = messages
        state.messageRevision = revision
        state.activeTurnID = activeTurnID
        state.isThreadRunning = isThreadRunning
        state.latestTurnTerminalState = latestTurnTerminalState
        state.completedTurnIDs = completedTurnIDs
        state.stoppedTurnIDs = stoppedTurnIDs
        state.repoRefreshSignal = repoRefreshSignal
        state.renderSnapshot = TurnTimelineRenderSnapshot(
            threadID: threadId,
            messages: projectedMessages,
            messageIndexByID: projectedMessages.messageIndexByID(),
            planMatchingMessages: planMatchingMessages,
            timelineChangeToken: revision,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning,
            latestTurnTerminalState: latestTurnTerminalState,
            completedTurnIDs: completedTurnIDs,
            stoppedTurnIDs: stoppedTurnIDs,
            assistantRevertStatesByMessageID: assistantRevertStates,
            repoRefreshSignal: repoRefreshSignal
        )
    }

    // Bounds expensive render-only projection work to the recent transcript tail.
    // The service still keeps the full raw history for sync, diff summaries, and persistence.
    func snapshotProjectionSourceMessages(from messages: [CodexMessage]) -> [CodexMessage] {
        guard messages.count > TurnTimelineProjectionPolicy.rawMessageLimit else {
            return messages
        }

        return Array(messages.suffix(TurnTimelineProjectionPolicy.rawMessageLimit))
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
                .filter { terminalStateByTurnID[$0] == .stopped }
        )
        stoppedTurnIDsByThread[threadId] = stoppedTurnIDs
        return stoppedTurnIDs
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
        if let cached = assistantRevertStateCacheByThread[threadId],
           cached.messageRevision == messageRevision,
           cached.busyRepoRevision == busyRepoRootsRevision,
           cached.revertStateRevision == revertStateRevision {
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
        normalizedMessage.proposedPlan = derivedProposedPlan(for: normalizedMessage)
        if message.isStreaming {
            // Keep sidebar run state independent from timeline scanning cost.
            markThreadAsRunning(message.threadId)
        }
        messagesByThread[message.threadId, default: []].append(normalizedMessage)
        messagesByThread[message.threadId]?.sort(by: { $0.orderIndex < $1.orderIndex })
        persistMessages()
        updateCurrentOutput(for: message.threadId)
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

        let rebuiltIndex = Dictionary(
            uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) }
        )
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
        turnId: String?
    ) -> CodexPlanPresentation {
        guard requested == .resultCompletedItem else {
            return requested
        }

        switch turnTerminalState(for: turnId) {
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

    func ensureStreamingAssistantMessage(threadId: String, turnId: String, itemId: String?) -> String? {
        let turnStreamingKey = streamingMessageKey(threadId: threadId, turnId: turnId)
        let normalizedItemId = normalizedStreamingItemID(itemId)
        let itemStreamingKey = normalizedItemId.map {
            assistantStreamingMessageKey(threadId: threadId, turnId: turnId, itemId: $0)
        }

        if let itemStreamingKey,
           let messageID = streamingAssistantMessageByTurnID[itemStreamingKey],
           findMessageIndex(threadId: threadId, messageId: messageID) != nil {
            streamingAssistantMessageByTurnID[turnStreamingKey] = messageID
            return messageID
        }

        if let turnMessageID = streamingAssistantMessageByTurnID[turnStreamingKey],
           let messageIndex = findMessageIndex(threadId: threadId, messageId: turnMessageID) {
            if let normalizedItemId {
                let existingItemId = normalizedStreamingItemID(messagesByThread[threadId]?[messageIndex].itemId)

                if existingItemId == nil {
                    messagesByThread[threadId]?[messageIndex].itemId = normalizedItemId
                    if let itemStreamingKey {
                        streamingAssistantMessageByTurnID[itemStreamingKey] = turnMessageID
                    }
                    persistMessages()
                    updateCurrentOutput(for: threadId)
                    return turnMessageID
                }

                if existingItemId == normalizedItemId {
                    if let itemStreamingKey {
                        streamingAssistantMessageByTurnID[itemStreamingKey] = turnMessageID
                    }
                    return turnMessageID
                }

                // New assistant item in the same turn: close previous row and start a new bubble.
                messagesByThread[threadId]?[messageIndex].isStreaming = false
                streamingAssistantMessageByTurnID.removeValue(forKey: turnStreamingKey)
                persistMessages()
                updateCurrentOutput(for: threadId)

                beginAssistantMessage(threadId: threadId, turnId: turnId, itemId: normalizedItemId)
                if let itemStreamingKey,
                   let messageID = streamingAssistantMessageByTurnID[itemStreamingKey] {
                    streamingAssistantMessageByTurnID[turnStreamingKey] = messageID
                    return messageID
                }
                return streamingAssistantMessageByTurnID[turnStreamingKey]
            }

            return turnMessageID
        } else {
            streamingAssistantMessageByTurnID.removeValue(forKey: turnStreamingKey)
        }

        beginAssistantMessage(threadId: threadId, turnId: turnId, itemId: normalizedItemId)
        if let itemStreamingKey,
           let messageID = streamingAssistantMessageByTurnID[itemStreamingKey] {
            streamingAssistantMessageByTurnID[turnStreamingKey] = messageID
            return messageID
        }
        return streamingAssistantMessageByTurnID[turnStreamingKey]
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
        "turn:\(turnId)|kind:\(kind.rawValue)"
    }

    func syntheticSubagentActionItemIdPrefix(turnId: String) -> String {
        "turn:\(turnId)|kind:\(CodexMessageKind.subagentAction.rawValue)|action:"
    }

    func streamingPlaceholderText(for kind: CodexMessageKind) -> String {
        switch kind {
        case .thinking:
            return "Thinking..."
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
        case .chat:
            return "Updating..."
        }
    }

    func isStreamingPlaceholder(_ text: String, for kind: CodexMessageKind) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(streamingPlaceholderText(for: kind)) == .orderedSame
    }

    // Prunes only empty/placeholder thinking rows, preserving real reasoning text.
    func shouldPruneThinkingRowAfterTurnCompletion(_ message: CodexMessage) -> Bool {
        let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return true
        }

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
