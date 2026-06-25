// FILE: RuntimeCoordinator.swift
// Purpose: Runtime catalog fetch, model/list loading, retry state, provider capabilities, and models error persistence.
// Layer: Service
// Exports: RuntimeCoordinator
// Depends on: CodexService, CodexModelOption, ProviderCapabilities, OpenCodeCatalogProvider

import Foundation

private enum RuntimeConfigLoadingPolicy {
    // Bridge may cold-start OpenCode while listing agents; allow relay + decode headroom.
    static let runtimeCatalogTimeoutNanoseconds: UInt64 = 15_000_000_000
    // OpenCode model discovery can cold-start `opencode serve` (~25s on the bridge).
    static let modelListTimeoutNanoseconds: UInt64 = 35_000_000_000
}

private let openCodeModelsRetryErrorMessage = "OpenCode models did not load. Tap Retry in the model menu."

@MainActor
final class RuntimeCoordinator {
    private unowned let codex: CodexService

    init(codex: CodexService) {
        self.codex = codex
    }

    // MARK: - Models error state

    func modelsErrorMessage(forThreadId threadId: String?) -> String? {
        guard let threadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !threadId.isEmpty else {
            return nil
        }
        let provider = CodexModelOption.normalizedProvider(
            codex.runtimeModelProviderForTurn(threadId: threadId)
        ) ?? RuntimeSelectionDefaults.provider
        return codex.modelsErrorMessageByProvider[provider]
    }

