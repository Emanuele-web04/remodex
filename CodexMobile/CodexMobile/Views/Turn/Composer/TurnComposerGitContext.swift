// FILE: TurnComposerGitContext.swift
// Purpose: Bundles the git branch-selection and worktree-handoff context that travels
//          from TurnComposerHostView down to the collapsible context cluster, so the
//          composer chain passes two values instead of seventeen loose parameters.
// Layer: View Helper
// Exports: TurnComposerGitState, TurnComposerGitActions
// Depends on: Foundation

import Foundation

/// Read-only git context for a composer surface: branch targets, selection,
/// and the in-flight flags that gate the branch picker and worktree menu.
struct TurnComposerGitState: Equatable {
    var showsGitBranchSelector = false
    var isGitBranchSelectorEnabled = false
    var availableGitBranchTargets: [String] = []
    var gitBranchesCheckedOutElsewhere: Set<String> = []
    var gitWorktreePathsByBranch: [String: String] = [:]
    var selectedGitBaseBranch = ""
    var currentGitBranch = ""
    var gitDefaultBranch = ""
    var isLoadingGitBranchTargets = false
    var isSwitchingGitBranch = false
    var isCreatingGitWorktree = false
    var canHandOffToWorktree = false
}

/// Callbacks paired with `TurnComposerGitState`; implementations live at the
/// TurnView/NewChatDraftView layer (branch switching) and the view model
/// (base-branch selection), never in the composer views themselves.
struct TurnComposerGitActions {
    var onSelectGitBranch: (String) -> Void = { _ in }
    var onCreateGitBranch: (String) -> Void = { _ in }
    var onSelectGitBaseBranch: (String) -> Void = { _ in }
    var onRefreshGitBranches: () -> Void = {}
    var onTapCreateWorktree: () -> Void = {}
}
