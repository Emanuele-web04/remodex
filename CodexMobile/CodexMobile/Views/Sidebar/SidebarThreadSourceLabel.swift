// FILE: SidebarThreadSourceLabel.swift
// Purpose: Provenance marker for sidebar rows created by a desktop automation.
//          Automation forks inherit the origin thread's name, so the fork badge alone
//          leaves two identically titled rows; this names the source that made the copy.
// Layer: View Component
// Exports: SidebarThreadSourceLabel
// Depends on: SwiftUI, CodexThread, RemodexIcon, AppFont

import SwiftUI

struct SidebarThreadSourceLabel: View {
    private static let maximumLabelWidth: CGFloat = 96

    let thread: CodexThread
    // Matches the metadata icon slot next to it, so the clock lines up with the
    // fork / worktree glyph instead of introducing a second badge metric.
    let pointSize: CGFloat

    var body: some View {
        switch thread.automationSource {
        case .scheduled:
            // A scheduled run needs no word: the clock reads as "this one is on a
            // timer" at a glance and leaves the row's width to the title.
            RemodexIcon.image(systemName: "remodex.automation", size: pointSize, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: pointSize + 2, alignment: .center)
                .accessibilityLabel(CodexThreadAutomationSource.scheduled.accessibilityDescription)
        case .pullRequestFix:
            textLabel(.pullRequestFix)
        case nil:
            EmptyView()
        }
    }

    private func textLabel(_ source: CodexThreadAutomationSource) -> some View {
        Text(source.label)
            .font(AppFont.caption2())
            .foregroundStyle(SidebarForegroundStyle.meta)
            .lineLimit(1)
            .truncationMode(.tail)
            // The row's trailing metadata is laid out at its intrinsic width, so an
            // unbounded label would eat the title. Codex can add longer source names
            // than today's, and no label is worth more than this slice of the row.
            .frame(maxWidth: Self.maximumLabelWidth)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .accessibilityLabel(source.accessibilityDescription)
    }
}
