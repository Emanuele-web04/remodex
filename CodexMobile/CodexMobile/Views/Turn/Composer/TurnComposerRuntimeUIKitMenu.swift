// FILE: TurnComposerRuntimeUIKitMenu.swift
// Purpose: Builds the hierarchical UIKit menu for the composer runtime pill
//          (Model / Intelligence / Speed) consumed by UIKitMenuButton.
// Layer: View Helper
// Exports: TurnComposerRuntimeUIKitMenuBuilder
// Depends on: UIKit, TurnComposerRuntimeState, TurnComposerRuntimeActions,
//             TurnComposerMetaMapper, CodexModelOption, CodexServiceTier,
//             HapticFeedback, ComposerCapabilityCopy, OpenCodeCatalogProvider (catalog logo resolver)

import UIKit

enum TurnComposerRuntimeUIKitMenuBuilder {

    struct Input {
        let runtimeState: TurnComposerRuntimeState
        let runtimeActions: TurnComposerRuntimeActions
        let orderedModelOptions: [CodexModelOption]
        let selectedModelID: String?
        let selectedModelTitle: String
        let isLoadingModels: Bool
        let isLoadingOpenCodeProvider: Bool
        let isRuntimeSelectionLoading: Bool
        let modelsErrorMessage: String?
        let openCodeProviderDiscoveryReasonCode: String?
        let openCodeCatalogProviders: [OpenCodeCatalogProvider]
        let featuredModelIdentifiers: Set<String>
        let onRequestAllModelsSheet: () -> Void
    }

    static func makeMenu(_ input: Input) -> UIMenu {
        var children: [UIMenuElement] = []

        children.append(modelMenu(input))

        if let agentMenu = agentMenu(input) {
            children.append(agentMenu)
        }

        if let intelligenceMenu = intelligenceMenu(input) {
            children.append(intelligenceMenu)
        }

        if let speedMenu = speedMenu(input) {
            children.append(speedMenu)
        }

        return UIMenu(title: "", options: [.displayInline], children: children)
    }

    // MARK: - Model

    private static func modelMenu(_ input: Input) -> UIMenu {
        let subtitle: String
        if input.selectedModelID == nil {
            subtitle = input.isRuntimeSelectionLoading ? "Loading..." : "Select model"
        } else {
            subtitle = input.selectedModelTitle
        }

        let modelChildren: [UIMenuElement] = {
            if input.openCodeProviderDiscoveryReasonCode == "no_connected_providers" {
                return modelMenuChildrenWithOptionalBrowse([
                    disabledInfoAction(title: "No providers connected on your Mac"),
                    disabledInfoAction(title: "Connect providers in OpenCode on your Mac, then tap Retry"),
                    UIAction(title: "Retry loading models") { _ in
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        input.runtimeActions.refreshModels()
                    },
                ], input: input)
            }
            if input.isLoadingOpenCodeProvider,
               input.openCodeProviderDiscoveryReasonCode == nil {
                return modelMenuChildrenWithOptionalBrowse([
                    disabledInfoAction(title: "OpenCode models are still loading"),
                ], input: input)
            }
            if input.isLoadingModels {
                return modelMenuChildrenWithOptionalBrowse([
                    disabledInfoAction(title: "Loading models..."),
                ], input: input)
            }
            if input.orderedModelOptions.isEmpty {
                if let errorMessage = input.modelsErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !errorMessage.isEmpty {
                    return modelMenuChildrenWithOptionalBrowse([
                        disabledInfoAction(title: errorMessage),
                        UIAction(title: "Retry loading models") { _ in
                            HapticFeedback.shared.triggerImpactFeedback(style: .light)
                            input.runtimeActions.refreshModels()
                        },
                    ], input: input)
                }
                return modelMenuChildrenWithOptionalBrowse([
                    disabledInfoAction(title: "No models available"),
                    UIAction(title: "Retry loading models") { _ in
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        input.runtimeActions.refreshModels()
                    },
                ], input: input)
            }

            return providerMenus(input)
        }()

        return UIMenu(
            title: "Model",
            subtitle: subtitle,
            image: RemodexIcon.menuUIImage(systemName: "cube"),
            options: [],
            children: modelChildren
        )
    }

    private static func composerMenuLogoProvider(
        for models: [CodexModelOption],
        fallback: String
    ) -> String {
        models.first?.composerLogoProviderId ?? fallback
    }

    private static func modelAction(model: CodexModelOption, input: Input) -> UIAction {
        let title = TurnComposerMetaMapper.modelTitle(for: model)
        let image: UIImage? = model.supportsServiceTier(.fast)
            ? UIImage(systemName: CodexServiceTier.fast.iconName)
            : nil

        return UIAction(
            title: title,
            image: image,
            state: model.selectionKey == input.selectedModelID ? .on : .off
        ) { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            input.runtimeActions.selectModel(model.selectionKey)
        }
    }

