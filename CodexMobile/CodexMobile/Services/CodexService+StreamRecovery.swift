import Foundation

extension CodexService {
    func recordRecoverableStreamFailure(
        threadId: String, turnId: String?, message: String, errorInfo: JSONValue?
    ) {
        guard !isApplyingReplayedBridgeEvent,
              let turnId, !Self.isSyntheticPlaceholderTurnID(turnId),
              CodexStreamFailure.isRecoverable(message: message, errorInfo: errorInfo),
              turnTerminalState(for: turnId, threadId: threadId) != .stopped,
              lastRunStartTurnIDByThread[threadId].map({ $0 == turnId }) ?? true,
              activeTurnID(for: threadId).map({ $0 == turnId }) ?? true else { return }
        // error and turn/completed commonly describe the same failure. Preserve
        // dismissal/consumption so their duplicate delivery cannot re-arm Continue.
        guard recoverableStreamFailuresByThread[threadId]?.turnID != turnId else { return }
        recoverableStreamFailuresByThread[threadId] = CodexStreamFailure(
            turnID: turnId, message: message,
            runGeneration: runStartGenerationByThread[threadId, default: 0]
        )
    }

    func recoverableStreamFailure(for threadId: String) -> CodexStreamFailure? {
        guard isConnected, isInitialized,
              !threadHasActiveOrRunningTurn(threadId),
              latestTurnTerminalState(for: threadId) == .failed,
              let failure = recoverableStreamFailuresByThread[threadId],
              !failure.isDismissed, !failure.hasAttemptedContinuation,
              failure.runGeneration == runStartGenerationByThread[threadId, default: 0] else { return nil }
        return failure
    }

    func dismissStreamFailure(threadId: String, failureID: UUID? = nil) {
        guard let failure = recoverableStreamFailuresByThread[threadId],
              failureID == nil || failure.id == failureID else { return }
        recoverableStreamFailuresByThread[threadId]?.isDismissed = true
        if lastErrorMessage == failure.message { lastErrorMessage = nil }
    }

    func reconcileRepeatedStreamFailure(threadId: String, turnId: String?) -> Bool {
        guard let failure = recoverableStreamFailuresByThread[threadId], failure.turnID == turnId,
              turnTerminalState(for: turnId, threadId: threadId) == .failed else { return false }
        // The first error already finalized this turn. Reconcile its final
        // history without duplicating the row or closing a pending continuation.
        requestThreadHistoryReconcile(threadId: threadId)
        if !threadHasActiveOrRunningTurn(threadId), !streamFailureContinuationsInFlight.contains(failure.id) {
            requestImmediateSync(threadId: threadId)
        }
        return true
    }

    func continueAfterStreamFailure(
        threadId: String, failureID: UUID, onDispatch: () -> Void = {}
    ) async throws {
        guard let failure = recoverableStreamFailure(for: threadId), failure.id == failureID,
              streamFailureContinuationsInFlight.insert(failureID).inserted else { return }
        defer { streamFailureContinuationsInFlight.remove(failureID) }
        let connectionGeneration = streamRecoveryConnectionGeneration

        // Resume through the existing owner-aware route. A missing thread must
        // fail here rather than silently creating a fresh conversation.
        try await ensureThreadResumed(threadId: threadId)
        try validateStreamContinuation(failure, threadId: threadId, connectionGeneration: connectionGeneration)
        try await waitForRuntimeSettingsUpdate(threadId: threadId)
        try validateStreamContinuation(failure, threadId: threadId, connectionGeneration: connectionGeneration)
        let messageID = appendUserMessage(threadId: threadId, text: CodexStreamFailure.continuationPrompt)
        if let checkpoint = scheduleMessageStartWorkspaceCheckpointIfPossible(threadId: threadId, messageId: messageID) {
            await checkpoint.value
        }
        do {
            try validateStreamContinuation(failure, threadId: threadId, connectionGeneration: connectionGeneration)
            let snapshot = try await readThreadTurnStateSnapshot(threadId: threadId)
            try validateStreamContinuation(failure, threadId: threadId, connectionGeneration: connectionGeneration)
            guard snapshot.interruptibleTurnID == nil, !snapshot.hasInterruptibleTurnWithoutID,
                  snapshot.latestTurnID == failure.turnID,
                  snapshot.latestTurnStatus == "failed" else {
                dismissStreamFailure(threadId: threadId, failureID: failure.id)
                requestImmediateSync(threadId: threadId)
                throw CodexServiceError.invalidInput("This chat has changed. Refresh it before continuing.")
            }
        } catch {
            markMessageDeliveryState(threadId: threadId, messageId: messageID, state: .failed)
            throw error
        }
        recoverableStreamFailuresByThread[threadId]?.hasAttemptedContinuation = true
        if lastErrorMessage == failure.message { lastErrorMessage = nil }
        onDispatch()
        markThreadAsRunning(threadId)
        setProtectedRunningFallback(true, for: threadId)

        // Omitted runtime settings inherit the current owner's model, permissions,
        // speed and collaboration mode. This request follows normal bridge routing.
        var params: RPCObject = [
            "threadId": .string(threadId),
            "input": .array([.object([
                "type": .string("text"), "text": .string(CodexStreamFailure.continuationPrompt),
            ])]),
        ]
        if supportsRuntimeSettingsSync {
            params["remodexRuntimeSettingsVersion"] = .integer(2)
        }
        do {
            let response = try await sendRequest(method: "turn/start", params: .object(params))
            guard connectionGeneration == streamRecoveryConnectionGeneration else { return }
            let responseTurnID = extractTurnID(from: response.result)
            // Notifications can finish this turn, or start another one, before
            // the acknowledgement arrives. It must not revive/replace that state.
            if let responseTurnID, turnTerminalState(for: responseTurnID, threadId: threadId) != nil {
                markMessageDeliveryState(threadId: threadId, messageId: messageID, state: .confirmed, turnId: responseTurnID)
                return
            }
            guard runStartGenerationByThread[threadId, default: 0] == failure.runGeneration
                    || (responseTurnID != nil && activeTurnID(for: threadId) == responseTurnID) else { return }
            let turnID = handleSuccessfulTurnStartResponse(response, pendingMessageId: messageID, threadId: threadId)
            if let turnID {
                scheduleMessageStartWorkspaceCheckpointCopyIfPossible(threadId: threadId, messageId: messageID, turnId: turnID)
            }
        } catch {
            // Delivery may be ambiguous. Keep this failure consumed, and never
            // clear a newer run that started while the request was in flight.
            if connectionGeneration == streamRecoveryConnectionGeneration,
               runStartGenerationByThread[threadId, default: 0] == failure.runGeneration {
                try handleTurnStartFailure(error, pendingMessageId: messageID, threadId: threadId)
            }
            throw error
        }
    }

    private func validateStreamContinuation(
        _ failure: CodexStreamFailure, threadId: String, connectionGeneration: Int
    ) throws {
        guard !Task.isCancelled, isConnected, isInitialized,
              connectionGeneration == streamRecoveryConnectionGeneration,
              recoverableStreamFailuresByThread[threadId]?.id == failure.id,
              recoverableStreamFailuresByThread[threadId]?.isDismissed == false,
              runStartGenerationByThread[threadId, default: 0] == failure.runGeneration,
              lastRunStartTurnIDByThread[threadId].map({ $0 == failure.turnID }) ?? true,
              activeTurnID(for: threadId) == nil,
              !threadHasActiveOrRunningTurn(threadId) else {
            throw CodexServiceError.invalidInput("This chat changed before it could continue. Check its latest state and try again.")
        }
    }
}
