// FILE: CodexService+ThreadHistoryPagination.swift
// Purpose: Owns paginated thread history fetch, cursor state, and older-message reveal helpers.
// Layer: Service extension
// Exports: CodexService thread history pagination APIs
// Depends on: CodexService transport, CodexMessage history merge helpers, JSONValue

import Foundation

enum TurnTimelineProjectionPolicy {
    // Long chats can contain thousands of persisted rows. Reveal them through a bounded
    // render window while remote turn pages extend the backing cache as needed.
    static let initialMessageLimit = 80
    static let messagePageSize = 40
    static let eagerHydrationMessageLimit = 400
}

enum ThreadHistoryHydrationPolicy {
    // Huge desktop transcripts can make thread/read stall before the bridge can compact the payload.
    // Match Litter's cursor-driven paging: hydrate a tiny recent window, then prepend on demand.
    static let requestTimeoutNanoseconds: UInt64 = 30_000_000_000
    static let initialPageSoftTimeoutNanoseconds: UInt64 = 8_000_000_000
    static let initialTurnPageSize = 5
    static let olderTurnPageSize = 5
    static let duplicateOlderPageSkipLimit = 12
}

struct ThreadTurnsHistoryPage {
    let turns: [JSONValue]
    let nextCursor: JSONValue
}

extension CodexService {
    // Fetches one cursor page from Codex app-server and keeps the response shape tolerant.
    private func fetchThreadTurnsHistoryPage(
        threadId: String,
        limit: Int,
        cursor: JSONValue?,
        timeoutNanoseconds: UInt64
    ) async throws -> ThreadTurnsHistoryPage {
        var params: RPCObject = [
            "threadId": .string(threadId),
            "limit": .integer(limit),
            "sortDirection": .string("desc"),
        ]
        if let cursor, cursorHasValue(cursor) {
            params["cursor"] = cursor
        }

        let response = try await sendRequest(
            method: "thread/turns/list",
            params: .object(params),
            timeoutNanoseconds: timeoutNanoseconds
        )

        guard let resultObject = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("thread/turns/list response missing payload")
        }
        let turns =
            resultObject["data"]?.arrayValue
            ?? resultObject["items"]?.arrayValue
            ?? resultObject["turns"]?.arrayValue
        guard let turns else {
            throw CodexServiceError.invalidResponse("thread/turns/list response missing data array")
        }

