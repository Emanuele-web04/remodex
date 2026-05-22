// FILE: SidebarToolbarIconButton.swift
// Purpose: Shared visual shell for the icon-only buttons in the sidebar top
//          toolbar (hamburger, settings, ellipsis menu, ...). Same adaptive
//          glass circle treatment everywhere so the row reads as a single
//          cohesive control cluster, mirroring how `ComposerPillLabel` unifies
//          the composer secondary bar pills.
//          The control is built on `.contentShape(Circle()) + .onTapGesture`
//          rather than a `Button` because the sidebar header is hosted inside
//          iOS 26's `safeAreaBar(edge:.top)`. SwiftUI `Button` actions do not
//          fire when wrapped inside that bar chrome (the gear / ellipsis /
//          hamburger become inert no matter which `buttonStyle` we pick),
//          while a plain tap gesture still receives the tap and runs our
//          closure — keeping the rest of the bar (look, padding, Liquid
//          Glass material) untouched. Haptics + accessibility traits are
//          added explicitly so we don't regress from the `HapticButton`
//          baseline.
// Layer: View Component
// Exports: SidebarToolbarIconButton, SidebarToolbarIcon
// Depends on: SwiftUI, UIKit, AdaptiveGlassModifier, HapticFeedback

import SwiftUI
import UIKit

/// Icon source for a toolbar slot. Either a mapped SF Symbol name (routed
/// through `RemodexIcon` so custom `central-*` assets win) or a free-form
/// SwiftUI view (used by `TwoLineHamburgerIcon`).
enum SidebarToolbarIcon {
    case systemImage(String)
    case custom(AnyView)

    static func custom<Content: View>(@ViewBuilder _ content: () -> Content) -> SidebarToolbarIcon {
        .custom(AnyView(content()))
    }
}

struct SidebarToolbarIconButton: View {
    let icon: SidebarToolbarIcon
    let accessibilityLabel: String
    var iconSize: CGFloat = 18
    var iconWeight: Font.Weight = .semibold
    var diameter: CGFloat = 40
    var hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle = .light
    var action: () -> Void

    var body: some View {
        iconView
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .adaptiveGlass(.regular, isInteractive: true, in: Circle())
            .contentShape(Circle())
            .onTapGesture {
                handleTap()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                handleTap()
            }
    }

    private func handleTap() {
        HapticFeedback.shared.triggerImpactFeedback(style: hapticStyle)
        action()
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .systemImage(let name):
            RemodexIcon.image(systemName: name, size: iconSize, weight: iconWeight)
        case .custom(let view):
            view
        }
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 8) {
        SidebarToolbarIconButton(
            icon: .systemImage("gearshape"),
            accessibilityLabel: "Settings",
            action: {}
        )
        SidebarToolbarIconButton(
            icon: .systemImage("ellipsis"),
            accessibilityLabel: "More",
            action: {}
        )
    }
    .padding()
}
#endif
