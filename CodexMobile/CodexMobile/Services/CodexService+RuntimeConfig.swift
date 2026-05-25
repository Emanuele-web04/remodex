// FILE: CodexService+RuntimeConfig.swift
// Purpose: Runtime model/reasoning/access preferences, per-thread overrides, and model/list loading.
// Layer: Service
// Exports: CodexService runtime config APIs
// Depends on: CodexModelOption, CodexReasoningEffortOption, CodexAccessMode

import Foundation

private let runtimeDebugTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

private enum RuntimeConfigLoadingPolicy {
    static let modelListTimeoutNanoseconds: UInt64 = 8_000_000_000
}

private enum RuntimeSelectionDefaults {
    static let modelId = "gpt-5.5"
    static let reasoningEffort = "medium"

    static func reasoningEffort(for unresolvedModelId: String?) -> String? {
        guard let unresolvedModelId,
              unresolvedModelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == modelId else {
            return nil
        }
        return reasoningEffort
    }
}

extension CodexService {
    func learnAgentRuntimesFromInitializeResponse(_ response: RPCMessage) {
        guard let object = response.result?.objectValue else {
            return
        }

        if let rawDefault = object["defaultAgentRuntime"]?.stringValue {
            defaultAgentRuntime = normalizedAgentRuntimeID(rawDefault)
        }

        let decoded = (object["agentRuntimes"]?.arrayValue ?? [])
            .compactMap(decodeAgentRuntimeDescriptor)
        guard !decoded.isEmpty else {
            agentRuntimeDescriptors = [.codex]
            selectedAgentRuntimeForNewThreads = normalizedAgentRuntimeID(defaultAgentRuntime)
            return
        }

        var byID: [String: AgentRuntimeDescriptor] = [:]
        byID["codex"] = .codex
        for descriptor in decoded {
            byID[descriptor.id] = descriptor
        }

        let orderedIDs = ["codex", "opencode", "cursor"]
        agentRuntimeDescriptors = orderedIDs.compactMap { byID[$0] }
        let normalizedDefault = normalizedAgentRuntimeID(defaultAgentRuntime)
        if agentRuntimeDescriptor(id: normalizedDefault)?.isReady == true {
            selectedAgentRuntimeForNewThreads = normalizedDefault
        } else {
            selectedAgentRuntimeForNewThreads = "codex"
        }
    }

    func agentRuntimeDescriptor(id rawID: String?) -> AgentRuntimeDescriptor? {
        let runtimeID = normalizedAgentRuntimeID(rawID ?? "codex")
        return agentRuntimeDescriptors.first { $0.id == runtimeID }
    }

    func effectiveAgentRuntimeID(for thread: CodexThread?) -> String {
        normalizedAgentRuntimeID(thread?.agentRuntime ?? selectedAgentRuntimeForNewThreads)
    }

    func effectiveAgentRuntimeCapabilities(for thread: CodexThread?) -> AgentRuntimeCapabilities {
        agentRuntimeDescriptor(id: effectiveAgentRuntimeID(for: thread))?.capabilities ?? .codex
    }

    func setSelectedAgentRuntimeForNewThreads(_ runtimeID: String) {
        let normalized = normalizedAgentRuntimeID(runtimeID)
        guard agentRuntimeDescriptor(id: normalized)?.isReady == true else {
            return
        }
        selectedAgentRuntimeForNewThreads = normalized
    }

    func agentRuntimeOptionsForComposer() -> [AgentRuntimeDescriptor] {
        agentRuntimeDescriptors.filter { descriptor in
            switch descriptor.id {
            case "codex":
                return true
            case "opencode", "cursor":
                return true
            default:
                return false
            }
        }
    }

