// FILE: CodexService+ThreadsTurns.swift
// Purpose: Thread/turn operations exposed to the UI.
// Layer: Service
// Exports: CodexService thread+turn APIs
// Depends on: CodexThread, JSONValue

import Foundation

extension CodexService {
    // Keeps sidebar/project loading focused on recent conversations without hiding
    // other active project groups when the latest chats all belong to one repo.
    var recentThreadListLimit: Int { 40 }

    // Encodes manual approval replies using the app-server decision object shape.
    func approvalDecisionResult(_ decision: String) -> JSONValue {
        .object(["decision": .string(decision)])
    }

    func listThreads(limit: Int? = nil) async throws {
        isLoadingThreads = true
        defer { isLoadingThreads = false }

        let effectiveLimit = limit ?? recentThreadListLimit
        let activeThreads = try await fetchServerThreads(limit: effectiveLimit)

        var archivedThreads: [CodexThread] = []
        do {
            archivedThreads = try await fetchServerThreads(limit: effectiveLimit, archived: true)
        } catch {
            debugSyncLog("thread/list archived fetch failed (non-fatal): \(error.localizedDescription)")
        }

        reconcileLocalThreadsWithServer(activeThreads, serverArchivedThreads: archivedThreads)

        if activeThreadId == nil {
            activeThreadId = firstLiveThreadID()
        }
    }

    // Preserves the older startThread symbol used by most call sites and incremental builds.
    func startThread(
        preferredProjectPath: String? = nil,
        runtimeOverride: CodexThreadRuntimeOverride? = nil
    ) async throws -> CodexThread {
        try await startThreadImpl(
            preferredProjectPath: preferredProjectPath,
            pendingComposerAction: nil,
            runtimeOverride: runtimeOverride
        )
    }

    // Starts a new thread and seeds a one-shot composer action for the destination thread.
    func startThread(
        preferredProjectPath: String? = nil,
        pendingComposerAction: CodexPendingThreadComposerAction,
        runtimeOverride: CodexThreadRuntimeOverride? = nil
    ) async throws -> CodexThread {
        try await startThreadImpl(
            preferredProjectPath: preferredProjectPath,
            pendingComposerAction: pendingComposerAction,
            runtimeOverride: runtimeOverride
        )
    }

    // Starts a new thread and stores it in local state.
    private func startThreadImpl(
        preferredProjectPath: String? = nil,
        pendingComposerAction: CodexPendingThreadComposerAction? = nil,
        runtimeOverride: CodexThreadRuntimeOverride? = nil
    ) async throws -> CodexThread {
        let normalizedPreferredProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(preferredProjectPath)
        // Brand-new chats start from app defaults; per-chat overrides are inherited only on continuation.
        let explicitServiceTier = runtimeOverride?.overridesServiceTier == true
            ? runtimeOverride?.serviceTierRawValue
            : runtimeServiceTierForTurn()
        var includesServiceTier = explicitServiceTier != nil

        while true {
            let params = CodexThreadStartProjectBinding.makeThreadStartParams(
                modelIdentifier: runtimeModelIdentifierForTurn(),
                preferredProjectPath: normalizedPreferredProjectPath,
                serviceTier: includesServiceTier ? explicitServiceTier : nil
            )

            do {
                let response = try await sendRequestWithSandboxFallback(method: "thread/start", baseParams: params)

                guard let result = response.result,
                      let resultObject = result.objectValue,
                      let threadValue = resultObject["thread"],
                      let decodedThread = decodeModel(CodexThread.self, from: threadValue) else {
                    throw CodexServiceError.invalidResponse("thread/start response missing thread")
                }

                let thread = CodexThreadStartProjectBinding.applyPreferredProjectFallback(
                    to: decodedThread,
                    preferredProjectPath: normalizedPreferredProjectPath
                )
                if let pendingComposerAction {
                    queuePendingComposerAction(pendingComposerAction, for: thread.id)
                }
                if let runtimeOverride, !runtimeOverride.isEmpty {
                    applyThreadRuntimeOverride(runtimeOverride, to: thread.id)
                }
                upsertThread(thread)
                resumedThreadIDs.insert(thread.id)
                activeThreadId = thread.id
                return thread
            } catch {
                guard consumeUnsupportedServiceTier(error, includesServiceTier: &includesServiceTier) else {
                    throw error
                }
            }
        }
    }

    // Stores one-shot composer setup so a newly created thread can open in the requested mode.
    func queuePendingComposerAction(_ action: CodexPendingThreadComposerAction, for threadId: String) {
        pendingComposerActionByThreadID[threadId] = action
    }

    // Consumes the pending composer setup once the destination thread view appears.
    func consumePendingComposerAction(for threadId: String) -> CodexPendingThreadComposerAction? {
        pendingComposerActionByThreadID.removeValue(forKey: threadId)
    }

