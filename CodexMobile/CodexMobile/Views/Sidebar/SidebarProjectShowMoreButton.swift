// FILE: SidebarProjectShowMoreButton.swift
// Purpose: Localizes "show more" project-section button UI and animation state.
// Layer: Sidebar UI component
// Exports: SidebarProjectShowMoreButton
// Depends on: SwiftUI, HapticFeedback

import SwiftUI

struct SidebarProjectShowMoreButton: View {
    let hiddenCount: Int
    let reveal: () -> Void

    @State private var chevronRotated = false

    var body: some View {
        HStack {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                withAnimation(.easeInOut(duration: 0.2)) {
                    chevronRotated = true
                    reveal()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(hiddenCount > 0 ? "Show \(hiddenCount) more" : "Show more")
                    Image(systemName: "chevron.down")
                        .font(AppFont.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(chevronRotated ? 180 : 0))
                }
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.leading, 48)
        .padding(.top, 6)
        .onAppear { chevronRotated = false }
    }
}
