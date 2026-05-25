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
    let entries: [TurnFileChangeSummaryEntry]
    let fallbackText: String
    let detailBodyText: String
    let messageID: String

    @Environment(\.colorScheme) private var colorScheme

    @State private var activeDiffPresentation: FileChangeSummaryDiffPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !entries.isEmpty {
                softDivider

                ForEach(entries.indices, id: \.self) { index in
                    let entry = entries[index]
                    let isLastEntry = index == entries.index(before: entries.endIndex)

                    Button {
                        activeDiffPresentation = .singleEntry(entry)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.compactPath)
                                .font(AppFont.body())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 8)

                            if entry.additions > 0 || entry.deletions > 0 {
                                DiffCountsLabel(additions: entry.additions, deletions: entry.deletions)
                                    .font(AppFont.body())
                            }

                            RemodexIcon.image(systemName: "chevron.down")
                                .font(AppFont.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !isLastEntry {
                        softDivider
                            .padding(.leading, 16)
                    }
                }
            } else if !fallbackText.isEmpty {
                Text(fallbackText)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            cardBackgroundColor,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(cardOutlineColor, lineWidth: 1)
        }
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
    private var header: some View {
        HStack(spacing: 12) {
            Image("changes")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(iconBackgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(summaryTitle)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if totalAdditions > 0 || totalDeletions > 0 {
                    DiffCountsLabel(additions: totalAdditions, deletions: totalDeletions)
                        .font(AppFont.subheadline())
                }
            }

            Spacer(minLength: 8)

            if !entries.isEmpty {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    activeDiffPresentation = .allEntries
                } label: {
                    Text("Review")
                        .font(AppFont.body(weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Color(.systemBackground).opacity(colorScheme == .dark ? 0.08 : 0.75), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(cardOutlineColor, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Review file changes")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
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
        Color(.separator).opacity(0.6)
    }

    private var summaryTitle: String {
        guard !entries.isEmpty else {
            return "File changes"
        }

        return "\(summaryActionTitle) \(entries.count) \(entries.count == 1 ? "file" : "files")"
    }

    private var summaryActionTitle: String {
        let actionTitles = Set(entries.compactMap { $0.action?.rawValue })
        return actionTitles.count == 1 ? (actionTitles.first ?? "Edited") : "Edited"
    }

    private var cardBackgroundColor: Color {
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.12, blue: 0.13)
            : Color(.systemBackground)
    }

    private var cardOutlineColor: Color {
        Color(.separator).opacity(colorScheme == .dark ? 0.52 : 0.44)
    }

    private var iconBackgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.04)
            : Color(.secondarySystemBackground).opacity(0.65)
    }
}
