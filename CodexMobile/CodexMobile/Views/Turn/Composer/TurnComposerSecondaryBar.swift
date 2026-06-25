// FILE: TurnComposerSecondaryBar.swift
// Purpose: Owns the secondary composer controls shown above the main input card.
// Layer: View Component
// Exports: TurnComposerSecondaryBar
// Depends on: SwiftUI, TurnComposerCollapsibleContextCluster

import SwiftUI

struct TurnComposerSecondaryBar: View {
    let isInputFocused: Bool
    let isEmptyThread: Bool
    let hasWorkingDirectory: Bool
    let isWorktreeProject: Bool
    var activeFileChangeStatus: FileChangeStatusSnapshot? = nil

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
    let canHandOffToWorktree: Bool
    let onTapCreateWorktree: () -> Void
    let showsComposerDesktopHandoff: Bool
    let isDesktopHandoffLoading: Bool
    let onContinueOnDesktop: (() -> Void)?

    var body: some View {
        Group {
            if !isInputFocused {
                HStack(spacing: 0) {
                    TurnComposerCollapsibleContextCluster(
                        isEmptyThread: isEmptyThread,
                        hasWorkingDirectory: hasWorkingDirectory,
                        isWorktreeProject: isWorktreeProject,
                        showsGitBranchSelector: showsGitBranchSelector,
                        isGitBranchSelectorEnabled: isGitBranchSelectorEnabled,
                        availableGitBranchTargets: availableGitBranchTargets,
                        gitBranchesCheckedOutElsewhere: gitBranchesCheckedOutElsewhere,
                        gitWorktreePathsByBranch: gitWorktreePathsByBranch,
                        selectedGitBaseBranch: selectedGitBaseBranch,
                        currentGitBranch: currentGitBranch,
                        gitDefaultBranch: gitDefaultBranch,
                        isLoadingGitBranchTargets: isLoadingGitBranchTargets,
                        isSwitchingGitBranch: isSwitchingGitBranch,
                        isCreatingGitWorktree: isCreatingGitWorktree,
                        onSelectGitBranch: onSelectGitBranch,
                        onCreateGitBranch: onCreateGitBranch,
                        onSelectGitBaseBranch: onSelectGitBaseBranch,
                        onRefreshGitBranches: onRefreshGitBranches,
                        canHandOffToWorktree: canHandOffToWorktree,
                        onTapCreateWorktree: onTapCreateWorktree
                    )

                    if showsComposerDesktopHandoff {
                        Spacer(minLength: 8)

                        Button {
                            onContinueOnDesktop?()
                        } label: {
                            HStack(spacing: 6) {
                                if isDesktopHandoffLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "desktopcomputer")
                                        .font(AppFont.subheadline(weight: .semibold))
                                }
                                Text("Continue on Desktop")
                                    .font(AppFont.subheadline(weight: .semibold))
                            }
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(onContinueOnDesktop == nil || isDesktopHandoffLoading)
                        .opacity(onContinueOnDesktop == nil || isDesktopHandoffLoading ? 0.5 : 1)
                        .accessibilityLabel("Continue on Desktop")
                    }

                    Spacer(minLength: showsComposerDesktopHandoff ? 8 : 12)

                    if let activeFileChangeStatus {
                        FileChangeStatusCapsule(snapshot: activeFileChangeStatus)
                            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.28, dampingFraction: 0.88), value: activeFileChangeStatus)
            }
        }
    }
}
