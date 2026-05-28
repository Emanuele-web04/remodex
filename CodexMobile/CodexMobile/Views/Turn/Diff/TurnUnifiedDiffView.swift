// FILE: TurnUnifiedDiffView.swift
// Purpose: Custom GitHub-style unified diff renderer used inside TurnDiffSheet file cards.
// Layer: View Component
// Exports: UnifiedDiffView, UnifiedDiffParser, UnifiedDiffHunk, UnifiedDiffLine, UnifiedDiffPalette
// Depends on: SwiftUI, UIKit, AppFont, RemodexIcon, TurnDiffLineKind

import SwiftUI
import UIKit

// ─── Model ──────────────────────────────────────────────────────────

struct UnifiedDiff: Equatable {
    let hunks: [UnifiedDiffHunk]

    var isEmpty: Bool { hunks.isEmpty }
}

struct UnifiedDiffHunk: Identifiable, Equatable {
    let id: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [UnifiedDiffLine]
    let isSynthetic: Bool

    var additions: Int { lines.reduce(0) { $0 + ($1.kind == .addition ? 1 : 0) } }
    var deletions: Int { lines.reduce(0) { $0 + ($1.kind == .deletion ? 1 : 0) } }

    // Real-hunk range derived from the actual numbered lines so it stays accurate even when
    // the source `@@ -X,Y +A,B @@` header had odd counts. Synthetic hunks return nil so the
    // view can label them as "Patch N" instead of pretending they start at line 1 of the file.
    var displayRange: String? {
        guard !isSynthetic else { return nil }
        let newNumbers = lines.compactMap(\.newNumber)
        if let first = newNumbers.first, let last = newNumbers.last {
            return first == last ? "Line \(first)" : "Lines \(first)-\(last)"
        }
        let oldNumbers = lines.compactMap(\.oldNumber)
        if let first = oldNumbers.first, let last = oldNumbers.last {
            return first == last ? "Line \(first)" : "Lines \(first)-\(last)"
        }
        return nil
    }
}

struct UnifiedDiffLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case addition
        case deletion
        case context
    }

    let id: String
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

// ─── Parser ─────────────────────────────────────────────────────────

