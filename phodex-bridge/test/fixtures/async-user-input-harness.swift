import Foundation

// Only the host, message container and transport are mocked. The submission,
// projection, draft preservation and reconciliation code come from the app.
nonisolated struct CodexMessage: Equatable {
    enum Role { case assistant, user }
    enum Kind { case chat, asyncUserInputAnswer }
    enum Delivery { case pending, confirmed }
    let id: String
    let threadId: String
    let role: Role
    var text: String
    var turnId: String? = nil
    var itemId: String? = nil
    var isStreaming = false
    var asyncUserInput: CodexAsyncUserInput? = nil
    var kind: Kind = .chat
    var createdAt = Date()
}

@MainActor final class CodexService {
    enum Provider { case codex, opencode }
    struct Thread { var runtimeProvider: Provider = .codex }
    var isConnected = true
    var isInitialized = true
    var active = true
    var messagesByThread: [String: [CodexMessage]] = [:]
    var asyncAnswerVerificationThreadIDs: Set<String> = []
    var lastErrorMessage: String?
    var sends = 0
    var starts = 0
    var resolve: () async throws -> String? = { "turn_1" }
    var onSend: () async throws -> Void = {}
    var beforeDispatch: () throws -> Void = {}

    func thread(for _: String) -> Thread? { Thread() }
    static func stableAssistantMessageID(threadId: String, turnId: String?, itemId: String) -> String? { itemId }
    static func isSyntheticPlaceholderTurnID(_ id: String) -> Bool { id == "placeholder" }
    func appendMessage(_ message: CodexMessage) { messagesByThread[message.threadId, default: []].append(message) }
    func appendUserMessage(threadId: String, text: String) -> String {
        let id = UUID().uuidString
        appendMessage(.init(id: id, threadId: threadId, role: .user, text: text))
        return id
    }
    func findMessageIndex(threadId: String, messageId: String) -> Int? {
        messagesByThread[threadId]?.firstIndex(where: { $0.id == messageId })
    }
    func persistMessages() {}
    func updateCurrentOutput(for _: String) {}
    func threadHasActiveOrRunningTurn(_: String) -> Bool { active }
    func resolveInFlightTurnID(threadId: String) async throws -> String? { try await resolve() }
    func sendRequest(method: String, params: JSONValue?, timeoutNanoseconds: UInt64?, timeoutMessage: String?, onDispatch: (@MainActor () -> Void)? = nil) async throws -> RPCMessage {
        precondition(method == "turn/steer")
        precondition(params?.objectValue?["clientUserMessageId"]?.stringValue != nil)
        try beforeDispatch()
        onDispatch?()
        sends += 1
        try await onSend()
        return RPCMessage(id: nil, result: .object([:]))
    }
    func markMessageDeliveryState(threadId: String, messageId: String, state: CodexMessage.Delivery, turnId: String) {}
    func startTurn(userInput: String, threadId: String, shouldAppendUserMessage: Bool, preAppendedUserMessageID: String, onTurnStartDispatch: (@MainActor () -> Void)? = nil) async throws {
        precondition(!shouldAppendUserMessage)
        precondition(findMessageIndex(threadId: threadId, messageId: preAppendedUserMessageID) != nil)
        try beforeDispatch()
        onTurnStartDispatch?()
        starts += 1
        try await onSend()
    }
    func syncActiveThreadState(threadId: String) async {}
    func fetchLegacyThreadHistoryObject(threadId: String) async throws -> RPCObject { ["turns": .array([])] }
    func decodeMessagesFromThreadRead(threadId: String, threadObject: RPCObject) -> [CodexMessage] { [] }
    func turnStateSnapshot(from turns: [RPCObject], newestFirst: Bool) -> (interruptibleTurnID: String?, hasInterruptibleTurnWithoutID: Bool) {
        let active = turns.last { $0["status"]?.stringValue == "inProgress" }
        return (active?["id"]?.stringValue, active != nil && active?["id"]?.stringValue == nil)
    }
}