        return ThreadTurnsHistoryPage(
            turns: turns,
            nextCursor: threadTurnsListCursor(from: resultObject)
        )
    }

    // Starts with Litter-sized pages so long chats always expose older history through a real cursor.
    func fetchInitialThreadTurnsHistoryPage(threadId: String) async throws -> ThreadTurnsHistoryPage {
        let startedAt = Date()
        let page = try await fetchThreadTurnsHistoryPage(
            threadId: threadId,
            limit: ThreadHistoryHydrationPolicy.initialTurnPageSize,
            cursor: nil,
            timeoutNanoseconds: ThreadHistoryHydrationPolicy.initialPageSoftTimeoutNanoseconds
        )
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        debugSyncLog("thread/turns/list initial thread=\(threadId) limit=\(ThreadHistoryHydrationPolicy.initialTurnPageSize) turns=\(page.turns.count) hasNextCursor=\(cursorHasValue(page.nextCursor)) elapsedMs=\(elapsedMs)")
        return page
    }

    // Legacy fallback for old runtimes that cannot page turns; still bounded by the chat-open timeout.
    func fetchLegacyThreadHistoryObject(threadId: String) async throws -> RPCObject {
        let response = try await sendRequest(
            method: "thread/read",
            params: .object([
                "threadId": .string(threadId),
                "includeTurns": .bool(true),
            ]),
            timeoutNanoseconds: ThreadHistoryHydrationPolicy.requestTimeoutNanoseconds
        )

        guard let threadObject = response.result?.objectValue?["thread"]?.objectValue else {
            throw CodexServiceError.invalidResponse("thread/read response missing thread payload")
        }
        return threadObject
    }

    // Loads the next older page after local rows have all been revealed by the timeline.
    func loadOlderThreadHistoryPage(threadId: String) async {
        guard let cursor = olderThreadHistoryCursorByThreadID[threadId],
              cursorHasValue(cursor),
              !hasKnownLocalHistoryStart(threadId: threadId),
              !loadingOlderThreadHistoryIDs.contains(threadId) else {
            return
        }

        loadingOlderThreadHistoryIDs.insert(threadId)
        olderHistoryLoadErrorByThreadID.removeValue(forKey: threadId)
        refreshThreadTimelineState(for: threadId)
        defer {
            loadingOlderThreadHistoryIDs.remove(threadId)
            refreshThreadTimelineState(for: threadId)
        }

        do {
            var pageCursor = cursor
            var duplicatePagesSkipped = 0

            while true {
                let startedAt = Date()
                debugSyncLog("thread/turns/list older start thread=\(threadId) limit=\(ThreadHistoryHydrationPolicy.olderTurnPageSize)")
                let page = try await fetchThreadTurnsHistoryPage(
                    threadId: threadId,
                    limit: ThreadHistoryHydrationPolicy.olderTurnPageSize,
                    cursor: pageCursor,
                    timeoutNanoseconds: ThreadHistoryHydrationPolicy.requestTimeoutNanoseconds
                )
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                let hasNextCursor = cursorHasValue(page.nextCursor)
                debugSyncLog("thread/turns/list older thread=\(threadId) limit=\(ThreadHistoryHydrationPolicy.olderTurnPageSize) turns=\(page.turns.count) hasNextCursor=\(hasNextCursor) elapsedMs=\(elapsedMs)")
                guard !Task.isCancelled else {
                    return
                }

                let threadObject: RPCObject = [
                    "id": .string(threadId),
                    "turns": .array(chronologicalTurnsFromDescendingPage(page.turns)),
                ]
                let olderMessages = decodeMessagesFromThreadRead(threadId: threadId, threadObject: threadObject)
                registerSubagentThreads(from: olderMessages, parentThreadId: threadId)

                let olderTerminalStates = decodeTurnTerminalStatesFromThreadRead(threadObject)
                _ = mergeHistoryTurnTerminalStates(
                    threadId: threadId,
                    terminalStatesByTurnID: olderTerminalStates
                )

                guard !olderMessages.isEmpty else {
                    if hasNextCursor,
                       page.nextCursor != pageCursor,
                       duplicatePagesSkipped < ThreadHistoryHydrationPolicy.duplicateOlderPageSkipLimit {
                        updateOlderThreadHistoryCursor(threadId: threadId, cursor: page.nextCursor)
                        pageCursor = page.nextCursor
                        duplicatePagesSkipped += 1
                        continue
                    }

                    debugSyncLog("thread/turns/list older empty page thread=\(threadId) hasNextCursor=\(hasNextCursor); advancing cursor")
                    finishOlderPageWithoutNewRows(
                        threadId: threadId,
                        nextCursor: page.nextCursor,
                        currentCursor: pageCursor
                    )
                    refreshThreadTimelineState(for: threadId)
                    return
                }

                let existingMessages = messagesByThread[threadId] ?? []
                let orderedOlderMessages = olderHistoryMessagesFilteredAndOrderedBeforeExisting(
                    olderMessages,
                    existingMessages: existingMessages
                )

                if orderedOlderMessages.isEmpty {
                    debugSyncLog("thread/turns/list older duplicate page thread=\(threadId) decodedMessages=\(olderMessages.count) hasNextCursor=\(hasNextCursor)")
                    if hasNextCursor,
                       page.nextCursor != pageCursor,
                       duplicatePagesSkipped < ThreadHistoryHydrationPolicy.duplicateOlderPageSkipLimit {
                        updateOlderThreadHistoryCursor(threadId: threadId, cursor: page.nextCursor)
                        pageCursor = page.nextCursor
                        duplicatePagesSkipped += 1
                        continue
                    }

                    debugSyncLog("thread/turns/list older duplicate pages exhausted thread=\(threadId) hasNextCursor=\(hasNextCursor); advancing cursor")
                    finishOlderPageWithoutNewRows(
                        threadId: threadId,
                        nextCursor: page.nextCursor,
                        currentCursor: pageCursor
                    )
                    refreshThreadTimelineState(for: threadId)
                    return
                }

                let merged = try await mergeHistoryMessagesOffMainActor(
                    existing: existingMessages,
                    history: orderedOlderMessages,
                    activeThreadIDs: Set(activeTurnIdByThread.keys),
                    runningThreadIDs: runningThreadIDs,
                    preferRecentWindow: false
                )

                guard !Task.isCancelled else {
                    return
                }

                if merged == existingMessages {
                    debugSyncLog("thread/turns/list older no-op page thread=\(threadId) decodedMessages=\(olderMessages.count) candidates=\(orderedOlderMessages.count) hasNextCursor=\(hasNextCursor)")
                    if hasNextCursor,
                       page.nextCursor != pageCursor,
                       duplicatePagesSkipped < ThreadHistoryHydrationPolicy.duplicateOlderPageSkipLimit {
                        updateOlderThreadHistoryCursor(threadId: threadId, cursor: page.nextCursor)
                        pageCursor = page.nextCursor
                        duplicatePagesSkipped += 1
                        continue
                    }

                    if !hasNextCursor {
                        updateOlderCursorOrMarkStart(threadId: threadId, nextCursor: page.nextCursor)
                        debugSyncLog("thread/turns/list older no-op after local start thread=\(threadId); hiding older button")
                        refreshThreadTimelineState(for: threadId)
                        return
                    }

                    finishOlderPageWithoutNewRows(
                        threadId: threadId,
                        nextCursor: page.nextCursor,
                        currentCursor: pageCursor
                    )
                    refreshThreadTimelineState(for: threadId)
                    return
                }

                updateOlderCursorOrMarkStart(
                    threadId: threadId,
                    nextCursor: page.nextCursor,
                    currentCursor: pageCursor
                )
                expandThreadTimelineProjectionForRemoteOlderMessages(
                    threadId: threadId,
                    addedCount: orderedOlderMessages.count
                )
                debugSyncLog("thread/turns/list older merge thread=\(threadId) decodedMessages=\(olderMessages.count) newMessages=\(orderedOlderMessages.count) totalMessages=\(merged.count) hasNextCursor=\(hasNextCursor)")
                messagesByThread[threadId] = merged
                persistMessages()
                updateCurrentOutput(for: threadId)
                return
            }
        } catch is CancellationError {
            return
        } catch {
            if consumeUnsupportedTurnPagination(error, attemptedMethod: "thread/turns/list") {
                return
            }
            noteThreadHistoryRemoteRevealFailed(threadId: threadId)
            olderHistoryLoadErrorByThreadID[threadId] = "Couldn't load earlier messages. Tap to retry."
            refreshThreadTimelineState(for: threadId)
            debugSyncLog("failed to load older history page for thread=\(threadId): \(error.localizedDescription)")
        }
    }

    // Exposed to the turn screen when either local projection or server cursor can reveal older rows.
    func canLoadOlderThreadHistory(threadId: String) -> Bool {
        (hasRemoteOlderThreadHistoryCursor(threadId: threadId)
            && !hasKnownLocalHistoryStart(threadId: threadId))
            || hasLocallyProjectedEarlierThreadHistory(threadId: threadId)
    }

    func hasRemoteOlderThreadHistoryCursor(threadId: String) -> Bool {
        cursorHasValue(olderThreadHistoryCursorByThreadID[threadId])
    }

    func hasAuthoritativeLocalHistoryStart(threadId: String) -> Bool {
        threadsWithAuthoritativeLocalHistoryStart.contains(threadId)
    }

    func hasKnownLocalHistoryStart(threadId: String) -> Bool {
        hasAuthoritativeLocalHistoryStart(threadId: threadId)
    }

    // Call only when the source proves the local cache includes the first turn.
    func markThreadLocalHistoryStartAuthoritative(_ threadId: String, clearRemoteCursor: Bool = false) {
        threadsWithAuthoritativeLocalHistoryStart.insert(threadId)
        exhaustedOlderThreadHistoryCursorByThreadID.removeValue(forKey: threadId)
        if clearRemoteCursor {
            clearOlderThreadHistoryCursor(threadId: threadId, persistState: false)
        }
        persistThreadHistoryPaginationState()
    }

    func isLoadingOlderThreadHistory(threadId: String) -> Bool {
        loadingOlderThreadHistoryIDs.contains(threadId)
    }

    // Treats resume metadata and first-turn hydration as separate milestones.
    func hasSatisfiedInitialThreadHistoryLoad(threadId: String) -> Bool {
        !supportsTurnPagination || initialTurnsLoadedByThreadID.contains(threadId)
    }

    func hasLocallyProjectedEarlierThreadHistory(threadId: String) -> Bool {
        let currentLimit = threadTimelineProjectionLimitByThreadID[threadId]
            ?? TurnTimelineProjectionPolicy.initialMessageLimit
        return (messagesByThread[threadId]?.count ?? 0) > currentLimit
    }

    // Expands the render snapshot window whenever the user asks to reveal older rows.
    func noteThreadHistoryRevealRequested(threadId: String, pageSize: Int) {
        let normalizedPageSize = max(1, pageSize)
        let currentLimit = threadTimelineProjectionLimitByThreadID[threadId]
            ?? TurnTimelineProjectionPolicy.initialMessageLimit
        let nextLimit = currentLimit + normalizedPageSize
        let totalMessages = messagesByThread[threadId]?.count ?? 0
        guard totalMessages > currentLimit else {
            if totalMessages > 0,
               hasKnownLocalHistoryStart(threadId: threadId)
                || localCacheStartsAtThreadCreation(
                    threadId: threadId,
                    existingMessages: messagesByThread[threadId] ?? []
                ) {
                markThreadLocalHistoryStartAuthoritative(threadId, clearRemoteCursor: true)
                debugSyncLog("thread history local start reached thread=\(threadId) limit=\(currentLimit) total=\(totalMessages); hiding older button")
            } else {
                debugSyncLog("thread history local reveal skipped thread=\(threadId) limit=\(currentLimit) total=\(totalMessages)")
            }
            refreshThreadTimelineState(for: threadId)
            return
        }
        threadTimelineProjectionLimitByThreadID[threadId] = nextLimit
        olderHistoryLoadErrorByThreadID.removeValue(forKey: threadId)
        if nextLimit >= totalMessages {
            if hasKnownLocalHistoryStart(threadId: threadId)
                || localCacheStartsAtThreadCreation(
                    threadId: threadId,
                    existingMessages: messagesByThread[threadId] ?? []
                ) {
                markThreadLocalHistoryStartAuthoritative(threadId, clearRemoteCursor: true)
                debugSyncLog("thread history local start reached thread=\(threadId) limit=\(nextLimit) total=\(totalMessages); hiding older button")
            }
        }
        debugSyncLog("thread history local reveal thread=\(threadId) fromLimit=\(currentLimit) toLimit=\(nextLimit) total=\(totalMessages)")

        if totalMessages > currentLimit {
            noteMessagesChanged(for: threadId)
            refreshThreadTimelineState(for: threadId)
        }
    }

    func noteThreadHistoryRevealRequested(threadId: String) {
        noteThreadHistoryRevealRequested(
            threadId: threadId,
            pageSize: TurnTimelineProjectionPolicy.messagePageSize
        )
    }

    // Rolls back an optimistic remote reveal when the server page did not arrive.
    func noteThreadHistoryRemoteRevealFailed(threadId: String) {
        let loadedCount = messagesByThread[threadId]?.count ?? 0
        let currentLimit = threadTimelineProjectionLimitByThreadID[threadId]
            ?? TurnTimelineProjectionPolicy.initialMessageLimit
        guard currentLimit > loadedCount else {
            return
        }

        threadTimelineProjectionLimitByThreadID[threadId] = max(
            TurnTimelineProjectionPolicy.initialMessageLimit,
            loadedCount
        )
        noteMessagesChanged(for: threadId)
        refreshThreadTimelineState(for: threadId)
    }

    // Fails open after a chat-load timeout but leaves a retryable reconcile trail behind.
    func markThreadHistoryDeferredAfterTimeout(threadId: String) {
        hydratedThreadIDs.insert(threadId)
        initialTurnsLoadedByThreadID.insert(threadId)
        if activeThreadId == threadId, (messagesByThread[threadId]?.isEmpty ?? true) {
            lastErrorMessage = "Couldn't load this chat yet. Retrying in the background."
        } else {
            olderHistoryLoadErrorByThreadID[threadId] = "Couldn't load earlier messages. Tap to retry."
        }
        markThreadNeedingCanonicalHistoryReconcile(threadId)
        refreshThreadTimelineState(for: threadId)
    }

    func clearDeferredThreadHistoryErrorIfNeeded(threadId: String) {
        olderHistoryLoadErrorByThreadID.removeValue(forKey: threadId)
        if activeThreadId == threadId,
           lastErrorMessage == "Couldn't load this chat yet. Retrying in the background." {
            lastErrorMessage = nil
        }
    }

    // Embedded legacy snapshots may contain full history; render only the first window, then reveal locally.
    func updateThreadTimelineProjectionForEmbeddedHistory(threadId: String, decodedMessageCount: Int) {
        threadTimelineProjectionLimitByThreadID[threadId] = max(
            threadTimelineProjectionLimitByThreadID[threadId] ?? 0,
            TurnTimelineProjectionPolicy.initialMessageLimit
        )
    }

    // First paginated pages can be larger than the default render window when a turn has many items.
    func seedThreadTimelineProjectionForPaginatedHistory(threadId: String, decodedMessageCount: Int) {
        threadTimelineProjectionLimitByThreadID[threadId] = max(
            threadTimelineProjectionLimitByThreadID[threadId] ?? 0,
            TurnTimelineProjectionPolicy.initialMessageLimit,
            decodedMessageCount
        )
    }

    // Remote older pages prepend rows, so the render window must expand with the successful page.
    private func expandThreadTimelineProjectionForRemoteOlderMessages(threadId: String, addedCount: Int) {
        guard addedCount > 0 else {
            return
        }
        let currentLimit = threadTimelineProjectionLimitByThreadID[threadId]
            ?? TurnTimelineProjectionPolicy.initialMessageLimit
        threadTimelineProjectionLimitByThreadID[threadId] = currentLimit + addedCount
    }

    // Descending pages arrive newest-first; the history decoder expects chronological turn order.
    func chronologicalTurnsFromDescendingPage(_ turns: [JSONValue]) -> [JSONValue] {
        Array(turns.reversed())
    }

    // Older pages are prepended chronologically; dedupe items without dropping partial turns.
    private func olderHistoryMessagesFilteredAndOrderedBeforeExisting(
        _ olderMessages: [CodexMessage],
        existingMessages: [CodexMessage]
    ) -> [CodexMessage] {
        let existingItemIDs = Set(existingMessages.compactMap { Self.normalizedHistoryIdentifier($0.itemId) })
        let existingMessageKeys = Set(existingMessages.map(Self.historyMessageKey(for:)))
        let filtered = olderMessages.filter { message in
            if let itemID = Self.normalizedHistoryIdentifier(message.itemId),
               existingItemIDs.contains(itemID) {
                return false
            }
            return !existingMessageKeys.contains(Self.historyMessageKey(for: message))
        }

        guard let firstExistingOrder = existingMessages.map(\.orderIndex).min() else {
            return filtered
        }

        var ordered = filtered
        let startOrder = firstExistingOrder - ordered.count
        for index in ordered.indices {
            ordered[index].orderIndex = startOrder + index
        }
        return ordered
    }

    // Accepts both generated app-server field names and older list-style aliases.
    private func threadTurnsListCursor(from resultObject: RPCObject) -> JSONValue {
        if let nextCursor = resultObject["nextCursor"] {
            return nextCursor
        }
        if let nextCursor = resultObject["next_cursor"] {
            return nextCursor
        }
        return .null
    }

    private func updateOlderThreadHistoryCursor(threadId: String, cursor: JSONValue) {
        if cursorHasValue(cursor) {
            exhaustedOlderThreadHistoryCursorByThreadID.removeValue(forKey: threadId)
            olderThreadHistoryCursorByThreadID[threadId] = cursor
            persistThreadHistoryPaginationState()
        } else {
            clearOlderThreadHistoryCursor(threadId: threadId)
        }
    }

    // A nil cursor on an older-page response is authoritative: the server says there is no earlier page.
    private func updateOlderCursorOrMarkStart(threadId: String, nextCursor: JSONValue, currentCursor: JSONValue? = nil) {
        if cursorHasValue(nextCursor) {
            if let currentCursor, nextCursor == currentCursor {
                markOlderThreadHistoryCursorExhausted(threadId: threadId, cursor: currentCursor)
                return
            }
            updateOlderThreadHistoryCursor(threadId: threadId, cursor: nextCursor)
        } else {
            markThreadLocalHistoryStartAuthoritative(threadId, clearRemoteCursor: true)
        }
    }

    // Duplicate or empty pages must still make forward progress; an unchanged cursor would loop forever.
    private func finishOlderPageWithoutNewRows(threadId: String, nextCursor: JSONValue, currentCursor: JSONValue) {
        updateOlderCursorOrMarkStart(
            threadId: threadId,
            nextCursor: nextCursor,
            currentCursor: currentCursor
        )
    }

    private func markOlderThreadHistoryCursorExhausted(threadId: String, cursor: JSONValue) {
        olderThreadHistoryCursorByThreadID.removeValue(forKey: threadId)
        olderHistoryLoadErrorByThreadID.removeValue(forKey: threadId)
        exhaustedOlderThreadHistoryCursorByThreadID[threadId] = cursor
        persistThreadHistoryPaginationState()
    }

    private func clearOlderThreadHistoryCursor(
        threadId: String,
        persistState: Bool = true,
        clearExhaustedCursor: Bool = true
    ) {
        olderThreadHistoryCursorByThreadID.removeValue(forKey: threadId)
        olderHistoryLoadErrorByThreadID.removeValue(forKey: threadId)
        if clearExhaustedCursor {
            exhaustedOlderThreadHistoryCursorByThreadID.removeValue(forKey: threadId)
        }
        if persistState {
            persistThreadHistoryPaginationState()
        }
    }

    // Only the first paginated hydration seeds the older cursor. Later fresh pages
    // must not revive "Load earlier" after the user already reached the start.
    func updateOlderThreadHistoryCursorFromInitialPage(threadId: String, cursor: JSONValue, isFreshInitialLoad: Bool) {
        guard isFreshInitialLoad else {
            return
        }
        if hasAuthoritativeLocalHistoryStart(threadId: threadId) {
            clearOlderThreadHistoryCursor(threadId: threadId)
            return
        }
        if cursorHasValue(cursor) {
            if exhaustedOlderThreadHistoryCursorByThreadID[threadId] == cursor {
                clearOlderThreadHistoryCursor(threadId: threadId, clearExhaustedCursor: false)
                return
            }
            threadsWithAuthoritativeLocalHistoryStart.remove(threadId)
            updateOlderThreadHistoryCursor(threadId: threadId, cursor: cursor)
        } else {
            markThreadLocalHistoryStartAuthoritative(threadId, clearRemoteCursor: true)
        }
    }

    private func cursorHasValue(_ cursor: JSONValue?) -> Bool {
        guard let cursor else {
            return false
        }
        switch cursor {
        case .null:
            return false
        case .string(let value):
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }

    // Persists only cursor and "known start" metadata; the render window itself remains transient UI state.
    func persistThreadHistoryPaginationState() {
        let threadIDs = Set(olderThreadHistoryCursorByThreadID.keys)
            .union(threadsWithAuthoritativeLocalHistoryStart)
            .union(exhaustedOlderThreadHistoryCursorByThreadID.keys)
        let stateByThreadID = threadIDs.reduce(into: [String: CodexThreadHistoryPaginationState]()) { partial, threadId in
            let cursor = olderThreadHistoryCursorByThreadID[threadId]
            let exhaustedCursor = exhaustedOlderThreadHistoryCursorByThreadID[threadId]
            let hasCursor = cursorHasValue(cursor)
            let hasExhaustedCursor = cursorHasValue(exhaustedCursor)
            let hasAuthoritativeStart = threadsWithAuthoritativeLocalHistoryStart.contains(threadId)
            guard hasCursor || hasExhaustedCursor || hasAuthoritativeStart else {
                return
            }
            partial[threadId] = CodexThreadHistoryPaginationState(
                olderCursor: hasCursor ? cursor : nil,
                exhaustedOlderCursor: hasExhaustedCursor ? exhaustedCursor : nil,
                hasAuthoritativeLocalHistoryStart: hasAuthoritativeStart
            )
        }

        guard !stateByThreadID.isEmpty else {
            defaults.removeObject(forKey: Self.threadHistoryPaginationStateDefaultsKey)
            return
        }
        guard let data = try? encoder.encode(stateByThreadID) else {
            return
        }
        defaults.set(data, forKey: Self.threadHistoryPaginationStateDefaultsKey)
    }

    // One-time migration for transcripts saved before cursor-backed history existed.
    func shouldTrustExistingCacheAsPrePaginationFullHistory(
        threadId: String,
        existingMessages: [CodexMessage],
        paginatedMessages: [CodexMessage],
        hadInitialTurnsLoadedBeforeRefresh: Bool,
        hadAuthoritativeLocalStartBeforeRefresh: Bool
    ) -> Bool {
        guard !hadInitialTurnsLoadedBeforeRefresh,
              !hadAuthoritativeLocalStartBeforeRefresh,
              !paginatedMessages.isEmpty,
              existingMessages.count > paginatedMessages.count else {
            return false
        }

        let existingItemIDs = Set(existingMessages.compactMap { Self.normalizedHistoryIdentifier($0.itemId) })
        let existingKeys = Set(existingMessages.map(Self.historyMessageKey(for:)))
        let exactOverlapCount = paginatedMessages.reduce(into: 0) { count, message in
            if let itemID = Self.normalizedHistoryIdentifier(message.itemId),
               existingItemIDs.contains(itemID) {
                count += 1
                return
            }
            if existingKeys.contains(Self.historyMessageKey(for: message)) {
                count += 1
            }
        }
        let localStartsAtThreadCreation = localCacheStartsAtThreadCreation(
            threadId: threadId,
            existingMessages: existingMessages
        )
        let localHasSubstantialPrefix = existingMessages.count >= max(
            TurnTimelineProjectionPolicy.initialMessageLimit,
            paginatedMessages.count * 2
        )

        return localStartsAtThreadCreation
            && localHasSubstantialPrefix
            && exactOverlapCount > 0
    }

    // A persisted cache whose oldest row is at the thread creation time came from a full-history load.
    private func localCacheStartsAtThreadCreation(threadId: String, existingMessages: [CodexMessage]) -> Bool {
        guard let threadCreatedAt = thread(for: threadId)?.createdAt,
              CodexTimestampParser.isTrustworthyServerDate(threadCreatedAt),
              let oldestMessageDate = existingMessages.map(\.createdAt).min(),
              CodexTimestampParser.isTrustworthyServerDate(oldestMessageDate) else {
            return false
        }

        return oldestMessageDate <= threadCreatedAt.addingTimeInterval(180)
    }

    // Recognizes the mobile-side timeout used to avoid permanently blocking chat opening.
    func shouldDeferThreadHistoryAfterTimeout(_ error: CodexServiceError) -> Bool {
        guard case .invalidInput(let message) = error else {
            return false
        }
        return (
            message.localizedCaseInsensitiveContains("thread/read")
                || message.localizedCaseInsensitiveContains("thread/turns/list")
        )
            && message.localizedCaseInsensitiveContains("timed out")
    }
}
