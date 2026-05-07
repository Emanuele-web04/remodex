// FILE: TurnComposerSecondaryBar.swift
// Purpose: Owns the secondary composer controls shown below the main input card.
// Layer: View Component
// Exports: TurnComposerSecondaryBar
// Depends on: SwiftUI, UIKit, TurnGitBranchSelector, ContextWindowProgressRing, CodexWorktreeIcon, PadPresentationStyle

import SwiftUI
import UIKit

struct TurnComposerSecondaryBar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showsRuntimeSheet = false
    @State private var showsAccessSheet = false

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
    private var runtimeLabelTitle: String { isWorktreeProject ? "Worktree" : "Local" }
    private var usesPadPresentation: Bool {
        PadPresentationStyle.usesPadPresentation(horizontalSizeClass: horizontalSizeClass)
    }

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        Group {
            if !isInputFocused {
                HStack(spacing: 8) {
                    runtimePicker

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

                    Spacer()

                    accessMenuLabel
                    statusControlCircle
                }

                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // ─── Menus ───────────────────────────────────────────────────

    @ViewBuilder
    private var accessMenuLabel: some View {
        if usesPadPresentation {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                showsAccessSheet = true
            } label: {
                accessMenuChrome
            }
            .buttonStyle(.plain)
            .tint(branchLabelColor)
            .sheet(isPresented: $showsAccessSheet) {
                NavigationStack {
                    List {
                        Section("Access") {
                            accessOptions
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle("Access")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showsAccessSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        } else {
            accessCompactMenu
        }
    }

    private var accessCompactMenu: some View {
        Menu {
            accessOptions
        } label: {
            accessMenuChrome
        }
        .tint(branchLabelColor)
    }

    @ViewBuilder
    private var accessOptions: some View {
        ForEach(CodexAccessMode.allCases, id: \.rawValue) { mode in
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onSelectAccessMode(mode)
                showsAccessSheet = false
            } label: {
                if selectedAccessMode == mode {
                    Label(mode.menuTitle, systemImage: "checkmark")
                } else {
                    Text(mode.menuTitle)
                }
            }
        }
    }

    private var accessMenuChrome: some View {
        HStack(spacing: 6) {
            Image(systemName: selectedAccessMode == .fullAccess
                  ? "hand.thumbsup"
                  : "hand.raised")
                .font(branchTextFont)

            Image(systemName: "chevron.down")
                .font(branchChevronFont)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .adaptiveGlass(.regular, in: Capsule())
        .foregroundStyle(branchLabelColor)
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var runtimePicker: some View {
        if usesPadPresentation {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                showsRuntimeSheet = true
            } label: {
                runtimeMenuChrome
            }
            .buttonStyle(.plain)
            .tint(branchLabelColor)
            .sheet(isPresented: $showsRuntimeSheet) {
                NavigationStack {
                    List {
                        Section("Continue in") {
                            runtimeOptions
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle("Continue in")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showsRuntimeSheet = false }
                        }
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        } else {
            runtimeCompactMenu
        }
    }

    private var runtimeCompactMenu: some View {
        Menu {
            Section("Continue in") {
                runtimeOptions
            }
        } label: {
            runtimeMenuChrome
        }
        .tint(branchLabelColor)
    }

    @ViewBuilder
    private var runtimeOptions: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            showsRuntimeSheet = false
            if let url = URL(string: "https://chatgpt.com/codex") {
                UIApplication.shared.open(url)
            }
        } label: {
            Label("Cloud", systemImage: "cloud")
        }

        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            showsRuntimeSheet = false
            onTapCreateWorktree()
        } label: {
            CodexWorktreeMenuLabelRow(
                title: isCreatingGitWorktree
                    ? "Preparing worktree..."
                    : isWorktreeProject ? "Hand off to Local" : isEmptyThread ? "New worktree" : "Hand off to Worktree",
                pointSize: 12,
                weight: .regular
            )
        }
        .disabled(!canHandOffToWorktree || isCreatingGitWorktree || isSwitchingGitBranch)

        Button {
            // Returning to Local is intentionally disabled until it can move code + branch safely.
        } label: {
            TurnComposerRuntimeMenuRow(title: "Local") {
                Image(systemName: "laptopcomputer")
            }
        }
        .disabled(true)
    }

    private var runtimeMenuChrome: some View {
        HStack(spacing: 6) {
            if isWorktreeProject {
                CodexWorktreeIcon(pointSize: 12, weight: .regular)
            } else {
                Image(systemName: "laptopcomputer")
                    .font(branchTextFont)
            }

            Text(runtimeLabelTitle)
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