enum UnifiedDiffParser {
    private static let hunkHeaderPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
    }()

    // Splits a unified diff string into hunks with per-line classification and numbering.
    // Metadata lines (`diff --git`, `index ...`, `+++ ...`, mode/rename headers) are skipped so
    // the renderer only emits real change rows. If the source has no `@@` headers but still
    // contains +/-/context rows (e.g. synthesised history diffs for added/deleted files),
    // a single synthetic hunk is opened so the renderer can still display content.
    static func parse(_ diffText: String) -> UnifiedDiff {
        let rawLines = diffText.components(separatedBy: "\n")
        guard !rawLines.isEmpty else { return UnifiedDiff(hunks: []) }

        var hunks: [UnifiedDiffHunk] = []
        var currentLines: [UnifiedDiffLine] = []
        var hasOpenHunk = false
        var hunkIsSynthetic = false
        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var oldCounter = 0, newCounter = 0
        var hunkIndex = 0

        func flushHunk() {
            guard hasOpenHunk else { return }
            guard !currentLines.isEmpty else {
                currentLines = []
                hasOpenHunk = false
                hunkIsSynthetic = false
                return
            }
            hunks.append(
                UnifiedDiffHunk(
                    id: "hunk-\(hunkIndex)-\(oldStart)-\(newStart)",
                    oldStart: oldStart,
                    oldCount: oldCount,
                    newStart: newStart,
                    newCount: newCount,
                    lines: currentLines,
                    isSynthetic: hunkIsSynthetic
                )
            )
            currentLines = []
            hasOpenHunk = false
            hunkIsSynthetic = false
            hunkIndex += 1
        }

        // Synthetic hunks start at line 1 for both sides so the gutter still shows numbers
        // even when the source diff omitted the `@@ -X +Y @@` header. They get a synthetic
        // flag so the view labels them as "Patch N" instead of a misleading "Lines 1-N".
        func openSyntheticHunkIfNeeded() {
            guard !hasOpenHunk else { return }
            oldStart = 1
            oldCount = 0
            newStart = 1
            newCount = 0
            oldCounter = 1
            newCounter = 1
            hasOpenHunk = true
            hunkIsSynthetic = true
        }

        for rawLine in rawLines {
            if rawLine.hasPrefix("@@") {
                flushHunk()
                if let parsed = parseHunkHeader(rawLine) {
                    oldStart = parsed.oldStart
                    oldCount = parsed.oldCount
                    newStart = parsed.newStart
                    newCount = parsed.newCount
                    oldCounter = max(parsed.oldStart, 1)
                    newCounter = max(parsed.newStart, 1)
                    hasOpenHunk = true
                    hunkIsSynthetic = false
                }
                continue
            }

            if isMetadataLine(rawLine) {
                continue
            }

            if rawLine.hasPrefix("\\") {
                // Common `\ No newline at end of file` marker - safe to skip.
                continue
            }

            // Recognise a change/context row even before we ever saw a `@@` header.
            let isChangeRow = rawLine.hasPrefix("+") || rawLine.hasPrefix("-") || rawLine.hasPrefix(" ")
            if !hasOpenHunk {
                if isChangeRow {
                    openSyntheticHunkIfNeeded()
                } else {
                    continue
                }
            }

            if rawLine.hasPrefix("+") {
                let text = String(rawLine.dropFirst())
                currentLines.append(
                    UnifiedDiffLine(
                        id: "\(hunkIndex)-add-\(currentLines.count)",
                        kind: .addition,
                        oldNumber: nil,
                        newNumber: newCounter,
                        text: text
                    )
                )
                newCounter += 1
            } else if rawLine.hasPrefix("-") {
                let text = String(rawLine.dropFirst())
                currentLines.append(
                    UnifiedDiffLine(
                        id: "\(hunkIndex)-del-\(currentLines.count)",
                        kind: .deletion,
                        oldNumber: oldCounter,
                        newNumber: nil,
                        text: text
                    )
                )
                oldCounter += 1
            } else {
                let text = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
                currentLines.append(
                    UnifiedDiffLine(
                        id: "\(hunkIndex)-ctx-\(currentLines.count)",
                        kind: .context,
                        oldNumber: oldCounter,
                        newNumber: newCounter,
                        text: text
                    )
                )
                oldCounter += 1
                newCounter += 1
            }
        }

        flushHunk()
        return UnifiedDiff(hunks: hunks)
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        if line.hasPrefix("diff --git ")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode")
            || line.hasPrefix("deleted file mode")
            || line.hasPrefix("old mode ")
            || line.hasPrefix("new mode ")
            || line.hasPrefix("rename from ")
            || line.hasPrefix("rename to ")
            || line.hasPrefix("copy from ")
            || line.hasPrefix("copy to ")
            || line.hasPrefix("similarity index ")
            || line.hasPrefix("dissimilarity index ")
            || line.hasPrefix("Binary files ") {
            return true
        }
        return false
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard let regex = hunkHeaderPattern else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }

        func intAt(_ index: Int, defaultValue: Int) -> Int {
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound, let r = Range(nsRange, in: line) else {
                return defaultValue
            }
            return Int(line[r]) ?? defaultValue
        }

        return (
            oldStart: intAt(1, defaultValue: 0),
            oldCount: intAt(2, defaultValue: 1),
            newStart: intAt(3, defaultValue: 0),
            newCount: intAt(4, defaultValue: 1)
        )
    }
}

// ─── View ───────────────────────────────────────────────────────────

struct UnifiedDiffView: View {
    let diff: UnifiedDiff
    let rawDiffCode: String
    let collapseAllHunks: Bool
    @State private var collapsedHunkIDs: Set<String> = []

    init(diffCode: String, collapseAllHunks: Bool = false) {
        rawDiffCode = diffCode
        diff = UnifiedDiffParser.parse(diffCode)
        self.collapseAllHunks = collapseAllHunks
    }

