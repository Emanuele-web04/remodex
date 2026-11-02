// Compiles the production send orchestration against a controllable runtime.
import Foundation

enum CodexServiceError: Error {
    case invalidInput(String), missingThread, transient
}

enum RuntimeProvider { case codex, opencode }
struct CodexThread {
    let id: String
    var runtimeProvider: RuntimeProvider = .codex
    var updatedAt = Date()
    var syncState: SyncState = .live
    enum SyncState { case live, archivedLocal }
}
struct CodexImageAttachment: Equatable {}
struct CodexTurnSkillMention { var name: String?; var id: String }
struct CodexTurnMention { var name: String }
enum CodexCollaborationModeKind { case plan }
enum CodexMessageDeliveryState { case pending, failed, confirmed }
struct RuntimeAccessConfiguration {}

@MainActor final class CodexService {
    let original = "original"
    var activeThreadId: String? = "original"
    var activeTurnId: String?
    var activeTurnIdByThread: [String: String] = [:]
    var threadIdByTurnID: [String: String] = [:]
    var threads = [CodexThread(id: "original")]
    var requests: [(String, String)] = []
    var messages: [String: CodexMessageDeliveryState] = [:]
    var lastErrorMessage: String?
    var resumeError: CodexServiceError?
    var sendError: CodexServiceError?

    func resolveThreadID(_ id: String?) async throws -> String { id ?? original }
    func thread(for id: String) -> CodexThread? { threads.first { $0.id == id } }
    func threadIndex(for id: String) -> Int? { threads.firstIndex { $0.id == id } }
    func sortThreads(_ threads: [CodexThread]) -> [CodexThread] { threads }
    func runtimeAccessConfiguration() -> RuntimeAccessConfiguration { .init() }
    func setActiveTurnID(_ id: String?, for threadId: String) { activeTurnIdByThread[threadId] = id }
    func setProtectedRunningFallback(_ value: Bool, for id: String) {}
    func clearRunningState(for id: String) {}
    func markThreadAsRunning(_ id: String) {}
    func extractTurnID(from value: JSONValue?) -> String? { value?.objectValue?["turnId"]?.stringValue }
    func normalizedInterruptIdentifier(_ value: String?) -> String? { value }
    func shouldTreatAsThreadNotFound(_ error: Error) -> Bool {
        if case .missingThread = error as? CodexServiceError { return true }
        return false
    }
    func isMissingRolloutError(_ error: Error) -> Bool { false }
    func userFacingTurnErrorMessageForFooter(from error: Error) -> String? { nil }
    func shouldSuppressRuntimeErrorInChat(_ error: Error) -> Bool { true }
    func appendSystemMessage(threadId: String, text: String) {}
    func handleMissingThread(_ id: String) { threads[threadIndex(for: id)!].syncState = .archivedLocal }
    func hasRenderableStructuredMentions(skillMentions: [CodexTurnSkillMention], mentionMentions: [CodexTurnMention]) -> Bool { false }
    func collaborationModeForOutgoingTurn(threadId: String, requestedMode: CodexCollaborationModeKind?, preserveExisting: Bool) -> CodexCollaborationModeKind? { requestedMode }
    func preparePlanSessionForStart(threadId: String, collaborationMode: CodexCollaborationModeKind?, preserveExisting: Bool) {}
    func displayTextForOutgoingTurn(userInput: String, skillMentions: [CodexTurnSkillMention], mentionMentions: [CodexTurnMention]) -> String { userInput }
    func resolvedAutomaticThreadTitleSeed(override: String?, shouldEvaluate: Bool, userInput: String, attachments: [CodexImageAttachment], threadId: String) -> String? { nil }
    func appendUserMessage(threadId: String, text: String, attachments: [CodexImageAttachment] = [], fileMentions: [String] = [], skillMentions: [String] = [], pluginMentions: [String] = []) -> String {
        let id = "\(threadId):\(text)"
        messages[id] = .pending
        return id
    }
    func markMessageDeliveryState(threadId: String, messageId: String, state: CodexMessageDeliveryState, turnId: String? = nil) {
        if messages[messageId] != nil { messages[messageId] = state }
    }
    func ensureThreadResumed(threadId: String, force: Bool = false, accessConfigurationOverride: RuntimeAccessConfiguration? = nil) async throws {
        requests.append(("thread/resume", threadId))
        if let resumeError, threadId == original { throw resumeError }
    }
    func sendTurnStart(_ text: String, attachments: [CodexImageAttachment], skillMentions: [CodexTurnSkillMention], mentionMentions: [CodexTurnMention], fileMentions: [String], to threadId: String, shouldAppendUserMessage: Bool, collaborationMode: CodexCollaborationModeKind?, preAppendedUserMessageID: String? = nil, automaticTitleSeedOverride: String? = nil, onDispatch: (@MainActor () -> Void)?) async throws {
        let messageId = shouldAppendUserMessage
            ? appendUserMessage(threadId: threadId, text: text)
            : preAppendedUserMessageID ?? ""
        do {
            onDispatch?()
            _ = try await sendRequest(method: "turn/start", params: .object(["threadId": .string(threadId)]))
            markMessageDeliveryState(threadId: threadId, messageId: messageId, state: .confirmed)
        } catch {
            try handleTurnStartFailure(error, pendingMessageId: messageId, threadId: threadId)
        }
    }
    func sendRequest(method: String, params: JSONValue) async throws -> RPCMessage {
        let threadId = params.objectValue?["threadId"]?.stringValue ?? ""
        requests.append((method, threadId))
        if let sendError, threadId == original { throw sendError }
        return RPCMessage(id: nil, result: .object(["turnId": .string("turn")]))
    }
}

@main struct ThreadIdentityHarness {
    static func main() async throws {
        for isReview in [false, true] {
            for failsOnResume in [true, false] {
                let service = CodexService()
                if failsOnResume { service.resumeError = .missingThread } else { service.sendError = .missingThread }
                do {
                    if isReview {
                        try await service.startReview(threadId: service.original, target: .uncommittedChanges)
                    } else {
                        try await service.startTurn(userInput: "prompt", threadId: service.original)
                    }
                    preconditionFailure("Missing thread should fail without replacing the conversation")
                } catch CodexServiceError.invalidInput(let message) {
                    precondition(message.contains("Reopen it in Codex"))
                }
                let sendMethod = isReview ? "review/start" : "turn/start"
                precondition(service.requests.map(\.0) == (failsOnResume ? ["thread/resume"] : ["thread/resume", sendMethod]))
                precondition(service.requests.allSatisfy { $0.1 == service.original })
                precondition(service.activeThreadId == service.original)
                precondition(service.threads[0].syncState == .archivedLocal)
                let expectedMessages: [String: CodexMessageDeliveryState] = isReview && failsOnResume
                    ? [:] : [isReview ? "original:Review current changes" : "original:prompt": .failed]
                precondition(service.messages == expectedMessages)
            }
        }

        let service = CodexService()
        service.resumeError = .transient
        try await service.startTurn(userInput: "prompt", threadId: service.original)
        precondition(service.requests.map(\.0) == ["thread/resume", "turn/start"])
        precondition(service.requests.allSatisfy { $0.1 == service.original })
        precondition(service.messages == ["original:prompt": .confirmed])
        print("thread identity checks passed")
    }
}