    // Resolves the effective per-chat override record after normalizing the thread id.
    func threadRuntimeOverride(for threadId: String?) -> CodexThreadRuntimeOverride? {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return nil
        }
        return threadRuntimeOverridesByThreadID[normalizedThreadID]
    }

    // Sends one request while trying approvalPolicy enum variants for cross-version compatibility.
    func sendRequestWithApprovalPolicyFallback(
        method: String,
        baseParams: RPCObject,
        context: String
    ) async throws -> RPCMessage {
        let policies = selectedAccessMode.approvalPolicyCandidates
        var lastError: Error?

        for (index, policy) in policies.enumerated() {
            var params = baseParams
            params["approvalPolicy"] = .string(policy)

            do {
                return try await sendRequest(method: method, params: .object(params))
            } catch {
                lastError = error
                let hasMorePolicies = index < (policies.count - 1)
                if hasMorePolicies, shouldRetryWithApprovalPolicyFallback(error) {
                    debugRuntimeLog("\(method) \(context) fallback approvalPolicy=\(policy)")
                    continue
                }
                throw error
            }
        }

        throw lastError ?? CodexServiceError.invalidResponse("\(method) failed with unknown approvalPolicy error")
    }

    func listModels() async throws {
        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            let response = try await sendRequest(
                method: "model/list",
                params: .object([
                    "cursor": .null,
                    "limit": .integer(50),
                    "includeHidden": .bool(false),
                ]),
                timeoutNanoseconds: RuntimeConfigLoadingPolicy.modelListTimeoutNanoseconds,
                timeoutMessage: "model/list timed out while syncing runtime options."
            )

            guard let resultObject = response.result?.objectValue else {
                throw CodexServiceError.invalidResponse("model/list response missing payload")
            }

            let items =
                resultObject["items"]?.arrayValue
                ?? resultObject["data"]?.arrayValue
                ?? resultObject["models"]?.arrayValue
                ?? []

            let decodedModels = items.compactMap { decodeModel(CodexModelOption.self, from: $0) }
            availableModels = decodedModels
            modelsErrorMessage = nil
            normalizeRuntimeSelectionsAfterModelsUpdate()

            debugRuntimeLog("model/list success count=\(decodedModels.count)")
        } catch {
            handleModelListFailure(error)
            throw error
        }
    }

    func setSelectedModelId(_ modelId: String?) {
        setSelectedModelId(modelId, forAgentRuntime: effectiveAgentRuntimeID(for: nil))
    }

    func setSelectedModelId(_ modelId: String?, forAgentRuntime runtimeID: String) {
        let runtime = normalizedAgentRuntimeID(runtimeID)
        guard runtime != "codex" else {
            setSelectedCodexModelId(modelId)
            return
        }

        let normalized = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized?.isEmpty == false {
            selectedModelIdByAgentRuntime[runtime] = normalized
        } else {
            selectedModelIdByAgentRuntime.removeValue(forKey: runtime)
        }
        persistRuntimeSelections()
    }

    func setSelectedGitWriterModelId(_ modelId: String?) {
        let normalized = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedGitWriterModelId = (normalized?.isEmpty == false) ? normalized : nil
        normalizeRuntimeSelectionsAfterModelsUpdate()
    }

    func setSelectedReasoningEffort(_ effort: String?) {
        let normalized = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedReasoningEffort = (normalized?.isEmpty == false) ? normalized : nil
        normalizeRuntimeSelectionsAfterModelsUpdate()
    }

    func setThreadReasoningEffortOverride(_ effort: String, for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        let normalizedEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEffort.isEmpty else {
            clearThreadReasoningEffortOverride(for: normalizedThreadID)
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.reasoningEffort = normalizedEffort
            override.overridesReasoning = true
        }
    }

    func clearThreadReasoningEffortOverride(for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.reasoningEffort = nil
            override.overridesReasoning = false
        }
    }

    func setSelectedServiceTier(_ serviceTier: CodexServiceTier?) {
        selectedServiceTier = normalizedServiceTierForSelectedModel(serviceTier)
        persistRuntimeSelections()
    }

    func setThreadServiceTierOverride(_ serviceTier: CodexServiceTier?, for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        let normalizedServiceTier = normalizedServiceTierForSelectedModel(serviceTier)
        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.serviceTierRawValue = normalizedServiceTier?.rawValue
            override.overridesServiceTier = true
        }
    }

    func clearThreadServiceTierOverride(for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.serviceTierRawValue = nil
            override.overridesServiceTier = false
        }
    }

    func applyThreadRuntimeOverride(_ runtimeOverride: CodexThreadRuntimeOverride?, to threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        guard let runtimeOverride, !runtimeOverride.isEmpty else {
            threadRuntimeOverridesByThreadID.removeValue(forKey: normalizedThreadID)
            persistThreadRuntimeOverrides()
            return
        }

        threadRuntimeOverridesByThreadID[normalizedThreadID] = runtimeOverride
        persistThreadRuntimeOverrides()
    }

    func setSelectedAccessMode(_ accessMode: CodexAccessMode) {
        selectedAccessMode = accessMode
        persistRuntimeSelections()
    }

    func selectedModelOption() -> CodexModelOption? {
        selectedModelOption(for: nil)
    }

    func selectedModelOption(for thread: CodexThread?) -> CodexModelOption? {
        selectedModelOption(from: modelOptions(for: thread), agentRuntime: effectiveAgentRuntimeID(for: thread))
    }

    // Composer chrome should not present the canonical fallback as a loaded user choice.
    func visibleSelectedModelIDForComposer(thread: CodexThread? = nil) -> String? {
        if let selectedModel = selectedModelOption(for: thread) {
            return selectedModel.id
        }

        let runtime = effectiveAgentRuntimeID(for: thread)
        guard runtime == "codex" else {
            return nil
        }

        guard hasPersistedSelectedModelId else {
            return nil
        }

        if shouldHidePersistedDefaultWhileRuntimeLoads {
            return nil
        }

        return selectedModelId
    }

    // Keeps the model pill honest while bridge runtime metadata is still in flight.
    func isRuntimeSelectionLoadingForComposer(thread: CodexThread? = nil) -> Bool {
        guard visibleSelectedModelIDForComposer(thread: thread) == nil else {
            return false
        }
        return isBootstrappingConnectionSync || isLoadingThreads || isLoadingModels
    }

    func selectedGitWriterModelOption() -> CodexModelOption? {
        selectedGitWriterModelOption(from: availableModels)
    }

    func selectedModelSupportsServiceTier(_ serviceTier: CodexServiceTier) -> Bool {
        selectedModelOption()?.supportsServiceTier(serviceTier) == true
    }

    func gitWriterModelIdentifier() -> String? {
        selectedGitWriterModelOption()?.model
    }

    func supportedReasoningEffortsForSelectedModel() -> [CodexReasoningEffortOption] {
        selectedModelOption()?.supportedReasoningEfforts ?? []
    }

    func isThreadReasoningEffortOverridden(_ threadId: String?) -> Bool {
        guard let threadOverride = threadRuntimeOverride(for: threadId),
              threadOverride.overridesReasoning,
              let selectedReasoning = threadOverride.reasoningEffort else {
            return false
        }

        let supportedReasoningEfforts = Set(
            supportedReasoningEffortsForSelectedModel().map(\.reasoningEffort)
        )
        return supportedReasoningEfforts.contains(selectedReasoning)
    }

    func isThreadServiceTierOverridden(_ threadId: String?) -> Bool {
        threadRuntimeOverride(for: threadId)?.overridesServiceTier == true
    }

    func selectedReasoningEffortForSelectedModel(threadId: String? = nil) -> String? {
        guard let model = selectedModelOption() else {
            return RuntimeSelectionDefaults.reasoningEffort(for: selectedModelId)
                ?? selectedReasoningEffort
                ?? RuntimeSelectionDefaults.reasoningEffort
        }

        let supported = Set(model.supportedReasoningEfforts.map { $0.reasoningEffort })
        guard !supported.isEmpty else {
            return nil
        }

        if let threadOverride = threadRuntimeOverride(for: threadId),
           threadOverride.overridesReasoning,
           let selected = threadOverride.reasoningEffort,
           supported.contains(selected) {
            return selected
        }

        if let selected = selectedReasoningEffort,
           supported.contains(selected) {
            return selected
        }

        if let defaultEffort = model.defaultReasoningEffort,
           supported.contains(defaultEffort) {
            return defaultEffort
        }

        if supported.contains("medium") {
            return "medium"
        }

        return model.supportedReasoningEfforts.first?.reasoningEffort
    }

    func runtimeModelIdentifierForTurn(thread: CodexThread? = nil) -> String? {
        let runtime = effectiveAgentRuntimeID(for: thread)
        if runtime == "codex" {
            return selectedModelOption(for: thread)?.model ?? selectedModelId ?? RuntimeSelectionDefaults.modelId
        }
        return selectedModelOption(for: thread)?.model
            ?? selectedModelIdByAgentRuntime[runtime]
            ?? agentRuntimeDescriptor(id: runtime)?.modelCatalog?.defaultModelId
    }

    func effectiveServiceTier(for threadId: String? = nil) -> CodexServiceTier? {
        let candidate: CodexServiceTier?
        if let threadOverride = threadRuntimeOverride(for: threadId),
           threadOverride.overridesServiceTier {
            candidate = threadOverride.serviceTier
        } else {
            candidate = selectedServiceTier
        }

        guard let candidate else {
            return nil
        }
        return selectedModelSupportsServiceTier(candidate) ? candidate : nil
    }

    func runtimeServiceTierForTurn(threadId: String? = nil) -> String? {
        guard supportsServiceTier else {
            return nil
        }
        return effectiveServiceTier(for: threadId)?.rawValue
    }

    // Copies per-chat runtime overrides forward when we continue an archived thread.
    func inheritThreadRuntimeOverrides(from sourceThreadId: String?, to destinationThreadId: String?) {
        guard let normalizedSourceThreadID = normalizedInterruptIdentifier(sourceThreadId),
              let normalizedDestinationThreadID = normalizedInterruptIdentifier(destinationThreadId),
              normalizedSourceThreadID != normalizedDestinationThreadID else {
            return
        }

        guard let sourceOverride = threadRuntimeOverridesByThreadID[normalizedSourceThreadID] else {
            applyThreadRuntimeOverride(nil, to: normalizedDestinationThreadID)
            return
        }

        applyThreadRuntimeOverride(sourceOverride, to: normalizedDestinationThreadID)
    }

    func runtimeSandboxPolicyObject(for accessMode: CodexAccessMode) -> JSONValue {
        switch accessMode {
        case .onRequest:
            return .object([
                "type": .string("workspaceWrite"),
                "networkAccess": .bool(true),
            ])
        case .fullAccess:
            return .object([
                "type": .string("dangerFullAccess"),
            ])
        }
    }

    func shouldFallbackFromSandboxPolicy(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code != -32602 && rpcError.code != -32600 {
            return false
        }

        let loweredMessage = rpcError.message.lowercased()
        if loweredMessage.contains("thread not found") || loweredMessage.contains("unknown thread") {
            return false
        }

        return loweredMessage.contains("invalid params")
            || loweredMessage.contains("invalid param")
            || loweredMessage.contains("unknown field")
            || loweredMessage.contains("unexpected field")
            || loweredMessage.contains("unrecognized field")
            || loweredMessage.contains("failed to parse")
            || loweredMessage.contains("unsupported")
    }

    func sendRequestWithSandboxFallback(method: String, baseParams: RPCObject) async throws -> RPCMessage {
        var firstAttemptParams = baseParams
        firstAttemptParams["sandboxPolicy"] = runtimeSandboxPolicyObject(for: selectedAccessMode)

        do {
            debugRuntimeLog("\(method) using sandboxPolicy")
            return try await sendRequestWithApprovalPolicyFallback(
                method: method,
                baseParams: firstAttemptParams,
                context: "sandboxPolicy"
            )
        } catch {
            guard shouldFallbackFromSandboxPolicy(error) else {
                throw error
            }
        }

        var secondAttemptParams = baseParams
        secondAttemptParams["sandbox"] = .string(selectedAccessMode.sandboxLegacyValue)

        do {
            debugRuntimeLog("\(method) fallback using sandbox")
            return try await sendRequestWithApprovalPolicyFallback(
                method: method,
                baseParams: secondAttemptParams,
                context: "sandbox"
            )
        } catch {
            guard shouldFallbackFromSandboxPolicy(error) else {
                throw error
            }
        }

        let finalAttemptParams = baseParams
        debugRuntimeLog("\(method) fallback using minimal payload")
        return try await sendRequestWithApprovalPolicyFallback(
            method: method,
            baseParams: finalAttemptParams,
            context: "minimal"
        )
    }

    func handleModelListFailure(_ error: Error) {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.isEmpty ? "Unable to load models" : message
        modelsErrorMessage = normalized
        debugRuntimeLog("model/list failed: \(normalized)")
    }

    func debugRuntimeLog(_ message: String) {
        let entry = "[\(runtimeDebugTimestampFormatter.string(from: Date()))] \(message)"
        runtimeDebugLogEntries.append(entry)
        if runtimeDebugLogEntries.count > 400 {
            runtimeDebugLogEntries.removeFirst(runtimeDebugLogEntries.count - 400)
        }
#if DEBUG
        print("[CodexRuntime] \(entry)")
#endif
    }

    func clearRuntimeDebugLog() {
        runtimeDebugLogEntries.removeAll()
    }

    func shouldRetryWithApprovalPolicyFallback(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code != -32600 && rpcError.code != -32602 {
            return false
        }

        let message = rpcError.message.lowercased()
        return message.contains("approval")
            || message.contains("unknown variant")
            || message.contains("expected one of")
            || message.contains("onrequest")
            || message.contains("on-request")
    }

    func normalizedServiceTierForSelectedModel(_ serviceTier: CodexServiceTier?) -> CodexServiceTier? {
        guard let serviceTier else {
            return nil
        }
        guard let selectedModel = selectedModelOption() else {
            return serviceTier
        }
        return selectedModel.supportsServiceTier(serviceTier) ? serviceTier : nil
    }

    private func decodeAgentRuntimeDescriptor(_ value: JSONValue) -> AgentRuntimeDescriptor? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !id.isEmpty else {
            return nil
        }

        let capabilitiesObject = object["capabilities"]?.objectValue ?? [:]
        let capabilities = AgentRuntimeCapabilities(
            queue: capabilitiesObject["queue"]?.boolValue ?? false,
            steer: capabilitiesObject["steer"]?.boolValue ?? false,
            photos: capabilitiesObject["photos"]?.boolValue ?? false,
            planMode: capabilitiesObject["planMode"]?.boolValue ?? false,
            permissions: capabilitiesObject["permissions"]?.boolValue ?? false,
            desktopHandoff: capabilitiesObject["desktopHandoff"]?.boolValue ?? false,
            subagents: capabilitiesObject["subagents"]?.boolValue ?? false
        )

        return AgentRuntimeDescriptor(
            id: Self.normalizedStaticAgentRuntimeID(id),
            displayName: object["displayName"]?.stringValue ?? id,
            status: object["status"]?.stringValue ?? "not_installed",
            statusMessage: object["statusMessage"]?.stringValue,
            capabilities: capabilities,
            defaultBuildAgentName: object["defaultBuildAgentName"]?.stringValue,
            defaultPlanAgentName: object["defaultPlanAgentName"]?.stringValue,
            openCodeAgents: decodeOpenCodeAgents(object["openCodeAgents"]),
            openCodeSkills: decodeOpenCodeSkills(object["openCodeSkills"]),
            modelCatalog: decodeAgentRuntimeModelCatalog(object["modelCatalog"])
        )
    }

    private func decodeOpenCodeSkills(_ value: JSONValue?) -> [OpenCodeSkillOption]? {
        guard let entries = value?.arrayValue, !entries.isEmpty else {
            return nil
        }
        let skills = entries.compactMap { entry -> OpenCodeSkillOption? in
            guard let object = entry.objectValue else { return nil }
            let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id, !id.isEmpty else { return nil }
            return OpenCodeSkillOption(
                id: id,
                name: object["name"]?.stringValue ?? id,
                displayName: object["displayName"]?.stringValue ?? id,
                description: object["description"]?.stringValue
            )
        }
        return skills.isEmpty ? nil : skills
    }

    func openCodeSkillMetadata(for thread: CodexThread?) -> [CodexSkillMetadata] {
        guard effectiveAgentRuntimeID(for: thread) == "opencode" else {
            return []
        }
        let skills = agentRuntimeDescriptor(id: "opencode")?.openCodeSkills ?? []
        return skills.map { skill in
            CodexSkillMetadata(
                name: skill.name,
                description: skill.description,
                path: nil,
                scope: "opencode",
                enabled: true
            )
        }
    }

    private func decodeOpenCodeAgents(_ value: JSONValue?) -> [OpenCodeAgentOption]? {
        guard let entries = value?.arrayValue, !entries.isEmpty else {
            return nil
        }
        let agents = entries.compactMap { entry -> OpenCodeAgentOption? in
            guard let object = entry.objectValue,
                  let id = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                return nil
            }
            return OpenCodeAgentOption(
                id: id,
                displayName: object["displayName"]?.stringValue ?? id,
                isDefaultBuild: object["isDefaultBuild"]?.boolValue ?? false,
                isDefaultPlan: object["isDefaultPlan"]?.boolValue ?? false
            )
        }
        return agents.isEmpty ? nil : agents
    }

    func openCodeAgentOptions(for thread: CodexThread?) -> [OpenCodeAgentOption] {
        let descriptor = agentRuntimeDescriptor(id: effectiveAgentRuntimeID(for: thread))
        if let agents = descriptor?.openCodeAgents, !agents.isEmpty {
            return agents
        }
        let buildDefault = descriptor?.defaultBuildAgentName ?? "build"
        let planDefault = descriptor?.defaultPlanAgentName ?? "plan"
        return [
            OpenCodeAgentOption(id: buildDefault, displayName: buildDefault.capitalized, isDefaultBuild: true),
            OpenCodeAgentOption(id: planDefault, displayName: planDefault.capitalized, isDefaultPlan: true),
        ]
    }

    func effectiveOpenCodeBuildAgentName(for thread: CodexThread?) -> String {
        if let locked = thread?.opencodeBuildAgentName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !locked.isEmpty {
            return locked
        }
        let selected = selectedOpenCodeBuildAgentForNewThreads.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty {
            return selected
        }
        return agentRuntimeDescriptor(id: "opencode")?.defaultBuildAgentName ?? "build"
    }

    func setSelectedOpenCodeBuildAgentForNewThreads(_ agentName: String) {
        let normalized = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        selectedOpenCodeBuildAgentForNewThreads = normalized
    }

    func setOpenCodeBuildAgentName(_ agentName: String, for thread: CodexThread?) {
        let normalized = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if var mutableThread = thread {
            mutableThread.opencodeBuildAgentName = normalized
            upsertThread(mutableThread)
            return
        }
        setSelectedOpenCodeBuildAgentForNewThreads(normalized)
    }

    func effectiveOpenCodePlanAgentName(for thread: CodexThread?) -> String {
        if let locked = thread?.opencodePlanAgentName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !locked.isEmpty {
            return locked
        }
        let selected = selectedOpenCodePlanAgentForNewThreads.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty {
            return selected
        }
        return agentRuntimeDescriptor(id: "opencode")?.defaultPlanAgentName ?? "plan"
    }

    func setSelectedOpenCodePlanAgentForNewThreads(_ agentName: String) {
        let normalized = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        selectedOpenCodePlanAgentForNewThreads = normalized
    }

    func setOpenCodePlanAgentName(_ agentName: String, for thread: CodexThread?) {
        let normalized = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if var mutableThread = thread {
            mutableThread.opencodePlanAgentName = normalized
            upsertThread(mutableThread)
            return
        }
        setSelectedOpenCodePlanAgentForNewThreads(normalized)
    }

    func effectiveCursorMode(for thread: CodexThread?) -> String {
        let override = threadRuntimeOverride(for: thread?.id)?.cursorMode?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return normalizedCursorMode(override)
        }
        return normalizedCursorMode(selectedCursorModeForNewThreads)
    }

    func setSelectedCursorModeForNewThreads(_ mode: String) {
        selectedCursorModeForNewThreads = normalizedCursorMode(mode)
    }

    func setCursorMode(_ mode: String, for thread: CodexThread?) {
        let normalized = normalizedCursorMode(mode)
        guard let threadID = normalizedInterruptIdentifier(thread?.id) else {
            selectedCursorModeForNewThreads = normalized
            return
        }
        mutateThreadRuntimeOverride(for: threadID) { override in
            override.cursorMode = normalized
        }
    }

    private func normalizedCursorMode(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plan", "debug", "multitask", "ask":
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case "none", "agent", "":
            return "agent"
        default:
            return "agent"
        }
    }

    private func normalizedAgentRuntimeID(_ value: String) -> String {
        Self.normalizedStaticAgentRuntimeID(value)
    }

    func modelOptions(for thread: CodexThread?) -> [CodexModelOption] {
        let runtime = effectiveAgentRuntimeID(for: thread)
        guard runtime != "codex" else {
            return availableModels
        }
        return agentRuntimeDescriptor(id: runtime)?.modelCatalog?.models ?? []
    }

    func setSelectedRuntimeModelId(_ modelId: String?, for thread: CodexThread?) {
        setSelectedModelId(modelId, forAgentRuntime: effectiveAgentRuntimeID(for: thread))
    }

    func setSelectedRuntimeProviderId(_ providerId: String, for thread: CodexThread?) {
        let normalizedProviderID = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProviderID.isEmpty else { return }

        let models = modelOptions(for: thread).filter { model in
            model.providerID == normalizedProviderID
        }
        guard let selectedModel = models.first(where: { $0.isDefault }) ?? models.first else {
            return
        }
        setSelectedRuntimeModelId(selectedModel.id, for: thread)
    }

    private func setSelectedCodexModelId(_ modelId: String?) {
        let normalized = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized?.isEmpty == false {
            selectedModelId = normalized
        } else {
            selectedModelId = RuntimeSelectionDefaults.modelId
            selectedReasoningEffort = RuntimeSelectionDefaults.reasoningEffort
        }
        hasPersistedSelectedModelId = true
        normalizeRuntimeSelectionsAfterModelsUpdate()
    }

    private func decodeAgentRuntimeModelCatalog(_ value: JSONValue?) -> AgentRuntimeModelCatalog? {
        guard let object = value?.objectValue else {
            return nil
        }

        let models = (object["models"]?.arrayValue ?? [])
            .compactMap { decodeModel(CodexModelOption.self, from: $0) }
        let providers = (object["providers"]?.arrayValue ?? [])
            .compactMap(decodeAgentRuntimeModelProvider)
        return AgentRuntimeModelCatalog(
            defaultModelId: object["defaultModelId"]?.stringValue ?? object["default_model_id"]?.stringValue,
            defaultProviderId: object["defaultProviderId"]?.stringValue ?? object["default_provider_id"]?.stringValue,
            status: object["status"]?.stringValue,
            statusMessage: object["statusMessage"]?.stringValue ?? object["status_message"]?.stringValue,
            providers: providers,
            models: models
        )
    }

    private func decodeAgentRuntimeModelProvider(_ value: JSONValue) -> AgentRuntimeModelProvider? {
        guard let object = value.objectValue else { return nil }
        let rawID = object["id"]?.stringValue ?? object["providerID"]?.stringValue ?? object["provider_id"]?.stringValue
        guard let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return nil
        }

        let displayName = object["displayName"]?.stringValue
            ?? object["display_name"]?.stringValue
            ?? id
        let modelIds = (object["modelIds"]?.arrayValue
            ?? object["modelIDs"]?.arrayValue
            ?? object["model_ids"]?.arrayValue
            ?? [])
            .compactMap { value -> String? in
                let normalized = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return normalized.isEmpty ? nil : normalized
            }
        let isDefault = object["isDefault"]?.boolValue
            ?? object["is_default"]?.boolValue
            ?? false

        return AgentRuntimeModelProvider(
            id: id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            modelIds: modelIds,
            isDefault: isDefault
        )
    }

    private static func normalizedStaticAgentRuntimeID(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "opencode", "cursor":
            return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        default:
            return "codex"
        }
    }
}

