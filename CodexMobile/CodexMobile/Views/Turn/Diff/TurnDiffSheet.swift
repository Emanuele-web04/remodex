// FILE: TurnDiffSheet.swift
// Purpose: Shared diff sheet UI and repo-patch presentation helpers for turn-level change inspection.
// Layer: View Component
// Exports: TurnDiffSheet, TurnDiffPresentation, TurnDiffPresentationBuilder
// Depends on: Foundation, SwiftUI, UnifiedDiffView, TurnMessageCaches, TurnFileChangeSummaryParser

import Foundation
import SwiftUI

struct TurnDiffPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let bodyText: String
    let entries: [TurnFileChangeSummaryEntry]
    let messageID: String
}

enum TurnDiffRenderingMode: Equatable {
    case detailed
    case summaryOnly(changedLineCount: Int)
}

// Detailed diffs are built entirely on the main actor. Keep an oversized patch out of the
// parser and SwiftUI line renderer so opening the change sheet can never stall the app.
enum TurnDiffRenderingPolicy {
    static let maximumDetailedChangedLines = 2_000
    static let maximumDetailedBytes = 256_000
    static let maximumDetailedLineBytes = 16_000
    static let maximumSummaryFileEntries = 200

    static func mode(
        entries: [TurnFileChangeSummaryEntry],
        bodyText: String
    ) -> TurnDiffRenderingMode {
        let entryChangedLineCount = entries.reduce(0) { $0 + $1.additions + $1.deletions }
        guard bodyText.utf8.count <= maximumDetailedBytes else {
            return .summaryOnly(changedLineCount: entryChangedLineCount)
        }

        let bodyMetrics = diffBodyMetrics(in: bodyText)
        let changedLineCount = max(entryChangedLineCount, bodyMetrics.changedLineCount)
        guard changedLineCount <= maximumDetailedChangedLines,
              bodyMetrics.longestLineByteCount <= maximumDetailedLineBytes else {
            return .summaryOnly(changedLineCount: changedLineCount)
        }
        return .detailed
    }

    private static func diffBodyMetrics(in bodyText: String) -> (
        changedLineCount: Int,
        longestLineByteCount: Int
    ) {
        var changedLineCount = 0
        var longestLineByteCount = 0

        bodyText.enumerateSubstrings(
            in: bodyText.startIndex..<bodyText.endIndex,
            options: .byLines
        ) { line, _, _, stop in
            guard let line else { return }
            let lineByteCount = line.utf8.count
            longestLineByteCount = max(longestLineByteCount, lineByteCount)

            if (line.hasPrefix("+") && !line.hasPrefix("+++"))
                || (line.hasPrefix("-") && !line.hasPrefix("---")) {
                changedLineCount += 1
            }

            if changedLineCount > maximumDetailedChangedLines
                || longestLineByteCount > maximumDetailedLineBytes {
                stop = true
            }
        }

        return (changedLineCount, longestLineByteCount)
    }
}

// A file row can be opened from a multi-file recap. Extract its section away from the
// main actor before the diff parser runs so one small file remains inspectable even when
// the aggregate turn exceeds the detailed-rendering limit.
enum TurnDiffBodyTextScope {
    static func bodyText(for path: String, in bodyText: String) -> String {
        let separator = "\n\n---\n\n"
        var sectionStart = bodyText.startIndex

        while sectionStart < bodyText.endIndex {
            let sectionEnd = bodyText.range(
                of: separator,
                range: sectionStart..<bodyText.endIndex
            )?.lowerBound ?? bodyText.endIndex
            let section = bodyText[sectionStart..<sectionEnd]
            if let lineEnd = section.firstIndex(of: "\n") {
                let firstLine = section[..<lineEnd]
                if firstLine.hasPrefix("Path:") {
                    let candidatePath = String(firstLine.dropFirst("Path:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if FileChangePathIdentity.representsSameFile(candidatePath, path) {
                        return String(section)
                    }
                }
            }

            guard let separatorRange = bodyText.range(
                of: separator,
                range: sectionStart..<bodyText.endIndex
            ) else {
                break
            }
            sectionStart = separatorRange.upperBound
        }

        return bodyText
    }
}

enum TurnDiffPresentationBuilder {
    // Converts a raw unified repo patch into the same sectioned shape the existing diff sheet already renders.
    static func repositoryPresentation(from rawPatch: String, title: String = "Repository Changes") -> TurnDiffPresentation? {
        let patch = rawPatch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !patch.isEmpty else { return nil }

        let chunks = splitUnifiedDiffByFile(patch)
        guard !chunks.isEmpty else { return nil }

        let entries = chunks.map { chunk in
            TurnFileChangeSummaryEntry(
                path: chunk.path,
                additions: chunk.additions,
                deletions: chunk.deletions,
                action: chunk.action
            )
        }

        let bodyText = chunks.map { chunk in
            let action = chunk.action?.rawValue.lowercased() ?? "edited"
            return """
            Path: \(chunk.path)
            Kind: \(action)
            Totals: +\(chunk.additions) -\(chunk.deletions)

            ```diff
            \(chunk.diff)
            ```
            """
        }
        .joined(separator: "\n\n---\n\n")

        return TurnDiffPresentation(
            id: AIUnifiedPatchParser.hash(for: patch),
            title: title,
            bodyText: bodyText,
            entries: entries,
            messageID: "repo-diff-\(AIUnifiedPatchParser.hash(for: patch))"
        )
    }

