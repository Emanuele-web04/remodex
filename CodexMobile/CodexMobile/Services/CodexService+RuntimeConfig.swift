// FILE: CodexService+RuntimeConfig.swift
// Purpose: Runtime model/reasoning/access preferences, per-thread overrides, and model/list loading.
// Layer: Service
// Exports: CodexService runtime config APIs
// Depends on: CodexModelOption, CodexReasoningEffortOption, CodexAccessMode

import Foundation

enum CodexSandboxRequestShape: CaseIterable {
    case sandboxPolicy
    case sandbox
    case minimal
}

extension CodexService {
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
        let policies = orderedApprovalPolicyCandidates(for: selectedAccessMode)
        var lastError: Error?

        for (index, policy) in policies.enumerated() {
            var params = baseParams
            params["approvalPolicy"] = .string(policy)

            do {
                let response = try await sendRequest(method: method, params: .object(params))
                preferredApprovalPolicyByAccessMode[selectedAccessMode] = policy
                return response
            } catch {
                lastError = error
                let hasMorePolicies = index < (policies.count - 1)
                if hasMorePolicies, shouldRetryWithApprovalPolicyFallback(error) {
                    preferredApprovalPolicyByAccessMode.removeValue(forKey: selectedAccessMode)
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
                ])
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
        let normalized = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedModelId = (normalized?.isEmpty == false) ? normalized : nil
        hasExplicitModelSelection = selectedModelId != nil
        normalizeRuntimeSelectionsAfterModelsUpdate()
    }

    func refreshConfigProfiles(cwd: String? = nil) async {
        isLoadingConfigProfiles = true
        defer { isLoadingConfigProfiles = false }

        do {
            var params: RPCObject = [
                "includeLayers": .bool(false),
            ]
            if let normalizedCWD = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
               !normalizedCWD.isEmpty {
                params["cwd"] = .string(normalizedCWD)
            }

            let response = try await sendRequest(
                method: "config/read",
                params: .object(params)
            )

            guard let result = response.result,
                  let decodedConfig = decodeModel(CodexConfigReadPayload.self, from: result) else {
                throw CodexServiceError.invalidResponse("config/read response missing config")
            }

            availableConfigProfiles = decodedConfig.availableProfiles
            configProfilesErrorMessage = nil

            if let selectedConfigProfileName,
               !availableConfigProfiles.contains(where: { $0.id == selectedConfigProfileName }) {
                self.selectedConfigProfileName = nil
                persistRuntimeSelections()
            }
        } catch {
            availableConfigProfiles = []
            let normalized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            configProfilesErrorMessage = normalized.isEmpty ? "Unable to load profiles" : normalized
        }
    }

    func setSelectedConfigProfileName(_ profileName: String?) {
        let normalized = profileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedConfigProfileName = (normalized?.isEmpty == false) ? normalized : nil
        persistRuntimeSelections()
        scheduleDeferredModelListRefresh()
    }

    func setSelectedReasoningEffort(_ effort: String?) {
        let normalized = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedReasoningEffort = (normalized?.isEmpty == false) ? normalized : nil
        hasExplicitReasoningEffortSelection = selectedReasoningEffort != nil
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
        selectedServiceTier = serviceTier
        persistRuntimeSelections()
    }

