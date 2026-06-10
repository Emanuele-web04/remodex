// FILE: CodexService+RuntimeConfig.swift
// Purpose: Per-thread runtime overrides, selection persistence, and thin forwards to RuntimeCoordinator.
// Layer: Service
// Exports: CodexService runtime config APIs
// Depends on: RuntimeCoordinator, CodexModelOption, CodexReasoningEffortOption, CodexAccessMode

import Foundation

private let runtimeDebugTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

private enum RuntimeReasoningFallback {
    static let codexEfforts = ["low", "medium", "high", "xhigh"]
}

private struct RuntimeModelIdentity {
    let modelId: String
    let provider: String
}

private enum RuntimeProviderPolicy {
    static let strictThreadProviders: Set<String> = [
        "opencode",
    ]
}

// MARK: - RuntimeCoordinator forwards

extension CodexService {
    func modelsErrorMessage(forThreadId threadId: String?) -> String? {
        runtimeCoordinator.modelsErrorMessage(forThreadId: threadId)
    }

    func setModelsErrorMessage(_ message: String?, forProvider provider: String) {
        runtimeCoordinator.setModelsErrorMessage(message, forProvider: provider)
    }

    func clearModelsErrorMessages() {
        runtimeCoordinator.clearModelsErrorMessages()
    }

    func loadPersistedModelsErrorMessages() {
        runtimeCoordinator.loadPersistedModelsErrorMessages()
    }

    var isLoadingOpenCodeProvider: Bool {
        runtimeCoordinator.isLoadingOpenCodeProvider
    }

    var openCodeProviderDiscoveryReasonCode: String? {
        runtimeCoordinator.openCodeProviderDiscoveryReasonCode
    }

    var menuCatalogProviderIDs: [String] {
        runtimeCoordinator.menuCatalogProviderIDs
    }

    var isOpenCodeRuntimeEnabledInCatalog: Bool {
        runtimeCoordinator.isOpenCodeRuntimeEnabledInCatalog
    }

    var shouldAttemptOpenCodeModelLoad: Bool {
        runtimeCoordinator.shouldAttemptOpenCodeModelLoad
    }

    var openCodeRuntimeCatalogEntry: RuntimeInfo? {
        runtimeCoordinator.openCodeRuntimeCatalogEntry
    }

    var openCodeRuntimeDetails: OpenCodeRuntimeDetails? {
        runtimeCoordinator.openCodeRuntimeDetails
    }

    var openCodeCatalogProviders: [OpenCodeCatalogProvider] {
        runtimeCoordinator.openCodeCatalogProviders
    }

    var handoffEnvEnabled: Bool {
        runtimeCoordinator.handoffEnvEnabled
    }

    func isOpenCodeModelListRetryTerminal() -> Bool {
        runtimeCoordinator.isOpenCodeModelListRetryTerminal()
    }

    func listModels(refreshProviders: Bool = false) async throws {
        try await runtimeCoordinator.listModels(refreshProviders: refreshProviders)
    }

    func fetchFullOpenCodeModelList(threadId: String?) async throws -> [CodexModelOption] {
        try await runtimeCoordinator.fetchFullOpenCodeModelList(threadId: threadId)
    }

    func resetOpenCodeModelsRetry() {
        runtimeCoordinator.resetOpenCodeModelsRetry()
    }

    func reconcileOpenCodeModelsAfterList() {
        runtimeCoordinator.reconcileOpenCodeModelsAfterList()
    }

    func fetchRuntimeCatalog() async throws {
        try await runtimeCoordinator.fetchRuntimeCatalog()
    }

    func refreshRuntimeMetadataSequential() async {
        await runtimeCoordinator.refreshRuntimeMetadataSequential()
    }

    func refreshRuntimeMetadataParallel() async {
        await runtimeCoordinator.refreshRuntimeMetadataParallel()
    }

    func noteOpenCodeCatalogRevisionAfterFetch() {
        runtimeCoordinator.noteOpenCodeCatalogRevisionAfterFetch()
    }

    func supportsStructuredSkillInput(forThreadId threadId: String?) -> Bool {
        runtimeCoordinator.supportsStructuredSkillInput(forThreadId: threadId)
    }

    func supportsSkillFileInjection(forThreadId threadId: String?) -> Bool {
        runtimeCoordinator.supportsSkillFileInjection(forThreadId: threadId)
    }

