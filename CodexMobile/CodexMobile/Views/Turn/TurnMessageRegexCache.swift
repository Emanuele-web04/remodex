// FILE: TurnMessageRegexCache.swift
// Purpose: Shared regex patterns for turn message parsing and formatting.
// Layer: Infrastructure
// Exports: TurnMessageRegexCache
// Depends on: Foundation

import Foundation

enum TurnMessageRegexCache {
    static let inlineAction = try? NSRegularExpression(
        pattern: #"(?i)^(edited|updated|added|created|deleted|removed|renamed|moved)\s+(.+?)$"#
    )
    static let inlineTotals = try? NSRegularExpression(
        pattern: #"[+\u{FF0B}]\s*(\d+)\s*[-\u{2212}\u{2013}\u{2014}\u{FE63}\u{FF0D}]\s*(\d+)"#
    )
    static let trailingInlineTotals = try? NSRegularExpression(
        pattern: #"\s*[+\u{FF0B}]\s*\d+\s*[-\u{2212}\u{2013}\u{2014}\u{FE63}\u{FF0D}]\s*\d+\s*$"#
    )
    static let trailingLineColumn = try? NSRegularExpression(pattern: #":\d+(?::\d+)?$"#)
    static let fileLikeToken = try? NSRegularExpression(pattern: #"[A-Za-z0-9_+.-]+\.[A-Za-z0-9]+$"#)
    static let markdownLinkToken = try? NSRegularExpression(pattern: #"^\[([^\]]+)\]\(([^)]+)\)$"#)
    static let heading = try? NSRegularExpression(pattern: #"(?m)^#{1,6}\s+(.+)$"#)
    static let genericPath = try? NSRegularExpression(
        pattern: #"(?:\/[^\s`"'<>]+|~\/[^\s`"'<>]+|\.{1,2}\/[^\s`"'<>]+|[A-Za-z0-9._+\-]+(?:\/[A-Za-z0-9._+\-]+)+)(?::\d+(?::\d+)?)?"#
    )
    static let inlineCodeContent = try? NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    static let markdownLinkRange = try? NSRegularExpression(pattern: #"\[[^\]]+\]\([^)]+\)"#)
    static let inlineCodeRange = try? NSRegularExpression(pattern: #"`[^`]+`"#)
    static let userMentionToken = try? NSRegularExpression(
        // File mentions may contain spaces, but skills remain single-token `$name` values.
        pattern: #"(?<![A-Za-z0-9_])([@$])((?:[^@$\n]+?\.[A-Za-z0-9]+)|(?:[^\s@$]+))(?=[\s,.;:!?)\]}>]|$)"#
    )
    static let filenameWithLine = try? NSRegularExpression(pattern: #"^(.*\.[A-Za-z0-9]+):(\d+)(?::\d+)?$"#)
    static let inlineEditingRow = try? NSRegularExpression(
        pattern: #"(?i)^(edited|updated|added|created|deleted|removed|renamed|moved)\s+.+\s+[+\u{FF0B}]\s*\d+\s*[-\u{2212}\u{2013}\u{2014}\u{FE63}\u{FF0D}]\s*\d+\s*$"#
    )
    static let collapsibleNewlines = try? NSRegularExpression(pattern: #"\n{3,}"#)
    static let thinkingSummaryLine = try? NSRegularExpression(pattern: #"^\s*\*\*(.+?)\*\*\s*$"#)

    // ─── Shared Helpers ─────────────────────────────────────────────

    static func parseMarkdownLink(from token: String) -> (label: String, destination: String)? {
        guard let regex = markdownLinkToken else { return nil }

        let nsToken = token as NSString
        let fullRange = NSRange(location: 0, length: nsToken.length)
        guard let match = regex.firstMatch(in: token, range: fullRange),
              match.numberOfRanges == 3 else {
            return nil
        }

        let label = nsToken.substring(with: match.range(at: 1))
        let destination = nsToken.substring(with: match.range(at: 2))
        return (label: label, destination: destination)
    }

    static func markdownLinkRanges(in line: String) -> [NSRange] {
        guard let regex = markdownLinkRange else { return [] }
        let nsLine = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length)).map(\.range)
    }

    static func inlineCodeRanges(in line: String) -> [NSRange] {
        guard let regex = inlineCodeRange else { return [] }
        let nsLine = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length)).map(\.range)
    }

    static func rangeOverlaps(_ range: NSRange, protectedRanges: [NSRange]) -> Bool {
        for protectedRange in protectedRanges where NSIntersectionRange(range, protectedRange).length > 0 {
            return true
        }
        return false
    }

    static func replaceMatches(in text: String, regex: NSRegularExpression?, template: String) -> String {
        guard let regex else { return text }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: template)
    }

    static func removingTrailingLineColumnSuffix(from token: String) -> String {
        guard let regex = trailingLineColumn else {
            return token
        }

        let fullRange = NSRange(location: 0, length: (token as NSString).length)
        guard let match = regex.firstMatch(in: token, range: fullRange),
              match.range.location != NSNotFound,
              let range = Range(match.range, in: token) else {
            return token
        }

        var normalizedToken = token
        normalizedToken.removeSubrange(range)
        return normalizedToken
    }
}

// Shared heuristics for deciding whether an `@token` is plausibly a file/path
// reference instead of copied terminal syntax such as `@scope/pkg:build`.
enum TurnFileMentionHeuristics {
    // Keeps common extensionless files mentionable without reopening the door to arbitrary
    // terminal handles such as `@workspace` or `@remodex`.
    private static let allowedExtensionlessFileNames: Set<String> = [
        ".env",
        ".env.example",
        ".gitignore",
        ".node-version",
        ".nvmrc",
        "Brewfile",
        "Cartfile",
        "Dangerfile",
        "Dockerfile",
        "Gemfile",
        "LICENSE",
        "Makefile",
        "Podfile",
        "Procfile",
        "README",
        "Rakefile",
    ]

    static func isAllowedAutocompleteQuery(_ query: String) -> Bool {
        isAllowedFileLikeToken(query)
    }

    static func isAllowedInlineMentionToken(_ token: String) -> Bool {
        isAllowedFileLikeToken(token)
    }

    private static func isAllowedFileLikeToken(_ token: String) -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return false
        }

        guard !containsUnsupportedColonSyntax(trimmedToken) else {
            return false
        }

        if looksPathLike(trimmedToken) {
            return true
        }

        if allowedExtensionlessFileNames.contains(trimmedToken) {
            return true
        }

        return false
    }

    private static func looksPathLike(_ token: String) -> Bool {
        let normalizedToken = TurnMessageRegexCache.removingTrailingLineColumnSuffix(from: token)
        return normalizedToken.contains("/")
            || normalizedToken.contains("\\")
            || normalizedToken.contains(".")
    }

    // Keeps `foo.swift:42` valid while rejecting task labels like `pkg/build:watch`.
    private static func containsUnsupportedColonSyntax(_ token: String) -> Bool {
        var normalizedToken = TurnMessageRegexCache.removingTrailingLineColumnSuffix(from: token)
        if hasWindowsDrivePrefix(normalizedToken) {
            normalizedToken.removeFirst(2)
        }
        return normalizedToken.contains(":")
    }

    private static func hasWindowsDrivePrefix(_ token: String) -> Bool {
        guard token.count >= 3 else { return false }
        let characters = Array(token)
        return characters[0].isLetter && characters[1] == ":" && (characters[2] == "\\" || characters[2] == "/")
    }
}