    func setThreadServiceTierOverride(_ serviceTier: CodexServiceTier?, for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.serviceTierRawValue = serviceTier?.rawValue
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
        selectedModelOption(from: availableModels)
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
            return nil
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

        if selectedConfigProfileName != nil,
           !hasExplicitModelSelection,
           !hasExplicitReasoningEffortSelection {
            return nil
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

    // Maps Codex model IDs to GLM equivalents when using a GLM profile.
    // This allows the UI to display familiar OpenAI model names while sending
    // the appropriate GLM model ID to the backend.
    private static let glmModelMapping: [String: String] = [
        "gpt-5.4": "glm-5",
        "gpt-5.4-mini": "glm-4-plus",
        "gpt-5.3": "glm-5",
        "gpt-5.3-mini": "glm-4-plus",
        "gpt-5.2": "glm-5",
        "gpt-5.2-mini": "glm-4-plus",
        "gpt-5.1": "glm-5.1",
        "gpt-5.1-mini": "glm-4.7",
        "gpt-5": "glm-5",
        "gpt-5-mini": "glm-4-plus",
        "gpt-4.1": "glm-4.1",
        "gpt-4.1-mini": "glm-4.7",
        "gpt-4o": "glm-4",
        "gpt-4o-mini": "glm-4.7",
        "o4-mini": "glm-4.7",
        "o3-mini": "glm-4.7",
    ]

    // Returns true if the current profile is a GLM-based provider.
    private var isUsingGLMProfile: Bool {
        guard let profile = selectedConfigProfileName else { return false }
        return profile.lowercased().hasPrefix("glm") || profile.lowercased().hasPrefix("zai-glm")
    }

    // Translates a model ID to the GLM equivalent when using a GLM profile.
    private func mappedModelIdForGLM(_ modelId: String) -> String {
        guard isUsingGLMProfile else { return modelId }
        // Check for exact match first
        if let mapped = Self.glmModelMapping[modelId] {
            return mapped
        }
        // Try matching without version suffix (e.g., "gpt-5.4" matches "gpt-5.4-mini")
        let baseModelId = modelId.components(separatedBy: "-").first ?? modelId
        if let mapped = Self.glmModelMapping[baseModelId] {
            return mapped
        }
        // Default fallback to glm-5 for unknown GPT models
        if modelId.lowercased().hasPrefix("gpt") || modelId.lowercased().hasPrefix("o") {
            return "glm-5"
        }
        return modelId
    }

    func runtimeModelIdentifierForTurn() -> String? {
        if selectedConfigProfileName != nil, !hasExplicitModelSelection {
            return nil
        }
        let rawModelId = selectedModelOption()?.model
        guard let modelId = rawModelId else { return nil }
        return mappedModelIdForGLM(modelId)
    }

    func runtimeConfigOverrideForThreadStart() -> JSONValue? {
        guard let selectedConfigProfileName,
              !selectedConfigProfileName.isEmpty else {
            return nil
        }

        return .object([
            "profile": .string(selectedConfigProfileName),
        ])
    }

    func effectiveServiceTier(for threadId: String? = nil) -> CodexServiceTier? {
        if let threadOverride = threadRuntimeOverride(for: threadId),
           threadOverride.overridesServiceTier {
            return threadOverride.serviceTier
        }

        return selectedServiceTier
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
        let requestShapes = orderedSandboxRequestShapes()
        var lastError: Error?

        for (index, requestShape) in requestShapes.enumerated() {
            let params = requestParams(
                for: requestShape,
                baseParams: baseParams,
                accessMode: selectedAccessMode
            )

            do {
                debugRuntimeLog("\(method) using \(requestShape.debugLabel)")
                let response = try await sendRequestWithApprovalPolicyFallback(
                    method: method,
                    baseParams: params,
                    context: requestShape.debugLabel
                )
                preferredSandboxRequestShape = requestShape
                return response
            } catch {
                lastError = error
                let hasMoreShapes = index < (requestShapes.count - 1)
                guard hasMoreShapes, shouldFallbackFromSandboxPolicy(error) else {
                    throw error
                }
            }
        }

        throw lastError ?? CodexServiceError.invalidResponse("\(method) failed with unknown sandbox compatibility error")
    }

    private func orderedApprovalPolicyCandidates(for accessMode: CodexAccessMode) -> [String] {
        let candidates = accessMode.approvalPolicyCandidates
        guard let preferredPolicy = preferredApprovalPolicyByAccessMode[accessMode],
              candidates.contains(preferredPolicy) else {
            return candidates
        }

        return [preferredPolicy] + candidates.filter { $0 != preferredPolicy }
    }

    private func orderedSandboxRequestShapes() -> [CodexSandboxRequestShape] {
        [preferredSandboxRequestShape] + CodexSandboxRequestShape.allCases.filter { $0 != preferredSandboxRequestShape }
    }

    private func requestParams(
        for requestShape: CodexSandboxRequestShape,
        baseParams: RPCObject,
        accessMode: CodexAccessMode
    ) -> RPCObject {
        var params = baseParams

        switch requestShape {
        case .sandboxPolicy:
            params["sandboxPolicy"] = runtimeSandboxPolicyObject(for: accessMode)
        case .sandbox:
            params["sandbox"] = .string(accessMode.sandboxLegacyValue)
        case .minimal:
            break
        }

        return params
    }

    func handleModelListFailure(_ error: Error) {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.isEmpty ? "Unable to load models" : message
        modelsErrorMessage = normalized
        debugRuntimeLog("model/list failed: \(normalized)")
    }

    func debugRuntimeLog(_ message: String) {
#if DEBUG
        print("[CodexRuntime] \(message)")
#endif
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
}

private extension CodexSandboxRequestShape {
    var debugLabel: String {
        switch self {
        case .sandboxPolicy:
            return "sandboxPolicy"
        case .sandbox:
            return "sandbox"
        case .minimal:
            return "minimal"
        }
    }
}

private extension CodexService {
    // Centralizes thread-override mutation so empty records never linger in storage.
    func mutateThreadRuntimeOverride(
        for threadId: String,
        mutate: (inout CodexThreadRuntimeOverride) -> Void
    ) {
        var currentOverride = threadRuntimeOverridesByThreadID[threadId] ?? CodexThreadRuntimeOverride(
            reasoningEffort: nil,
            serviceTierRawValue: nil,
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

    func normalizeRuntimeSelectionsAfterModelsUpdate() {
        guard !availableModels.isEmpty else {
            persistRuntimeSelections()
            return
        }

        let resolvedModel = selectedModelOption(from: availableModels) ?? fallbackModel(from: availableModels)
        selectedModelId = resolvedModel?.id

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
        } else {
            selectedReasoningEffort = nil
        }

        persistRuntimeSelections()
    }

    func selectedModelOption(from models: [CodexModelOption]) -> CodexModelOption? {
        guard !models.isEmpty else {
            return nil
        }

        if let selectedModelId,
           let directMatch = models.first(where: { $0.id == selectedModelId || $0.model == selectedModelId }) {
            return directMatch
        }

        return nil
    }

    func fallbackModel(from models: [CodexModelOption]) -> CodexModelOption? {
        if let defaultModel = models.first(where: { $0.isDefault }) {
            return defaultModel
        }
        return models.first
    }

    func persistRuntimeSelections() {
        if hasExplicitModelSelection,
           let selectedModelId, !selectedModelId.isEmpty {
            defaults.set(selectedModelId, forKey: Self.selectedModelIdDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedModelIdDefaultsKey)
        }

        if let selectedConfigProfileName, !selectedConfigProfileName.isEmpty {
            defaults.set(selectedConfigProfileName, forKey: Self.selectedConfigProfileDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedConfigProfileDefaultsKey)
        }

        if hasExplicitReasoningEffortSelection,
           let selectedReasoningEffort, !selectedReasoningEffort.isEmpty {
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
            defaults.removeObject(forKey: Self.threadRuntimeOverridesDefaultsKey)
            return
        }

        defaults.set(encodedOverrides, forKey: Self.threadRuntimeOverridesDefaultsKey)
    }
}

private struct CodexConfigReadPayload: Decodable {
    let config: CodexConfigReadConfig

    var availableProfiles: [CodexConfigProfileOption] {
        (config.profiles ?? [:])
            .map { key, value in
                CodexConfigProfileOption(
                    id: key,
                    model: value.model,
                    modelProvider: value.modelProvider
                )
            }
            .sorted { lhs, rhs in
                lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
    }
}

struct CodexConfigProfileOption: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let model: String?
    let modelProvider: String?

    var detailText: String? {
        if let model {
            if let provider = modelProvider {
                return "Uses \(model) (\(provider)) for new chats."
            }
            return "Uses \(model) for new chats."
        }
        return nil
    }

    init(id: String, model: String?, modelProvider: String?) {
        self.id = id
        self.model = model
        self.modelProvider = modelProvider
    }
}

private struct CodexConfigReadConfig: Decodable {
    let profiles: [String: CodexConfigReadProfile]?
}

private struct CodexConfigReadProfile: Decodable {
    let model: String?
    let modelProvider: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case modelProvider = "model_provider"
    }
}