    // Sends user input as a new turn against an existing (or newly created) thread.
    func startTurn(
        userInput: String,
        threadId: String?,
        attachments: [CodexImageAttachment] = [],
        skillMentions: [CodexTurnSkillMention] = [],
        shouldAppendUserMessage: Bool = true,
        collaborationMode: CodexCollaborationModeKind? = nil
    ) async throws {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || !attachments.isEmpty else {
            throw CodexServiceError.invalidInput("User input and images cannot both be empty")
        }

        let initialThreadId = try await resolveThreadID(threadId)

        do {
            try await ensureThreadResumed(threadId: initialThreadId)
        } catch {
            if shouldTreatAsThreadNotFound(error) {
                handleMissingThread(initialThreadId)

                let continuationThread = try await createContinuationThread(from: initialThreadId)
                try await ensureThreadResumed(threadId: continuationThread.id)
                try await sendTurnStart(
                    trimmedInput,
                    attachments: attachments,
                    skillMentions: skillMentions,
                    to: continuationThread.id,
                    shouldAppendUserMessage: shouldAppendUserMessage,
                    collaborationMode: collaborationMode
                )
                activeThreadId = continuationThread.id
                lastErrorMessage = nil
                return
            }
        }

        do {
            try await sendTurnStart(
                trimmedInput,
                attachments: attachments,
                skillMentions: skillMentions,
                to: initialThreadId,
                shouldAppendUserMessage: shouldAppendUserMessage,
                collaborationMode: collaborationMode
            )
        } catch {
            if shouldTreatAsThreadNotFound(error) {
                // If turn/start explicitly says "thread not found", treat it as authoritative.
                // Some server states can make thread/read flaky, so we avoid blocking on a second check.
                if shouldAppendUserMessage {
                    removeLatestFailedUserMessage(
                        threadId: initialThreadId,
                        matchingText: trimmedInput,
                        matchingAttachments: attachments
                    )
                }
                handleMissingThread(initialThreadId)

                let continuationThread = try await createContinuationThread(from: initialThreadId)
                try await sendTurnStart(
                    trimmedInput,
                    attachments: attachments,
                    skillMentions: skillMentions,
                    to: continuationThread.id,
                    shouldAppendUserMessage: shouldAppendUserMessage,
                    collaborationMode: collaborationMode
                )
                activeThreadId = continuationThread.id
                lastErrorMessage = nil
                return
            }
            throw error
        }

        activeThreadId = initialThreadId
    }

    // Requests interruption for the active turn.
    func interruptTurn(turnId: String?, threadId: String? = nil) async throws {
        let normalizedThreadID = normalizedInterruptIdentifier(threadId)
            ?? normalizedInterruptIdentifier(activeThreadId)

        var normalizedTurnID = normalizedInterruptIdentifier(turnId)
        if normalizedTurnID == nil,
           let normalizedThreadID {
            normalizedTurnID = normalizedInterruptIdentifier(activeTurnIdByThread[normalizedThreadID])
        }
        if normalizedTurnID == nil {
            normalizedTurnID = normalizedInterruptIdentifier(activeTurnId)
        }
        if normalizedTurnID == nil,
           let normalizedThreadID {
            do {
                normalizedTurnID = try await resolveInFlightTurnID(threadId: normalizedThreadID)
            } catch {
                if let serviceError = error as? CodexServiceError,
                   case .invalidInput(_) = serviceError,
                   protectedRunningFallbackThreadIDs.contains(normalizedThreadID),
                   activeTurnID(for: normalizedThreadID) == nil {
                    demoteVisibleRunningStateToProtectedFallback(for: normalizedThreadID)
                }
                lastErrorMessage = userFacingTurnErrorMessage(from: error)
                throw error
            }
        }

        guard let normalizedTurnID else {
            throw CodexServiceError.invalidInput("turn/interrupt requires a non-empty turnId")
        }

        let resolvedThreadID = normalizedThreadID
            ?? threadIdByTurnID[normalizedTurnID]
            ?? normalizedInterruptIdentifier(activeThreadId)
        if let resolvedThreadID {
            threadIdByTurnID[normalizedTurnID] = resolvedThreadID
        }

        do {
            try await sendInterruptRequest(
                turnId: normalizedTurnID,
                threadId: resolvedThreadID,
                useSnakeCaseParams: false
            )
            return
        } catch {
            var finalError: Error = error

            if shouldRetryInterruptWithSnakeCaseParams(error) {
                do {
                    try await sendInterruptRequest(
                        turnId: normalizedTurnID,
                        threadId: resolvedThreadID,
                        useSnakeCaseParams: true
                    )
                    return
                } catch {
                    finalError = error
                }
            }

            if let resolvedThreadID,
               shouldRetryInterruptWithRefreshedTurnID(finalError),
               let refreshedTurnID = try await resolveInFlightTurnID(threadId: resolvedThreadID),
               refreshedTurnID != normalizedTurnID {
                do {
                    try await sendInterruptRequest(
                        turnId: refreshedTurnID,
                        threadId: resolvedThreadID,
                        useSnakeCaseParams: false
                    )
                    setActiveTurnID(refreshedTurnID, for: resolvedThreadID)
                    threadIdByTurnID[refreshedTurnID] = resolvedThreadID
                    return
                } catch {
                    finalError = error
                    if shouldRetryInterruptWithSnakeCaseParams(error) {
                        do {
                            try await sendInterruptRequest(
                                turnId: refreshedTurnID,
                                threadId: resolvedThreadID,
                                useSnakeCaseParams: true
                            )
                            setActiveTurnID(refreshedTurnID, for: resolvedThreadID)
                            threadIdByTurnID[refreshedTurnID] = resolvedThreadID
                            return
                        } catch {
                            finalError = error
                        }
                    }
                }
            }

            lastErrorMessage = userFacingTurnErrorMessage(from: finalError)
            throw finalError
        }
    }

