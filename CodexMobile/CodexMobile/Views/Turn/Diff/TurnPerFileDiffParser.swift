// FILE: TurnPerFileDiffParser.swift
// Purpose: Parses and caches per-file diff chunks for file-change sheets.
// Layer: View Support
// Exports: PerFileDiffChunk, FileChangePathIdentity, PerFileDiffParser, PerFileDiffChunkCache
// Depends on: Foundation, TurnFileChangeSummaryParser, TurnDiffLineKind

import Foundation

struct PerFileDiffChunk: Identifiable {
    let id: String
    let path: String
    let action: TurnFileChangeAction
    let additions: Int
    let deletions: Int
    let diffCode: String

    var compactPath: String {
        if let last = path.split(separator: "/").last { return String(last) }
        return path
    }

    var fullDirectoryPath: String? {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }
}

enum FileChangePathIdentity {
    // Treats absolute-vs-relative references to the same repo file as one identity,
    // while keeping same-named files in different directories separate.
    static func representsSameFile(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLHS = normalizedPath(lhs)
        let normalizedRHS = normalizedPath(rhs)

        guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else {
            return false
        }
        if normalizedLHS == normalizedRHS {
            return true
        }

        let lhsIsAbsolute = isAbsolutePath(lhs)
        let rhsIsAbsolute = isAbsolutePath(rhs)
        guard lhsIsAbsolute != rhsIsAbsolute else {
            return false
        }

        let absolutePath = lhsIsAbsolute ? normalizedLHS : normalizedRHS
        let relativePath = lhsIsAbsolute ? normalizedRHS : normalizedLHS
        guard relativePath.contains("/") else {
            return false
        }

        return absolutePath.hasSuffix("/" + relativePath)
    }

    static func preferredDisplayPath(_ lhs: String, _ rhs: String) -> String {
        let trimmedLHS = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRHS = rhs.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedLHS.isEmpty { return trimmedRHS }
        if trimmedRHS.isEmpty { return trimmedLHS }
        if trimmedLHS == trimmedRHS { return trimmedLHS }
        if representsSameFile(trimmedLHS, trimmedRHS) {
            return trimmedLHS.count <= trimmedRHS.count ? trimmedLHS : trimmedRHS
        }
        return trimmedLHS
    }

    static func normalizedPath(_ rawPath: String) -> String {
        var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("a/") || normalized.hasPrefix("b/") {
            normalized = String(normalized.dropFirst(2))
        }
        if normalized.hasPrefix("./") {
            normalized = String(normalized.dropFirst(2))
        }
        if let range = normalized.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            normalized.removeSubrange(range)
        }
        return normalized.lowercased()
    }

    private static func isAbsolutePath(_ rawPath: String) -> Bool {
        rawPath.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }
}

enum PerFileDiffParser {
    static func parse(bodyText: String, entries: [TurnFileChangeSummaryEntry]) -> [PerFileDiffChunk] {
        let sections = bodyText.components(separatedBy: "\n\n---\n\n")

        if sections.count <= 1 {
            return singleChunkFallback(bodyText: bodyText, entries: entries)
        }

        var chunks: [PerFileDiffChunk] = []
        for (index, section) in sections.enumerated() {
            let lines = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let path = extractPath(from: lines)
            let code = extractFencedCode(from: lines)

            let resolvedPath = path ?? (index < entries.count ? entries[index].path : "file-\(index)")
            let entry = entries.first { FileChangePathIdentity.representsSameFile($0.path, resolvedPath) }
            let totals = preferredTotals(diffCode: code, fallbackEntry: entry)

            chunks.append(PerFileDiffChunk(
                id: "\(index)-\(resolvedPath)",
                path: resolvedPath,
                action: entry?.action ?? .edited,
                additions: totals.additions,
                deletions: totals.deletions,
                diffCode: code ?? ""
            ))
        }
        return consolidate(chunks: chunks)
    }

