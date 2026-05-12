// FILE: TurnFileChangeSummaryParser.swift
// Purpose: Parses file-change recap prose and fenced diffs into per-file summary entries.
// Layer: Parser
// Exports: TurnDiffLineTotals, TurnFileChangeAction, TurnFileChangeSummaryEntry, TurnFileChangeSummary, TurnFileChangeSummaryParser
// Depends on: Foundation, TurnMessageRegexCache, TurnDiffLineKind (TurnDiffRenderer)

import Foundation

struct TurnDiffLineTotals {
    var additions: Int = 0
    var deletions: Int = 0
}

enum TurnFileChangeAction: String, Hashable {
    case edited = "Edited"
    case added = "Added"
    case deleted = "Deleted"
    case renamed = "Renamed"

    static func fromInlineVerb(_ verb: String) -> TurnFileChangeAction? {
        switch verb.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "edited", "updated":
            return .edited
        case "added", "created":
            return .added
        case "deleted", "removed":
            return .deleted
        case "renamed", "moved":
            return .renamed
        default:
            return nil
        }
    }

    static func fromKind(_ kind: String) -> TurnFileChangeAction? {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "add", "added", "create", "created":
            return .added
        case "delete", "deleted", "remove", "removed":
            return .deleted
        case "rename", "renamed", "move", "moved":
            return .renamed
        case "update", "updated", "edit", "edited":
            return .edited
        default:
            return nil
        }
    }
}

struct TurnFileChangeSummaryEntry: Identifiable, Hashable {
    let path: String
    var additions: Int
    var deletions: Int
    var action: TurnFileChangeAction?

    var id: String { path }

    var compactPath: String {
        if let lastComponent = path.split(separator: "/").last {
            return String(lastComponent)
        }
        return path
    }
}

struct TurnFileChangeSummary {
    let entries: [TurnFileChangeSummaryEntry]
}

enum TurnFileChangeSummaryParser {
    // Extracts per-file +/- totals from file-change prose + fenced diff blocks.
    static func parse(from text: String) -> TurnFileChangeSummary? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lineIndex = 0
        var currentPath: String?
        var orderedPaths: [String] = []
        var seenPaths: Set<String> = []
        var inlineTotalsByPath: [String: TurnDiffLineTotals] = [:]
        var diffTotalsByPath: [String: TurnDiffLineTotals] = [:]
        var kindsByPath: [String: String] = [:]
        var actionsByPath: [String: TurnFileChangeAction] = [:]
        var pathsWithInlineTotals: Set<String> = []
        var pathsWithNonZeroInlineTotals: Set<String> = []
        var pathsWithDiffBodyEvidence: Set<String> = []
        var sawPathLine = false
        var sawKindLine = false
        var sawDiffFence = false
        var sawInlineTotals = false
        var sawInlineAction = false

        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let parsedPath = parsePathLine(trimmedLine) {
                sawPathLine = true
                currentPath = parsedPath
                if seenPaths.insert(parsedPath).inserted {
                    orderedPaths.append(parsedPath)
                }
                lineIndex += 1
                continue
            }

            if let parsedKind = parseKindLine(trimmedLine), let currentPath {
                sawKindLine = true
                kindsByPath[currentPath] = parsedKind
                if actionsByPath[currentPath] == nil {
                    actionsByPath[currentPath] = TurnFileChangeAction.fromKind(parsedKind)
                }
                lineIndex += 1
                continue
            }

            if let totals = parseTotalsLine(trimmedLine), let currentPath {
                if totals.additions > 0 || totals.deletions > 0 {
                    sawInlineTotals = true
                    pathsWithNonZeroInlineTotals.insert(currentPath)
                }
                inlineTotalsByPath[currentPath, default: TurnDiffLineTotals()].additions += totals.additions
                inlineTotalsByPath[currentPath, default: TurnDiffLineTotals()].deletions += totals.deletions
                pathsWithInlineTotals.insert(currentPath)
                lineIndex += 1
                continue
            }