    // Queries server-side fuzzy file search using stable RPC (non-experimental).
    func fuzzyFileSearch(
        query: String,
        roots: [String],
        cancellationToken: String?
    ) async throws -> [CodexFuzzyFileMatch] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }

        let normalizedRoots = roots
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedRoots.isEmpty else {
            return []
        }

        let normalizedToken = cancellationToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenValue = (normalizedToken?.isEmpty == false) ? normalizedToken : nil

        let params: JSONValue = .object([
            "query": .string(normalizedQuery),
            "roots": .array(normalizedRoots.map { .string($0) }),
            "cancellationToken": tokenValue.map(JSONValue.string) ?? .null,
        ])

        let response = try await sendRequest(method: "fuzzyFileSearch", params: params)

        guard let decodedFiles = decodeFuzzyFileMatches(from: response.result) else {
            throw CodexServiceError.invalidResponse("fuzzyFileSearch response missing result.files")
        }

        return decodedFiles.map { match in
            let normalizedPath = normalizeFuzzyFilePath(path: match.path, root: match.root)
            return CodexFuzzyFileMatch(
                root: match.root,
                path: normalizedPath,
                fileName: match.fileName,
                score: match.score,
                indices: match.indices
            )
        }
    }

    // Loads available skills for one or more roots with shape-fallback compatibility.
    func listSkills(
        cwds: [String]?,
        forceReload: Bool = false
    ) async throws -> [CodexSkillMetadata] {
        let normalizedCwds = (cwds ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var paramsObject: RPCObject = [:]
        if !normalizedCwds.isEmpty {
            paramsObject["cwds"] = .array(normalizedCwds.map { .string($0) })
        }
        if forceReload {
            paramsObject["forceReload"] = .bool(true)
        }

        let response: RPCMessage
        do {
            response = try await sendRequest(method: "skills/list", params: .object(paramsObject))
        } catch {
            guard !normalizedCwds.isEmpty,
                  shouldRetrySkillsListWithCwdFallback(error) else {
                throw error
            }

            var fallbackParams: RPCObject = ["cwd": .string(normalizedCwds[0])]
            if forceReload {
                fallbackParams["forceReload"] = .bool(true)
            }
            response = try await sendRequest(method: "skills/list", params: .object(fallbackParams))
        }

        guard let decodedSkills = decodeSkillMetadata(from: response.result) else {
            throw CodexServiceError.invalidResponse("skills/list response missing result.data[].skills")
        }

        let dedupedByName = Dictionary(grouping: decodedSkills) { $0.normalizedName }
            .compactMap { _, bucket -> CodexSkillMetadata? in
                bucket.first(where: { $0.enabled }) ?? bucket.first
            }
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return dedupedByName
    }

    // Accepts the latest pending approval request.
    func approvePendingRequest(forSession: Bool = false) async throws {
        guard let request = pendingApproval else {
            throw CodexServiceError.noPendingApproval
        }

        let normalizedMethod = request.method.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCommandApproval = normalizedMethod == "item/commandExecution/requestApproval"
            || normalizedMethod == "item/command_execution/request_approval"
        let decision = (forSession && isCommandApproval) ? "acceptForSession" : "accept"

        try await sendResponse(id: request.requestID, result: approvalDecisionResult(decision))
        pendingApproval = nil
    }

    // Declines the latest pending approval request.
    func declinePendingRequest() async throws {
        guard let request = pendingApproval else {
            throw CodexServiceError.noPendingApproval
        }

        try await sendResponse(id: request.requestID, result: approvalDecisionResult("decline"))
        pendingApproval = nil
    }

    // Responds to item/tool/requestUserInput using the exact app-server answer envelope.
    func respondToStructuredUserInput(
        requestID: JSONValue,
        answersByQuestionID: [String: [String]]
    ) async throws {
        try await sendResponse(
            id: requestID,
            result: buildStructuredUserInputResponse(answersByQuestionID: answersByQuestionID)
        )
    }

    func buildStructuredUserInputResponse(
        answersByQuestionID: [String: [String]]
    ) -> JSONValue {
        let answersObject = answersByQuestionID.reduce(into: RPCObject()) { result, entry in
            let filteredAnswers = entry.value
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            result[entry.key] = .object([
                "answers": .array(filteredAnswers.map(JSONValue.string)),
            ])
        }

        return .object([
            "answers": .object(answersObject),
        ])
    }
}

enum CodexThreadStartProjectBinding {
    // Normalizes project paths before sending them to thread/start.
    static func normalizedProjectPath(_ rawValue: String?) -> String? {
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

    static func makeThreadStartParams(
        modelIdentifier: String?,
        preferredProjectPath: String?,
        serviceTier: String?
    ) -> RPCObject {
        var params: RPCObject = [:]

        if let modelIdentifier {
            params["model"] = .string(modelIdentifier)
        }

        if let preferredProjectPath {
            params["cwd"] = .string(preferredProjectPath)
        }

        if let serviceTier {
            params["serviceTier"] = .string(serviceTier)
        }

        return params
    }

    // Preserves project grouping even when older servers omit cwd in thread/start result.
    static func applyPreferredProjectFallback(to thread: CodexThread, preferredProjectPath: String?) -> CodexThread {
        guard thread.normalizedProjectPath == nil,
              let preferredProjectPath else {
            return thread
        }

        var patchedThread = thread
        patchedThread.cwd = preferredProjectPath
        return patchedThread
    }
}

extension CodexService {
    func fetchServerThreads(limit: Int? = nil, archived: Bool = false) async throws -> [CodexThread] {
        var allThreads: [CodexThread] = []
        var nextCursor: JSONValue = .null
        var hasRequestedFirstPage = false

        repeat {
            var params: RPCObject = [
                // Avoid the server's narrower default sourceKinds so multi-project history
                // includes threads started from the app-server flow as well.
                "sourceKinds": .array(threadListSourceKinds.map(JSONValue.string)),
                "cursor": nextCursor,
            ]
            if let limit {
                params["limit"] = .integer(limit)
            }
            if archived {
                params["archived"] = .bool(true)
            }

            let response = try await sendRequest(method: "thread/list", params: .object(params))

            guard let resultObject = response.result?.objectValue else {
                throw CodexServiceError.invalidResponse("thread/list response missing payload")
            }

            let page =
                resultObject["data"]?.arrayValue
                ?? resultObject["items"]?.arrayValue
                ?? resultObject["threads"]?.arrayValue
            guard let page else {
                throw CodexServiceError.invalidResponse("thread/list response missing data array")
            }

            allThreads.append(contentsOf: page.compactMap { decodeModel(CodexThread.self, from: $0) })
            nextCursor = nextThreadListCursor(from: resultObject)
            hasRequestedFirstPage = true
        } while shouldContinueThreadListPagination(
            nextCursor: nextCursor,
            limit: limit,
            hasRequestedFirstPage: hasRequestedFirstPage
        )

        return allThreads
    }

    // Requests all user-facing thread sources instead of relying on the server default.
    private var threadListSourceKinds: [String] {
        [
            "cli",
            "vscode",
            "appServer",
            "exec",
            "unknown",
        ]
    }

    // Accepts both modern and legacy cursor field names from thread/list responses.
    private func nextThreadListCursor(from resultObject: RPCObject) -> JSONValue {
        if let nextCursor = resultObject["nextCursor"] {
            return nextCursor
        }
        if let nextCursor = resultObject["next_cursor"] {
            return nextCursor
        }
        return .null
    }

