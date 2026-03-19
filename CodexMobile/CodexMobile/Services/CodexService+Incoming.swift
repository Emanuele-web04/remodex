// FILE: CodexService+Incoming.swift
// Purpose: Inbound message decoding and event routing.
// Layer: Service
// Exports: CodexService inbound handlers
// Depends on: RPCMessage

import Foundation

typealias IncomingParamsObject = [String: JSONValue]

private struct CommandExecutionMessageContext {
    let threadId: String
    let turnId: String?
    let itemId: String?
}

// Off-actor wire message classification and JSON-RPC decoding so transport callbacks
// can parse before dispatching typed results to MainActor.
enum WireMessagePreDecoder {
    enum Result: Sendable {
        case message(RPCMessage)
        case decodeFailed
        case invalidUTF8
    }

    struct Classification: Sendable {
        let isSecure: Bool
        let rpcResult: Result?
    }

    private static let secureKindValues = [
        "\"serverHello\"", "\"secureReady\"", "\"secureError\"", "\"encryptedEnvelope\""
    ]

    static func decodeRPCMessage(from text: String) -> Result {
        guard let data = text.data(using: .utf8) else { return .invalidUTF8 }
        do {
            let message = try JSONDecoder().decode(RPCMessage.self, from: data)
            return .message(message)
        } catch {
            return .decodeFailed
        }
    }

    static func classify(_ text: String) -> Classification {
        if text.contains("\"kind\":") {
            for value in secureKindValues {
                if text.contains(value) {
                    return Classification(isSecure: true, rpcResult: nil)
                }
            }
        }
        return Classification(isSecure: false, rpcResult: decodeRPCMessage(from: text))
    }
}

extension CodexService {
    func processIncomingText(_ text: String) {
        guard let payloadData = text.data(using: .utf8) else {
            return
        }

        do {
            let message = try decoder.decode(RPCMessage.self, from: payloadData)
            handleIncomingRPCMessage(message)
        } catch {
            lastErrorMessage = "Unable to decode server payload"
        }
    }

    // Handles a pre-decoded RPC message from off-actor transport paths.
    func handleDecodedRPCResult(_ result: WireMessagePreDecoder.Result, rawText: String) {
        switch result {
        case .message(let message):
            lastRawMessage = rawText
            handleIncomingRPCMessage(message)
        case .decodeFailed:
            lastErrorMessage = "Unable to decode server payload"
        case .invalidUTF8:
            break
        }
    }

    func handleIncomingRPCMessage(_ message: RPCMessage) {
        if let method = message.method {
            let normalizedMethod = normalizedIncomingMethodName(method)
            if let requestID = message.id {
                handleServerRequest(method: normalizedMethod, requestID: requestID, params: message.params)
            } else {
                handleNotification(method: normalizedMethod, params: message.params)
            }
            return
        }

        guard let responseID = message.id else {
            return
        }

        let requestKey = idKey(from: responseID)
        guard let continuation = pendingRequests.removeValue(forKey: requestKey) else {
            return
        }

        if let rpcError = message.error {
            continuation.resume(throwing: CodexServiceError.rpcError(rpcError))
        } else {
            continuation.resume(returning: message)
        }
    }

    // Handles server-initiated RPC requests like approval prompts.
    func handleServerRequest(method: String, requestID: JSONValue, params: JSONValue?) {
        if method == "item/tool/requestUserInput" {
            handleStructuredUserInputRequest(
                requestID: requestID,
                paramsObject: params?.objectValue
            )
            return
        }

        if method == "item/commandExecution/requestApproval"
            || method == "item/fileChange/requestApproval"
            || method.hasSuffix("requestApproval") {
            let paramsObject = params?.objectValue
            let request = CodexApprovalRequest(
                id: idKey(from: requestID),
                requestID: requestID,
                method: method,
                command: paramsObject?["command"]?.stringValue,
                reason: paramsObject?["reason"]?.stringValue,
                threadId: paramsObject?["threadId"]?.stringValue,
                turnId: paramsObject?["turnId"]?.stringValue,
                params: params
            )

            if selectedAccessMode == .fullAccess {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        debugRuntimeLog("auto-approve triggered method=\(method)")
                        try await sendResponse(
                            id: requestID,
                            result: .string("accept")
                        )
                    } catch {
                        debugRuntimeLog("auto-approve failed method=\(method): \(error.localizedDescription)")
                        pendingApproval = request
                    }
                }
                return
            }