    func supportsImageAttachments(forThreadId threadId: String?) -> Bool {
        runtimeCoordinator.supportsImageAttachments(forThreadId: threadId)
    }

    func providerCapabilitiesForTurn(threadId: String?) -> ProviderCapabilities {
        runtimeCoordinator.providerCapabilitiesForTurn(threadId: threadId)
    }

    func supportsDesktopHandoffForTurn(threadId: String?) -> Bool {
        runtimeCoordinator.supportsDesktopHandoffForTurn(threadId: threadId)
    }

    func isDesktopHandoffActionAvailable(forThreadId threadId: String?) -> Bool {
        runtimeCoordinator.isDesktopHandoffActionAvailable(forThreadId: threadId)
    }
}

// MARK: - Thread overrides and selection persistence

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

    func setSelectedModelId(_ modelId: String?) {
        let normalized = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized?.isEmpty == false {
            selectedModelId = normalized
        } else {
            selectedModelId = RuntimeSelectionDefaults.selectionKey
            selectedReasoningEffort = RuntimeSelectionDefaults.reasoningEffort
        }
        hasPersistedSelectedModelId = true
        normalizeRuntimeSelectionsAfterModelsUpdate()
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

        let normalizedServiceTier = normalizedServiceTierForSelectedModel(serviceTier, threadId: normalizedThreadID)
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

    func setThreadModelOverride(_ model: CodexModelOption, for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.modelId = model.id
            override.modelProvider = model.modelProvider
            override.overridesModel = true
        }
    }

    func clearThreadModelOverride(for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.modelId = nil
            override.modelProvider = nil
            override.overridesModel = false
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

    func setSelectedAgentOverride(_ agent: String?, for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        let normalized = agent?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            clearThreadOpenCodeAgentOverride(for: normalizedThreadID)
            return
        }

        setThreadOpenCodeAgentOverride(normalized, for: normalizedThreadID)
    }

    func setThreadOpenCodeAgentOverride(_ agentId: String, for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        let normalized = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            clearThreadOpenCodeAgentOverride(for: normalizedThreadID)
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.opencodeAgentId = validatedOpenCodeAgentId(normalized) ?? normalized
            override.overridesAgent = true
        }
    }

    func clearThreadOpenCodeAgentOverride(for threadId: String?) {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId) else {
            return
        }

        mutateThreadRuntimeOverride(for: normalizedThreadID) { override in
            override.opencodeAgentId = nil
            override.overridesAgent = false
        }
    }

    func setDefaultOpenCodeAgent(_ agent: String?) {
        let normalized = agent?.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultOpenCodeAgentId = (normalized?.isEmpty == false) ? normalized : nil
        persistRuntimeSelections()
    }

    // Remodex app drives Mac-started OpenCode session/project discovery via thread/list params.
    var openCodeExternalDiscoveryEnabled: Bool {
        if defaults.object(forKey: Self.openCodeExternalDiscoveryDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: Self.openCodeExternalDiscoveryDefaultsKey)
    }

    func setOpenCodeExternalDiscoveryEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.openCodeExternalDiscoveryDefaultsKey)
    }

    func selectedModelOption() -> CodexModelOption? {
        selectedModelOption(from: availableModels)
    }

    func modelOption(forSelectionKey selectionKey: String?) -> CodexModelOption? {
        let normalized = selectionKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else {
            return nil
        }
        return availableModels.first(where: {
            $0.selectionKey == normalized || $0.id == normalized || $0.model == normalized
        })
    }

    func selectedModelOption(threadId: String?) -> CodexModelOption? {
        if let overrideIdentity = runtimeOverrideModelIdentity(for: threadId) {
            return modelOption(
                forThreadModelId: overrideIdentity.modelId,
                provider: overrideIdentity.provider,
                in: availableModels
            )
        }

        if let threadIdentity = threadModelIdentity(for: threadId) {
            return modelOption(
                forThreadModelId: threadIdentity.modelId,
                provider: threadIdentity.provider,
                in: availableModels
            )
        }

        return selectedModelOption()
    }

    // Composer chrome should not present the canonical fallback as a loaded user choice.
    func visibleSelectedModelIDForComposer(threadId: String? = nil) -> String? {
        if let selectedModel = selectedModelOption(threadId: threadId) {
            return selectedModel.selectionKey
        }

        if let unresolvedIdentity = unresolvedRuntimeModelIdentity(for: threadId) {
            return CodexModelOption.selectionKey(
                provider: unresolvedIdentity.provider,
                modelId: unresolvedIdentity.modelId
            )
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
    func isRuntimeSelectionLoadingForComposer(threadId: String? = nil) -> Bool {
        guard visibleSelectedModelIDForComposer(threadId: threadId) == nil else {
            return false
        }
        return isBootstrappingConnectionSync || isLoadingThreads || isLoadingModels
    }

    // Blocks composer send/attach until the first catalog or model/list snapshot resolves.
    func isRuntimeCapabilitiesLoadingForComposer(threadId: String? = nil) -> Bool {
        _ = threadId
        guard availableModels.isEmpty else {
            return false
        }
        return isBootstrappingConnectionSync || isLoadingModels || availableRuntimes.isEmpty
    }

    func selectedGitWriterModelOption() -> CodexModelOption? {
        selectedGitWriterModelOption(from: availableModels)
    }

    func selectedModelSupportsServiceTier(_ serviceTier: CodexServiceTier) -> Bool {
        selectedModelSupportsServiceTier(serviceTier, threadId: nil)
    }

    func selectedModelSupportsServiceTier(_ serviceTier: CodexServiceTier, threadId: String?) -> Bool {
        selectedModelOption(threadId: threadId)?.supportsServiceTier(serviceTier) == true
    }

    func gitWriterModelIdentifier() -> String? {
        selectedGitWriterModelOption()?.model
    }

    func supportedReasoningEffortsForSelectedModel() -> [CodexReasoningEffortOption] {
        supportedReasoningEffortsForSelectedModel(threadId: nil)
    }

    func supportedReasoningEffortsForSelectedModel(threadId: String?) -> [CodexReasoningEffortOption] {
        let modelEfforts = selectedModelOption(threadId: threadId)?.supportedReasoningEfforts ?? []
        if !modelEfforts.isEmpty {
            return modelEfforts
        }

        guard shouldOfferCodexReasoningFallback(threadId: threadId) else {
            return []
        }

        return RuntimeReasoningFallback.codexEfforts.map {
            CodexReasoningEffortOption(reasoningEffort: $0, description: "")
        }
    }

    private func shouldOfferCodexReasoningFallback(threadId: String?) -> Bool {
        if let model = selectedModelOption(threadId: threadId) {
            return model.modelProvider == RuntimeSelectionDefaults.provider
                && (model.capabilities.supportsReasoningEffort || model.supportedReasoningEfforts.isEmpty)
        }

        if let identity = unresolvedRuntimeModelIdentity(for: threadId) {
            return identity.provider == RuntimeSelectionDefaults.provider
        }

        let persistedProvider = CodexModelOption.splitSelectionKey(selectedModelId).provider
        return selectedModelId == nil
            || CodexModelOption.normalizedProvider(persistedProvider) == RuntimeSelectionDefaults.provider
    }

    func isThreadReasoningEffortOverridden(_ threadId: String?) -> Bool {
        guard let threadOverride = threadRuntimeOverride(for: threadId),
              threadOverride.overridesReasoning,
              let selectedReasoning = threadOverride.reasoningEffort else {
            return false
        }

        let supportedReasoningEfforts = Set(
            supportedReasoningEffortsForSelectedModel(threadId: threadId).map(\.reasoningEffort)
        )
        return supportedReasoningEfforts.contains(selectedReasoning)
    }

    func isThreadServiceTierOverridden(_ threadId: String?) -> Bool {
        threadRuntimeOverride(for: threadId)?.overridesServiceTier == true
    }

    func selectedReasoningEffortForSelectedModel(threadId: String? = nil) -> String? {
        guard let model = selectedModelOption(threadId: threadId) else {
            if let unresolvedIdentity = unresolvedRuntimeModelIdentity(for: threadId),
               unresolvedIdentity.provider != RuntimeSelectionDefaults.provider {
                return nil
            }
            return RuntimeSelectionDefaults.reasoningEffort(for: runtimeModelIdentifierForTurn(threadId: threadId))
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

    func runtimeModelIdentifierForTurn(threadId: String? = nil) -> String? {
        if let selectedModel = selectedModelOption(threadId: threadId) {
            return selectedModel.model
        }
        if let unresolvedIdentity = unresolvedRuntimeModelIdentity(for: threadId) {
            return unresolvedIdentity.modelId
        }
        let splitSelection = CodexModelOption.splitSelectionKey(selectedModelId)
        return splitSelection.modelId ?? RuntimeSelectionDefaults.modelId
    }

    func runtimeModelProviderForTurn(threadId: String? = nil) -> String {
        if let enforced = enforcedThreadOwnershipModelProvider(for: threadId) {
            return enforced
        }
        if let selectedModel = selectedModelOption(threadId: threadId) {
            return selectedModel.modelProvider
        }
        if let unresolvedIdentity = unresolvedRuntimeModelIdentity(for: threadId) {
            return unresolvedIdentity.provider
        }
        return CodexModelOption.splitSelectionKey(selectedModelId).provider
    }

    func runtimeCapabilitiesForTurn(threadId: String? = nil) -> ProviderCapabilities {
        if let capabilities = selectedModelOption(threadId: threadId)?.capabilities {
            return capabilities
        }
        let provider = CodexModelOption.normalizedProvider(runtimeModelProviderForTurn(threadId: threadId))
        if isRuntimeCapabilitiesLoadingForComposer(threadId: threadId) {
            if provider == "opencode", let catalogCapabilities = openCodeRuntimeCatalogEntry?.capabilities {
                return catalogCapabilities
            }
            if let runtime = availableRuntimes.first(where: {
                CodexModelOption.normalizedProvider($0.id) == provider
            }) {
                return runtime.capabilities
            }
        }
        if let runtime = availableRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == provider
        }) {
            return runtime.capabilities
        }
        return provider == "opencode"
            ? ProviderCapabilities.defaultOpenCode
            : ProviderCapabilities.defaultCodex
    }

    // Thread list ownership wins over global composer selection on turn/start wire params.
    func enforcedThreadOwnershipModelProvider(for threadId: String?) -> String? {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId),
              let thread = threadByID[normalizedThreadID],
              let modelProvider = thread.modelProvider else {
            return nil
        }
        let normalizedProvider = CodexModelOption.normalizedProvider(modelProvider)
        return isStrictRuntimeProvider(normalizedProvider) ? normalizedProvider : nil
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
        return selectedModelSupportsServiceTier(candidate, threadId: threadId) ? candidate : nil
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
        if method == "turn/start",
           let threadId = baseParams["threadId"]?.stringValue,
           CodexModelOption.normalizedProvider(runtimeModelProviderForTurn(threadId: threadId)) == "opencode" {
            return try await sendRequestWithApprovalPolicyFallback(
                method: method,
                baseParams: baseParams,
                context: "opencode-minimal"
            )
        }

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

    func normalizedServiceTierForSelectedModel(
        _ serviceTier: CodexServiceTier?,
        threadId: String? = nil
    ) -> CodexServiceTier? {
        guard let serviceTier else {
            return nil
        }
        guard let selectedModel = selectedModelOption(threadId: threadId) else {
            return serviceTier
        }
        return selectedModel.supportsServiceTier(serviceTier) ? serviceTier : nil
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
        return (normalizedSelection == RuntimeSelectionDefaults.modelId
            || normalizedSelection == RuntimeSelectionDefaults.selectionKey)
            && (isBootstrappingConnectionSync || isLoadingModels)
    }

    // Centralizes thread-override mutation so empty records never linger in storage.
    func mutateThreadRuntimeOverride(
        for threadId: String,
        mutate: (inout CodexThreadRuntimeOverride) -> Void
    ) {
        var currentOverride = threadRuntimeOverridesByThreadID[threadId] ?? CodexThreadRuntimeOverride(
            modelId: nil,
            modelProvider: nil,
            reasoningEffort: nil,
            serviceTierRawValue: nil,
            opencodeAgentId: nil,
            overridesModel: false,
            overridesReasoning: false,
            overridesServiceTier: false,
            overridesAgent: false
        )

        mutate(&currentOverride)

        if currentOverride.isEmpty {
            threadRuntimeOverridesByThreadID.removeValue(forKey: threadId)
        } else {
            threadRuntimeOverridesByThreadID[threadId] = currentOverride
        }

        persistThreadRuntimeOverrides()
    }

    func selectedModelOption(from models: [CodexModelOption]) -> CodexModelOption? {
        guard !models.isEmpty else {
            return nil
        }

        if let selectedModelId,
           let directMatch = models.first(where: {
               $0.selectionKey == selectedModelId || $0.id == selectedModelId || $0.model == selectedModelId
           }) {
            return directMatch
        }

        return nil
    }

    func unresolvedRuntimeModelIdentity(for threadId: String?) -> RuntimeModelIdentity? {
        runtimeOverrideModelIdentity(for: threadId) ?? threadModelIdentity(for: threadId)
    }

    func runtimeOverrideModelIdentity(for threadId: String?) -> RuntimeModelIdentity? {
        guard let threadOverride = threadRuntimeOverride(for: threadId),
              threadOverride.overridesModel,
              let modelId = normalizedRuntimeModelId(threadOverride.modelId) else {
            return nil
        }

        return RuntimeModelIdentity(
            modelId: modelId,
            provider: CodexModelOption.normalizedProvider(threadOverride.modelProvider)
        )
    }

    func threadModelIdentity(for threadId: String?) -> RuntimeModelIdentity? {
        guard let normalizedThreadID = normalizedInterruptIdentifier(threadId),
              let thread = threadByID[normalizedThreadID],
              let modelId = normalizedRuntimeModelId(thread.model) else {
            return nil
        }

        return RuntimeModelIdentity(
            modelId: modelId,
            provider: CodexModelOption.normalizedProvider(thread.modelProvider)
        )
    }

    func normalizedRuntimeModelId(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    // Thread metadata predates runtime providers, so only known runtime providers bypass Codex fallback.
    func modelOption(
        forThreadModelId modelId: String,
        provider: String?,
        in models: [CodexModelOption]
    ) -> CodexModelOption? {
        let normalizedProvider = CodexModelOption.normalizedProvider(provider)
        if let providerMatch = models.first(where: {
            $0.modelProvider == normalizedProvider && ($0.id == modelId || $0.model == modelId)
        }) {
            return providerMatch
        }

        if isStrictRuntimeProvider(normalizedProvider) {
            return nil
        }

        if let codexMatch = models.first(where: {
            $0.modelProvider == RuntimeSelectionDefaults.provider && ($0.id == modelId || $0.model == modelId)
        }) {
            return codexMatch
        }

        return models.first(where: {
            $0.id == modelId || $0.model == modelId
        })
    }

    func isStrictRuntimeProvider(_ provider: String) -> Bool {
        RuntimeProviderPolicy.strictThreadProviders.contains(provider)
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
           let directMatch = models.first(where: {
               $0.modelProvider == RuntimeSelectionDefaults.provider
                   && ($0.selectionKey == savedSelection || $0.id == savedSelection || $0.model == savedSelection)
           }) {
            return directMatch
        }

        if let miniModel = models.first(where: {
            $0.modelProvider == RuntimeSelectionDefaults.provider
                && ($0.id == "gpt-5.4-mini" || $0.model == "gpt-5.4-mini")
        }) {
            return miniModel
        }

        if let runtimeSelected = selectedModelOption(from: models),
           runtimeSelected.modelProvider == RuntimeSelectionDefaults.provider {
            return runtimeSelected
        }

        return fallbackModel(from: models.filter { $0.modelProvider == RuntimeSelectionDefaults.provider })
    }

    func fallbackModel(from models: [CodexModelOption]) -> CodexModelOption? {
        if let preferred = models.first(where: {
            $0.modelProvider == RuntimeSelectionDefaults.provider
                && ($0.id.lowercased() == "gpt-5.5" || $0.model.lowercased() == "gpt-5.5")
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

        if let defaultOpenCodeAgentId, !defaultOpenCodeAgentId.isEmpty {
            defaults.set(defaultOpenCodeAgentId, forKey: Self.defaultOpenCodeAgentDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultOpenCodeAgentDefaultsKey)
        }

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
        selectedModelId = resolvedModel?.selectionKey
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
               $0.modelProvider == RuntimeSelectionDefaults.provider
                   && (
                       $0.selectionKey == selectedGitWriterModelId
                       || $0.id == selectedGitWriterModelId
                       || $0.model == selectedGitWriterModelId
                   )
           }) {
            self.selectedGitWriterModelId = nil
        }

        persistRuntimeSelections()
    }
}
