// Compiles the production queue action against a controllable transport and queue.
import Foundation

struct QueuedTurnDraft {
    let id: String
    var text: String { id }
    var attachments: [String] = []
    var skillMentions: [String] = []
    var mentionMentions: [String] = []
    var rawFileMentions: [String] = []
    var collaborationMode: String?
}
enum QueuePauseState { case paused(errorMessage: String) }
enum DeliveryState { case failed }

@MainActor final class TurnViewModel {
    var steeringDraftID: String?
    var isAwaitingAssistantResponse = false
    var paused = false
    var drafts = ["first", "selected", "last"].map { QueuedTurnDraft(id: $0) }

    func isThreadBusy(codex: CodexService, threadID: String) -> Bool { codex.isBusy }
    func queuedDrafts(codex: CodexService, threadID: String) -> [QueuedTurnDraft] { drafts }
    func removeQueuedDraft(id: String, codex: CodexService, threadID: String) { drafts.removeAll { $0.id == id } }
    func confirmedFileMentionPaths(from paths: [String]) -> [String] { paths }
    func refreshBusyStateIfNeeded(codex: CodexService, threadID: String, wasBusy: Bool) async -> Bool { wasBusy }
    func resolveSteerExpectedTurnID(codex: CodexService, threadID: String) async throws -> String? { "old-turn" }
    func setQueuePauseState(_ state: QueuePauseState, codex: CodexService, threadID: String) { paused = true }
}

@MainActor final class CodexService {
    var isConnected = true
    var isBusy = true
    var refreshedBusy: Bool?
    var error: Error?
    var includesMention = false
    var lastErrorMessage: String?
    var calls: [String] = []
    var rows: [String: String] = [:]

    func steerTurn(userInput: String, threadId: String, expectedTurnId: String?, attachments: [String], skillMentions: [String], mentionMentions: [String], fileMentions: [String], collaborationMode: String?, onDispatch: (@MainActor () -> Void)? = nil) async throws {
        calls.append("steer:\(userInput)")
        onDispatch?()
        if let error {
            rows["steered-row"] = includesMention ? userInput + " @plugin" : userInput
            handleSteerFailure(error, pendingMessageId: "steered-row", threadId: threadId)
            throw error
        }
    }
    func refreshInFlightTurnState(threadId: String) async -> Bool {
        calls.append("refresh")
        guard let refreshedBusy else { return false }
        isBusy = refreshedBusy
        return true
    }
    func startTurn(userInput: String, threadId: String, attachments: [String], skillMentions: [String], mentionMentions: [String], fileMentions: [String], collaborationMode: String?) async throws {
        calls.append("start:\(userInput)")
    }
    func markMessageDeliveryState(threadId: String, messageId: String, state: DeliveryState) {}
    func removeUserMessage(threadId: String, messageId: String) -> Bool { rows.removeValue(forKey: messageId) != nil }
    func removeLatestFailedUserMessage(threadId: String, matchingText: String, matchingAttachments: [String]) {
        if let match = rows.first(where: { $0.value == matchingText }) {
            rows.removeValue(forKey: match.key)
        }
    }
    func userFacingTurnErrorMessageForFooter(from error: Error) -> String? { error.localizedDescription }
}

@main struct DesktopSteerHarness {
    static func main() async throws {
        let ended = CodexServiceError.rpcError(RPCError(code: -32000, message: "The active run ended",
            data: .object(["errorCode": .string("desktop_steer_turn_ended")])))
        let unknown = CodexServiceError.rpcError(RPCError(code: -32000, message: "Delivery uncertain",
            data: .object(["errorCode": .string("desktop_steer_delivery_unknown")])))
        let scenarios: [(error: Error?, refreshedBusy: Bool?, calls: [String], sent: Bool, paused: Bool)] = [
            (ended, false, ["steer:selected", "refresh", "start:selected"], true, false),
            (ended, true, ["steer:selected", "refresh"], false, false),
            (ended, nil, ["steer:selected", "refresh"], false, false),
            (unknown, false, ["steer:selected"], false, true),
            (CodexServiceError.disconnected, false, ["steer:selected"], false, true),
            (nil, nil, ["steer:selected"], true, false),
        ]
        for (index, scenario) in scenarios.enumerated() {
            let viewModel = TurnViewModel()
            let service = CodexService()
            service.error = scenario.error
            service.includesMention = index < 3
            service.refreshedBusy = scenario.refreshedBusy
            viewModel.steerQueuedDraft(id: "selected", codex: service, threadID: "thread")
            while viewModel.steeringDraftID != nil { await Task.yield() }
            precondition(service.calls == scenario.calls, "Expected \(scenario.calls), got \(service.calls)")
            precondition(viewModel.drafts.map(\.id) == (scenario.sent ? ["first", "last"] : ["first", "selected", "last"]))
            precondition(viewModel.paused == scenario.paused)
            precondition(service.rows.isEmpty, "The rejected optimistic row must be removed by item ID")
        }
        print("desktop steer checks passed")
    }
}
