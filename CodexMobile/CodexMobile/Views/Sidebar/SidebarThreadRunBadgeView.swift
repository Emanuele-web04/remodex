// FILE: SidebarThreadRunBadgeView.swift
// Purpose: Renders compact active/failed run-state indicators for sidebar conversation rows.
// Layer: View Component
// Exports: SidebarThreadRunBadgeView, CodexThreadRunBadgeState.isVisibleInSidebar
// Depends on: SwiftUI, CodexThreadRunBadgeState

import SwiftUI

struct SidebarThreadRunBadgeView: View {
    let state: CodexThreadRunBadgeState

    var body: some View {
        switch state {
        case .running:
            RunningThreadSpinner()
        case .failed:
            statusDot(color: .red)
        case .ready:
            EmptyView()
        }
    }

    private func statusDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 15, height: 15)
            .overlay(
                Circle()
                    .stroke(Color(.systemBackground), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

extension CodexThreadRunBadgeState {
    var isVisibleInSidebar: Bool {
        switch self {
        case .running, .failed:
            return true
        case .ready:
            return false
        }
    }
}
