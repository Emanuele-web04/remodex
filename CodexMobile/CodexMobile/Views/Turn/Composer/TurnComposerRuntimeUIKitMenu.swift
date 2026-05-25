// FILE: TurnComposerRuntimeUIKitMenu.swift
// Purpose: Builds the hierarchical UIKit menu for the composer runtime pill
//          (Model / Intelligence / Speed) consumed by UIKitMenuButton.
// Layer: View Helper
// Exports: TurnComposerRuntimeUIKitMenuBuilder
// Depends on: UIKit, TurnComposerRuntimeState, TurnComposerRuntimeActions,
//             TurnComposerMetaMapper, CodexModelOption, CodexServiceTier,
//             HapticFeedback
//
// Design notes
// ------------
// * Top-level menu has three submenus: Model, Intelligence, Speed. Each parent
//   carries `subtitle:` (current selection) so the row renders as the
//   "Label / Value / >" pill you see in the screenshot.
// * Submenus use `UIMenu.Options.singleSelection` so UIKit draws/clears the
//   checkmarks for us. We pass `.on` for the active item as a hint; UIKit
//   reconciles state when singleSelection is set.
// * Long model lists keep the existing "featured + Other models…" split so the
//   menu stays glanceable. The "Other models" action opens the existing
//   SwiftUI sheet via an injected callback.

import UIKit

enum TurnComposerRuntimeUIKitMenuBuilder {

    struct Input {
        let runtimeState: TurnComposerRuntimeState
        let runtimeActions: TurnComposerRuntimeActions
        let orderedModelOptions: [CodexModelOption]
        let selectedModelID: String?
        let selectedModelTitle: String
        let isLoadingModels: Bool
        let isRuntimeSelectionLoading: Bool
        let featuredModelIdentifiers: Set<String>
        let onRequestAllModelsSheet: () -> Void
    }

    static func makeMenu(_ input: Input) -> UIMenu {
        var children: [UIMenuElement] = []

        if let cursorModeMenu = cursorModeMenu(input) {
            children.append(cursorModeMenu)
        }
        if let providerMenu = providerMenu(input) {
            children.append(providerMenu)
        }
        children.append(modelMenu(input))
        if let openCodeAgentMenu = openCodeAgentMenu(input) {
            children.append(openCodeAgentMenu)
        }

        if let intelligenceMenu = intelligenceMenu(input) {
            children.append(intelligenceMenu)
        }

        if let speedMenu = speedMenu(input) {
            children.append(speedMenu)
        }

        return UIMenu(title: "", options: [.displayInline], children: children)
    }

    // MARK: - Cursor / Provider / Model / OpenCode agent

    private static func cursorModeMenu(_ input: Input) -> UIMenu? {
        guard input.runtimeState.selectedAgentRuntimeID == "cursor" else {
            return nil
        }

        let selectedModeID = input.runtimeState.selectedCursorModeID
        let selectedTitle = input.runtimeState.selectedCursorModeTitle
        let actions = CursorComposerModeOption.all.map { mode in
            UIAction(
                title: mode.displayName,
                state: mode.id == selectedModeID ? .on : .off
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                input.runtimeActions.selectCursorMode(mode.id)
            }
        }

        return UIMenu(
            title: "Mode",
            subtitle: selectedTitle,
            image: RemodexIcon.menuUIImage(systemName: "slider.horizontal.3"),
            options: [.singleSelection],
            children: actions
        )
    }

    private static func openCodeAgentMenu(_ input: Input) -> UIMenu? {
        guard input.runtimeState.selectedAgentRuntimeID == "opencode",
              input.runtimeState.openCodeAgentOptions.count > 1 else {
            return nil
        }

        let selectedAgentID = input.runtimeState.selectedOpenCodeBuildAgentID
        let selectedTitle = input.runtimeState.selectedOpenCodeBuildAgentTitle
        let actions = input.runtimeState.openCodeAgentOptions.map { agent in
            UIAction(
                title: agent.displayName,
                state: agent.id == selectedAgentID ? .on : .off
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                input.runtimeActions.selectOpenCodeBuildAgent(agent.id)
            }
        }

        return UIMenu(
            title: "Agent",
            subtitle: selectedTitle,
            image: RemodexIcon.menuUIImage(systemName: "person.crop.circle"),
            options: [.singleSelection],
            children: actions
        )
    }

    private static func providerMenu(_ input: Input) -> UIMenu? {
        let providers = providerOptions(input)
        guard providers.count > 1 else { return nil }

        let selectedProviderID = selectedProviderID(input)
        let selectedProviderName = providers.first(where: { $0.id == selectedProviderID })?.displayName
            ?? "Provider"
        let actions: [UIMenuElement] = providers.map { provider in
            UIAction(
                title: provider.modelCount > 0 ? "\(provider.displayName) (\(provider.modelCount))" : provider.displayName,
                state: provider.id == selectedProviderID ? .on : .off
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                input.runtimeActions.selectProvider(provider.id)
            }
        }

        return UIMenu(
            title: "Provider",
            subtitle: selectedProviderName,
            image: RemodexIcon.menuUIImage(systemName: "server.rack"),
            options: [.singleSelection],
            children: actions
        )
    }

