// FILE: TurnComposerCollapsibleContextCluster.swift
// Purpose: Collapsible Local + branch picker above the composer. The chevron
//          toggle lives inside the accessory carousel; the expanded pills
//          render as TurnComposerContextClusterFloatingColumn, overlaid by the
//          secondary bar OUTSIDE the carousel's UIScrollView so they stay
//          tappable while floating over the timeline (UIScrollView never
//          delivers touches outside its own bounds, even with clipping off).
// Layer: View Component
// Exports: TurnComposerCollapsibleContextCluster, TurnComposerContextClusterFloatingColumn
// Depends on: SwiftUI, UIKit, TurnGitBranchSelector, ComposerPillLabel,
//             UIKitMenuButton, CodexWorktreeIcon, RemodexIcon, AdaptiveGlassModifier

import SwiftUI
import UIKit

struct TurnComposerCollapsibleContextCluster: View {
    @Binding var isExpanded: Bool

    static let toggleControlSize: CGFloat = 34
    static let columnSpacing: CGFloat = 10
    private let toggleChevronSize: CGFloat = 14

    var body: some View {
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
                .frame(width: Self.toggleControlSize, height: Self.toggleControlSize)
                .adaptiveGlass(.regular, isInteractive: true, in: Circle())
                .foregroundStyle(Color(.secondaryLabel))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse project controls" : "Expand project controls")
        .accessibilityHint(isExpanded ? "Hides the local and branch pickers" : "Shows the local and branch pickers")
    }
}

// The floating pills column. Hosted by TurnComposerSecondaryBar as an overlay
// anchored to the bar's bottom-leading corner (where the chevron sits) and
// lifted clear of the chevron so its collapse tap target stays unobstructed.
// It never participates in the composer's vertical flow, so the composer (and
// the chat scroll height) stays fixed while the pickers are open.
struct TurnComposerContextClusterFloatingColumn: View {
    let isEmptyThread: Bool
    let hasWorkingDirectory: Bool
    let isWorktreeProject: Bool

    let gitState: TurnComposerGitState
    let gitActions: TurnComposerGitActions

    private let branchLabelColor = Color(.secondaryLabel)
    private var branchTextFont: Font { AppFont.subheadline() }

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
        VStack(alignment: .leading, spacing: TurnComposerCollapsibleContextCluster.columnSpacing) {
            if gitState.showsGitBranchSelector {
                TurnGitBranchSelector(
                    isEnabled: gitState.isGitBranchSelectorEnabled,
                    availableGitBranchTargets: gitState.availableGitBranchTargets,
                    gitBranchesCheckedOutElsewhere: gitState.gitBranchesCheckedOutElsewhere,
                    gitWorktreePathsByBranch: gitState.gitWorktreePathsByBranch,
                    selectedGitBaseBranch: gitState.selectedGitBaseBranch,
                    currentGitBranch: gitState.currentGitBranch,
                    defaultBranch: gitState.gitDefaultBranch,
                    isLoadingGitBranchTargets: gitState.isLoadingGitBranchTargets,
                    isSwitchingGitBranch: gitState.isSwitchingGitBranch,
                    onSelectGitBranch: gitActions.onSelectGitBranch,
                    onCreateGitBranch: gitActions.onCreateGitBranch,
                    onSelectGitBaseBranch: gitActions.onSelectGitBaseBranch,
                    onRefreshGitBranches: gitActions.onRefreshGitBranches
                )
                .equatable()
            }

            runtimePickerMenu
        }
        .fixedSize()
        // Lift the column entirely clear of the chevron so its tap target
        // (collapse) stays unobstructed.
        .offset(y: -(TurnComposerCollapsibleContextCluster.toggleControlSize
            + TurnComposerCollapsibleContextCluster.columnSpacing))
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
            if gitState.isCreatingGitWorktree { return "Preparing worktree..." }
            if isWorktreeProject { return "Hand off to Local" }
            return isEmptyThread ? "New worktree" : "Hand off to Worktree"
        }()
        let worktreeDisabled = !gitState.canHandOffToWorktree
            || gitState.isCreatingGitWorktree
            || gitState.isSwitchingGitBranch
        let worktreeAction = UIAction(
            title: worktreeTitle,
            image: CodexWorktreeIcon.menuImage(pointSize: 16, weight: .regular),
            attributes: worktreeDisabled ? .disabled : []
        ) { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            gitActions.onTapCreateWorktree()
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
// Internal (not private): TurnComposerSecondaryBar applies it at the overlay
// insertion point.
extension AnyTransition {
    static var contextClusterReveal: AnyTransition {
        .scale(scale: 0.01, anchor: .bottomLeading).combined(with: .opacity)
    }
}

#if DEBUG
#Preview("Column") {
    TurnComposerContextClusterFloatingColumn(
        isEmptyThread: true,
        hasWorkingDirectory: true,
        isWorktreeProject: false,
        gitState: TurnComposerGitState(
            showsGitBranchSelector: true,
            isGitBranchSelectorEnabled: true,
            availableGitBranchTargets: ["main", "feature/ui"],
            selectedGitBaseBranch: "main",
            currentGitBranch: "main",
            gitDefaultBranch: "main",
            canHandOffToWorktree: true
        ),
        gitActions: TurnComposerGitActions()
    )
    .padding()
}
#endif
