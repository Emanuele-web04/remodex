// FILE: RemodexDisplayIslandCoordinator.swift
// Purpose: Owns Remodex Live Activity state, coalescing, and expiration.
// Layer: Service

import ActivityKit
import Foundation

struct RemodexDisplayIslandSnapshot: Equatable {
    let runningConversations: [RemodexDisplayIslandConversation]
    let completedConversations: [RemodexDisplayIslandConversation]
    let failedConversations: [RemodexDisplayIslandConversation]
    let nextExpirationDate: Date?

    var isEmpty: Bool {
        runningConversations.isEmpty && completedConversations.isEmpty && failedConversations.isEmpty
    }
}

@MainActor
final class RemodexDisplayIslandCoordinator {
    private static let maxDisplayedConversations = CodexRunCompletionEvent.maxRetainedPerResult
    private static let syncDelayNanoseconds: UInt64 = 350_000_000
    private static let completedLifetime: TimeInterval = 5 * 60
    private static let failedLifetime: TimeInterval = 15 * 60
    private static let defaultStaleInterval: TimeInterval = 30 * 60
    private static let staleRefreshLeadTime: TimeInterval = 60
    private static let runningStartRetentionInterval: TimeInterval = 2 * 60 * 60
    // Failsafe: a running row that never received a terminal event must not tick
    // forever; past this age it is dropped from the activity instead.
    private static let maxRunningRowLifetime: TimeInterval = 4 * 60 * 60

    private var activityID: String?
    private var lastSnapshot: RemodexDisplayIslandSnapshot?
    private var lastActivityStaleDate: Date?
    private var scheduledSyncTask: Task<Void, Never>?
    private var timedSyncTask: Task<Void, Never>?

    private var runningStartedAtByThread: [String: Date] = [:]
    private var runningLastSeenAtByThread: [String: Date] = [:]

    func clearOutcome(for threadId: String, codex: CodexService) {
        codex.recentRunCompletionEventsByThread.removeValue(forKey: threadId)
    }

    func sync(codex: CodexService, immediately: Bool = false) {
        if immediately {
            scheduledSyncTask?.cancel()
            scheduledSyncTask = nil
            Task { @MainActor [weak self, weak codex] in
                guard let self, let codex else {
                    return
                }
                await self.performSync(codex: codex)
            }
            return
        }

        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { @MainActor [weak self, weak codex] in
            try? await Task.sleep(nanoseconds: Self.syncDelayNanoseconds)
            guard !Task.isCancelled, let self, let codex else {
                return
            }
            await self.performSync(codex: codex)
        }
    }

    func timelineFingerprint(codex: CodexService) -> String {
        currentRunningThreadIDs(codex: codex)
            .sorted()
            .map { threadId in
                let snapshot = codex.timelineState(for: threadId).renderSnapshot
                return "\(threadId):\(snapshot.timelineChangeToken):\(runningState(for: threadId, codex: codex).rawValue)"
            }
            .joined(separator: "|")
    }

    private func performSync(codex: CodexService) async {
        let now = Date()
        let snapshot = makeReconciledSnapshot(codex: codex, now: now)
        scheduleNextTimedSyncIfNeeded(codex: codex, snapshot: snapshot, now: now)
        await apply(snapshot: snapshot, now: now)
    }

    // Reconciles transient run/outcome caches before producing ActivityKit content.
    func makeReconciledSnapshot(codex: CodexService, now: Date) -> RemodexDisplayIslandSnapshot {
        reconcileCompletions(codex: codex, now: now)
        return makeSnapshot(codex: codex, now: now)
    }

