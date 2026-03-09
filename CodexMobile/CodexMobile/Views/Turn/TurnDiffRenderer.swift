// FILE: TurnDiffRenderer.swift
// Purpose: Provides GitHub-like rendering for diff/code-change blocks (+/-/hunks/meta).
// Layer: View Components
// Exports: TurnDiffLineKind, TurnDiffCodeBlockView
// Depends on: SwiftUI

import SwiftUI

// ─── Diff Classification ────────────────────────────────────────────

enum TurnDiffLineKind {
    case addition
    case deletion
    case hunk
    case meta
    case neutral

    // Detects whether a code snippet should be treated as a diff patch.
    static func detect(in code: String) -> Bool {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let additionCount = lines.filter { classify($0) == .addition }.count
        let deletionCount = lines.filter { classify($0) == .deletion }.count
        let hasHunk = lines.contains { classify($0) == .hunk }
        return hasHunk || (additionCount > 0 && deletionCount > 0)
    }

    // Strict diff detection: accepts real patch metadata-only diffs (e.g. rename/mode-only),
    // while still avoiding generic prose/code blocks.
    static func detectVerifiedPatch(in code: String) -> Bool {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return false }

        var hasHunk = false
        var hasGitHeader = false
        var hasBodyChange = false
        var metadataEvidenceCount = 0

        for line in lines {
            if line.hasPrefix("@@") {
                hasHunk = true
                continue
            }

            if line.hasPrefix("diff --git ")
                || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ")
                || line.hasPrefix("index ")
                || line.hasPrefix("new file mode")
                || line.hasPrefix("deleted file mode")
                || line.hasPrefix("old mode ")
                || line.hasPrefix("new mode ")
                || line.hasPrefix("rename from ")
                || line.hasPrefix("rename to ")
                || line.hasPrefix("similarity index ")
                || line.hasPrefix("dissimilarity index ") {
                hasGitHeader = true
                metadataEvidenceCount += 1
                continue
            }

            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                hasBodyChange = true
                continue
            }

            if line.hasPrefix("-") && !line.hasPrefix("---") {
                hasBodyChange = true
                continue
            }
        }

        if hasBodyChange {
            return hasHunk || hasGitHeader
        }

        if hasHunk {
            return true
        }

        // Metadata-only patches are valid (e.g. rename/mode changes), but require
        // multiple git patch markers to avoid matching incidental prose.
        return hasGitHeader && metadataEvidenceCount >= 2
    }

    // Classifies each diff row so the renderer can color it consistently.
    static func classify(_ line: String) -> TurnDiffLineKind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
            return .meta
        }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .addition }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .deletion }
        return .neutral
    }

    // Left-side marker color (only on added/removed rows).
    var indicatorColor: Color {
        switch self {
        case .addition:
            return Color(red: 0.13, green: 0.77, blue: 0.37)
        case .deletion:
            return Color(red: 0.94, green: 0.27, blue: 0.27)
        default:
            return .clear
        }
    }

    var hasIndicator: Bool {
        switch self {
        case .addition, .deletion:
            return true
        default:
            return false
        }
    }

    // Text color tuned for dark/light readability, aligned with desktop diff conventions.
    var textColor: Color {
        switch self {
        case .addition:
            return Color(red: 0.13, green: 0.77, blue: 0.37)
        case .deletion:
            return Color(red: 0.94, green: 0.27, blue: 0.27)
        case .hunk:
            return Color(red: 0.70, green: 0.74, blue: 0.85)
        case .meta:
            return Color(.secondaryLabel)
        case .neutral:
            return Color(.label)
        }
    }

    // Row background tint for additions/deletions, like GitHub/Codex desktop.
    var backgroundColor: Color {
        switch self {
        case .addition:
            return Color(red: 0.10, green: 0.45, blue: 0.26).opacity(0.12)
        case .deletion:
            return Color(red: 0.55, green: 0.18, blue: 0.18).opacity(0.12)
        default:
            return .clear
        }
    }
}

// ─── Diff View ──────────────────────────────────────────────────────

struct TurnDiffCodeBlockView: View {
    let code: String
    let showsLineIndicator: Bool

    init(code: String, showsLineIndicator: Bool = true) {
        self.code = code
        self.showsLineIndicator = showsLineIndicator
    }

    private var lines: [String] {
        code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let kind = TurnDiffLineKind.classify(line)
                if kind != .meta {
                    ZStack(alignment: .leading) {
                        // Keep diff row backgrounds strictly rectangular (no rounded corners).
                        Rectangle()
                            .fill(kind.backgroundColor)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(kind.indicatorColor)
                                .frame(width: (showsLineIndicator && kind.hasIndicator) ? 2 : 0)

                            Text(verbatim: line)
                                .font(AppFont.mono(.callout))
                                .foregroundStyle(kind.textColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

// ─── Clean Diff View (no raw syntax) ────────────────────────────────

struct CleanDiffCodeBlockView: View {
    let code: String

    private var lines: [String] {
        code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let kind = TurnDiffLineKind.classify(line)
                switch kind {
                case .meta:
                    EmptyView()
                case .hunk:
                    Divider()
                        .padding(.vertical, 6)
                default:
                    let displayText = strippedText(line, kind: kind)
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(kind.backgroundColor)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(kind.indicatorColor)
                                .frame(width: kind.hasIndicator ? 2 : 0)

                            Text(verbatim: displayText)
                                .font(AppFont.mono(.callout))
                                .foregroundStyle(kind.textColor)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func strippedText(_ line: String, kind: TurnDiffLineKind) -> String {
        switch kind {
        case .addition:
            return line.count > 1 ? String(line.dropFirst()) : ""
        case .deletion:
            return line.count > 1 ? String(line.dropFirst()) : ""
        case .neutral:
            if line.hasPrefix(" ") { return String(line.dropFirst()) }
            return line
        default:
            return line
        }
    }
}
