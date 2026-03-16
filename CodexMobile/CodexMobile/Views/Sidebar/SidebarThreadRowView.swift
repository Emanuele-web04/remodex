// FILE: SidebarThreadRowView.swift
// Purpose: Displays a single sidebar conversation row.
// Layer: View Component
// Exports: SidebarThreadRowView

import SwiftUI

struct SidebarThreadRowView: View {
    let thread: CodexThread
    let isSelected: Bool
    let runBadgeState: CodexThreadRunBadgeState?
    let timingLabel: String?
    let diffTotals: TurnSessionDiffTotals?
    let onTap: () -> Void
    var onRename: ((String) -> Void)? = nil
    var onArchiveToggle: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isShowingRenameAlert = false
    @State private var renameText = ""

    var body: some View {
        Button(action: {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onTap()
        }) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if let runBadgeState {
                        SidebarThreadRunBadgeView(state: runBadgeState)
                    }

                    Text(thread.displayTitle)
                        .font(AppFont.body())
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)

                // Keeps the row tail scannable: status, relative time, then compact diff total.
                HStack(spacing: 4) {
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

                    if let timingLabel {
                        Text(timingLabel)
                            .font(AppFont.footnote())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, isSelected ? 12 : 12)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    Color(.tertiarySystemFill).opacity(0.8)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .contextMenu {
            if onRename != nil {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    renameText = thread.displayTitle
                    isShowingRenameAlert = true
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

            if let onDelete {
                Button(role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .alert("Rename Conversation", isPresented: $isShowingRenameAlert) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onRename?(trimmed)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct SidebarThreadDiffTotalsLabel: View {
    let totals: TurnSessionDiffTotals

    var body: some View {
        HStack(spacing: 3) {
            Text("+\(totals.additions)")
                .foregroundStyle(Color.green)
            Text("-\(totals.deletions)")
                .foregroundStyle(Color.red)
        }
        .font(AppFont.mono(.caption2))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Conversation diff total")
        .accessibilityValue("+\(totals.additions) -\(totals.deletions)")
    }
}
