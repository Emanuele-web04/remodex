// FILE: UIKitMenuButton.swift
// Purpose: SwiftUI bridge to a UIKit UIButton + UIMenu so we can use hierarchical
//          UIKit menus (subtitle rows, nested submenus) without hitting SwiftUI's
//          long-standing nested-Menu bugs (stale checkmarks, dismissal glitches,
//          rebuild loops when a child Menu changes shape).
// Layer: View Component
// Exports: UIKitMenuButton
// Depends on: SwiftUI, UIKit
//
// Design notes
// ------------
// * The label is rendered with SwiftUI and OVERLAID by a transparent UIButton.
//   The SwiftUI view sizes the container; the button just acts as a tap target
//   anchored to the same rect, which is what the UIMenu presentation anchors to.
// * The button is hosted inside a dedicated `UIViewController` and bridged with
//   `UIViewControllerRepresentable`, NOT a bare `UIViewRepresentable`. UIKit's
//   menu presentation reparents an internal `_UIReparentingView` into the
//   nearest enclosing view; if our button sits inside a `UIViewRepresentable`
//   that view is `UIHostingController.view`, which Apple explicitly flags as
//   unsupported. Giving the button its own VC makes UIKit anchor reparenting
//   to that VC's view instead.
// * The menu is wired through a single `UIDeferredMenuElement.uncached` so the
//   children are rebuilt on every open. This is required for fresh checkmark
//   state and current "subtitle" values without manually reassigning `.menu`.
// * A `Coordinator` holds the latest menu-builder closure. SwiftUI recreates the
//   representable struct on every body re-eval, but `makeUIViewController` runs
//   once, so any closure captured there goes stale. `updateUIViewController`
//   writes the freshest closure into the coordinator, and the deferred element
//   reads it back at menu-open time. Without this indirection the menu freezes
//   on first-render state forever.
// * `sizeThatFits` returns the proposed size so the backer fills the overlay
//   rather than collapsing to its intrinsic 0x0.

import SwiftUI
import UIKit

struct UIKitMenuButton<Label: View>: View {
    private let menu: () -> UIMenu
    private let onWillPresent: (() -> Void)?
    private let label: Label

    init(
        @ViewBuilder label: () -> Label,
        onWillPresent: (() -> Void)? = nil,
        menu: @escaping () -> UIMenu
    ) {
        self.label = label()
        self.menu = menu
        self.onWillPresent = onWillPresent
    }

    var body: some View {
        label
            .overlay {
                UIKitMenuButtonBacker(menu: menu, onWillPresent: onWillPresent)
            }
            // Promote the label + backer pair to a single accessibility element
            // with the button trait so VoiceOver reads the label text and can
            // activate the underlying UIButton (which presents the UIMenu).
            // Hiding the backer entirely loses the only menu activation path.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - UIKit backer

private struct UIKitMenuButtonBacker: UIViewControllerRepresentable {
    let menu: () -> UIMenu
    let onWillPresent: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(menu: menu, onWillPresent: onWillPresent)
    }

    func makeUIViewController(context: Context) -> MenuButtonHostController {
        let controller = MenuButtonHostController()
        let button = controller.button

        let coordinator = context.coordinator
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                completion(AppMenuPresentation.style(coordinator.menu()).children)
            },
        ])

        button.addAction(
            UIAction { [weak coordinator] _ in
                coordinator?.onWillPresent?()
            },
            for: .menuActionTriggered
        )

        return controller
    }

    func updateUIViewController(_ uiViewController: MenuButtonHostController, context: Context) {
        context.coordinator.menu = menu
        context.coordinator.onWillPresent = onWillPresent
    }

    // The overlay would otherwise collapse to UIButton's intrinsic (0x0) size,
    // making only the dead center of the label tappable. Returning the proposed
    // size makes the invisible button fill the overlay slot exactly.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: MenuButtonHostController,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? UIView.noIntrinsicMetric,
            height: proposal.height ?? UIView.noIntrinsicMetric
        )
    }

    final class Coordinator {
        var menu: () -> UIMenu
        var onWillPresent: (() -> Void)?

        init(menu: @escaping () -> UIMenu, onWillPresent: (() -> Void)?) {
            self.menu = menu
            self.onWillPresent = onWillPresent
        }
    }
}

// MARK: - Hosting controller

// Dedicated container so UIKit's menu presentation reparents `_UIReparentingView`
// into THIS controller's view rather than the outer `UIHostingController.view`.
final class MenuButtonHostController: UIViewController {
    let button = UIButton(type: .custom)

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .clear
        container.isOpaque = false
        view = container

        button.showsMenuAsPrimaryAction = true
        button.backgroundColor = .clear
        button.setTitle(nil, for: .normal)
        button.setImage(nil, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
