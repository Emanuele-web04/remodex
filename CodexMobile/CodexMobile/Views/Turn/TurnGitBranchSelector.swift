// FILE: TurnGitBranchSelector.swift
// Purpose: Hosts the local branch switcher plus the separate compare-base branch picker.
// Layer: View Component
// Exports: TurnGitBranchSelector
// Depends on: SwiftUI

import SwiftUI

// Normalizes newly created local branch names toward the repo's preferred prefix without double-prefixing.
func remodexNormalizedCreatedBranchName(_ rawName: String) -> String {
    let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return "" }
    if trimmedName.hasPrefix("remodex/") {
        return trimmedName
    }
    return "remodex/\(trimmedName)"
}

// Leaves "open elsewhere" branches selectable so the caller can surface the right alert or git error.
func remodexCurrentBranchSelectionIsDisabled(
    branch: String,
    currentBranch: String,
    gitBranchesCheckedOutElsewhere: Set<String>,
    gitWorktreePathsByBranch: [String: String],
    allowsSelectingCurrentBranch: Bool
) -> Bool {
    if !allowsSelectingCurrentBranch {
        return branch == currentBranch
    }

    return false
}

private enum TurnGitBranchPickerMode: String, Identifiable {
    case currentBranch
    case pullRequestTarget

    var id: String { rawValue }

    var sectionTitle: String {
        "Branches"
    }

    var navigationTitle: String {
        switch self {
        case .currentBranch:
            return "Current Branch"
        case .pullRequestTarget:
            return "Base Branch"
        }
    }
}

struct TurnGitBranchSelector: View {
    let isEnabled: Bool
    let availableGitBranchTargets: [String]
    let gitBranchesCheckedOutElsewhere: Set<String>
    let gitWorktreePathsByBranch: [String: String]
    let selectedGitBaseBranch: String
    let currentGitBranch: String
    let defaultBranch: String
    let isLoadingGitBranchTargets: Bool
    let isSwitchingGitBranch: Bool
    let onSelectGitBranch: (String) -> Void
    let onCreateGitBranch: (String) -> Void
    let onSelectGitBaseBranch: (String) -> Void
    let onRefreshGitBranches: () -> Void

    @State private var activePickerMode: TurnGitBranchPickerMode?

    private let branchLabelColor = Color(.secondaryLabel)
    private var branchSymbolSize: CGFloat { 12 }
    private var branchChevronFont: Font { AppFont.system(size: 9, weight: .regular) }
    private var branchControlsDisabled: Bool { !isEnabled || isLoadingGitBranchTargets || isSwitchingGitBranch }
    private var normalizedDefaultBranch: String? {
        let value = defaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    private var normalizedCurrentBranch: String {
        currentGitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var visibleBranchLabel: String {
        if !normalizedCurrentBranch.isEmpty {
            return normalizedCurrentBranch
        }
        return normalizedDefaultBranch ?? "Branch"
    }

    // Keep the repo default branch visible even if the latest branch-status payload omitted it.
    private var localDefaultBranch: String? {
        normalizedDefaultBranch
    }

    private func defaultBranch(for pickerMode: TurnGitBranchPickerMode) -> String? {
        switch pickerMode {
        case .currentBranch:
            return localDefaultBranch
        case .pullRequestTarget:
            return normalizedDefaultBranch
        }
    }

    private func visibleBranches(for pickerMode: TurnGitBranchPickerMode) -> [String] {
        let branchToExclude = defaultBranch(for: pickerMode)
        return availableGitBranchTargets.filter { branch in
            guard let branchToExclude else { return true }
            return branch != branchToExclude
        }
    }

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            activePickerMode = .currentBranch
        } label: {
            HStack(spacing: 6) {
                Image("git-branch")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: branchSymbolSize, height: branchSymbolSize)

                Text(visibleBranchLabel)
                    // Keep the inline label focused on the checked-out branch only.
                    .font(AppFont.mono(.subheadline))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .layoutPriority(1)

                Image(systemName: "chevron.down")
                    .font(branchChevronFont)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .adaptiveGlass(.regular, in: Capsule())
            .foregroundStyle(branchLabelColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(branchControlsDisabled)
        .popover(item: $activePickerMode, arrowEdge: .bottom) { pickerMode in
            TurnGitBranchPickerSheet(
                branches: visibleBranches(for: pickerMode),
                gitBranchesCheckedOutElsewhere: gitBranchesCheckedOutElsewhere,
                gitWorktreePathsByBranch: gitWorktreePathsByBranch,
                selectedBranch: normalizedCurrentBranch,
                defaultBranch: defaultBranch(for: pickerMode),
                currentBranch: normalizedCurrentBranch,
                allowsSelectingCurrentBranch: pickerMode == .currentBranch,
                sectionTitle: pickerMode.sectionTitle,
                navigationTitle: pickerMode.navigationTitle,
                isLoading: isLoadingGitBranchTargets,
                isSwitching: isSwitchingGitBranch,
                onSelect: { branch in
                    switch pickerMode {
                    case .currentBranch:
                        onSelectGitBranch(branch)
                    case .pullRequestTarget:
                        onSelectGitBaseBranch(branch)
                    }
                },
                onCreateBranch: onCreateGitBranch,
                onRefresh: onRefreshGitBranches
            )
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 400, minHeight: 260, idealHeight: 360, maxHeight: 480)
            .presentationCompactAdaptation(.popover)
        }
    }
}

struct TurnGitBranchPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let branches: [String]
    let gitBranchesCheckedOutElsewhere: Set<String>
    let gitWorktreePathsByBranch: [String: String]
    let selectedBranch: String
    let defaultBranch: String?
    let currentBranch: String
    let allowsSelectingCurrentBranch: Bool
    let sectionTitle: String
    let navigationTitle: String
    let isLoading: Bool
    let isSwitching: Bool
    let onSelect: (String) -> Void
    let onCreateBranch: (String) -> Void
    let onRefresh: () -> Void