            pendingApproval = request
            return
        }

        switch method {
        default:
            Task { [requestID] in
                try? await sendErrorResponse(
                    id: requestID,
                    code: -32601,
                    message: "Unsupported request method: \(method)"
                )
            }
        }
    }

    // Handles stream notifications to keep UI state in sync.
    func handleNotification(method: String, params: JSONValue?) {
        let paramsObject = params?.objectValue

        switch method {
        case "thread/started":
            handleThreadStarted(paramsObject)

        case "thread/name/updated":
            handleThreadNameUpdated(paramsObject)

        case "thread/status/changed":
            handleThreadStatusChanged(paramsObject)

        case "turn/started":
            handleTurnStarted(paramsObject)

        case "turn/completed":
            handleTurnCompleted(paramsObject)

        case "turn/plan/updated":
            handleTurnPlanUpdated(paramsObject)

        case "item/agentMessage/delta",
             "codex/event/agent_message_content_delta",
             "codex/event/agent_message_delta":
            appendAgentDelta(from: paramsObject)

        case "codex/event/user_message":
            appendMirroredUserMessage(from: paramsObject)

        case "item/plan/delta":
            appendPlanDelta(from: paramsObject)

        case "item/reasoning/summaryTextDelta",
             "item/reasoning/summaryPartAdded",
             "item/reasoning/textDelta":
            appendReasoningDelta(from: paramsObject)

        case "item/fileChange/outputDelta":
            appendFileChangeDelta(from: paramsObject)

        case "item/toolCall/outputDelta",
             "item/toolCall/output_delta",
             "item/tool_call/outputDelta",
             "item/tool_call/output_delta":
            appendToolCallDelta(from: paramsObject)

        case "item/commandExecution/outputDelta",
             "item/command_execution/outputDelta":
            appendCommandExecutionDelta(from: paramsObject)

        case "item/commandExecution/terminalInteraction",
             "item/command_execution/terminalInteraction":
            handleCommandExecutionTerminalInteraction(from: paramsObject)

        case "codex/event/exec_command_begin",
             "codex/event/exec_command_output_delta",
             "codex/event/exec_command_end",
             "codex/event/background_event",
             "codex/event/read",
             "codex/event/search",
             "codex/event/list_files":
            if handleLegacyCodexNamedEvent(method: method, paramsObject: paramsObject) {
                return
            }

        case "turn/diff/updated", "codex/event/turn_diff_updated", "codex/event/turn_diff":
            handleTurnDiffUpdated(paramsObject)

        case "codex/event/patch_apply_begin", "codex/event/patch_apply_end":
            if handleLegacyPatchApplyMethod(method: method, paramsObject: paramsObject) {
                return
            }

        case "codex/event":
            if handleLegacyCodexEnvelopeEvent(paramsObject) {
                return
            }

        case "thread/tokenUsage/updated":
            handleThreadTokenUsageUpdated(paramsObject)

        case "account/rateLimits/updated":
            handleRateLimitsUpdated(paramsObject)

        case "item/completed", "codex/event/item_completed", "codex/event/agent_message":
            appendCompletedAgentText(from: paramsObject)

        case "item/started", "codex/event/item_started":
            handleItemStarted(paramsObject)

        case "error", "codex/event/error", "turn/failed":
            handleErrorNotification(paramsObject)

        case "serverRequest/resolved":
            handleServerRequestResolved(paramsObject)

        default:
            if method.hasPrefix("codex/event/"),
               handleLegacyCodexNamedEvent(method: method, paramsObject: paramsObject) {
                return
            }
            if handleToolCallNotificationFallback(method: method, paramsObject: paramsObject) {
                return
            }
            if handleDiffNotificationFallback(method: method, paramsObject: paramsObject) {
                return
            }
            if handleFileChangeNotificationFallback(method: method, paramsObject: paramsObject) {
                return
            }
        }
    }

    // Captures file-change notifications even when the server uses variant method names.
    private func handleFileChangeNotificationFallback(
        method: String,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        let normalizedMethod = method
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        guard normalizedMethod.contains("filechange") else {
            return false
        }

        if normalizedMethod.contains("delta") || normalizedMethod.contains("partadded") {
            appendFileChangeDelta(from: paramsObject)
            return true
        }

        if normalizedMethod.contains("started") {
            handleFileChangeLifecycleFallback(paramsObject, isCompleted: false)
            return true
        }

        if normalizedMethod.contains("completed")
            || normalizedMethod.contains("finished")
            || normalizedMethod.contains("done") {
            handleFileChangeLifecycleFallback(paramsObject, isCompleted: true)
            return true
        }

        // Unknown file-change notification shape: try best-effort lifecycle decode.
        handleFileChangeLifecycleFallback(paramsObject, isCompleted: false)
        return true
    }

    // Captures tool-call notifications that carry file-change payloads under generic names.
    private func handleToolCallNotificationFallback(
        method: String,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        let normalizedMethod = method
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        guard normalizedMethod.contains("toolcall") else {
            return false
        }

        if normalizedMethod.contains("delta") || normalizedMethod.contains("partadded") {
            appendToolCallDelta(from: paramsObject)
            return true
        }

        if normalizedMethod.contains("started") {
            handleToolCallLifecycleFallback(paramsObject, isCompleted: false)
            return true
        }

        if normalizedMethod.contains("completed")
            || normalizedMethod.contains("finished")
            || normalizedMethod.contains("done") {
            handleToolCallLifecycleFallback(paramsObject, isCompleted: true)
            return true
        }

        handleToolCallLifecycleFallback(paramsObject, isCompleted: false)
        return true
    }

    // Captures diff-centric notifications when servers emit non-standard method aliases.
    private func handleDiffNotificationFallback(
        method: String,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        let normalizedMethod = method
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        let isDiffMethod = normalizedMethod.contains("turndiff")
            || normalizedMethod.contains("/diff/")
            || normalizedMethod.hasPrefix("diff/")
            || normalizedMethod.hasSuffix("/diff")
            || normalizedMethod.contains("itemdiff")
        guard isDiffMethod else {
            return false
        }

        let payloadObject = envelopeEventObject(from: paramsObject) ?? paramsObject
        guard let payloadObject else {
            return false
        }

        _ = handleStructuredItemLifecycle(
            itemObject: payloadObject,
            paramsObject: paramsObject,
            itemType: "diff",
            isCompleted: true
        )
        return true
    }

    private func handleThreadStarted(_ paramsObject: IncomingParamsObject?) {
        guard let paramsObject,
              let threadValue = paramsObject["thread"],
              let thread = decodeModel(CodexThread.self, from: threadValue) else {
            return
        }

        upsertThread(thread)
        if activeThreadId == nil {
            activeThreadId = thread.id
        }
        requestImmediateSync(threadId: thread.id)
    }

    // Mirrors desktop behavior: when server pushes a thread rename, update local
    // title immediately instead of waiting for the next thread/list refresh.
    private func handleThreadNameUpdated(_ paramsObject: IncomingParamsObject?) {
        guard let paramsObject else {
            return
        }

        guard let threadId = extractThreadID(from: paramsObject)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !threadId.isEmpty else {
            return
        }

        let eventObject = envelopeEventObject(from: paramsObject)
        let renameKeys = ["threadName", "thread_name", "name", "title"]
        let hasExplicitRenameField = hasAnyValue(in: paramsObject, keys: renameKeys)
            || hasAnyValue(in: eventObject, keys: renameKeys)
        let threadName = firstStringValue(in: paramsObject, keys: renameKeys)
            ?? firstStringValue(in: eventObject, keys: renameKeys)
        let normalizedThreadName = normalizedIdentifier(threadName)

        if let normalizedThreadName, !normalizedThreadName.isEmpty {
            if let existingIndex = threadIndex(for: threadId) {
                threads[existingIndex].title = normalizedThreadName
                threads[existingIndex].name = normalizedThreadName
            } else {
                threads.append(
                    CodexThread(
                        id: threadId,
                        title: normalizedThreadName,
                        name: normalizedThreadName
                    )
                )
            }
            threads = sortThreads(threads)
            requestImmediateSync(threadId: threadId)
            return
        }

        // If server explicitly sends an empty/null name, clear local custom title.
        guard hasExplicitRenameField,
              let existingIndex = threadIndex(for: threadId) else {
            return
        }

        threads[existingIndex].title = nil
        threads[existingIndex].name = nil
        threads = sortThreads(threads)
        requestImmediateSync(threadId: threadId)
    }

    private func handleTurnStarted(_ paramsObject: IncomingParamsObject?) {
        let threadId = resolveThreadID(from: paramsObject)
        let turnID = extractTurnIDForTurnLifecycleEvent(from: paramsObject)

        if let threadId {
            markThreadAsRunning(threadId)
        }

        if let threadId, let turnID {
            setActiveTurnID(turnID, for: threadId)
            threadIdByTurnID[turnID] = threadId
            setProtectedRunningFallback(false, for: threadId)
            confirmLatestPendingUserMessage(threadId: threadId, turnId: turnID)
            // Do NOT create the assistant placeholder here.
            // It will be created lazily by ensureStreamingAssistantMessage()
            // when the first agent message delta arrives. Creating it here
            // gives it an orderIndex lower than thinking/reasoning messages
            // that arrive before the actual response, causing wrong visual order.
        } else if let threadId {
            setProtectedRunningFallback(true, for: threadId)
        }

        if let turnID {
            activeTurnId = turnID
        }

        requestImmediateSync(threadId: threadId ?? activeThreadId)
    }

    private func handleTurnCompleted(_ paramsObject: IncomingParamsObject?) {
        let completedTurnID = extractTurnIDForTurnLifecycleEvent(from: paramsObject)
        let turnFailureMessage = parseTurnFailureMessage(from: paramsObject)

        if let threadId = resolveThreadID(from: paramsObject, turnIdHint: completedTurnID) {
            if let completedTurnID {
                confirmLatestPendingUserMessage(threadId: threadId, turnId: completedTurnID)
            }
            let resolvedTurnID = completedTurnID ?? activeTurnIdByThread[threadId]
            let terminalState = parseTurnTerminalState(
                from: paramsObject,
                turnFailureMessage: turnFailureMessage
            )
            recordTurnTerminalState(threadId: threadId, turnId: resolvedTurnID, state: terminalState)
            noteTurnFinished(turnId: resolvedTurnID)
            markTurnCompleted(threadId: threadId, turnId: resolvedTurnID)
            if terminalState == .completed {
                markReadyIfUnread(threadId: threadId)
                notifyRunCompletionIfNeeded(threadId: threadId, turnId: resolvedTurnID, result: .completed)
            } else if terminalState == .failed {
                markFailedIfUnread(threadId: threadId)
                notifyRunCompletionIfNeeded(threadId: threadId, turnId: resolvedTurnID, result: .failed)
            }
            requestImmediateSync(threadId: threadId)

            guard let turnFailureMessage else {
                return
            }

            lastErrorMessage = turnFailureMessage
            appendSystemMessage(
                threadId: threadId,
                text: "Turn error: \(turnFailureMessage)",
                turnId: completedTurnID
            )
            return
        }

        finalizeAllStreamingState()

        guard let turnFailureMessage else {
            return
        }
        lastErrorMessage = turnFailureMessage
    }

    private func handleErrorNotification(_ paramsObject: IncomingParamsObject?) {
        if shouldRetryTurnError(from: paramsObject) {
            return
        }

        let eventObject = envelopeEventObject(from: paramsObject)
        let paramsErrorObject = paramsObject?["error"]?.objectValue
        let eventErrorObject = eventObject?["error"]?.objectValue
        let nestedEventObject = paramsObject?["event"]?.objectValue
        let errorMessage = firstNonEmptyString([
            firstStringValue(in: paramsObject, keys: ["message"]),
            firstStringValue(in: paramsErrorObject, keys: ["message"]),
            firstStringValue(in: eventObject, keys: ["message"]),
            firstStringValue(in: eventErrorObject, keys: ["message"]),
            firstStringValue(in: nestedEventObject, keys: ["message"]),
        ]) ?? "Server error"
        lastErrorMessage = errorMessage

        let turnId = extractTurnID(from: paramsObject)
        if let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) {
            let resolvedTurnID = turnId ?? activeTurnIdByThread[threadId]
            appendSystemMessage(threadId: threadId, text: "Error: \(errorMessage)", turnId: turnId)
            recordTurnTerminalState(threadId: threadId, turnId: resolvedTurnID, state: .failed)
            noteTurnFinished(turnId: resolvedTurnID)
            markTurnCompleted(threadId: threadId, turnId: resolvedTurnID)
            markFailedIfUnread(threadId: threadId)
            notifyRunCompletionIfNeeded(threadId: threadId, turnId: resolvedTurnID, result: .failed)
        } else {
            finalizeAllStreamingState()
        }
    }

    private func handleThreadTokenUsageUpdated(_ paramsObject: IncomingParamsObject?) {
        guard let threadId = extractThreadID(from: paramsObject), !threadId.isEmpty else {
            return
        }

        let eventObject = envelopeEventObject(from: paramsObject)
        let usageObject = paramsObject?["usage"]?.objectValue
            ?? eventObject?["usage"]?.objectValue
            ?? paramsObject

        guard let usage = extractContextWindowUsage(from: usageObject) else { return }
        contextWindowUsageByThread[threadId] = usage
    }

    private func handleThreadStatusChanged(_ paramsObject: IncomingParamsObject?) {
        guard let threadId = extractThreadID(from: paramsObject), !threadId.isEmpty else {
            return
        }

        let eventObject = envelopeEventObject(from: paramsObject)
        let nestedEventObject = paramsObject?["event"]?.objectValue
        let statusObject = paramsObject?["status"]?.objectValue
            ?? eventObject?["status"]?.objectValue
            ?? nestedEventObject?["status"]?.objectValue

        let rawStatusType = firstNonEmptyString([
            firstStringValue(in: statusObject, keys: ["type", "statusType", "status_type"]),
            firstStringValue(in: paramsObject, keys: ["status"]),
            firstStringValue(in: eventObject, keys: ["status"]),
            firstStringValue(in: nestedEventObject, keys: ["status"]),
        ]) ?? ""

        let normalizedStatusType = normalizeThreadStatusType(rawStatusType)

        if normalizedStatusType == "active"
            || normalizedStatusType == "running"
            || normalizedStatusType == "processing"
            || normalizedStatusType == "inprogress"
            || normalizedStatusType == "started"
            || normalizedStatusType == "pending" {
            markThreadAsRunning(threadId)
            return
        }

        if normalizedStatusType == "idle"
            || normalizedStatusType == "notloaded"
            || normalizedStatusType == "completed"
            || normalizedStatusType == "done"
            || normalizedStatusType == "finished"
            || normalizedStatusType == "stopped"
            || normalizedStatusType == "systemerror" {
            // Keep only the protected fallback alive until a real turn lifecycle event lands.
            if activeTurnIdByThread[threadId] != nil
                || protectedRunningFallbackThreadIDs.contains(threadId)
                || hasStreamingMessage(in: threadId) {
                return
            }

            let activeTurnIdForThread = activeTurnIdByThread[threadId]
            let terminalState = threadTerminalState(from: normalizedStatusType)
            if let terminalState {
                recordTurnTerminalState(
                    threadId: threadId,
                    turnId: activeTurnIdForThread,
                    state: terminalState
                )
                noteTurnFinished(turnId: activeTurnIdForThread)
                if let completionResult = runCompletionResult(for: terminalState) {
                    notifyRunCompletionIfNeeded(
                        threadId: threadId,
                        turnId: activeTurnIdForThread,
                        result: completionResult
                    )
                }
            }
            markTurnCompleted(threadId: threadId, turnId: activeTurnIdForThread)
            clearRunningState(for: threadId)

            if normalizedStatusType.contains("error") {
                markFailedIfUnread(threadId: threadId)
            }
        }
    }

    // Parses the real terminal outcome so UI can distinguish completion from interruption.
    private func parseTurnTerminalState(
        from paramsObject: IncomingParamsObject?,
        turnFailureMessage: String?
    ) -> CodexTurnTerminalState {
        if turnFailureMessage != nil {
            return .failed
        }

        let eventObject = envelopeEventObject(from: paramsObject)
        let turnObject = paramsObject?["turn"]?.objectValue
        let statusObject = turnObject?["status"]?.objectValue
            ?? paramsObject?["status"]?.objectValue
            ?? eventObject?["status"]?.objectValue

        let rawStatus = firstNonEmptyString([
            firstStringValue(in: turnObject, keys: ["status"]),
            firstStringValue(in: paramsObject, keys: ["status"]),
            firstStringValue(in: eventObject, keys: ["status"]),
            firstStringValue(in: statusObject, keys: ["type", "statusType", "status_type"]),
        ]) ?? ""

        let normalizedStatus = normalizeThreadStatusType(rawStatus)
        if normalizedStatus.contains("cancel")
            || normalizedStatus.contains("abort")
            || normalizedStatus.contains("interrupt")
            || normalizedStatus.contains("stopped") {
            return .stopped
        }
        if normalizedStatus.contains("fail")
            || normalizedStatus.contains("error") {
            return .failed
        }
        return .completed
    }

    // Maps terminal runtime states onto the smaller notification vocabulary.
    private func runCompletionResult(for state: CodexTurnTerminalState) -> CodexRunCompletionResult? {
        switch state {
        case .completed:
            .completed
        case .failed:
            .failed
        case .stopped:
            nil
        }
    }

    private func parseTurnFailureMessage(from paramsObject: IncomingParamsObject?) -> String? {
        let turnObject = paramsObject?["turn"]?.objectValue
        let status = turnObject?["status"]?.stringValue
            ?? paramsObject?["status"]?.stringValue

        guard status == "failed" else {
            return nil
        }

        return turnObject?["error"]?.objectValue?["message"]?.stringValue
            ?? paramsObject?["error"]?.objectValue?["message"]?.stringValue
            ?? paramsObject?["errorMessage"]?.stringValue
            ?? "Turn failed with no details"
    }

    private func appendReasoningDelta(from paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)

        let delta = extractTextDelta(from: paramsObject)
        guard !delta.isEmpty else { return }

        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return
        }
        let resolvedTurnId = turnId ?? activeTurnIdByThread[threadId]

        if let resolvedTurnId {
            threadIdByTurnID[resolvedTurnId] = threadId
        }

        let isReasoningTurnActive: Bool
        if let resolvedTurnId, !resolvedTurnId.isEmpty {
            if activeTurnIdByThread[threadId] == resolvedTurnId {
                isReasoningTurnActive = true
            } else {
                isReasoningTurnActive = activeTurnIdByThread[threadId] == nil
                    && runningThreadIDs.contains(threadId)
            }
        } else {
            isReasoningTurnActive = activeTurnIdByThread[threadId] != nil
                || runningThreadIDs.contains(threadId)
        }
        if !isReasoningTurnActive {
            let lateItemId = extractItemID(from: paramsObject, eventObject: eventObject)
            _ = mergeLateReasoningDeltaIfPossible(
                threadId: threadId,
                turnId: resolvedTurnId,
                itemId: lateItemId,
                delta: delta
            )
            return
        }

        let itemId = extractItemID(from: paramsObject, eventObject: eventObject)
        if let itemId, !itemId.isEmpty {
            appendStreamingSystemItemDelta(
                threadId: threadId,
                turnId: resolvedTurnId,
                itemId: itemId,
                kind: .thinking,
                delta: delta
            )
            return
        }

        if let resolvedTurnId, !resolvedTurnId.isEmpty {
            appendStreamingSystemTurnDelta(
                threadId: threadId,
                turnId: resolvedTurnId,
                kind: .thinking,
                delta: delta
            )
            return
        }

        appendSystemMessage(
            threadId: threadId,
            text: delta,
            turnId: resolvedTurnId,
            kind: .thinking
        )
    }

    private func appendFileChangeDelta(from paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)

        let delta = extractTextDelta(from: paramsObject)
        guard !delta.isEmpty else { return }

        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return
        }
        let resolvedTurnId = turnId ?? activeTurnIdByThread[threadId]

        if let resolvedTurnId {
            threadIdByTurnID[resolvedTurnId] = threadId
        }

        let itemId = extractItemID(from: paramsObject, eventObject: eventObject)
        if let itemId, !itemId.isEmpty {
            appendStreamingSystemItemDelta(
                threadId: threadId,
                turnId: resolvedTurnId,
                itemId: itemId,
                kind: .fileChange,
                delta: delta
            )
            return
        }

        if let resolvedTurnId, !resolvedTurnId.isEmpty {
            appendStreamingSystemTurnDelta(
                threadId: threadId,
                turnId: resolvedTurnId,
                kind: .fileChange,
                delta: delta
            )
            return
        }

        appendSystemMessage(
            threadId: threadId,
            text: delta,
            turnId: resolvedTurnId,
            kind: .fileChange
        )
    }

    private func appendToolCallDelta(from paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)
        let itemObject = extractIncomingItemObject(from: paramsObject, eventObject: eventObject)

        let delta = extractTextDelta(from: paramsObject)
        guard !delta.isEmpty else { return }
        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return
        }
        let resolvedTurnId = turnId ?? activeTurnIdByThread[threadId]

        if let resolvedTurnId {
            threadIdByTurnID[resolvedTurnId] = threadId
        }

        guard isLikelyFileChangeToolCall(itemObject: itemObject, fallbackText: delta) else {
            let activityLines = extractToolCallActivityLines(from: delta)
            guard !activityLines.isEmpty else {
                return
            }
            for line in activityLines {
                appendEssentialActivityLine(threadId: threadId, turnId: resolvedTurnId, line: line)
            }
            return
        }

        let itemId = extractItemID(from: paramsObject, eventObject: eventObject, itemObject: itemObject)
        if let itemId, !itemId.isEmpty {
            appendStreamingSystemItemDelta(
                threadId: threadId,
                turnId: resolvedTurnId,
                itemId: itemId,
                kind: .fileChange,
                delta: delta
            )
            return
        }

        if let resolvedTurnId, !resolvedTurnId.isEmpty {
            appendStreamingSystemTurnDelta(
                threadId: threadId,
                turnId: resolvedTurnId,
                kind: .fileChange,
                delta: delta
            )
            return
        }

        appendSystemMessage(
            threadId: threadId,
            text: delta,
            turnId: resolvedTurnId,
            kind: .fileChange
        )
    }

    private func appendCommandExecutionDelta(from paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)
        let itemObject = extractIncomingItemObject(from: paramsObject, eventObject: eventObject)
        let payloadObject = itemObject ?? eventObject ?? paramsObject

        guard let context = resolveCommandExecutionMessageContext(
            paramsObject: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject
        ) else {
            return
        }

        if let itemId = context.itemId, !itemId.isEmpty {
            let hasCommandHint = extractCommandExecutionCommand(from: payloadObject) != nil
                || payloadObject["command"] != nil
                || payloadObject["cmd"] != nil
            if !hasCommandHint {
                if existingCommandExecutionRow(threadId: context.threadId, itemId: itemId) != nil {
                    return
                }
            }
        }

        let statusText = decodeCommandExecutionStatusText(
            payloadObject,
            threadId: context.threadId,
            isCompleted: false
        )
        appendCommandExecutionOutputToDetails(itemId: context.itemId, paramsObject: paramsObject, eventObject: eventObject)
        publishCommandExecutionStatus(
            context: context,
            statusText: statusText,
            isStreaming: true
        )
    }

    private func handleCommandExecutionTerminalInteraction(from paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)
        guard let context = resolveCommandExecutionMessageContext(
            paramsObject: paramsObject,
            eventObject: eventObject
        ) else {
            return
        }
        guard let itemId = context.itemId,
              !itemId.isEmpty else {
            return
        }

        let eventType = commandExecutionEventType(eventObject: eventObject, paramsObject: paramsObject)
        let state = decodeCommandRunViewState(
            payloadObject: eventObject ?? paramsObject,
            paramsObject: paramsObject,
            eventType: eventType
        )
        let statusText = commandExecutionStatusText(for: state)
        let existingRunRow = existingCommandExecutionRow(threadId: context.threadId, itemId: itemId)

        if let existingRunRow {
            // Ignore late status-less terminal interaction updates that would regress a completed row.
            if !existingRunRow.isStreaming, state.phase == .running {
                return
            }

            if state.shortCommand.lowercased() != "command" || state.phase != .running {
                publishCommandExecutionStatus(
                    context: context,
                    statusText: statusText,
                    isStreaming: state.phase == .running
                )
            }
            return
        }

        publishCommandExecutionStatus(
            context: context,
            statusText: statusText,
            isStreaming: state.phase == .running
        )
    }

    private func resolveCommandExecutionMessageContext(
        paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?,
        itemObject: IncomingParamsObject? = nil
    ) -> CommandExecutionMessageContext? {
        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return nil
        }
        let resolvedTurnId = turnId ?? activeTurnIdByThread[threadId]
        if let resolvedTurnId {
            threadIdByTurnID[resolvedTurnId] = threadId
        }

        let itemId = extractItemID(
            from: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject
        )
        return CommandExecutionMessageContext(
            threadId: threadId,
            turnId: resolvedTurnId,
            itemId: itemId
        )
    }

    private func commandExecutionEventType(
        eventObject: IncomingParamsObject?,
        paramsObject: IncomingParamsObject
    ) -> String? {
        let rawEventType = firstNonEmptyString([
            eventObject?["type"]?.stringValue,
            eventObject?["event_type"]?.stringValue,
            paramsObject["type"]?.stringValue,
            paramsObject["event_type"]?.stringValue,
        ])
        return rawEventType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func existingCommandExecutionRow(threadId: String, itemId: String) -> CodexMessage? {
        messagesByThread[threadId]?.first(where: { message in
            message.role == .system
                && message.kind == .commandExecution
                && message.itemId == itemId
        })
    }

    private func publishCommandExecutionStatus(
        context: CommandExecutionMessageContext,
        statusText: String,
        isStreaming: Bool
    ) {
        if let itemId = context.itemId, !itemId.isEmpty {
            upsertStreamingSystemItemMessage(
                threadId: context.threadId,
                turnId: context.turnId,
                itemId: itemId,
                kind: .commandExecution,
                text: statusText,
                isStreaming: isStreaming
            )
            return
        }

        if let turnId = context.turnId, !turnId.isEmpty {
            upsertStreamingSystemTurnMessage(
                threadId: context.threadId,
                turnId: turnId,
                kind: .commandExecution,
                text: statusText,
                isStreaming: isStreaming
            )
            return
        }

        appendSystemMessage(
            threadId: context.threadId,
            text: statusText,
            turnId: context.turnId,
            kind: .commandExecution,
            isStreaming: isStreaming
        )
    }

    // Consumes turn-level aggregated diff updates and renders them as file-change system messages.
    private func handleTurnDiffUpdated(_ paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }

        let eventObject = envelopeEventObject(from: paramsObject)
        let nestedEventObject = paramsObject["event"]?.objectValue
        let diffCandidate = firstStringValue(in: paramsObject, keys: ["diff", "unified_diff"])
            ?? firstStringValue(in: eventObject, keys: ["diff", "unified_diff"])
            ?? firstStringValue(in: nestedEventObject, keys: ["diff", "unified_diff"])
        guard let diffText = normalizedUnifiedPatchPayload(diffCandidate ?? "") else { return }

        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return
        }
        if let turnId {
            threadIdByTurnID[turnId] = threadId
            recordTurnDiffChangeSet(threadId: threadId, turnId: turnId, diff: diffText)
        }

        let renderedBody = decodeTurnDiffUpdatedBody(from: diffText)
        if let turnId, !turnId.isEmpty {
            upsertStreamingSystemTurnMessage(
                threadId: threadId,
                turnId: turnId,
                kind: .fileChange,
                text: renderedBody,
                isStreaming: false
            )
            return
        }

        appendSystemMessage(
            threadId: threadId,
            text: renderedBody,
            turnId: turnId,
            kind: .fileChange
        )
    }

    // Supports legacy codex/event envelopes where `msg.type == "turn_diff"` and payload uses unified_diff.
    private func handleLegacyCodexEnvelopeEvent(_ paramsObject: IncomingParamsObject?) -> Bool {
        guard let paramsObject,
              let msgObject = paramsObject["msg"]?.objectValue else {
            return false
        }

        let eventType = msgObject["type"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let eventType else { return false }

        if eventType == "turn_diff" {
            var normalizedParams = paramsObject
            if normalizedParams["event"] == nil {
                normalizedParams["event"] = .object(msgObject)
            }

            if normalizedParams["diff"] == nil, let unified = msgObject["unified_diff"]?.stringValue {
                normalizedParams["diff"] = .string(unified)
            }

            if normalizedParams["turnId"] == nil {
                if let turnId = firstStringValue(in: msgObject, keys: ["turnId", "turn_id", "id"]) {
                    normalizedParams["turnId"] = .string(turnId)
                }
            }

            if normalizedParams["threadId"] == nil {
                if let threadId = firstStringValue(
                    in: msgObject,
                    keys: ["threadId", "thread_id", "conversationId", "conversation_id"]
                ) {
                    normalizedParams["threadId"] = .string(threadId)
                }
            }

            handleTurnDiffUpdated(normalizedParams)
            return true
        }

        if eventType == "patch_apply_begin" || eventType == "patch_apply_end" {
            return handleLegacyPatchApplyPayload(
                eventType: eventType,
                payload: msgObject,
                paramsObject: paramsObject
            )
        }

        return handleLegacyCodexEventType(
            eventType: eventType,
            payload: msgObject,
            paramsObject: paramsObject
        )
    }

    private func handleLegacyCodexNamedEvent(
        method: String,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        guard method.hasPrefix("codex/event/"),
              let paramsObject else {
            return false
        }

        let eventType = method
            .replacingOccurrences(of: "codex/event/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !eventType.isEmpty else {
            return false
        }

        let payload = paramsObject["msg"]?.objectValue
            ?? paramsObject["event"]?.objectValue
            ?? paramsObject

        if eventType == "turn_diff" {
            var normalizedParams = paramsObject
            if normalizedParams["event"] == nil {
                normalizedParams["event"] = .object(payload)
            }
            if normalizedParams["diff"] == nil,
               let unified = firstStringValue(in: payload, keys: ["unified_diff", "diff"]) {
                normalizedParams["diff"] = .string(unified)
            }
            handleTurnDiffUpdated(normalizedParams)
            return true
        }

        if eventType == "patch_apply_begin" || eventType == "patch_apply_end" {
            return handleLegacyPatchApplyPayload(
                eventType: eventType,
                payload: payload,
                paramsObject: paramsObject
            )
        }

        return handleLegacyCodexEventType(
            eventType: eventType,
            payload: payload,
            paramsObject: paramsObject
        )
    }

    private func handleLegacyCodexEventType(
        eventType: String,
        payload: IncomingParamsObject,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        switch eventType {
        case "exec_command_begin", "exec_command_output_delta", "exec_command_end":
            return handleLegacyCommandExecutionEvent(
                eventType: eventType,
                payload: payload,
                paramsObject: paramsObject
            )
        case "token_count":
            return handleLegacyTokenCountEvent(
                payload: payload,
                paramsObject: paramsObject
            )
        case "background_event", "read", "search", "list_files":
            return handleEssentialActivityEvent(
                eventType: eventType,
                payload: payload,
                paramsObject: paramsObject
            )
        default:
            return false
        }
    }

    // Accepts legacy Codex token_count events, even when the runtime omits thread ids.
    private func handleLegacyTokenCountEvent(
        payload: IncomingParamsObject,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        var normalizedParams = paramsObject ?? [:]
        if normalizedParams["event"] == nil {
            normalizedParams["event"] = .object(payload)
        }

        if normalizedParams["threadId"] == nil,
           let threadId = firstStringValue(
            in: payload,
            keys: ["threadId", "thread_id", "conversationId", "conversation_id"]
           ) {
            normalizedParams["threadId"] = .string(threadId)
        }

        if normalizedParams["turnId"] == nil,
           let turnId = firstStringValue(in: payload, keys: ["turnId", "turn_id", "id"]) {
            normalizedParams["turnId"] = .string(turnId)
        }

        let usageObject = payload["info"]?.objectValue
            ?? payload["usage"]?.objectValue
            ?? payload
        let usage = extractContextWindowUsageFromTokenCountPayload(payload)
            ?? extractContextWindowUsage(from: usageObject)
        guard let usage else {
            return false
        }

        let turnId = extractTurnID(from: normalizedParams)
        guard let threadId = resolveContextUsageThreadID(
            from: normalizedParams,
            turnIdHint: turnId
        ) else {
            return false
        }

        if let turnId {
            threadIdByTurnID[turnId] = threadId
        }
        contextWindowUsageByThread[threadId] = usage
        return true
    }

    private func handleLegacyPatchApplyMethod(
        method: String,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        guard let paramsObject else { return false }
        let eventType: String
        if method.hasSuffix("patch_apply_begin") {
            eventType = "patch_apply_begin"
        } else if method.hasSuffix("patch_apply_end") {
            eventType = "patch_apply_end"
        } else {
            return false
        }

        let payload = paramsObject["event"]?.objectValue
            ?? paramsObject["msg"]?.objectValue
            ?? paramsObject
        return handleLegacyPatchApplyPayload(
            eventType: eventType,
            payload: payload,
            paramsObject: paramsObject
        )
    }

    private func handleLegacyPatchApplyPayload(
        eventType: String,
        payload: IncomingParamsObject,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        guard eventType == "patch_apply_begin" || eventType == "patch_apply_end" else {
            return false
        }

        var normalizedParams = paramsObject ?? [:]
        if normalizedParams["event"] == nil {
            normalizedParams["event"] = .object(payload)
        }

        if normalizedParams["itemId"] == nil,
           let itemId = firstStringValue(in: payload, keys: ["call_id", "callId"]) {
            normalizedParams["itemId"] = .string(itemId)
        }

        if normalizedParams["threadId"] == nil,
           let threadId = firstStringValue(
            in: payload,
            keys: ["threadId", "thread_id", "conversationId", "conversation_id"]
           ) {
            normalizedParams["threadId"] = .string(threadId)
        }

        if normalizedParams["turnId"] == nil,
           let turnId = firstStringValue(in: payload, keys: ["turnId", "turn_id", "id"]) {
            normalizedParams["turnId"] = .string(turnId)
        }

        let isCompleted = (eventType == "patch_apply_end")
        let status: String = {
            if let status = payload["status"]?.stringValue,
               !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return status
            }
            if isCompleted {
                let success = payload["success"]?.boolValue ?? true
                return success ? "completed" : "failed"
            }
            return "inProgress"
        }()

        var syntheticItem: IncomingParamsObject = [
            "type": .string("fileChange"),
            "status": .string(status),
        ]
        if let changes = payload["changes"] {
            syntheticItem["changes"] = changes
        }

        _ = handleStructuredItemLifecycle(
            itemObject: syntheticItem,
            paramsObject: normalizedParams,
            itemType: "filechange",
            isCompleted: isCompleted
        )
        return true
    }

    private func handleLegacyCommandExecutionEvent(
        eventType: String,
        payload: IncomingParamsObject,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        guard eventType == "exec_command_begin"
            || eventType == "exec_command_output_delta"
            || eventType == "exec_command_end" else {
            return false
        }

        var normalizedParams = paramsObject ?? [:]
        if normalizedParams["event"] == nil {
            normalizedParams["event"] = .object(payload)
        }

        if normalizedParams["itemId"] == nil,
           let itemId = firstStringValue(in: payload, keys: ["call_id", "callId"]) {
            normalizedParams["itemId"] = .string(itemId)
        }

        if normalizedParams["turnId"] == nil,
           let turnId = firstNonEmptyString([
            firstStringValue(in: payload, keys: ["turn_id", "turnId"]),
            firstStringValue(in: paramsObject, keys: ["id"]),
           ]) {
            normalizedParams["turnId"] = .string(turnId)
        }

        if normalizedParams["threadId"] == nil,
           let threadId = firstNonEmptyString([
            firstStringValue(in: payload, keys: ["threadId", "thread_id", "conversationId"]),
            firstStringValue(in: paramsObject, keys: ["conversationId"]),
           ]) {
            normalizedParams["threadId"] = .string(threadId)
        }

        let turnId = extractTurnID(from: normalizedParams)
        guard let threadId = resolveThreadID(from: normalizedParams, turnIdHint: turnId) else {
            return false
        }
        if let turnId {
            threadIdByTurnID[turnId] = threadId
        }

        let state = decodeCommandRunViewState(
            payloadObject: payload,
            paramsObject: normalizedParams,
            eventType: eventType
        )
        let itemId = state.itemId
            ?? extractItemID(from: normalizedParams, eventObject: payload)
            ?? firstStringValue(in: payload, keys: ["call_id", "callId"])

        if eventType == "exec_command_output_delta" {
            if let itemId, !itemId.isEmpty {
                // Ensure details entry exists so output is captured.
                if commandExecutionDetailsByItemID[itemId] == nil {
                    upsertCommandExecutionDetails(from: state, threadId: threadId, isCompleted: false)
                }
                appendCommandExecutionOutputToDetails(itemId: itemId, paramsObject: normalizedParams, eventObject: payload)

                let hasExistingRunRow = messagesByThread[threadId]?.contains(where: { message in
                    message.role == .system
                        && message.kind == .commandExecution
                        && message.itemId == itemId
                }) ?? false
                if !hasExistingRunRow {
                    upsertStreamingSystemItemMessage(
                        threadId: threadId,
                        turnId: turnId,
                        itemId: itemId,
                        kind: .commandExecution,
                        text: commandExecutionStatusText(for: state),
                        isStreaming: true
                    )
                }
            }
            return true
        }

        let isCompleted = (eventType == "exec_command_end")
        upsertCommandExecutionDetails(from: state, threadId: threadId, isCompleted: isCompleted)
        let statusText = commandExecutionStatusText(for: state)
        if let itemId, !itemId.isEmpty {
            if isCompleted {
                completeStreamingSystemItemMessage(
                    threadId: threadId,
                    turnId: turnId,
                    itemId: itemId,
                    kind: .commandExecution,
                    text: statusText
                )
            } else {
                upsertStreamingSystemItemMessage(
                    threadId: threadId,
                    turnId: turnId,
                    itemId: itemId,
                    kind: .commandExecution,
                    text: statusText,
                    isStreaming: true
                )
            }
        } else if let turnId, !turnId.isEmpty {
            if isCompleted {
                completeStreamingSystemTurnMessage(
                    threadId: threadId,
                    turnId: turnId,
                    kind: .commandExecution,
                    text: statusText
                )
            } else {
                upsertStreamingSystemTurnMessage(
                    threadId: threadId,
                    turnId: turnId,
                    kind: .commandExecution,
                    text: statusText,
                    isStreaming: true
                )
            }
        } else {
            appendSystemMessage(
                threadId: threadId,
                text: statusText,
                turnId: turnId,
                itemId: itemId,
                kind: .commandExecution,
                isStreaming: !isCompleted
            )
        }

        if let activityLine = state.activityLine {
            appendEssentialActivityLine(threadId: threadId, turnId: turnId, line: activityLine)
        }

        if isCompleted {
            maybeAppendPushResetMarker(from: state, threadId: threadId)
        }

        return true
    }

    private func handleEssentialActivityEvent(
        eventType: String,
        payload: IncomingParamsObject,
        paramsObject: IncomingParamsObject?
    ) -> Bool {
        guard let line = essentialActivityLine(for: eventType, payload: payload) else {
            return false
        }

        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return false
        }

        appendEssentialActivityLine(threadId: threadId, turnId: turnId, line: line)
        return true
    }

    private func essentialActivityLine(
        for eventType: String,
        payload: IncomingParamsObject
    ) -> String? {
        switch eventType {
        case "background_event":
            let rawMessage = firstNonEmptyString([
                payload["message"]?.stringValue,
                payload["text"]?.stringValue,
                payload["body"]?.stringValue,
                firstString(forKey: "message", in: .object(payload)),
                firstString(forKey: "text", in: .object(payload)),
                firstString(forKey: "body", in: .object(payload)),
            ])
            guard let message = rawMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !message.isEmpty else {
                return nil
            }
            if message.count > 140 {
                return nil
            }
            return message

        case "read":
            if let path = firstNonEmptyString([
                firstString(forKey: "path", in: .object(payload)),
                firstString(forKey: "file_path", in: .object(payload)),
                firstString(forKey: "file", in: .object(payload)),
            ]) {
                return "Read \(path)"
            }
            return "Read file"

        case "search":
            if let query = firstNonEmptyString([
                firstString(forKey: "query", in: .object(payload)),
                firstString(forKey: "pattern", in: .object(payload)),
                firstString(forKey: "regex", in: .object(payload)),
            ]) {
                return "Search \(query)"
            }
            return "Search files"

        case "list_files":
            if let path = firstNonEmptyString([
                firstString(forKey: "path", in: .object(payload)),
                firstString(forKey: "cwd", in: .object(payload)),
            ]) {
                return "List files \(path)"
            }
            return "List files"

        default:
            return nil
        }
    }

    private func appendEssentialActivityLine(threadId: String, turnId: String?, line: String) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return
        }

        let dedupeKey = "\(threadId)|\(turnId ?? "no-turn")"
        let now = Date()
        if let previous = recentActivityLineByThread[dedupeKey],
           previous.line.caseInsensitiveCompare(trimmedLine) == .orderedSame,
           now.timeIntervalSince(previous.timestamp) <= 4 {
            return
        }
        recentActivityLineByThread[dedupeKey] = CodexRecentActivityLine(line: trimmedLine, timestamp: now)
        appendThinkingActivityLine(threadId: threadId, turnId: turnId, line: trimmedLine)
    }

    private func extractToolCallActivityLines(from delta: String) -> [String] {
        let lines = delta
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        let acceptedPrefixes = [
            "running ",
            "read ",
            "search ",
            "searched ",
            "exploring ",
            "list ",
            "listing ",
            "open ",
            "opened ",
            "find ",
            "finding ",
            "edit ",
            "edited ",
            "write ",
            "wrote ",
            "apply ",
            "applied ",
        ]

        var seen: Set<String> = []
        var result: [String] = []
        for line in lines {
            if line.count > 140 { continue }
            if line.contains("```") { continue }
            if line.hasPrefix("{") || line.hasPrefix("[") { continue }
            if looksLikePatchText(line) { continue }

            let normalized = line.lowercased()
            guard acceptedPrefixes.contains(where: { normalized.hasPrefix($0) }) else {
                continue
            }

            if seen.insert(normalized).inserted {
                result.append(line)
            }
        }

        return result
    }

    // Handles non-standard file-change started/completed envelopes without dropping UI updates.
    private func handleFileChangeLifecycleFallback(
        _ paramsObject: IncomingParamsObject?,
        isCompleted: Bool
    ) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)

        if let itemObject = extractIncomingItemObject(from: paramsObject, eventObject: eventObject) {
            _ = handleStructuredItemLifecycle(
                itemObject: itemObject,
                paramsObject: paramsObject,
                itemType: "filechange",
                isCompleted: isCompleted
            )
            return
        }

        let payloadObject = eventObject ?? paramsObject
        let body = decodeFileChangeItemBody(payloadObject)
        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return
        }

        if let turnId {
            threadIdByTurnID[turnId] = threadId
        }

        let itemId = extractItemID(from: paramsObject, eventObject: eventObject)
        if let itemId, !itemId.isEmpty {
            if isCompleted {
                completeStreamingSystemItemMessage(
                    threadId: threadId,
                    turnId: turnId,
                    itemId: itemId,
                    kind: .fileChange,
                    text: body
                )
            } else {
                upsertStreamingSystemItemMessage(
                    threadId: threadId,
                    turnId: turnId,
                    itemId: itemId,
                    kind: .fileChange,
                    text: body,
                    isStreaming: true
                )
            }
            return
        }

        if let turnId, !turnId.isEmpty {
            if isCompleted {
                completeStreamingSystemTurnMessage(
                    threadId: threadId,
                    turnId: turnId,
                    kind: .fileChange,
                    text: body
                )
            } else {
                upsertStreamingSystemTurnMessage(
                    threadId: threadId,
                    turnId: turnId,
                    kind: .fileChange,
                    text: body,
                    isStreaming: true
                )
            }
            return
        }

        appendSystemMessage(
            threadId: threadId,
            text: body,
            turnId: turnId,
            kind: .fileChange,
            isStreaming: !isCompleted
        )
    }

    private func handleToolCallLifecycleFallback(
        _ paramsObject: IncomingParamsObject?,
        isCompleted: Bool
    ) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)

        if let itemObject = extractIncomingItemObject(from: paramsObject, eventObject: eventObject) {
            _ = handleStructuredItemLifecycle(
                itemObject: itemObject,
                paramsObject: paramsObject,
                itemType: "toolcall",
                isCompleted: isCompleted
            )
            return
        }

        let payloadObject = eventObject ?? paramsObject
        _ = handleStructuredItemLifecycle(
            itemObject: payloadObject,
            paramsObject: paramsObject,
            itemType: "toolcall",
            isCompleted: isCompleted
        )
    }

    func handleStructuredItemLifecycle(
        itemObject: IncomingParamsObject,
        paramsObject: IncomingParamsObject?,
        itemType: String,
        isCompleted: Bool
    ) -> Bool {
        guard itemType == "reasoning"
            || itemType == "filechange"
            || itemType == "toolcall"
            || itemType == "commandexecution"
            || itemType == "collabagenttoolcall"
            || itemType == "collabtoolcall"
            || itemType.hasPrefix("collabagentspawn")
            || itemType.hasPrefix("collabwaiting")
            || itemType.hasPrefix("collabclose")
            || itemType.hasPrefix("collabresume")
            || itemType.hasPrefix("collabagentinteraction")
            || itemType == "diff"
            || itemType == "plan"
            || itemType == "enteredreviewmode"
            || itemType == "contextcompaction" else {
            return false
        }

        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return true
        }
        if let turnId {
            threadIdByTurnID[turnId] = threadId
        }

        let eventObject = envelopeEventObject(from: paramsObject)
        let itemId = extractItemID(from: paramsObject, eventObject: eventObject, itemObject: itemObject)

        let kind: CodexMessageKind
        let body: String
        switch itemType {
        case "reasoning":
            kind = .thinking
            body = decodeReasoningItemBody(itemObject)
        case "filechange":
            kind = .fileChange
            body = decodeFileChangeItemBody(itemObject)
        case "toolcall":
            guard let resolvedBody = decodeToolCallFileChangeBody(itemObject, isCompleted: isCompleted) else {
                return false
            }
            kind = .fileChange
            body = resolvedBody
        case "commandexecution":
            kind = .commandExecution
            body = decodeCommandExecutionStatusText(itemObject, isCompleted: isCompleted)
        case let collabType where collabType == "collabagenttoolcall"
            || collabType == "collabtoolcall"
            || collabType.hasPrefix("collabagentspawn")
            || collabType.hasPrefix("collabwaiting")
            || collabType.hasPrefix("collabclose")
            || collabType.hasPrefix("collabresume")
            || collabType.hasPrefix("collabagentinteraction"):
            guard let subagentAction = decodeSubagentActionItem(from: itemObject) else {
                return false
            }
            upsertSubagentActionMessage(
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                action: subagentAction,
                isStreaming: !isCompleted
            )
            return true
        case "diff":
            guard let resolvedBody = decodeDiffItemBody(itemObject, isCompleted: isCompleted) else {
                return false
            }
            kind = .fileChange
            body = resolvedBody
        case "plan":
            kind = .plan
            body = decodePlanItemBody(itemObject)
        case "enteredreviewmode":
            kind = .commandExecution
            let reviewLabel = firstNonEmptyString([
                itemObject["review"]?.stringValue,
                firstString(forKey: "review", in: .object(itemObject)),
            ]) ?? "changes"
            body = "Reviewing \(reviewLabel)..."
        case "contextcompaction":
            kind = .commandExecution
            body = isCompleted ? "Context compacted" : "Compacting context…"
        default:
            kind = .fileChange
            body = ""
        }

        if isCompleted,
           kind == .fileChange,
           let turnId,
           let patch = extractChangeSetUnifiedPatch(from: itemObject, itemType: itemType) {
            recordFallbackFileChangePatch(threadId: threadId, turnId: turnId, patch: patch)
        }

        if let itemId, !itemId.isEmpty {
            if isCompleted {
                completeStreamingSystemItemMessage(
                    threadId: threadId,
                    turnId: turnId,
                    itemId: itemId,
                    kind: kind,
                    text: body
                )
            } else {
                upsertStreamingSystemItemMessage(
                    threadId: threadId,
                    turnId: turnId,
                    itemId: itemId,
                    kind: kind,
                    text: body,
                    isStreaming: true
                )
            }
            return true
        }

        if let turnId, !turnId.isEmpty {
            if isCompleted {
                completeStreamingSystemTurnMessage(
                    threadId: threadId,
                    turnId: turnId,
                    kind: kind,
                    text: body
                )
            } else {
                upsertStreamingSystemTurnMessage(
                    threadId: threadId,
                    turnId: turnId,
                    kind: kind,
                    text: body,
                    isStreaming: true
                )
            }
            return true
        }

        appendSystemMessage(
            threadId: threadId,
            text: body,
            turnId: turnId,
            kind: kind,
            isStreaming: !isCompleted
        )
        return true
    }

    func extractIncomingItemObject(
        from paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?
    ) -> IncomingParamsObject? {
        if let item = paramsObject["item"]?.objectValue {
            return item
        }
        if let item = eventObject?["item"]?.objectValue {
            return item
        }
        if let item = paramsObject["event"]?.objectValue?["item"]?.objectValue {
            return item
        }

        if isLikelyIncomingItemPayload(paramsObject) {
            return paramsObject
        }
        if let eventObject, isLikelyIncomingItemPayload(eventObject) {
            return eventObject
        }
        if let nestedEventObject = paramsObject["event"]?.objectValue,
           isLikelyIncomingItemPayload(nestedEventObject) {
            return nestedEventObject
        }

        return nil
    }

    private func isLikelyIncomingItemPayload(_ object: IncomingParamsObject) -> Bool {
        guard let type = object["type"]?.stringValue,
              !normalizedItemType(type).isEmpty else {
            return false
        }

        if object["content"] != nil || object["status"] != nil || object["output"] != nil {
            return true
        }
        if object["changes"] != nil || object["files"] != nil || object["diff"] != nil || object["patch"] != nil {
            return true
        }
        if object["result"] != nil || object["payload"] != nil || object["data"] != nil {
            return true
        }

        return false
    }

    private func extractItemID(
        from paramsObject: IncomingParamsObject?,
        eventObject: IncomingParamsObject?,
        itemObject: IncomingParamsObject? = nil
    ) -> String? {
        if let itemId = itemObject?["id"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = itemObject?["call_id"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = itemObject?["callId"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = paramsObject?["itemId"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = paramsObject?["item_id"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = paramsObject?["call_id"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = paramsObject?["callId"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = paramsObject?["id"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = paramsObject?["item"]?.objectValue?["id"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = eventObject?["itemId"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = eventObject?["item_id"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = eventObject?["call_id"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = eventObject?["callId"]?.stringValue, !itemId.isEmpty { return itemId }
        if let itemId = eventObject?["item"]?.objectValue?["id"]?.stringValue, !itemId.isEmpty { return itemId }
        return nil
    }

    private func extractTextDelta(from paramsObject: IncomingParamsObject) -> String {
        let eventObject = envelopeEventObject(from: paramsObject)

        if let delta = paramsObject["delta"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = paramsObject["textDelta"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = paramsObject["text_delta"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = paramsObject["text"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = paramsObject["summary"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = paramsObject["part"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = eventObject?["delta"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = eventObject?["text"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = eventObject?["summary"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = eventObject?["part"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = paramsObject["event"]?.objectValue?["delta"]?.stringValue, !delta.isEmpty {
            return delta
        }
        if let delta = paramsObject["event"]?.objectValue?["text"]?.stringValue, !delta.isEmpty {
            return delta
        }

        return ""
    }

    private func decodeReasoningItemBody(_ itemObject: IncomingParamsObject) -> String {
        let summary = decodeStringParts(itemObject["summary"]).joined(separator: "\n")
        let content = decodeStringParts(itemObject["content"]).joined(separator: "\n\n")

        var sections: [String] = []
        if !summary.isEmpty {
            sections.append(summary)
        }
        if !content.isEmpty {
            sections.append(content)
        }

        if sections.isEmpty {
            return "Thinking..."
        }

        return sections.joined(separator: "\n\n")
    }

    private func decodePlanItemBody(_ itemObject: IncomingParamsObject) -> String {
        let decodedText = decodeItemText(from: itemObject)
        if !decodedText.isEmpty {
            return decodedText
        }

        let summary = decodeStringParts(itemObject["summary"]).joined(separator: "\n")
        if !summary.isEmpty {
            return summary
        }

        return "Planning..."
    }

    private func decodeFileChangeItemBody(_ itemObject: IncomingParamsObject) -> String {
        let status = itemObject["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStatus = (status?.isEmpty == false) ? status! : "inProgress"
        var sections: [String] = ["Status: \(normalizedStatus)"]

        let changes = decodeFileChangeEntries(from: itemObject["changes"])
        let renderedChanges = changes.map { entry -> String in
            var chunk = "Path: \(entry.path)\nKind: \(entry.kind)"
            if let totals = entry.inlineTotals {
                chunk += "\nTotals: +\(totals.additions) -\(totals.deletions)"
            }
            if !entry.diff.isEmpty {
                chunk += "\n\n```diff\n\(entry.diff)\n```"
            }
            return chunk
        }

        if !renderedChanges.isEmpty {
            sections.append(renderedChanges.joined(separator: "\n\n---\n\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    // Extracts a single canonical patch for revert tracking; turn/diff remains the authoritative source.
    private func extractChangeSetUnifiedPatch(
        from itemObject: IncomingParamsObject,
        itemType: String
    ) -> String? {
        switch itemType {
        case "diff":
            if let diff = extractToolCallUnifiedDiff(from: itemObject), looksLikePatchText(diff) {
                return normalizedUnifiedPatchPayload(diff)
            }
        case "toolcall":
            if let diff = extractToolCallUnifiedDiff(from: itemObject), looksLikePatchText(diff) {
                return normalizedUnifiedPatchPayload(diff)
            }
            fallthrough
        case "filechange":
            let changes = decodeFileChangeEntries(from: itemObject["changes"])
            if !changes.isEmpty {
                let joinedDiff = changes
                    .map(\.diff)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                if let normalizedPatch = normalizedUnifiedPatchPayload(joinedDiff) {
                    return normalizedPatch
                }
            }
            let diff = decodeChangeDiff(from: itemObject)
            if let normalizedPatch = normalizedUnifiedPatchPayload(diff) {
                return normalizedPatch
            }
        default:
            break
        }

        return nil
    }

    private func decodeToolCallFileChangeBody(
        _ itemObject: IncomingParamsObject,
        isCompleted: Bool
    ) -> String? {
        guard isLikelyFileChangeToolCall(itemObject: itemObject, fallbackText: extractToolCallOutputText(from: itemObject)) else {
            return nil
        }

        let status = normalizedFileChangeStatus(from: itemObject, isCompleted: isCompleted)
        var synthetic = itemObject
        if synthetic["status"] == nil {
            synthetic["status"] = .string(status)
        }
        if synthetic["changes"] == nil, let extractedChanges = extractToolCallChanges(from: itemObject) {
            synthetic["changes"] = extractedChanges
        }

        let changes = decodeFileChangeEntries(from: synthetic["changes"])
        if !changes.isEmpty {
            return decodeFileChangeItemBody(synthetic)
        }

        if let diff = extractToolCallUnifiedDiff(from: itemObject), looksLikePatchText(diff) {
            return renderUnifiedDiffBody(diff, status: status)
        }

        if let output = extractToolCallOutputText(from: itemObject),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Status: \(status)\n\n" + output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func decodeDiffItemBody(
        _ itemObject: IncomingParamsObject,
        isCompleted: Bool
    ) -> String? {
        let status = normalizedFileChangeStatus(from: itemObject, isCompleted: isCompleted)
        if let diff = extractToolCallUnifiedDiff(from: itemObject), looksLikePatchText(diff) {
            return renderUnifiedDiffBody(diff, status: status)
        }

        if let output = extractToolCallOutputText(from: itemObject),
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Status: \(status)\n\n" + output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func decodeCommandExecutionStatusText(
        _ itemObject: IncomingParamsObject,
        threadId: String? = nil,
        isCompleted: Bool
    ) -> String {
        let state = decodeCommandRunViewState(
            payloadObject: itemObject,
            paramsObject: nil,
            eventType: isCompleted ? "exec_command_end" : "exec_command_begin"
        )
        upsertCommandExecutionDetails(from: state, threadId: threadId, isCompleted: isCompleted)
        return commandExecutionStatusText(for: state)
    }

    private func commandExecutionStatusText(for state: CommandRunViewState) -> String {
        "\(state.phase.rawValue) \(state.shortCommand)"
    }

    private func upsertCommandExecutionDetails(
        from state: CommandRunViewState,
        threadId: String? = nil,
        isCompleted: Bool
    ) {
        guard let itemId = state.itemId, !itemId.isEmpty else { return }
        if let threadId {
            adoptManagedWorktreeProjectPathIfNeeded(threadId: threadId, projectPath: state.cwd)
        }
        if var existing = commandExecutionDetailsByItemID[itemId] {
            if state.fullCommand.count > existing.fullCommand.count {
                existing.fullCommand = state.fullCommand
            }
            if let cwd = state.cwd, existing.cwd == nil {
                existing.cwd = cwd
            }
            existing.exitCode = state.exitCode ?? existing.exitCode
            existing.durationMs = state.durationMs ?? existing.durationMs
            commandExecutionDetailsByItemID[itemId] = existing
        } else {
            commandExecutionDetailsByItemID[itemId] = CommandExecutionDetails(
                fullCommand: state.fullCommand,
                cwd: state.cwd,
                exitCode: state.exitCode,
                durationMs: state.durationMs,
                outputTail: ""
            )
        }
    }

    private func appendCommandExecutionOutputToDetails(itemId: String?, paramsObject: IncomingParamsObject, eventObject: IncomingParamsObject?) {
        guard let itemId, !itemId.isEmpty else { return }
        guard let chunk = commandExecutionOutputChunk(paramsObject: paramsObject, eventObject: eventObject),
              !chunk.isEmpty else { return }
        guard var details = commandExecutionDetailsByItemID[itemId] else { return }
        details.appendOutput(chunk)
        commandExecutionDetailsByItemID[itemId] = details
    }

    // Mirrors toolbar push resets for successful `git push` commands executed by the agent.
    private func maybeAppendPushResetMarker(from state: CommandRunViewState, threadId: String) {
        guard state.phase == .completed else {
            return
        }

        let normalizedCommand = unwrapShellCommandIfPresent(state.fullCommand)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard commandContainsGitPush(normalizedCommand) else {
            return
        }

        appendHiddenPushResetMarkers(
            threadId: threadId,
            workingDirectory: state.cwd,
            branch: "",
            remote: nil
        )
    }

    private func commandContainsGitPush(_ command: String) -> Bool {
        guard !command.isEmpty else {
            return false
        }

        let patterns = [
            #"(^|\s|&&|\|\||;)\s*git\s+push(\s|$)"#,
            #"(^|\s|&&|\|\||;)\s*git\s+-c\s+\S+\s+push(\s|$)"#,
            #"(^|\s|&&|\|\||;)\s*git\s+-C\s+\S+\s+push(\s|$)"#,
        ]

        return patterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func decodeFileChangeEntries(
        from rawChanges: JSONValue?
    ) -> [(path: String, kind: String, diff: String, inlineTotals: (additions: Int, deletions: Int)?)] {
        var changeObjects: [IncomingParamsObject] = []

        if let array = rawChanges?.arrayValue {
            for value in array {
                if let object = value.objectValue {
                    changeObjects.append(object)
                }
            }
        } else if let objectMap = rawChanges?.objectValue {
            for key in objectMap.keys.sorted() {
                guard var object = objectMap[key]?.objectValue else { continue }
                if object["path"] == nil {
                    object["path"] = .string(key)
                }
                changeObjects.append(object)
            }
        }

        return changeObjects.compactMap { changeObject in
            let path = decodeChangePath(from: changeObject)
            let kind = decodeChangeKind(from: changeObject)

            var diff = decodeChangeDiff(from: changeObject)
            let totals = decodeChangeInlineTotals(from: changeObject)
            if diff.isEmpty,
               let content = changeObject["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty {
                diff = synthesizeUnifiedDiffFromContent(content, kind: kind, path: path)
            }

            return (path: path, kind: kind, diff: diff, inlineTotals: totals)
        }
    }

    private func decodeChangePath(from changeObject: IncomingParamsObject) -> String {
        let candidates = [
            changeObject["path"]?.stringValue,
            changeObject["file"]?.stringValue,
            changeObject["file_path"]?.stringValue,
            changeObject["filePath"]?.stringValue,
            changeObject["relative_path"]?.stringValue,
            changeObject["relativePath"]?.stringValue,
            changeObject["new_path"]?.stringValue,
            changeObject["newPath"]?.stringValue,
            changeObject["to"]?.stringValue,
            changeObject["target"]?.stringValue,
            changeObject["name"]?.stringValue,
            changeObject["old_path"]?.stringValue,
            changeObject["oldPath"]?.stringValue,
            changeObject["from"]?.stringValue,
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return "unknown"
    }

    private func decodeChangeKind(from changeObject: IncomingParamsObject) -> String {
        if let kindString = changeObject["kind"]?.stringValue,
           !kindString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return kindString
        }
        if let actionString = changeObject["action"]?.stringValue,
           !actionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return actionString
        }
        if let kindType = changeObject["kind"]?.objectValue?["type"]?.stringValue,
           !kindType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return kindType
        }
        if let typeString = changeObject["type"]?.stringValue,
           !typeString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return typeString
        }
        return "update"
    }

    private func decodeChangeDiff(from changeObject: IncomingParamsObject) -> String {
        let diff = changeObject["diff"]?.stringValue
            ?? changeObject["unified_diff"]?.stringValue
            ?? changeObject["unifiedDiff"]?.stringValue
            ?? changeObject["patch"]?.stringValue
            ?? changeObject["delta"]?.stringValue
            ?? ""
        return diff.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeChangeInlineTotals(
        from changeObject: IncomingParamsObject
    ) -> (additions: Int, deletions: Int)? {
        let additions = decodeNumericField(
            from: changeObject,
            keys: [
                "additions",
                "lines_added",
                "line_additions",
                "lineAdditions",
                "added",
                "insertions",
                "inserted",
                "num_added",
            ]
        ) ?? 0
        let deletions = decodeNumericField(
            from: changeObject,
            keys: [
                "deletions",
                "lines_deleted",
                "line_deletions",
                "lineDeletions",
                "removed",
                "deleted",
                "num_deleted",
                "num_removed",
            ]
        ) ?? 0

        guard additions > 0 || deletions > 0 else { return nil }
        return (additions: additions, deletions: deletions)
    }

    private func decodeNumericField(
        from object: IncomingParamsObject,
        keys: [String]
    ) -> Int? {
        for key in keys {
            if let intValue = object[key]?.intValue {
                return intValue
            }
            if let doubleValue = object[key]?.doubleValue {
                return Int(doubleValue)
            }
            if let stringValue = object[key]?.stringValue,
               let parsed = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private func synthesizeUnifiedDiffFromContent(
        _ content: String,
        kind: String,
        path: String
    ) -> String {
        let normalizedKind = kind.lowercased()
        let contentLines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if normalizedKind.contains("add") || normalizedKind.contains("create") {
            var lines: [String] = [
                "diff --git a/\(path) b/\(path)",
                "new file mode 100644",
                "--- /dev/null",
                "+++ b/\(path)",
            ]
            lines.append(contentsOf: contentLines.map { "+\($0)" })
            return lines.joined(separator: "\n")
        }

        if normalizedKind.contains("delete") || normalizedKind.contains("remove") {
            var lines: [String] = [
                "diff --git a/\(path) b/\(path)",
                "deleted file mode 100644",
                "--- a/\(path)",
                "+++ /dev/null",
            ]
            lines.append(contentsOf: contentLines.map { "-\($0)" })
            return lines.joined(separator: "\n")
        }

        return ""
    }

    private func decodeTurnDiffUpdatedBody(from diff: String) -> String {
        renderUnifiedDiffBody(diff, status: "inProgress")
    }

    private func renderUnifiedDiffBody(_ diff: String, status: String) -> String {
        let perFileDiffs = splitUnifiedDiffByFile(diff)
        guard !perFileDiffs.isEmpty else {
            return "Status: \(status)\n\n```diff\n\(diff)\n```"
        }

        let renderedChanges = perFileDiffs.map { change in
            let normalizedPath = normalizeDiffPath(change.path)
            return "Path: \(normalizedPath)\nKind: update\n\n```diff\n\(change.diff)\n```"
        }

        return "Status: \(status)\n\n" + renderedChanges.joined(separator: "\n\n---\n\n")
    }

    private func splitUnifiedDiffByFile(_ diff: String) -> [(path: String, diff: String)] {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }

        var chunks: [(path: String, diff: String)] = []
        var currentLines: [String] = []
        var currentPath: String?

        func flushChunk() {
            guard !currentLines.isEmpty else { return }
            let fallbackPath = currentPath ?? parsePathFromDiffLines(currentLines) ?? "unknown"
            let chunkText = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunkText.isEmpty else {
                currentLines = []
                return
            }

            chunks.append((path: fallbackPath, diff: chunkText))
            currentLines = []
        }

        for line in lines {
            if line.hasPrefix("diff --git "), !currentLines.isEmpty {
                flushChunk()
                currentPath = nil
            }

            if currentPath == nil, let parsed = parsePathFromDiffLine(line) {
                currentPath = parsed
            }
            currentLines.append(line)
        }

        flushChunk()
        return chunks
    }

    private func parsePathFromDiffLines(_ lines: [String]) -> String? {
        for line in lines {
            if let parsed = parsePathFromDiffLine(line) {
                return parsed
            }
        }
        return nil
    }

    private func parsePathFromDiffLine(_ line: String) -> String? {
        if line.hasPrefix("+++ ") {
            let rawPath = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeDiffPath(rawPath)
            return normalized.isEmpty ? nil : normalized
        }

        if line.hasPrefix("diff --git ") {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            if components.count >= 4 {
                let normalized = normalizeDiffPath(String(components[3]))
                return normalized.isEmpty ? nil : normalized
            }
        }

        return nil
    }

    private func normalizeDiffPath(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/dev/null" else { return "unknown" }

        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    private func decodeStringParts(_ value: JSONValue?) -> [String] {
        guard let value else { return [] }

        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case .array(let values):
            return values
                .compactMap { candidate -> String? in
                    if let text = candidate.stringValue {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    if let object = candidate.objectValue,
                       let text = object["text"]?.stringValue {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    return nil
                }
        case .object(let object):
            if let text = object["text"]?.stringValue {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [trimmed]
            }
            return []
        default:
            return []
        }
    }

    private func normalizedFileChangeStatus(from itemObject: IncomingParamsObject, isCompleted: Bool) -> String {
        let nestedOutput = itemObject["output"]?.objectValue
        let nestedResult = itemObject["result"]?.objectValue
        let nestedPayload = itemObject["payload"]?.objectValue
        let nestedData = itemObject["data"]?.objectValue
        let status = firstNonEmptyString([
            itemObject["status"]?.stringValue,
            nestedOutput?["status"]?.stringValue,
            nestedResult?["status"]?.stringValue,
            nestedPayload?["status"]?.stringValue,
            nestedData?["status"]?.stringValue,
        ])
        if let status {
            return status
        }
        return isCompleted ? "completed" : "inProgress"
    }

    private func extractToolCallChanges(from itemObject: IncomingParamsObject) -> JSONValue? {
        let candidateKeys = [
            "changes",
            "file_changes",
            "fileChanges",
            "files",
            "edits",
            "modified_files",
            "modifiedFiles",
            "patches",
        ]

        if let direct = firstValue(forAnyKey: candidateKeys, in: .object(itemObject)) {
            return direct
        }
        return nil
    }

    private func extractToolCallUnifiedDiff(from itemObject: IncomingParamsObject) -> String? {
        let candidateKeys = ["diff", "unified_diff", "unifiedDiff", "patch"]
        for key in candidateKeys {
            if let value = firstString(forKey: key, in: .object(itemObject)) {
                return value
            }
        }
        return nil
    }

    private func extractToolCallOutputText(from itemObject: IncomingParamsObject) -> String? {
        if let directOutput = itemObject["output"]?.stringValue,
           !directOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return directOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let directResult = itemObject["result"]?.stringValue,
           !directResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return directResult.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let candidateKeys = ["text", "message", "summary", "stdout", "stderr", "output_text", "outputText"]
        var extracted: [String] = []
        for key in candidateKeys {
            if let value = firstString(forKey: key, in: .object(itemObject)),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                extracted.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        if extracted.isEmpty,
           let contentString = flattenNestedText(from: .object(itemObject)) {
            return contentString
        }

        if extracted.isEmpty {
            return nil
        }

        return extracted.joined(separator: "\n\n")
    }

    private func isLikelyFileChangeToolCall(
        itemObject: IncomingParamsObject?,
        fallbackText: String?
    ) -> Bool {
        guard let itemObject else {
            return looksLikePatchText(fallbackText ?? "")
        }

        let descriptor = toolCallDescriptor(from: itemObject)
        let normalizedDescriptor = descriptor
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")

        let hasToolHint = normalizedDescriptor.contains("filechange")
            || normalizedDescriptor.contains("applypatch")
            || normalizedDescriptor.contains("patchapply")
            || normalizedDescriptor.contains("diff")
            || normalizedDescriptor.contains("edit")
            || normalizedDescriptor.contains("write")
            || normalizedDescriptor.contains("rename")
            || normalizedDescriptor.contains("delete")
            || normalizedDescriptor.contains("remove")
            || normalizedDescriptor.contains("create")
            || normalizedDescriptor.contains("add")
            || normalizedDescriptor.contains("move")

        let hasStructuredChanges = extractToolCallChanges(from: itemObject) != nil
        let hasDiffPayload = extractToolCallUnifiedDiff(from: itemObject).map(looksLikePatchText) ?? false
        let hasPatchLikeText = looksLikePatchText(fallbackText ?? "")

        return (hasToolHint && (hasStructuredChanges || hasDiffPayload || hasPatchLikeText))
            || hasDiffPayload
            || hasPatchLikeText
    }

    private func toolCallDescriptor(from itemObject: IncomingParamsObject) -> String {
        let nestedTool = itemObject["tool"]?.objectValue
        let nestedCall = itemObject["call"]?.objectValue
        var parts = [
            itemObject["kind"]?.stringValue,
            itemObject["name"]?.stringValue,
            itemObject["tool"]?.stringValue,
            itemObject["tool_name"]?.stringValue,
            itemObject["toolName"]?.stringValue,
            itemObject["title"]?.stringValue,
            nestedTool?["kind"]?.stringValue,
            nestedTool?["name"]?.stringValue,
            nestedTool?["type"]?.stringValue,
            nestedTool?["title"]?.stringValue,
            nestedCall?["kind"]?.stringValue,
            nestedCall?["name"]?.stringValue,
            nestedCall?["type"]?.stringValue,
            nestedCall?["title"]?.stringValue,
        ]
        if let recursiveToolName = firstString(forKey: "tool_name", in: .object(itemObject)) {
            parts.append(recursiveToolName)
        }
        if let recursiveKind = firstString(forKey: "kind", in: .object(itemObject)) {
            parts.append(recursiveKind)
        }
        if let recursiveName = firstString(forKey: "name", in: .object(itemObject)) {
            parts.append(recursiveName)
        }
        return parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func extractThreadID(from paramsObject: IncomingParamsObject?) -> String? {
        guard let paramsObject else { return nil }

        if let threadId = normalizedIdentifier(paramsObject["threadId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(paramsObject["thread_id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(paramsObject["conversationId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(paramsObject["conversation_id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(paramsObject["thread"]?.objectValue?["id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(paramsObject["turn"]?.objectValue?["threadId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(paramsObject["turn"]?.objectValue?["thread_id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(paramsObject["item"]?.objectValue?["threadId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(paramsObject["item"]?.objectValue?["thread_id"]?.stringValue) { return threadId }

        let eventObject = envelopeEventObject(from: paramsObject)
        if let threadId = normalizedIdentifier(eventObject?["threadId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject?["thread_id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject?["conversationId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject?["conversation_id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject?["thread"]?.objectValue?["id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject?["turn"]?.objectValue?["threadId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject?["turn"]?.objectValue?["thread_id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject?["item"]?.objectValue?["threadId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject?["item"]?.objectValue?["thread_id"]?.stringValue) { return threadId }

        guard let eventObject = paramsObject["event"]?.objectValue else { return nil }
        if let threadId = normalizedIdentifier(eventObject["threadId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject["thread_id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject["conversationId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject["conversation_id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject["thread"]?.objectValue?["id"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject["turn"]?.objectValue?["threadId"]?.stringValue) { return threadId }
        if let threadId = normalizedIdentifier(eventObject["turn"]?.objectValue?["thread_id"]?.stringValue) { return threadId }

        return nil
    }

    func extractTurnID(from paramsObject: IncomingParamsObject?) -> String? {
        guard let paramsObject else { return nil }

        if let turnId = extractTurnID(from: paramsObject["turn"]) { return turnId }
        if let turnId = normalizedIdentifier(paramsObject["turnId"]?.stringValue) { return turnId }
        if let turnId = normalizedIdentifier(paramsObject["turn_id"]?.stringValue) { return turnId }
        if let turnId = normalizedIdentifier(paramsObject["item"]?.objectValue?["turnId"]?.stringValue) { return turnId }
        if let turnId = normalizedIdentifier(paramsObject["item"]?.objectValue?["turn_id"]?.stringValue) { return turnId }

        let eventObject = envelopeEventObject(from: paramsObject)
        if let turnId = normalizedIdentifier(eventObject?["turnId"]?.stringValue) { return turnId }
        if let turnId = normalizedIdentifier(eventObject?["turn_id"]?.stringValue) { return turnId }
        if let turnId = extractTurnID(from: eventObject?["turn"]) { return turnId }
        if let turnId = normalizedIdentifier(eventObject?["item"]?.objectValue?["turnId"]?.stringValue) { return turnId }
        if let turnId = normalizedIdentifier(eventObject?["item"]?.objectValue?["turn_id"]?.stringValue) { return turnId }

        guard let eventObject = paramsObject["event"]?.objectValue else { return nil }
        if let turnId = normalizedIdentifier(eventObject["turnId"]?.stringValue) { return turnId }
        if let turnId = normalizedIdentifier(eventObject["turn_id"]?.stringValue) { return turnId }
        if let turnId = extractTurnID(from: eventObject["turn"]) { return turnId }

        return nil
    }

    func envelopeEventObject(from paramsObject: IncomingParamsObject?) -> IncomingParamsObject? {
        paramsObject?["msg"]?.objectValue ?? paramsObject?["event"]?.objectValue
    }

    // Turn lifecycle notifications sometimes carry the turn id as top-level `id`.
    // Accept that shape only for turn/started and turn/completed handling.
    private func extractTurnIDForTurnLifecycleEvent(from paramsObject: IncomingParamsObject?) -> String? {
        if let turnID = extractTurnID(from: paramsObject) {
            return turnID
        }

        let eventObject = envelopeEventObject(from: paramsObject)
        let nestedEventObject = paramsObject?["event"]?.objectValue
        return normalizedIdentifier(
            paramsObject?["id"]?.stringValue
                ?? eventObject?["id"]?.stringValue
                ?? nestedEventObject?["id"]?.stringValue
        )
    }

    private func shouldRetryTurnError(from paramsObject: IncomingParamsObject?) -> Bool {
        let eventObject = envelopeEventObject(from: paramsObject)

        let candidates: [JSONValue?] = [
            paramsObject?["willRetry"],
            paramsObject?["will_retry"],
            eventObject?["willRetry"],
            eventObject?["will_retry"],
            paramsObject?["event"]?.objectValue?["willRetry"],
            paramsObject?["event"]?.objectValue?["will_retry"],
        ]

        for candidate in candidates {
            if let parsed = parseBooleanFlag(candidate) {
                return parsed
            }
        }
        return false
    }

    private func parseBooleanFlag(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }

        if let boolValue = value.boolValue {
            return boolValue
        }

        guard let text = value.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }

        if text == "true" || text == "1" || text == "yes" {
            return true
        }
        if text == "false" || text == "0" || text == "no" {
            return false
        }

        return nil
    }

    func normalizedIdentifier(_ candidate: String?) -> String? {
        guard let candidate else {
            return nil
        }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Reuses the same "first meaningful string wins" rule for array-built candidate lists.
    private func firstNonEmptyString(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func hasStreamingMessage(in threadId: String) -> Bool {
        (messagesByThread[threadId] ?? []).contains(where: { $0.isStreaming })
    }

    func resolveThreadID(
        from paramsObject: IncomingParamsObject?,
        turnIdHint: String? = nil
    ) -> String? {
        if let threadId = extractThreadID(from: paramsObject), !threadId.isEmpty {
            if let turnId = turnIdHint ?? extractTurnID(from: paramsObject) {
                threadIdByTurnID[turnId] = threadId
            }
            return threadId
        }

        if let turnId = turnIdHint ?? extractTurnID(from: paramsObject),
           let mappedThreadId = threadIdByTurnID[turnId] {
            return mappedThreadId
        }

        // Conservative fallback: infer only when there is a single unambiguous thread context.
        if activeTurnIdByThread.count == 1,
           let soleRunningThreadId = activeTurnIdByThread.keys.first {
            return soleRunningThreadId
        }
        if threads.count == 1, let soleThreadId = threads.first?.id {
            return soleThreadId
        }
        if threads.isEmpty,
           messagesByThread.keys.count <= 1,
           let activeThreadId {
            return activeThreadId
        }

        return nil
    }

    // Token-count events can be session-scoped, so only fall back when one running thread is unambiguous.
    func resolveContextUsageThreadID(
        from paramsObject: IncomingParamsObject?,
        turnIdHint: String? = nil
    ) -> String? {
        if let resolved = resolveThreadID(from: paramsObject, turnIdHint: turnIdHint) {
            return resolved
        }

        let runtimeScopedCandidates = runningThreadIDs.union(protectedRunningFallbackThreadIDs)
        if runtimeScopedCandidates.count == 1 {
            return runtimeScopedCandidates.first
        }

        return nil
    }

    func extractIncomingMessageText(from itemObject: [String: JSONValue]) -> String {
        let contentItems = itemObject["content"]?.arrayValue ?? []
        var parts: [String] = []

        for content in contentItems {
            guard let object = content.objectValue else { continue }
            let contentType = object["type"]?.stringValue?.lowercased()
            let isTextType = contentType == nil
                || contentType == "text"
                || contentType == "input_text"
                || contentType == "output_text"
                || contentType == "message"
            if contentType == "skill" {
                let skillID = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let skillName = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = (skillID?.isEmpty == false) ? skillID : skillName
                if let resolved, !resolved.isEmpty {
                    parts.append("$\(resolved)")
                }
                continue
            }

            guard isTextType else { continue }

            if let text = object["text"]?.stringValue, !text.isEmpty {
                parts.append(text)
                continue
            }

            if let delta = object["delta"]?.stringValue, !delta.isEmpty {
                parts.append(delta)
                continue
            }

            if let nestedText = object["data"]?.objectValue?["text"]?.stringValue,
               !nestedText.isEmpty {
                parts.append(nestedText)
            }
        }

        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            return joined
        }

        if let directText = itemObject["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directText.isEmpty {
            return directText
        }

        if let messageText = itemObject["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !messageText.isEmpty {
            return messageText
        }

        return ""
    }
}