    private static func splitUnifiedDiffByFile(_ diff: String) -> [UnifiedDiffChunk] {
        let lines = diff.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        var chunks: [UnifiedDiffChunk] = []
        var currentLines: [String] = []

        func flushChunk() {
            guard !currentLines.isEmpty else { return }
            let normalizedLines = currentLines.map { $0.trimmingCharacters(in: .newlines) }
            let path = extractPath(from: normalizedLines)
            let chunkDiff = normalizedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !chunkDiff.isEmpty else {
                currentLines = []
                return
            }

            chunks.append(
                UnifiedDiffChunk(
                    path: path,
                    action: detectAction(from: normalizedLines),
                    additions: countAdditions(in: normalizedLines),
                    deletions: countDeletions(in: normalizedLines),
                    diff: chunkDiff
                )
            )
            currentLines = []
        }

        for line in lines {
            if line.hasPrefix("diff --git "), !currentLines.isEmpty {
                flushChunk()
            }
            currentLines.append(line)
        }

        flushChunk()
        return chunks
    }

    private static func extractPath(from lines: [String]) -> String {
        for line in lines {
            if line.hasPrefix("+++ ") {
                let value = normalizeDiffPath(String(line.dropFirst(4)))
                if !value.isEmpty, value != "/dev/null" {
                    return value
                }
            }
        }

        for line in lines {
            if line.hasPrefix("--- ") {
                let value = normalizeDiffPath(String(line.dropFirst(4)))
                if !value.isEmpty, value != "/dev/null" {
                    return value
                }
            }
        }

        for line in lines where line.hasPrefix("diff --git ") {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            if components.count >= 4 {
                let value = normalizeDiffPath(String(components[3]))
                if !value.isEmpty {
                    return value
                }
            }
        }

        return ""
    }

    private static func normalizeDiffPath(_ rawPath: String) -> String {
        var value = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value = String(value.dropFirst(2))
        }
        return value
    }

    private static func detectAction(from lines: [String]) -> TurnFileChangeAction? {
        if lines.contains(where: { $0.hasPrefix("rename from ") || $0.hasPrefix("rename to ") }) {
            return .renamed
        }
        if lines.contains(where: { $0.hasPrefix("new file mode ") || $0 == "--- /dev/null" }) {
            return .added
        }
        if lines.contains(where: { $0.hasPrefix("deleted file mode ") || $0 == "+++ /dev/null" }) {
            return .deleted
        }
        return .edited
    }

    private static func countAdditions(in lines: [String]) -> Int {
        lines.reduce(into: 0) { total, line in
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                total += 1
            }
        }
    }

    private static func countDeletions(in lines: [String]) -> Int {
        lines.reduce(into: 0) { total, line in
            if line.hasPrefix("-"), !line.hasPrefix("---") {
                total += 1
            }
        }
    }

    private struct UnifiedDiffChunk {
        let path: String
        let action: TurnFileChangeAction?
        let additions: Int
        let deletions: Int
        let diff: String
    }
}

struct TurnDiffSheet: View {
    let title: String
    let entries: [TurnFileChangeSummaryEntry]
    let bodyText: String
    let messageID: String
    var restrictToPath: String?

    @Environment(\.dismiss) private var dismiss
    @State private var allHunksCollapsed = false
    @State private var presentationDetent: PresentationDetent = .large
    @State private var restrictedBodyText: String?

    init(
        title: String,
        entries: [TurnFileChangeSummaryEntry],
        bodyText: String,
        messageID: String,
        restrictToPath: String? = nil
    ) {
        self.title = title
        self.entries = entries
        self.bodyText = bodyText
        self.messageID = messageID
        self.restrictToPath = restrictToPath
    }

    private var chunks: [PerFileDiffChunk] {
        let all = PerFileDiffChunkCache.chunks(
            messageID: scopedMessageID,
            bodyText: scopedBodyText,
            entries: visibleEntries
        )
        guard let restrictToPath else { return all }
        return all.filter { FileChangePathIdentity.representsSameFile($0.path, restrictToPath) }
    }

    private var scopedMessageID: String {
        guard let restrictToPath else { return messageID }
        return "\(messageID)|\(restrictToPath)"
    }

