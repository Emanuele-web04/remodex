// FILE: SkillReferenceFormatter.swift
// Purpose: Replaces skill file-path references with compact display names or mention tokens.
// Layer: Parser
// Exports: SkillReferenceFormatter
// Depends on: Foundation, TurnMessageRegexCache, SkillDisplayNameFormatter

import Foundation

enum SkillReferenceFormatter {
    // Only paths under dedicated skill roots should render as skills; project files named Skill.md stay normal files.
    private static let knownSkillPathMarkers = [
        "/.codex/skills/",
        "/.agents/skills/",
    ]

    static func replacingSkillReferences(
        in text: String,
        style: SkillReferenceReplacementStyle
    ) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var isInsideFence = false

        let transformed = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                isInsideFence.toggle()
                return line
            }

            guard !isInsideFence else {
                return line
            }

            return replacingSkillReferencesInLine(line, style: style)
        }

        return transformed.joined(separator: "\n")
    }

    private static func replacingSkillReferencesInLine(
        _ line: String,
        style: SkillReferenceReplacementStyle
    ) -> String {
        var transformedLine = replaceMarkdownSkillLinks(in: line, style: style)
        transformedLine = replaceInlineCodeSkillReferences(in: transformedLine, style: style)
        return replaceGenericSkillPaths(in: transformedLine, style: style)
    }

    private static func replaceMarkdownSkillLinks(
        in line: String,
        style: SkillReferenceReplacementStyle
    ) -> String {
        guard let regex = TurnMessageRegexCache.markdownLinkRange else {
            return line
        }

        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard !matches.isEmpty else {
            return line
        }

        let mutableLine = NSMutableString(string: line)
        for match in matches.reversed() {
            let token = nsLine.substring(with: match.range)
            guard let skillName = skillName(fromReference: token) else {
                continue
            }

            mutableLine.replaceCharacters(
                in: match.range,
                with: replacementText(for: skillName, style: style)
            )
        }

        return String(mutableLine)
    }

    private static func replaceInlineCodeSkillReferences(
        in line: String,
        style: SkillReferenceReplacementStyle
    ) -> String {
        guard let regex = TurnMessageRegexCache.inlineCodeContent else {
            return line
        }

        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard !matches.isEmpty else {
            return line
        }

        let mutableLine = NSMutableString(string: line)
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else {
                continue
            }

            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound, tokenRange.length > 0 else {
                continue
            }

            let token = nsLine.substring(with: tokenRange)
            guard let skillName = skillName(fromReference: token) else {
                continue
            }

            mutableLine.replaceCharacters(
                in: match.range,
                with: replacementText(for: skillName, style: style)
            )
        }

        return String(mutableLine)
    }

    private static func replaceGenericSkillPaths(
        in line: String,
        style: SkillReferenceReplacementStyle
    ) -> String {
        guard let regex = TurnMessageRegexCache.genericPath else {
            return line
        }

        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        guard !matches.isEmpty else {
            return line
        }

        let linkRanges = markdownLinkRanges(in: line)
        let inlineCodeRanges = inlineCodeRanges(in: line)
        let mutableLine = NSMutableString(string: line)
        for match in matches.reversed() {
            let matchRange = match.range
            guard !rangeOverlaps(matchRange, protectedRanges: linkRanges) else {
                continue
            }
            guard !rangeOverlaps(matchRange, protectedRanges: inlineCodeRanges) else {
                continue
            }

            let token = nsLine.substring(with: matchRange)
            guard let skillName = skillName(fromReference: token) else {
                continue
            }

            mutableLine.replaceCharacters(
                in: matchRange,
                with: replacementText(for: skillName, style: style)
            )
        }

        return String(mutableLine)
    }

    private static func skillName(fromReference rawReference: String) -> String? {
        let normalized = normalizedPath(fromReference: rawReference)
        guard isSkillPath(normalized) else {
            return nil
        }

        let pathComponents = normalized.split(separator: "/").map(String.init)
        guard let skillsIndex = pathComponents.firstIndex(of: "skills"),
              pathComponents.indices.contains(skillsIndex + 1) else {
            return nil
        }

        let skillName = pathComponents[skillsIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return skillName.isEmpty ? nil : skillName
    }

    private static func normalizedPath(fromReference rawReference: String) -> String {
        var candidate = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))

        if let markdownLink = parseMarkdownLink(candidate) {
            candidate = markdownLink.destination
        }

        while let last = candidate.last, ",.;)]}".contains(last) {
            candidate.removeLast()
        }
        if candidate.hasPrefix("(") {
            candidate.removeFirst()
        }

        if let queryIndex = candidate.firstIndex(of: "?") {
            candidate = String(candidate[..<queryIndex])
        }
        if let fragmentIndex = candidate.firstIndex(of: "#") {
            candidate = String(candidate[..<fragmentIndex])
        }

        if let url = URL(string: candidate) {
            if url.isFileURL {
                return url.path
            }
            if !url.path.isEmpty {
                return url.path
            }
        }

        return candidate
    }

    private static func isSkillPath(_ normalizedPath: String) -> Bool {
        let lowercasedPath = normalizedPath.lowercased()
        guard lowercasedPath.hasSuffix("/skill.md") else {
            return false
        }

        return knownSkillPathMarkers.contains { lowercasedPath.contains($0) }
    }

    private static func replacementText(
        for skillName: String,
        style: SkillReferenceReplacementStyle
    ) -> String {
        switch style {
        case .mentionToken:
            return "$\(skillName)"
        case .displayName:
            return SkillDisplayNameFormatter.displayName(for: skillName)
        }
    }

    private static func parseMarkdownLink(_ token: String) -> (label: String, destination: String)? {
        TurnMessageRegexCache.parseMarkdownLink(from: token)
    }

    private static func markdownLinkRanges(in line: String) -> [NSRange] {
        TurnMessageRegexCache.markdownLinkRanges(in: line)
    }

    private static func inlineCodeRanges(in line: String) -> [NSRange] {
        TurnMessageRegexCache.inlineCodeRanges(in: line)
    }

    private static func rangeOverlaps(_ range: NSRange, protectedRanges: [NSRange]) -> Bool {
        TurnMessageRegexCache.rangeOverlaps(range, protectedRanges: protectedRanges)
    }
}