    private static func singleChunkFallback(bodyText: String, entries: [TurnFileChangeSummaryEntry]) -> [PerFileDiffChunk] {
        // Try to split by fenced diff blocks associated with Path: lines.
        let lines = bodyText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [PerFileDiffChunk] = []
        var currentPath: String?
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("**Path:**") || trimmed.hasPrefix("Path:") {
                let raw = trimmed
                    .replacingOccurrences(of: "**Path:**", with: "")
                    .replacingOccurrences(of: "Path:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if !raw.isEmpty { currentPath = raw }
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    // Match the closing fence on the raw line so context rows like ` ```` (a
                    // backtick fence inside a diffed source file) do not terminate the block
                    // prematurely. Strip only trailing whitespace to stay forgiving.
                    let candidate = lines[i].trimmingTrailingWhitespace()
                    if candidate == "```" { break }
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }

                let code = codeLines.joined(separator: "\n")
                if TurnDiffLineKind.detectVerifiedPatch(in: code) {
                    let resolvedPath = currentPath ?? (chunks.count < entries.count ? entries[chunks.count].path : "file-\(chunks.count)")
                    let entry = entries.first { FileChangePathIdentity.representsSameFile($0.path, resolvedPath) }
                    let totals = preferredTotals(diffCode: code, fallbackEntry: entry)
                    chunks.append(PerFileDiffChunk(
                        id: "\(chunks.count)-\(resolvedPath)",
                        path: resolvedPath,
                        action: entry?.action ?? .edited,
                        additions: totals.additions,
                        deletions: totals.deletions,
                        diffCode: code
                    ))
                    currentPath = nil
                }
                continue
            }

            i += 1
        }

        if chunks.isEmpty, !entries.isEmpty {
            // Ultimate fallback: one chunk per entry with the whole body.
            let allCode = extractFencedCode(from: lines) ?? bodyText
            let first = entries[0]
            let totals = preferredTotals(diffCode: allCode, fallbackEntry: first)
            chunks.append(PerFileDiffChunk(
                id: "0-\(first.path)",
                path: first.path,
                action: first.action ?? .edited,
                additions: totals.additions,
                deletions: totals.deletions,
                diffCode: allCode
            ))
        }

