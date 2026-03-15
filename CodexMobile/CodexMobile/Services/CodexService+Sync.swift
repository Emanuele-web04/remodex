// FILE: CodexService+Sync.swift
// Purpose: Near-real-time sync loop and server-authoritative thread reconciliation.
// Layer: Service
// Exports: CodexService sync APIs
// Depends on: CodexThread, CodexServiceError

import Foundation
import UIKit

extension CodexService {
    func startSyncLoop() {
        guard canRunRealtimeSyncLoop else {
            stopSyncLoop()
            return
        }

        stopSyncLoop()
        debugSyncLog("sync loop start")

        // Foreground polling is intentionally more aggressive so desktop-authored changes
        // feel closer to live on iPhone even when Codex.app itself doesn't push updates.
        let listIntervalForegroundNs: UInt64 = 10_000_000_000
        let listIntervalBackgroundNs: UInt64 = 75_000_000_000
        let historyIntervalForegroundNs: UInt64 = 3_000_000_000
        let historyIntervalForegroundMirroredNs: UInt64 = 1_000_000_000
        let historyIntervalBackgroundIdleNs: UInt64 = 90_000_000_000
        let historyIntervalBackgroundRunningNs: UInt64 = 12_000_000_000
        let watchIntervalForegroundNs: UInt64 = 2_000_000_000
        let watchIntervalBackgroundNs: UInt64 = 15_000_000_000

        threadListSyncTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.syncThreadsList()
                await self.refreshInactiveRunningBadgeThreads()
                let interval = self.isAppInForeground ? listIntervalForegroundNs : listIntervalBackgroundNs
                try? await Task.sleep(nanoseconds: interval)
            }
        }

        activeThreadSyncTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if let threadId = self.activeThreadId {
                    let hasActiveOrRunningTurn = self.threadHasActiveOrRunningTurn(threadId)
                    let wantsMirroredRunningCatchup = self.shouldPrioritizeMirroredRunningCatchup(threadId)
                    await self.syncActiveThreadState(threadId: threadId)
                    let interval: UInt64
                    if self.isAppInForeground {
                        interval = wantsMirroredRunningCatchup
                            ? historyIntervalForegroundMirroredNs
                            : historyIntervalForegroundNs
                    } else if hasActiveOrRunningTurn {
                        interval = historyIntervalBackgroundRunningNs
                    } else {
                        interval = historyIntervalBackgroundIdleNs
                    }
                    try? await Task.sleep(nanoseconds: interval)
                    continue
                }
                let interval = self.isAppInForeground ? historyIntervalForegroundNs : historyIntervalBackgroundIdleNs
                try? await Task.sleep(nanoseconds: interval)
            }
        }

        runningThreadWatchSyncTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshInactiveRunningBadgeThreads()
                let interval = self.isAppInForeground ? watchIntervalForegroundNs : watchIntervalBackgroundNs
                try? await Task.sleep(nanoseconds: interval)
            }
        }

        requestImmediateSync(threadId: activeThreadId)
    }

    func stopSyncLoop() {
        threadListSyncTask?.cancel()
        threadListSyncTask = nil

        activeThreadSyncTask?.cancel()
        activeThreadSyncTask = nil

        runningThreadWatchSyncTask?.cancel()
        runningThreadWatchSyncTask = nil
    }

    func setForegroundState(_ isForeground: Bool) {
        guard isAppInForeground != isForeground else {
            return
        }

        isAppInForeground = isForeground
        if isForeground {
            if isConnected && isInitialized {
                startSyncLoop()
                requestImmediateSync(threadId: activeThreadId)
            } else {
                stopSyncLoop()
            }
        } else {
            if isConnected && isInitialized {
                startSyncLoop()
                requestImmediateSync(threadId: activeThreadId)
            } else {
                stopSyncLoop()
            }
        }
        updateBackgroundRunGraceTask()
    }

    func requestImmediateSync(threadId: String? = nil) {
        guard canRunRealtimeSyncLoop else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncThreadsList()
            await self.refreshInactiveRunningBadgeThreads()
            if let threadId = threadId ?? self.activeThreadId {
                await self.syncActiveThreadState(threadId: threadId)
            }
        }
    }

    func syncThreadsList() async {
        guard isConnected, isInitialized else {
            return
        }

        do {
            let activeThreads = try await fetchServerThreads(limit: recentThreadListLimit)

            // Also fetch server-archived threads so they survive app restarts.
            var archivedThreads: [CodexThread] = []
            do {
                archivedThreads = try await fetchServerThreads(limit: recentThreadListLimit, archived: true)
            } catch {
                debugSyncLog("thread/list archived fetch failed (non-fatal): \(error.localizedDescription)")
            }

            reconcileLocalThreadsWithServer(activeThreads, serverArchivedThreads: archivedThreads)
            debugSyncLog("sync thread/list active=\(activeThreads.count) archived=\(archivedThreads.count) local=\(threads.count)")
        } catch {
            presentConnectionErrorIfNeeded(error)
        }
    }

    func syncThreadHistory(threadId: String, force: Bool = false) async {
        guard isConnected, isInitialized else {
            return
        }

        if threads.first(where: { $0.id == threadId })?.syncState == .archivedLocal {
            return
        }

        do {
            try await loadThreadHistoryIfNeeded(threadId: threadId, forceRefresh: force)
        } catch {
            if shouldTreatAsThreadNotFound(error) {
                // Do not archive on background sync alone.
                // Some servers can temporarily fail thread/read for fresh or stale listeners.
                // We archive only after an explicit turn/start send failure confirms missing thread.
                debugSyncLog("sync thread/read reported missing thread=\(threadId); waiting for send-time confirmation")
                return
            }
            presentConnectionErrorIfNeeded(error)
        }
    }

    func reconcileLocalThreadsWithServer(
        _ serverThreads: [CodexThread],
        serverArchivedThreads: [CodexThread] = []
    ) {
        let localByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let persistedArchivedIDs = locallyArchivedThreadIDs
        let persistedDeletedIDs = locallyDeletedThreadIDs
        let serverArchivedIDs = Set(serverArchivedThreads.map(\.id))

        var merged: [String: CodexThread] = [:]

        // Merge active server threads.
        for serverThread in serverThreads {
            if persistedDeletedIDs.contains(serverThread.id) {
                continue
            }

            var liveThread = serverThread

            if let localThread = localByID[liveThread.id] {
                liveThread.syncState = localThread.syncState
                if liveThread.title == nil { liveThread.title = localThread.title }
                if liveThread.name == nil { liveThread.name = localThread.name }
                if liveThread.preview == nil { liveThread.preview = localThread.preview }
                if liveThread.createdAt == nil { liveThread.createdAt = localThread.createdAt }
                if liveThread.updatedAt == nil { liveThread.updatedAt = localThread.updatedAt }
                if liveThread.cwd == nil { liveThread.cwd = localThread.cwd }
                liveThread.metadata = mergedThreadMetadata(
                    serverMetadata: liveThread.metadata,
                    localMetadata: localThread.metadata
                )
            } else if persistedArchivedIDs.contains(liveThread.id) {
                liveThread.syncState = .archivedLocal
            } else {
                liveThread.syncState = .live
            }

            merged[liveThread.id] = liveThread
        }

        // Merge server-archived threads (from thread/list?archived=true).
        for serverThread in serverArchivedThreads {
            if persistedDeletedIDs.contains(serverThread.id) {
                continue
            }
            guard merged[serverThread.id] == nil else {
                continue
            }

            var archivedThread = serverThread
            archivedThread.syncState = .archivedLocal

            if let localThread = localByID[archivedThread.id] {
                if archivedThread.title == nil { archivedThread.title = localThread.title }
                if archivedThread.name == nil { archivedThread.name = localThread.name }
                if archivedThread.preview == nil { archivedThread.preview = localThread.preview }
                if archivedThread.createdAt == nil { archivedThread.createdAt = localThread.createdAt }
                if archivedThread.updatedAt == nil { archivedThread.updatedAt = localThread.updatedAt }
                if archivedThread.cwd == nil { archivedThread.cwd = localThread.cwd }
                archivedThread.metadata = mergedThreadMetadata(
                    serverMetadata: archivedThread.metadata,
                    localMetadata: localThread.metadata
                )
            }

            // Persist the archived state so it survives future reconciliations.
            addLocallyArchivedThreadID(archivedThread.id)
            merged[archivedThread.id] = archivedThread
        }

        // Keep local-only threads as-is; a missing entry in thread/list can be
        // caused by server-side pagination or temporary visibility mismatch.
        // We archive only on explicit "thread not found" from thread/read/turn/start.
        for localThread in threads where merged[localThread.id] == nil {
            if persistedDeletedIDs.contains(localThread.id) {
                continue
            }
            merged[localThread.id] = localThread
        }

        threads = sortThreads(Array(merged.values))
        assistantRevertStateCacheByThread.removeAll()
        refreshBusyRepoRootsAndDependentTimelineStates()
        refreshAllThreadTimelineStates()

        if activeThreadId == nil {
            activeThreadId = threads.first(where: { $0.syncState == .live })?.id
        }

        if pendingNotificationOpenThreadID != nil {
            // A successful thread/list refresh gives us fresh server truth, so retry
            // any deferred push deep-link without forcing another list round-trip.
            Task { @MainActor [weak self] in
                _ = await self?.routePendingNotificationOpenIfPossible(refreshIfNeeded: false)
            }
        }
    }

    func handleMissingThread(_ threadId: String) {
        clearRunningState(for: threadId)
        clearOutcomeBadge(for: threadId)

        if let index = threads.firstIndex(where: { $0.id == threadId }) {
            threads[index].syncState = .archivedLocal
        } else {
            threads.append(CodexThread(id: threadId, title: "Conversation", syncState: .archivedLocal))
            threads = sortThreads(threads)
        }

        hydratedThreadIDs.remove(threadId)
        loadingThreadIDs.remove(threadId)
        resumedThreadIDs.remove(threadId)
        streamingSystemMessageByItemID = streamingSystemMessageByItemID.filter { key, _ in
            !key.hasPrefix("\(threadId)|item:")
        }

        if let turnId = activeTurnID(for: threadId) {
            setActiveTurnID(nil, for: threadId)
            threadIdByTurnID.removeValue(forKey: turnId)
            if activeTurnId == turnId {
                activeTurnId = nil
            }
        }
        threadIdByTurnID = threadIdByTurnID.filter { $0.value != threadId }

        if var messages = messagesByThread[threadId] {
            var didMutate = false
            for index in messages.indices where messages[index].isStreaming {
                messages[index].isStreaming = false
                didMutate = true
            }
            if didMutate {
                messagesByThread[threadId] = messages
                persistMessages()
                updateCurrentOutput(for: threadId)
            }
        }

        removeThreadTimelineState(for: threadId)

        debugSyncLog("thread archived locally: \(threadId)")
    }

    func archiveThread(_ threadId: String) {
        clearRunningState(for: threadId)
        removeThreadTimelineState(for: threadId)
        clearOutcomeBadge(for: threadId)

        if let index = threads.firstIndex(where: { $0.id == threadId }) {
            threads[index].syncState = .archivedLocal
        }

        hydratedThreadIDs.remove(threadId)
        resumedThreadIDs.remove(threadId)

        if let turnId = activeTurnID(for: threadId) {
            setActiveTurnID(nil, for: threadId)
            threadIdByTurnID.removeValue(forKey: turnId)
            if activeTurnId == turnId { activeTurnId = nil }
        }
        threadIdByTurnID = threadIdByTurnID.filter { $0.value != threadId }

        addLocallyArchivedThreadID(threadId)
        debugSyncLog("thread archived by user: \(threadId)")
        sendThreadArchiveRPC(threadId: threadId, unarchive: false)
    }

    // Archives every active thread in a sidebar project group so the folder disappears from the live list.
    func archiveThreadGroup(threadIDs: [String]) -> [String] {
        let uniqueThreadIDs = Array(Set(threadIDs)).sorted()
        for threadID in uniqueThreadIDs {
            archiveThread(threadID)
        }

        debugSyncLog("thread group archived by user: count=\(uniqueThreadIDs.count)")
        return uniqueThreadIDs
    }

    func unarchiveThread(_ threadId: String) {
        if let index = threads.firstIndex(where: { $0.id == threadId }) {
            threads[index].syncState = .live
        }
        removeLocallyArchivedThreadID(threadId)
        debugSyncLog("thread unarchived by user: \(threadId)")
        sendThreadArchiveRPC(threadId: threadId, unarchive: true)
    }

    func deleteThread(_ threadId: String) {
        // Single-thread delete stays optimistic locally, then best-effort archives remotely.
        removeThreadLocally(threadId, persistAsDeleted: true)
        debugSyncLog("thread deleted by user: \(threadId)")
        sendThreadArchiveRPC(threadId: threadId, unarchive: false)
    }

    func renameThread(_ threadId: String, name: String) {
        // Optimistic local update.
        if let index = threads.firstIndex(where: { $0.id == threadId }) {
            threads[index].name = name
            threads[index].title = name
        }
        debugSyncLog("thread renamed by user: \(threadId) → \(name)")
        sendThreadNameSetRPC(threadId: threadId, name: name)
    }

    private func sendThreadNameSetRPC(threadId: String, name: String) {
        guard isConnected, webSocketConnection != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sendRequest(
                    method: "thread/name/set",
                    params: .object([
                        "thread_id": .string(threadId),
                        "name": .string(name),
                    ])
                )
                self.debugSyncLog("thread/name/set RPC success: \(threadId)")
            } catch {
                self.debugSyncLog("thread/name/set RPC failed (non-fatal): \(error.localizedDescription)")
            }
        }
    }

    // Removes every thread in a sidebar group without issuing per-thread RPC mutations.
    func deleteLocalThreadGroup(threadIDs: [String]) -> [String] {
        for threadID in threadIDs {
            removeThreadLocally(threadID, persistAsDeleted: true)
        }

        debugSyncLog("thread group deleted locally: count=\(threadIDs.count)")
        return threadIDs
    }

    // Centralizes local-only thread cleanup so repo-group deletion can reuse it safely.
    private func removeThreadLocally(_ threadId: String, persistAsDeleted: Bool) {
        clearRunningState(for: threadId)
        removeThreadTimelineState(for: threadId)
        clearOutcomeBadge(for: threadId)

        // Drop local-only runtime overrides once a chat is fully removed from the device.
        clearThreadReasoningEffortOverride(for: threadId)
        clearThreadServiceTierOverride(for: threadId)

        threads.removeAll { $0.id == threadId }
        messagesByThread.removeValue(forKey: threadId)
        messagePersistence.save(messagesByThread)

        hydratedThreadIDs.remove(threadId)
        loadingThreadIDs.remove(threadId)
        resumedThreadIDs.remove(threadId)
        streamingSystemMessageByItemID = streamingSystemMessageByItemID.filter { key, _ in
            !key.hasPrefix("\(threadId)|item:")
        }

        if let turnId = activeTurnID(for: threadId) {
            setActiveTurnID(nil, for: threadId)
            threadIdByTurnID.removeValue(forKey: turnId)
            if activeTurnId == turnId { activeTurnId = nil }
        }
        threadIdByTurnID = threadIdByTurnID.filter { $0.value != threadId }

        if activeThreadId == threadId { activeThreadId = nil }

        removeLocallyArchivedThreadID(threadId)
        if persistAsDeleted {
            addLocallyDeletedThreadID(threadId)
        }
    }

    func clearHydrationCaches() {
        hydratedThreadIDs.removeAll()
        loadingThreadIDs.removeAll()
    }

    func shouldTreatAsThreadNotFound(_ error: Error) -> Bool {
        let message: String
        if let serviceError = error as? CodexServiceError,
           case .rpcError(let rpcError) = serviceError {
            message = rpcError.message.lowercased()
        } else {
            message = error.localizedDescription.lowercased()
        }

        if message.contains("not materialized") || message.contains("not yet materialized") {
            return false
        }
        return message.contains("thread not found") || message.contains("unknown thread")
    }

    // Preserves locally derived metadata keys (for example repo context) when server payload is sparse.
    func mergedThreadMetadata(
        serverMetadata: [String: JSONValue]?,
        localMetadata: [String: JSONValue]?
    ) -> [String: JSONValue]? {
        var merged = serverMetadata ?? [:]
        for (key, value) in localMetadata ?? [:] where merged[key] == nil {
            merged[key] = value
        }
        return merged.isEmpty ? nil : merged
    }

    func debugSyncLog(_ message: String) {
#if DEBUG
        print("[CodexSync] \(message)")
#endif
    }

    // Treats thread as active if either turn mapping or runtime running fallback is present.
    func threadHasActiveOrRunningTurn(_ threadId: String) -> Bool {
        activeTurnID(for: threadId) != nil || runningThreadIDs.contains(threadId)
    }

    // Keeps short-lived background execution alive when a run is still in flight.
    var hasAnyRunningTurn: Bool {
        !runningThreadIDs.isEmpty
            || !protectedRunningFallbackThreadIDs.isEmpty
            || !activeTurnIdByThread.isEmpty
    }

    var canRunRealtimeSyncLoop: Bool {
        syncRealtimeEnabled && isConnected && isInitialized
    }

    // Prioritizes only desktop-mirrored runs that still lack authoritative assistant deltas.
    func shouldPrioritizeMirroredRunningCatchup(_ threadId: String) -> Bool {
        mirroredRunningCatchupThreadIDs.contains(threadId) && threadHasActiveOrRunningTurn(threadId)
    }

    // Grants one bounded catch-up slot so mirrored desktop runs can refresh via
    // thread/resume without hammering the server every loop tick.
    func takeMirroredRunningCatchupPermit(
        for threadId: String,
        minInterval: TimeInterval = 1.0,
        now: Date = Date()
    ) -> Bool {
        guard shouldPrioritizeMirroredRunningCatchup(threadId) else {
            return false
        }

        if let lastSyncAt = lastMirroredRunningCatchupAtByThread[threadId],
           now.timeIntervalSince(lastSyncAt) < minInterval {
            return false
        }

        lastMirroredRunningCatchupAtByThread[threadId] = now
        return true
    }

    // Polls the currently displayed thread even while it is running so missed socket events can recover.
    // If the live snapshot fails, fall back to a history refresh instead of trusting stale running state.
    func syncActiveThreadState(threadId: String) async {
        let wasRunning = threadHasActiveOrRunningTurn(threadId)
        let shouldRunMirroredCatchup = wasRunning && takeMirroredRunningCatchupPermit(for: threadId)
        var didRunMirroredCatchup = false

        if wasRunning {
            let didRefresh = await refreshInFlightTurnState(threadId: threadId)
            let isStillRunning = threadHasActiveOrRunningTurn(threadId)

            if shouldRunMirroredCatchup && isStillRunning {
                do {
                    _ = try await ensureThreadResumed(threadId: threadId, force: true)
                } catch {
                    await syncThreadHistory(threadId: threadId, force: true)
                }
                didRunMirroredCatchup = true
            }

            guard !didRefresh || !isStillRunning else {
                return
            }
        }

        if !didRunMirroredCatchup {
            await syncThreadHistory(threadId: threadId, force: true)
        }
    }

    func refreshInactiveRunningBadgeThreads(limit: Int = 3) async {
        pruneRunningThreadWatchlist()

        let availableThreadIDs = Set(threads.map(\.id))
        let candidateThreadIDs = runningThreadWatchByID.values
            .sorted { lhs, rhs in
                lhs.expiresAt < rhs.expiresAt
            }
            .map(\.threadId)
            .filter { threadId in
                threadId != activeThreadId
                    && availableThreadIDs.contains(threadId)
                    && runningThreadIDs.contains(threadId)
            }
            .prefix(limit)

        for threadId in candidateThreadIDs {
            let wasRunning = threadHasActiveOrRunningTurn(threadId)
            let didRefresh = await refreshInFlightTurnState(threadId: threadId)

            guard !didRefresh || !wasRunning || !threadHasActiveOrRunningTurn(threadId) else {
                continue
            }

            await syncThreadHistory(threadId: threadId, force: true)
            if !failedThreadIDs.contains(threadId) {
                markReadyIfUnread(threadId: threadId)
            }
            clearRunningThreadWatch(threadId)
        }
    }

    func pruneRunningThreadWatchlist(now: Date = Date()) {
        runningThreadWatchByID = runningThreadWatchByID.filter { _, watch in
            watch.expiresAt > now
        }
    }

    // Starts or ends the iOS grace window that lets a just-backgrounded run finish cleanly.
    func updateBackgroundRunGraceTask() {
        guard !isAppInForeground else {
            endBackgroundRunGraceTask(reason: "foreground")
            return
        }

        guard hasAnyRunningTurn else {
            endBackgroundRunGraceTask(reason: "idle")
            return
        }

        guard backgroundTurnGraceTaskID == .invalid else {
            return
        }

        let taskID = UIApplication.shared.beginBackgroundTask(withName: "CodexRunGrace") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundRunGraceTask(reason: "expired")
            }
        }

        guard taskID != .invalid else {
            debugSyncLog("background run grace task unavailable")
            return
        }

        backgroundTurnGraceTaskID = taskID
        debugSyncLog("background run grace task started")
    }

    func endBackgroundRunGraceTask(reason: String) {
        guard backgroundTurnGraceTaskID != .invalid else {
            return
        }

        let taskID = backgroundTurnGraceTaskID
        backgroundTurnGraceTaskID = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
        debugSyncLog("background run grace task ended reason=\(reason)")
    }

    /// Best-effort server-side archive/unarchive. Failures are logged but never
    /// surface to the user or trigger reconnection side-effects.
    private func sendThreadArchiveRPC(threadId: String, unarchive: Bool) {
        guard isConnected, webSocketConnection != nil else { return }
        let method = unarchive ? "thread/unarchive" : "thread/archive"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sendRequest(method: method, params: .object(["threadId": .string(threadId)]))
                self.debugSyncLog("\(method) RPC success: \(threadId)")
            } catch {
                self.debugSyncLog("\(method) RPC failed (non-fatal): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persisted archive/delete sets

    private static let locallyDeletedThreadIDsKey = "codex.locallyDeletedThreadIDs"

    var locallyArchivedThreadIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.locallyArchivedThreadIDsKey) ?? [])
    }

    var locallyDeletedThreadIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.locallyDeletedThreadIDsKey) ?? [])
    }

    private func addLocallyArchivedThreadID(_ threadId: String) {
        var ids = locallyArchivedThreadIDs
        ids.insert(threadId)
        defaults.set(Array(ids), forKey: Self.locallyArchivedThreadIDsKey)
    }

    private func removeLocallyArchivedThreadID(_ threadId: String) {
        var ids = locallyArchivedThreadIDs
        ids.remove(threadId)
        defaults.set(Array(ids), forKey: Self.locallyArchivedThreadIDsKey)
    }

    private func addLocallyDeletedThreadID(_ threadId: String) {
        var ids = locallyDeletedThreadIDs
        ids.insert(threadId)
        defaults.set(Array(ids), forKey: Self.locallyDeletedThreadIDsKey)
    }
}
