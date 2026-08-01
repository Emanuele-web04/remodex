// FILE: SidebarThreadRunBadgeView.swift
// Purpose: Renders the compact run-state indicator for sidebar conversation rows.
// Layer: View Component
// Exports: SidebarThreadRunBadgeView
// Depends on: SwiftUI, CodexThreadRunBadgeState

import SwiftUI

struct SidebarThreadRunBadgeView: View {
    // The dot only has to read as a colour at a glance, so it stays well under the
    // spinner's footprint instead of competing with the row's title.
    private static let statusDotSize: CGFloat = 10.5

    let state: CodexThreadRunBadgeState

    var body: some View {
        switch state {
        case .running:
            RunningThreadSpinner(size: 13)
        case .waitingOnUser:
            statusDot(color: .yellow, label: "Waiting for your response")
        case .ready:
            statusDot(color: .blue, label: "Finished, not opened yet")
        case .failed:
            statusDot(color: .red, label: "Last run failed")
        case .goalActive:
            statusDot(color: .teal, label: "Goal running")
        case .goalAttention:
            statusDot(color: .orange, label: "Goal needs attention")
        }
    }

    // Each colour is a different state, so the dot carries meaning no other part of
    // the row repeats: it stays readable to VoiceOver instead of being decoration.
    private func statusDot(color: Color, label: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: Self.statusDotSize, height: Self.statusDotSize)
            .overlay(
                Circle()
                    .stroke(Color(.systemBackground), lineWidth: 1)
            )
            .accessibilityElement()
            .accessibilityLabel(label)
    }
}
