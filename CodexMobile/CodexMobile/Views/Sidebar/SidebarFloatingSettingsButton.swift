// FILE: SidebarFloatingSettingsButton.swift
// Purpose: Floating shortcut used to open sidebar settings.
// Layer: View Component
// Exports: SidebarFloatingSettingsButton, SidebarMacConnectionStatusView

import SwiftUI

struct SidebarFloatingSettingsButton: View {
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticFeedback.shared.triggerImpactFeedback()
            action()
        }) {
            Image(systemName: "gearshape.fill")
                .font(AppFont.system(size: 17, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .frame(width: 44, height: 44)
                .adaptiveGlass(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Settings")
    }
}

struct SidebarMacConnectionStatusView: View {
    let name: String
    let systemName: String?
    let isConnected: Bool

    var body: some View {
        // Let the trusted-Mac label use the sidebar width instead of truncating
        // inside a narrow fixed box while the center spacer absorbs the space.
        VStack(alignment: .trailing, spacing: 2) {
            Text(statusTitle)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(name)
                .font(AppFont.mono(.subheadline))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .layoutPriority(1)
    }

    private var statusTitle: String {
        isConnected ? "Connected to Mac" : "Saved Mac"
    }
}