    // Paginates until the server reports no cursor or the caller requested a capped page.
    private func shouldContinueThreadListPagination(
        nextCursor: JSONValue,
        limit: Int?,
        hasRequestedFirstPage: Bool
    ) -> Bool {
        guard hasRequestedFirstPage, limit == nil else {
            return false
        }

        switch nextCursor {
        case .null:
            return false
        case let .string(value):
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    func createContinuationThread(from archivedThreadId: String) async throws -> CodexThread {
        let continuationRuntimeOverride = threadRuntimeOverride(for: archivedThreadId)
        let continuationThread = try await startThread(runtimeOverride: continuationRuntimeOverride)
        appendSystemMessage(
            threadId: continuationThread.id,
            text: "Continued from archived thread `\(archivedThreadId)`"
        )
        return continuationThread
    }

    @discardableResult
    func ensureThreadResumed(
        threadId: String,
        force: Bool = false,
        preferredProjectPath: String? = nil,
        modelIdentifierOverride: String? = nil
    ) async throws -> CodexThread? {
        guard !threadId.isEmpty else {
            return nil
        }

        if !force, resumedThreadIDs.contains(threadId) {
            return thread(for: threadId)
        }

        var params: RPCObject = [
            "threadId": .string(threadId),
        ]
        let resolvedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(preferredProjectPath)
            ?? thread(for: threadId)?.gitWorkingDirectory
        if let workingDirectory = resolvedProjectPath {
            params["cwd"] = .string(workingDirectory)
        }
        if let modelIdentifier = modelIdentifierOverride ?? runtimeModelIdentifierForTurn() {
            params["model"] = .string(modelIdentifier)
        }
        let response = try await sendRequestWithSandboxFallback(method: "thread/resume", baseParams: params)

        guard let resultObject = response.result?.objectValue else {
            resumedThreadIDs.insert(threadId)
            return nil
        }

        var resumedThread: CodexThread?
        if let threadValue = resultObject["thread"],
           var decodedThread = decodeModel(CodexThread.self, from: threadValue) {
            decodedThread.syncState = .live
            upsertThread(decodedThread)
            resumedThread = decodedThread

            if let threadObject = threadValue.objectValue {
                let historyMessages = decodeMessagesFromThreadRead(threadId: threadId, threadObject: threadObject)
                registerSubagentThreads(from: historyMessages, parentThreadId: threadId)
                if !historyMessages.isEmpty {
                    let existingMessages = messagesByThread[threadId] ?? []
                    let activeThreadIDs = Set(activeTurnIdByThread.keys)
                    let runningIDs = runningThreadIDs
                    let merged = await Task.detached {
                        Self.mergeHistoryMessages(existingMessages, historyMessages, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningIDs)
                    }.value
                    // Forced resumes are used when reopening a running thread, so merge the
                    // latest snapshot even mid-run and let mergeHistoryMessages preserve
                    // existing streaming rows instead of waiting for the final block.
                    if (force || !threadHasActiveOrRunningTurn(threadId) || existingMessages.isEmpty)
                        && merged != existingMessages {
                        messagesByThread[threadId] = merged
                        persistMessages()
                        updateCurrentOutput(for: threadId)
                    }
                }
            }
        } else if let index = threadIndex(for: threadId) {
            threads[index].syncState = .live
        }

        hydratedThreadIDs.insert(threadId)
        resumedThreadIDs.insert(threadId)
        return resumedThread
    }

    func isThreadMissingOnServer(_ threadId: String) async -> Bool {
        let params: JSONValue = .object([
            "threadId": .string(threadId),
            "includeTurns": .bool(false),
        ])

        do {
            _ = try await sendRequest(method: "thread/read", params: params)
            return false
        } catch {
            return shouldTreatAsThreadNotFound(error)
        }
    }

    // Rebuilds active turn/running state from server truth after reconnect/background transitions.
    // Returns false when the snapshot could not be refreshed, so callers can fall back to history sync.
    func refreshInFlightTurnState(threadId: String) async -> Bool {
        let normalizedThreadID = normalizedInterruptIdentifier(threadId)
        guard let normalizedThreadID,
              isConnected,
              isInitialized else {
            return false
        }

        do {
            let snapshot = try await readThreadTurnStateSnapshot(threadId: normalizedThreadID)

            if let runningTurnID = snapshot.interruptibleTurnID {
                markThreadAsRunning(normalizedThreadID)
                setProtectedRunningFallback(false, for: normalizedThreadID)
                setActiveTurnID(runningTurnID, for: normalizedThreadID)
                threadIdByTurnID[runningTurnID] = normalizedThreadID
                activeTurnId = runningTurnID
                return true
            }

            if snapshot.hasInterruptibleTurnWithoutID {
                markThreadAsRunning(normalizedThreadID)
                setProtectedRunningFallback(true, for: normalizedThreadID)
            } else {
                clearRunningState(for: normalizedThreadID)
            }

            if let existingTurnID = activeTurnID(for: normalizedThreadID) {
                setActiveTurnID(nil, for: normalizedThreadID)
                if threadIdByTurnID[existingTurnID] == normalizedThreadID {
                    threadIdByTurnID.removeValue(forKey: existingTurnID)
                }
                if activeTurnId == existingTurnID {
                    activeTurnId = nil
                }
            }
            return true
        } catch {
            debugSyncLog("in-flight turn refresh failed thread=\(normalizedThreadID): \(error.localizedDescription)")
            return false
        }
    }

    func sendTurnStart(
        _ userInput: String,
        attachments: [CodexImageAttachment] = [],
        skillMentions: [CodexTurnSkillMention] = [],
        to threadId: String,
        shouldAppendUserMessage: Bool = true,
        collaborationMode: CodexCollaborationModeKind? = nil
    ) async throws {
        let pendingMessageId = shouldAppendUserMessage
            ? appendUserMessage(threadId: threadId, text: userInput, attachments: attachments)
            : ""
        activeThreadId = threadId
        markThreadAsRunning(threadId)
        setProtectedRunningFallback(true, for: threadId)

        var includeStructuredSkillItems = supportsStructuredSkillInput && !skillMentions.isEmpty
        var imageURLKey = "url"
        var effectiveCollaborationMode = supportsTurnCollaborationMode ? collaborationMode : nil
        var didDowngradePlanModeForRuntime = false
        var includesServiceTier = runtimeServiceTierForTurn(threadId: threadId) != nil

        while true {
            do {
                let requestParams = try buildTurnStartRequestParams(
                    threadId: threadId,
                    userInput: userInput,
                    attachments: attachments,
                    skillMentions: skillMentions,
                    imageURLKey: imageURLKey,
                    includeStructuredSkillItems: includeStructuredSkillItems,
                    collaborationMode: effectiveCollaborationMode,
                    includeServiceTier: includesServiceTier
                )
                let response = try await sendRequestWithSandboxFallback(
                    method: "turn/start",
                    baseParams: requestParams
                )
                handleSuccessfulTurnStartResponse(
                    response,
                    pendingMessageId: pendingMessageId,
                    threadId: threadId
                )
                if didDowngradePlanModeForRuntime {
                    appendSystemMessage(
                        threadId: threadId,
                        text: "Plan mode is not supported by this runtime. Sent as a normal turn instead."
                    )
                }
                return
            } catch {
                if includeStructuredSkillItems,
                   shouldRetryTurnStartWithoutSkillItems(error) {
                    // Disable structured skill input for this runtime after first incompatibility signal.
                    supportsStructuredSkillInput = false
                    includeStructuredSkillItems = false
                    continue
                }

                if imageURLKey == "url",
                   !attachments.isEmpty,
                   shouldRetryTurnStartWithImageURLField(error) {
                    imageURLKey = "image_url"
                    continue
                }

                if effectiveCollaborationMode != nil,
                   shouldRetryTurnStartWithoutCollaborationMode(error) {
                    // Remember the runtime limitation so future plan-mode sends skip the rejected field.
                    supportsTurnCollaborationMode = false
                    effectiveCollaborationMode = nil
                    didDowngradePlanModeForRuntime = true
                    continue
                }

                if consumeUnsupportedServiceTier(error, includesServiceTier: &includesServiceTier) {
                    continue
                }

                try handleTurnStartFailure(
                    error,
                    pendingMessageId: pendingMessageId,
                    threadId: threadId
                )
                return
            }
        }
    }

    // Steers an active turn using the same mixed input-item encoding as turn/start.
    func steerTurn(
        userInput: String,
        threadId: String,
        expectedTurnId: String?,
        attachments: [CodexImageAttachment] = [],
        skillMentions: [CodexTurnSkillMention] = [],
        shouldAppendUserMessage: Bool = true,
        collaborationMode: CodexCollaborationModeKind? = nil
    ) async throws {
        let normalizedThreadID = normalizedInterruptIdentifier(threadId) ?? threadId
        let pendingMessageId = shouldAppendUserMessage
            ? appendUserMessage(threadId: normalizedThreadID, text: userInput, attachments: attachments)
            : ""
        var resolvedExpectedTurnID = normalizedInterruptIdentifier(expectedTurnId)
        if resolvedExpectedTurnID == nil {
            do {
                resolvedExpectedTurnID = try await resolveInFlightTurnID(threadId: normalizedThreadID)
            } catch {
                handleSteerFailure(error, pendingMessageId: pendingMessageId, threadId: normalizedThreadID)
                throw error
            }
        }

        guard let initialTurnID = resolvedExpectedTurnID else {
            let error = CodexServiceError.invalidInput("No active turn available to steer")
            handleSteerFailure(error, pendingMessageId: pendingMessageId, threadId: normalizedThreadID)
            throw error
        }

        var includeStructuredSkillItems = supportsStructuredSkillInput && !skillMentions.isEmpty
        var imageURLKey = "url"
        var effectiveCollaborationMode = supportsTurnCollaborationMode ? collaborationMode : nil
        var currentExpectedTurnID = initialTurnID
        var didRetryWithRefreshedTurnID = false

        while true {
            var params: RPCObject = [
                "threadId": .string(normalizedThreadID),
                "expectedTurnId": .string(currentExpectedTurnID),
                "input": .array(
                    makeTurnInputPayload(
                        userInput: userInput,
                        attachments: attachments,
                        imageURLKey: imageURLKey,
                        skillMentions: skillMentions,
                        includeStructuredSkillItems: includeStructuredSkillItems
                    )
                ),
            ]
            if let collaborationModePayload = try buildCollaborationModePayload(
                for: effectiveCollaborationMode,
                threadId: normalizedThreadID
            ) {
                params["collaborationMode"] = collaborationModePayload
            }

            do {
                let response = try await sendRequest(method: "turn/steer", params: .object(params))
                let resolvedTurnID = extractTurnID(from: response.result) ?? currentExpectedTurnID
                markMessageDeliveryState(
                    threadId: normalizedThreadID,
                    messageId: pendingMessageId,
                    state: .confirmed,
                    turnId: resolvedTurnID
                )
                activeTurnId = resolvedTurnID
                setActiveTurnID(resolvedTurnID, for: normalizedThreadID)
                threadIdByTurnID[resolvedTurnID] = normalizedThreadID
                markThreadAsRunning(normalizedThreadID)
                setProtectedRunningFallback(false, for: normalizedThreadID)
                return
            } catch {
                if includeStructuredSkillItems,
                   shouldRetryTurnStartWithoutSkillItems(error) {
                    supportsStructuredSkillInput = false
                    includeStructuredSkillItems = false
                    continue
                }

                if imageURLKey == "url",
                   !attachments.isEmpty,
                   shouldRetryTurnStartWithImageURLField(error) {
                    imageURLKey = "image_url"
                    continue
                }

                if effectiveCollaborationMode != nil,
                   shouldRetryTurnStartWithoutCollaborationMode(error) {
                    // Keep steer compatible with runtimes that only support plain turns.
                    supportsTurnCollaborationMode = false
                    effectiveCollaborationMode = nil
                    continue
                }

                if !didRetryWithRefreshedTurnID,
                   shouldRetrySteerWithRefreshedTurnID(error) {
                    do {
                        if let refreshedTurnID = try await resolveInFlightTurnID(threadId: normalizedThreadID),
                           refreshedTurnID != currentExpectedTurnID {
                            didRetryWithRefreshedTurnID = true
                            currentExpectedTurnID = refreshedTurnID
                            activeTurnId = refreshedTurnID
                            setActiveTurnID(refreshedTurnID, for: normalizedThreadID)
                            threadIdByTurnID[refreshedTurnID] = normalizedThreadID
                            continue
                        }
                    } catch {
                        handleSteerFailure(error, pendingMessageId: pendingMessageId, threadId: normalizedThreadID)
                        throw error
                    }
                }

                handleSteerFailure(error, pendingMessageId: pendingMessageId, threadId: normalizedThreadID)
                throw error
            }
        }
    }

    func userFacingTurnErrorMessage(from error: Error) -> String {
        if let serviceError = error as? CodexServiceError {
            switch serviceError {
            case .rpcError(let rpcError):
                let trimmed = rpcError.message.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? serviceError.localizedDescription : trimmed
            default:
                let trimmed = serviceError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "Error while sending message" : trimmed
            }
        }

        let trimmed = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Error while sending message" : trimmed
    }

    // Normalizes outgoing turn input so we can support mixed text + image messages.
    func makeTurnInputPayload(
        userInput: String,
        attachments: [CodexImageAttachment],
        imageURLKey: String,
        skillMentions: [CodexTurnSkillMention] = [],
        includeStructuredSkillItems: Bool = true
    ) -> [JSONValue] {
        var inputItems: [JSONValue] = []

        for attachment in attachments {
            guard let payloadDataURL = attachment.payloadDataURL,
                  !payloadDataURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            inputItems.append(
                .object([
                    "type": .string("image"),
                    imageURLKey: .string(payloadDataURL),
                ])
            )
        }

        let trimmedText = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            inputItems.append(
                .object([
                    "type": .string("text"),
                    "text": .string(trimmedText),
                ])
            )
        }

        if includeStructuredSkillItems {
            for mention in skillMentions {
                let normalizedSkillID = mention.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSkillID.isEmpty else {
                    continue
                }

                var payload: RPCObject = [
                    "type": .string("skill"),
                    "id": .string(normalizedSkillID),
                ]

                if let name = mention.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    payload["name"] = .string(name)
                }

                if let path = mention.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    payload["path"] = .string(path)
                }

                inputItems.append(.object(payload))
            }
        }

