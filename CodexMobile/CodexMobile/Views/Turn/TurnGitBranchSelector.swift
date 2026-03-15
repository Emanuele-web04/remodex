// FILE: TurnGitBranchSelector.swift
// Purpose: Hosts the local branch switcher plus the separate PR target branch picker.
// Layer: View Component
// Exports: TurnGitBranchSelector
// Depends on: SwiftUI

import SwiftUI

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
            return "PR Target"
        }
    }
}

struct TurnGitBranchSelector: View {
    let isEnabled: Bool
    let availableGitBranchTargets: [String]
    let gitBranchesCheckedOutElsewhere: Set<String>
    let selectedGitBaseBranch: String
    let currentGitBranch: String
    let defaultBranch: String
    let isLoadingGitBranchTargets: Bool
    let isSwitchingGitBranch: Bool
    let onSelectGitBranch: (String) -> Void
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
    private var effectiveGitBaseBranch: String {
        let selected = selectedGitBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty {
            return selected
        }
        if let normalizedDefaultBranch {
            return normalizedDefaultBranch
        }
        return normalizedCurrentBranch
    }
    private var visibleBranchLabel: String {
        if !normalizedCurrentBranch.isEmpty {
            return normalizedCurrentBranch
        }
        return normalizedDefaultBranch ?? "Branch"
    }

    private var nonDefaultGitBranches: [String] {
        availableGitBranchTargets.filter { branch in
            guard let normalizedDefaultBranch else { return true }
            return branch != normalizedDefaultBranch
        }
    }

    var body: some View {
        Menu {
            Section("Current branch") {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    activePickerMode = .currentBranch
                } label: {
                    Text(menuSelectionTitle(for: .currentBranch))
                }
                .disabled(branchControlsDisabled)
            }

            Section("PR target") {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    activePickerMode = .pullRequestTarget
                } label: {
                    Text(menuSelectionTitle(for: .pullRequestTarget))
                }
                .disabled(branchControlsDisabled)
            }

            Section {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onRefreshGitBranches()
                } label: {
                    if isSwitchingGitBranch {
                        Text("Switching...")
                    } else {
                        Text(isLoadingGitBranchTargets ? "Reloading..." : "Reload branch list")
                    }
                }
                .disabled(branchControlsDisabled)
            }
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
            .foregroundStyle(branchLabelColor)
            .contentShape(Rectangle())
        }
        .tint(branchLabelColor)
        .disabled(branchControlsDisabled)
        .sheet(item: $activePickerMode) { pickerMode in
            TurnGitBranchPickerSheet(
                branches: nonDefaultGitBranches,
                gitBranchesCheckedOutElsewhere: gitBranchesCheckedOutElsewhere,
                selectedBranch: pickerMode == .currentBranch ? normalizedCurrentBranch : effectiveGitBaseBranch,
                defaultBranch: normalizedDefaultBranch,
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
                onRefresh: onRefreshGitBranches
            )
            .presentationDetents([.medium, .large])
        }
    }

    // Keeps the compact menu readable while routing real selection work into the searchable sheet.
    private func menuSelectionTitle(for pickerMode: TurnGitBranchPickerMode) -> String {
        switch pickerMode {
        case .currentBranch:
            return visibleBranchLabel
        case .pullRequestTarget:
            return effectiveGitBaseBranch.isEmpty ? "Choose base branch" : effectiveGitBaseBranch
        }
    }
}

private struct TurnGitBranchPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let branches: [String]
    let gitBranchesCheckedOutElsewhere: Set<String>
    let selectedBranch: String
    let defaultBranch: String?
    let currentBranch: String
    let allowsSelectingCurrentBranch: Bool
    let sectionTitle: String
    let navigationTitle: String
    let isLoading: Bool
    let isSwitching: Bool
    let onSelect: (String) -> Void
    let onRefresh: () -> Void

    @State private var searchText = ""

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

    private var filteredBranches: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(sectionTitle) {
                    if let defaultBranch {
                        let isCurrentBranchTarget = !allowsSelectingCurrentBranch && defaultBranch == currentBranch
                        let isCheckedOutElsewhere = gitBranchesCheckedOutElsewhere.contains(defaultBranch)
                        let isDisabled = isCurrentBranchTarget || (allowsSelectingCurrentBranch && isCheckedOutElsewhere)
                        Button {
                            onSelect(defaultBranch)
                            dismiss()
                        } label: {
                            TurnGitBranchOptionRow(
                                branch: defaultBranch,
                                isSelected: selectedBranch == defaultBranch,
                                isDefault: true,
                                isCurrent: defaultBranch == currentBranch,
                                isCheckedOutElsewhere: isCheckedOutElsewhere,
                                isDisabled: isDisabled
                            )
                        }
                        .disabled(isLoading || isSwitching || isDisabled)
                    }

                    ForEach(orderedBranches, id: \.self) { branch in
                        let isCurrentBranchTarget = !allowsSelectingCurrentBranch && branch == currentBranch
                        let isCheckedOutElsewhere = gitBranchesCheckedOutElsewhere.contains(branch)
                        let isDisabled = isCurrentBranchTarget || (allowsSelectingCurrentBranch && isCheckedOutElsewhere)
                        Button {
                            onSelect(branch)
                            dismiss()
                        } label: {
                            TurnGitBranchOptionRow(
                                branch: branch,
                                isSelected: selectedBranch == branch,
                                isDefault: false,
                                isCurrent: branch == currentBranch,
                                isCheckedOutElsewhere: isCheckedOutElsewhere,
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
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search branches")
            .navigationTitle(navigationTitle)
            .adaptiveNavigationBar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onRefresh()
                    } label: {
                        if isSwitching {
                            Text("Switching...")
                        } else {
                            Text(isLoading ? "Refreshing..." : "Refresh")
                        }
                    }
                    .disabled(isLoading || isSwitching)
                }
            }
        }
    }
}

// Reuses the same row styling for both branch-switching and PR target selection.
private struct TurnGitBranchOptionRow: View {
    let branch: String
    let isSelected: Bool
    let isDefault: Bool
    let isCurrent: Bool
    let isCheckedOutElsewhere: Bool
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(branch)
                    .font(AppFont.mono(.body))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if isCurrent {
                        TurnGitBranchBadge(title: "Current")
                    }
                    if isDefault {
                        TurnGitBranchBadge(title: "Default")
                    }
                    if isCheckedOutElsewhere {
                        TurnGitBranchBadge(title: "Open elsewhere")
                    }
                }
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct TurnGitBranchBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(AppFont.mono(.caption2))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(.secondarySystemFill), in: Capsule())
    }
}
