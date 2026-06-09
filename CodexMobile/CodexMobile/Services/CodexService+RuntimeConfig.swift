// FILE: CodexService+RuntimeConfig.swift
// Purpose: Runtime model/reasoning/access preferences, per-thread overrides, and model/list loading.
// Layer: Service
// Exports: CodexService runtime config APIs
// Depends on: CodexModelOption, CodexReasoningEffortOption, CodexAccessMode, OpenCodeCatalogProvider (for logo catalog)

import Foundation

private let runtimeDebugTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

private enum RuntimeConfigLoadingPolicy {
    // Bridge may cold-start OpenCode while listing agents; allow relay + decode headroom.
    static let runtimeCatalogTimeoutNanoseconds: UInt64 = 15_000_000_000
    // OpenCode model discovery can cold-start `opencode serve` (~25s on the bridge).
    static let modelListTimeoutNanoseconds: UInt64 = 35_000_000_000
}

private enum RuntimeReasoningFallback {
    static let codexEfforts = ["low", "medium", "high", "xhigh"]
}

private enum RuntimeSelectionDefaults {
    static let provider = "codex"
    static let modelId = "gpt-5.5"
    static let selectionKey = CodexModelOption.selectionKey(provider: provider, modelId: modelId)
    static let reasoningEffort = "medium"

    static func reasoningEffort(for unresolvedModelId: String?) -> String? {
        guard let unresolvedModelId,
              unresolvedModelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == modelId else {
            return nil
        }
        return reasoningEffort
    }
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

private let openCodeModelsRetryErrorMessage = "OpenCode models did not load. Tap Retry in the model menu."

extension CodexService {
    func modelsErrorMessage(forThreadId threadId: String?) -> String? {
        guard let threadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !threadId.isEmpty else {
            return nil
        }
        let provider = CodexModelOption.normalizedProvider(
            runtimeModelProviderForTurn(threadId: threadId)
        ) ?? RuntimeSelectionDefaults.provider
        return modelsErrorMessageByProvider[provider]
    }

    func setModelsErrorMessage(_ message: String?, forProvider provider: String) {
        let normalizedProvider = CodexModelOption.normalizedProvider(provider) ?? provider
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            modelsErrorMessageByProvider.removeValue(forKey: normalizedProvider)
        } else {
            modelsErrorMessageByProvider[normalizedProvider] = trimmed
        }
        persistModelsErrorMessages()
    }

    func clearModelsErrorMessages() {
        modelsErrorMessageByProvider.removeAll()
        persistModelsErrorMessages()
    }

    func loadPersistedModelsErrorMessages() {
        guard let data = defaults.object(forKey: Self.modelsErrorMessageByProviderDefaultsKey) as? Data,
              let decoded = try? decoder.decode([String: String].self, from: data) else {
            return
        }
        modelsErrorMessageByProvider = decoded
    }

