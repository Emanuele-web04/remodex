// Compile the actual recovery service against controllable transport/lifecycle seams.
import Foundation

typealias RPCObject = [String: JSONValue]
enum CodexServiceError: Error { case invalidInput(String), disconnected }
enum CodexTurnTerminalState { case completed, failed, stopped }
enum CodexMessageKind: String { case fileChange }
enum DeliveryState { case failed, confirmed }
struct RPCMessage { var result: JSONValue? = .object(["turnId": .string("continued-turn")]) }

@MainActor final class TurnViewModel {
    var isSending = false
    var input = "Unsent draft"
}
@MainActor final class SubscriptionService {
    var hasAppAccess = true
    var consumed = 0
    func consumeFreeSendAttemptIfNeeded() { consumed += 1 }
}

@MainActor final class CodexService {
    var isConnected = true
    var isInitialized = true
    var supportsRuntimeSettingsSync = true
    var isApplyingReplayedBridgeEvent = false
    var recoverableStreamFailuresByThread: [String: CodexStreamFailure] = [:]
    var streamFailureContinuationsInFlight: Set<UUID> = []
    var streamRecoveryConnectionGeneration = 0
    var runStartGenerationByThread = ["thread": 1]
    var lastRunStartTurnIDByThread = ["thread": "failed-turn"]
    var lastErrorMessage: String?
    var active: String?
    var running = false
    var terminal: CodexTurnTerminalState = .failed
    var snapshot: (interruptibleTurnID: String?, hasInterruptibleTurnWithoutID: Bool, latestTurnID: String?, latestTurnStatus: String?) = (nil, false, "failed-turn", "failed")
    var beforeResume: (() -> Void)?
    var beforeSettings: (() -> Void)?
    var beforeSnapshot: (() -> Void)?
    var beforeCheckpoint: (() -> Void)?
    var beforeResponse: (() -> Void)?
    var failSend = false
    var delaySnapshot = false
    var snapshotGate: CheckedContinuation<Void, Never>?
    var requests: [RPCObject] = []
    var messages: [String] = []
    var refreshes = 0
    var reconciles = 0
    var failureCleanups = 0

