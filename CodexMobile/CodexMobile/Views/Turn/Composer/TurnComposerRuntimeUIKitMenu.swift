// FILE: TurnComposerRuntimeUIKitMenu.swift
// Purpose: Builds the UIKit model-picker menu opened from the runtime slider
//          overlay's model label. Intelligence lives on the overlay's effort
//          slider and Speed on its bolt toggle, so the menu is model-only.
// Layer: View Helper
// Exports: TurnComposerRuntimeUIKitMenuBuilder
// Depends on: UIKit, TurnComposerRuntimeActions, TurnComposerMetaMapper,
//             CodexModelOption, CodexServiceTier, HapticFeedback
//
// Design notes
// ------------
// * Long model lists keep the existing "featured + Other models…" split so the
//   menu stays glanceable. The "Other models" action opens the existing
//   SwiftUI sheet via an injected callback.
// * `UIAction.state` paints the checkmark on the selected model; the root
//   menu's options are dropped by `UIKitMenuButton`'s deferred wrapper, so no
//   `.singleSelection` is relied upon here.

import UIKit

enum TurnComposerRuntimeUIKitMenuBuilder {

    struct Input {
        let runtimeActions: TurnComposerRuntimeActions
        let orderedModelOptions: [CodexModelOption]
        let selectedModelID: String?
        let isLoadingModels: Bool
        let onRequestAllModelsSheet: () -> Void
    }

    // Identifiers pinned to the top of the model menu; the rest are reachable
    // via "Other models…" so the menu stays glanceable as the list grows.
    private static let featuredModelIdentifiers: Set<String> = [
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.5",
        "gpt-5.4",
    ]

    static func makeModelMenu(_ input: Input) -> UIMenu {
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

        return UIMenu(title: "", children: modelChildren)
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
            let isFeatured = featuredModelIdentifiers.contains(normalizedID)
                || featuredModelIdentifiers.contains(normalizedModel)
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

    // MARK: - Helpers

    private static func disabledInfoAction(title: String) -> UIAction {
        let action = UIAction(title: title) { _ in }
        action.attributes.insert(.disabled)
        return action
    }
}
