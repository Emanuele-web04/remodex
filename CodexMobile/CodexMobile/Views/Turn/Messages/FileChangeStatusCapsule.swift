// FILE: FileChangeStatusCapsule.swift
// Purpose: Renders compact right-aligned Liquid Glass capsules for file-change activity.
// Layer: View Component
// Exports: FileChangeStatusSnapshot, FileChangeStatusCapsule
// Depends on: SwiftUI, TurnDiffSheet, AdaptiveGlassModifier, AppFont, HapticFeedback

import SwiftUI

struct FileChangeStatusSnapshot: Equatable {
    let fileCount: Int
    let additions: Int
    let deletions: Int
    let entries: [TurnFileChangeSummaryEntry]
    let detailBodyText: String
    let messageID: String

    var title: String {
        fileCount == 1 ? "1 file changed" : "\(fileCount) files changed"
    }

    var compactTitle: String {
        fileCount == 1 ? "1 change" : "\(fileCount) changes"
    }

    var hasChanges: Bool {
        fileCount > 0
    }

    static func activeTurnSnapshot(
        from messages: [CodexMessage],
        activeTurnID: String?,
        isThreadRunning: Bool
    ) -> FileChangeStatusSnapshot? {
        guard isThreadRunning,
              let activeTurnID = activeTurnID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !activeTurnID.isEmpty else {
            return nil
        }

        let activeFileChangeMessages = messages.filter { message in
            message.role == .system
                && message.kind == .fileChange
                && message.turnId == activeTurnID
        }
        guard !activeFileChangeMessages.isEmpty else {
            return nil
        }

        guard let presentation = FileChangeBlockPresentationBuilder.build(from: activeFileChangeMessages)
            ?? fallbackPresentation(from: activeFileChangeMessages) else {
            return nil
        }

        let additions = presentation.entries.reduce(0) { $0 + $1.additions }
        let deletions = presentation.entries.reduce(0) { $0 + $1.deletions }
        let contentFingerprint = TurnTextCacheKey.stableFingerprint(for: presentation.bodyText)
        let entriesFingerprint = TurnTextCacheKey.entriesFingerprint(presentation.entries)
        let snapshot = FileChangeStatusSnapshot(
            fileCount: presentation.entries.count,
            additions: additions,
            deletions: deletions,
            entries: presentation.entries,
            detailBodyText: presentation.bodyText,
            messageID: "active-file-change-\(activeTurnID)-\(entriesFingerprint)-\(contentFingerprint)"
        )
        return snapshot.hasChanges ? snapshot : nil
    }

    private static func fallbackPresentation(from messages: [CodexMessage]) -> FileChangeBlockPresentation? {
        var entries: [TurnFileChangeSummaryEntry] = []
        var bodyTexts: [String] = []

        for message in messages {
            guard message.text.utf8.count <= 128_000,
                  let summary = TurnFileChangeSummaryParser.parse(from: message.text) else {
                continue
            }

            entries.append(contentsOf: summary.entries)
            bodyTexts.append(message.text)
        }

        let consolidatedEntries = consolidateFallbackEntries(entries)
        guard !consolidatedEntries.isEmpty else {
            return nil
        }

        return FileChangeBlockPresentation(
            entries: consolidatedEntries,
            bodyText: bodyTexts.joined(separator: "\n\n---\n\n")
        )
    }

    private static func consolidateFallbackEntries(
        _ entries: [TurnFileChangeSummaryEntry]
    ) -> [TurnFileChangeSummaryEntry] {
        var consolidated: [TurnFileChangeSummaryEntry] = []
        consolidated.reserveCapacity(entries.count)

        for entry in entries {
            guard let existingIndex = consolidated.firstIndex(where: {
                FileChangePathIdentity.representsSameFile($0.path, entry.path)
            }) else {
                consolidated.append(entry)
                continue
            }

            let existing = consolidated[existingIndex]
            consolidated[existingIndex] = TurnFileChangeSummaryEntry(
                path: FileChangePathIdentity.preferredDisplayPath(existing.path, entry.path),
                additions: existing.additions + entry.additions,
                deletions: existing.deletions + entry.deletions,
                action: existing.action ?? entry.action
            )
        }

        return consolidated
    }
}

struct FileChangeStatusCapsule: View {
    let title: String
    var additions: Int? = nil
    var deletions: Int? = nil
    private var snapshot: FileChangeStatusSnapshot?
    @State private var isShowingDiffSheet = false

    init(snapshot: FileChangeStatusSnapshot) {
        self.title = snapshot.compactTitle
        self.additions = snapshot.additions
        self.deletions = snapshot.deletions
        self.snapshot = snapshot
    }

    init(title: String, additions: Int? = nil, deletions: Int? = nil) {
        self.title = title
        self.additions = additions
        self.deletions = deletions
        self.snapshot = nil
    }

    var body: some View {
        Group {
            if let snapshot {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    isShowingDiffSheet = true
                } label: {
                    capsuleContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open file changes diff")
                .sheet(isPresented: $isShowingDiffSheet) {
                    TurnDiffSheet(
                        title: "Changes",
                        entries: snapshot.entries,
                        bodyText: snapshot.detailBodyText,
                        messageID: snapshot.messageID
                    )
                }
            } else {
                capsuleContent
            }
        }
    }

    private var capsuleContent: some View {
        HStack(spacing: 8) {
            Image("changes")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(.secondary)

            Text(title)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.82)

            if let additions, let deletions, additions > 0 || deletions > 0 {
                FileChangeStatusDiffCountsLabel(additions: additions, deletions: deletions)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .adaptiveGlass(.regular, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        }
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct FileChangeStatusDiffCountsLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(Self.compactCount(additions))")
                .foregroundStyle(Color.green)
            Text("-\(Self.compactCount(deletions))")
                .foregroundStyle(Color.red)
        }
        .font(AppFont.subheadline(weight: .semibold))
        .lineLimit(1)
    }

    private static func compactCount(_ value: Int) -> String {
        let absoluteValue = abs(value)
        guard absoluteValue >= 1_000 else {
            return "\(value)"
        }

        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.maximumFractionDigits = absoluteValue >= 10_000 ? 0 : 1
        formatter.minimumFractionDigits = 0

        let scaledValue = Double(value) / 1_000
        let formatted = formatter.string(from: NSNumber(value: scaledValue)) ?? String(format: "%.1f", scaledValue)
        return "\(formatted)K"
    }
}

#if DEBUG
#Preview("File Change Status Capsule") {
    VStack(spacing: 14) {
        FileChangeStatusCapsule(title: "30 files changed", additions: 2700, deletions: 72)
    }
    .padding()
}
#endif