        return inputItems
    }

    // Builds turn/start params so retries can switch only the input-item encoding.
    func buildTurnStartRequestParams(
        threadId: String,
        userInput: String,
        attachments: [CodexImageAttachment],
        skillMentions: [CodexTurnSkillMention],
        imageURLKey: String,
        includeStructuredSkillItems: Bool,
        collaborationMode: CodexCollaborationModeKind?,
        includeServiceTier: Bool
    ) throws -> RPCObject {
        var params: RPCObject = [
            "threadId": .string(threadId),
            "input": .array(
                makeTurnInputPayload(
                    userInput: userInput,
                    attachments: attachments,
                    imageURLKey: imageURLKey,
                    skillMentions: skillMentions,
                    includeStructuredSkillItems: includeStructuredSkillItems
                )
            ),
        ]
        // Keep the legacy top-level fields populated so plan-mode turns still honor
        // the user's selected model on runtimes that do not read collaboration settings.
        if let modelIdentifier = runtimeModelIdentifierForTurn() {
            params["model"] = .string(modelIdentifier)
        }
        if let effort = selectedReasoningEffortForSelectedModel(threadId: threadId) {
            params["effort"] = .string(effort)
        }
        if includeServiceTier,
           let serviceTier = runtimeServiceTierForTurn(threadId: threadId) {
            params["serviceTier"] = .string(serviceTier)
        }
        if let collaborationModePayload = try buildCollaborationModePayload(
            for: collaborationMode,
            threadId: threadId
        ) {
            params["collaborationMode"] = collaborationModePayload
        }
        return params
    }

