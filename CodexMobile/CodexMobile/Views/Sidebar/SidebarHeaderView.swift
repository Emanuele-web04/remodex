// FILE: SidebarHeaderView.swift
// Purpose: Top sidebar row with logo/title, detached utility shortcut (settings),
//          overflow creation menu, and the hamburger close affordance. All
//          icon buttons route through `SidebarToolbarIconButton` so they
//          share one visual treatment.
// Layer: View Component
// Exports: SidebarHeaderView, SidebarOverflowMenuActions
// Depends on: SwiftUI, UIKit, SidebarToolbarIconButton, RemodexIcon,
//             AdaptiveGlassModifier, UIKitMenuButton, HapticFeedback

import SwiftUI
import UIKit

struct SidebarOverflowMenuActions {
    var isEnabled: Bool
    var pendingAction: SidebarTopAction?
    var onNewChat: () -> Void
    var onQuickChat: () -> Void
    var onNewProject: () -> Void
    var onOpenTerminal: () -> Void
    var onOpenConnections: () -> Void
    var onOpenSettings: () -> Void
}

struct SidebarHeaderView: View {
    var showsCloseButton: Bool = true
    var onClose: () -> Void
    var overflowActions: SidebarOverflowMenuActions

    var body: some View {
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                appLogo
                Text("Remodex")
                    .font(AppFont.title3(weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                overflowMenuButton

                SidebarToolbarIconButton(
                    icon: .systemImage("gearshape"),
                    accessibilityLabel: "Settings",
                    action: overflowActions.onOpenSettings
                )

                if showsCloseButton {
                    hamburgerButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var appLogo: some View {
        // Custom SF Symbol so the glyph picks up the same font-driven
        // scaling SwiftUI gives native symbols; semibold has its own asset
        // because interpolated weights are too subtle for this custom mark.
        Image("remodex_symbol_semibold")
            .font(.system(size: 20))
            .foregroundStyle(.primary)
    }

    // Close affordance kept inside the sidebar so both drawer and full-width
    // presentations share the same dismissal target.
    private var hamburgerButton: some View {
        SidebarToolbarIconButton(
            icon: .custom { TwoLineHamburgerIcon() },
            accessibilityLabel: "Close menu",
            action: onClose
        )
    }

    private var overflowMenuButton: some View {
        // Routed through `UIKitMenuButton` so the leading glyphs render
        // through `RemodexIcon.menuUIImage` at the SF Symbol menu glyph
        // metric, matching the rest of the sidebar's UIKit-rendered menus.
        UIKitMenuButton(
            label: {
                // Reuses the same toolbar button shell so the ellipsis trigger
                // matches the surrounding settings + hamburger glyphs exactly.
                SidebarToolbarIconButton(
                    icon: .systemImage("ellipsis"),
                    accessibilityLabel: "More actions",
                    action: {}
                )
                .allowsHitTesting(false)
            },
            menu: { buildOverflowMenu() }
        )
        .accessibilityLabel("More actions")
    }

    private func buildOverflowMenu() -> UIMenu {
        UIMenu(
            title: "",
            children: [
                UIMenu(
                    title: "",
                    options: [.displayInline],
                    children: [
                        overflowAction(
                            title: "New Chat",
                            systemName: "square.and.pencil",
                            isEnabled: overflowActions.isEnabled
                        ) {
                            overflowActions.onNewChat()
                        },
                        overflowAction(
                            title: "Quick Chat",
                            systemName: "message",
                            isEnabled: overflowActions.isEnabled
                        ) {
                            overflowActions.onQuickChat()
                        },
                        overflowAction(
                            title: "New Project",
                            systemName: "folder.badge.plus",
                            isEnabled: overflowActions.isEnabled
                        ) {
                            overflowActions.onNewProject()
                        },
                    ]
                ),
                UIMenu(
                    title: "",
                    options: [.displayInline],
                    children: [
                        overflowAction(title: "Connections", systemName: "globe") {
                            overflowActions.onOpenConnections()
                        },
                    ]
                ),
            ]
        )
    }

    private func overflowAction(
        title: String,
        systemName: String,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> UIAction {
        UIAction(
            title: title,
            image: RemodexIcon.menuUIImage(systemName: systemName),
            attributes: isEnabled ? [] : .disabled
        ) { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            handler()
        }
    }
}

#if DEBUG
#Preview {
    SidebarHeaderView(
        onClose: {},
        overflowActions: SidebarOverflowMenuActions(
            isEnabled: true,
            pendingAction: nil,
            onNewChat: {},
            onQuickChat: {},
            onNewProject: {},
            onOpenTerminal: {},
            onOpenConnections: {},
            onOpenSettings: {}
        )
    )
}
#endif
