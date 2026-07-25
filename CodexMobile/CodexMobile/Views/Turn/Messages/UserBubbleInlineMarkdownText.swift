// FILE: UserBubbleInlineMarkdownText.swift
// Purpose: Renders lightweight inline markdown inside user prompt bubbles.
// Layer: View Support
// Exports: UserBubbleInlineMarkdownText, UserBubbleInlineMarkdownRenderer, UserBubbleBlockMarkdownDetector,
//   UserBubbleCollapsedMarkdownPreview
// Depends on: Foundation, SwiftUI, TurnMessageCacheCore, TurnMessageRegexCache, StreamingInlineMarkupAutoCloser

import Foundation
import SwiftUI
import UIKit

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

struct UserBubbleInlineSkillText: View {
    let segments: [UserBubbleInlineSegment]
    let foreground: Color
    let skillForeground: Color
    @ScaledMetric(relativeTo: .body) private var skillIconSide: CGFloat = 17

    init(_ segments: [UserBubbleInlineSegment], foreground: Color, skillForeground: Color) {
        self.segments = segments
        self.foreground = foreground
        self.skillForeground = skillForeground
    }

    var body: some View {
        renderedText
            .foregroundStyle(foreground)
            .tint(foreground)
    }

    private var renderedText: Text {
        segments.reduce(Text("")) { partial, segment in
            partial + text(for: segment)
        }
    }

    private func text(for segment: UserBubbleInlineSegment) -> Text {
        switch segment {
        case .text(let rawText):
            switch UserBubbleInlineMarkdownRenderer.render(rawText) {
            case .plain:
                return Text(rawText)
            case .rich(let attributed):
                return Text(attributed)
            }
        case .skillMention(_, let displayLabel):
            let iconText = Text(Image(uiImage: skillIcon))
                .baselineOffset(skillIconBaselineOffset)
            return (iconText + Text("\u{00A0}\(displayLabel)"))
                .foregroundColor(skillForeground)
        }
    }

    private var skillIconBaselineOffset: CGFloat {
        let bodyFont = AppFont.bodyUIFont()
        return (bodyFont.ascender + bodyFont.descender - skillIconSide) / 2
    }

    private var skillIcon: UIImage {
        guard let base = RemodexIcon.uiImage(systemName: "remodex.skill") else { return UIImage() }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let size = CGSize(width: skillIconSide, height: skillIconSide)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.withRenderingMode(.alwaysTemplate)
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

// Collapsed block-markdown bubbles render only this bounded prefix, so a long
// paste never pays full StructuredText layout just to be clipped to ~10 lines.
enum UserBubbleCollapsedMarkdownPreview {
    private static let cache = BoundedCache<String, String>(maxEntries: 256)
    private static let maxLines = 10
    private static let maxCharacters = 1_200

    static func previewText(for rawText: String) -> String {
        guard needsTruncation(rawText) else {
            return rawText
        }

        let key = TurnTextCacheKey.stableKey(namespace: "user-bubble-collapsed-preview", text: rawText)
        return cache.getOrSet(key) {
            truncatedPreview(from: rawText)
        }
    }

    static func reset() {
        cache.removeAll()
    }

    // Bounded scan; text within both limits is already its own preview.
    private static func needsTruncation(_ rawText: String) -> Bool {
        var characterCount = 0
        var newlineCount = 0
        for character in rawText {
            characterCount += 1
            if characterCount > maxCharacters {
                return true
            }
            if character == "\n" {
                newlineCount += 1
                if newlineCount >= maxLines {
                    return true
                }
            }
        }
        return false
    }

    private static func truncatedPreview(from rawText: String) -> String {
        var openFenceCloser: String?
        var includedLines = 0
        var remainingCharacters = maxCharacters
        var cutIndex = rawText.endIndex
        var lineStart = rawText.startIndex

        while lineStart < rawText.endIndex {
            let lineEnd = rawText[lineStart...].firstIndex(of: "\n") ?? rawText.endIndex
            let line = rawText[lineStart..<lineEnd]

            if let budgetIndex = line.index(line.startIndex, offsetBy: remainingCharacters, limitedBy: line.endIndex),
               budgetIndex < line.endIndex {
                // Single overlong line (minified pastes): cut mid-line at the budget.
                cutIndex = budgetIndex
                break
            }

            // A tilde fence is only closed by tildes, so remember which closer is owed.
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            if let fenceCloser = openFenceCloser {
                if content.hasPrefix(fenceCloser) {
                    openFenceCloser = nil
                }
            } else if content.hasPrefix("```") {
                openFenceCloser = "```"
            } else if content.hasPrefix("~~~") {
                openFenceCloser = "~~~"
            }

            includedLines += 1
            remainingCharacters -= line.count + 1
            if includedLines >= maxLines || remainingCharacters <= 0 {
                cutIndex = lineEnd
                break
            }
            lineStart = lineEnd < rawText.endIndex ? rawText.index(after: lineEnd) : rawText.endIndex
        }

        let preview = String(rawText[..<cutIndex])
        if let openFenceCloser {
            // An unterminated fence would swallow the rest of the preview's styling.
            return preview + "\n" + openFenceCloser
        }
        return StreamingInlineMarkupAutoCloser.autoClosed(preview)
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
        // Bubbles render at `AppFont.body()`, so code spans take the matching mono size.
        AppFont.monospaceCodeSpans(in: &parsed)
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