    // Always renderable as long as we have any text to show. The view itself falls back to a
    // raw highlighted block when the parser couldn't find structured hunks.
    static func canRender(diffCode: String) -> Bool {
        !diffCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let syntheticHunkCount = diff.hunks.reduce(0) { $0 + ($1.isSynthetic ? 1 : 0) }
        let syntheticIndices: [String: Int] = {
            var indices: [String: Int] = [:]
            var counter = 0
            for hunk in diff.hunks where hunk.isSynthetic {
                counter += 1
                indices[hunk.id] = counter
            }
            return indices
        }()

        return Group {
            if diff.hunks.isEmpty {
                rawFallback
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.element.id) { index, hunk in
                        if index > 0 {
                            Rectangle()
                                .fill(Color(.separator).opacity(0.5))
                                .frame(height: 0.5)
                        }
                        UnifiedDiffHunkSection(
                            hunk: hunk,
                            headerLabel: headerLabel(for: hunk, syntheticIndex: syntheticIndices[hunk.id], totalSynthetic: syntheticHunkCount),
                            gutterWidth: gutterWidth(for: hunk),
                            isCollapsed: Binding(
                                get: { collapsedHunkIDs.contains(hunk.id) },
                                set: { newValue in
                                    if newValue {
                                        collapsedHunkIDs.insert(hunk.id)
                                    } else {
                                        collapsedHunkIDs.remove(hunk.id)
                                    }
                                }
                            )
                        )
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .onChange(of: collapseAllHunks) { _, collapsed in
            withAnimation(.easeInOut(duration: 0.18)) {
                if collapsed {
                    collapsedHunkIDs = Set(diff.hunks.map(\.id))
                } else {
                    collapsedHunkIDs.removeAll()
                }
            }
        }
    }

    // Single-column gutter width sized for the widest visible line number in the hunk.
    private func gutterWidth(for hunk: UnifiedDiffHunk) -> CGFloat {
        let largest = max(
            hunk.lines.compactMap(\.newNumber).max() ?? 0,
            hunk.lines.compactMap(\.oldNumber).max() ?? 0
        )
        let digits = max(2, String(largest).count)
        return CGFloat(digits) * 7 + 10
    }

    private func headerLabel(for hunk: UnifiedDiffHunk, syntheticIndex: Int?, totalSynthetic: Int) -> String {
        if let range = hunk.displayRange {
            return range
        }
        if let index = syntheticIndex, totalSynthetic > 1 {
            return "Patch \(index) of \(totalSynthetic)"
        }
        return "Patch"
    }

    // Raw, line-oriented fallback rendering used when no hunks could be parsed but the diff
    // code is still non-empty (e.g. plain `+`/`-` snippets without `@@` markers).
    private var rawFallback: some View {
        let lines = rawDiffCode.components(separatedBy: "\n")
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                UnifiedDiffRawRow(rawLine: raw)
            }
        }
    }
}

// ─── Hunk section ───────────────────────────────────────────────────

private struct UnifiedDiffHunkSection: View {
    let hunk: UnifiedDiffHunk
    let headerLabel: String
    let gutterWidth: CGFloat
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RemodexIcon.image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(AppFont.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Text(headerLabel)
                        .font(AppFont.mono(.caption))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    if hunk.additions > 0 || hunk.deletions > 0 {
                        DiffCountsLabel(additions: hunk.additions, deletions: hunk.deletions)
                            .font(AppFont.mono(.caption2))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hunk.lines) { line in
                        UnifiedDiffRow(line: line, gutterWidth: gutterWidth)
                    }
                }
            }
        }
    }
}

// Raw-line fallback row used when the structured parser yielded no hunks. It still classifies
// the row by leading prefix so additions/deletions stay coloured.
private struct UnifiedDiffRawRow: View {
    let rawLine: String

    var body: some View {
        let palette = paletteForLine(rawLine)
        let text = displayText(rawLine)
        let indicator = gutterIndicator(for: rawLine)
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .trailing) {
                palette.gutterBackground
                Text(indicator)
                    .font(AppFont.mono(.caption2))
                    .foregroundStyle(palette.gutterForeground)
                    .padding(.trailing, 6)
                    .padding(.vertical, 3)
            }
            .frame(width: 22)

