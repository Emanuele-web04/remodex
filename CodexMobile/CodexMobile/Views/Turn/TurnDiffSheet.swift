// FILE: TurnDiffSheet.swift
// Purpose: Shared diff sheet UI and repo-patch presentation helpers for turn-level change inspection.
// Layer: View Component
// Exports: TurnDiffSheet, TurnDiffPresentation, TurnDiffPresentationBuilder
// Depends on: SwiftUI, TurnMessageCaches, TurnFileChangeSummaryParser, TurnDiffRenderer

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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var expandedFileIDs: Set<String> = []
    @State private var selectedChunkID: String?

    private var chunks: [PerFileDiffChunk] {
        PerFileDiffChunkCache.chunks(messageID: messageID, bodyText: bodyText, entries: entries)
    }

    private var allExpanded: Bool {
        let ids = Set(chunks.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: expandedFileIDs)
    }

    private var selectedChunk: PerFileDiffChunk? {
        if let selectedChunkID,
           let selected = chunks.first(where: { $0.id == selectedChunkID }) {
            return selected
        }

        return chunks.first
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if usesWideDiffLayout(for: geometry.size.width) {
                    wideDiffLayout(for: geometry.size)
                } else {
                    compactDiffLayout
                }
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
        .presentationDetents(usesPadFullscreenCover ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            expandedFileIDs = Set(chunks.map(\.id))
            selectedChunkID = selectedChunkID ?? chunks.first?.id
        }
        .onChange(of: chunks.map(\.id)) { _, _ in
            if selectedChunk == nil {
                selectedChunkID = chunks.first?.id
            }
        }
    }

    private var usesPadFullscreenCover: Bool {
        horizontalSizeClass == .regular
    }

    private func usesWideDiffLayout(for availableWidth: CGFloat) -> Bool {
        usesPadFullscreenCover && availableWidth >= 900
    }

    private var compactDiffLayout: some View {
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
    }

    @ViewBuilder
    private func wideDiffLayout(for availableSize: CGSize) -> some View {
        HStack(spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(chunks.count) file\(chunks.count == 1 ? "" : "s") changed")
                        .font(AppFont.mono(.subheadline))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)

                    ForEach(chunks) { chunk in
                        TurnDiffFileSidebarRow(
                            chunk: chunk,
                            isSelected: selectedChunkID == chunk.id,
                            onSelect: {
                                selectedChunkID = chunk.id
                            }
                        )
                    }
                }
                .padding(12)
            }
            .frame(width: min(max(availableSize.width * 0.28, 260), 340))
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if let selectedChunk {
                TurnDiffSelectedFileView(chunk: selectedChunk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("No Diff Selected", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
    }
}

private struct TurnDiffFileSidebarRow: View {
    let chunk: PerFileDiffChunk
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: actionIcon)
                        .font(AppFont.system(size: 12))
                        .foregroundStyle(actionColor)

                    Text(chunk.compactPath)
                        .font(AppFont.mono(.subheadline))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 6)
                }

                HStack(spacing: 8) {
                    Text(chunk.action.rawValue)
                        .font(AppFont.mono(.caption2))
                        .foregroundStyle(actionColor)

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

                if let dir = chunk.fullDirectoryPath, dir != chunk.compactPath {
                    Text(dir)
                        .font(AppFont.mono(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
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

private struct TurnDiffSelectedFileView: View {
    let chunk: PerFileDiffChunk

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(chunk.compactPath)
                        .font(AppFont.mono(.body))
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    Text(chunk.action.rawValue)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(actionColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(actionColor.opacity(0.12), in: Capsule())

                    Spacer(minLength: 0)

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

                if let dir = chunk.fullDirectoryPath {
                    Text(dir)
                        .font(AppFont.mono(.caption2))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                CleanDiffCodeBlockView(code: chunk.diffCode)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

            if isExpanded, !chunk.diffCode.isEmpty {
                Divider()

                ScrollView(.horizontal, showsIndicators: false) {
                    CleanDiffCodeBlockView(code: chunk.diffCode)
                        .padding(.vertical, 4)
                }
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