    private func persistModelsErrorMessages() {
        if modelsErrorMessageByProvider.isEmpty {
            defaults.removeObject(forKey: Self.modelsErrorMessageByProviderDefaultsKey)
            return
        }
        guard let data = try? encoder.encode(modelsErrorMessageByProvider) else { return }
        defaults.set(data, forKey: Self.modelsErrorMessageByProviderDefaultsKey)
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

    var isLoadingOpenCodeProvider: Bool {
        guard shouldAttemptOpenCodeModelLoad else {
            return false
        }
        if openCodeProviderDiscoveryReasonCode == "no_connected_providers" {
            return false
        }
        if openCodeModelsRetryTask != nil {
            return true
        }
        if isLoadingModels, openCodeProviderDiscoveryReasonCode == nil, lastModelListOpenCodeMeta == nil {
            return true
        }
        if isLoadingModels {
            return true
        }
        return false
    }

    var openCodeProviderDiscoveryReasonCode: String? {
        let fromList = lastModelListOpenCodeMeta?.reasonCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromList, !fromList.isEmpty {
            return fromList
        }
        let fromCatalog = openCodeRuntimeDetails?.providerDiscoveryReasonCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromCatalog, !fromCatalog.isEmpty {
            return fromCatalog
        }
        return nil
    }

    /// Provider IDs for the model menu — from `runtime/catalog`, or default-on until catalog arrives.
    var menuCatalogProviderIDs: [String] {
        let fromCatalog = availableRuntimes.map {
            CodexModelOption.normalizedProvider($0.id)
        }
        if !fromCatalog.isEmpty {
            return fromCatalog
        }
        guard isConnected, isInitialized else {
            return ["codex"]
        }
        return ["codex", "opencode"]
    }

    var isOpenCodeRuntimeEnabledInCatalog: Bool {
        openCodeRuntimeCatalogEntry?.enabled == true
    }

    /// True when OpenCode should appear in the model menu and model/list retries may run.
    var shouldAttemptOpenCodeModelLoad: Bool {
        if let entry = openCodeRuntimeCatalogEntry {
            if entry.reasonCode == "opencode_not_enabled" {
                return false
            }
            return true
        }
        return isConnected && isInitialized
    }

    var openCodeRuntimeCatalogEntry: RuntimeInfo? {
        availableRuntimes.first {
            CodexModelOption.normalizedProvider($0.id) == "opencode"
        }
    }

    var openCodeRuntimeDetails: OpenCodeRuntimeDetails? {
        openCodeRuntimeCatalogEntry?.opencode
    }

    /// Catalog-driven providers for logo resolution (id, name, logoAssetId? from BRAND-1).
    /// Used by ProviderLogoView catalog resolver; see provider-branding.md for emergency SF fallback.
    var openCodeCatalogProviders: [OpenCodeCatalogProvider] {
        openCodeRuntimeCatalogEntry?.opencode?.providers ?? []
    }

    func isOpenCodeModelListRetryTerminal() -> Bool {
        guard shouldAttemptOpenCodeModelLoad else {
            return true
        }
        guard let reason = openCodeProviderDiscoveryReasonCode?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !reason.isEmpty
        else {
            return false
        }

        switch reason {
        case "no_connected_providers", "unknown", "provider_list_failed":
            return true
        case "ok":
            return !availableModels.contains {
                CodexModelOption.normalizedProvider($0.modelProvider) == "opencode"
            }
        default:
            return false
        }
    }

    func listModels(refreshProviders: Bool = false) async throws {
        isLoadingModels = true
        defer { isLoadingModels = false }

        do {
            var params: [String: JSONValue] = [
                "cursor": .null,
                "limit": .integer(50),
                "includeHidden": .bool(false),
            ]
            if refreshProviders {
                params["refreshProviders"] = .bool(true)
            }
            let response = try await sendRequest(
                method: "model/list",
                params: .object(params),
                timeoutNanoseconds: RuntimeConfigLoadingPolicy.modelListTimeoutNanoseconds,
                timeoutMessage: "model/list timed out while syncing runtime options."
            )

            guard let resultObject = response.result?.objectValue else {
                throw CodexServiceError.invalidResponse("model/list response missing payload")
            }

            if let opencodeObject = resultObject["opencode"]?.objectValue,
               let opencodeData = try? JSONEncoder().encode(opencodeObject),
               let meta = try? JSONDecoder().decode(OpenCodeModelListMeta.self, from: opencodeData) {
                lastModelListOpenCodeMeta = meta
            }

            let items =
                resultObject["items"]?.arrayValue
                ?? resultObject["data"]?.arrayValue
                ?? resultObject["models"]?.arrayValue
                ?? []

            let decodedModels = items.compactMap { decodeModel(CodexModelOption.self, from: $0) }
            if decodedModels.isEmpty, !items.isEmpty {
                setModelsErrorMessage(
                    "Models could not be decoded. Tap Retry in the model menu.",
                    forProvider: "opencode"
                )
                debugRuntimeLog("model/list decode produced 0 models from \(items.count) items")
            } else {
                availableModels = decodedModels
                clearModelsErrorMessages()
                normalizeRuntimeSelectionsAfterModelsUpdate()
                debugRuntimeLog("model/list success count=\(decodedModels.count)")
            }
            reconcileOpenCodeModelsAfterList()
        } catch {
            if !availableModels.isEmpty {
                clearModelsErrorMessages()
                debugRuntimeLog("model/list refresh failed; keeping \(availableModels.count) cached models")
                reconcileOpenCodeModelsAfterList()
                return
            }
            handleModelListFailure(error)
            reconcileOpenCodeModelsAfterList()
            throw error
        }
    }

    func fetchFullOpenCodeModelList(threadId: String?) async throws -> [CodexModelOption] {
        let response = try await sendRequest(
            method: "model/list",
            params: .object([
                "full": .bool(true),
                "provider": .string("opencode"),
                "refreshProviders": .bool(true),
            ]),
            timeoutNanoseconds: RuntimeConfigLoadingPolicy.modelListTimeoutNanoseconds,
            timeoutMessage: "model/list full timed out."
        )

        guard let resultObject = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("model/list full response missing payload")
        }

        let items =
            resultObject["items"]?.arrayValue
            ?? resultObject["data"]?.arrayValue
            ?? resultObject["models"]?.arrayValue
            ?? []

        return items
            .compactMap { decodeModel(CodexModelOption.self, from: $0) }
            .filter { CodexModelOption.normalizedProvider($0.modelProvider) == "opencode" }
            .sorted {
                TurnComposerMetaMapper.modelTitle(for: $0)
                    .localizedCaseInsensitiveCompare(TurnComposerMetaMapper.modelTitle(for: $1)) == .orderedAscending
            }
    }

