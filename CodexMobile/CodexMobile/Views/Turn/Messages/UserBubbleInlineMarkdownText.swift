// FILE: UserBubbleInlineMarkdownText.swift
// Purpose: Renders lightweight inline markdown inside user prompt bubbles.
// Layer: View Support
// Exports: UserBubbleInlineMarkdownText, UserBubbleInlineMarkdownRenderer, UserBubbleBlockMarkdownDetector
// Depends on: Foundation, SwiftUI, TurnMessageCacheCore, TurnMessageRegexCache

import Foundation
import SwiftUI

struct UserBubbleInlineMarkdownText: View {
    let rawText: String
    let foreground: Color

    init(_ rawText: String, foreground: Color) {
        self.rawText = rawText
        self.foreground = foreground
    }

    var body: some View {
        switch UserBubbleInlineMarkdownRenderer.render(rawText) {
        case .plain:
            Text(rawText)
                .foregroundStyle(foreground)
        case .rich(let attributed):
            Text(attributed)
                .foregroundStyle(foreground)
                .tint(foreground)
        }
    }
}

enum UserBubbleInlineMarkdownRenderResult {
    case plain
    case rich(AttributedString)
}

// Detects block-level markdown the inline renderer cannot express; those user
// messages take the shared MarkdownTextView pipeline used by assistant rows.
enum UserBubbleBlockMarkdownDetector {
    static func containsBlockMarkdown(_ rawText: String) -> Bool {
        if rawText.contains("```") || rawText.contains("~~~") {
            return true
        }

        return rawText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .contains { isBlockSyntaxLine($0.drop(while: { $0 == " " || $0 == "\t" })) }
    }

    private static func isBlockSyntaxLine(_ line: Substring) -> Bool {
        guard let first = line.first else {
            return false
        }

        switch first {
        case "#":
            let hashes = line.prefix(while: { $0 == "#" })
            return hashes.count <= 6 && line.dropFirst(hashes.count).first == " "
        case "-", "*", "+":
            return line.dropFirst().first == " " || isThematicBreak(line)
        case ">":
            return true
        case "|":
            return line.dropFirst().contains("|")
        default:
            return isOrderedListItem(line)
        }
    }

    private static func isOrderedListItem(_ line: Substring) -> Bool {
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else {
            return false
        }

        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    private static func isThematicBreak(_ line: Substring) -> Bool {
        guard let marker = line.first, line.count >= 3 else {
            return false
        }
        return line.allSatisfy { $0 == marker }
    }
}

enum UserBubbleInlineMarkdownRenderer {
    private static let cache = BoundedCache<String, UserBubbleInlineMarkdownRenderResult>(maxEntries: 512)
    private static let bareURLRegex = try? NSRegularExpression(
        pattern: #"(?i)\bhttps?://[^\s<>\[\]]+"#
    )
    private static let trailingURLPunctuation = CharacterSet(charactersIn: ".,!?;:)}")

    // Avoids invoking Foundation markdown parsing for the common plain-message path.
    static func render(_ rawText: String) -> UserBubbleInlineMarkdownRenderResult {
        guard shouldParse(rawText) else {
            return .plain
        }

        let key = TurnTextCacheKey.stableKey(namespace: "user-bubble-inline-markdown", text: rawText)
        return cache.getOrSet(key) {
            .rich(parsedAttributedString(from: rawText))
        }
    }

    static func reset() {
        cache.removeAll()
    }

    static func shouldParse(_ rawText: String) -> Bool {
        rawText.contains("[") && rawText.contains("](")
            || rawText.contains("**")
            || hasPairedMarker("*", in: rawText)
            || hasPairedMarker("_", in: rawText)
            || hasPairedMarker("`", in: rawText)
            || rawText.localizedCaseInsensitiveContains("http://")
            || rawText.localizedCaseInsensitiveContains("https://")
    }

    private static func hasPairedMarker(_ marker: Character, in text: String) -> Bool {
        var count = 0
        for character in text where character == marker {
            count += 1
            if count >= 2 {
                return true
            }
        }
        return false
    }

    // Keeps user bubbles inline-only: no headings, tables, fenced blocks, images, or assistant file-link rewrites.
    private static func parsedAttributedString(from rawText: String) -> AttributedString {
        let preparedText = linkifiedBareURLs(in: rawText)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var parsed = (try? AttributedString(markdown: preparedText, options: options)) ?? AttributedString(rawText)
        underlineLinks(in: &parsed)
        return parsed
    }

    private static func underlineLinks(in attributed: inout AttributedString) {
        for run in attributed.runs where run.link != nil {
            attributed[run.range].underlineStyle = Text.LineStyle(pattern: .dot)
        }
    }

    private static func linkifiedBareURLs(in rawText: String) -> String {
        guard let bareURLRegex else {
            return rawText
        }

        let nsText = rawText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = bareURLRegex.matches(in: rawText, range: fullRange)
        guard !matches.isEmpty else {
            return rawText
        }

        let markdownLinkRanges = TurnMessageRegexCache.markdownLinkRanges(in: rawText)
        let inlineCodeRanges = TurnMessageRegexCache.inlineCodeRanges(in: rawText)
        let mutableText = NSMutableString(string: rawText)

        for match in matches.reversed() {
            let urlRange = match.range
            guard !TurnMessageRegexCache.rangeOverlaps(urlRange, protectedRanges: markdownLinkRanges),
                  !TurnMessageRegexCache.rangeOverlaps(urlRange, protectedRanges: inlineCodeRanges) else {
                continue
            }

            var token = nsText.substring(with: urlRange)
            var trailingPunctuation = ""
            while let lastScalar = token.unicodeScalars.last,
                  shouldTrimTrailingPunctuation(lastScalar, from: token) {
                trailingPunctuation.insert(Character(lastScalar), at: trailingPunctuation.startIndex)
                token.removeLast()
            }

            guard !token.isEmpty,
                  let url = URL(string: token),
                  url.scheme?.lowercased().hasPrefix("http") == true else {
                continue
            }

            let replacement = "[\(token)](\(escapedMarkdownDestination(token)))\(trailingPunctuation)"
            mutableText.replaceCharacters(in: match.range, with: replacement)
        }

        return String(mutableText)
    }

    private static func escapedMarkdownDestination(_ destination: String) -> String {
        destination
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    // Keeps wrapper punctuation out of links without breaking URLs that contain balanced parentheses.
    private static func shouldTrimTrailingPunctuation(_ scalar: Unicode.Scalar, from token: String) -> Bool {
        guard trailingURLPunctuation.contains(scalar) else {
            return false
        }
        guard scalar == ")" else {
            return true
        }

        let openingCount = token.reduce(into: 0) { count, character in
            if character == "(" { count += 1 }
        }
        let closingCount = token.reduce(into: 0) { count, character in
            if character == ")" { count += 1 }
        }
        return closingCount > openingCount
    }
}
