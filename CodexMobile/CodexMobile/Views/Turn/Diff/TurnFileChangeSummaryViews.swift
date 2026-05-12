// FILE: TurnFileChangeSummaryViews.swift
// Purpose: Renders inline and turn-end file-change summaries in the timeline.
// Layer: View Component
// Exports: FileChangeInlineActionRow, FileChangeSummaryBox
// Depends on: SwiftUI, TurnDiffSheet, DiffCountsLabel

import SwiftUI

// MARK: - FileChangeInlineActionRow
// Keeps live file-change deltas as lightweight status rows while a turn is still streaming.
struct FileChangeInlineActionRow: View {
    let entry: TurnFileChangeSummaryEntry
    var showActionLabel: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showActionLabel {
                Text(entry.action?.rawValue ?? "Edited")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary.opacity(0.6))
            }

            HStack(spacing: 6) {
                Text(entry.compactPath)
                    .foregroundStyle(Color.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)

                DiffCountsLabel(additions: entry.additions, deletions: entry.deletions)
                    .font(AppFont.mono(.caption))
            }
            .font(AppFont.body())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - FileChangeSummaryBox
// Renders turn-end file edits as one compact recap instead of chat-like rows.
struct FileChangeSummaryBox: View {
    @Environment(\.colorScheme) private var colorScheme

    let entries: [TurnFileChangeSummaryEntry]
    let fallbackText: String
    let messageID: String

    // Default to expanded so the recap stays informative without an extra tap;
    // collapse remains available for long lists or visual decluttering.
    @State private var isExpanded: Bool = true
    @State private var selectedEntry: TurnFileChangeSummaryEntry?

    private var canCollapse: Bool {
        !entries.isEmpty || !fallbackText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                if !entries.isEmpty {
                    Divider()

                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        let isLastEntry = index == entries.index(before: entries.endIndex)

                        Button {
                            selectedEntry = entry
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.compactPath)
                                    .font(AppFont.subheadline())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 8)

                                if entry.additions > 0 || entry.deletions > 0 {
                                    DiffCountsLabel(additions: entry.additions, deletions: entry.deletions)
                                        .font(AppFont.mono(.caption))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if !isLastEntry {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                } else if !fallbackText.isEmpty {
                    Text(fallbackText)
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UserBubbleColor.default.bubbleBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
        }
        .padding(2)
        .sheet(item: $selectedEntry) { entry in
            TurnDiffSheet(
                title: entry.compactPath,
                entries: [entry],
                bodyText: fallbackText,
                messageID: messageID,
                restrictToPath: entry.path
            )
        }
    }

    @ViewBuilder
    private var header: some View {
        let content = HStack(spacing: 6) {
            Image(systemName: "pencil.line")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if canCollapse {
                Image(systemName: "chevron.down")
                    .font(AppFont.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, isExpanded && !entries.isEmpty ? 8 : 10)
        .contentShape(Rectangle())

        if canCollapse {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isExpanded ? "Collapse list" : "Expand list")
            .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }

    private var title: String {
        let count = entries.count
        if count == 0 {
            return "Files modified"
        }
        if count == 1 {
            return "1 file modified"
        }
        return "\(count) files modified"
    }
}