    func resetOpenCodeModelsRetry() {
        openCodeModelsRetryTask?.cancel()
        openCodeModelsRetryTask = nil
        openCodeModelRetryCount = 0
    }

    func reconcileOpenCodeModelsAfterList() {
        guard shouldAttemptOpenCodeModelLoad else {
            resetOpenCodeModelsRetry()
            return
        }

        if isOpenCodeModelListRetryTerminal() {
            resetOpenCodeModelsRetry()
            if openCodeProviderDiscoveryReasonCode == "no_connected_providers" {
                setModelsErrorMessage(nil, forProvider: "opencode")
            }
            return
        }

        let hasOpenCodeModels = availableModels.contains {
            CodexModelOption.normalizedProvider($0.modelProvider) == "opencode"
        }
        if hasOpenCodeModels {
            resetOpenCodeModelsRetry()
            if modelsErrorMessage(forThreadId: activeThreadId) == openCodeModelsRetryErrorMessage {
                setModelsErrorMessage(nil, forProvider: "opencode")
            }
            return
        }

        guard openCodeModelRetryCount < 4 else {
            openCodeModelsRetryTask = nil
            setModelsErrorMessage(openCodeModelsRetryErrorMessage, forProvider: "opencode")
            debugRuntimeLog("OpenCode model/list gave up after \(openCodeModelRetryCount) retries")
            return
        }

        openCodeModelRetryCount += 1
        let attempt = openCodeModelRetryCount
        debugRuntimeLog("OpenCode models missing after model/list; retry \(attempt)/4 in \(attempt + 2)s")
        openCodeModelsRetryTask?.cancel()
        openCodeModelsRetryTask = Task { @MainActor [weak self] in
            let delaySeconds = UInt64(attempt + 2)
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.isConnected, self.isInitialized else {
                self?.openCodeModelsRetryTask = nil
                return
            }
            defer { self.openCodeModelsRetryTask = nil }
            try? await self.listModels()
        }
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

    func fetchRuntimeCatalog() async throws {
        let response = try await sendRequest(
            method: "runtime/catalog",
            params: .object([:]),
            timeoutNanoseconds: RuntimeConfigLoadingPolicy.runtimeCatalogTimeoutNanoseconds,
            timeoutMessage: "runtime/catalog timed out"
        )

        guard let resultObject = response.result?.objectValue else {
            debugRuntimeLog(
                "runtime/catalog missing payload; keeping \(availableRuntimes.count) cached runtimes"
            )
            return
        }

        let runtimes = resultObject["runtimes"]?.arrayValue ?? []
        var nextAgents: [AgentOption] = []
        var nextRuntimes: [RuntimeInfo] = []

        for runtimeJSON in runtimes {
            guard let runtimeObj = runtimeJSON.objectValue else { continue }
            guard let runtimeId = runtimeObj["id"]?.stringValue else { continue }

            let label = runtimeObj["label"]?.stringValue ?? runtimeId
            let enabled = runtimeObj["enabled"]?.boolValue ?? false
            let unavailableReason = runtimeObj["unavailableReason"]?.stringValue
            let reasonCode = runtimeObj["reasonCode"]?.stringValue

            let capabilities: ProviderCapabilities
            if let capsObj = runtimeObj["capabilities"] {
                if let capsData = try? JSONEncoder().encode(capsObj),
                   let decoded = try? JSONDecoder().decode(ProviderCapabilities.self, from: capsData) {
                    capabilities = decoded
                } else {
                    debugRuntimeLog("capability decode fallback — bridge catalog capabilities could not be parsed; using defaultCodex. capsObj=\(capsObj)")
                    capabilities = ProviderCapabilities.defaultCodex
                }
            } else {
                capabilities = ProviderCapabilities.defaultCodex
            }

            // Parse agents
            let agents = (runtimeObj["agents"]?.arrayValue ?? []).compactMap { agentJSON -> AgentOption? in
                guard let agentId = agentJSON.objectValue?["id"]?.stringValue,
                      let agentLabel = agentJSON.objectValue?["label"]?.stringValue else {
                    return nil
                }
                return AgentOption(id: agentId, displayName: agentLabel)
            }

            let showsBetaLabel = runtimeObj["showsBetaLabel"]?.boolValue ?? false

            var opencodeDetails: OpenCodeRuntimeDetails?
            if let opencodeObj = runtimeObj["opencode"]?.objectValue,
               let opencodeData = try? JSONEncoder().encode(opencodeObj) {
                opencodeDetails = try? JSONDecoder().decode(OpenCodeRuntimeDetails.self, from: opencodeData)
            }

            let runtimeInfo = RuntimeInfo(
                id: runtimeId,
                label: label,
                enabled: enabled,
                unavailableReason: unavailableReason,
                reasonCode: reasonCode,
                showsBetaLabel: showsBetaLabel,
                capabilities: capabilities,
                agents: agents,
                opencode: opencodeDetails
            )
            nextRuntimes.append(runtimeInfo)
            nextAgents.append(contentsOf: agents)
        }

        availableRuntimes = nextRuntimes
        availableAgents = nextAgents

        if let codexRuntime = nextRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == "codex"
        }) {
            supportsStructuredSkillInput = codexRuntime.capabilities.supportsStructuredSkillInput
        }

