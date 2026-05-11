// FILE: TurnFileChangeBlockPresentation.swift
// Purpose: Builds and caches file-change block summaries for assistant turn accessories.
// Layer: View Support
// Exports: FileChangeBlockPresentation, FileChangeBlockPresentationBuilder, FileChangeBlockPresentationCache
// Depends on: Foundation, CodexMessage, TurnFileChangeSummaryParser, TurnDiffLineKind

import Foundation

struct FileChangeBlockPresentation {
    let entries: [TurnFileChangeSummaryEntry]
    let bodyText: String
}

private struct FileChangeBlockAggregate {
    var path: String
    var additions: Int
    var deletions: Int
    var action: TurnFileChangeAction?
    var diffSections: [String]
    var totalsBySourceIndex: [Int: TurnDiffLineTotals]
}

private struct RawFileChangeDiffSection {
    let path: String
    let action: TurnFileChangeAction?
    let additions: Int
    let deletions: Int
    let diffCode: String
}

// Builds one per-file diff model from raw file-change messages. Summary Totals
// override same-message diff counts, then separate messages for the same file add up.
enum FileChangeBlockPresentationBuilder {
    static func build(from messages: [CodexMessage]) -> FileChangeBlockPresentation? {
        guard !messages.isEmpty else {
            return nil
        }

        var aggregates: [FileChangeBlockAggregate] = []
        aggregates.reserveCapacity(messages.count)

        for (messageIndex, message) in messages.enumerated() {
            let parsedEntries = TurnFileChangeSummaryParser.parse(from: message.text)?.entries ?? []
            let diffSections = RawFileChangeDiffSectionParser.parse(
                bodyText: message.text,
                fallbackPaths: parsedEntries.map(\.path)
            )

            for section in diffSections {
                mergeDiffSection(section, sourceIndex: messageIndex, into: &aggregates)
            }

            for entry in parsedEntries {
                mergeSummaryEntry(entry, sourceIndex: messageIndex, into: &aggregates)
            }
        }

        let entries = aggregates.map { aggregate in
            TurnFileChangeSummaryEntry(
                path: aggregate.path,
                additions: aggregate.additions,
                deletions: aggregate.deletions,
                action: aggregate.action
            )
        }
        guard !entries.isEmpty else {
            return nil
        }

        let bodyText = aggregates.map { aggregate in
            let action = aggregate.action?.rawValue.lowercased() ?? "edited"
            let diffBody = aggregate.diffSections.isEmpty
                ? ""
                : """

                ```diff
                \(aggregate.diffSections.joined(separator: "\n\n"))
                ```
                """

            return """
            Path: \(aggregate.path)
            Kind: \(action)
            Totals: +\(aggregate.additions) -\(aggregate.deletions)\(diffBody)
            """
        }
        .joined(separator: "\n\n---\n\n")

        return FileChangeBlockPresentation(entries: entries, bodyText: bodyText)
    }

    private static func mergeSummaryEntry(
        _ entry: TurnFileChangeSummaryEntry,
        sourceIndex: Int,
        into aggregates: inout [FileChangeBlockAggregate]
    ) {
        if let existingIndex = aggregates.firstIndex(where: {
            FileChangePathIdentity.representsSameFile($0.path, entry.path)
        }) {
            let existing = aggregates[existingIndex]
            var updated = existing
            updated.path = FileChangePathIdentity.preferredDisplayPath(existing.path, entry.path)
            updated.action = mergedFileChangeAction(existing: existing.action, incoming: entry.action)
            updated.totalsBySourceIndex[sourceIndex] = TurnDiffLineTotals(
                additions: entry.additions,
                deletions: entry.deletions
            )
            applyTotals(from: updated.totalsBySourceIndex, to: &updated)

            aggregates[existingIndex] = updated
            return
        }

        aggregates.append(
            FileChangeBlockAggregate(
                path: entry.path,
                additions: entry.additions,
                deletions: entry.deletions,
                action: entry.action,
                diffSections: [],
                totalsBySourceIndex: [
                    sourceIndex: TurnDiffLineTotals(
                        additions: entry.additions,
                        deletions: entry.deletions
                    ),
                ]
            )
        )
    }

    private static func mergeDiffSection(
        _ section: RawFileChangeDiffSection,
        sourceIndex: Int,
        into aggregates: inout [FileChangeBlockAggregate]
    ) {
        let normalizedDiff = section.diffCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDiff.isEmpty else {
            return
        }

        if let existingIndex = aggregates.firstIndex(where: {
            FileChangePathIdentity.representsSameFile($0.path, section.path)
        }) {
            var existing = aggregates[existingIndex]
            existing.path = FileChangePathIdentity.preferredDisplayPath(existing.path, section.path)
            existing.action = mergedFileChangeAction(existing: existing.action, incoming: section.action)

            if existing.diffSections.contains(normalizedDiff) {
                aggregates[existingIndex] = existing
                return
            }

            existing.totalsBySourceIndex[sourceIndex, default: TurnDiffLineTotals()].additions += section.additions
            existing.totalsBySourceIndex[sourceIndex, default: TurnDiffLineTotals()].deletions += section.deletions
            applyTotals(from: existing.totalsBySourceIndex, to: &existing)
            existing.diffSections.append(normalizedDiff)
            aggregates[existingIndex] = existing
            return
        }

        aggregates.append(
            FileChangeBlockAggregate(
                path: section.path,
                additions: section.additions,
                deletions: section.deletions,
                action: section.action,
                diffSections: [normalizedDiff],
                totalsBySourceIndex: [
                    sourceIndex: TurnDiffLineTotals(
                        additions: section.additions,
                        deletions: section.deletions
                    ),
                ]
            )
        )
    }