    private static func providerMenus(_ input: Input) -> [UIMenuElement] {
        let grouped = Dictionary(grouping: input.orderedModelOptions, by: \.modelProvider)
        var providerIDs = input.runtimeState.catalogProviderIDs
        for provider in grouped.keys {
            let normalized = CodexModelOption.normalizedProvider(provider)
            if !providerIDs.contains(normalized) {
                providerIDs.append(normalized)
            }
        }

        providerIDs.sort { lhs, rhs in
            let lhsRank = providerRank(lhs)
            let rhsRank = providerRank(rhs)
            if lhsRank == rhsRank {
                return TurnComposerMetaMapper.providerTitle(for: lhs)
                    < TurnComposerMetaMapper.providerTitle(for: rhs)
            }
            return lhsRank < rhsRank
        }

        return providerIDs.compactMap { provider in
            let normalizedProvider = CodexModelOption.normalizedProvider(provider)
            let models = grouped[provider] ?? grouped[normalizedProvider] ?? []
            let providerTitle = TurnComposerMetaMapper.providerTitle(for: provider)
            let inCatalog = input.runtimeState.catalogProviderIDs.contains(normalizedProvider)

            if models.isEmpty {
                guard inCatalog else { return nil }
                return catalogOnlyProviderMenu(
                    provider: provider,
                    normalizedProvider: normalizedProvider,
                    providerTitle: providerTitle,
                    input: input
                )
            }

            if input.runtimeState.disabledProviderIDs.contains(normalizedProvider) {
                let rawReason = input.runtimeState.unavailableReasonByProviderID[normalizedProvider]
                let reasonCode = input.runtimeState.reasonCodeByProviderID[normalizedProvider]
                let unavailable = ComposerCapabilityCopy.runtimeUnavailableMessage(rawReason, reasonCode: reasonCode)
                return UIMenu(
                    title: providerTitle,
                    image: RuntimeProviderLogo.menuUIImage(
                        provider: normalizedProvider == "opencode" ? "opencode" : composerMenuLogoProvider(for: models, fallback: provider),
                        catalogProviders: input.openCodeCatalogProviders
                    ),
                    options: [],
                    children: [disabledInfoAction(title: unavailable.title)]
                )
            }

            if normalizedProvider == "opencode" {
                return openCodeRuntimeMenu(
                    providerTitle: providerTitle,
                    models: models,
                    input: input
                )
            }

            return UIMenu(
                title: providerTitle,
                image: RuntimeProviderLogo.menuUIImage(provider: provider, catalogProviders: input.openCodeCatalogProviders),
                options: [.singleSelection],
                children: featuredProviderModelItems(models: models, input: input)
            )
        }
    }

    // Long model lists keep the "featured + Other models…" split so the menu
    // stays glanceable. The "Other models" action opens the all-models sheet.
    private static func featuredProviderModelItems(
        models: [CodexModelOption],
        input: Input
    ) -> [UIMenuElement] {
        let featured = featuredOrderedModels(models, input: input)
        guard !featured.isEmpty else {
            return models.map { modelAction(model: $0, input: input) }
        }

        var items: [UIMenuElement] = featured.map { model in
            modelAction(model: model, input: input)
        }

        let hasOthers = models.contains { model in
            !featured.contains(where: { $0.selectionKey == model.selectionKey })
        }
        if hasOthers {
            items.append(
                UIAction(
                    title: "Other models…",
                    image: RemodexIcon.menuUIImage(systemName: "ellipsis")
                ) { _ in
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    input.onRequestAllModelsSheet()
                }
            )
        }
        return items
    }

    private static func featuredOrderedModels(
        _ models: [CodexModelOption],
        input: Input
    ) -> [CodexModelOption] {
        var seen = Set<String>()
        var result: [CodexModelOption] = []

        for model in models {
            let normalizedID = model.id.lowercased()
            let normalizedModel = model.model.lowercased()
            let isFeatured = input.featuredModelIdentifiers.contains(normalizedID)
                || input.featuredModelIdentifiers.contains(normalizedModel)
            guard isFeatured, seen.insert(model.selectionKey).inserted else { continue }
            result.append(model)
        }

        if let selectedID = input.selectedModelID,
           seen.insert(selectedID).inserted,
           let selected = models.first(where: { $0.selectionKey == selectedID }) {
            result.append(selected)
        }
        return result
    }