            Text(text.isEmpty ? " " : text)
                .font(AppFont.mono(.caption))
                .foregroundStyle(palette.rowForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .background(palette.rowBackground)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func gutterIndicator(for raw: String) -> String {
        if raw.hasPrefix("+") && !raw.hasPrefix("+++") { return "+" }
        if raw.hasPrefix("-") && !raw.hasPrefix("---") { return "-" }
        return ""
    }

    private func paletteForLine(_ raw: String) -> UnifiedDiffPalette.RowPalette {
        if raw.hasPrefix("+") && !raw.hasPrefix("+++") { return UnifiedDiffPalette.addition }
        if raw.hasPrefix("-") && !raw.hasPrefix("---") { return UnifiedDiffPalette.deletion }
        return UnifiedDiffPalette.context
    }

    private func displayText(_ raw: String) -> String {
        if raw.hasPrefix("+") || raw.hasPrefix("-") || raw.hasPrefix(" ") {
            return String(raw.dropFirst())
        }
        return raw
    }
}

// ─── Row ────────────────────────────────────────────────────────────

private struct UnifiedDiffRow: View {
    let line: UnifiedDiffLine
    let gutterWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .trailing) {
                palette.gutterBackground
                Text(gutterLabel)
                    .font(AppFont.mono(.caption2))
                    .foregroundStyle(palette.gutterForeground)
                    .padding(.trailing, 6)
                    .padding(.vertical, 3)
            }
            .frame(width: gutterWidth)

            Text(line.text.isEmpty ? " " : line.text)
                .font(AppFont.mono(.caption))
                .foregroundStyle(palette.rowForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .background(palette.rowBackground)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // Single-column gutter: deletions show the removed source line number, additions and
    // context lines show the resulting (new) file line number. This matches how GitHub on
    // mobile collapses the dual gutter and avoids the "1 1 / 2 2 / 3 3" redundancy.
    private var gutterLabel: String {
        switch line.kind {
        case .addition:
            if let new = line.newNumber { return "\(new)" }
            return "+"
        case .deletion:
            if let old = line.oldNumber { return "\(old)" }
            return "-"
        case .context:
            if let new = line.newNumber { return "\(new)" }
            if let old = line.oldNumber { return "\(old)" }
            return ""
        }
    }

    private var palette: UnifiedDiffPalette.RowPalette {
        switch line.kind {
        case .addition: return UnifiedDiffPalette.addition
        case .deletion: return UnifiedDiffPalette.deletion
        case .context: return UnifiedDiffPalette.context
        }
    }
}

// ─── Palette ────────────────────────────────────────────────────────

// GitHub-style diff palette with full-row and gutter tints for light/dark mode.
enum UnifiedDiffPalette {
    struct RowPalette {
        let rowBackground: Color
        let rowForeground: Color
        let gutterBackground: Color
        let gutterForeground: Color
    }

    static var additionForeground: Color { Color(additionForegroundUI) }
    static var deletionForeground: Color { Color(deletionForegroundUI) }

    static var addition: RowPalette {
        RowPalette(
            rowBackground: Color(additionRowBackgroundUI),
            rowForeground: .primary,
            gutterBackground: Color(additionGutterBackgroundUI),
            gutterForeground: additionForeground
        )
    }

    static var deletion: RowPalette {
        RowPalette(
            rowBackground: Color(deletionRowBackgroundUI),
            rowForeground: .primary,
            gutterBackground: Color(deletionGutterBackgroundUI),
            gutterForeground: deletionForeground
        )
    }

    static var context: RowPalette {
        RowPalette(
            rowBackground: Color(.systemBackground),
            rowForeground: .primary,
            gutterBackground: Color(.secondarySystemBackground),
            gutterForeground: .secondary
        )
    }

    private static let additionForegroundUI = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.34, green: 0.83, blue: 0.39, alpha: 1.0)
            : UIColor(red: 0.10, green: 0.50, blue: 0.22, alpha: 1.0)
    }

    private static let deletionForegroundUI = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.97, green: 0.32, blue: 0.29, alpha: 1.0)
            : UIColor(red: 0.81, green: 0.13, blue: 0.18, alpha: 1.0)
    }

    private static let additionRowBackgroundUI = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.18, green: 0.63, blue: 0.26, alpha: 0.18)
            : UIColor(red: 0.90, green: 1.00, blue: 0.93, alpha: 1.0)
    }

    private static let additionGutterBackgroundUI = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.18, green: 0.63, blue: 0.26, alpha: 0.30)
            : UIColor(red: 0.82, green: 0.96, blue: 0.83, alpha: 1.0)
    }

    private static let deletionRowBackgroundUI = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.97, green: 0.32, blue: 0.29, alpha: 0.18)
            : UIColor(red: 1.00, green: 0.92, blue: 0.91, alpha: 1.0)
    }

    private static let deletionGutterBackgroundUI = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.97, green: 0.32, blue: 0.29, alpha: 0.30)
            : UIColor(red: 1.00, green: 0.84, blue: 0.84, alpha: 1.0)
    }
}
