// FILE: TurnToolbarContent.swift
// Purpose: Encapsulates the TurnView navigation toolbar and thread-path sheet.
// Layer: View Component
// Exports: TurnToolbarContent, TurnThreadNavigationContext

import SwiftUI

struct TurnThreadNavigationContext {
    let folderName: String
    let subtitle: String
    let fullPath: String
}

struct TurnToolbarContent: ToolbarContent {
    let displayTitle: String
    let navigationContext: TurnThreadNavigationContext?
    let repoDiffTotals: GitDiffTotals?
    let showsGitActions: Bool
    let isGitActionEnabled: Bool
    let isRunningGitAction: Bool
    let showsDiscardRuntimeChangesAndSync: Bool
    let gitSyncState: String?
    let contextWindowUsage: ContextWindowUsage?
    var threadId: String = ""
    var isCompacting: Bool = false
    var onCompactContext: (() -> Void)?
    let onGitAction: (TurnGitActionKind) -> Void

    @Binding var isShowingPathSheet: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(AppFont.headline())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let context = navigationContext {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        isShowingPathSheet = true
                    } label: {
                        Text(context.subtitle)
                            .font(AppFont.mono(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if let contextWindowUsage {
                ContextWindowProgressRing(
                    usage: contextWindowUsage,
                    threadId: threadId,
                    isCompacting: isCompacting,
                    onCompact: onCompactContext
                )
            }

            if let repoDiffTotals {
                TurnToolbarDiffTotalsLabel(totals: repoDiffTotals)
            }

            if showsGitActions {
                TurnGitActionsToolbarButton(
                    isEnabled: isGitActionEnabled,
                    isRunningAction: isRunningGitAction,
                    showsDiscardRuntimeChangesAndSync: showsDiscardRuntimeChangesAndSync,
                    gitSyncState: gitSyncState,
                    onSelect: onGitAction
                )
            }
        }
    }
}

private struct TurnToolbarDiffTotalsLabel: View {
    let totals: GitDiffTotals

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(totals.additions)")
                .foregroundStyle(Color.green)
            Text("-\(totals.deletions)")
                .foregroundStyle(Color.red)
            if totals.binaryFiles > 0 {
                Text("B\(totals.binaryFiles)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(AppFont.mono(.caption))
        .padding(.horizontal, 4)
        .frame(minHeight: 24)
        .fixedSize(horizontal: true, vertical: false)
        .adaptiveToolbarItem(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Repository diff total")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if totals.binaryFiles > 0 {
            return "+\(totals.additions) -\(totals.deletions) binary \(totals.binaryFiles)"
        }
        return "+\(totals.additions) -\(totals.deletions)"
    }
}

struct TurnThreadPathSheet: View {
    let context: TurnThreadNavigationContext

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(context.fullPath)
                    .font(AppFont.mono(.callout))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(context.folderName)
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
        }
        .presentationDetents([.fraction(0.25), .medium])
    }
}
