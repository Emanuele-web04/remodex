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
// * Intelligence (reasoning effort) is surfaced inline at the top of the menu
//   so every level is directly selectable without drilling into a submenu. It
//   is a `.displayInline` group whose `title` renders as the "Intelligence"
//   section header, followed by Model and Speed as "Label / Value / >" submenus.
// * Model and Speed submenus carry `subtitle:` (current selection) so the row
//   renders as the "Label / Value / >" pill you see in the screenshot.
// * Menus use `UIMenu.Options.singleSelection` so UIKit draws/clears the
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
        // The pill lives in the composer bottom bar, so UIKit anchors the menu
        // above the button and lays it out in `.priority` order: the first child
        // renders closest to the button (at the BOTTOM), so the array is
        // effectively reversed on screen. Author the children in reverse of the
        // desired top-to-bottom order — Speed, Model, Intelligence — so the menu
        // reads Intelligence → Model → Speed from the top.
        var children: [UIMenuElement] = []

        if let speedMenu = speedMenu(input) {
            children.append(speedMenu)
        }

        children.append(modelMenu(input))

        if let intelligenceMenu = intelligenceMenu(input) {
            children.append(intelligenceMenu)
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

            let featured = featuredOrderedModels(input)
            var items: [UIMenuElement] = featured.map { model in
                modelAction(model: model, input: input)
            }

            let hasOthers = input.orderedModelOptions.contains { model in
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
            ? RemodexIcon.menuUIImage(systemName: CodexServiceTier.fast.iconName)
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

    private static func featuredOrderedModels(_ input: Input) -> [CodexModelOption] {
        var seen = Set<String>()
        var result: [CodexModelOption] = []

        for model in input.orderedModelOptions {
            let normalizedID = model.id.lowercased()
            let normalizedModel = model.model.lowercased()
            let isFeatured = input.featuredModelIdentifiers.contains(normalizedID)
                || input.featuredModelIdentifiers.contains(normalizedModel)
            guard isFeatured, seen.insert(model.id).inserted else { continue }
            result.append(model)
        }

        if let selectedID = input.selectedModelID,
           seen.insert(selectedID).inserted,
           let selected = input.orderedModelOptions.first(where: { $0.id == selectedID }) {
            result.append(selected)
        }
        return result
    }

    // MARK: - Intelligence (reasoning effort)

    // Surfaced inline (not a submenu) so the reasoning levels are selectable
    // directly from the top of the runtime menu. The inline group's title
    // renders as the "Intelligence" section header above the options.
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
            options: [.displayInline, .singleSelection],
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
                image: RemodexIcon.menuUIImage(systemName: tier.iconName),
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
            image: RemodexIcon.menuUIImage(systemName: "bolt.fill"),
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
