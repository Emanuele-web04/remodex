// FILE: SidebarTopActionsRow.swift
// Purpose: Renders the three primary entry actions (New Chat, Quick Chat, New Project)
//          as an inline row of circular icon buttons with labels underneath.
// Layer: View Component
// Exports: SidebarTopActionsRow, SidebarTopAction

import SwiftUI

enum SidebarTopAction {
    case newChat
    case quickChat
    case newProject
}

struct SidebarTopActionsRow: View {
    let isEnabled: Bool
    let pendingAction: SidebarTopAction?
    let onNewChat: () -> Void
    let onQuickChat: () -> Void
    let onNewProject: () -> Void

    private var isBusy: Bool { pendingAction != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            actionButton(
                action: .newChat,
                systemName: "square.and.pencil",
                label: "New Chat",
                tap: onNewChat
            )

            actionButton(
                action: .quickChat,
                systemName: "message",
                label: "Quick Chat",
                tap: onQuickChat
            )

            actionButton(
                action: .newProject,
                systemName: "folder.badge.plus",
                label: "New Project",
                tap: onNewProject
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .disabled(!isEnabled || isBusy)
        .opacity(isEnabled ? 1 : 0.35)
    }

    @ViewBuilder
    private func actionButton(
        action: SidebarTopAction,
        systemName: String,
        label: String,
        tap: @escaping () -> Void
    ) -> some View {
        let isLoading = pendingAction == action

        Button {
            HapticFeedback.shared.triggerImpactFeedback()
            tap()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 55, height: 55)

                    if isLoading {
                        ProgressView()
                            .tint(.primary)
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: systemName)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(.primary)
                    }
                }

                Text(label)
                    .font(AppFont.caption2(weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#if DEBUG
private struct SidebarTopActionsRowPreviewHost: View {
    let isEnabled: Bool
    let pendingAction: SidebarTopAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarTopActionsRow(
                isEnabled: isEnabled,
                pendingAction: pendingAction,
                onNewChat: {},
                onQuickChat: {},
                onNewProject: {}
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}

#Preview("Enabled - Light") {
    SidebarTopActionsRowPreviewHost(isEnabled: true, pendingAction: nil)
}

#Preview("Enabled - Dark") {
    SidebarTopActionsRowPreviewHost(isEnabled: true, pendingAction: nil)
        .preferredColorScheme(.dark)
}

#Preview("Quick Chat loading") {
    SidebarTopActionsRowPreviewHost(isEnabled: true, pendingAction: .quickChat)
}

#Preview("Disabled") {
    SidebarTopActionsRowPreviewHost(isEnabled: false, pendingAction: nil)
}
#endif
