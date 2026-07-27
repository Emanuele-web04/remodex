// FILE: SidebarThreadStatusIcon.swift
// Purpose: Single metadata icon slot used by sidebar thread rows to surface
//          either fork ancestry or worktree scope. Centralizes the diff-key
//          identity that lets SwiftUI animate the swap cleanly when a row
//          flips between fork / worktree / no badge.
// Layer: View Component
// Exports: SidebarThreadStatusIcon
// Depends on: SwiftUI, CodexThread, CodexForkIcon, CodexWorktreeIcon

import SwiftUI

struct SidebarThreadStatusIcon: View {
    let thread: CodexThread
    let pointSize: CGFloat

    var body: some View {
        Group {
            icon
        }
        .id(identity)
        .frame(width: pointSize + 2, alignment: .center)
    }

    // Subagent sessions are forked from the thread that spawned them, so the fork
    // glyph would be true but useless there: it would say "spawned by its parent"
    // on every nested row and hide the worktree scope that actually varies.
    private var showsForkBadge: Bool {
        thread.isForkedThread && !thread.isSubagent
    }

    @ViewBuilder
    private var icon: some View {
        if showsForkBadge {
            CodexForkIcon(pointSize: pointSize)
                .foregroundStyle(.secondary)
        } else if thread.isManagedWorktreeProject {
            CodexWorktreeIcon(pointSize: pointSize, weight: .medium)
                .foregroundStyle(.secondary)
        }
    }

    // Stable identity so SwiftUI replaces the view when the underlying badge
    // category changes instead of trying to morph between unrelated shapes.
    private var identity: String {
        if showsForkBadge {
            return "fork"
        }
        if thread.isManagedWorktreeProject {
            return "worktree"
        }
        return "none"
    }
}
