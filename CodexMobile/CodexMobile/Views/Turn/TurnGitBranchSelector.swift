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
        switch self {
        case .currentBranch:
            return "Current branch"
        case .pullRequestTarget:
            return "PR target"
        }
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
    private let inlineBranchLimit = 12
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

    private func prioritizedNonDefaultGitBranches(selectedBranch: String) -> [String] {
        var prioritizedBranches = nonDefaultGitBranches
        if selectedBranch != normalizedDefaultBranch,
           let selectedIndex = prioritizedBranches.firstIndex(of: selectedBranch) {
            let selected = prioritizedBranches.remove(at: selectedIndex)
            prioritizedBranches.insert(selected, at: 0)
        }
        return prioritizedBranches
    }

    private func inlineGitBranches(selectedBranch: String) -> [String] {
        Array(prioritizedNonDefaultGitBranches(selectedBranch: selectedBranch).prefix(inlineBranchLimit))
    }

    private var hasOverflowBranches: Bool {
        nonDefaultGitBranches.count > inlineBranchLimit
    }

    var body: some View {
        Menu {
            Section("Current branch") {
                branchOptions(
                    selectedBranch: normalizedCurrentBranch,
                    browseMode: .currentBranch,
                    onSelect: onSelectGitBranch
                )
            }

            Section("PR target") {
                branchOptions(
                    selectedBranch: effectiveGitBaseBranch,
                    browseMode: .pullRequestTarget,
                    onSelect: onSelectGitBaseBranch
                )
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

    @ViewBuilder
    private func branchOptions(
        selectedBranch: String,
        browseMode: TurnGitBranchPickerMode,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        if let normalizedDefaultBranch {
            let isCurrentBranchTarget = browseMode == .pullRequestTarget && normalizedDefaultBranch == normalizedCurrentBranch
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onSelect(normalizedDefaultBranch)
            } label: {
                if selectedBranch == normalizedDefaultBranch {
                    Label("\(normalizedDefaultBranch) (default)", systemImage: "checkmark")
                } else {
                    Text("\(normalizedDefaultBranch) (default)")
                }
            }
            .disabled(branchControlsDisabled || isCurrentBranchTarget)
        }

        ForEach(inlineGitBranches(selectedBranch: selectedBranch), id: \.self) { branch in
            let isCurrentBranchTarget = browseMode == .pullRequestTarget && branch == normalizedCurrentBranch
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onSelect(branch)
            } label: {
                if selectedBranch == branch {
                    Label(branch, systemImage: "checkmark")
                } else {
                    Text(branch)
                }
            }
            .disabled(branchControlsDisabled || isCurrentBranchTarget)
        }

        if hasOverflowBranches {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                activePickerMode = browseMode
            } label: {
                Text("Browse all branches (\(nonDefaultGitBranches.count))...")
            }
            .disabled(branchControlsDisabled)
        }
    }
}

private struct TurnGitBranchPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let branches: [String]
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
                        Button {
                            onSelect(defaultBranch)
                            dismiss()
                        } label: {
                            if selectedBranch == defaultBranch {
                                Label("\(defaultBranch) (default)", systemImage: "checkmark")
                            } else {
                                Text("\(defaultBranch) (default)")
                            }
                        }
                        .disabled(isLoading || isSwitching || isCurrentBranchTarget)
                    }

                    ForEach(filteredBranches, id: \.self) { branch in
                        let isCurrentBranchTarget = !allowsSelectingCurrentBranch && branch == currentBranch
                        Button {
                            onSelect(branch)
                            dismiss()
                        } label: {
                            if selectedBranch == branch {
                                Label(branch, systemImage: "checkmark")
                            } else {
                                Text(branch)
                            }
                        }
                        .disabled(isLoading || isSwitching || isCurrentBranchTarget)
                    }

                    if filteredBranches.isEmpty {
                        Text("No branches found")
                            .foregroundStyle(.secondary)
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
