// Exercises the production synchronization extension with a controllable RPC transport.
import Foundation

enum CodexServiceError: Error {
    case invalidInput(String)
    case disconnected
}

@MainActor final class CodexService {
    var supportsRuntimeSettingsSync = true
    var isConnected = true
    var isInitialized = true
    var threadRuntimeOverridesByThreadID: [String: CodexThreadRuntimeOverride] = [:]
    var runtimeSettingsUpdateErrors: [String: String] = [:]
    var runtimeSettingsUpdateTasks: [String: Task<Void, Never>] = [:]
    var runtimeSettingsUpdateIDs: [String: UUID] = [:]
    var confirmedRuntimeSettings: [String: CodexRuntimeSettings] = [:]
    var retiredRuntimeSettingsEpochs: [String: Set<String>] = [:]
    var lastErrorMessage: String?
    let globalModel = "device-default"
    let globalEffort = "medium"
    let globalTier = CodexServiceTier.fast
    var requests: [RPCObject] = []
    var resumedThreadIDs: Set<String> = []
    var resumeGate: CheckedContinuation<Void, Error>?
    var delayResume = false

    func ensureThreadResumed(threadId: String) async throws {
        if resumedThreadIDs.contains(threadId) { return }
        if delayResume { try await withCheckedThrowingContinuation { resumeGate = $0 } }
        resumedThreadIDs.insert(threadId)
    }
    var responses: [CheckedContinuation<RPCMessage, Error>] = []

    func threadRuntimeOverride(for id: String) -> CodexThreadRuntimeOverride? { threadRuntimeOverridesByThreadID[id] }
    func applyThreadRuntimeOverride(_ value: CodexThreadRuntimeOverride, to id: String) { threadRuntimeOverridesByThreadID[id] = value }
    func runtimeModelIdentifierForTurn(threadId: String) -> String? { threadRuntimeOverride(for: threadId)?.modelId ?? globalModel }
    func selectedReasoningEffortForSelectedModel(threadId: String) -> String? { threadRuntimeOverride(for: threadId)?.reasoningEffort ?? globalEffort }
    func effectiveServiceTier(for id: String) -> CodexServiceTier? { threadRuntimeOverride(for: id)?.serviceTier }
    func decodeModel<T: Decodable>(_ type: T.Type, from value: JSONValue) -> T? { try? JSONDecoder().decode(type, from: JSONEncoder().encode(value)) }
    func sendRequest(method: String, params: JSONValue) async throws -> RPCMessage {
        precondition(method == "thread/settings/update")
        requests.append(params.objectValue!)
        return try await withCheckedThrowingContinuation { responses.append($0) }
    }
    func acknowledge(_ index: Int, _ settings: CodexRuntimeSettings) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(settings))
        responses[index].resume(returning: RPCMessage(id: nil, result: .object(["runtimeSettings": value])))
    }
}

