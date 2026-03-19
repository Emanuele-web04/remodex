// FILE: TurnComposerSecondaryBar.swift
// Purpose: Owns the secondary composer controls shown below the main input card.
// Layer: View Component
// Exports: TurnComposerSecondaryBar
// Depends on: SwiftUI, UIKit, TurnGitBranchSelector, ContextWindowProgressRing, CodexWorktreeIcon

import SwiftUI
import UIKit

struct TurnComposerSecondaryBar: View {
    let isInputFocused: Bool
    let isEmptyThread: Bool
    let isWorktreeProject: Bool

    let selectedAccessMode: CodexAccessMode
    let contextWindowUsage: ContextWindowUsage?
    let rateLimitBuckets: [CodexRateLimitBucket]
    let isLoadingRateLimits: Bool
    let rateLimitsErrorMessage: String?
    let shouldAutoRefreshUsageStatus: Bool

    let showsGitBranchSelector: Bool
    let isGitBranchSelectorEnabled: Bool
    let availableGitBranchTargets: [String]
    let gitBranchesCheckedOutElsewhere: Set<String>
    let gitWorktreePathsByBranch: [String: String]
    let selectedGitBaseBranch: String
    let currentGitBranch: String
    let gitDefaultBranch: String
    let isLoadingGitBranchTargets: Bool
    let isSwitchingGitBranch: Bool
    let isCreatingGitWorktree: Bool

    let onSelectGitBranch: (String) -> Void
    let onCreateGitBranch: (String) -> Void
    let onSelectGitBaseBranch: (String) -> Void
    let onRefreshGitBranches: () -> Void
    let onRefreshUsageStatus: () async -> Void
    let onSelectAccessMode: (CodexAccessMode) -> Void
    let canHandOffToWorktree: Bool
    let onTapCreateWorktree: () -> Void

    private let branchLabelColor = Color(.secondaryLabel)
    private var branchTextFont: Font { AppFont.subheadline() }
    private var branchChevronFont: Font { AppFont.system(size: 9, weight: .regular) }

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        Group {
            if !isInputFocused {
                HStack(spacing: 8) {
                    runtimePicker

                    accessMenuLabel
                    Spacer()

                    if showsGitBranchSelector {
                        TurnGitBranchSelector(
                            isEnabled: isGitBranchSelectorEnabled,
                            availableGitBranchTargets: availableGitBranchTargets,
                            gitBranchesCheckedOutElsewhere: gitBranchesCheckedOutElsewhere,
                            gitWorktreePathsByBranch: gitWorktreePathsByBranch,
                            selectedGitBaseBranch: selectedGitBaseBranch,
                            currentGitBranch: currentGitBranch,
                            defaultBranch: gitDefaultBranch,
                            isLoadingGitBranchTargets: isLoadingGitBranchTargets,
                            isSwitchingGitBranch: isSwitchingGitBranch,
                            onSelectGitBranch: onSelectGitBranch,
                            onCreateGitBranch: onCreateGitBranch,
                            onSelectGitBaseBranch: onSelectGitBaseBranch,
                            onRefreshGitBranches: onRefreshGitBranches
                        )
                    }

                    statusControlCircle
                }

                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // ─── Menus ───────────────────────────────────────────────────

    private var accessMenuLabel: some View {
        Menu {
            ForEach(CodexAccessMode.allCases, id: \.rawValue) { mode in
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onSelectAccessMode(mode)
                } label: {
                    if selectedAccessMode == mode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedAccessMode == .fullAccess
                      ? "exclamationmark.shield"
                      : "checkmark.shield")
                    .font(branchTextFont)

                Text(selectedAccessMode.displayName)
                    .font(branchTextFont)
                    .fontWeight(.regular)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(branchChevronFont)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .adaptiveGlass(.regular, in: Capsule())
            .foregroundStyle(selectedAccessMode == .fullAccess ? .orange : branchLabelColor)
            .contentShape(Capsule())
        }
        .tint(branchLabelColor)
    }

    private var runtimePicker: some View {
        Menu {
            Section("Continue in") {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    if let url = URL(string: "https://chatgpt.com/codex") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Cloud", systemImage: "cloud")
                }

                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onTapCreateWorktree()
                } label: {
                    CodexWorktreeMenuLabelRow(
                        title: isCreatingGitWorktree
                            ? "Creating worktree..."
                            : isEmptyThread ? "New worktree" : "Hand off to worktree",
                        pointSize: 12,
                        weight: .regular
                    )
                }
                .disabled(!canHandOffToWorktree || isCreatingGitWorktree || isSwitchingGitBranch)

                Button {
                    // Returning to Local is intentionally disabled until it can move code + branch safely.
                } label: {
                    TurnComposerRuntimeMenuRow(title: "Local") {
                        if isWorktreeProject {
                            Image(uiImage: CodexWorktreeIcon.menuImage(pointSize: 12, weight: .regular))
                        } else {
                            Image(systemName: "laptopcomputer")
                        }
                    }
                }
                .disabled(true)
            }
        } label: {
            HStack(spacing: 6) {
                if isWorktreeProject {
                    CodexWorktreeIcon(pointSize: 12, weight: .regular)
                } else {
                    Image(systemName: "laptopcomputer")
                        .font(branchTextFont)
                }

                Text("Local")
                    .font(branchTextFont)
                    .fontWeight(.regular)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(branchChevronFont)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .adaptiveGlass(.regular, in: Capsule())
            .foregroundStyle(branchLabelColor)
            .contentShape(Capsule())
        }
        .tint(branchLabelColor)
    }

    private var statusControlCircle: some View {
        ContextWindowProgressRing(
            usage: contextWindowUsage,
            rateLimitBuckets: rateLimitBuckets,
            isLoadingRateLimits: isLoadingRateLimits,
            rateLimitsErrorMessage: rateLimitsErrorMessage,
            shouldAutoRefreshStatus: shouldAutoRefreshUsageStatus,
            onRefreshStatus: onRefreshUsageStatus
        )
    }
}

private struct TurnComposerRuntimeMenuRow<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 10) {
            icon()
                .frame(width: 16, height: 16)

            Text(title)
        }
    }
}