            if let inlineEntry = parseInlineFileEntry(from: trimmedLine) {
                currentPath = inlineEntry.path
                if seenPaths.insert(inlineEntry.path).inserted {
                    orderedPaths.append(inlineEntry.path)
                }
                if let inlineTotals = inlineEntry.inlineTotals {
                    if inlineTotals.additions > 0 || inlineTotals.deletions > 0 {
                        sawInlineTotals = true
                        pathsWithNonZeroInlineTotals.insert(inlineEntry.path)
                    }
                    inlineTotalsByPath[inlineEntry.path, default: TurnDiffLineTotals()].additions += inlineTotals.additions
                    inlineTotalsByPath[inlineEntry.path, default: TurnDiffLineTotals()].deletions += inlineTotals.deletions
                    pathsWithInlineTotals.insert(inlineEntry.path)
                }
                if let action = inlineEntry.action {
                    sawInlineAction = true
                    actionsByPath[inlineEntry.path] = action
                }
                lineIndex += 1
                continue
            }

            if trimmedLine.hasPrefix("```") {
                lineIndex += 1
                var codeLines: [String] = []
                while lineIndex < lines.count {
                    let candidate = lines[lineIndex]
                    if candidate.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                        break
                    }
                    codeLines.append(candidate)
                    lineIndex += 1
                }

                let code = codeLines.joined(separator: "\n")
                if TurnDiffLineKind.detectVerifiedPatch(in: code) {
                    sawDiffFence = true
                    let resolvedPath = currentPath ?? parsePathFromDiff(lines: codeLines)
                    if let resolvedPath, !resolvedPath.isEmpty {
                        if seenPaths.insert(resolvedPath).inserted {
                            orderedPaths.append(resolvedPath)
                        }

                        let delta = countDiffLines(in: codeLines)
                        diffTotalsByPath[resolvedPath, default: TurnDiffLineTotals()].additions += delta.additions
                        diffTotalsByPath[resolvedPath, default: TurnDiffLineTotals()].deletions += delta.deletions

                        if let evidence = parseDiffBodyEvidence(in: codeLines),
                           evidence.additions > 0 || evidence.deletions > 0 {
                            pathsWithDiffBodyEvidence.insert(resolvedPath)
                        }
                    }
                }

