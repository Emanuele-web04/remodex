// FILE: SidebarThreadRowView.swift
// Purpose: Displays a single sidebar conversation row.
// Layer: View Component
// Exports: SidebarThreadRowView

import SwiftUI
import UIKit

struct SidebarThreadRowView: View {
    let thread: CodexThread
    let isSelected: Bool
    let runBadgeState: CodexThreadRunBadgeState?
    let timingLabel: String?
    let diffTotals: TurnSessionDiffTotals?
    let isPinned: Bool
    let pinnedProjectLabel: String?
    let childSubagentCount: Int
    let isSubagentExpanded: Bool
    let onToggleSubagents: (() -> Void)?
    let onTap: () -> Void
    var onRename: ((String) -> Void)? = nil
    var onPinToggle: (() -> Void)? = nil
    var onArchiveToggle: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var renamePrompt = ThreadRenamePromptState()
    private let titleLeadingSlotWidth: CGFloat = 16

    var body: some View {
        Group {
            if thread.isSubagent {
                subagentRow
            } else {
                parentRow
            }
        }
        .background {
            if isSelected {
                Color(.tertiarySystemFill).opacity(0.8)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .contextMenu { contextMenuContent }
        .threadRenamePrompt(state: $renamePrompt) { newName in
            onRename?(newName)
        }
    }

    // MARK: - Parent row (no CodexService dependency)

    private var parentRow: some View {
        Button(action: { HapticFeedback.shared.triggerImpactFeedback(style: .light); onTap() }) {
            HStack(alignment: .center, spacing: 8) {
                leadingIndicatorSlot

                // Keep trailing metadata inside the main stack so long titles truncate before it.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if isPinned && !thread.isSubagent {
                            Image(systemName: "pin.fill")
                                .font(AppFont.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(thread.displayTitle)
                            .font(AppFont.body())
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.primary)
                    }

                    if let pinnedProjectLabel, !pinnedProjectLabel.isEmpty {
                        Text(pinnedProjectLabel)
                            .font(AppFont.footnote())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if thread.syncState == .archivedLocal {
                        Text("Stored locally")
                            .font(AppFont.footnote())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                parentTrailingMeta
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var parentTrailingMeta: some View {
        HStack(spacing: 6) {
            if thread.syncState == .archivedLocal {
                Text("Archived")
                    .font(AppFont.caption2())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }

            if let diffTotals {
                SidebarThreadDiffTotalsLabel(totals: diffTotals)
            }

            expansionToggleButton

            threadStatusIconSlot(pointSize: 12)

            if let timingLabel {
                Text(timingLabel)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Subagent row (CodexService isolated in SubagentNameLabel)

    private var subagentRow: some View {
        Button(action: { HapticFeedback.shared.triggerImpactFeedback(style: .light); onTap() }) {
            HStack(alignment: .center, spacing: 8) {
                leadingIndicatorSlot

                SidebarSubagentNameLabel(thread: thread)
                    .frame(maxWidth: .infinity, alignment: .leading)

                subagentTrailingMeta
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var subagentTrailingMeta: some View {
        HStack(spacing: 4) {
            expansionToggleButton

            threadStatusIconSlot(pointSize: 11)

            if let timingLabel {
                Text(timingLabel)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private var leadingIndicatorSlot: some View {
        Group {
            if let runBadgeState, !thread.isSubagent {
                SidebarThreadRunBadgeView(state: runBadgeState)
            } else {
                Color.clear
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: titleLeadingSlotWidth, alignment: .center)
    }

    @ViewBuilder
    private var expansionToggleButton: some View {
        if childSubagentCount > 0, let onToggleSubagents {
            Button(action: {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onToggleSubagents()
            }) {
                Image(systemName: isSubagentExpanded ? "chevron.down" : "chevron.right")
                    .font(AppFont.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSubagentExpanded ? "Collapse subagents" : "Expand subagents")
        }
    }

    // Keeps fork ancestry and worktree scope visually distinct in the single metadata icon slot.
    private func threadStatusIconSlot(pointSize: CGFloat) -> some View {
        Group {
            threadStatusIcon(pointSize: pointSize)
        }
        .id(threadStatusIconIdentity)
        .frame(width: pointSize + 2, alignment: .center)
    }

    // Gives SwiftUI an explicit diff key when the row flips between fork/worktree/no badge.
    private var threadStatusIconIdentity: String {
        if thread.isForkedThread {
            return "fork"
        }
        if thread.isManagedWorktreeProject {
            return "worktree"
        }
        return "none"
    }

    // Keeps fork ancestry and worktree scope visually distinct in the single metadata icon slot.
    @ViewBuilder
    private func threadStatusIcon(pointSize: CGFloat) -> some View {
        if thread.isForkedThread {
            CodexForkIcon(pointSize: pointSize)
                .foregroundStyle(.secondary)
        } else if thread.isManagedWorktreeProject {
            CodexWorktreeIcon(pointSize: pointSize, weight: .medium)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            UIPasteboard.general.string = thread.sessionId
        } label: {
            Label("Copy sessionId", systemImage: "doc.on.doc")
        }

        if onRename != nil {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                renamePrompt.present(currentTitle: thread.displayTitle)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }

        if let onArchiveToggle {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onArchiveToggle()
            } label: {
                Label(
                    thread.syncState == .archivedLocal ? "Unarchive" : "Archive",
                    systemImage: thread.syncState == .archivedLocal ? "tray.and.arrow.up" : "archivebox"
                )
            }
        }

        if let onPinToggle, thread.syncState != .archivedLocal, !thread.isSubagent {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onPinToggle()
            } label: {
                Label(
                    isPinned ? "Unpin" : "Pin",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
        }

        if let onDelete {
            Button(role: .destructive) {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onDelete()
            } label: {
                Label("Remove from Phone", systemImage: "trash")
            }
        }
    }
}

// MARK: - Subagent name label (isolates CodexService observation)

/// Owns the `@Environment(CodexService.self)` so parent thread rows
/// never observe `subagentIdentityVersion` changes.
private struct SidebarSubagentNameLabel: View {
    let thread: CodexThread
    @Environment(CodexService.self) private var codex

    var body: some View {
        let _ = codex.subagentIdentityVersion
        let source = thread.preferredSubagentLabel
            ?? codex.resolvedSubagentDisplayLabel(threadId: thread.id, agentId: thread.agentId)
            ?? "Subagent"
        let parsed = SubagentLabelParser.parse(source)
        let nickname = parsed.nickname.isEmpty || CodexThread.isGenericPlaceholderTitle(parsed.nickname) ? "Subagent" : parsed.nickname
        SubagentLabelParser.styledText(nickname: nickname, roleSuffix: parsed.roleSuffix)
            .font(AppFont.caption(weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - Preview

private enum SidebarRowPreviewFixtures {
    static let now = Date()

    // Two project groups worth of threads with subagent hierarchies
    static let allThreads: [CodexThread] = [
        // ── Project 1: auth-middleware ──
        CodexThread(id: "t1", title: "Refactor auth middleware", createdAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-60), cwd: "/Users/dev/auth-middleware"),
        CodexThread(id: "t1_a", title: "Gibbs [explorer]", createdAt: now.addingTimeInterval(-3000), updatedAt: now.addingTimeInterval(-120), cwd: "/Users/dev/auth-middleware", parentThreadId: "t1", agentNickname: "Gibbs", agentRole: "explorer"),
        CodexThread(id: "t1_b", title: "Locke [coder]", createdAt: now.addingTimeInterval(-2400), updatedAt: now.addingTimeInterval(-90), cwd: "/Users/dev/auth-middleware", parentThreadId: "t1", agentNickname: "Locke", agentRole: "coder"),
        CodexThread(id: "t1_c", title: "Reyes [reviewer]", createdAt: now.addingTimeInterval(-1800), updatedAt: now.addingTimeInterval(-300), cwd: "/Users/dev/auth-middleware", parentThreadId: "t1", agentNickname: "Reyes", agentRole: "reviewer"),
        CodexThread(id: "t2", title: "Add rate limiting", createdAt: now.addingTimeInterval(-7200), updatedAt: now.addingTimeInterval(-600), cwd: "/Users/dev/auth-middleware"),

        // ── Project 2: payments ──
        CodexThread(id: "t3", title: "Fix payment flow", createdAt: now.addingTimeInterval(-14400), updatedAt: now.addingTimeInterval(-1200), cwd: "/Users/dev/payments"),
        CodexThread(id: "t3_a", title: "Ford [planner]", createdAt: now.addingTimeInterval(-13000), updatedAt: now.addingTimeInterval(-1500), cwd: "/Users/dev/payments", parentThreadId: "t3", agentNickname: "Ford", agentRole: "planner"),
        CodexThread(id: "t4", title: "Stripe webhook retry logic", createdAt: now.addingTimeInterval(-86400), updatedAt: now.addingTimeInterval(-3600), cwd: "/Users/dev/payments"),
    ]

    static let groups: [SidebarThreadGroup] = [
        SidebarThreadGroup(
            id: "/Users/dev/auth-middleware",
            label: "auth-middleware",
            kind: .project,
            sortDate: now.addingTimeInterval(-60),
            projectPath: "/Users/dev/auth-middleware",
            threads: Array(allThreads.prefix(5))
        ),
        SidebarThreadGroup(
            id: "/Users/dev/payments",
            label: "payments",
            kind: .project,
            sortDate: now.addingTimeInterval(-1200),
            projectPath: "/Users/dev/payments",
            threads: Array(allThreads.suffix(3))
        ),
    ]

    static let runBadges: [String: CodexThreadRunBadgeState] = [
        "t1": .running,
        "t1_a": .running,
        "t1_b": .ready,
        "t3": .ready,
    ]

    static let diffTotals: [String: TurnSessionDiffTotals] = [
        "t1": TurnSessionDiffTotals(additions: 42, deletions: 17, distinctDiffCount: 5),
        "t2": TurnSessionDiffTotals(additions: 8, deletions: 3, distinctDiffCount: 2),
        "t3": TurnSessionDiffTotals(additions: 120, deletions: 55, distinctDiffCount: 12),
    ]

    static func timingLabel(for thread: CodexThread) -> String? {
        guard let updated = thread.updatedAt else { return nil }
        let seconds = Int(now.timeIntervalSince(updated))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}

#Preview("Sidebar with Subagents") {
    SidebarThreadListView(
        isConnected: true,
        isCreatingThread: false,
        threads: SidebarRowPreviewFixtures.allThreads,
        groups: SidebarRowPreviewFixtures.groups,
        selectedThread: SidebarRowPreviewFixtures.allThreads[2], // Locke selected
        bottomContentInset: 80,
        timingLabelProvider: SidebarRowPreviewFixtures.timingLabel,
        diffTotalsByThreadID: SidebarRowPreviewFixtures.diffTotals,
        runBadgeStateByThreadID: SidebarRowPreviewFixtures.runBadges,
        onSelectThread: { _ in },
        onCreateThreadInProjectGroup: { _ in },
        onRenameThread: { _, _ in },
        onArchiveToggleThread: { _ in },
        onDeleteThread: { _ in }
    )
    .environment(CodexService())
}

// MARK: - Diff totals

private struct SidebarThreadDiffTotalsLabel: View {
    let totals: TurnSessionDiffTotals

    var body: some View {
        DiffCountsLabel(additions: totals.additions, deletions: totals.deletions)
            .font(AppFont.mono(.caption2))
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Conversation diff total")
            .accessibilityValue("+\(totals.additions) -\(totals.deletions)")
    }
}
