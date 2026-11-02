// FILE: TurnDiffSheet.swift
// Purpose: Shared diff sheet UI and repo-patch presentation helpers for turn-level change inspection.
// Layer: View Component
// Exports: TurnDiffSheet, TurnDiffPresentation, TurnDiffPresentationBuilder
// Depends on: Foundation, SwiftUI, UnifiedDiffView, TurnMessageCaches, TurnFileChangeSummaryParser

import Foundation
import SwiftUI

nonisolated struct TurnDiffPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let bodyText: String
    let entries: [TurnFileChangeSummaryEntry]
    let messageID: String
}

nonisolated enum TurnDiffRenderingPolicy {
    static func canRenderDetails(_ body: String) -> Bool {
        let maximumBytes = 256_000
        let maximumLines = 2_000
        let maximumLineBytes = 16_000
        guard body.utf8.count <= maximumBytes else { return false }

        var lines = 1
        var lineBytes = 0
        for byte in body.utf8 {
            if byte == 0x0A {
                lines += 1
                lineBytes = 0
                if lines > maximumLines { return false }
            } else {
                lineBytes += 1
                if lineBytes > maximumLineBytes { return false }
            }
        }
        return true
    }

    // Large aggregate changes can still contain a small, inspectable file.
    static func section(for path: String, in body: String) -> String? {
        let separator = "\n\n---\n\n"
        var start = body.startIndex
        while start < body.endIndex {
            let boundary = body.range(of: separator, range: start..<body.endIndex)
            let section = body[start..<(boundary?.lowerBound ?? body.endIndex)]
            let header = section.prefix(while: { !$0.isNewline })
            if let candidate = PerFileDiffParser.pathFromHeader(String(header)),
               FileChangePathIdentity.representsSameFile(candidate, path) {
                return String(section)
            }
            guard let boundary else { break }
            start = boundary.upperBound
        }
        return nil
    }
}

nonisolated enum TurnDiffPresentationBuilder {
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

        let bodyText = TurnDiffRenderingPolicy.canRenderDetails(patch) ? chunks.map { chunk in
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
        .joined(separator: "\n\n---\n\n") : patch

        let patchID = AIUnifiedPatchParser.hash(for: patch)
        return TurnDiffPresentation(
            id: patchID,
            title: title,
            bodyText: bodyText,
            entries: entries,
            messageID: "repo-diff-\(patchID)"
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
    let restrictToPath: String?
    private let canRenderBodyDetails: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var scopedBodyText: String?
    @State private var allHunksCollapsed = false
    @State private var presentationDetent: PresentationDetent = .large

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
        self.canRenderBodyDetails = TurnDiffRenderingPolicy.canRenderDetails(bodyText)
    }

    private var visibleEntries: [TurnFileChangeSummaryEntry] {
        guard let restrictToPath else { return entries }
        return entries.filter { FileChangePathIdentity.representsSameFile($0.path, restrictToPath) }
    }

    private var needsScopedBody: Bool {
        restrictToPath != nil && !canRenderBodyDetails
    }

    @ViewBuilder
    private var content: some View {
        if canRenderBodyDetails {
            detailedContent(bodyText)
        } else if needsScopedBody, scopedBodyText == nil {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let detail = scopedBodyText, !detail.isEmpty, TurnDiffRenderingPolicy.canRenderDetails(detail) {
            detailedContent(detail)
        } else {
            summaryContent
        }
    }

    private func detailedContent(_ detail: String) -> some View {
        let cacheID = needsScopedBody ? "\(messageID)|\(restrictToPath ?? "")" : messageID
        let parsedChunks = PerFileDiffChunkCache.chunks(
            messageID: cacheID,
            bodyText: detail,
            entries: needsScopedBody ? visibleEntries : entries
        )
        let chunks = parsedChunks.filter { chunk in
            restrictToPath.map { FileChangePathIdentity.representsSameFile(chunk.path, $0) } ?? true
        }
        let totals = chunks.reduce(into: (additions: 0, deletions: 0)) { totals, chunk in
            totals.additions += chunk.additions
            totals.deletions += chunk.deletions
        }
        return LazyVStack(alignment: .leading, spacing: 12) {
            summaryHeader(fileCount: chunks.count, totals: totals, showsCollapseControl: !chunks.isEmpty)
            ForEach(chunks) { chunk in
                TurnDiffFileCard(chunk: chunk, collapseAllHunks: allHunksCollapsed)
            }
        }
    }

    private var summaryContent: some View {
        let entries = visibleEntries
        let shownEntries = entries.prefix(200)
        return LazyVStack(alignment: .leading, spacing: 12) {
            Text("This diff is too large to display in full.")
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)

            ForEach(shownEntries) { entry in
                HStack {
                    Text(entry.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    DiffCountsLabel(additions: entry.additions, deletions: entry.deletions)
                        .font(AppFont.mono(.caption))
                }
                .font(AppFont.subheadline())
            }

            if entries.count > shownEntries.count {
                Text("\(entries.count - shownEntries.count) more files")
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
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
        .task(id: messageID) {
            guard let restrictToPath, needsScopedBody else { return }
            let bodyText = bodyText
            let section = await Task.detached(priority: .userInitiated) {
                TurnDiffRenderingPolicy.section(for: restrictToPath, in: bodyText)
            }.value
            guard !Task.isCancelled else { return }
            scopedBodyText = section ?? ""
        }
    }

    private func summaryHeader(
        fileCount: Int,
        totals: (additions: Int, deletions: Int),
        showsCollapseControl: Bool
    ) -> some View {
        HStack(alignment: .top) {
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
                    Text(allHunksCollapsed ? "Expand All" : "Collapse All")
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