@main struct AsyncUserInputHarness {
    @MainActor static func main() async {
        let question = CodexMessage(id: "question", threadId: "thread", role: .assistant, text: "",
            itemId: "item_question", asyncUserInput: .init(questions: [.init(title: "Works?", options: ["Yes", "No"])]))
        func makeService() -> CodexService {
            let service = CodexService()
            service.messagesByThread["thread"] = [question]
            return service
        }
        func input(_ service: CodexService) -> CodexAsyncUserInput {
            service.messagesByThread["thread"]![0].asyncUserInput!
        }
        func submit(_ service: CodexService) async {
            await service.submitAsyncUserInput(threadId: "thread", messageID: "question", answers: [" Yes "])
        }

        for disconnected in [true, false] {
            let service = makeService()
            service.isConnected = !disconnected
            service.isInitialized = disconnected
            await submit(service)
            precondition(input(service).status == .unanswered)
            precondition(input(service).answers == ["Yes"])
            precondition(service.messagesByThread["thread"]!.count == 1)
            precondition(service.sends == 0 && service.starts == 0)
        }

        let beforeDelivery = makeService()
        beforeDelivery.resolve = { throw CodexServiceError.disconnected }
        await submit(beforeDelivery)
        precondition(input(beforeDelivery).status == .unanswered)
        precondition(input(beforeDelivery).responseMessageID == nil)
        precondition(input(beforeDelivery).answers == ["Yes"])
        precondition(beforeDelivery.messagesByThread["thread"]!.count == 1)
        precondition(beforeDelivery.sends == 0)
        beforeDelivery.resolve = { "turn_1" }
        await submit(beforeDelivery)
        precondition(input(beforeDelivery).status == .answered)
        precondition(beforeDelivery.sends == 1)

        let disconnectedWhileResolving = makeService()
        disconnectedWhileResolving.resolve = {
            disconnectedWhileResolving.isConnected = false
            return "turn_1"
        }
        await submit(disconnectedWhileResolving)
        precondition(input(disconnectedWhileResolving).status == .unanswered)
        precondition(disconnectedWhileResolving.sends == 0)

        let failedBeforeDispatch = makeService()
        failedBeforeDispatch.beforeDispatch = { throw CodexServiceError.encodingFailed }
        await submit(failedBeforeDispatch)
        precondition(input(failedBeforeDispatch).status == .unanswered)
        precondition(failedBeforeDispatch.sends == 0)

        let ambiguous = makeService()
        ambiguous.onSend = { throw CodexServiceError.disconnected }
        await submit(ambiguous)
        precondition(input(ambiguous).status == .uncertain)
        precondition(ambiguous.sends == 1)
        precondition(ambiguous.messagesByThread["thread"]!.count == 2)
        await submit(ambiguous)
        precondition(ambiguous.sends == 1, "An ambiguous reply must not be resent without verification")

        // A partial history without the question is not evidence of non-delivery.
        var messages = ambiguous.messagesByThread["thread"]!
        precondition(!CodexAsyncUserInputProjection.hasMissingAnswerCandidate(in: messages, canonical: []))
        let now = input(ambiguous).responseRecordedAt!.addingTimeInterval(20)
        _ = CodexAsyncUserInputProjection.reopenRepliesMissingFromCanonicalHistory(&messages, canonical: [], now: now)
        precondition(messages[0].asyncUserInput?.status == .uncertain)

        precondition(CodexAsyncUserInputProjection.hasMissingAnswerCandidate(in: messages, canonical: [question]))
        _ = CodexAsyncUserInputProjection.reopenRepliesMissingFromCanonicalHistory(&messages, canonical: [question], now: now)
        precondition(messages[0].asyncUserInput?.status == .uncertain, "One snapshot must not enable a duplicate send")
        _ = CodexAsyncUserInputProjection.reopenRepliesMissingFromCanonicalHistory(&messages, canonical: [question], now: now.addingTimeInterval(1))
        precondition(messages[0].asyncUserInput?.status == .uncertain, "The second read must be separated in time")
        _ = CodexAsyncUserInputProjection.reopenRepliesMissingFromCanonicalHistory(&messages, canonical: [question], now: now.addingTimeInterval(3))
        precondition(messages.count == 1)
        precondition(messages[0].asyncUserInput?.status == .unanswered)
        precondition(messages[0].asyncUserInput?.answers == ["Yes"])
        ambiguous.messagesByThread["thread"] = messages
        ambiguous.onSend = {}
        await submit(ambiguous)
        precondition(input(ambiguous).status == .answered)
        precondition(ambiguous.sends == 2)

        let accepted = makeService()
        accepted.onSend = { throw CodexServiceError.disconnected }
        await submit(accepted)
        var canonical = [question, CodexMessage(id: "server_answer", threadId: "thread", role: .user, text: "Works?\nYes")]
        CodexAsyncUserInputProjection.reconcile(&canonical)
        var local = accepted.messagesByThread["thread"]!
        _ = CodexAsyncUserInputProjection.reopenRepliesMissingFromCanonicalHistory(&local, canonical: canonical, now: now)
        precondition(local[0].asyncUserInput?.status == .answered)
        precondition(local.count == 2, "Confirmed history must retain the reply")

        let confirmationRace = makeService()
        confirmationRace.onSend = {
            confirmationRace.messagesByThread["thread"]![0].asyncUserInput!.status = .answered
            throw CodexServiceError.disconnected
        }
        await submit(confirmationRace)
        precondition(input(confirmationRace).status == .answered)

        let inactive = makeService()
        inactive.active = false
        await submit(inactive)
        precondition(inactive.starts == 1 && inactive.sends == 0)
        precondition(input(inactive).status == .answered)
        precondition(!inactive.canVerifyAsyncAnswerAbsence(threadId: "thread", threadObject: [:]))
        precondition(!inactive.canVerifyAsyncAnswerAbsence(threadId: "thread", threadObject: ["turns": .array([
            .object(["id": .string("turn_1"), "status": .string("inProgress")]),
        ])]))
        precondition(!inactive.canVerifyAsyncAnswerAbsence(threadId: "thread", threadObject: ["turns": .array([
            .object(["status": .string("inProgress")]),
        ])]))
        precondition(inactive.canVerifyAsyncAnswerAbsence(threadId: "thread", threadObject: ["turns": .array([
            .object(["id": .string("turn_1"), "status": .string("completed")]),
        ])]))
        print("async answer recovery checks passed")
    }
}