private extension CodexService {
    var shouldHidePersistedDefaultWhileRuntimeLoads: Bool {
        guard availableModels.isEmpty else {
            return false
        }

        guard let selectedModelId else {
            return false
        }

        let normalizedSelection = selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedSelection == RuntimeSelectionDefaults.modelId
            && (isBootstrappingConnectionSync || isLoadingModels)
    }

    // Centralizes thread-override mutation so empty records never linger in storage.
    func mutateThreadRuntimeOverride(
        for threadId: String,
        mutate: (inout CodexThreadRuntimeOverride) -> Void
    ) {
        var currentOverride = threadRuntimeOverridesByThreadID[threadId] ?? CodexThreadRuntimeOverride(
            reasoningEffort: nil,
            serviceTierRawValue: nil,
            cursorMode: nil,
            overridesReasoning: false,
            overridesServiceTier: false
        )

        mutate(&currentOverride)

        if currentOverride.isEmpty {
            threadRuntimeOverridesByThreadID.removeValue(forKey: threadId)
        } else {
            threadRuntimeOverridesByThreadID[threadId] = currentOverride
        }

        persistThreadRuntimeOverrides()
    }

    func selectedModelOption(
        from models: [CodexModelOption],
        agentRuntime runtime: String = "codex"
    ) -> CodexModelOption? {
        guard !models.isEmpty else {
            return nil
        }

        let selected = normalizedAgentRuntimeID(runtime) == "codex"
            ? selectedModelId
            : selectedModelIdByAgentRuntime[normalizedAgentRuntimeID(runtime)]

        if let selected,
           let directMatch = models.first(where: { $0.id == selected || $0.model == selected }) {
            return directMatch
        }

        if let defaultModel = models.first(where: { $0.isDefault }) {
            return defaultModel
        }

        return nil
    }

