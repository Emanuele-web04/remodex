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
    let showsTimestampRefreshIndicator: Bool
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

    // Read here only so we can re-inject `codex` across the
    // `UIHostingController` boundary that `.uiKitContextMenu` adds: SwiftUI
    // environment values do NOT propagate through a representable-built
    // host, so without this re-injection `SidebarSubagentNameLabel` would
    // fault on `@Environment(CodexService.self)` inside the wrapped row.
    // The row body itself never touches any property on `codex`, so the
    // "no service observation in the parent row" invariant documented on
    // `SidebarSubagentNameLabel` is preserved (only that nested label
    // subscribes to `codex.subagentIdentityVersion`).
    @Environment(CodexService.self) private var codex

    @State private var renamePrompt = ThreadRenamePromptState()

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
                Color(.tertiarySystemFill).opacity(0.5)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(.horizontal, 6)
        // Re-inject `codex` so `SidebarSubagentNameLabel` (which lives
        // inside the row body and reads `@Environment(CodexService.self)`)
        // still resolves the service after `.uiKitContextMenu` wraps the
        // chain in a `UIHostingController`.
        .environment(codex)
        .uiKitContextMenu {
            SidebarThreadContextMenu(
                thread: thread,
                isPinned: isPinned,
                onCopySessionId: { UIPasteboard.general.string = thread.sessionId },
                onRename: onRename.map { _ in { renamePrompt.present(currentTitle: thread.displayTitle) } },
                onArchiveToggle: onArchiveToggle,
                onPinToggle: onPinToggle,
                onDelete: onDelete
            )
            .uiMenu()
        }
        .threadRenamePrompt(state: $renamePrompt) { newName in
            onRename?(newName)
        }
    }

    // MARK: - Parent row (no CodexService dependency)

    private var parentRow: some View {
        HapticButton(action: onTap) {
            HStack(alignment: .center, spacing: 8) {
                // Keep trailing metadata inside the main stack so long titles truncate before it.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        // Pinned glyph hidden on the row itself: pinned threads already
                        // live under the "Pinned" section header, so the per-row badge
                        // was redundant. Kept the `isPinned` plumbing for the context
                        // menu / accessibility / future use.
                        // if isPinned && !thread.isSubagent {
                        //     SidebarPinIcon(style: .rowBadge)
                        // }

                        Text(thread.displayTitle)
                            .font(AppFont.body())
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.primary)
                    }

                    if thread.syncState == .archivedLocal {
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

            expansionToggleButton

            SidebarThreadStatusIcon(thread: thread, pointSize: 12)

            if let pinnedProjectLabel, !pinnedProjectLabel.isEmpty {
                Text(pinnedProjectLabel)
                    .font(AppFont.footnote())
                    .foregroundStyle(SidebarForegroundStyle.meta)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Snapshot-only pinned rows need an honest metadata hint until opening refreshes them.
            if let runBadgeState, runBadgeState.isVisibleInSidebar {
                SidebarThreadRunBadgeView(state: runBadgeState)
                    .frame(width: 28, alignment: .trailing)
            } else if showsTimestampRefreshIndicator {
                SidebarTimestampRefreshIndicator(size: .parent)
            } else if let timingLabel {
                SidebarTimingLabel(text: timingLabel, size: .parent)
            }
        }
    }

    // MARK: - Subagent row (CodexService isolated in SubagentNameLabel)

    private var subagentRow: some View {
        HapticButton(action: onTap) {
            HStack(alignment: .center, spacing: 8) {
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
        .padding(.vertical, 6)
    }

    private var subagentTrailingMeta: some View {
        HStack(spacing: 4) {
            expansionToggleButton

            SidebarThreadStatusIcon(thread: thread, pointSize: 11)

            if showsTimestampRefreshIndicator {
                SidebarTimestampRefreshIndicator(size: .subagent)
            } else if let timingLabel {
                SidebarTimingLabel(text: timingLabel, size: .subagent)
            }
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private var expansionToggleButton: some View {
        if childSubagentCount > 0, let onToggleSubagents {
            HapticButton(action: onToggleSubagents) {
                RemodexIcon.image(systemName: isSubagentExpanded ? "chevron.down" : "chevron.right")
                    .font(AppFont.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSubagentExpanded ? "Collapse subagents" : "Expand subagents")
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
        runBadgeStateByThreadID: SidebarRowPreviewFixtures.runBadges,
        onSelectThread: { _ in },
        onCreateThreadInProjectGroup: { _ in },
        onRenameThread: { _, _ in },
        onArchiveToggleThread: { _ in },
        onDeleteThread: { _ in }
    )
    .environment(CodexService())
}