@main struct RuntimeSettingsHarness {
    @MainActor static func settings(_ revision: Int, model: String = "astra", effort: String? = "high", tier: String? = nil, epoch: String = "epoch-a") -> CodexRuntimeSettings {
        CodexRuntimeSettings(model: model, reasoningEffort: effort, serviceTier: tier, revision: revision, updatedAt: Double(revision) + (epoch == "epoch-b" ? 100 : 0), epoch: epoch, source: "runtime")
    }
    @MainActor static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Timed out waiting for the settings queue")
    }
    @MainActor static func main() async throws {
        let service = CodexService()
        let id = "task"
        service.delayResume = true
        service.applyConfirmedRuntimeSettings(settings(5, effort: "medium", tier: "priority"), threadId: id)
        service.threadRuntimeOverridesByThreadID[id]!.serviceTierRawValue = nil
        service.queueThreadRuntimeSettingsUpdate(threadId: id, fields: ["serviceTier"])
        try await until { service.resumeGate != nil || !service.requests.isEmpty }
        precondition(service.requests.isEmpty, "Settings must wait for the resumed task and owner discovery")
        service.resumeGate!.resume()
        service.resumeGate = nil
        service.delayResume = false
        try await until { service.responses.count == 1 }
        precondition(service.requests[0] == ["threadId": .string(id), "serviceTier": .null])
        service.threadRuntimeOverridesByThreadID[id]!.reasoningEffort = "high"
        service.queueThreadRuntimeSettingsUpdate(threadId: id, fields: ["effort"])
        service.applyConfirmedRuntimeSettings(settings(6, model: "sol", effort: "low", tier: "priority"), threadId: id)
        precondition(service.threadRuntimeOverride(for: id)?.reasoningEffort == "high")
        try service.acknowledge(0, settings(7, model: "sol", effort: "low"))
        try await until { service.responses.count == 2 }
        precondition(service.requests[1] == ["threadId": .string(id), "effort": .string("high")])
        try service.acknowledge(1, settings(8, model: "sol"))
        try await service.waitForRuntimeSettingsUpdate(threadId: id)
        precondition(service.threadRuntimeOverride(for: id)?.modelId == "sol")
        precondition(service.threadRuntimeOverride(for: id)?.serviceTier == nil)
        precondition(service.threadRuntimeOverride(for: id)?.pendingRuntimeSettings.isEmpty == true)

        // An older acknowledgement must not overwrite a newer Desktop edit.
        service.threadRuntimeOverridesByThreadID[id]!.reasoningEffort = "ultra"
        service.queueThreadRuntimeSettingsUpdate(threadId: id, fields: ["effort"])
        try await until { service.responses.count == 3 }
        service.applyConfirmedRuntimeSettings(settings(11, model: "desktop", effort: nil), threadId: id)
        try service.acknowledge(2, settings(10, effort: "ultra"))
        try await service.waitForRuntimeSettingsUpdate(threadId: id)
        precondition(service.threadRuntimeOverride(for: id)?.modelId == "desktop")
        precondition(service.threadRuntimeOverride(for: id)?.reasoningEffort == nil)

        // Rejected updates retain the desired choice and block a dependent turn.
        service.queueThreadRuntimeSettingsUpdate(threadId: id, fields: ["serviceTier"])
        try await until { service.responses.count == 4 }
        service.responses[3].resume(throwing: CodexServiceError.invalidInput("rejected"))
        try await until { service.runtimeSettingsUpdateTasks[id] == nil }
        precondition(service.runtimeSettingsUpdateErrors[id] != nil)
        precondition(service.threadRuntimeOverride(for: id)?.pendingRuntimeSettings.isEmpty == false)
        let retry = Task { @MainActor in try await service.waitForRuntimeSettingsUpdate(threadId: id) }
        try await until { service.responses.count == 5 }
        service.responses[4].resume(throwing: CodexServiceError.invalidInput("rejected again"))
        do { try await retry.value; fatalError("Failed settings must block sending") } catch {}

        // Pending choices survive disk persistence and resume; stale connection replies cannot clear them.
        let persisted = try JSONEncoder().encode(service.threadRuntimeOverridesByThreadID)
        service.threadRuntimeOverridesByThreadID = try JSONDecoder().decode([String: CodexThreadRuntimeOverride].self, from: persisted)
        service.resumePendingRuntimeSettingsUpdates()
        try await until { service.responses.count == 6 }
        service.cancelRuntimeSettingsUpdates()
        service.isConnected = false
        service.isInitialized = false
        service.isConnected = true
        service.isInitialized = true
        service.supportsRuntimeSettingsSync = true
        service.resumePendingRuntimeSettingsUpdates()
        try await until { service.responses.count == 7 }
        try service.acknowledge(5, settings(12, model: "stale-connection"))
        await Task.yield()
        precondition(service.threadRuntimeOverride(for: id)?.pendingRuntimeSettings.isEmpty == false)
        try service.acknowledge(6, settings(1, model: "reconnected", epoch: "epoch-b"))
        try await service.waitForRuntimeSettingsUpdate(threadId: id)
        precondition(service.lastErrorMessage == nil)
        service.applyConfirmedRuntimeSettings(settings(99, model: "retired"), threadId: id)
        precondition(service.threadRuntimeOverride(for: id)?.modelId == "reconnected")
        precondition(service.globalModel == "device-default" && service.globalEffort == "medium" && service.globalTier == .fast)

        // Persisted epoch cursors still reject stale replay after a fresh app launch.
        let relaunched = CodexService()
        relaunched.threadRuntimeOverridesByThreadID = try JSONDecoder().decode(
            [String: CodexThreadRuntimeOverride].self, from: JSONEncoder().encode(service.threadRuntimeOverridesByThreadID))
        relaunched.applyConfirmedRuntimeSettings(settings(99, model: "stale-replay"), threadId: id)
        precondition(relaunched.threadRuntimeOverride(for: id)?.modelId == "reconnected")

        // Switching Macs clears confirmed cursors, so returning to the same task
        // on the previous Mac can accept that Mac's independent settings epoch.
        service.resetRuntimeSettingsSyncState()
        service.threadRuntimeOverridesByThreadID.removeAll()
        service.applyConfirmedRuntimeSettings(settings(5, model: "other-mac"), threadId: id)
        precondition(service.threadRuntimeOverride(for: id)?.modelId == "other-mac")

        // A failed older slider edit cannot strand a newer choice in the queue.
        let rapid = CodexService()
        rapid.applyConfirmedRuntimeSettings(settings(1), threadId: id)
        rapid.threadRuntimeOverridesByThreadID[id]!.reasoningEffort = "unsupported"
        rapid.queueThreadRuntimeSettingsUpdate(threadId: id, fields: ["effort"])
        try await until { rapid.responses.count == 1 }
        rapid.threadRuntimeOverridesByThreadID[id]!.reasoningEffort = "ultra"
        rapid.queueThreadRuntimeSettingsUpdate(threadId: id, fields: ["effort"])
        rapid.responses[0].resume(throwing: CodexServiceError.invalidInput("unsupported"))
        try await until { rapid.responses.count == 2 }
        precondition(rapid.requests[1]["effort"] == .string("ultra"))
        try rapid.acknowledge(1, settings(2, effort: "ultra"))
        try await rapid.waitForRuntimeSettingsUpdate(threadId: id)
        precondition(rapid.lastErrorMessage == nil)

        rapid.queueThreadRuntimeSettingsUpdate(threadId: id, fields: ["effort"])
        try await until { rapid.responses.count == 3 }
        rapid.responses[2].resume(throwing: CodexServiceError.invalidInput("rejected"))
        try await until { rapid.runtimeSettingsUpdateTasks[id] == nil }
        precondition(rapid.lastErrorMessage != nil)
        rapid.threadRuntimeOverridesByThreadID[id]!.reasoningEffort = "high"
        rapid.queueThreadRuntimeSettingsUpdate(threadId: id, fields: ["effort"])
        precondition(rapid.lastErrorMessage == nil, "A new edit dismisses its obsolete error")
        try await until { rapid.responses.count == 4 }
        let interruptedWait = Task { @MainActor in try await rapid.waitForRuntimeSettingsUpdate(threadId: id) }
        await Task.yield()
        rapid.cancelRuntimeSettingsUpdates()
        rapid.isConnected = false
        rapid.responses[3].resume(throwing: CodexServiceError.disconnected)
        do { try await interruptedWait.value; fatalError("Disconnect must not unblock a dependent turn") } catch {}
        precondition(rapid.threadRuntimeOverride(for: id)?.pendingRuntimeSettings.isEmpty == false)

        // Modern model catalogs do not need the deprecated additionalSpeedTiers field.
        struct Fixture: Decodable { let models: [CodexModelOption] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        precondition(fixture.models.count == 7)
        precondition(fixture.models.first!.supportsFastMode)
        precondition(fixture.models.first!.supportedReasoningEfforts.contains { $0.reasoningEffort == "ultra" })
        precondition(fixture.models.last!.serviceTiers.isEmpty)
        precondition(CodexServiceTier(rawValue: "fast") == CodexServiceTier(rawValue: "priority"))
        let futureTier = try JSONDecoder().decode(CodexServiceTier.self, from: Data(#"{"id":"future-speed","name":"Future speed","description":"Catalog supplied"}"#.utf8))
        precondition(futureTier.rawValue == "future-speed" && futureTier.displayName == "Future speed")
        print("Runtime settings: ordering, rejection, reconnect, persistence, epochs and catalog checks passed")
    }
}
