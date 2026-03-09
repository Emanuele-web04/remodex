// FILE: SidebarFloatingSettingsButton.swift
// Purpose: Floating shortcut used to open sidebar settings.
// Layer: View Component
// Exports: SidebarFloatingSettingsButton

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