    private static func catalogOnlyProviderMenu(
        provider: String,
        normalizedProvider: String,
        providerTitle: String,
        input: Input
    ) -> UIMenu? {
        if input.runtimeState.disabledProviderIDs.contains(normalizedProvider) {
            let rawReason = input.runtimeState.unavailableReasonByProviderID[normalizedProvider]
            let reasonCode = input.runtimeState.reasonCodeByProviderID[normalizedProvider]
            let unavailable = ComposerCapabilityCopy.runtimeUnavailableMessage(rawReason, reasonCode: reasonCode)
            return UIMenu(
                title: providerTitle,
                image: RuntimeProviderLogo.menuUIImage(provider: provider, catalogProviders: input.openCodeCatalogProviders),
                options: [],
                children: [disabledInfoAction(title: unavailable.title)]
            )
        }

        let statusTitle: String = {
            if normalizedProvider == "opencode",
               input.openCodeProviderDiscoveryReasonCode == "no_connected_providers" {
                return "No providers connected on your Mac"
            }
            if normalizedProvider == "opencode",
               input.openCodeProviderDiscoveryReasonCode == "provider_list_failed" {
                return input.modelsErrorMessage ?? "OpenCode provider list failed"
            }
            if normalizedProvider == "opencode", input.isLoadingOpenCodeProvider,
               input.openCodeProviderDiscoveryReasonCode == nil {
                return "OpenCode models are still loading"
            }
            if normalizedProvider == "opencode",
               let errorMessage = input.modelsErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               !errorMessage.isEmpty {
                return errorMessage
            }
            if normalizedProvider == "opencode" {
                return "OpenCode models are still loading"
            }
            if input.isLoadingModels {
                return "Loading models..."
            }
            return "No models available"
        }()

        var children: [UIMenuElement] = [
            disabledInfoAction(title: statusTitle),
            UIAction(title: "Retry loading models") { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                input.runtimeActions.refreshModels()
            },
        ]
        if normalizedProvider == "opencode" {
            children.append(browseAllModelsAction(input))
        }

        return UIMenu(
            title: providerTitle,
            image: RuntimeProviderLogo.menuUIImage(provider: provider, catalogProviders: input.openCodeCatalogProviders),
            options: [],
            children: children
        )
    }

    private static func openCodeRuntimeMenu(
        providerTitle: String,
        models: [CodexModelOption],
        input: Input
    ) -> UIMenu {
        let upstreamGroups = TurnComposerMetaMapper.openCodeModelsGroupedByUpstream(models)
        if upstreamGroups.isEmpty {
            var flatChildren: [UIMenuElement] = models.map { modelAction(model: $0, input: input) }
            flatChildren.append(browseAllModelsAction(input))
            return UIMenu(
                title: providerTitle,
                image: RuntimeProviderLogo.menuUIImage(provider: "opencode", catalogProviders: input.openCodeCatalogProviders),
                options: [],
                children: flatChildren
            )
        }

        let groupedIds = Set(upstreamGroups.map(\.upstreamId))
        let ungrouped = models.filter { model in
            let upstream = model.upstreamProviderId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return upstream.isEmpty || !groupedIds.contains(upstream)
        }

        var children: [UIMenuElement] = upstreamGroups.map { group in
            UIMenu(
                title: group.title,
                image: RuntimeProviderLogo.menuUIImage(
                    provider: composerMenuLogoProvider(for: group.models, fallback: group.upstreamId),
                    catalogProviders: input.openCodeCatalogProviders
                ),
                options: [.singleSelection],
                children: group.models.map { modelAction(model: $0, input: input) }
            )
        }

        if !ungrouped.isEmpty {
            children.append(contentsOf: ungrouped.map { modelAction(model: $0, input: input) })
        }

        children.append(browseAllModelsAction(input))

        return UIMenu(
            title: providerTitle,
            image: RuntimeProviderLogo.menuUIImage(provider: "opencode", catalogProviders: input.openCodeCatalogProviders),
            options: [],
            children: children
        )
    }

    private static func providerRank(_ provider: String) -> Int {
        switch CodexModelOption.normalizedProvider(provider) {
        case "codex":
            return 0
        case "opencode":
            return 1
        case "claude":
            return 2
        default:
            return 100
        }
    }

    // MARK: - Agent

    private static func agentMenu(_ input: Input) -> UIMenu? {
        guard input.runtimeState.capabilities.supportsAgentSelection else { return nil }

        let agents = input.runtimeState.availableAgents
        guard !agents.isEmpty else {
            return disabledSubmenu(
                title: "Agent",
                subtitle: "Unavailable",
                image: RemodexIcon.menuUIImage(systemName: "person.and.arrow.left.and.arrow.right"),
                reason: ComposerCapabilityCopy.capabilityReasonWhenAgentSelectionUnavailable(
                    capabilities: input.runtimeState.capabilities
                )
            )
        }

        let selectedId = input.runtimeState.selectedAgent ?? agents.first?.id
        let actions: [UIMenuElement] = agents.map { agent in
            UIAction(
                title: agent.displayName,
                state: agent.id == selectedId ? .on : .off
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                input.runtimeActions.selectAgent(agent.id)
            }
        }

        let subtitle = agents.first(where: { $0.id == selectedId })?.displayName
            ?? agents.first?.displayName

        return UIMenu(
            title: "Agent",
            subtitle: subtitle,
            image: RemodexIcon.menuUIImage(systemName: "person.and.arrow.left.and.arrow.right"),
            options: [.singleSelection],
            children: actions
        )
    }