    @State private var searchText = ""
    @State private var isShowingCreateBranchPrompt = false
    @State private var newBranchName = ""

    // Surfaces the active selection near the top until the user starts filtering.
    private var orderedBranches: [String] {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return filteredBranches
        }

        var prioritizedBranches = branches
        if selectedBranch != defaultBranch,
           let selectedIndex = prioritizedBranches.firstIndex(of: selectedBranch) {
            let selected = prioritizedBranches.remove(at: selectedIndex)
            prioritizedBranches.insert(selected, at: 0)
        }
        return prioritizedBranches
    }

    private var showsDefaultBranchRow: Bool {
        defaultBranch != nil
    }

    private var filteredBranches: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.lowercased().contains(query) }
    }

    private var isNewBranchNameValid: Bool {
        let trimmed = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "remodex/" else { return false }
        return true
    }

    // Suggests quick branch creation when the search query does not match an existing branch.
    private var suggestedCreateBranchName: String? {
        guard allowsSelectingCurrentBranch else { return nil }
        let candidate = remodexNormalizedCreatedBranchName(searchText)
        guard !candidate.isEmpty else { return nil }

        let normalizedCandidate = candidate.lowercased()
        let allBranchNames = Set(branches + [defaultBranch].compactMap { $0 })
        let alreadyExists = allBranchNames.contains { $0.lowercased() == normalizedCandidate }
        return alreadyExists ? nil : candidate
    }

    private func checkedOutBadgeTitle(for branch: String) -> String? {
        guard gitBranchesCheckedOutElsewhere.contains(branch) else {
            return nil
        }

        if allowsSelectingCurrentBranch, gitWorktreePathsByBranch[branch] != nil {
            return "Open worktree"
        }

        return "Open elsewhere"
    }

    var body: some View {
        List {
            Section(sectionTitle) {
                if showsDefaultBranchRow, let defaultBranch {
                    let isDisabled = remodexCurrentBranchSelectionIsDisabled(
                        branch: defaultBranch,
                        currentBranch: currentBranch,
                        gitBranchesCheckedOutElsewhere: gitBranchesCheckedOutElsewhere,
                        gitWorktreePathsByBranch: gitWorktreePathsByBranch,
                        allowsSelectingCurrentBranch: allowsSelectingCurrentBranch
                    )
                    Button {
                        onSelect(defaultBranch)
                        dismiss()
                    } label: {
                        TurnGitBranchOptionRow(
                            branch: defaultBranch,
                            isSelected: selectedBranch == defaultBranch,
                            isDefault: true,
                            isCurrent: defaultBranch == currentBranch,
                            checkedOutBadgeTitle: checkedOutBadgeTitle(for: defaultBranch),
                            isDisabled: isDisabled
                        )
                    }
                    .disabled(isLoading || isSwitching || isDisabled)
                }

                ForEach(orderedBranches, id: \.self) { branch in
                    let isDisabled = remodexCurrentBranchSelectionIsDisabled(
                        branch: branch,
                        currentBranch: currentBranch,
                        gitBranchesCheckedOutElsewhere: gitBranchesCheckedOutElsewhere,
                        gitWorktreePathsByBranch: gitWorktreePathsByBranch,
                        allowsSelectingCurrentBranch: allowsSelectingCurrentBranch
                    )
                    Button {
                        onSelect(branch)
                        dismiss()
                    } label: {
                        TurnGitBranchOptionRow(
                            branch: branch,
                            isSelected: selectedBranch == branch,
                            isDefault: false,
                            isCurrent: branch == currentBranch,
                            checkedOutBadgeTitle: checkedOutBadgeTitle(for: branch),
                            isDisabled: isDisabled
                        )
                    }
                    .disabled(isLoading || isSwitching || isDisabled)
                }

                if orderedBranches.isEmpty {
                    ContentUnavailableView(
                        "No branches found",
                        systemImage: "arrow.triangle.branch",
                        description: Text("Try a different search or refresh the branch list.")
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
                }
            }

            if allowsSelectingCurrentBranch {
                Section {
                    if let suggestedCreateBranchName {
                        Button {
                            onCreateBranch(suggestedCreateBranchName)
                            dismiss()
                        } label: {
                            Label("Create and checkout '\(suggestedCreateBranchName)'", systemImage: "plus")
                        }
                        .disabled(isLoading || isSwitching)
                    }

                    Button {
                        let fromSearch = remodexNormalizedCreatedBranchName(searchText)
                        newBranchName = fromSearch.isEmpty ? "remodex/" : fromSearch
                        isShowingCreateBranchPrompt = true
                    } label: {
                        Label("New branch...", systemImage: "plus")
                    }
                    .disabled(isLoading || isSwitching)
                }
            }

            Section {
                Button {
                    onRefresh()
                } label: {
                    if isSwitching {
                        Text("Switching...")
                    } else {
                        Text(isLoading ? "Refreshing..." : "Reload branch list")
                    }
                }
                .disabled(isLoading || isSwitching)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .environment(\.defaultMinListRowHeight, 28)
        .searchable(text: $searchText, prompt: "Search branches")
        .alert("New branch", isPresented: $isShowingCreateBranchPrompt) {
            TextField("remodex/my-feature", text: $newBranchName)
            Button("Cancel", role: .cancel) {
                newBranchName = ""
            }
            Button("Create") {
                let branchName = remodexNormalizedCreatedBranchName(newBranchName)
                guard !branchName.isEmpty else { return }
                onCreateBranch(branchName)
                newBranchName = ""
                dismiss()
            }
            .disabled(!isNewBranchNameValid)
        } message: {
            Text("Branch will be created locally and checked out. Uncommitted changes stay with this working copy.")
        }
    }
}

// Reuses the same row styling for both branch-switching and base-branch selection.
private struct TurnGitBranchOptionRow: View {
    let branch: String
    let isSelected: Bool
    let isDefault: Bool
    let isCurrent: Bool
    let checkedOutBadgeTitle: String?
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(branch)
                    .font(AppFont.mono(.subheadline))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if isCurrent {
                        TurnGitBranchBadge(title: "Current")
                    }
                    if isDefault {
                        TurnGitBranchBadge(title: "Default")
                    }
                    if let checkedOutBadgeTitle {
                        TurnGitBranchBadge(title: checkedOutBadgeTitle)
                    }
                }
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

private struct TurnGitBranchBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppFont.mono(.caption2))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.secondarySystemFill), in: Capsule())
    }
}

#Preview("Branch Picker") {
    TurnGitBranchPickerSheet(
        branches: [
            "feature/auth-flow",
            "feature/dark-mode",
            "remodex/onboarding-v2",
            "remodex/sidebar-refactor",
            "fix/crash-on-launch",
            "fix/memory-leak-timeline",
            "chore/bump-dependencies",
            "experiment/new-composer"
        ],
        gitBranchesCheckedOutElsewhere: ["feature/dark-mode"],
        gitWorktreePathsByBranch: ["feature/dark-mode": "/tmp/worktree"],
        selectedBranch: "remodex/onboarding-v2",
        defaultBranch: "main",
        currentBranch: "remodex/onboarding-v2",
        allowsSelectingCurrentBranch: true,
        sectionTitle: "Branches",
        navigationTitle: "Current Branch",
        isLoading: false,
        isSwitching: false,
        onSelect: { _ in },
        onCreateBranch: { _ in },
        onRefresh: {}
    )
    .frame(width: 360, height: 400)
    .preferredColorScheme(.dark)
}