    func selectedGitWriterModelOption(
        from models: [CodexModelOption],
        explicitModelId: String? = nil
    ) -> CodexModelOption? {
        guard !models.isEmpty else {
            return nil
        }

        let savedSelection = explicitModelId ?? selectedGitWriterModelId
        if let savedSelection,
           let directMatch = models.first(where: { $0.id == savedSelection || $0.model == savedSelection }) {
            return directMatch
        }

        if let miniModel = models.first(where: { $0.id == "gpt-5.4-mini" || $0.model == "gpt-5.4-mini" }) {
            return miniModel
        }

        if let runtimeSelected = selectedModelOption(from: models) {
            return runtimeSelected
        }

        return fallbackModel(from: models)
    }

    func fallbackModel(from models: [CodexModelOption]) -> CodexModelOption? {
        // Prefer GPT-5.5 when the bridge advertises it; the rest of the app treats
        // it as the canonical default regardless of the bridge's `isDefault` flag.
        if let preferred = models.first(where: {
            $0.id.lowercased() == "gpt-5.5" || $0.model.lowercased() == "gpt-5.5"
        }) {
            return preferred
        }
        if let defaultModel = models.first(where: { $0.isDefault }) {
            return defaultModel
        }
        return models.first
    }

    func persistRuntimeSelections() {
        if let selectedModelId, !selectedModelId.isEmpty, hasPersistedSelectedModelId {
            defaults.set(selectedModelId, forKey: Self.selectedModelIdDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedModelIdDefaultsKey)
        }

        if !selectedModelIdByAgentRuntime.isEmpty,
           let encodedRuntimeModels = try? encoder.encode(selectedModelIdByAgentRuntime) {
            defaults.set(encodedRuntimeModels, forKey: Self.selectedModelIdByAgentRuntimeDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedModelIdByAgentRuntimeDefaultsKey)
        }

        if let selectedGitWriterModelId, !selectedGitWriterModelId.isEmpty {
            defaults.set(selectedGitWriterModelId, forKey: Self.selectedGitWriterModelIdDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedGitWriterModelIdDefaultsKey)
        }

        if let selectedReasoningEffort, !selectedReasoningEffort.isEmpty {
            defaults.set(selectedReasoningEffort, forKey: Self.selectedReasoningEffortDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedReasoningEffortDefaultsKey)
        }

        if let selectedServiceTier {
            defaults.set(selectedServiceTier.rawValue, forKey: Self.selectedServiceTierDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedServiceTierDefaultsKey)
        }

        defaults.set(selectedAccessMode.rawValue, forKey: Self.selectedAccessModeDefaultsKey)
        persistThreadRuntimeOverrides()
    }

