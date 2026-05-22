// FILE: SidebarFloatingSettingsButton.swift
// Purpose: Floating shortcuts used to open top-level sidebar destinations.
// Layer: View Component
// Exports: SidebarFloatingSettingsButton, SidebarFloatingMacsButton, SidebarFloatingTerminalButton, SidebarComputerConnectionStatusView

import SwiftUI

private struct SidebarFloatingCircleButton: View {
    let colorScheme: ColorScheme
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        HapticButton(hapticStyle: .medium, action: action) {
            RemodexIcon.image(systemName: systemImage, size: 17, weight: .semibold)
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .frame(width: 44, height: 44)
                .adaptiveGlass(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SidebarFloatingSettingsButton: View {
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        SidebarFloatingCircleButton(
            colorScheme: colorScheme,
            systemImage: "gearshape",
            accessibilityLabel: "Settings",
            action: action
        )
    }
}

struct SidebarFloatingMacsButton: View {
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        SidebarFloatingCircleButton(
            colorScheme: colorScheme,
            systemImage: "laptopcomputer",
            accessibilityLabel: "My Devices",
            action: action
        )
    }
}

struct SidebarFloatingTerminalButton: View {
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        HapticButton(hapticStyle: .medium, action: action) {
            RemodexIcon.image(systemName: "terminal.fill", size: 17, weight: .semibold)
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .frame(width: 44, height: 44)
                .adaptiveGlass(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Terminal")
    }
}

struct SidebarComputerConnectionStatusView: View {
    let name: String
    let systemName: String?
    let isConnected: Bool

    var body: some View {
        // Let the trusted-computer label use the sidebar width instead of truncating
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
        isConnected ? "Connected to Device" : "Saved Device"
    }
}
