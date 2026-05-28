// FILE: TurnDiffRenderer.swift
// Purpose: Classifies unified-diff rows so parsers can detect and trim patches.
// Layer: Turn diff parsing support
// Exports: TurnDiffLineKind
// Depends on: Swift standard library

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

}