    private static func intelligenceMenu(_ input: Input) -> UIMenu? {
        let options = input.runtimeState.reasoningDisplayOptions
        if options.isEmpty {
            if input.runtimeState.capabilities.supportsReasoningEffort {
                return disabledSubmenu(
                    title: "Intelligence",
                    subtitle: "Unavailable",
                    image: RemodexIcon.menuUIImage(systemName: "brain"),
                    reason: ComposerCapabilityCopy.capabilityReason(for: .reasoningEffort)
                )
            }
            return nil
        }

        let actions: [UIMenuElement] = options.map { option in
            let action = UIAction(
                title: option.title,
                state: input.runtimeState.isSelectedReasoning(option.effort) ? .on : .off
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                input.runtimeActions.selectReasoning(option.effort)
            }
            if input.runtimeState.reasoningMenuDisabled {
                action.attributes.insert(.disabled)
            }
            return action
        }

        return UIMenu(
            title: "Intelligence",
            subtitle: input.runtimeState.selectedReasoningTitle,
            image: RemodexIcon.menuUIImage(systemName: "brain"),
            options: [.singleSelection],
            children: actions
        )
    }

    // MARK: - Speed

    private static func speedMenu(_ input: Input) -> UIMenu? {
        guard input.selectedModelID != nil else { return nil }

        let selectedModelCapabilities = modelCapabilitiesForSelectedModel(input)
        guard input.runtimeState.capabilities.supportsFastMode else {
            return nil
        }
        guard selectedModelCapabilities?.supportsFastMode ?? false else {
            return nil
        }

        let normalAction = UIAction(
            title: "Normal",
            state: input.runtimeState.isSelectedServiceTier(nil) ? .on : .off
        ) { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            input.runtimeActions.selectServiceTier(nil)
        }

        let tierActions: [UIMenuElement] = CodexServiceTier.allCases.map { tier in
            UIAction(
                title: tier.displayName,
                image: tier == .fast
                    ? UIImage(systemName: tier.iconName)
                    : RemodexIcon.menuUIImage(systemName: tier.iconName),
                state: input.runtimeState.isSelectedServiceTier(tier) ? .on : .off
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                input.runtimeActions.selectServiceTier(tier)
            }
        }

        let subtitle: String = {
            if let tier = input.runtimeState.selectedServiceTier {
                return tier.displayName
            }
            return "Normal"
        }()

        return UIMenu(
            title: "Speed",
            subtitle: subtitle,
            image: UIImage(systemName: "bolt.fill"),
            options: [.singleSelection],
            children: [normalAction] + tierActions
        )
    }

    // MARK: - Helpers

    private static func modelCapabilitiesForSelectedModel(_ input: Input) -> ProviderCapabilities? {
        guard let selectedModelID = input.selectedModelID else { return nil }
        let (provider, modelId) = CodexModelOption.splitSelectionKey(selectedModelID)
        return input.orderedModelOptions.first(where: { option in
            option.modelProvider == provider && option.id == (modelId ?? option.id)
        })?.capabilities
    }

    private static func disabledSubmenu(
        title: String,
        subtitle: String,
        image: UIImage?,
        reason: String
    ) -> UIMenu {
        let action = disabledInfoAction(title: reason)
        return UIMenu(
            title: title,
            subtitle: subtitle,
            image: image,
            options: [],
            children: [action]
        )
    }

    private static func disabledInfoAction(title: String) -> UIAction {
        let action = UIAction(title: title) { _ in }
        action.attributes.insert(.disabled)
        return action
    }

    private static func shouldOfferBrowseAllModels(_ input: Input) -> Bool {
        input.runtimeState.catalogProviderIDs.contains("opencode")
            || input.openCodeProviderDiscoveryReasonCode != nil
            || input.isLoadingOpenCodeProvider
    }

    private static func modelMenuChildrenWithOptionalBrowse(
        _ children: [UIMenuElement],
        input: Input
    ) -> [UIMenuElement] {
        guard shouldOfferBrowseAllModels(input) else { return children }
        var result = children
        result.append(browseAllModelsAction(input))
        return result
    }

    private static func browseAllModelsAction(_ input: Input) -> UIAction {
        UIAction(title: "Browse all models…") { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            input.runtimeActions.browseAllModels()
        }
    }
}