    static func isSyntheticPlaceholderTurnID(_ id: String) -> Bool { CodexSyntheticIdentifiers.isBridgeMintedTurnID(id) }
    func normalizedInterruptIdentifier(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var responseTerminal: CodexTurnTerminalState?
    func turnTerminalState(for id: String?, threadId: String) -> CodexTurnTerminalState? { id == "continued-turn" ? responseTerminal : terminal }
    func latestTurnTerminalState(for id: String) -> CodexTurnTerminalState? { terminal }
    func activeTurnID(for id: String) -> String? { active }
    func threadHasActiveOrRunningTurn(_ id: String) -> Bool { running || active != nil }
    func ensureThreadResumed(threadId: String) async throws { beforeResume?() }
    func waitForRuntimeSettingsUpdate(threadId: String) async throws { beforeSettings?() }
    func readThreadTurnStateSnapshot(threadId: String) async throws -> (interruptibleTurnID: String?, hasInterruptibleTurnWithoutID: Bool, latestTurnID: String?, latestTurnStatus: String?) {
        if delaySnapshot { await withCheckedContinuation { snapshotGate = $0 } }
        beforeSnapshot?()
        return snapshot
    }
    func requestImmediateSync(threadId: String) { refreshes += 1 }
    func requestThreadHistoryReconcile(threadId: String) { reconciles += 1 }
    func userFacingTurnErrorMessageForFooter(from error: Error) -> String? { "Could not continue" }
    func appendUserMessage(threadId: String, text: String) -> String { messages.append(text); return "message" }
    func scheduleMessageStartWorkspaceCheckpointIfPossible(threadId: String, messageId: String) -> Task<Void, Never>? {
        Task { @MainActor in beforeCheckpoint?() }
    }
    func markMessageDeliveryState(threadId: String, messageId: String, state: DeliveryState, turnId: String? = nil) {}
    func extractTurnID(from result: JSONValue?) -> String? { result?.objectValue?["turnId"]?.stringValue }
    func markThreadAsRunning(_ threadId: String) { running = true }
    func setProtectedRunningFallback(_ value: Bool, for threadId: String) {}
    func sendRequest(method: String, params: JSONValue) async throws -> RPCMessage {
        precondition(method == "turn/start")
        requests.append(params.objectValue!)
        beforeResponse?()
        if failSend { throw CodexServiceError.disconnected }
        return RPCMessage()
    }
    func handleSuccessfulTurnStartResponse(_ response: RPCMessage, pendingMessageId: String, threadId: String) -> String? {
        active = "continued-turn"
        return active
    }
    func scheduleMessageStartWorkspaceCheckpointCopyIfPossible(threadId: String, messageId: String, turnId: String) {}
    func handleTurnStartFailure(_ error: Error, pendingMessageId: String, threadId: String) throws {
        failureCleanups += 1
        running = false
        throw error
    }
}

@main struct StreamRecoveryHarness {
    static let error = "stream disconnected before completion: Service temporarily unavailable (request id: example)"
    static func fixture() -> (CodexService, CodexStreamFailure) {
        let service = CodexService()
        service.recordRecoverableStreamFailure(threadId: "thread", turnId: "failed-turn", message: error, errorInfo: nil)
        return (service, service.recoverableStreamFailure(for: "thread")!)
    }
    static func attempt(_ service: CodexService, _ failure: CodexStreamFailure) async {
        try? await service.continueAfterStreamFailure(threadId: "thread", failureID: failure.id)
    }
    static func main() async throws {
        let parser = CodexService()
        let turnPage: [RPCObject] = [
            ["id": .string("remodex-history-compacted-test")],
            ["id": .string("failed-turn"), "status": .string("failed")],
            ["id": .string("older"), "status": .string("completed")],
        ]
        for newestFirst in [true, false] {
            let parsed = parser.turnStateSnapshot(from: newestFirst ? turnPage : Array(turnPage.reversed()), newestFirst: newestFirst)
            precondition(parsed.latestTurnID == "failed-turn" && parsed.latestTurnStatus == "failed")
            precondition(parsed.interruptibleTurnID == nil && !parsed.hasInterruptibleTurnWithoutID)
        }
        let parallel = parser.turnStateSnapshot(from: [
            ["id": .string("failed-turn"), "status": .string("failed")],
            ["id": .string("parallel"), "status": .string("inProgress")],
        ], newestFirst: true, knownParallelTurnIDs: ["parallel"])
        precondition(parallel.interruptibleTurnID == "parallel" && parallel.latestTurnStatus == "failed")
        precondition(CodexStreamFailure.isRecoverable(message: error))
        for message in ["The paired device was temporarily unavailable", "Permission denied", "stream disconnected before completion: invalid API key", "stream disconnected before completion: quota exceeded"] {
            precondition(!CodexStreamFailure.isRecoverable(message: message))
        }
        for kind in ["unauthorized", "usageLimitExceeded", "contextWindowExceeded", "badRequest", "sandboxError"] {
            precondition(!CodexStreamFailure.isRecoverable(message: error, errorInfo: .string(kind)))
        }
        for status in [401, 403, 429] {
            precondition(!CodexStreamFailure.isRecoverable(message: error, errorInfo: .object([
                "responseStreamDisconnected": .object(["httpStatusCode": .integer(status)])
            ])))
        }
        for status in [408, 500, 502, 503, 504] {
            precondition(CodexStreamFailure.isRecoverable(message: "upstream failed", errorInfo: .object([
                "responseStreamDisconnected": .object(["httpStatusCode": .integer(status)])
            ])))
        }
        precondition(CodexStreamFailure.isRecoverable(message: "disconnected", errorInfo: .object([
            "responseStreamDisconnected": .object(["httpStatusCode": .null])
        ])))

        let (success, failure) = fixture()
        await attempt(success, failure)
        await attempt(success, failure)
        precondition(success.requests.count == 1)
        precondition(success.messages == [CodexStreamFailure.continuationPrompt])
        precondition(success.requests[0]["threadId"] == .string("thread"))
        precondition(Set(success.requests[0].keys) == ["threadId", "input", "remodexRuntimeSettingsVersion"], "Owner settings must be inherited")
        let (legacy, legacyFailure) = fixture()
        legacy.supportsRuntimeSettingsSync = false
        await attempt(legacy, legacyFailure)
        precondition(legacy.requests.first?["remodexRuntimeSettingsVersion"] == nil)

        let (duplicate, original) = fixture()
        duplicate.dismissStreamFailure(threadId: "thread")
        duplicate.recordRecoverableStreamFailure(threadId: "thread", turnId: "failed-turn", message: error, errorInfo: nil)
        precondition(duplicate.recoverableStreamFailuresByThread["thread"]?.id == original.id)
        precondition(duplicate.recoverableStreamFailure(for: "thread") == nil)
        precondition(duplicate.reconcileRepeatedStreamFailure(threadId: "thread", turnId: "failed-turn"))
        precondition(duplicate.reconciles == 1 && duplicate.refreshes == 1)
        duplicate.streamFailureContinuationsInFlight.insert(original.id)
        precondition(duplicate.reconcileRepeatedStreamFailure(threadId: "thread", turnId: "failed-turn"))
        precondition(duplicate.reconciles == 2 && duplicate.refreshes == 1)

        for snapshot: (String?, Bool, String?, String?) in [("busy", false, "failed-turn", "failed"), (nil, true, "failed-turn", "failed"), (nil, false, "newer-turn", "failed"), (nil, false, nil, nil), (nil, false, "failed-turn", "completed"), (nil, false, "failed-turn", "interrupted")] {
            let (service, failure) = fixture()
            service.snapshot = snapshot
            await attempt(service, failure)
            precondition(service.requests.isEmpty && service.refreshes == 1)
        }
        for phase in ["resume", "settings", "snapshot", "checkpoint"] {
            for change in ["new-turn", "stop", "reconnect", "mac-switch"] {
                let (service, failure) = fixture()
                let mutate = {
                    switch change {
                    case "new-turn": service.runStartGenerationByThread["thread"] = 2; service.active = "newer-turn"
                    case "stop": service.dismissStreamFailure(threadId: "thread")
                    case "reconnect": service.streamRecoveryConnectionGeneration += 1
                    default: service.recoverableStreamFailuresByThread.removeAll()
                    }
                }
                switch phase {
                case "resume": service.beforeResume = mutate
                case "settings": service.beforeSettings = mutate
                case "snapshot": service.beforeSnapshot = mutate
                default: service.beforeCheckpoint = mutate
                }
                await attempt(service, failure)
                precondition(service.requests.isEmpty, "Must cancel after \(change) during \(phase)")
            }
        }

        let (doubleTap, doubleFailure) = fixture()
        doubleTap.delaySnapshot = true
        let first = Task { await attempt(doubleTap, doubleFailure) }
        while doubleTap.snapshotGate == nil { await Task.yield() }
        await attempt(doubleTap, doubleFailure)
        doubleTap.snapshotGate?.resume()
        await first.value
        precondition(doubleTap.requests.count == 1)

        let (ambiguous, failedSend) = fixture()
        ambiguous.failSend = true
        await attempt(ambiguous, failedSend)
        ambiguous.recordRecoverableStreamFailure(threadId: "thread", turnId: "failed-turn", message: error, errorInfo: nil)
        await attempt(ambiguous, failedSend)
        precondition(ambiguous.requests.count == 1, "Ambiguous sends must not be replayed")

        let (newer, newerFailure) = fixture()
        newer.failSend = true
        newer.beforeResponse = { newer.runStartGenerationByThread["thread"] = 2; newer.active = "newer" }
        await attempt(newer, newerFailure)
        precondition(newer.failureCleanups == 0 && newer.active == "newer")

        let (lateAck, lateFailure) = fixture()
        lateAck.beforeResponse = { lateAck.runStartGenerationByThread["thread"] = 2; lateAck.active = "newer" }
        await attempt(lateAck, lateFailure)
        precondition(lateAck.active == "newer", "A late acknowledgement must not replace the newer run")
        let (finished, finishedFailure) = fixture()
        finished.beforeResponse = { finished.responseTerminal = .completed; finished.running = false }
        await attempt(finished, finishedFailure)
        precondition(finished.active == nil && !finished.running, "A late acknowledgement must not revive a completed run")

        let (composed, composedFailure) = fixture()
        let viewModel = TurnViewModel()
        let subscription = SubscriptionService()
        viewModel.continueAfterStreamFailure(composedFailure, codex: composed, subscriptions: subscription, threadID: "thread")
        viewModel.continueAfterStreamFailure(composedFailure, codex: composed, subscriptions: subscription, threadID: "thread")
        while viewModel.isSending { await Task.yield() }
        precondition(composed.requests.count == 1 && subscription.consumed == 1)
        precondition(viewModel.input == "Unsent draft")

        let (changed, changedFailure) = fixture()
        let changedViewModel = TurnViewModel()
        let failedPreflightSubscription = SubscriptionService()
        changed.beforeSnapshot = {
            changed.recoverableStreamFailuresByThread["thread"] = CodexStreamFailure(
                turnID: "different-failure", message: "new error", runGeneration: 2)
            changed.lastErrorMessage = "new error"
        }
        changedViewModel.continueAfterStreamFailure(changedFailure, codex: changed, subscriptions: failedPreflightSubscription, threadID: "thread")
        while changedViewModel.isSending { await Task.yield() }
        precondition(changed.requests.isEmpty && changed.lastErrorMessage == "new error")
        precondition(changed.recoverableStreamFailuresByThread["thread"]?.isDismissed == false)
        precondition(failedPreflightSubscription.consumed == 0, "A failed preflight must not consume a free message")

        for condition in ["stopped", "replay", "old-turn", "synthetic"] {
            let service = CodexService()
            if condition == "stopped" { service.terminal = .stopped }
            if condition == "replay" { service.isApplyingReplayedBridgeEvent = true }
            if condition == "old-turn" { service.lastRunStartTurnIDByThread["thread"] = "newer" }
            let turnID = condition == "synthetic" ? "rollout-synthetic" : "failed-turn"
            if condition == "synthetic" { service.lastRunStartTurnIDByThread["thread"] = turnID }
            service.recordRecoverableStreamFailure(threadId: "thread", turnId: turnID, message: error, errorInfo: nil)
            precondition(service.recoverableStreamFailuresByThread.isEmpty)
        }
        print("stream recovery checks passed")
    }
}