    private func reconcileCompletions(codex: CodexService, now: Date) {
        hydrateRunningStartsFromCurrentActivity(now: now)

        let currentRunningIDs = currentRunningThreadIDs(codex: codex)
        let visibleThreadIDs = visibleThreadIDs(codex: codex)
        let activeThreadIDs = currentActiveThreadIDs(codex: codex)
        let terminalStates = codex.latestTurnTerminalStateByThread

        for threadId in currentRunningIDs where runningStartedAtByThread[threadId] == nil {
            runningStartedAtByThread[threadId] = now
        }
        for threadId in currentRunningIDs {
            runningLastSeenAtByThread[threadId] = now
        }
        pruneRunningStarts(
            currentRunningIDs: currentRunningIDs,
            visibleThreadIDs: visibleThreadIDs,
            terminalStates: terminalStates,
            now: now
        )

        // A terminal state or banner may come from history. Only the shared,
        // admitted completion events can produce a new Live Activity outcome.
        codex.recentRunCompletionEventsByThread = codex.recentRunCompletionEventsByThread.filter { threadId, event in
            let expectedState: CodexTurnTerminalState = event.result == .completed ? .completed : .failed
            return visibleThreadIDs.contains(threadId)
                && !currentRunningIDs.contains(threadId)
                && !activeThreadIDs.contains(threadId)
                && (terminalStates[threadId] == nil || terminalStates[threadId] == expectedState)
                && now.timeIntervalSince(event.receivedAt) < outcomeLifetime(for: event.result)
        }
    }

    private func outcomeLifetime(for result: CodexRunCompletionResult) -> TimeInterval {
        result == .completed ? Self.completedLifetime : Self.failedLifetime
    }

    private func pruneRunningStarts(
        currentRunningIDs: Set<String>,
        visibleThreadIDs: Set<String>,
        terminalStates: [String: CodexTurnTerminalState],
        now: Date
    ) {
        let retainedThreadIDs = Set(runningStartedAtByThread.keys.filter { threadId in
            guard visibleThreadIDs.contains(threadId) else {
                return false
            }
            if currentRunningIDs.contains(threadId) {
                return true
            }
            if terminalStates[threadId] != nil {
                return false
            }
            guard let lastSeenAt = runningLastSeenAtByThread[threadId] else {
                return false
            }
            return now.timeIntervalSince(lastSeenAt) < Self.runningStartRetentionInterval
        })

        runningStartedAtByThread = runningStartedAtByThread.filter { threadId, _ in
            retainedThreadIDs.contains(threadId)
        }
        runningLastSeenAtByThread = runningLastSeenAtByThread.filter { threadId, _ in
            retainedThreadIDs.contains(threadId)
        }
    }

