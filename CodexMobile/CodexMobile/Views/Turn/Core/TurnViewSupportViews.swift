// FILE: TurnViewSupportViews.swift
// Purpose: Small support overlays, sheets, and value types for TurnView.
// Layer: View Component
// Exports: NewChatOpeningOverlay, SubagentParentAccessoryCard, RuntimeDebugLogSheet, voice recovery support types
// Depends on: SwiftUI, UIKit, CodexService

import SwiftUI
import UIKit

struct NewChatOpeningOverlay: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)

            VStack(spacing: 4) {
                Text("Starting new chat...")
                    .font(AppFont.headline())
                    .foregroundStyle(.primary)

                Text("Preparing an empty conversation.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

enum VoiceRecoveryAction: Equatable {
    case reconnect
    case openMacLogin
    case showSetupHelp
    case openSystemSettings
    case none
}

struct VoiceRecoveryPresentation: Equatable {
    let snapshot: ConnectionRecoverySnapshot
    let action: VoiceRecoveryAction
}

struct SubagentParentAccessoryCard: View {
    let parentTitle: String
    let agentLabel: String
    let onTap: () -> Void

    var body: some View {
        GlassAccessoryCard(onTap: onTap) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 22, height: 22)

                RemodexIcon.image(systemName: "arrow.turn.up.left")
                    .font(AppFont.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        } header: {
            HStack(alignment: .center, spacing: 6) {
                Text("Subagent")
                    .font(AppFont.mono(.caption2))
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(Color(.separator).opacity(0.6))
                    .frame(width: 3, height: 3)

                SubagentLabelParser.styledText(for: agentLabel)
                    .font(AppFont.caption(weight: .regular))
                    .lineLimit(1)
            }
        } summary: {
            Text("Back to \(parentTitle)")
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        } trailing: {
            RemodexIcon.image(systemName: "chevron.right")
                .font(AppFont.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

struct CheckedOutElsewhereAlert: Identifiable {
    let id = UUID()
    let branch: String
    let threadID: String?

    var title: String {
        "Branch already open elsewhere"
    }

    var message: String {
        if threadID != nil {
            return "'\(branch)' is already checked out in another worktree. Open that chat to continue there."
        }

        return "'\(branch)' is already checked out in another worktree. Open that chat from the sidebar to continue there."
    }
}

struct RuntimeDebugLogSheet: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.dismiss) private var dismiss

    private var combinedLogText: String {
        codex.runtimeDebugLogEntries.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Group {
                if codex.runtimeDebugLogEntries.isEmpty {
                    ContentUnavailableView {
                        RemodexIcon.label("No Runtime Logs Yet", systemName: "list.bullet.rectangle")
                    } description: {
                        Text("Start a Plan Mode turn and the RPC events will appear here.")
                    }
                } else {
                    ScrollView {
                        Text(combinedLogText)
                            .font(AppFont.mono(.footnote))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .background(Color(.systemBackground))
                }
            }
            .navigationTitle("Runtime Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Clear") {
                        codex.clearRuntimeDebugLog()
                    }

                    Button("Copy") {
                        UIPasteboard.general.string = combinedLogText
                    }
                    .disabled(combinedLogText.isEmpty)
                }
            }
        }
    }
}
