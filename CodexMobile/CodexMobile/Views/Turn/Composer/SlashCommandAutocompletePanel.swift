// FILE: SlashCommandAutocompletePanel.swift
// Purpose: Inline slash-command picker (V2 sectioned panel for OpenCode bridge; flat list for Codex enum).
// Layer: View Component
// Exports: SlashCommandAutocompletePanel
// Depends on: SwiftUI, AutocompleteRowButtonStyle, RuntimeProviderLogoView, TurnViewModel, ComposerAutocompletePanelHeight

import SwiftUI

struct SlashCommandAutocompletePanel: View {
    let state: TurnComposerSlashCommandPanelState
    let availableCommands: [TurnComposerSlashCommandItem]
    let groupedBridgeSlashSections: [(section: SlashCommandSection, commands: [BridgeSlashCommand])]
    let supportsSlashCommands: Bool
    let supportsSlashCommandExecute: Bool
    let usesBridgeSlashCommands: Bool
    let isLoadingBridgeSlashCommands: Bool
    let showsBridgeSlashCommandsEmptyHint: Bool
    let bridgeSlashCommandsLoadError: String?
    let onRetryBridgeSlashCommands: () -> Void
    let supportsThreadFork: Bool
    let hasComposerContentConflictingWithReview: Bool
    let isThreadRunning: Bool
    let showsGitBranchSelector: Bool
    let isLoadingGitBranchTargets: Bool
    let availableGitBranchTargets: [String]
    let selectedGitBaseBranch: String
    let gitDefaultBranch: String
    let onSelectCommand: (TurnComposerSlashCommandItem) -> Void
    let onSelectReviewTarget: (TurnComposerReviewTarget) -> Void
    let onSelectForkDestination: (TurnComposerForkDestination) -> Void
    let onClose: () -> Void
    var onSeeAll: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .subheadline) private var codexRowHeight: CGFloat = 50
    @ScaledMetric(relativeTo: .subheadline) private var bridgeRowHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .caption) private var sectionHeaderHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var commandsCountHeaderHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var seeAllRowHeight: CGFloat = 32

    // Keep the floating composer menu compact above the iOS keyboard.
    private static let codexMaxVisibleRows = 4

    private func codexVisibleListHeight(count: Int) -> CGFloat {
        codexRowHeight * CGFloat(min(count, Self.codexMaxVisibleRows))
    }

    private func bridgeInlineListHeight(filteredCount: Int, sectionCount: Int, screenHeight: CGFloat) -> CGFloat {
        let sectionAllowance = ComposerAutocompletePanelHeight.sectionHeaderAllowance(
            sectionCount: sectionCount,
            sectionHeaderHeight: sectionHeaderHeight
        )
        return ComposerAutocompletePanelHeight.cappedListHeight(
            rowHeight: bridgeRowHeight,
            headerHeights: sectionAllowance,
            rowCount: filteredCount,
            screenHeight: screenHeight
        )
    }

    var body: some View {
        panelContent(screenHeight: ComposerAutocompletePanelHeight.screenHeightForCap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func panelContent(screenHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .hidden:
                EmptyView()

            case .commands(let query):
                commandList(query: query, screenHeight: screenHeight)

            case .codeReviewTargets:
                reviewTargetList

            case .forkDestinations(let destinations):
                forkDestinationList(destinations: destinations)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func commandList(query: String, screenHeight: CGFloat) -> some View {
        if usesBridgeSlashCommands {
            bridgeCommandListV2(query: query, screenHeight: screenHeight)
        } else {
            codexCommandList(query: query)
        }
    }

    @ViewBuilder
    private func codexCommandList(query: String) -> some View {
        let items = TurnComposerSlashCommandItem.filtered(matching: query, within: availableCommands)

        VStack(alignment: .leading, spacing: 0) {
            slashCapabilityBanner

            if isLoadingBridgeSlashCommands {
                slashLoadingRow
            } else if items.isEmpty {
                slashEmptyState(query: query, hasFilteredItems: false)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            codexCommandRow(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollIndicators(.visible)
                .frame(height: codexVisibleListHeight(count: items.count))
            }
        }
    }

    @ViewBuilder
    private func bridgeCommandListV2(query: String, screenHeight: CGFloat) -> some View {
        let filteredCount = groupedBridgeSlashSections.reduce(0) { $0 + $1.commands.count }
        let sectionCount = groupedBridgeSlashSections.count

        VStack(alignment: .leading, spacing: 0) {
            slashCapabilityBanner

            if isLoadingBridgeSlashCommands {
                slashLoadingRow
            } else if filteredCount == 0 {
                slashEmptyState(query: query, hasFilteredItems: false)
            } else {
                if filteredCount > 0 {
                    HStack(spacing: 6) {
                        Text("Commands")
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("(\(filteredCount))")
                            .font(AppFont.subheadline(weight: .regular))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(height: commandsCountHeaderHeight, alignment: .center)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedBridgeSlashSections, id: \.section) { group in
                            bridgeSectionHeader(group.section.displayTitle)
                            ForEach(group.commands) { command in
                                bridgeCommandRow(command, section: group.section)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollIndicators(.visible)
                .frame(height: bridgeInlineListHeight(
                    filteredCount: filteredCount,
                    sectionCount: sectionCount,
                    screenHeight: screenHeight
                ))
                .clipped()

                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onSeeAll?()
                } label: {
                    HStack(spacing: 6) {
                        Text("See all")
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.indigo)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: seeAllRowHeight, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AutocompleteRowButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var slashCapabilityBanner: some View {
        if !supportsSlashCommands {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(AppFont.caption2())
                    .foregroundStyle(.secondary)
                Text("Slash commands not supported by this runtime")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var slashLoadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading commands…")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func slashEmptyState(query: String, hasFilteredItems: Bool) -> some View {
        if usesBridgeSlashCommands,
           let bridgeSlashCommandsLoadError,
           query.isEmpty,
           !hasFilteredItems {
            bridgeSlashCommandsFailureView(message: bridgeSlashCommandsLoadError)
        } else if showsBridgeSlashCommandsEmptyHint, query.isEmpty {
            Text("No commands for this project")
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            Text("No commands for /\(query)")
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    private func bridgeSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: sectionHeaderHeight, alignment: .bottomLeading)
    }

    private func bridgeCommandRow(_ command: BridgeSlashCommand, section: SlashCommandSection) -> some View {
        let item = TurnComposerSlashCommandItem.bridge(command)
        let isEnabled = bridgeSlashRowIsEnabled(command: command)
        return Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onSelectCommand(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    RuntimeProviderLogoView(
                        provider: command.resolvedProviderID(for: section),
                        size: 14
                    )

                    Text(command.token)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.indigo)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(command.title)
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let description = Self.descriptionLabel(from: command.description) {
                    Text(description)
                        .font(AppFont.caption2())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: bridgeRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(AutocompleteRowButtonStyle())
        .capabilityGreyOut(
            isEnabled: isEnabled,
            reason: bridgeSlashRowDisabledReason(command: command)
        )
    }

    private func bridgeSlashRowIsEnabled(command: BridgeSlashCommand) -> Bool {
        guard supportsSlashCommands else { return false }
        if command.requiresArguments {
            return true
        }
        return supportsSlashCommandExecute
    }

    private func bridgeSlashRowDisabledReason(command: BridgeSlashCommand) -> String? {
        if !supportsSlashCommands {
            return ComposerCapabilityCopy.capabilityReason(for: .slashCommands)
        }
        if !command.requiresArguments, !supportsSlashCommandExecute {
            return ComposerCapabilityCopy.capabilityReason(for: .slashCommandExecute)
        }
        return nil
    }

    private func codexCommandRow(_ item: TurnComposerSlashCommandItem) -> some View {
        let isEnabled = isCommandEnabled(item) && supportsSlashCommands
        let disabledReason: String? = !supportsSlashCommands
            ? ComposerCapabilityCopy.capabilityReason(for: .slashCommands)
            : (!isCommandEnabled(item) ? commandSubtitle(for: item) : nil)
        return Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onSelectCommand(item)
        } label: {
            HStack(spacing: 10) {
                commandIcon(for: item, isEnabled: isEnabled)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.commandToken)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(commandPrimaryStyle(isEnabled: isEnabled))
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
            .frame(height: codexRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(AutocompleteRowButtonStyle())
        .capabilityGreyOut(isEnabled: isEnabled, reason: disabledReason)
    }

    static func descriptionLabel(from rawDescription: String) -> String? {
        let normalized = rawDescription
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func bridgeSlashCommandsFailureView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(AppFont.caption2())
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onRetryBridgeSlashCommands()
            } label: {
                Text("Retry")
                    .font(AppFont.subheadline(weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            .frame(height: codexRowHeight)
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
            .frame(height: codexRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(AutocompleteRowButtonStyle())
    }

    @ViewBuilder
    private func commandIcon(for command: TurnComposerSlashCommandItem, isEnabled: Bool) -> some View {
        switch command {
        case .codex(let codexCommand):
            if codexCommand == .fork {
                RemodexIcon.image(systemName: "remodex.git-branch", size: 16)
                    .foregroundStyle(commandPrimaryStyle(isEnabled: isEnabled))
                    .frame(width: 22)
            } else {
                RemodexIcon.image(systemName: codexCommand.symbolName)
                    .font(AppFont.system(size: 15, weight: .semibold))
                    .foregroundStyle(commandPrimaryStyle(isEnabled: isEnabled))
                    .frame(width: 22)
            }
        case .bridge:
            RemodexIcon.image(systemName: "terminal")
                .font(AppFont.system(size: 15, weight: .semibold))
                .foregroundStyle(commandPrimaryStyle(isEnabled: isEnabled))
                .frame(width: 22)
        }
    }

    private func commandPrimaryStyle(isEnabled: Bool) -> Color {
        isEnabled ? .primary : .secondary
    }

    @ViewBuilder
    private func forkDestinationIcon(for destination: TurnComposerForkDestination) -> some View {
        switch destination {
        case .local:
            RemodexIcon.image(systemName: destination.symbolName)
                .font(AppFont.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 22)
        case .newWorktree:
            RemodexIcon.image(systemName: "remodex.git-branch", size: 16)
                .foregroundStyle(.primary)
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

    private func isCommandEnabled(_ command: TurnComposerSlashCommandItem) -> Bool {
        switch command {
        case .bridge:
            return true
        case .codex(let codexCommand):
            switch codexCommand {
            case .codeReview:
                return !hasComposerContentConflictingWithReview
            case .compact:
                return !isThreadRunning
            case .feedback:
                return true
            case .fork:
                return supportsThreadFork && !isThreadRunning
            case .status:
                return true
            case .subagents:
                return true
            }
        }
    }

    private func commandSubtitle(for command: TurnComposerSlashCommandItem) -> String {
        switch command {
        case .bridge(let bridgeCommand):
            return bridgeCommand.description
        case .codex(let codexCommand):
            if codexCommand == .fork, !supportsThreadFork {
                return "Fork not supported by this runtime"
            }

            if (codexCommand == .compact || codexCommand == .fork), isThreadRunning {
                return "Wait for the current response to finish first"
            }

            guard isCommandEnabled(command) else {
                return "Clear draft text, files, skills, and images first"
            }

            return codexCommand.subtitle
        }
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
                RemodexIcon.image(systemName: "xmark")
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
