// FILE: SlashCommandAutocompletePanel.swift
// Purpose: Inline slash-command picker for composer actions like Code Review.
// Layer: View Component
// Exports: SlashCommandAutocompletePanel
// Depends on: SwiftUI, AutocompleteRowButtonStyle, TurnViewModel

import SwiftUI

struct SlashCommandAutocompletePanel: View {
    let state: TurnComposerSlashCommandPanelState
    let hasComposerContentConflictingWithReview: Bool
    let showsGitBranchSelector: Bool
    let isLoadingGitBranchTargets: Bool
    let selectedGitBaseBranch: String
    let gitDefaultBranch: String
    let onSelectCommand: (TurnComposerSlashCommand) -> Void
    let onSelectReviewTarget: (TurnComposerReviewTarget) -> Void
    let onClose: () -> Void

    private static let rowHeight: CGFloat = 50
    private static let maxVisibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .hidden:
                EmptyView()

            case .commands(let query):
                commandList(query: query)

            case .codeReviewTargets:
                reviewTargetList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func commandList(query: String) -> some View {
        let items = TurnComposerSlashCommand.filtered(matching: query)

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
                                Image(systemName: item.symbolName)
                                    .font(AppFont.system(size: 15, weight: .semibold))
                                    .foregroundStyle(isEnabled ? .primary : .secondary)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(AppFont.subheadline(weight: .semibold))
                                        .foregroundStyle(isEnabled ? .primary : .secondary)
                                        .lineLimit(1)

                                    Text(commandSubtitle(for: item))
                                        .font(AppFont.caption2())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                Text(item.commandToken)
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
            .scrollIndicators(.visible)
            .frame(maxHeight: Self.rowHeight * CGFloat(min(items.count, Self.maxVisibleRows)))
        }
    }

    private var reviewTargetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Code Review")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("Choose what the reviewer should compare.")
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
                .accessibilityLabel("Close code review options")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

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

    private var resolvedBaseBranchName: String? {
        let trimmedSelected = selectedGitBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelected.isEmpty {
            return trimmedSelected
        }

        let trimmedDefault = gitDefaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDefault.isEmpty ? nil : trimmedDefault
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
        case .status:
            return true
        }
    }

    private func commandSubtitle(for command: TurnComposerSlashCommand) -> String {
        guard isCommandEnabled(command) else {
            return "Clear draft text, files, skills, and images first"
        }

        return command.subtitle
    }
}
