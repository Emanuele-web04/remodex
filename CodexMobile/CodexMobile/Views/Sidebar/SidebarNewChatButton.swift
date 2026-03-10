// FILE: SidebarNewChatButton.swift
// Purpose: Renders the "New Chat" action with loading and disabled states.
// Layer: View Component
// Exports: SidebarNewChatButton

import SwiftUI

struct SidebarNewChatButton: View {
    let isCreatingThread: Bool
    let isEnabled: Bool
    let statusMessage: String?
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticFeedback.shared.triggerImpactFeedback()
            action()
        }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isCreatingThread {
                        ProgressView()
                            .tint(.primary)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "plus.app")
                            .font(AppFont.title3(weight: .regular))
                    }

                    Text("New Chat")
                        .font(AppFont.body(weight: .medium))
                }

                if let statusMessage, isCreatingThread, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!isEnabled || isCreatingThread)
        .opacity(isEnabled ? 1 : 0.35)
    }
}
// MARK: - Previews
#Preview("Enabled") {
    SidebarNewChatButton(isCreatingThread: false, isEnabled: true, statusMessage: nil) {
        // Preview action
    }
    .padding()
    .frame(width: 260)
}

#Preview("Loading") {
    SidebarNewChatButton(isCreatingThread: true, isEnabled: true, statusMessage: "Preparing owner/repo...") {
        // Preview action
    }
    .padding()
    .frame(width: 260)
}

#Preview("Disabled") {
    SidebarNewChatButton(isCreatingThread: false, isEnabled: false, statusMessage: nil) {
        // Preview action
    }
    .padding()
    .frame(width: 260)
}
