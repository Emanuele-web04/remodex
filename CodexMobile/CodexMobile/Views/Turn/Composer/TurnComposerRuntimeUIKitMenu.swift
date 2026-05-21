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

        children.append(modelMenu(input))

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

            return providerMenus(input)
        }()

        // singleSelection paints the checkmark on the `.on` child for us.
        return UIMenu(
            title: "Model",
            subtitle: subtitle,
            image: RemodexIcon.menuUIImage(systemName: "cube"),
            options: [],
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
            state: model.selectionKey == input.selectedModelID ? .on : .off
        ) { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            input.runtimeActions.selectModel(model.selectionKey)
        }
    }

    private static func providerMenus(_ input: Input) -> [UIMenuElement] {
        let grouped = Dictionary(grouping: input.orderedModelOptions, by: \.modelProvider)
        let providers = grouped.keys.sorted { lhs, rhs in
            providerRank(lhs) < providerRank(rhs)
        }

        return providers.compactMap { provider in
            guard let models = grouped[provider], !models.isEmpty else { return nil }
            return UIMenu(
                title: TurnComposerMetaMapper.providerTitle(for: provider),
                image: RemodexIcon.menuUIImage(systemName: TurnComposerMetaMapper.providerIconName(for: provider)),
                options: [.singleSelection],
                children: models.map { model in
                    modelAction(model: model, input: input)
                }
            )
        }
    }

    private static func providerRank(_ provider: String) -> Int {
        switch CodexModelOption.normalizedProvider(provider) {
        case "codex":
            return 0
        case "claude":
            return 1
        default:
            return 100
        }
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
