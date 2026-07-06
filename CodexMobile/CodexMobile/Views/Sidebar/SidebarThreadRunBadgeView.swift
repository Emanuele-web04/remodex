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
            SidebarThreadRunSpinner()
        case .failed:
            statusDot(color: .red)
        case .ready:
            EmptyView()
        }
    }

    private func statusDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
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

private struct SidebarThreadRunSpinner: View {
    @State private var isSpinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.22), lineWidth: 1.5)
            Circle()
                .trim(from: 0.16, to: 0.72)
                .stroke(
                    Color.gray,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(
                    .linear(duration: 0.85).repeatForever(autoreverses: false),
                    value: isSpinning
                )
        }
        .frame(width: 12, height: 12)
        .onAppear {
            isSpinning = true
        }
        .accessibilityHidden(true)
    }
}
