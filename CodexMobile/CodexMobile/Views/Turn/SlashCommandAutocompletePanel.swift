// FILE: SlashCommandAutocompletePanel.swift
// Purpose: Inline slash-command picker for composer actions like Code Review and Fork.
// Layer: View Component
// Exports: SlashCommandAutocompletePanel
// Depends on: SwiftUI, AutocompleteRowButtonStyle, TurnViewModel

import SwiftUI

struct SlashCommandAutocompletePanel: View {
    let state: TurnComposerSlashCommandPanelState
    let availableCommands: [TurnComposerSlashCommand]
    let hasComposerContentConflictingWithReview: Bool
    let isThreadRunning: Bool
    let showsGitBranchSelector: Bool
    let isLoadingGitBranchTargets: Bool
    let availableGitBranchTargets: [String]
    let selectedGitBaseBranch: String
    let gitDefaultBranch: String
    let onSelectCommand: (TurnComposerSlashCommand) -> Void
    let onSelectReviewTarget: (TurnComposerReviewTarget) -> Void
    let onSelectForkDestination: (TurnComposerForkDestination) -> Void
    let onClose: () -> Void

    private static let rowHeight: CGFloat = 50
    private static let maxVisibleRows = 6

    private static func visibleListHeight(for count: Int) -> CGFloat {
        rowHeight * CGFloat(min(count, maxVisibleRows))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .hidden:
                EmptyView()

            case .commands(let query):
                commandList(query: query)

            case .codeReviewTargets:
                reviewTargetList

            case .forkDestinations(let destinations):
                forkDestinationList(destinations: destinations)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(4)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func commandList(query: String) -> some View {
        let items = TurnComposerSlashCommand.filtered(matching: query, within: availableCommands)

        if items.isEmpty {
            Text("No commands for /\(query)")
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        let isEnabled = isCommandEnabled(item)
                        Button {
                            HapticFeedback.shared.triggerImpactFeedback(style: .light)
                            onSelectCommand(item)
                        } label: {
                            HStack(spacing: 10) {
                                commandIcon(for: item, isEnabled: isEnabled)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.commandToken)
                                        .font(AppFont.subheadline(weight: .semibold))
                                        .foregroundStyle(isEnabled ? Color.teal : .secondary)
                                        .lineLimit(1)

                                    Text(commandSubtitle(for: item))
                                        .font(AppFont.caption2())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                Text(item.title)
                                    .font(AppFont.footnote())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(AutocompleteRowButtonStyle())
                        .disabled(!isEnabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scrollIndicators(.visible)
            .frame(height: Self.visibleListHeight(for: items.count))
        }
    }

    private var reviewTargetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            submenuHeader(
                title: "Code Review",
                subtitle: "Choose what the reviewer should compare.",
                closeAccessibilityLabel: "Close code review options"
            )

            VStack(alignment: .leading, spacing: 0) {
                reviewTargetButton(
                    target: .uncommittedChanges,
                    subtitle: "Review everything currently modified in the repo",
                    isEnabled: true
                )

                if showsGitBranchSelector {
                    reviewTargetButton(
                        target: .baseBranch,
                        subtitle: baseBranchSubtitle,
                        isEnabled: isBaseBranchTargetAvailable
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func forkDestinationList(destinations: [TurnComposerForkDestination]) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            submenuHeader(
                title: "Fork",
                subtitle: forkDestinationSubtitle(for: destinations),
                closeAccessibilityLabel: "Close fork options"
            )

            VStack(alignment: .leading, spacing: 0) {
                ForEach(destinations) { destination in
                    forkDestinationButton(destination)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func forkDestinationSubtitle(for destinations: [TurnComposerForkDestination]) -> String {
        let showsLocal = destinations.contains(.local)
        let showsNewWorktree = destinations.contains(.newWorktree)

        switch (showsLocal, showsNewWorktree) {
        case (true, true):
            return "Fork this thread into local or a new worktree."
        case (true, false):
            return "Fork this thread into a new local thread."
        case (false, true):
            return "Fork this thread into a new worktree."
        default:
            return "Fork this thread."
        }
    }

    private func reviewTargetButton(
        target: TurnComposerReviewTarget,
        subtitle: String,
        isEnabled: Bool
    ) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onSelectReviewTarget(target)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(target.title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(AppFont.caption2())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(AutocompleteRowButtonStyle())
        .disabled(!isEnabled)
    }

    private func forkDestinationButton(_ destination: TurnComposerForkDestination) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onSelectForkDestination(destination)
        } label: {
            HStack(spacing: 10) {
                forkDestinationIcon(for: destination)

                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.title)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(destination.subtitle)
                        .font(AppFont.caption2())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(AutocompleteRowButtonStyle())
    }

    @ViewBuilder
    private func commandIcon(for command: TurnComposerSlashCommand, isEnabled: Bool) -> some View {
        if command == .fork {
            Image("git-branch")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .frame(width: 16, height: 16)
                .frame(width: 22)
        } else {
            Image(systemName: command.symbolName)
                .font(AppFont.system(size: 15, weight: .semibold))
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .frame(width: 22)
        }
    }

    @ViewBuilder
    private func forkDestinationIcon(for destination: TurnComposerForkDestination) -> some View {
        switch destination {
        case .local:
            Image(systemName: destination.symbolName)
                .font(AppFont.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 22)
        case .newWorktree:
            Image("git-branch")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .frame(width: 16, height: 16)
                .frame(width: 22)
        }
    }

    private var resolvedBaseBranchName: String? {
        let trimmedSelected = selectedGitBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelected.isEmpty {
            return trimmedSelected
        }

        return remodexSelectableDefaultBranch(
            defaultBranch: gitDefaultBranch,
            availableGitBranchTargets: availableGitBranchTargets
        )
    }

    private var isBaseBranchTargetAvailable: Bool {
        resolvedBaseBranchName != nil
    }

    private var baseBranchSubtitle: String {
        if let resolvedBaseBranchName {
            return "Diff against \(resolvedBaseBranchName)"
        }

        if isLoadingGitBranchTargets {
            return "Loading base branches..."
        }

        return "Pick a base branch first"
    }

    private func isCommandEnabled(_ command: TurnComposerSlashCommand) -> Bool {
        switch command {
        case .codeReview:
            return !hasComposerContentConflictingWithReview
        case .feedback:
            return true
        case .fork:
            return !isThreadRunning
        case .status:
            return true
        case .subagents:
            return true
        }
    }

    private func commandSubtitle(for command: TurnComposerSlashCommand) -> String {
        if command == .fork, isThreadRunning {
            return "Wait for the current response to finish first"
        }

        guard isCommandEnabled(command) else {
            return "Clear draft text, files, skills, and images first"
        }

        return command.subtitle
    }

    private func submenuHeader(
        title: String,
        subtitle: String,
        closeAccessibilityLabel: String
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(AppFont.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(.secondarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(closeAccessibilityLabel)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