    func persistThreadRuntimeOverrides() {
        guard !threadRuntimeOverridesByThreadID.isEmpty,
              let encodedOverrides = try? encoder.encode(threadRuntimeOverridesByThreadID) else {
            defaults.removeObject(forKey: macScopedDefaultsKey(Self.threadRuntimeOverridesDefaultsKey))
            return
        }

        defaults.set(encodedOverrides, forKey: macScopedDefaultsKey(Self.threadRuntimeOverridesDefaultsKey))
    }
}

extension CodexService {
    func normalizeRuntimeSelectionsAfterModelsUpdate() {
        guard !availableModels.isEmpty else {
            if selectedModelId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                selectedModelId = nil
            }
            if selectedReasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                selectedReasoningEffort = nil
            }
            persistRuntimeSelections()
            return
        }

        let resolvedModel = selectedModelOption(from: availableModels) ?? fallbackModel(from: availableModels)
        selectedModelId = resolvedModel?.id
        hasPersistedSelectedModelId = resolvedModel != nil

        if let resolvedModel {
            let supported = Set(resolvedModel.supportedReasoningEfforts.map { $0.reasoningEffort })
            if supported.isEmpty {
                selectedReasoningEffort = nil
            } else if let selectedReasoningEffort,
                      supported.contains(selectedReasoningEffort) {
                // Keep current reasoning.
            } else if let modelDefault = resolvedModel.defaultReasoningEffort,
                      supported.contains(modelDefault) {
                selectedReasoningEffort = modelDefault
            } else if supported.contains("medium") {
                selectedReasoningEffort = "medium"
            } else {
                selectedReasoningEffort = resolvedModel.supportedReasoningEfforts.first?.reasoningEffort
            }

            if let selectedServiceTier,
               !resolvedModel.supportsServiceTier(selectedServiceTier) {
                self.selectedServiceTier = nil
            }
        } else {
            selectedReasoningEffort = nil
            selectedServiceTier = nil
        }

        if let selectedGitWriterModelId,
           !availableModels.contains(where: {
               $0.id == selectedGitWriterModelId || $0.model == selectedGitWriterModelId
           }) {
            self.selectedGitWriterModelId = nil
        }

        persistRuntimeSelections()
    }
}
