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
    let showsMacHandoff: Bool
    let isHandingOffToMac: Bool
    let repoDiffTotals: GitDiffTotals?
    let isLoadingRepoDiff: Bool
    let showsGitActions: Bool
    let isGitActionEnabled: Bool
    let isRunningGitAction: Bool
    let showsDiscardRuntimeChangesAndSync: Bool
    let gitSyncState: String?
    var onTapMacHandoff: (() -> Void)?
    var onTapRepoDiff: (() -> Void)?
    let onGitAction: (TurnGitActionKind) -> Void

    @Binding var isShowingPathSheet: Bool

    var body: some ToolbarContent {
        let hasTrailingCluster = repoDiffTotals != nil || showsGitActions

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

        if showsMacHandoff, let onTapMacHandoff {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onTapMacHandoff()
                } label: {
                    TurnMacHandoffToolbarLabel(isLoading: isHandingOffToMac)
                }
                .disabled(isHandingOffToMac)
                .accessibilityLabel("Hand off to Mac app")
            }
        }

        if showsMacHandoff, onTapMacHandoff != nil, hasTrailingCluster {
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
        }

        if repoDiffTotals != nil || showsGitActions {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let repoDiffTotals {
                    TurnToolbarDiffTotalsLabel(
                        totals: repoDiffTotals,
                        isLoading: isLoadingRepoDiff,
                        onTap: onTapRepoDiff
                    )
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
}

private struct TurnMacHandoffToolbarLabel: View {
    let isLoading: Bool

    private let iconSize: CGFloat = 10
    private let minToolbarButtonSize: CGFloat = 32

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                VStack(spacing: 1.5) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: iconSize, weight: .semibold))
                    Image(systemName: "arrow.left")
                        .font(.system(size: iconSize, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
            }
        }
        .contentShape(Circle())
        .adaptiveToolbarItem(in: Circle())
    }
}

private struct TurnToolbarDiffTotalsLabel: View {
    let totals: GitDiffTotals
    let isLoading: Bool
    let onTap: (() -> Void)?

    // Keeps small diff totals tappable without forcing large-count pills into a fixed width.
    private let minPillWidth: CGFloat = 50

    var body: some View {
        Group {
            if let onTap {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onTap()
                } label: {
                    labelContent
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            } else {
                labelContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Repository diff total")
        .accessibilityValue(accessibilityValue)
    }

    private var labelContent: some View {
        HStack(spacing: 4) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
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
        .frame(minWidth: minPillWidth, minHeight: 28)
        .contentShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .opacity(isLoading ? 0.8 : 1)
        .adaptiveToolbarItem(in: Capsule())
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
