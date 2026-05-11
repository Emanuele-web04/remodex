// FILE: ThinkingDisclosureParser.swift
// Purpose: Parses thinking/reasoning text into collapsible disclosure sections.
// Layer: Parser
// Exports: ThinkingDisclosureSection, ThinkingDisclosureContent, ThinkingDisclosureParser
// Depends on: Foundation, TurnMessageRegexCache

import Foundation

struct ThinkingDisclosureSection: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

struct ThinkingDisclosureContent: Equatable {
    let sections: [ThinkingDisclosureSection]
    let fallbackText: String

    var showsDisclosure: Bool { !sections.isEmpty }
}

enum ThinkingDisclosureParser {
    private static let compactActivityPrefixes = [
        "running ",
        "completed ",
        "failed ",
        "stopped ",
        "read ",
        "search ",
        "searched ",
        "exploring ",
        "list ",
        "listing ",
        "open ",
        "opened ",
        "find ",
        "finding ",
        "edit ",
        "edited ",
        "write ",
        "wrote ",
        "apply ",
        "applied ",
    ]

    // Extracts compact summary anchors from standalone bold reasoning lines.
    static func parse(from rawText: String) -> ThinkingDisclosureContent {
        let normalizedText = normalizedThinkingContent(from: rawText)
        guard !normalizedText.isEmpty else {
            return ThinkingDisclosureContent(sections: [], fallbackText: "")
        }

        let lines = normalizedText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var preambleLines: [String] = []
        var currentTitle: String?
        var currentDetailLines: [String] = []
        var sections: [ThinkingDisclosureSection] = []

        func flushCurrentSection() {
            guard let currentTitle else { return }

            let detail = joinedThinkingBlock(from: currentDetailLines)
            sections.append(
                ThinkingDisclosureSection(
                    id: "\(sections.count)-\(currentTitle)",
                    title: currentTitle,
                    detail: detail
                )
            )

            currentDetailLines = []
        }

        for line in lines {
            if let summaryTitle = summaryTitle(from: line) {
                flushCurrentSection()
                currentTitle = summaryTitle
                continue
            }

            if currentTitle == nil {
                preambleLines.append(line)
            } else {
                currentDetailLines.append(line)
            }
        }

        flushCurrentSection()

        if !sections.isEmpty {
            let preamble = joinedThinkingBlock(from: preambleLines)
            if !preamble.isEmpty {
                var firstSection = sections.removeFirst()
                let mergedDetail = [preamble, firstSection.detail]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                firstSection = ThinkingDisclosureSection(
                    id: firstSection.id,
                    title: firstSection.title,
                    detail: mergedDetail
                )
                sections.insert(firstSection, at: 0)
            }

            return ThinkingDisclosureContent(
                sections: coalescedAdjacentSections(from: sections),
                fallbackText: normalizedText
            )
        }

        return ThinkingDisclosureContent(sections: [], fallbackText: normalizedText)
    }

    // Keeps transient thinking labels outside the body so the UI can render status once.
    static func normalizedThinkingContent(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.lowercased().hasPrefix("thinking...") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: "thinking...".count)
            return String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.lowercased() == "thinking" {
            return ""
        }

        return trimmed
    }

    // Collapses activity-only tool traces down to the latest status line for compact timeline rendering.
    static func compactActivityPreview(fromNormalizedText normalizedText: String) -> String? {
        let lines = normalizedText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return nil
        }

        let activityLines = lines.filter { line in
            let normalizedLine = line.lowercased()
            return compactActivityPrefixes.contains(where: { normalizedLine.hasPrefix($0) })
        }

        let isActivityOnly = activityLines.count == lines.count

        guard isActivityOnly else {
            // Some streamed command previews wrap onto follow-up lines that no longer carry the
            // original prefix. In that case keep the first meaningful activity line.
            if activityLines.count == 1, let firstActivityLine = activityLines.first {
                return firstActivityLine
            }
            return nil
        }

        return activityLines.last
    }

    private static func summaryTitle(from line: String) -> String? {
        guard let regex = TurnMessageRegexCache.thinkingSummaryLine else { return nil }

        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 2 else {
            return nil
        }

        let title = nsLine.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func joinedThinkingBlock(from lines: [String]) -> String {
        lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Collapses repeated summary anchors that arrive as streaming snapshots.
    private static func coalescedAdjacentSections(
        from sections: [ThinkingDisclosureSection]
    ) -> [ThinkingDisclosureSection] {
        var collapsed: [ThinkingDisclosureSection] = []

        for section in sections {
            guard var previous = collapsed.last,
                  previous.title == section.title else {
                collapsed.append(section)
                continue
            }

            let mergedDetail: String
            if previous.detail == section.detail || section.detail.isEmpty {
                mergedDetail = previous.detail
            } else if previous.detail.isEmpty || section.detail.contains(previous.detail) {
                mergedDetail = section.detail
            } else if previous.detail.contains(section.detail) {
                mergedDetail = previous.detail
            } else {
                mergedDetail = [previous.detail, section.detail]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            }

            previous = ThinkingDisclosureSection(
                id: previous.id,
                title: previous.title,
                detail: mergedDetail
            )
            collapsed[collapsed.count - 1] = previous
        }

        return collapsed
    }
}
