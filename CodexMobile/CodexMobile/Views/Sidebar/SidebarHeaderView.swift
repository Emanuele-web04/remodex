// FILE: SidebarHeaderView.swift
// Purpose: Displays the sidebar app identity header and the inline close affordance for full-width presentation.
// Layer: View Component
// Exports: SidebarHeaderView

import SwiftUI

struct SidebarHeaderView: View {
    var showsCloseButton = false
    var onClose: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Remodex")
                .font(AppFont.title3(weight: .medium))

            Spacer(minLength: 0)

            if showsCloseButton {
                // Mirrors the top-bar menu affordance so full-width sidebar presentations still
                // have an obvious close target after the content shifts completely offscreen.
                Button(action: onClose) {
                    TwoLineHamburgerIcon()
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .adaptiveGlass(.regular, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close menu")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

#Preview {
    SidebarHeaderView(showsCloseButton: true)
}