    private static func modelMenu(_ input: Input) -> UIMenu {
        let subtitle: String
        if input.selectedModelID == nil {
            subtitle = input.isRuntimeSelectionLoading ? "Loading…" : "Select model"
        } else {
            subtitle = input.selectedModelTitle
        }

        let modelChildren: [UIMenuElement] = {
            if input.isLoadingModels {
                return [
                    disabledInfoAction(title: "Loading models…"),
                ]
            }
            if input.orderedModelOptions.isEmpty {
                return [
                    disabledInfoAction(title: "No models available"),
                ]
            }

            let visibleModels = modelsForSelectedProvider(input)
            let featured = featuredOrderedModels(input, models: visibleModels)
            var items: [UIMenuElement] = featured.map { model in
                modelAction(model: model, input: input)
            }

            let hasOthers = visibleModels.contains { model in
                !featured.contains(where: { $0.id == model.id })
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
        }()

        // singleSelection paints the checkmark on the `.on` child for us.
        return UIMenu(
            title: "Model",
            subtitle: subtitle,
            image: RemodexIcon.menuUIImage(systemName: "cube"),
            options: [.singleSelection],
            children: modelChildren
        )
    }

    private static func modelAction(model: CodexModelOption, input: Input) -> UIAction {
        let title = TurnComposerMetaMapper.modelTitle(for: model)
        let image: UIImage? = model.supportsServiceTier(.fast)
            ? UIImage(systemName: CodexServiceTier.fast.iconName)
            : nil

        return UIAction(
            title: title,
            image: image,
            state: model.id == input.selectedModelID ? .on : .off
        ) { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            input.runtimeActions.selectModel(model.id)
        }
    }

    private static func featuredOrderedModels(_ input: Input, models: [CodexModelOption]) -> [CodexModelOption] {
        var seen = Set<String>()
        var result: [CodexModelOption] = []

        for model in models {
            let normalizedID = model.id.lowercased()
            let normalizedModel = model.model.lowercased()
            let isFeatured = input.featuredModelIdentifiers.contains(normalizedID)
                || input.featuredModelIdentifiers.contains(normalizedModel)
                || providerOptions(input).count > 1
            guard isFeatured, seen.insert(model.id).inserted else { continue }
            result.append(model)
            if result.count >= 8 {
                break
            }
        }

        if let selectedID = input.selectedModelID,
           seen.insert(selectedID).inserted,
           let selected = models.first(where: { $0.id == selectedID }) {
            result.append(selected)
        }
        return result
    }

    private static func modelsForSelectedProvider(_ input: Input) -> [CodexModelOption] {
        let providers = providerOptions(input)
        guard providers.count > 1, let providerID = selectedProviderID(input) else {
            return input.orderedModelOptions
        }
        let filtered = input.orderedModelOptions.filter { $0.providerID == providerID }
        return filtered.isEmpty ? input.orderedModelOptions : filtered
    }

    private static func selectedProviderID(_ input: Input) -> String? {
        if let selectedID = input.selectedModelID,
           let selectedModel = input.orderedModelOptions.first(where: { $0.id == selectedID || $0.model == selectedID }),
           let providerID = selectedModel.providerID,
           !providerID.isEmpty {
            return providerID
        }
        return providerOptions(input).first(where: { $0.isDefault })?.id
            ?? providerOptions(input).first?.id
    }

    private static func providerOptions(_ input: Input) -> [RuntimeMenuProviderOption] {
        var providersByID: [String: RuntimeMenuProviderOption] = [:]
        var orderedProviderIDs: [String] = []
        for model in input.orderedModelOptions {
            guard let providerID = model.providerID, !providerID.isEmpty else {
                continue
            }
            if providersByID[providerID] == nil {
                providersByID[providerID] = RuntimeMenuProviderOption(
                    id: providerID,
                    displayName: model.providerDisplayName?.isEmpty == false ? model.providerDisplayName! : providerID,
                    modelCount: 0,
                    isDefault: model.isDefault
                )
                orderedProviderIDs.append(providerID)
            }
            if var provider = providersByID[providerID] {
                provider.modelCount += 1
                if model.isDefault {
                    provider.isDefault = true
                }
                providersByID[providerID] = provider
            }
        }
        return orderedProviderIDs.compactMap { providersByID[$0] }
    }

    // MARK: - Intelligence (reasoning effort)

    private static func intelligenceMenu(_ input: Input) -> UIMenu? {
        let options = input.runtimeState.reasoningDisplayOptions
        guard !options.isEmpty else { return nil }

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
        guard input.runtimeState.supportsFastMode else { return nil }

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
                // Keep the Fast tier on the native SF bolt to match the speed
                // badge in the composer; other tiers can use Central artwork.
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

    private static func disabledInfoAction(title: String) -> UIAction {
        let action = UIAction(title: title) { _ in }
        action.attributes.insert(.disabled)
        return action
    }
}

private struct RuntimeMenuProviderOption {
    let id: String
    var displayName: String
    var modelCount: Int
    var isDefault: Bool
}
