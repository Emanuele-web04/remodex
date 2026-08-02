// FILE: UIKitContextMenu.swift
// Purpose: Bridges SwiftUI's `.contextMenu` to `UIContextMenuInteraction`
//          so menu rows can use UIKit's `UIMenu`/`UIAction(image:)` API.
//          That matters because SwiftUI's native context menu renderer does
//          not give `Label(_, image:)` (Central bundle assets) the same
//          "menu glyph" sizing it gives `Label(_, systemImage:)` — the
//          custom artwork ends up visually larger than the SF Symbols in
//          the same column. Routing the menu through UIKit lets us hand
//          UIMenu a `UIImage` that we pre-render at the SF Symbol menu
//          metric via `RemodexIcon.menuUIImage(systemName:)`, restoring
//          per-row visual parity.
//
// Layer: View Component (shared)
// Exports: View.uiKitContextMenu(_:)
// Depends on: SwiftUI, UIKit
//
// Design notes
// ------------
// * The bridge wraps the modified view in a `UIHostingController` so the
//   `UIContextMenuInteraction` has a real, ancestor `UIView` to attach
//   itself to. SwiftUI does not expose the underlying host view of an
//   arbitrary modifier, and `.overlay` / `.background` views are siblings
//   (not ancestors) of the modified content's UIKit representation, so a
//   `UIContextMenuInteraction` attached there would not see the long-press
//   touches that hit the SwiftUI content.
// * SwiftUI environment values (incl. `@Environment(SomeObservable.self)`)
//   do NOT auto-propagate across a `UIHostingController` boundary that we
//   build ourselves. Callers that need access to environment-injected
//   services inside the wrapped content must re-inject them explicitly at
//   the call site, e.g. `SidebarThreadRowView(...).environment(codex)`.
// * The menu closure is invoked on every long-press via the coordinator,
//   so subtitles / checkmarks / availability stay fresh between opens.

import SwiftUI
import UIKit

extension View {
    /// Attach a UIKit-rendered context menu to this view. Use instead of
    /// SwiftUI's `.contextMenu { ... }` when the menu contains Central
    /// custom artwork, so the icons render at the SF Symbol menu glyph
    /// metric (see `RemodexIcon.menuUIImage`).
    ///
    /// The closure is invoked every time the menu opens; build a fresh
    /// `UIMenu` inside it so subtitles and checkmark state stay current.
    func uiKitContextMenu(_ menu: @escaping () -> UIMenu) -> some View {
        UIKitContextMenuHost(content: self, menu: menu)
    }
}

// MARK: - Host

private struct UIKitContextMenuHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let menu: () -> UIMenu

    func makeCoordinator() -> Coordinator {
        Coordinator(menu: menu)
    }

    func makeUIViewController(context: Context) -> ContextMenuHostController<Content> {
        let host = ContextMenuHostController(rootView: content)
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        host.view.addInteraction(interaction)
        return host
    }

    func updateUIViewController(_ host: ContextMenuHostController<Content>, context: Context) {
        host.rootView = content
        context.coordinator.menu = menu
    }

    // Forward SwiftUI's proposed size into the hosted SwiftUI view so the
    // wrapped row gets the same width/height it would have rendered at
    // without the bridge. Without this, the host collapses to its
    // intrinsic content size and breaks list-row layout (truncated tail
    // metadata, lost flexible width).
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: ContextMenuHostController<Content>,
        context: Context
    ) -> CGSize? {
        let target = CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        )
        return uiViewController.sizeThatFits(in: target)
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var menu: () -> UIMenu

        init(menu: @escaping () -> UIMenu) {
            self.menu = menu
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            // Capture the latest builder closure each time the menu opens
            // so live state (current subtitle, checkmarks, …) is reflected.
            let builder = self.menu
            return UIContextMenuConfiguration(
                identifier: nil,
                previewProvider: nil
            ) { _ in
                AppMenuPresentation.style(builder())
            }
        }
    }
}

// MARK: - Hosting controller

// Subclass exists so the host view is transparent (the wrapped SwiftUI
// content brings its own background) and so each instance gets a clean
// UIHostingController without forcing a navigation bar / safe area inset
// on the caller.
final class ContextMenuHostController<Content: View>: UIHostingController<Content> {
    override init(rootView: Content) {
        super.init(rootView: rootView)
        view.backgroundColor = .clear
        view.isOpaque = false
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported for ContextMenuHostController")
    }
}