        return consolidate(chunks: chunks)
    }

    // Diff cards must show counts for the diff block being rendered, not whatever
    // aggregate totals the surrounding recap text happened to report.
    private static func preferredTotals(
        diffCode: String?,
        fallbackEntry: TurnFileChangeSummaryEntry?
    ) -> TurnDiffLineTotals {
        guard let diffCode, !diffCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TurnDiffLineTotals(
                additions: fallbackEntry?.additions ?? 0,
                deletions: fallbackEntry?.deletions ?? 0
            )
        }

        let diffTotals = countDiffLines(in: diffCode.components(separatedBy: "\n"))
        if diffTotals.additions > 0 || diffTotals.deletions > 0 || fallbackEntry == nil {
            return diffTotals
        }

        return TurnDiffLineTotals(
            additions: fallbackEntry?.additions ?? 0,
            deletions: fallbackEntry?.deletions ?? 0
        )
    }

    private static func countDiffLines(in lines: [String]) -> TurnDiffLineTotals {
        lines.reduce(into: TurnDiffLineTotals()) { totals, line in
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                totals.additions += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                totals.deletions += 1
            }
        }
    }

    // Collapses repeated snapshots for the same file into one card and appends
    // distinct hunks in-order so users can inspect the full file history in one place.
    private static func consolidate(chunks: [PerFileDiffChunk]) -> [PerFileDiffChunk] {
        guard chunks.count > 1 else {
            return chunks
        }

        var consolidated: [PerFileDiffChunk] = []
        consolidated.reserveCapacity(chunks.count)

        for chunk in chunks {
            if let existingIndex = consolidated.firstIndex(where: {
                FileChangePathIdentity.representsSameFile($0.path, chunk.path)
            }) {
                let existing = consolidated[existingIndex]
                let isExactDuplicate = existing.diffCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    == chunk.diffCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    && existing.additions == chunk.additions
                    && existing.deletions == chunk.deletions
                    && existing.action == chunk.action
                let mergedDiff = mergedDiffCode(existing.diffCode, chunk.diffCode)
                consolidated[existingIndex] = PerFileDiffChunk(
                    id: existing.id,
                    path: FileChangePathIdentity.preferredDisplayPath(existing.path, chunk.path),
                    action: mergedAction(existing.action, chunk.action),
                    additions: isExactDuplicate ? existing.additions : (existing.additions + chunk.additions),
                    deletions: isExactDuplicate ? existing.deletions : (existing.deletions + chunk.deletions),
                    diffCode: mergedDiff
                )
            } else {
                consolidated.append(chunk)
            }
        }

        return consolidated
    }

    private static func mergedDiffCode(_ lhs: String, _ rhs: String) -> String {
        let trimmedLHS = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRHS = rhs.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedLHS.isEmpty { return trimmedRHS }
        if trimmedRHS.isEmpty { return trimmedLHS }
        if trimmedLHS == trimmedRHS { return trimmedLHS }
        return "\(trimmedLHS)\n\n\(trimmedRHS)"
    }

    private static func mergedAction(
        _ lhs: TurnFileChangeAction,
        _ rhs: TurnFileChangeAction
    ) -> TurnFileChangeAction {
        if lhs == rhs {
            return lhs
        }
        let precedence: [TurnFileChangeAction] = [.added, .deleted, .renamed, .edited]
        let lhsRank = precedence.firstIndex(of: lhs) ?? precedence.count
        let rhsRank = precedence.firstIndex(of: rhs) ?? precedence.count
        return lhsRank <= rhsRank ? lhs : rhs
    }

    private static func extractPath(from lines: [String]) -> String? {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("**Path:**") || t.hasPrefix("Path:") {
                let raw = t
                    .replacingOccurrences(of: "**Path:**", with: "")
                    .replacingOccurrences(of: "Path:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if !raw.isEmpty { return raw }
            }
        }
        return nil
    }

    private static func extractFencedCode(from lines: [String]) -> String? {
        var inFence = false
        var codeLines: [String] = []
        for line in lines {
            // Use the raw line (only trailing whitespace stripped) so context rows starting
            // with a single leading space don't accidentally close the fence.
            let trailingTrimmed = line.trimmingTrailingWhitespace()
            if !inFence, trailingTrimmed.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence = true
                codeLines = []
                continue
            }
            if inFence, trailingTrimmed == "```" {
                return codeLines.joined(separator: "\n")
            }
            if inFence { codeLines.append(line) }
        }
        return inFence ? codeLines.joined(separator: "\n") : nil
    }
}

private extension String {
    // Trims only trailing whitespace/newlines while keeping any leading whitespace intact,
    // so diff context rows (which always start with a single space) survive the trim.
    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            if self[previous].isWhitespace || self[previous].isNewline {
                end = previous
            } else {
                break
            }
        }
        return String(self[startIndex..<end])
    }
}

enum PerFileDiffChunkCache {
    private static let cache = BoundedCache<String, [PerFileDiffChunk]>(maxEntries: 128)

    static func reset() { cache.removeAll() }

    static func chunks(messageID: String, bodyText: String, entries: [TurnFileChangeSummaryEntry]) -> [PerFileDiffChunk] {
        let key = "\(TurnTextCacheKey.key(messageID: messageID, kind: "per-file-diff", text: bodyText))|\(TurnTextCacheKey.entriesFingerprint(entries))"
        return cache.getOrSet(key) {
            PerFileDiffParser.parse(bodyText: bodyText, entries: entries)
        }
    }
}
