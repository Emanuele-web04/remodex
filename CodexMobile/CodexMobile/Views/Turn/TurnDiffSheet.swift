// FILE: TurnDiffSheet.swift
// Purpose: Shared diff sheet UI and repo-patch presentation helpers for turn-level change inspection.
// Layer: View Component
// Exports: TurnDiffSheet, TurnDiffPresentation, TurnDiffPresentationBuilder
// Depends on: SwiftUI, UIKit, MarkdownView, TurnMessageCaches, TurnFileChangeSummaryParser

import MarkdownView
import SwiftUI
import UIKit

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
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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

    @Environment(\.dismiss) private var dismiss
    @State private var expandedFileIDs: Set<String> = []

    private var chunks: [PerFileDiffChunk] {
        PerFileDiffChunkCache.chunks(messageID: messageID, bodyText: bodyText, entries: entries)
    }

    private var allExpanded: Bool {
        let ids = Set(chunks.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: expandedFileIDs)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(chunks.count) file\(chunks.count == 1 ? "" : "s") changed")
                            .font(AppFont.mono(.subheadline))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if allExpanded {
                                    expandedFileIDs.removeAll()
                                } else {
                                    expandedFileIDs = Set(chunks.map(\.id))
                                }
                            }
                        } label: {
                            Text(allExpanded ? "Collapse All" : "Expand All")
                                .font(AppFont.mono(.caption))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)

                    LazyVStack(spacing: 12) {
                        ForEach(chunks) { chunk in
                            TurnDiffFileCard(
                                chunk: chunk,
                                isExpanded: Binding(
                                    get: { expandedFileIDs.contains(chunk.id) },
                                    set: { newValue in
                                        if newValue {
                                            expandedFileIDs.insert(chunk.id)
                                        } else {
                                            expandedFileIDs.remove(chunk.id)
                                        }
                                    }
                                )
                            )
                        }
                    }
                }
                .padding(.vertical)
                .padding(.horizontal, 8)
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
        .presentationDetents([.medium, .large])
        .onAppear {
            expandedFileIDs = Set(chunks.map(\.id))
        }
    }
}

private struct TurnDiffFileCard: View {
    let chunk: PerFileDiffChunk
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(AppFont.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)

                        Image(systemName: actionIcon)
                            .font(AppFont.system(size: 12))
                            .foregroundStyle(actionColor)

                        Text(chunk.compactPath)
                            .font(AppFont.mono(.subheadline))
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 4)

                        Text(chunk.action.rawValue)
                            .font(AppFont.mono(.caption2))
                            .foregroundStyle(actionColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(actionColor.opacity(0.12), in: Capsule())

                        HStack(spacing: 4) {
                            if chunk.additions > 0 {
                                Text("+\(chunk.additions)")
                                    .font(AppFont.mono(.caption))
                                    .foregroundStyle(Color(red: 0.13, green: 0.77, blue: 0.37))
                            }
                            if chunk.deletions > 0 {
                                Text("-\(chunk.deletions)")
                                    .font(AppFont.mono(.caption))
                                    .foregroundStyle(Color(red: 0.94, green: 0.27, blue: 0.27))
                            }
                        }
                    }

                    if let dir = chunk.fullDirectoryPath, dir != chunk.compactPath {
                        Text(dir)
                            .font(AppFont.mono(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.leading, 30)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, MarkdownUnifiedDiffBlockView.canRender(diffCode: chunk.diffCode) {
                Divider()

                MarkdownUnifiedDiffBlockView(diffCode: chunk.diffCode)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var actionIcon: String {
        switch chunk.action {
        case .edited: return "pencil"
        case .added: return "plus"
        case .deleted: return "minus"
        case .renamed: return "arrow.right"
        }
    }

    private var actionColor: Color {
        switch chunk.action {
        case .edited: return .orange
        case .added: return Color(red: 0.13, green: 0.77, blue: 0.37)
        case .deleted: return Color(red: 0.94, green: 0.27, blue: 0.27)
        case .renamed: return .blue
        }
    }
}

private struct MarkdownUnifiedDiffBlockView: UIViewRepresentable {
    let diffCode: String

    func makeUIView(context _: Context) -> MarkdownView.MarkdownTextView {
        let view = MarkdownView.MarkdownTextView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.theme = Self.theme
        return view
    }

    func updateUIView(_ uiView: MarkdownView.MarkdownTextView, context _: Context) {
        let theme = Self.theme
        let content = MarkdownView.MarkdownTextView.PreprocessedContent(
            markdown: renderableDiff,
            theme: theme
        )
        uiView.theme = theme
        uiView.setMarkdownManually(content)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MarkdownView.MarkdownTextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else {
            return uiView.intrinsicContentSize
        }
        let measuredSize = uiView.boundingSize(for: width)
        return CGSize(width: width, height: measuredSize.height)
    }

    private var renderableDiff: String {
        let body = Self.renderableBody(from: diffCode)
        let fence = Self.markdownFence(for: body)
        return "\(fence)diff\n\(body)\n\(fence)"
    }

    static func canRender(diffCode: String) -> Bool {
        !renderableBody(from: diffCode).isEmpty
    }

    private static func renderableBody(from diffCode: String) -> String {
        let originalBody = diffCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalBody.isEmpty else { return "" }

        // Metadata-only patches (rename/mode changes) have no code rows, so keep
        // the original patch instead of rendering an empty expanded diff card.
        let strippedBody = strippedMetadataPreamble(from: originalBody)
        return strippedBody.isEmpty ? originalBody : strippedBody
    }

    private static func strippedMetadataPreamble(from diffCode: String) -> String {
        diffCode
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                !TurnDiffLineKind.classify(line).isMetadataPreamble
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func markdownFence(for body: String) -> String {
        let longestFence = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line
                    .drop(while: { $0 == " " || $0 == "\t" })
                    .prefix(while: { $0 == "`" })
                    .count
            }
            .max() ?? 0

        return String(repeating: "`", count: max(3, longestFence + 1))
    }

    private static var theme: MarkdownTheme {
        var theme = MarkdownTheme.default
        theme.showsBlockHeaders = false
        theme.fonts.code = AppFont.monoUIFont(size: 13, textStyle: .callout)
        theme.colors.body = .label
        theme.colors.code = .label
        theme.colors.codeBackground = .clear
        theme.diff.backgroundColor = .clear
        theme.diff.borderWidth = 0
        theme.diff.lineNumberStyle = .single
        theme.diff.showsChangeMarkers = false
        theme.diff.scrollBehavior = .horizontalOnly
        return theme
    }
}

private extension TurnDiffLineKind {
    var isMetadataPreamble: Bool {
        switch self {
        case .meta:
            true
        case .addition, .deletion, .hunk, .neutral:
            false
        }
    }
}
