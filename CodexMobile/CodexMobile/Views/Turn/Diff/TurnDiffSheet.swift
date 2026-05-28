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
        let all = PerFileDiffChunkCache.chunks(messageID: messageID, bodyText: bodyText, entries: entries)
        guard let restrictToPath else { return all }
        return all.filter { FileChangePathIdentity.representsSameFile($0.path, restrictToPath) }
    }

    private var totals: (additions: Int, deletions: Int) {
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
                VStack(alignment: .leading, spacing: 12) {
                    summaryHeader

                    ForEach(chunks) { chunk in
                        TurnDiffFileCard(
                            chunk: chunk,
                            collapseAllHunks: allHunksCollapsed
                        )
                    }
                }
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
    }

    private var summaryHeader: some View {
        let totals = totals
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(chunks.count) file\(chunks.count == 1 ? "" : "s") changed")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)

                if totals.additions > 0 || totals.deletions > 0 {
                    DiffCountsLabel(additions: totals.additions, deletions: totals.deletions)
                        .font(AppFont.mono(.caption))
                }
            }

            Spacer(minLength: 8)

            if !chunks.isEmpty {
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