    // Encodes collaborationMode while allowing the selected mode to supply built-in instructions.
    func buildCollaborationModePayload(
        for mode: CodexCollaborationModeKind?,
        threadId: String?
    ) throws -> JSONValue? {
        guard let mode else {
            return nil
        }

        let resolvedModel = runtimeModelIdentifierForTurn()
            ?? selectedModelOption()?.model
            ?? availableModels.first?.model
            ?? selectedModelId
        guard let resolvedModel,
              !resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexServiceError.invalidResponse(
                "Plan mode requires an available model before starting a plan turn."
            )
        }

        return .object([
            "mode": .string(mode.rawValue),
            "settings": .object([
                "model": .string(resolvedModel),
                "reasoning_effort": selectedReasoningEffortForSelectedModel(
                    threadId: threadId
                ).map(JSONValue.string) ?? .null,
                "developer_instructions": .null,
            ]),
        ])
    }

    // Applies common failure bookkeeping for turn/start primary and fallback attempts.
    func handleTurnStartFailure(
        _ error: Error,
        pendingMessageId: String,
        threadId: String
    ) throws {
        markMessageDeliveryState(threadId: threadId, messageId: pendingMessageId, state: .failed)
        clearRunningState(for: threadId)
        if shouldTreatAsThreadNotFound(error) {
            throw error
        }

        let errorMessage = userFacingTurnErrorMessage(from: error)
        lastErrorMessage = errorMessage
        appendSystemMessage(threadId: threadId, text: "Send error: \(errorMessage)")
        throw error
    }

    // Handles successful turn/start bookkeeping for both primary and fallback payload schemas.
    func handleSuccessfulTurnStartResponse(
        _ response: RPCMessage,
        pendingMessageId: String,
        threadId: String
    ) {
        let turnID = extractTurnID(from: response.result)
        let resolvedTurnID = turnID ?? activeTurnIdByThread[threadId]
        let deliveryState: CodexMessageDeliveryState = (resolvedTurnID == nil) ? .pending : .confirmed
        markMessageDeliveryState(
            threadId: threadId,
            messageId: pendingMessageId,
            state: deliveryState,
            turnId: resolvedTurnID
        )

        if let turnID = resolvedTurnID {
            activeTurnId = turnID
            setActiveTurnID(turnID, for: threadId)
            threadIdByTurnID[turnID] = threadId
            setProtectedRunningFallback(false, for: threadId)
            beginAssistantMessage(threadId: threadId, turnId: turnID)
        }

        if let index = threadIndex(for: threadId) {
            threads[index].updatedAt = Date()
            threads[index].syncState = .live
            threads = sortThreads(threads)
        }
    }

    // Applies steer failure bookkeeping for optimistic user rows without adding an extra system error card.
    func handleSteerFailure(
        _ error: Error,
        pendingMessageId: String,
        threadId: String
    ) {
        markMessageDeliveryState(threadId: threadId, messageId: pendingMessageId, state: .failed)
        lastErrorMessage = userFacingTurnErrorMessage(from: error)
    }

    // Some server versions expect `image_url` instead of `url` for image items.
    func shouldRetryTurnStartWithImageURLField(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        let message = rpcError.message.lowercased()
        guard message.contains("image_url") else {
            return false
        }

        return message.contains("missing")
            || message.contains("unknown field")
            || message.contains("expected")
            || message.contains("invalid")
    }

    // Detects legacy servers that reject input items with `type: "skill"`.
    func shouldRetryTurnStartWithoutSkillItems(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        let message = rpcError.message.lowercased()
        guard message.contains("skill") else {
            return false
        }

        return message.contains("unknown")
            || message.contains("unsupported")
            || message.contains("invalid")
            || message.contains("expected")
            || message.contains("unrecognized")
            || message.contains("type")
            || message.contains("field")
    }

    // Detects runtimes that reject plan-mode `collaborationMode` without `experimentalApi`.
    func shouldRetryTurnStartWithoutCollaborationMode(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        let message = rpcError.message.lowercased()
        guard message.contains("collaborationmode") || message.contains("collaboration_mode") else {
            return false
        }

        return message.contains("experimentalapi")
            || message.contains("unsupported")
            || message.contains("unknown")
            || message.contains("unexpected")
            || message.contains("unrecognized")
            || message.contains("invalid")
            || message.contains("field")
            || message.contains("mode")
    }

    // Parses `result.files` so tests can validate decoding without transport wiring.
    func decodeFuzzyFileMatches(from result: JSONValue?) -> [CodexFuzzyFileMatch]? {
        guard let resultObject = result?.objectValue,
              let filesValue = resultObject["files"] else {
            return nil
        }

        return decodeModel([CodexFuzzyFileMatch].self, from: filesValue)
    }

    // Parses skills/list payloads from both bucketed and flat server response shapes.
    func decodeSkillMetadata(from result: JSONValue?) -> [CodexSkillMetadata]? {
        guard let resultObject = result?.objectValue else {
            return nil
        }

        var collectedSkills: [CodexSkillMetadata] = []
        var hasSkillContainer = false

        if let dataItems = resultObject["data"]?.arrayValue {
            hasSkillContainer = true
            for item in dataItems {
                guard let itemObject = item.objectValue else {
                    continue
                }
                if let skillsValue = itemObject["skills"],
                   let decodedSkills = decodeModel([CodexSkillMetadata].self, from: skillsValue) {
                    collectedSkills.append(contentsOf: decodedSkills)
                }
            }

            if collectedSkills.isEmpty,
               let decodedSkills = decodeModel([CodexSkillMetadata].self, from: .array(dataItems)) {
                collectedSkills.append(contentsOf: decodedSkills)
            }
        }

        if collectedSkills.isEmpty,
           let skillsValue = resultObject["skills"],
           let decodedSkills = decodeModel([CodexSkillMetadata].self, from: skillsValue) {
            hasSkillContainer = true
            collectedSkills.append(contentsOf: decodedSkills)
        } else if resultObject["skills"] != nil {
            hasSkillContainer = true
        }

        return hasSkillContainer ? collectedSkills : nil
    }

    func shouldRetrySkillsListWithCwdFallback(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        guard rpcError.code == -32600 || rpcError.code == -32602 else {
            return false
        }

        let message = rpcError.message.lowercased()
        return message.contains("invalid")
            || message.contains("unknown field")
            || message.contains("unrecognized field")
            || message.contains("missing field")
            || message.contains("expected")
            || message.contains("cwds")
    }

    // Sends turn interruption request with camelCase or snake_case param keys for compatibility.
    func sendInterruptRequest(
        turnId: String,
        threadId: String?,
        useSnakeCaseParams: Bool
    ) async throws {
        var params: RPCObject = [:]
        params[useSnakeCaseParams ? "turn_id" : "turnId"] = .string(turnId)
        if let threadId {
            params[useSnakeCaseParams ? "thread_id" : "threadId"] = .string(threadId)
        }
        _ = try await sendRequest(method: "turn/interrupt", params: .object(params))
    }

    // Normalizes ids coming from UI/runtime state before RPC usage.
    func normalizedInterruptIdentifier(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Resolves the currently interruptible turn id from thread/read when local state becomes stale.
    // If the runtime reports "running" without an id yet, surface that instead of falling
    // back to the latest completed turn and interrupting the wrong run.
    func resolveInFlightTurnID(threadId: String) async throws -> String? {
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            let snapshot = try await readThreadTurnStateSnapshot(threadId: threadId)
            if let interruptibleTurnID = snapshot.interruptibleTurnID {
                return interruptibleTurnID
            }
            if snapshot.hasInterruptibleTurnWithoutID {
                if attempt < (maxAttempts - 1) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                throw CodexServiceError.invalidInput(
                    "The active run has not published an interruptible turn ID yet. Please try again in a moment."
                )
            }
            return nil
        }
        return nil
    }

    // Parses turn status values from thread/read turn objects.
    func normalizedInterruptTurnStatus(from turnObject: [String: JSONValue]) -> String? {
        let status = turnObject["status"]?.stringValue
            ?? turnObject["turnStatus"]?.stringValue
            ?? turnObject["turn_status"]?.stringValue

        guard let status else { return nil }

        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return trimmed
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    // Marks statuses that can still accept turn/interrupt.
    func isInterruptibleTurnStatus(_ normalizedStatus: String?) -> Bool {
        guard let normalizedStatus else {
            return true
        }

        if normalizedStatus.contains("inprogress")
            || normalizedStatus.contains("running")
            || normalizedStatus.contains("pending")
            || normalizedStatus.contains("started") {
            return true
        }

        if normalizedStatus.contains("complete")
            || normalizedStatus.contains("failed")
            || normalizedStatus.contains("error")
            || normalizedStatus.contains("interrupt")
            || normalizedStatus.contains("cancel")
            || normalizedStatus.contains("stopped") {
            return false
        }

        return true
    }

    // Retries with snake_case params for strict or legacy server parsers.
    func shouldRetryInterruptWithSnakeCaseParams(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        guard rpcError.code == -32600 || rpcError.code == -32602 else {
            return false
        }

        let message = rpcError.message.lowercased()
        let hints = ["turnid", "threadid", "turn_id", "thread_id", "unknown field", "missing field", "invalid"]
        return hints.contains { message.contains($0) }
    }

    // Reads thread/read(includeTurns=true) and extracts both running and latest turn metadata.
    func readThreadTurnStateSnapshot(threadId: String) async throws -> (
        interruptibleTurnID: String?,
        hasInterruptibleTurnWithoutID: Bool,
        latestTurnID: String?
    ) {
        let response: RPCMessage
        do {
            response = try await sendRequest(
                method: "thread/read",
                params: .object([
                    "threadId": .string(threadId),
                    "includeTurns": .bool(true),
                ])
            )
        } catch {
            guard shouldRetryThreadReadTurnSnapshotWithSnakeCase(error) else {
                throw error
            }

            response = try await sendRequest(
                method: "thread/read",
                params: .object([
                    "thread_id": .string(threadId),
                    "include_turns": .bool(true),
                ])
            )
        }

        guard let threadObject = response.result?.objectValue?["thread"]?.objectValue else {
            return (nil, false, nil)
        }

        let turnObjects = threadObject["turns"]?.arrayValue?.compactMap { $0.objectValue } ?? []
        guard !turnObjects.isEmpty else {
            return (nil, false, nil)
        }

        let latestTurnID = turnObjects.reversed().compactMap { turnObject in
            normalizedInterruptIdentifier(
                turnObject["id"]?.stringValue
                    ?? turnObject["turnId"]?.stringValue
                    ?? turnObject["turn_id"]?.stringValue
            )
        }.first

        // Some thread/read payloads can include a newer completed turn after the currently
        // running one, so scan backwards for the most recent interruptible turn instead of
        // assuming the array tail is always the active run.
        var hasInterruptibleTurnWithoutID = false
        for turnObject in turnObjects.reversed() {
            let turnStatus = normalizedInterruptTurnStatus(from: turnObject)
            guard isInterruptibleTurnStatus(turnStatus) else {
                continue
            }

            if let interruptibleTurnID = normalizedInterruptIdentifier(
                turnObject["id"]?.stringValue
                    ?? turnObject["turnId"]?.stringValue
                    ?? turnObject["turn_id"]?.stringValue
            ) {
                return (interruptibleTurnID, false, latestTurnID)
            }

            hasInterruptibleTurnWithoutID = true
        }

        return (nil, hasInterruptibleTurnWithoutID, latestTurnID)
    }

    // Keeps stop recovery compatible with runtimes that only accept snake_case thread/read params.
    func shouldRetryThreadReadTurnSnapshotWithSnakeCase(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        guard rpcError.code == -32600 || rpcError.code == -32602 else {
            return false
        }

        let message = rpcError.message.lowercased()
        let hints = ["threadid", "includeturns", "thread_id", "include_turns", "unknown field", "missing field", "invalid"]
        return hints.contains { message.contains($0) }
    }

    // Retries after refreshing turn id when local activeTurn cache is stale.
    func shouldRetryInterruptWithRefreshedTurnID(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        let message = rpcError.message.lowercased()
        let hints = [
            "turn not found",
            "no active turn",
            "not in progress",
            "not running",
            "already completed",
            "already finished",
            "invalid turn",
            "no such turn",
            "not active",
            "does not exist",
            "cannot interrupt"
        ]
        return hints.contains { message.contains($0) }
    }

    // Retries steer once after refreshing the active turn id when the server rejects the precondition.
    func shouldRetrySteerWithRefreshedTurnID(_ error: Error) -> Bool {
        shouldRetryInterruptWithRefreshedTurnID(error)
    }

    // Converts absolute match paths to root-relative output when older servers return full paths.
    func normalizeFuzzyFilePath(path: String, root: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return path
        }

        let normalizedRoot = normalizedFuzzyRootPath(root)
        guard !normalizedRoot.isEmpty else {
            return trimmedPath
        }

        if normalizedRoot == "/" {
            return trimmedPath.hasPrefix("/") ? String(trimmedPath.dropFirst()) : trimmedPath
        }

        let rootPrefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : "\(normalizedRoot)/"
        if trimmedPath.hasPrefix(rootPrefix) {
            return String(trimmedPath.dropFirst(rootPrefix.count))
        }

        return trimmedPath
    }

    private func normalizedFuzzyRootPath(_ root: String) -> String {
        var normalized = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ""
        }

        if normalized == "/" {
            return normalized
        }

        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        return normalized.isEmpty ? "/" : normalized
    }
}