        debugRuntimeLog(
            "runtime/catalog success runtimes=\(nextRuntimes.map(\.id).joined(separator: ","))"
        )
        noteOpenCodeCatalogRevisionAfterFetch()
    }

    func refreshRuntimeMetadataSequential() async {
        await refreshRuntimeMetadataParallel()
    }

    // Warms model inventory and runtime/catalog (logo providers) concurrently so composer
    // chrome and sidebar badges settle faster after connect.
    func refreshRuntimeMetadataParallel() async {
        async let modelsRefresh: Void = {
            try? await self.listModels(refreshProviders: true)
        }()
        async let catalogRefresh: Void = {
            try? await self.fetchRuntimeCatalog()
        }()
        _ = await (modelsRefresh, catalogRefresh)
    }

    func noteOpenCodeCatalogRevisionAfterFetch() {
        let revision = openCodeRuntimeDetails?.catalogRevision?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let revision, !revision.isEmpty else {
            return
        }
        guard revision != lastOpenCodeCatalogRevision else {
            return
        }
        if lastOpenCodeCatalogRevision != nil {
            debugRuntimeLog(
                "ios_catalog_revision_changed revision=\(revision) previous=\(lastOpenCodeCatalogRevision ?? "nil")"
            )
        }
        lastOpenCodeCatalogRevision = revision
    }

    func supportsStructuredSkillInput(forThreadId threadId: String?) -> Bool {
        providerCapabilitiesForTurn(threadId: threadId).supportsStructuredSkillInput
    }

    func supportsSkillFileInjection(forThreadId threadId: String?) -> Bool {
        providerCapabilitiesForTurn(threadId: threadId).supportsSkillFileInjection
    }

    func supportsImageAttachments(forThreadId threadId: String?) -> Bool {
        providerCapabilitiesForTurn(threadId: threadId).supportsImageAttachments
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

    func providerCapabilitiesForTurn(threadId: String?) -> ProviderCapabilities {
        let provider = CodexModelOption.normalizedProvider(runtimeModelProviderForTurn(threadId: threadId))
        if let model = selectedModelOption(threadId: threadId),
           CodexModelOption.normalizedProvider(model.modelProvider) == provider {
            return model.capabilities
        }
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
        if provider == "opencode" {
            return openCodeRuntimeCatalogEntry?.capabilities ?? .defaultOpenCode
        }
        if let codexRuntime = availableRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == "codex"
        }) {
            return codexRuntime.capabilities
        }
        return .defaultCodex
    }

    func supportsDesktopHandoffForTurn(threadId: String?) -> Bool {
        providerCapabilitiesForTurn(threadId: threadId).supportsDesktopHandoff
    }

    /// True when catalog advertises handoff and the Mac bridge reports handoff RPC is available.
    func isDesktopHandoffActionAvailable(forThreadId threadId: String?) -> Bool {
        guard supportsDesktopHandoffForTurn(threadId: threadId) else {
            return false
        }

        let provider = CodexModelOption.normalizedProvider(runtimeModelProviderForTurn(threadId: threadId))
        guard provider == "opencode" else {
            return true
        }

        return openCodeRuntimeDetails?.handoffEnvEnabled == true
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

    func handleModelListFailure(_ error: Error) {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.isEmpty ? "Unable to load models" : message
        setModelsErrorMessage(normalized, forProvider: "opencode")
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
        // Prefer GPT-5.5 when the bridge advertises it; the rest of the app treats
        // it as the canonical default regardless of the bridge's `isDefault` flag.
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