    private static func applyTotals(
        from totalsBySourceIndex: [Int: TurnDiffLineTotals],
        to aggregate: inout FileChangeBlockAggregate
    ) {
        aggregate.additions = totalsBySourceIndex.values.reduce(0) { $0 + $1.additions }
        aggregate.deletions = totalsBySourceIndex.values.reduce(0) { $0 + $1.deletions }
    }

    private static func mergedFileChangeAction(
        existing: TurnFileChangeAction?,
        incoming: TurnFileChangeAction?
    ) -> TurnFileChangeAction? {
        switch (existing, incoming) {
        case let (lhs?, rhs?) where lhs == rhs:
            return lhs
        case (.added, _), (_, .added):
            return .added
        case (.deleted, _), (_, .deleted):
            return .deleted
        case (.renamed, _), (_, .renamed):
            return .renamed
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (.edited, _), (_, .edited):
            return .edited
        case (nil, nil):
            return nil
        }
    }
}

enum FileChangeBlockPresentationCache {
    private static let cache = BoundedCache<String, FileChangeBlockPresentation?>(maxEntries: 128)

    static func presentation(from messages: [CodexMessage]) -> FileChangeBlockPresentation? {
        guard !messages.isEmpty else { return nil }
        let key = messages.map { message in
            TurnTextCacheKey.key(messageID: message.id, kind: "block-file-change", text: message.text)
        }.joined(separator: "||")
        return cache.getOrSet(key) {
            FileChangeBlockPresentationBuilder.build(from: messages)
        }
    }

    static func reset() {
        cache.removeAll()
    }
}

private enum RawFileChangeDiffSectionParser {
    static func parse(bodyText: String, fallbackPaths: [String]) -> [RawFileChangeDiffSection] {
        let sections = bodyText.components(separatedBy: "\n\n---\n\n")
        if sections.count > 1 {
            return sections.enumerated().compactMap { index, section in
                parseSection(
                    lines: section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                    fallbackPath: index < fallbackPaths.count ? fallbackPaths[index] : nil
                )
            }
        }

        let lines = bodyText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rawSections: [RawFileChangeDiffSection] = []
        var currentPath: String?
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsedPath = extractPath(from: [trimmed]) {
                currentPath = parsedPath
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate == "```" { break }
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }

                let code = codeLines.joined(separator: "\n")
                if TurnDiffLineKind.detectVerifiedPatch(in: code) {
                    let resolvedPath = currentPath
                        ?? parsePathFromDiff(lines: codeLines)
                        ?? (rawSections.count < fallbackPaths.count ? fallbackPaths[rawSections.count] : nil)
                    if let resolvedPath, !resolvedPath.isEmpty {
                        let totals = countDiffLines(in: codeLines)
                        rawSections.append(
                            RawFileChangeDiffSection(
                                path: resolvedPath,
                                action: detectAction(from: codeLines),
                                additions: totals.additions,
                                deletions: totals.deletions,
                                diffCode: code
                            )
                        )
                    }
                    currentPath = nil
                }
                continue
            }

            i += 1
        }

        return rawSections
    }

    private static func parseSection(lines: [String], fallbackPath: String?) -> RawFileChangeDiffSection? {
        guard let code = extractFencedCode(from: lines),
              TurnDiffLineKind.detectVerifiedPatch(in: code) else {
            return nil
        }
        let resolvedPath = extractPath(from: lines) ?? fallbackPath
        guard let resolvedPath, !resolvedPath.isEmpty else {
            return nil
        }

        let totals = countDiffLines(in: code.components(separatedBy: "\n"))
        return RawFileChangeDiffSection(
            path: resolvedPath,
            action: extractKind(from: lines) ?? detectAction(from: code.components(separatedBy: "\n")),
            additions: totals.additions,
            deletions: totals.deletions,
            diffCode: code
        )
    }

    private static func extractPath(from lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("**Path:**") || trimmed.hasPrefix("Path:") {
                let raw = trimmed
                    .replacingOccurrences(of: "**Path:**", with: "")
                    .replacingOccurrences(of: "Path:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if !raw.isEmpty {
                    return raw
                }
            }
        }
        return nil
    }

    private static func extractKind(from lines: [String]) -> TurnFileChangeAction? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("kind:") else { continue }
            let value = trimmed.dropFirst("Kind:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return TurnFileChangeAction.fromKind(value)
        }
        return nil
    }

    private static func extractFencedCode(from lines: [String]) -> String? {
        var inFence = false
        var codeLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                if inFence {
                    return codeLines.joined(separator: "\n")
                }
                inFence = true
                codeLines = []
                continue
            }
            if inFence {
                codeLines.append(line)
            }
        }
        return inFence ? codeLines.joined(separator: "\n") : nil
    }

    private static func parsePathFromDiff(lines: [String]) -> String? {
        for line in lines where line.hasPrefix("+++ ") {
            let candidate = normalizeDiffPath(String(line.dropFirst(4)))
            if !candidate.isEmpty {
                return candidate
            }
        }

        for line in lines where line.hasPrefix("diff --git ") {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            if components.count >= 4 {
                let candidate = normalizeDiffPath(String(components[3]))
                if !candidate.isEmpty {
                    return candidate
                }
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
            if line.isEmpty || isDiffMetadataLine(line) {
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
}