                // Skip closing fence line when present.
                if lineIndex < lines.count {
                    lineIndex += 1
                }
                continue
            }

            lineIndex += 1
        }

        let hasStrongFileChangeSignal = sawPathLine
            || sawKindLine
            || sawDiffFence
            || sawInlineTotals
            || sawInlineAction
        guard hasStrongFileChangeSignal else { return nil }

        let entries = orderedPaths.compactMap { path -> TurnFileChangeSummaryEntry? in
            let totals = pathsWithInlineTotals.contains(path)
                ? inlineTotalsByPath[path, default: TurnDiffLineTotals()]
                : diffTotalsByPath[path, default: TurnDiffLineTotals()]
            let inferredAction: TurnFileChangeAction?
            if let explicitAction = actionsByPath[path] {
                inferredAction = explicitAction
            } else if let kind = kindsByPath[path] {
                inferredAction = TurnFileChangeAction.fromKind(kind)
            } else {
                inferredAction = nil
            }

            let hasNonZeroTotals = totals.additions > 0 || totals.deletions > 0
            let hasPatchEvidence = pathsWithDiffBodyEvidence.contains(path)
                || pathsWithNonZeroInlineTotals.contains(path)
            let hasActionWithEvidence = inferredAction != nil && hasPatchEvidence
            guard hasNonZeroTotals || hasActionWithEvidence else {
                return nil
            }

            return TurnFileChangeSummaryEntry(
                path: path,
                additions: totals.additions,
                deletions: totals.deletions,
                action: inferredAction
            )
        }

        let consolidatedEntries = consolidate(entries: entries)
        guard !consolidatedEntries.isEmpty else { return nil }
        return TurnFileChangeSummary(entries: consolidatedEntries)
    }

    static func dedupeKey(from text: String) -> String? {
        guard let summary = parse(from: text) else {
            return nil
        }

        let parts = summary.entries
            .sorted { lhs, rhs in
                if lhs.path != rhs.path { return lhs.path < rhs.path }
                if lhs.action?.rawValue != rhs.action?.rawValue {
                    return (lhs.action?.rawValue ?? "") < (rhs.action?.rawValue ?? "")
                }
                if lhs.additions != rhs.additions { return lhs.additions < rhs.additions }
                return lhs.deletions < rhs.deletions
            }
            .map { entry in
                "\(entry.path)|\(entry.action?.rawValue ?? "")|+\(entry.additions)|-\(entry.deletions)"
            }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "||")
    }

    private static func parsePathLine(_ line: String) -> String? {
        guard line.lowercased().hasPrefix("path:") else { return nil }
        let value = line.dropFirst("Path:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let normalized = normalizeInlinePath(value)
        guard looksLikePath(normalized) else { return nil }
        return normalized
    }

    private static func parseKindLine(_ line: String) -> String? {
        guard line.lowercased().hasPrefix("kind:") else { return nil }
        let value = line.dropFirst("Kind:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func parseTotalsLine(_ line: String) -> TurnDiffLineTotals? {
        guard line.lowercased().hasPrefix("totals:") else { return nil }
        let value = line.dropFirst("Totals:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return parseInlineTotals(from: value)
    }

    private static func parseInlineFileEntry(
        from line: String
    ) -> (path: String, inlineTotals: TurnDiffLineTotals?, action: TurnFileChangeAction?)? {
        var candidate = line
        if candidate.hasPrefix("- ") || candidate.hasPrefix("* ") {
            candidate = String(candidate.dropFirst(2))
        } else if candidate.hasPrefix("• ") {
            candidate = String(candidate.dropFirst(2))
        }

        candidate = candidate.replacingOccurrences(of: "`", with: "")
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let totals = parseInlineTotals(from: trimmed)
        let withoutTotals = stripInlineTotals(from: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let actionEntry = parseInlineActionEntry(from: withoutTotals) {
            let normalizedPath = normalizeInlinePath(actionEntry.path)
            guard looksLikePath(normalizedPath) else {
                return nil
            }
            return (path: normalizedPath, inlineTotals: totals, action: actionEntry.action)
        }

        // Avoid false positives from generic file references (e.g. "File: ...").
        // Only accept path-only inline rows when explicit +/- totals are present.
        guard totals != nil else {
            return nil
        }

        let firstToken = withoutTotals
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? withoutTotals
        let normalizedPath = normalizeInlinePath(firstToken)

        guard looksLikePath(normalizedPath) else {
            return nil
        }

        return (path: normalizedPath, inlineTotals: totals, action: nil)
    }

    private static func parseInlineActionEntry(
        from line: String
    ) -> (action: TurnFileChangeAction, path: String)? {
        guard let regex = TurnMessageRegexCache.inlineAction else { return nil }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: fullRange),
              match.numberOfRanges == 3 else {
            return nil
        }

        let verb = nsLine.substring(with: match.range(at: 1))
        let path = nsLine.substring(with: match.range(at: 2))
        guard let action = TurnFileChangeAction.fromInlineVerb(verb) else {
            return nil
        }

        return (action: action, path: path)
    }

    private static func parseInlineTotals(from line: String) -> TurnDiffLineTotals? {
        // Accept ASCII and common Unicode plus/minus glyphs used by rich text renderers.
        guard let regex = TurnMessageRegexCache.inlineTotals else { return nil }
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: fullRange),
              match.numberOfRanges == 3 else {
            return nil
        }

        let plusText = nsLine.substring(with: match.range(at: 1))
        let minusText = nsLine.substring(with: match.range(at: 2))
        guard let plus = Int(plusText), let minus = Int(minusText) else {
            return nil
        }

        return TurnDiffLineTotals(additions: plus, deletions: minus)
    }

    private static func stripInlineTotals(from line: String) -> String {
        guard let regex = TurnMessageRegexCache.trailingInlineTotals else {
            return line
        }
        let fullRange = NSRange(location: 0, length: (line as NSString).length)
        return regex.stringByReplacingMatches(in: line, range: fullRange, withTemplate: "")
    }

    private static func normalizeInlinePath(_ rawToken: String) -> String {
        var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)

        token = token.replacingOccurrences(of: "\"", with: "")
        token = token.replacingOccurrences(of: "'", with: "")

        if let link = parseMarkdownLink(from: token) {
            let destination = normalizeLinkDestination(link.destination)
            if looksLikePath(destination) {
                token = destination
            } else {
                token = link.label
            }
        }

        if token.contains(" ") {
            token = token
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? token
        }

        while let last = token.last, ",.;)".contains(last) {
            token.removeLast()
        }
        if token.hasPrefix("(") {
            token.removeFirst()
        }

        if let regex = TurnMessageRegexCache.trailingLineColumn {
            let fullRange = NSRange(location: 0, length: (token as NSString).length)
            token = regex.stringByReplacingMatches(in: token, range: fullRange, withTemplate: "")
        }

        return token
    }

    private static func looksLikePath(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }

        if token.contains("/") || token.hasPrefix("./") || token.hasPrefix("../") {
            return true
        }

        guard let regex = TurnMessageRegexCache.fileLikeToken else {
            return false
        }
        let nsToken = token as NSString
        let range = NSRange(location: 0, length: nsToken.length)
        return regex.firstMatch(in: token, range: range) != nil
    }

    private static func parseMarkdownLink(from token: String) -> (label: String, destination: String)? {
        TurnMessageRegexCache.parseMarkdownLink(from: token)
    }

    private static func normalizeLinkDestination(_ destination: String) -> String {
        var normalized = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if let queryIndex = normalized.firstIndex(of: "?") {
            normalized = String(normalized[..<queryIndex])
        }
        if let fragmentIndex = normalized.firstIndex(of: "#") {
            normalized = String(normalized[..<fragmentIndex])
        }

        if let url = URL(string: normalized) {
            if url.isFileURL {
                return url.path
            }
            if !url.path.isEmpty {
                return url.path
            }
        }

        return normalized
    }

    private static func parsePathFromDiff(lines: [String]) -> String? {
        for line in lines {
            if line.hasPrefix("+++ ") {
                let candidate = normalizeDiffPath(String(line.dropFirst(4)))
                if !candidate.isEmpty { return candidate }
            }
        }

        for line in lines where line.hasPrefix("diff --git ") {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            if components.count >= 4 {
                let candidate = normalizeDiffPath(String(components[3]))
                if !candidate.isEmpty { return candidate }
            }
        }

        return nil
    }

    private static func normalizeDiffPath(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/dev/null" else { return "" }

        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }

        return trimmed
    }

    private static func countDiffLines(in lines: [String]) -> TurnDiffLineTotals {
        var totals = TurnDiffLineTotals()

        for line in lines {
            if line.isEmpty {
                continue
            }

            if isDiffMetadataLine(line) {
                continue
            }

            if line.hasPrefix("+") {
                totals.additions += 1
            } else if line.hasPrefix("-") {
                totals.deletions += 1
            }
        }

        return totals
    }

    private static func parseDiffBodyEvidence(in lines: [String]) -> TurnDiffLineTotals? {
        let totals = countDiffLines(in: lines)
        if totals.additions > 0 || totals.deletions > 0 {
            return totals
        }
        return nil
    }

    // Matches CodexMonitor counting behavior: ignore metadata and count only patch body +/- rows.
    private static func isDiffMetadataLine(_ line: String) -> Bool {
        let metadataPrefixes = [
            "+++",
            "---",
            "diff --git",
            "@@",
            "index ",
            "\\ No newline",
            "new file mode",
            "deleted file mode",
            "similarity index",
            "rename from",
            "rename to",
        ]

        return metadataPrefixes.contains { line.hasPrefix($0) }
    }

    // Removes one-line edit recap rows so we can render them as dedicated UI blocks.
    static func removingInlineEditingRows(from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let filtered = lines.filter { !isInlineEditingRow($0) }
        let joined = filtered.joined(separator: "\n")
        let collapsed = replaceMatches(
            in: joined,
            regex: TurnMessageRegexCache.collapsibleNewlines,
            template: "\n\n"
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isInlineEditingRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let regex = TurnMessageRegexCache.inlineEditingRow else { return false }
        let nsLine = trimmed as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        return regex.firstMatch(in: trimmed, range: range) != nil
    }

    private static func replaceMatches(
        in text: String,
        regex: NSRegularExpression?,
        template: String
    ) -> String {
        TurnMessageRegexCache.replaceMatches(in: text, regex: regex, template: template)
    }

    private static func consolidate(entries: [TurnFileChangeSummaryEntry]) -> [TurnFileChangeSummaryEntry] {
        var orderedPaths: [String] = []
        var entriesByPath: [String: TurnFileChangeSummaryEntry] = [:]

        for entry in entries {
            if var existing = entriesByPath[entry.path] {
                existing.additions += entry.additions
                existing.deletions += entry.deletions
                if existing.action == nil {
                    existing.action = entry.action
                }
                entriesByPath[entry.path] = existing
                continue
            }

            orderedPaths.append(entry.path)
            entriesByPath[entry.path] = entry
        }

        return orderedPaths.compactMap { entriesByPath[$0] }
    }
}
