import Foundation

extension CodexService {
    /// Keeps the question on its original assistant item, including question-only items.
    func upsertAsyncUserInput(
        _ input: CodexAsyncUserInput,
        threadId: String,
        turnId: String?,
        itemId: String?,
        text: String,
        completed: Bool
    ) {
        guard thread(for: threadId)?.runtimeProvider != .opencode,
              let itemId, !itemId.isEmpty else { return }
        if let index = messagesByThread[threadId]?.lastIndex(where: {
            $0.role == .assistant && $0.itemId == itemId
        }) {
            let old = messagesByThread[threadId]![index]
            messagesByThread[threadId]?[index].asyncUserInput = .merge(local: old.asyncUserInput, incoming: input)
            if old.turnId == nil { messagesByThread[threadId]?[index].turnId = turnId }
            if completed { messagesByThread[threadId]?[index].isStreaming = false }
            if !text.isEmpty { messagesByThread[threadId]?[index].text = text }
        } else {
            appendMessage(CodexMessage(
                id: Self.stableAssistantMessageID(threadId: threadId, turnId: turnId, itemId: itemId)
                    ?? UUID().uuidString,
                threadId: threadId,
                role: .assistant,
                text: text,
                turnId: turnId,
                itemId: itemId,
                isStreaming: !completed,
                asyncUserInput: input
            ))
        }
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    func submitAsyncUserInput(threadId: String, messageID: String, answers: [String]) async {
        guard thread(for: threadId)?.runtimeProvider != .opencode,
              let index = messagesByThread[threadId]?.firstIndex(where: { $0.id == messageID }),
              var input = messagesByThread[threadId]?[index].asyncUserInput,
              input.status == .unanswered,
              answers.count == input.questions.count,
              answers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        input.answers = answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let responseText = input.responseText else { return }
        guard isConnected, isInitialized else {
            messagesByThread[threadId]?[index].asyncUserInput = input
            persistMessages()
            updateCurrentOutput(for: threadId)
            lastErrorMessage = "Reconnect to send your answer."
            return
        }
        let responseMessageID = appendUserMessage(threadId: threadId, text: responseText)
        guard !responseMessageID.isEmpty else { return }
        if let userIndex = findMessageIndex(threadId: threadId, messageId: responseMessageID) {
            messagesByThread[threadId]?[userIndex].kind = .asyncUserInputAnswer
        }
        input.responseMessageID = responseMessageID
        input.responseRecordedAt = Date()
        input.status = .submitting
        messagesByThread[threadId]?[index].asyncUserInput = input
        persistMessages()
        updateCurrentOutput(for: threadId)
        await deliverAsyncUserInput(threadId: threadId, messageID: messageID)
    }

    private func deliverAsyncUserInput(threadId: String, messageID: String) async {
        guard let index = messagesByThread[threadId]?.firstIndex(where: { $0.id == messageID }),
              let input = messagesByThread[threadId]?[index].asyncUserInput,
              let responseText = input.responseText,
              let responseMessageID = input.responseMessageID,
              input.status == .submitting || input.status == .queued else { return }

        var deliveryMayHaveStarted = false
        do {
            guard isConnected, isInitialized else { throw CodexServiceError.disconnected }
            if threadHasActiveOrRunningTurn(threadId) {
                let turnID = try await resolveInFlightTurnID(threadId: threadId)
                guard let turnID, !Self.isSyntheticPlaceholderTurnID(turnID) else {
                    setAsyncUserInputStatus(.queued, threadId: threadId, messageID: messageID)
                    await refreshAndFlushQueuedAsyncInput(threadId: threadId)
                    return
                }
                // The turn may have completed while resolving its id. In that
                // case the reply belongs in a new turn, not a stale steer.
                guard threadHasActiveOrRunningTurn(threadId) else {
                    setAsyncUserInputStatus(.queued, threadId: threadId, messageID: messageID)
                    await flushQueuedAsyncUserInput(threadId: threadId)
                    return
                }
                let payload: RPCObject = [
                    "threadId": .string(threadId),
                    "expectedTurnId": .string(turnID),
                    "clientUserMessageId": .string(responseMessageID),
                    "input": .array([.object([
                        "type": .string("text"),
                        "text": .string(responseText),
                        "text_elements": .array([]),
                    ])]),
                ]
                guard isConnected, isInitialized else { throw CodexServiceError.disconnected }
                deliveryMayHaveStarted = true
                _ = try await sendRequest(
                    method: "turn/steer",
                    params: .object(payload),
                    timeoutNanoseconds: 30_000_000_000,
                    timeoutMessage: "The answer may have reached Codex, but confirmation timed out. Check on your Mac."
                )
                markMessageDeliveryState(
                    threadId: threadId,
                    messageId: responseMessageID,
                    state: .confirmed,
                    turnId: turnID
                )
            } else {
                deliveryMayHaveStarted = true
                try await startTurn(
                    userInput: responseText,
                    threadId: threadId,
                    shouldAppendUserMessage: false,
                    preAppendedUserMessageID: responseMessageID
                )
            }
            setAsyncUserInputStatus(.answered, threadId: threadId, messageID: messageID)
        } catch {
            // History may have confirmed the reply while the request was in flight.
            if messagesByThread[threadId]?.first(where: { $0.id == messageID })?.asyncUserInput?.status == .answered {
                return
            }
            if !deliveryMayHaveStarted {
                resetAsyncUserInputForRetry(threadId: threadId, messageID: messageID)
                lastErrorMessage = error.localizedDescription
            } else if isActiveTurnNotSteerable(error) {
                setAsyncUserInputStatus(.queued, threadId: threadId, messageID: messageID)
                await refreshAndFlushQueuedAsyncInput(threadId: threadId)
            } else {
                // Transport errors can mean the Mac accepted the reply before the socket fell.
                // Preserve the answer and wait for history instead of sending it twice.
                setAsyncUserInputStatus(.uncertain, threadId: threadId, messageID: messageID)
                scheduleAsyncAnswerVerification(threadId: threadId, delay: 3)
            }
        }
    }

    private func refreshAndFlushQueuedAsyncInput(threadId: String) async {
        if threadHasActiveOrRunningTurn(threadId) {
            await syncActiveThreadState(threadId: threadId)
        }
        await flushQueuedAsyncUserInput(threadId: threadId)
    }

    private func isActiveTurnNotSteerable(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else { return false }
        let normalized = rpcError.message.lowercased().filter(\.isLetter)
        return normalized.contains("activeturnnotsteerable")
            || normalized.contains("turnisnotsteerable")
    }

    func flushQueuedAsyncUserInput(threadId: String) async {
        guard isConnected, isInitialized, !threadHasActiveOrRunningTurn(threadId) else { return }
        let ids = messagesByThread[threadId]?.compactMap { message in
            message.asyncUserInput?.status == .queued ? message.id : nil
        } ?? []
        for id in ids {
            guard !threadHasActiveOrRunningTurn(threadId) else { return }
            setAsyncUserInputStatus(.submitting, threadId: threadId, messageID: id)
            await deliverAsyncUserInput(threadId: threadId, messageID: id)
        }
    }

    func scheduleAsyncAnswerVerification(threadId: String, delay: TimeInterval) {
        guard asyncAnswerVerificationThreadIDs.insert(threadId).inserted else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            guard self.isConnected, self.isInitialized else {
                self.asyncAnswerVerificationThreadIDs.remove(threadId)
                return
            }
            do {
                // The initial turns page can omit older items. Verify removal only
                // against a full thread/read, then re-read once more before reopening.
                let threadObject = try await self.fetchLegacyThreadHistoryObject(threadId: threadId)
                let canonical = self.decodeMessagesFromThreadRead(threadId: threadId, threadObject: threadObject)
                if self.canVerifyAsyncAnswerAbsence(threadId: threadId, threadObject: threadObject),
                   var messages = self.messagesByThread[threadId] {
                    let nextDelay = CodexAsyncUserInputProjection.reopenRepliesMissingFromCanonicalHistory(
                        &messages,
                        canonical: canonical
                    )
                    if messages != self.messagesByThread[threadId] {
                        self.messagesByThread[threadId] = messages
                        self.persistMessages()
                        self.updateCurrentOutput(for: threadId)
                    }
                    self.asyncAnswerVerificationThreadIDs.remove(threadId)
                    if let nextDelay {
                        self.scheduleAsyncAnswerVerification(threadId: threadId, delay: nextDelay)
                    }
                } else {
                    self.asyncAnswerVerificationThreadIDs.remove(threadId)
                }
            } catch {
                self.asyncAnswerVerificationThreadIDs.remove(threadId)
            }
        }
    }

