// FILE: TurnComposerRuntimeState.swift
// Purpose: Bundles the composer runtime selection state shared by the bottom bar and input context menu.
// Layer: View Helper
// Exports: TurnComposerRuntimeState, AgentOption
// Depends on: CodexService, TurnComposerMetaMapper, CodexServiceTier, OpenCodeCatalogProvider

import Foundation

struct AgentOption: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let displayName: String

    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

struct TurnComposerRuntimeState: Equatable {
    let reasoningDisplayOptions: [TurnComposerReasoningDisplayOption]
    let effectiveReasoningEffort: String?
    let selectedReasoningEffort: String?
    let reasoningMenuDisabled: Bool
    let selectedServiceTier: CodexServiceTier?
    let capabilities: ProviderCapabilities
    let availableAgents: [AgentOption]
    let selectedAgent: String?
    let isRuntimeEnabled: Bool
    let runtimeUnavailableReason: String?
    let runtimeUnavailableReasonCode: String?
    let disabledProviderIDs: Set<String>
    let catalogProviderIDs: [String]
    let openCodeCatalogProviders: [OpenCodeCatalogProvider]
    let unavailableReasonByProviderID: [String: String]
    let reasonCodeByProviderID: [String: String]
    let showsBetaLabel: Bool
    let showsComposerAccessMode: Bool

    var selectedReasoningTitle: String {
        effectiveReasoningEffort.map(TurnComposerMetaMapper.reasoningTitle(for:)) ?? "Select reasoning"
    }

    var showsSpeedBadgeInModelMenu: Bool {
        capabilities.supportsFastMode && selectedServiceTier != nil
    }

    func isSelectedReasoning(_ effort: String) -> Bool {
        (selectedReasoningEffort ?? effectiveReasoningEffort) == effort
    }

    func isSelectedServiceTier(_ serviceTier: CodexServiceTier?) -> Bool {
        selectedServiceTier == serviceTier
    }

    static func resolve(
        codex: CodexService,
        threadId: String? = nil,
        reasoningDisplayOptions: [TurnComposerReasoningDisplayOption]
    ) -> TurnComposerRuntimeState {
        let selectedModel = codex.selectedModelOption(threadId: threadId)
        let threadOverride = codex.threadRuntimeOverride(for: threadId)
        let capabilities = selectedModel?.capabilities
        let currentProviderId = CodexModelOption.normalizedProvider(selectedModel?.modelProvider ?? "codex")
        let runtimeInfo = codex.availableRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == currentProviderId
        })
        let isRuntimeEnabled = runtimeInfo?.enabled ?? true
        let runtimeUnavailableReason = runtimeInfo?.unavailableReason
        let runtimeUnavailableReasonCode = runtimeInfo?.reasonCode
        let resolvedCapabilities = capabilities ?? runtimeInfo?.capabilities ?? ProviderCapabilities.defaultCodex
        let disabledProviderIDs = Set(
            codex.availableRuntimes
                .filter { !$0.enabled }
                .map { CodexModelOption.normalizedProvider($0.id) }
        )
        let catalogProviderIDs = codex.menuCatalogProviderIDs
        let openCodeCatalogProviders = codex.openCodeCatalogProviders
        let unavailableReasonByProviderID: [String: String] = codex.availableRuntimes
            .filter { !$0.enabled }
            .reduce(into: [:]) { dict, runtime in
                let providerID = CodexModelOption.normalizedProvider(runtime.id)
                dict[providerID] = runtime.unavailableReason ?? ""
            }
        let reasonCodeByProviderID: [String: String] = codex.availableRuntimes
            .filter { !$0.enabled }
            .reduce(into: [:]) { dict, runtime in
                let providerID = CodexModelOption.normalizedProvider(runtime.id)
                if let code = runtime.reasonCode {
                    dict[providerID] = code
                }
            }
        return TurnComposerRuntimeState(
            reasoningDisplayOptions: reasoningDisplayOptions,
            effectiveReasoningEffort: codex.selectedReasoningEffortForSelectedModel(threadId: threadId),
            selectedReasoningEffort: threadOverride?.overridesReasoning == true
                ? threadOverride?.reasoningEffort
                : codex.selectedReasoningEffort,
            reasoningMenuDisabled: reasoningDisplayOptions.isEmpty || selectedModel == nil,
            selectedServiceTier: codex.effectiveServiceTier(for: threadId),
            capabilities: resolvedCapabilities,
            availableAgents: codex.availableAgents,
            selectedAgent: codex.effectiveOpenCodeAgent(threadId: threadId),
            isRuntimeEnabled: isRuntimeEnabled,
            runtimeUnavailableReason: runtimeUnavailableReason,
            runtimeUnavailableReasonCode: runtimeUnavailableReasonCode,
            disabledProviderIDs: disabledProviderIDs,
            catalogProviderIDs: catalogProviderIDs,
            openCodeCatalogProviders: openCodeCatalogProviders,
            unavailableReasonByProviderID: unavailableReasonByProviderID,
            reasonCodeByProviderID: reasonCodeByProviderID,
            showsBetaLabel: codex.showsBetaLabel(forProvider: currentProviderId),
            showsComposerAccessMode: resolvedCapabilities.supportsAccessMode
        )
    }
}