    private var scopedBodyText: String {
        restrictToPath == nil ? bodyText : (restrictedBodyText ?? "")
    }

    private var visibleEntries: [TurnFileChangeSummaryEntry] {
        guard let restrictToPath else { return entries }
        return entries.filter { FileChangePathIdentity.representsSameFile($0.path, restrictToPath) }
    }

    private var renderingMode: TurnDiffRenderingMode {
        TurnDiffRenderingPolicy.mode(entries: visibleEntries, bodyText: scopedBodyText)
    }

    private var entryTotals: (additions: Int, deletions: Int) {
        visibleEntries.reduce(into: (0, 0)) { totals, entry in
            totals.0 += entry.additions
            totals.1 += entry.deletions
        }
    }

    private var summaryEntries: ArraySlice<TurnFileChangeSummaryEntry> {
        visibleEntries.prefix(TurnDiffRenderingPolicy.maximumSummaryFileEntries)
    }

    private var hiddenSummaryEntryCount: Int {
        visibleEntries.count - summaryEntries.count
    }

    private func totals(for chunks: [PerFileDiffChunk]) -> (additions: Int, deletions: Int) {
        chunks.reduce(into: (0, 0)) { totals, chunk in
            totals.0 += chunk.additions
            totals.1 += chunk.deletions
        }
    }

    private var allExpanded: Bool {
        !allHunksCollapsed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                sheetContent
                .padding(.vertical)
                .padding(.horizontal, 12)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $presentationDetent)
        .task(id: scopedMessageID) {
            guard let restrictToPath else { return }
            let scopedText = await Task.detached(priority: .userInitiated) {
                TurnDiffBodyTextScope.bodyText(for: restrictToPath, in: bodyText)
            }
            .value
            guard !Task.isCancelled else { return }
            restrictedBodyText = scopedText
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if restrictToPath != nil, restrictedBodyText == nil {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            switch renderingMode {
            case .detailed:
                detailedContent
            case .summaryOnly(let changedLineCount):
                summaryOnlyContent(changedLineCount: changedLineCount)
            }
        }
    }

    private var detailedContent: some View {
        let chunks = chunks
        return LazyVStack(alignment: .leading, spacing: 12) {
            summaryHeader(
                fileCount: chunks.count,
                totals: totals(for: chunks),
                showsCollapseControl: !chunks.isEmpty
            )

            ForEach(chunks) { chunk in
                TurnDiffFileCard(
                    chunk: chunk,
                    collapseAllHunks: allHunksCollapsed
                )
            }
        }
    }

    private func summaryOnlyContent(changedLineCount: Int) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Large diff")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                Text(
                    "\(changedLineCount) changed lines. Full patch rendering is disabled to keep Remodex responsive."
                )
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            summaryHeader(
                fileCount: visibleEntries.count,
                totals: entryTotals,
                showsCollapseControl: false
            )

            ForEach(summaryEntries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.compactPath)
                        .font(AppFont.subheadline(weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    if entry.additions > 0 || entry.deletions > 0 {
                        DiffCountsLabel(additions: entry.additions, deletions: entry.deletions)
                            .font(AppFont.mono(.caption))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if hiddenSummaryEntryCount > 0 {
                Text("Showing the first \(summaryEntries.count) files; \(hiddenSummaryEntryCount) more are omitted.")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func summaryHeader(
        fileCount: Int,
        totals: (additions: Int, deletions: Int),
        showsCollapseControl: Bool
    ) -> some View {
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s") changed")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                if totals.additions > 0 || totals.deletions > 0 {
                    DiffCountsLabel(additions: totals.additions, deletions: totals.deletions)
                        .font(AppFont.mono(.caption))
                }
            }

            Spacer(minLength: 8)

            if showsCollapseControl {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        allHunksCollapsed.toggle()
                    }
                } label: {
                    Text(allExpanded ? "Collapse All" : "Expand All")
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TurnDiffFileCard: View {
    let chunk: PerFileDiffChunk
    let collapseAllHunks: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chunk.compactPath)
                        .font(AppFont.subheadline(weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)

                    if let dir = chunk.fullDirectoryPath, dir != chunk.compactPath {
                        Text(dir)
                            .font(AppFont.mono(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer(minLength: 8)

                if chunk.additions > 0 || chunk.deletions > 0 {
                    DiffCountsLabel(additions: chunk.additions, deletions: chunk.deletions)
                        .font(AppFont.mono(.caption))
                }

                RemodexIcon.image(systemName: "arrow.up.right")
                    .font(AppFont.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if UnifiedDiffView.canRender(diffCode: chunk.diffCode) {
                UnifiedDiffView(diffCode: chunk.diffCode, collapseAllHunks: collapseAllHunks)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
        )
    }
}
