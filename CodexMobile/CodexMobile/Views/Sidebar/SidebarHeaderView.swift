// FILE: SidebarHeaderView.swift
// Purpose: Top sidebar bar with a centered brand block — "Remodex" over the
//          paired computer's name with a live status dot — flanked by two
//          detached circle buttons: leading close hamburger (or the settings
//          gear when the sidebar is the navigation root and has no close
//          affordance) and the trailing overflow menu. All icon buttons route
//          through `SidebarToolbarIconButton` so they share one visual
//          treatment.
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
    var connectedComputerName: String? = nil
    var isConnected: Bool = false

    var body: some View {
        AdaptiveGlassContainer(spacing: 10) {
            // ZStack keeps the brand block centered on the bar regardless of
            // how wide the flanking circle buttons are.
            ZStack {
                titleBlock
                    .padding(.horizontal, 52)

                HStack {
                    if showsCloseButton {
                        hamburgerButton
                    } else {
                        settingsButton
                    }

                    Spacer(minLength: 0)

                    overflowMenuButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // Brand title with the paired computer underneath so users can tell at a
    // glance which machine the app is talking to. Hidden when no pair exists.
    private var titleBlock: some View {
        VStack(spacing: 2) {
            Text("Remodex")
                .font(AppFont.title3(weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let connectedComputerName {
                HStack(spacing: 4) {
                    Circle()
                        .fill(isConnected ? Color.green : Color(.tertiaryLabel))
                        .frame(width: 6, height: 6)

                    RemodexIcon.image(systemName: "laptopcomputer", size: 11, weight: .medium)
                        .foregroundStyle(.secondary)

                    Text(connectedComputerName)
                        .font(AppFont.caption(weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitleLabel)
    }

    private var accessibilityTitleLabel: String {
        guard let connectedComputerName else { return "Remodex" }
        let status = isConnected ? "connected to" : "paired with"
        return "Remodex, \(status) \(connectedComputerName)"
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

    // Occupies the leading slot when the sidebar is the navigation root: there
    // is no close action there, and Settings keeps its one-tap access.
    private var settingsButton: some View {
        SidebarToolbarIconButton(
            icon: .systemImage("gearshape"),
            accessibilityLabel: "Settings",
            action: overflowActions.onOpenSettings
        )
    }

    private var overflowMenuButton: some View {
        // Routed through `UIKitMenuButton` so the leading glyphs render
        // through `RemodexIcon.menuUIImage` at the SF Symbol menu glyph
        // metric, matching the rest of the sidebar's UIKit-rendered menus.
        UIKitMenuButton(
            label: {
                // Reuses the same toolbar button shell so the ellipsis trigger
                // matches the surrounding header glyphs exactly.
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
        var sections: [UIMenuElement] = [
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

        // The leading slot hosts the hamburger in this configuration, so
        // Settings moves into the menu to stay reachable.
        if showsCloseButton {
            sections.append(
                UIMenu(
                    title: "",
                    options: [.displayInline],
                    children: [
                        overflowAction(title: "Settings", systemName: "gearshape") {
                            overflowActions.onOpenSettings()
                        },
                    ]
                )
            )
        }

        return UIMenu(title: "", children: sections)
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
        ),
        connectedComputerName: "MacBook-Pro-di-Emanuele.local",
        isConnected: true
    )
}
#endif
