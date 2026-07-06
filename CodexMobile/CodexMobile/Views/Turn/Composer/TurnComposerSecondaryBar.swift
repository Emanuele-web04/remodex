// FILE: TurnComposerSecondaryBar.swift
// Purpose: Owns the secondary composer accessories above the main input card: a centered
//          file-change capsule and a horizontally scrollable carousel (chevron, plan, queued).
// Layer: View Component
// Exports: TurnComposerSecondaryBar
// Depends on: SwiftUI, TurnComposerCollapsibleContextCluster, PlanAccessoryCard, QueuedStatusCapsule

import SwiftUI

struct TurnComposerSecondaryBar: View {
    let isInputFocused: Bool
    let isEmptyThread: Bool
    let hasWorkingDirectory: Bool
    let isWorktreeProject: Bool
    var activeFileChangeStatus: FileChangeStatusSnapshot? = nil
    var queuedDraftCount: Int = 0
    var onTapQueuedDrafts: () -> Void = {}

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

    @Environment(\.pinnedPlanAccessory) private var pinnedPlanAccessory

    private var hasCarouselContent: Bool {
        hasWorkingDirectory || pinnedPlanAccessory != nil || queuedDraftCount > 0
    }

    var body: some View {
        // The row stays visible while the composer rests as a collapsed capsule
        // and hides only when the keyboard takes the space.
        if !isInputFocused, hasCarouselContent || activeFileChangeStatus != nil {
            VStack(spacing: 8) {
                if let activeFileChangeStatus {
                    FileChangeStatusCapsule(snapshot: activeFileChangeStatus)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }

                if hasCarouselContent {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if hasWorkingDirectory {
                                contextCluster
                            }

                            if let pinnedPlanAccessory {
                                PlanAccessoryCard(
                                    snapshot: pinnedPlanAccessory.snapshot,
                                    onTap: pinnedPlanAccessory.onTap
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                            }

                            if queuedDraftCount > 0 {
                                QueuedStatusCapsule(count: queuedDraftCount, onTap: onTapQueuedDrafts)
                                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Let the capsules' glass shadows breathe past the scroll bounds.
                    .scrollClipDisabled()
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: activeFileChangeStatus)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: queuedDraftCount > 0)
        }
    }

    private var contextCluster: some View {
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
    }
}