    func canVerifyAsyncAnswerAbsence(threadId: String, threadObject: RPCObject) -> Bool {
        guard !threadHasActiveOrRunningTurn(threadId),
              let turns = threadObject["turns"]?.arrayValue else { return false }
        let snapshot = turnStateSnapshot(from: turns.compactMap(\.objectValue), newestFirst: false)
        return snapshot.interruptibleTurnID == nil && !snapshot.hasInterruptibleTurnWithoutID
    }

    private func resetAsyncUserInputForRetry(threadId: String, messageID: String) {
        guard let index = messagesByThread[threadId]?.firstIndex(where: { $0.id == messageID }),
              var input = messagesByThread[threadId]?[index].asyncUserInput else { return }
        let responseID = input.responseMessageID
        input.prepareForRetry()
        messagesByThread[threadId]?[index].asyncUserInput = input
        messagesByThread[threadId]?.removeAll { $0.id == responseID && $0.kind == .asyncUserInputAnswer }
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    private func setAsyncUserInputStatus(
        _ status: CodexAsyncUserInputStatus,
        threadId: String,
        messageID: String
    ) {
        guard let index = messagesByThread[threadId]?.firstIndex(where: { $0.id == messageID }) else { return }
        messagesByThread[threadId]?[index].asyncUserInput?.status = status
        persistMessages()
        updateCurrentOutput(for: threadId)
    }
}