    private func makeSnapshot(codex: CodexService, now: Date) -> RemodexDisplayIslandSnapshot {
        let currentRunningIDs = currentRunningThreadIDs(codex: codex)
        let runningConversations = currentRunningIDs
            .filter { threadId in
                guard let runningStartedAt = runningStartedAtByThread[threadId] else {
                    return true
                }
                return now.timeIntervalSince(runningStartedAt) < Self.maxRunningRowLifetime
            }
            .compactMap { threadId in
                conversation(
                    threadId: threadId,
                    state: runningState(for: threadId, codex: codex),
                    runningStartedAt: runningStartedAtByThread[threadId],
                    codex: codex
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let recentCompletions = codex.recentRunCompletionEventsByThread.sorted {
            if $0.value.receivedAt != $1.value.receivedAt {
                return $0.value.receivedAt > $1.value.receivedAt
            }
            return $0.key < $1.key
        }
        let completedConversations = recentCompletions.filter { $0.value.result == .completed }.compactMap { threadId, _ in
            conversation(threadId: threadId, state: .ready, codex: codex)
        }
        let failedConversations = recentCompletions.filter { $0.value.result == .failed }.compactMap { threadId, _ in
            conversation(threadId: threadId, state: .failed, codex: codex)
        }

        return RemodexDisplayIslandSnapshot(
            runningConversations: Array(runningConversations.prefix(Self.maxDisplayedConversations)),
            completedConversations: Array(completedConversations.prefix(Self.maxDisplayedConversations)),
            failedConversations: Array(failedConversations.prefix(Self.maxDisplayedConversations)),
            nextExpirationDate: nextExpirationDate(codex: codex, now: now, currentRunningIDs: currentRunningIDs)
        )
    }

    private func currentRunningThreadIDs(codex: CodexService) -> Set<String> {
        codex.runningThreadIDs
            .union(Set(codex.activeTurnIdByThread.keys))
            .intersection(visibleThreadIDs(codex: codex))
    }

    private func visibleThreadIDs(codex: CodexService) -> Set<String> {
        Set(codex.threads.map(\.id))
    }

    private func currentActiveThreadIDs(codex: CodexService) -> Set<String> {
        guard let activeThreadId = codex.activeThreadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !activeThreadId.isEmpty else {
            return []
        }

        return [activeThreadId]
    }

    private func runningState(for threadId: String, codex: CodexService) -> RemodexDisplayIslandConversationState {
        let messages = codex.timelineState(for: threadId).renderSnapshot.messages
        let isFinalAnswerStreaming = messages.contains { message in
            message.role == .assistant
                && message.kind == .chat
                && message.isStreaming
                && message.assistantPhase == "final_answer"
                && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return isFinalAnswerStreaming ? .finishing : .running
    }

    private func conversation(
        threadId: String,
        state: RemodexDisplayIslandConversationState,
        runningStartedAt: Date? = nil,
        codex: CodexService
    ) -> RemodexDisplayIslandConversation? {
        let thread = codex.threads.first { $0.id == threadId }
        let rawTitle = thread?.displayTitle ?? CodexThread.defaultDisplayTitle
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detail(for: thread)

        return RemodexDisplayIslandConversation(
            id: threadId,
            title: title.isEmpty ? CodexThread.defaultDisplayTitle : title,
            detail: detail,
            state: state.rawValue,
            runningStartedAt: runningStartedAt
        )
    }

    private func detail(for thread: CodexThread?) -> String {
        guard let cwd = thread?.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return "Remodex"
        }

        let lastPathComponent = URL(fileURLWithPath: cwd).lastPathComponent
        return lastPathComponent.isEmpty ? "Remodex" : lastPathComponent
    }

    private func nextExpirationDate(codex: CodexService, now: Date, currentRunningIDs: Set<String>) -> Date? {
        let outcomeExpiration = codex.recentRunCompletionEventsByThread.values
            .map { $0.receivedAt.addingTimeInterval(outcomeLifetime(for: $0.result)) }
            .filter { $0 > now }
            .min()
        // Running rows expire too, so a stuck run re-syncs (and drops) at its cap
        // instead of ticking until the system-wide Live Activity limit.
        let runningExpiration = currentRunningIDs
            .compactMap { runningStartedAtByThread[$0]?.addingTimeInterval(Self.maxRunningRowLifetime) }
            .filter { $0 > now }
            .min()

        return [outcomeExpiration, runningExpiration]
            .compactMap { $0 }
            .min()
    }

    private func scheduleNextTimedSyncIfNeeded(
        codex: CodexService,
        snapshot: RemodexDisplayIslandSnapshot,
        now: Date
    ) {
        timedSyncTask?.cancel()
        guard let nextSyncDate = nextTimedSyncDate(for: snapshot, now: now) else {
            timedSyncTask = nil
            return
        }

        let delay = max(0, nextSyncDate.timeIntervalSince(now))
        let nanoseconds = UInt64(delay * 1_000_000_000)
        timedSyncTask = Task { @MainActor [weak self, weak codex] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, let codex else {
                return
            }
            self.sync(codex: codex, immediately: true)
        }
    }

    // Timed syncs handle both outcome expiry and quiet-running staleDate refreshes.
    private func nextTimedSyncDate(for snapshot: RemodexDisplayIslandSnapshot, now: Date) -> Date? {
        [
            snapshot.nextExpirationDate,
            staleDeadlineRefreshDate(for: snapshot, now: now),
        ]
        .compactMap { $0 }
        .filter { $0 > now }
        .min()
    }

    private func staleDeadlineRefreshDate(for snapshot: RemodexDisplayIslandSnapshot, now: Date) -> Date? {
        guard !snapshot.runningConversations.isEmpty else {
            return nil
        }

        let refreshDate = activityStaleDate(for: snapshot, now: now)
            .addingTimeInterval(-Self.staleRefreshLeadTime)
        return refreshDate > now ? refreshDate : nil
    }

    private func hydrateRunningStartsFromCurrentActivity(now: Date) {
        guard let activity = currentActivity else {
            return
        }

        for conversation in activity.content.state.runningConversations {
            guard let runningStartedAt = conversation.runningStartedAt else {
                continue
            }
            if let existingStartedAt = runningStartedAtByThread[conversation.id] {
                runningStartedAtByThread[conversation.id] = min(existingStartedAt, runningStartedAt)
            } else {
                runningStartedAtByThread[conversation.id] = runningStartedAt
            }
            runningLastSeenAtByThread[conversation.id] = now
        }
    }

    private func apply(snapshot: RemodexDisplayIslandSnapshot, now: Date) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAllActivities()
            lastSnapshot = nil
            return
        }

        guard !snapshot.isEmpty else {
            await endAllActivities()
            lastSnapshot = nil
            return
        }

        // nextExpirationDate can sit hours away (running-row cap); staleDate must
        // still trip after defaultStaleInterval so the widget stops faking live
        // progress when the app is suspended and updates stop.
        let staleDate = activityStaleDate(for: snapshot, now: now)
        let activity = currentActivity
        guard snapshot != lastSnapshot
                || activity == nil
                || shouldRefreshActivityStaleDate(staleDate, now: now) else {
            return
        }

        let content = ActivityContent(
            state: RemodexDisplayIslandAttributes.ContentState(
                runningConversations: snapshot.runningConversations,
                completedConversations: snapshot.completedConversations,
                failedConversations: snapshot.failedConversations,
                updatedAt: now
            ),
            staleDate: staleDate
        )

        var didApplyActivityContent = false
        if let activity {
            await activity.update(content)
            activityID = activity.id
            didApplyActivityContent = true
        } else {
            do {
                let activity = try Activity<RemodexDisplayIslandAttributes>.request(
                    attributes: RemodexDisplayIslandAttributes(title: "Remodex"),
                    content: content,
                    pushType: nil
                )
                activityID = activity.id
                didApplyActivityContent = true
            } catch {
                activityID = nil
            }
        }

        if didApplyActivityContent {
            lastActivityStaleDate = staleDate
        }
        lastSnapshot = snapshot
    }

    private func activityStaleDate(for snapshot: RemodexDisplayIslandSnapshot, now: Date) -> Date {
        min(
            snapshot.nextExpirationDate ?? .distantFuture,
            now.addingTimeInterval(Self.defaultStaleInterval)
        )
    }

    private func shouldRefreshActivityStaleDate(_ staleDate: Date, now: Date) -> Bool {
        guard let lastActivityStaleDate else {
            return true
        }

        return lastActivityStaleDate <= now.addingTimeInterval(Self.staleRefreshLeadTime)
            || staleDate < lastActivityStaleDate
    }

    private var currentActivity: Activity<RemodexDisplayIslandAttributes>? {
        if let activityID,
           let matchingActivity = Activity<RemodexDisplayIslandAttributes>.activities.first(where: { $0.id == activityID }) {
            return matchingActivity
        }

        return Activity<RemodexDisplayIslandAttributes>.activities.first
    }

    private func endAllActivities() async {
        for activity in Activity<RemodexDisplayIslandAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activityID = nil
        lastActivityStaleDate = nil
    }
}
