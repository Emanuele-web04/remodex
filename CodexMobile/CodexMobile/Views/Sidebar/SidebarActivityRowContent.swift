// FILE: SidebarActivityRowContent.swift
// Purpose: Two-line Activity row with project context and checkout diff totals.
// Layer: View Component

import SwiftUI

struct SidebarActivityRowContent: View {
    let thread: CodexThread
    let projectLabel: String?
    let diffTotals: GitDiffTotals?
    let onTap: () -> Void

    @Environment(CodexService.self) private var codex

    private var runBadgeState: CodexThreadRunBadgeState? {
        codex.threadRunBadgeState(for: thread.id)
    }

    var body: some View {
        // Observe inside the context-menu hosting root, before the button's
        // escaping label closure, so runtime updates invalidate this row.
        let runBadgeState = self.runBadgeState
        HapticButton(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Text(thread.displayTitle)
                        .font(AppFont.body())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if showsStatusIcon || thread.automationSource != nil || runBadgeState != nil {
                        HStack(spacing: 14) {
                            SidebarThreadSourceLabel(thread: thread, pointSize: 14)
                            if showsStatusIcon {
                                SidebarThreadStatusIcon(thread: thread, pointSize: 14, prioritizesWorktree: true)
                            }
                            if let runBadgeState {
                                SidebarThreadRunBadgeView(state: runBadgeState, spinnerSize: 15)
                                    .frame(width: 16)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        RemodexIcon.image(systemName: projectLabel == nil ? "bubble.left" : "folder", size: 13)
                        Text(projectLabel ?? "Chats")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let diffTotals, diffTotals.hasChanges {
                        HStack(spacing: 5) {
                            if diffTotals.additions > 0 || diffTotals.deletions > 0 {
                                Text("+\(formattedCount(diffTotals.additions))")
                                    .foregroundStyle(.green)
                                Text("−\(formattedCount(diffTotals.deletions))")
                                    .foregroundStyle(.red)
                            }
                            if diffTotals.binaryFiles > 0 {
                                Text("B\(diffTotals.binaryFiles)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(AppFont.mono(.caption))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(diffAccessibilityLabel(diffTotals))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        #if DEBUG
        .onChange(of: runBadgeState, initial: true) { _, badge in
            guard AppEnvironment.verboseDiagnosticsEnabled else { return }
            print("[SidebarActivityRow] thread=\(thread.id) badge=\(String(describing: badge))")
        }
        #endif
    }

    private var showsStatusIcon: Bool {
        thread.isManagedWorktreeProject || (thread.isForkedThread && !thread.isSubagent)
    }

    private func formattedCount(_ value: Int) -> String {
        guard value >= 1_000 else { return value.formatted(.number.grouping(.never)) }
        let divisor: Double = value >= 1_000_000 ? 1_000_000 : 1_000
        let suffix = value >= 1_000_000 ? "M" : "K"
        return (Double(value) / divisor).formatted(.number.precision(.fractionLength(0...1))) + suffix
    }

    private func diffAccessibilityLabel(_ totals: GitDiffTotals) -> String {
        var parts: [String] = []
        if totals.additions > 0 || totals.deletions > 0 {
            parts.append("\(totals.additions) lines added, \(totals.deletions) lines removed")
        }
        if totals.binaryFiles > 0 {
            parts.append(totals.binaryFiles == 1 ? "1 binary file changed" : "\(totals.binaryFiles) binary files changed")
        }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
#Preview("Activity row details") {
    VStack(spacing: 8) {
        SidebarActivityRowContent(
            thread: CodexThread(
                id: "preview-worktree",
                title: "Investigate Codex Activity bar for Remodex",
                cwd: "/Users/dev/.codex/worktrees/0672/remodex",
                worktreeOriginPath: "/Users/dev/remodex"
            ),
            projectLabel: "remodex",
            diffTotals: GitDiffTotals(additions: 2_200, deletions: 3),
            onTap: {}
        )
        SidebarActivityRowContent(
            thread: CodexThread(id: "preview-local", title: "Add keyboard cleaning mode", cwd: "/Users/dev/lateraldock"),
            projectLabel: "lateraldock",
            diffTotals: GitDiffTotals(additions: 852, deletions: 17),
            onTap: {}
        )
    }
    .padding(.horizontal, 10)
    .environment(activityRowPreviewService())
}

@MainActor
private func activityRowPreviewService() -> CodexService {
    let service = CodexService(defaults: UserDefaults(suiteName: "SidebarActivityRowPreview") ?? .standard)
    service.runningThreadIDs = ["preview-worktree", "preview-local"]
    return service
}
#endif
