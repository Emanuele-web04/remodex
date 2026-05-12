// FILE: SubagentViews.swift
// Purpose: UI components for multi-agent orchestration cards in the timeline.
// Layer: View Components
// Exports: SubagentActionCard
// Depends on: SwiftUI, CodexService, CodexSubagentAction, CodexSubagentThreadPresentation, AppFont

import SwiftUI

// MARK: - Card (timeline-level container)

struct SubagentActionCard: View {
    let parentThreadId: String
    let action: CodexSubagentAction
    let isStreaming: Bool
    let onOpenSubagent: ((CodexSubagentThreadPresentation) -> Void)?

    @Environment(CodexService.self) private var codex
    @State private var isExpanded = true
    @State private var selectedAgentDetails: CodexSubagentThreadPresentation?

    var body: some View {
        let _ = codex.subagentIdentityVersion
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            if isExpanded, !action.agentRows.isEmpty {
                VStack(alignment: .leading, spacing: agentRowSpacing) {
                    ForEach(action.agentRows) { agent in
                        agentRowView(agent)
                    }
                }
                .padding(.top, agentRowsTopPadding)
            }

            if isStreaming {
                TypingIndicator()
                    .padding(.top, action.agentRows.isEmpty ? 2 : 3)
            }
        }
        .task(id: action.agentRows.map(\.threadId)) {
            await hydrateChildThreadMetadata()
        }
        .sheet(item: $selectedAgentDetails) { agent in
            let resolved = codex.resolvedSubagentPresentation(agent, parentThreadId: parentThreadId)
            let title = resolvedAgentTitle(for: resolved)
            SubagentAgentDetailSheet(
                title: title,
                accentColor: SubagentLabelParser.nicknameColor(for: title),
                statusText: readableStatus(resolvedStatus(for: resolved).label),
                modelTitle: resolved.modelIsRequestedHint ? "Requested model" : "Model",
                modelLabel: resolvedModelLabel(for: resolved, prefixRequested: false),
                instructionText: trimmedValue(resolved.prompt) ?? trimmedValue(action.prompt),
                latestUpdateText: trimmedValue(resolved.fallbackMessage),
                onOpen: onOpenSubagent.map { openSubagent in
                    {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        selectedAgentDetails = nil
                        openSubagent(resolved)
                    }
                }
            )
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(action.summaryText)
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(AppFont.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }

    // MARK: - Agent row

    @ViewBuilder
    private func agentRowView(_ agent: CodexSubagentThreadPresentation) -> some View {
        let resolved = codex.resolvedSubagentPresentation(agent, parentThreadId: parentThreadId)
        let title = resolvedAgentTitle(for: resolved)
        let status = resolvedStatus(for: resolved)
        let detailModelLabel = resolvedModelLabel(for: resolved)

        SubagentAgentRowView(
            title: title,
            status: status,
            statusText: readableStatus(status.label),
            modelLabel: action.normalizedTool == "spawnagent" ? nil : detailModelLabel,
            showsDetails: detailText(for: resolved) != nil || detailModelLabel != nil,
            onShowDetails: {
                HapticFeedback.shared.triggerImpactFeedback(style: .soft)
                selectedAgentDetails = resolved
            },
            onOpen: onOpenSubagent.map { openSubagent in
                {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    selectedAgentDetails = nil
                    openSubagent(resolved)
                }
            }
        )
    }

    // MARK: - Resolution helpers

    private var agentRowSpacing: CGFloat {
        switch action.normalizedTool {
        case "wait", "waitagent", "resumeagent": return 9
        case "spawnagent": return 2
        default: return 4
        }
    }

    private var agentRowsTopPadding: CGFloat {
        switch action.normalizedTool {
        case "wait", "waitagent", "resumeagent": return 3
        default: return 2
        }
    }

    private func resolvedAgentTitle(for agent: CodexSubagentThreadPresentation) -> String {
        codex.resolvedSubagentDisplayLabel(threadId: agent.threadId, agentId: agent.agentId)
            ?? agent.displayLabel
    }

    private func resolvedModelLabel(
        for agent: CodexSubagentThreadPresentation,
        prefixRequested: Bool = true
    ) -> String? {
        if let model = sanitizedSubagentModelLabel(agent.model) {
            return agent.modelIsRequestedHint && prefixRequested ? "requested: \(model)" : model
        }

        guard let thread = observedThread(for: agent) else { return nil }

        if let model = sanitizedSubagentModelLabel(thread.model) {
            return model
        }

        return sanitizedSubagentModelLabel(thread.modelProvider)
    }

    private func resolvedStatus(for agent: CodexSubagentThreadPresentation) -> SubagentStatusPresentation {
        if codex.runningThreadIDs.contains(agent.threadId) || codex.activeTurnIdByThread[agent.threadId] != nil {
            return SubagentStatusPresentation(rawStatus: "running")
        }
        if let terminal = codex.latestTurnTerminalStateByThread[agent.threadId] {
            switch terminal {
            case .completed: return SubagentStatusPresentation(rawStatus: "completed")
            case .failed: return SubagentStatusPresentation(rawStatus: "failed")
            case .stopped: return SubagentStatusPresentation(rawStatus: "stopped")
            }
        }
        if agent.fallbackStatus == nil {
            return SubagentStatusPresentation(rawStatus: action.status)
        }
        return SubagentStatusPresentation(rawStatus: agent.fallbackStatus)
    }

    private func observedThread(for agent: CodexSubagentThreadPresentation) -> CodexThread? {
        codex.threads.first(where: { $0.id == agent.threadId })
    }

    private func readableStatus(_ label: String) -> String {
        switch action.normalizedTool {
        case "spawnagent":
            switch label {
            case "running": return "Starting child thread"
            case "completed": return "Child thread created"
            case "failed": return "Could not create child thread"
            case "stopped": return "Spawn interrupted"
            case "queued": return "Queued for spawn"
            default: return "Preparing child thread"
            }
        case "wait", "waitagent":
            switch label {
            case "running": return "Still working"
            case "completed": return "Finished"
            case "failed": return "Finished with error"
            case "stopped": return "Stopped early"
            case "queued": return "Queued"
            default: return "Waiting for updates"
            }
        case "sendinput":
            switch label {
            case "running": return "Working on new instructions"
            case "completed": return "Processed the update"
            case "failed": return "Update failed"
            case "stopped": return "Update interrupted"
            case "queued": return "Queued update"
            default: return "Instructions sent"
            }
        case "resumeagent":
            switch label {
            case "running": return "Back to work"
            case "completed": return "Resumed and completed"
            case "failed": return "Resume failed"
            case "stopped": return "Resume interrupted"
            case "queued": return "Queued to resume"
            default: return "Resuming agent"
            }
        case "closeagent":
            switch label {
            case "running": return "Closing"
            case "completed": return "Closed"
            case "failed": return "Close failed"
            case "stopped": return "Close interrupted"
            case "queued": return "Queued to close"
            default: return "Closing agent"
            }
        default:
            switch label {
            case "running": return "Working now"
            case "completed": return "Completed"
            case "failed": return "Ended with error"
            case "stopped": return "Stopped"
            case "queued": return "Queued"
            default: return "Idle"
            }
        }
    }

    private func detailText(for agent: CodexSubagentThreadPresentation) -> String? {
        var sections: [String] = []
        if let prompt = trimmedValue(agent.prompt) ?? trimmedValue(action.prompt) {
            sections.append(prompt)
        }
        if let statusMessage = trimmedValue(agent.fallbackMessage),
           !sections.contains(statusMessage) {
            sections.append(sections.isEmpty ? statusMessage : "Latest update: \(statusMessage)")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private func trimmedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitizedSubagentModelLabel(_ value: String?) -> String? {
        guard let trimmed = trimmedValue(value) else { return nil }
        if trimmed.lowercased() == "openai" {
            return nil
        }
        return trimmed
    }

    // Fetches thread metadata for child threads so names resolve without
    // navigating into each subagent thread first.
    private func hydrateChildThreadMetadata() async {
        await codex.loadSubagentThreadMetadataIfNeeded(threadIds: action.agentRows.map(\.threadId))
    }
}

// MARK: - Agent row

private struct SubagentAgentRowView: View {
    let title: String
    let status: SubagentStatusPresentation
    let statusText: String
    let modelLabel: String?
    let showsDetails: Bool
    let onShowDetails: (() -> Void)?
    let onOpen: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            openButtonContent

            if showsDetails, let onShowDetails {
                Button(action: onShowDetails) {
                    Image(systemName: "info.circle")
                        .font(AppFont.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var openButtonContent: some View {
        if let onOpen {
            Button(action: onOpen) { rowContent }
                .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 10) {
            labelText

            Spacer(minLength: 8)

            if let modelLabel, !modelLabel.isEmpty {
                Text(modelLabel)
                    .font(AppFont.mono(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            if onOpen != nil {
                Image(systemName: "chevron.right")
                    .font(AppFont.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var labelText: some View {
        (
            SubagentLabelParser.styledText(for: title, roleSuffixColor: .primary)
            + Text(" \(statusText)")
                .foregroundColor(.secondary)
        )
        .font(AppFont.caption())
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

// MARK: - Detail sheet

private struct SubagentAgentDetailSheet: View {
    let title: String
    let accentColor: Color
    let statusText: String
    let modelTitle: String
    let modelLabel: String?
    let instructionText: String?
    let latestUpdateText: String?
    let onOpen: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusSection

                    if let modelLabel, !modelLabel.isEmpty {
                        detailSection(title: modelTitle, value: modelLabel, monospace: true)
                    }

                    if let instructionText, !instructionText.isEmpty {
                        detailSection(title: "Instructions", value: instructionText)
                    }

                    if let latestUpdateText, !latestUpdateText.isEmpty {
                        detailSection(title: "Latest update", value: latestUpdateText)
                    }

                    if instructionText == nil, latestUpdateText == nil {
                        Text("No extra details yet.")
                            .font(AppFont.footnote())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { titleText }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let onOpen {
                    Button {
                        dismiss()
                        onOpen()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Open child thread")
                            Image(systemName: "arrow.right")
                        }
                        .font(AppFont.body(weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var titleText: some View {
        SubagentLabelParser.styledText(for: title)
            .font(AppFont.body(weight: .semibold))
            .lineLimit(1)
    }

    private var statusSection: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accentColor.opacity(0.18))
                .frame(width: 36, height: 36)
                .overlay {
                    Circle().fill(accentColor).frame(width: 10, height: 10)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Status")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(AppFont.body())
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func detailSection(title: String, value: String, monospace: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospace ? AppFont.mono(.footnote) : AppFont.footnote())
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared utilities

/// Parses "Locke [explorer]" → (nickname: "Locke", roleSuffix: " (explorer)")
enum SubagentLabelParser {
    static func parse(_ title: String) -> (nickname: String, roleSuffix: String) {
        guard title.hasSuffix("]"),
              let openBracket = title.lastIndex(of: "[") else {
            return (title, "")
        }
        let nickname = String(title[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        let roleStart = title.index(after: openBracket)
        let roleEnd = title.index(before: title.endIndex)
        let role = String(title[roleStart..<roleEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty else {
            return (nickname.isEmpty ? title : nickname, "")
        }
        let resolvedName = nickname.isEmpty ? role.capitalized : nickname
        return (resolvedName, " (\(role))")
    }

    /// Color derived from the parsed nickname — consistent across sidebar and timeline.
    static func nicknameColor(for title: String) -> Color {
        SubagentColorPalette.color(for: parse(title).nickname)
    }

    /// Pre-styled Text from already-parsed parts.
    static func styledText(
        nickname: String,
        roleSuffix: String,
        roleSuffixColor: Color = .secondary
    ) -> Text {
        Text(nickname)
            .foregroundColor(SubagentColorPalette.color(for: nickname))
            .fontWeight(.semibold)
        + Text(roleSuffix)
            .foregroundColor(roleSuffixColor)
    }

    /// Convenience: parses title first, then builds styled Text.
    static func styledText(
        for title: String,
        roleSuffixColor: Color = .secondary
    ) -> Text {
        let parts = parse(title)
        return styledText(nickname: parts.nickname, roleSuffix: parts.roleSuffix, roleSuffixColor: roleSuffixColor)
    }
}

/// Hash-stable palette — same nickname always gets the same color.
enum SubagentColorPalette {
    private static let colors: [Color] = [
        Color(red: 0.90, green: 0.30, blue: 0.30), // red
        Color(red: 0.30, green: 0.75, blue: 0.55), // green
        Color(red: 0.40, green: 0.55, blue: 0.95), // blue
        Color(red: 0.85, green: 0.60, blue: 0.25), // orange
        Color(red: 0.70, green: 0.45, blue: 0.85), // purple
        Color(red: 0.25, green: 0.78, blue: 0.82), // teal
        Color(red: 0.90, green: 0.50, blue: 0.60), // pink
        Color(red: 0.65, green: 0.75, blue: 0.30), // lime
    ]

    static func color(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

// MARK: - Status models

struct SubagentStatusPresentation {
    let rawStatus: String?

    var normalized: String {
        rawStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") ?? "unknown"
    }

    var label: String {
        switch normalized {
        case "running", "inprogress": return "running"
        case "completed", "done", "finished", "success": return "completed"
        case "failed", "error", "errored": return "failed"
        case "stopped", "cancelled", "canceled", "interrupted": return "stopped"
        case "queued", "pending": return "queued"
        default: return "idle"
        }
    }

    var tone: SubagentStatusTone {
        switch label {
        case "running": return .running
        case "completed": return .completed
        case "failed": return .failed
        case "stopped": return .stopped
        default: return .idle
        }
    }
}

enum SubagentStatusTone {
    case running, completed, failed, stopped, idle

    var color: Color {
        switch self {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .stopped: return .orange
        case .idle: return .secondary
        }
    }
}
