// FILE: TurnComposerCollapsibleContextCluster.swift
// Purpose: Collapsible Local + branch picker above the composer. Starts as a
//          single chevron circle and expands upward into a floating column of
//          the runtime/git pills, overlaid so it never resizes the composer.
// Layer: View Component
// Exports: TurnComposerCollapsibleContextCluster
// Depends on: SwiftUI, UIKit, TurnGitBranchSelector, ComposerPillLabel,
//             UIKitMenuButton, CodexWorktreeIcon, RemodexIcon, AdaptiveGlassModifier

import SwiftUI
import UIKit

struct TurnComposerCollapsibleContextCluster: View {
    let isEmptyThread: Bool
    let hasWorkingDirectory: Bool
    let isWorktreeProject: Bool

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

    @State private var isExpanded = false

    private let branchLabelColor = Color(.secondaryLabel)
    private var branchTextFont: Font { AppFont.subheadline() }
    private let toggleControlSize: CGFloat = 34
    private let toggleChevronSize: CGFloat = 14
    private let columnSpacing: CGFloat = 10

    private var runtimeLabelTitle: String {
        if !hasWorkingDirectory {
            return "Quick Chat"
        }
        return isWorktreeProject ? "Worktree" : "Local"
    }

    private var runtimeIconSystemName: String {
        if !hasWorkingDirectory {
            return "bubble.left.and.bubble.right"
        }
        return isWorktreeProject ? "remodex.worktree" : "laptopcomputer"
    }

    var body: some View {
        // The expanded pills float UP out of the chevron as an overlay so they
        // never participate in the composer's vertical flow. That keeps the
        // composer (and therefore the chat scroll height) fixed: the column
        // simply hovers over the messages above, which stay scrollable while the
        // pickers are open. `.overlay` here is anchored to the chevron's own
        // 34x34 bounds, so applying `maxWidth: .infinity` afterwards leaves the
        // chevron pinned to the leading edge without dragging the column with it.
        expandToggleButton
            .overlay(alignment: .bottomLeading) {
                if isExpanded {
                    expandedPillsColumn
                        .fixedSize()
                        .transition(.contextClusterReveal)
                        // Lift the column entirely clear of the chevron so its
                        // tap target (collapse) stays unobstructed.
                        .offset(y: -(toggleControlSize + columnSpacing))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expandedPillsColumn: some View {
        VStack(alignment: .leading, spacing: columnSpacing) {
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
                .equatable()
            }

            runtimePickerMenu
        }
    }

    private var expandToggleButton: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            // Use a tighter, fully damped spring on collapse so the pills
            // shrink back into the chevron crisply (no overshoot, no bounce
            // back through the chevron). Expansion keeps the slightly
            // springy feel that makes the chips "pop" out.
            let collapsing = isExpanded
            let animation: Animation = collapsing
                ? .spring(response: 0.26, dampingFraction: 1.0)
                : .spring(response: 0.34, dampingFraction: 0.86)
            withAnimation(animation) {
                isExpanded.toggle()
            }
        } label: {
            // Quarter-turn from right (collapsed) to up (expanded) so the glyph
            // sweeps in the same direction the pills travel as they rise out of
            // the chevron.
            RemodexIcon.image(systemName: "chevron.right", size: toggleChevronSize)
                .rotationEffect(.degrees(isExpanded ? -90 : 0))
                .frame(width: toggleControlSize, height: toggleControlSize)
                .adaptiveGlass(.regular, isInteractive: true, in: Circle())
                .foregroundStyle(branchLabelColor)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse project controls" : "Expand project controls")
        .accessibilityHint(isExpanded ? "Hides the local and branch pickers" : "Shows the local and branch pickers")
    }

    // Routed through `UIKitMenuButton` so the menu's UIKit presentation
    // reparents `_UIReparentingView` into the backer's own controller instead
    // of the outer `UIHostingController.view`. A plain SwiftUI `Menu` sitting
    // inside the composer's `GlassEffectContainer` would trip the iOS 26
    // "Adding _UIReparentingView as a subview of UIHostingController.view"
    // warning every time the user opened it.
    private var runtimePickerMenu: some View {
        UIKitMenuButton(
            label: {
                ComposerPillLabel(
                    title: runtimeLabelTitle,
                    iconSystemName: runtimeIconSystemName,
                    foregroundColor: branchLabelColor,
                    titleFont: branchTextFont,
                    showsTrailingChevron: false
                )
            },
            menu: { buildRuntimeMenu() }
        )
        .accessibilityLabel("Runtime")
    }

    private func buildRuntimeMenu() -> UIMenu {
        let worktreeTitle: String = {
            if isCreatingGitWorktree { return "Preparing worktree..." }
            if isWorktreeProject { return "Hand off to Local" }
            return isEmptyThread ? "New worktree" : "Hand off to Worktree"
        }()
        let worktreeDisabled = !canHandOffToWorktree || isCreatingGitWorktree || isSwitchingGitBranch
        let worktreeAction = UIAction(
            title: worktreeTitle,
            image: CodexWorktreeIcon.menuImage(pointSize: 16, weight: .regular),
            attributes: worktreeDisabled ? .disabled : []
        ) { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onTapCreateWorktree()
        }

        // Returning to Local is intentionally disabled until it can move code + branch safely.
        let localAction = UIAction(
            title: "Local",
            image: RemodexIcon.menuUIImage(systemName: "laptopcomputer"),
            attributes: .disabled
        ) { _ in }

        return UIMenu(
            title: "",
            children: [
                UIMenu(
                    title: "Continue in",
                    options: [.displayInline],
                    children: [worktreeAction, localAction]
                ),
            ]
        )
    }
}

// Scale-from-bottom-leading + opacity is applied symmetrically so the pill
// column grows up out of the chevron on expand and shrinks back down into it
// on collapse, as a single unit. Anchoring at `.bottomLeading` keeps the
// origin at the chevron's near corner so the column appears to emerge from the
// button rather than slide in from elsewhere. A small non-zero target scale
// (0.01) avoids the degenerate scale=0 frame that makes the spring's midpoint
// look like the column is drifting across the composer.
private extension AnyTransition {
    static var contextClusterReveal: AnyTransition {
        .scale(scale: 0.01, anchor: .bottomLeading).combined(with: .opacity)
    }
}

#if DEBUG
#Preview("Collapsed") {
    TurnComposerCollapsibleContextCluster(
        isEmptyThread: true,
        hasWorkingDirectory: true,
        isWorktreeProject: false,
        showsGitBranchSelector: true,
        isGitBranchSelectorEnabled: true,
        availableGitBranchTargets: ["main", "feature/ui"],
        gitBranchesCheckedOutElsewhere: [],
        gitWorktreePathsByBranch: [:],
        selectedGitBaseBranch: "main",
        currentGitBranch: "main",
        gitDefaultBranch: "main",
        isLoadingGitBranchTargets: false,
        isSwitchingGitBranch: false,
        isCreatingGitWorktree: false,
        onSelectGitBranch: { _ in },
        onCreateGitBranch: { _ in },
        onSelectGitBaseBranch: { _ in },
        onRefreshGitBranches: {},
        canHandOffToWorktree: true,
        onTapCreateWorktree: {}
    )
    .padding()
}
#endif
