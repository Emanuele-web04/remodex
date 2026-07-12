// FILE: TurnFileChangeSummaryViews.swift
// Purpose: Renders inline and turn-end file-change summaries in the timeline.
// Layer: View Component
// Exports: FileChangeInlineActionRow, FileChangeSummaryBox
// Depends on: SwiftUI, TurnDiffSheet, DiffCountsLabel

import SwiftUI

// Single sheet presentation source so we don't stack two `.sheet(...)` on the same view,
// which in SwiftUI can silently swap which sheet is rendered when state flips quickly.
private enum FileChangeSummaryDiffPresentation: Identifiable, Equatable {
    case singleEntry(TurnFileChangeSummaryEntry)
    case allEntries

    var id: String {
        switch self {
        case .singleEntry(let entry): return "single-\(entry.path)"
        case .allEntries: return "all"
        }
    }
}

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
                    .font(AppFont.subheadline())
            }
            .font(AppFont.body())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - FileChangeSummaryBox
// Renders turn-end file edits as one compact recap instead of chat-like rows.
struct FileChangeSummaryBox: View {
    private static let previewEntryLimit = 3

    let entries: [TurnFileChangeSummaryEntry]
    let fallbackText: String
    let detailBodyText: String
    let messageID: String

    @Environment(\.colorScheme) private var colorScheme

    // Default to expanded so the recap stays informative without an extra tap;
    // collapse remains available for long lists or visual decluttering.
    @State private var isExpanded: Bool = true
    @State private var showsAllEntries: Bool = false
    @State private var activeDiffPresentation: FileChangeSummaryDiffPresentation?

    private var canCollapse: Bool {
        !entries.isEmpty || !fallbackText.isEmpty
    }

    private var visibleEntries: ArraySlice<TurnFileChangeSummaryEntry> {
        showsAllEntries ? entries[...] : entries.prefix(Self.previewEntryLimit)
    }

    private var hiddenEntryCount: Int {
        max(0, entries.count - Self.previewEntryLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                if !entries.isEmpty {
                    softDivider

                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        let isLastEntry = index == visibleEntries.count - 1

                        Button {
                            activeDiffPresentation = .singleEntry(entry)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.compactPath)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 8)

                                if entry.additions > 0 || entry.deletions > 0 {
                                    DiffCountsLabel(additions: entry.additions, deletions: entry.deletions)
                                }
                            }
                            .font(AppFont.subheadline())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if !isLastEntry || hiddenEntryCount > 0 {
                            softDivider
                                .padding(.leading, 12)
                        }
                    }

                    if hiddenEntryCount > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showsAllEntries.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(showsAllEntries ? "Show less" : "Show more")
                                    .font(AppFont.subheadline(weight: .medium))

                                RemodexIcon.image(systemName: "chevron.down")
                                    .font(AppFont.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(showsAllEntries ? 180 : 0))
                            }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            showsAllEntries
                                ? "Show fewer file changes"
                                : "Show \(hiddenEntryCount) more file changes"
                        )
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
        .background { cardBackground }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(softDividerColor, lineWidth: 0.5)
        }
        .padding(2)
        .sheet(item: $activeDiffPresentation) { presentation in
            switch presentation {
            case .singleEntry(let entry):
                TurnDiffSheet(
                    title: entry.compactPath,
                    entries: [entry],
                    bodyText: detailBodyText,
                    messageID: messageID,
                    restrictToPath: entry.path
                )
            case .allEntries:
                TurnDiffSheet(
                    title: "Changes",
                    entries: entries,
                    bodyText: detailBodyText,
                    messageID: messageID
                )
            }
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .opacity(0.5)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Image("changes")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(.secondary)

            Text("File changes")
                .font(AppFont.subheadline(weight: .regular))
                .foregroundStyle(.secondary)

            if totalAdditions > 0 || totalDeletions > 0 {
                DiffCountsLabel(additions: totalAdditions, deletions: totalDeletions)
                    .font(AppFont.subheadline())
            }

            Spacer(minLength: 8)

            if !entries.isEmpty {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    activeDiffPresentation = .allEntries
                } label: {
                    RemodexIcon.image(systemName: "arrow.up.right")
                        .font(AppFont.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open diff")
            }

            if canCollapse {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    RemodexIcon.image(systemName: "chevron.down")
                        .font(AppFont.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse file changes" : "Expand file changes")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 4)
        .padding(.bottom, isExpanded && !entries.isEmpty ? 6 : 8)
    }

    private var totalAdditions: Int {
        entries.reduce(0) { $0 + $1.additions }
    }

    private var totalDeletions: Int {
        entries.reduce(0) { $0 + $1.deletions }
    }

    private var softDivider: some View {
        Rectangle()
            .fill(softDividerColor)
            .frame(height: 0.5)
    }

    private var softDividerColor: Color {
        Color(.separator).opacity(colorScheme == .dark ? 0.8 : 1.0)
    }
}