    func setModelsErrorMessage(_ message: String?, forProvider provider: String) {
        let normalizedProvider = CodexModelOption.normalizedProvider(provider) ?? provider
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            codex.modelsErrorMessageByProvider.removeValue(forKey: normalizedProvider)
        } else {
            codex.modelsErrorMessageByProvider[normalizedProvider] = trimmed
        }
        persistModelsErrorMessages()
    }

    func clearModelsErrorMessages() {
        codex.modelsErrorMessageByProvider.removeAll()
        persistModelsErrorMessages()
    }

    func loadPersistedModelsErrorMessages() {
        guard let data = codex.defaults.object(forKey: CodexService.modelsErrorMessageByProviderDefaultsKey) as? Data,
              let decoded = try? codex.decoder.decode([String: String].self, from: data) else {
            return
        }
        codex.modelsErrorMessageByProvider = decoded
    }

    private func persistModelsErrorMessages() {
        if codex.modelsErrorMessageByProvider.isEmpty {
            codex.defaults.removeObject(forKey: CodexService.modelsErrorMessageByProviderDefaultsKey)
            return
        }
        guard let data = try? codex.encoder.encode(codex.modelsErrorMessageByProvider) else { return }
        codex.defaults.set(data, forKey: CodexService.modelsErrorMessageByProviderDefaultsKey)
    }

    // MARK: - OpenCode catalog / loading state

    var isLoadingOpenCodeProvider: Bool {
        guard shouldAttemptOpenCodeModelLoad else {
            return false
        }
        if openCodeProviderDiscoveryReasonCode == "no_connected_providers" {
            return false
        }
        if codex.openCodeModelsRetryTask != nil {
            return true
        }
        if codex.isLoadingModels, openCodeProviderDiscoveryReasonCode == nil, codex.lastModelListOpenCodeMeta == nil {
            return true
        }
        if codex.isLoadingModels {
            return true
        }
        return false
    }

    var openCodeProviderDiscoveryReasonCode: String? {
        let fromList = codex.lastModelListOpenCodeMeta?.reasonCode?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let fromCatalog = codex.availableRuntimes.map {
            CodexModelOption.normalizedProvider($0.id)
        }
        if !fromCatalog.isEmpty {
            return fromCatalog
        }
        guard codex.isConnected, codex.isInitialized else {
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
        return codex.isConnected && codex.isInitialized
    }

    var openCodeRuntimeCatalogEntry: RuntimeInfo? {
        codex.availableRuntimes.first {
            CodexModelOption.normalizedProvider($0.id) == "opencode"
        }
    }

    var openCodeRuntimeDetails: OpenCodeRuntimeDetails? {
        openCodeRuntimeCatalogEntry?.opencode
    }

    /// Catalog-driven providers for logo resolution (id, name, logoAssetId? from BRAND-1).
    var openCodeCatalogProviders: [OpenCodeCatalogProvider] {
        openCodeRuntimeCatalogEntry?.opencode?.providers ?? []
    }

    /// True when the Mac bridge reports handoff RPC env is available for OpenCode.
    var handoffEnvEnabled: Bool {
        openCodeRuntimeDetails?.handoffEnvEnabled == true
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
            return !codex.availableModels.contains {
                CodexModelOption.normalizedProvider($0.modelProvider) == "opencode"
            }
        default:
            return false
        }
    }

    // MARK: - model/list

    func listModels(refreshProviders: Bool = false) async throws {
        codex.isLoadingModels = true
        defer { codex.isLoadingModels = false }

        do {
            var params: [String: JSONValue] = [
                "cursor": .null,
                "limit": .integer(50),
                "includeHidden": .bool(false),
            ]
            if refreshProviders {
                params["refreshProviders"] = .bool(true)
            }
            let response = try await codex.sendRequest(
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
                codex.lastModelListOpenCodeMeta = meta
            }

            let items =
                resultObject["items"]?.arrayValue
                ?? resultObject["data"]?.arrayValue
                ?? resultObject["models"]?.arrayValue
                ?? []

            let decodedModels = items.compactMap { codex.decodeModel(CodexModelOption.self, from: $0) }
            if decodedModels.isEmpty, !items.isEmpty {
                setModelsErrorMessage(
                    "Models could not be decoded. Tap Retry in the model menu.",
                    forProvider: "opencode"
                )
                codex.debugRuntimeLog("model/list decode produced 0 models from \(items.count) items")
            } else {
                codex.availableModels = decodedModels
                clearModelsErrorMessages()
                codex.normalizeRuntimeSelectionsAfterModelsUpdate()
                codex.debugRuntimeLog("model/list success count=\(decodedModels.count)")
            }
            reconcileOpenCodeModelsAfterList()
        } catch {
            if !codex.availableModels.isEmpty {
                clearModelsErrorMessages()
                codex.debugRuntimeLog("model/list refresh failed; keeping \(codex.availableModels.count) cached models")
                reconcileOpenCodeModelsAfterList()
                return
            }
            handleModelListFailure(error)
            reconcileOpenCodeModelsAfterList()
            throw error
        }
    }

    func fetchFullOpenCodeModelList(threadId: String?) async throws -> [CodexModelOption] {
        let response = try await codex.sendRequest(
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
            .compactMap { codex.decodeModel(CodexModelOption.self, from: $0) }
            .filter { CodexModelOption.normalizedProvider($0.modelProvider) == "opencode" }
            .sorted {
                TurnComposerMetaMapper.modelTitle(for: $0)
                    .localizedCaseInsensitiveCompare(TurnComposerMetaMapper.modelTitle(for: $1)) == .orderedAscending
            }
    }

    func resetOpenCodeModelsRetry() {
        codex.openCodeModelsRetryTask?.cancel()
        codex.openCodeModelsRetryTask = nil
        codex.openCodeModelRetryCount = 0
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

        let hasOpenCodeModels = codex.availableModels.contains {
            CodexModelOption.normalizedProvider($0.modelProvider) == "opencode"
        }
        if hasOpenCodeModels {
            resetOpenCodeModelsRetry()
            if modelsErrorMessage(forThreadId: codex.activeThreadId) == openCodeModelsRetryErrorMessage {
                setModelsErrorMessage(nil, forProvider: "opencode")
            }
            return
        }

        guard codex.openCodeModelRetryCount < 4 else {
            codex.openCodeModelsRetryTask = nil
            setModelsErrorMessage(openCodeModelsRetryErrorMessage, forProvider: "opencode")
            codex.debugRuntimeLog("OpenCode model/list gave up after \(codex.openCodeModelRetryCount) retries")
            return
        }

        codex.openCodeModelRetryCount += 1
        let attempt = codex.openCodeModelRetryCount
        codex.debugRuntimeLog("OpenCode models missing after model/list; retry \(attempt)/4 in \(attempt + 2)s")
        codex.openCodeModelsRetryTask?.cancel()
        codex.openCodeModelsRetryTask = Task { @MainActor [weak codex] in
            let delaySeconds = UInt64(attempt + 2)
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let codex, codex.isConnected, codex.isInitialized else {
                codex?.openCodeModelsRetryTask = nil
                return
            }
            defer { codex.openCodeModelsRetryTask = nil }
            try? await codex.listModels()
        }
    }

    // MARK: - runtime/catalog

    func fetchRuntimeCatalog() async throws {
        let response = try await codex.sendRequest(
            method: "runtime/catalog",
            params: .object([:]),
            timeoutNanoseconds: RuntimeConfigLoadingPolicy.runtimeCatalogTimeoutNanoseconds,
            timeoutMessage: "runtime/catalog timed out"
        )

        guard let resultObject = response.result?.objectValue else {
            codex.debugRuntimeLog(
                "runtime/catalog missing payload; keeping \(codex.availableRuntimes.count) cached runtimes"
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
                    codex.debugRuntimeLog("capability decode fallback — bridge catalog capabilities could not be parsed; using defaultCodex. capsObj=\(capsObj)")
                    capabilities = ProviderCapabilities.defaultCodex
                }
            } else {
                capabilities = ProviderCapabilities.defaultCodex
            }

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

        codex.availableRuntimes = nextRuntimes
        codex.availableAgents = nextAgents

        if let codexRuntime = nextRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == "codex"
        }) {
            codex.supportsStructuredSkillInput = codexRuntime.capabilities.supportsStructuredSkillInput
        }

        codex.debugRuntimeLog(
            "runtime/catalog success runtimes=\(nextRuntimes.map(\.id).joined(separator: ","))"
        )
        noteOpenCodeCatalogRevisionAfterFetch()
    }

    func refreshRuntimeMetadataSequential() async {
        await refreshRuntimeMetadataParallel()
    }

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
        guard revision != codex.lastOpenCodeCatalogRevision else {
            return
        }
        if codex.lastOpenCodeCatalogRevision != nil {
            codex.debugRuntimeLog(
                "ios_catalog_revision_changed revision=\(revision) previous=\(codex.lastOpenCodeCatalogRevision ?? "nil")"
            )
        }
        codex.lastOpenCodeCatalogRevision = revision
    }

    // MARK: - Provider capabilities per turn

    func supportsStructuredSkillInput(forThreadId threadId: String?) -> Bool {
        providerCapabilitiesForTurn(threadId: threadId).supportsStructuredSkillInput
    }

    func supportsSkillFileInjection(forThreadId threadId: String?) -> Bool {
        providerCapabilitiesForTurn(threadId: threadId).supportsSkillFileInjection
    }

    func supportsImageAttachments(forThreadId threadId: String?) -> Bool {
        providerCapabilitiesForTurn(threadId: threadId).supportsImageAttachments
    }

    func providerCapabilitiesForTurn(threadId: String?) -> ProviderCapabilities {
        let provider = CodexModelOption.normalizedProvider(codex.runtimeModelProviderForTurn(threadId: threadId))
        if let model = codex.selectedModelOption(threadId: threadId),
           CodexModelOption.normalizedProvider(model.modelProvider) == provider {
            return model.capabilities
        }
        if codex.isRuntimeCapabilitiesLoadingForComposer(threadId: threadId) {
            if provider == "opencode", let catalogCapabilities = openCodeRuntimeCatalogEntry?.capabilities {
                return catalogCapabilities
            }
            if let runtime = codex.availableRuntimes.first(where: {
                CodexModelOption.normalizedProvider($0.id) == provider
            }) {
                return runtime.capabilities
            }
        }
        if provider == "opencode" {
            return openCodeRuntimeCatalogEntry?.capabilities ?? .defaultOpenCode
        }
        if let codexRuntime = codex.availableRuntimes.first(where: {
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

        let provider = CodexModelOption.normalizedProvider(codex.runtimeModelProviderForTurn(threadId: threadId))
        guard provider == "opencode" else {
            return true
        }

        return handoffEnvEnabled
    }

    private func handleModelListFailure(_ error: Error) {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.isEmpty ? "Unable to load models" : message
        setModelsErrorMessage(normalized, forProvider: "opencode")
        codex.debugRuntimeLog("model/list failed: \(normalized)")
    }
}

// Shared with CodexService+RuntimeConfig selection helpers.
enum RuntimeSelectionDefaults {
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
