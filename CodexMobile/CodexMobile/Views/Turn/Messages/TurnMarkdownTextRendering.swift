// FILE: TurnMarkdownTextRendering.swift
// Purpose: Renders and formats markdown text used by turn timeline rows.
// Layer: Turn UI rendering
// Exports: MarkdownTextView, StreamingAssistantMarkdownTextView, MarkdownTextFormatter
// Depends on: Foundation, SwiftUI, Textual, TurnMessageCaches, TurnMessageRegexCache

import Foundation
import SwiftUI
import Textual

/// Resets the in-memory AttributedString cache that backs ``MarkdownTextView``.
/// Kept for explicit memory recovery without forcing cold parses on every thread switch.
@MainActor
enum MarkdownParseCacheReset {
    static func reset() { CachingMarkdownParser.reset() }
}

// Wraps the default Textual markdown parser with a bounded AttributedString
// cache so Foundation's markdown parser is not re-run during timeline redraws
// or when a future lazy container recycles a row on upward scroll.
@MainActor
private struct CachingMarkdownParser: MarkupParser {
    static let shared = CachingMarkdownParser()
    private static let cache = BoundedCache<String, AttributedString>(maxEntries: 128)
    private let inner: AttributedStringMarkdownParser = .markdown()

    func attributedString(for input: String) throws -> AttributedString {
        let key = TurnTextCacheKey.stableKey(namespace: "markdown-parser", text: input)
        if let cached = Self.cache.get(key) {
            return cached
        }
        let result = try inner.attributedString(for: input)
        Self.cache.set(key, value: result)
        return result
    }

    static func reset() {
        cache.removeAll()
    }
}

@MainActor
private struct UncachedMarkdownParser: MarkupParser {
    static let shared = UncachedMarkdownParser()
    private let inner: AttributedStringMarkdownParser = .markdown()

    func attributedString(for input: String) throws -> AttributedString {
        try inner.attributedString(for: input)
    }
}

struct MarkdownTextView: View {
    let text: String
    let profile: MarkdownRenderProfile
    var enablesSelection: Bool = false
    var constrainsToAvailableWidth: Bool = false
    var usesCaches: Bool = true

    var body: some View {
        let transformed = MarkdownTextFormatter.renderableText(
            from: text,
            profile: profile,
            usesCache: usesCaches
        )
        let parser: any MarkupParser = usesCaches
            ? CachingMarkdownParser.shared
            : UncachedMarkdownParser.shared
        // Keep prose on the app font, but let Textual own markdown/code layout to avoid block sizing regressions.
        // Force code-block overflow to wrap instead of scroll so horizontal ScrollViews
        // inside the timeline do not compete with the sidebar swipe gesture or let
        // the chat feel like a pannable canvas.
        let baseView = StructuredText(transformed, parser: parser)
            .font(AppFont.body())
            .textual.structuredTextStyle(.gitHub)
            .textual.overflowMode(.wrap)

        let renderedContent = Group {
            if enablesSelection {
                baseView
                    .textual.textSelection(.enabled)
            } else {
                baseView
            }
        }

        if constrainsToAvailableWidth {
            renderedContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
        } else {
            renderedContent
        }
    }
}

struct StreamingAssistantMarkdownTextView: View {
    let text: String
    var enablesSelection: Bool = false
    var constrainsToAvailableWidth: Bool = false

    @State private var displayedText = ""
    @State private var displayedSegments: StreamingMarkdownBlockSegments

    init(
        text: String,
        enablesSelection: Bool = false,
        constrainsToAvailableWidth: Bool = false
    ) {
        self.text = text
        self.enablesSelection = enablesSelection
        self.constrainsToAvailableWidth = constrainsToAvailableWidth
        _displayedText = State(initialValue: text)
        _displayedSegments = State(initialValue: StreamingMarkdownBlockSplitter.split(text))
    }

    var body: some View {
        Group {
            if constrainsToAvailableWidth {
                renderedSegments(displayedSegments)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                renderedSegments(displayedSegments)
            }
        }
        .onAppear {
            reconcileDisplayedText(with: text)
        }
        .onChange(of: text) { _, nextText in
            reconcileDisplayedText(with: nextText)
        }
    }

    @ViewBuilder
    private func renderedSegments(_ segments: StreamingMarkdownBlockSegments) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(segments.stableChunks) { chunk in
                MarkdownTextView(
                    text: chunk.text,
                    profile: .assistantProse,
                    enablesSelection: enablesSelection,
                    constrainsToAvailableWidth: constrainsToAvailableWidth
                )
            }

            if !segments.activeMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownTextView(
                    text: segments.activeMarkdown,
                    profile: .assistantProse,
                    enablesSelection: enablesSelection,
                    constrainsToAvailableWidth: constrainsToAvailableWidth,
                    usesCaches: false
                )
            }
        }
    }

    // Keep streaming append-oriented while promoting completed blocks to cached markdown.
    private func reconcileDisplayedText(with nextText: String) {
        guard !nextText.isEmpty else {
            guard !displayedText.isEmpty else { return }
            displayedText = ""
            displayedSegments = StreamingMarkdownBlockSplitter.split("")
            return
        }
        if nextText.hasPrefix(displayedText) {
            let appended = String(nextText.dropFirst(displayedText.count))
            guard !appended.isEmpty else { return }
            displayedText.append(appended)
        } else {
            guard displayedText != nextText else { return }
            displayedText = nextText
        }
        displayedSegments = StreamingMarkdownBlockSplitter.split(displayedText)
    }
}

private struct StreamingMarkdownBlockSegments {
    let stableChunks: [StreamingMarkdownChunk]
    let activeMarkdown: String
}

private struct StreamingMarkdownChunk: Identifiable {
    let id: Int
    let text: String
}

private enum StreamingMarkdownBlockSplitter {
    private static let stableChunkTargetCharacterCount = 6_000

    static func split(_ text: String) -> StreamingMarkdownBlockSegments {
        var lineStart = text.startIndex
        var chunkStart = text.startIndex
        var isInsideFence = false
        var stableChunks: [StreamingMarkdownChunk] = []

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let nextLineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            let hasLineBreak = lineEnd < text.endIndex
            let trimmedLine = String(text[lineStart..<lineEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var stableBoundary: String.Index?
            if isFenceDelimiter(trimmedLine) {
                isInsideFence.toggle()
                if !isInsideFence {
                    stableBoundary = nextLineStart
                }
            } else if !isInsideFence, hasLineBreak {
                if trimmedLine.isEmpty || isStableSingleLineBlock(trimmedLine) {
                    stableBoundary = nextLineStart
                }
            }

            if let stableBoundary,
               shouldSealChunk(in: text, from: chunkStart, to: stableBoundary) {
                appendChunk(in: text, from: chunkStart, to: stableBoundary, into: &stableChunks)
                chunkStart = stableBoundary
            }

            lineStart = nextLineStart
        }

        return StreamingMarkdownBlockSegments(
            stableChunks: stableChunks,
            activeMarkdown: String(text[chunkStart...])
        )
    }

    // Keep the newest chunk intact so Textual can apply native paragraph/list/code spacing
    // while old chunks stop reparsing during long streaming responses.
    private static func shouldSealChunk(in text: String, from start: String.Index, to boundary: String.Index) -> Bool {
        guard boundary < text.endIndex else { return false }
        return text.distance(from: start, to: boundary) >= stableChunkTargetCharacterCount
    }

    private static func appendChunk(
        in text: String,
        from start: String.Index,
        to end: String.Index,
        into chunks: inout [StreamingMarkdownChunk]
    ) {
        guard start < end else { return }
        let chunkText = String(text[start..<end])
        guard !chunkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chunks.append(
            StreamingMarkdownChunk(
                id: chunks.count,
                text: chunkText
            )
        )
    }

    private static func isFenceDelimiter(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }

    private static func isStableSingleLineBlock(_ trimmedLine: String) -> Bool {
        let headingMarkerCount = trimmedLine.prefix(while: { $0 == "#" }).count
        let isHeading = (1...6).contains(headingMarkerCount)
            && trimmedLine.dropFirst(headingMarkerCount).hasPrefix(" ")
        return isHeading || trimmedLine == "---" || trimmedLine == "***"
    }
}

enum MarkdownTextFormatter {
    // Applies lightweight markdown cleanup and turns file paths into link-styled labels.
    static func renderableText(
        from raw: String,
        profile: MarkdownRenderProfile,
        usesCache: Bool = true
    ) -> String {
        let build = {
            renderableTextUncached(from: raw, profile: profile)
        }

        if usesCache {
            return MarkdownRenderableTextCache.rendered(raw: raw, profile: profile, builder: build)
        }

        return build()
    }

    private static func renderableTextUncached(from raw: String, profile: MarkdownRenderProfile) -> String {
        let normalizedSkills = SkillReferenceFormatter.replacingSkillReferences(
            in: raw,
            style: .displayName
        )
        let headingNormalized = replaceMatches(
            in: normalizedSkills,
            regex: TurnMessageRegexCache.heading,
            template: "**$1**"
        )
        return linkifyFileReferenceLines(in: headingNormalized, profile: profile)
    }

    private static func linkifyFileReferenceLines(in text: String, profile: MarkdownRenderProfile) -> String {
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

            return linkifyInlineFileReferences(in: line, profile: profile)
        }

        return transformed.joined(separator: "\n")
    }

    private static func linkifyInlineFileReferences(in line: String, profile: MarkdownRenderProfile) -> String {
        switch profile {
        case .assistantProse, .fileChangeSystem:
            break
        }

        var transformedLine = line

        if let fileLinked = linkifyFileReferenceLine(transformedLine), fileLinked != transformedLine {
            transformedLine = fileLinked
        }

        transformedLine = linkifyInlineCodeFileReferences(in: transformedLine)
        return linkifyGenericPathTokens(in: transformedLine)
    }

    private static func linkifyFileReferenceLine(_ line: String) -> String? {
        guard let markerRange = line.range(of: "File:") else {
            return nil
        }

        let prefix = String(line[..<markerRange.lowerBound])
        let rawReference = line[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawReference.isEmpty,
              !rawReference.contains("]("),
              let parsed = parseFileReference(rawReference) else {
            return nil
        }

        return "\(prefix)File: [\(parsed.label)](\(escapeMarkdownLinkDestination(parsed.destination)))"
    }

    private static func linkifyGenericPathTokens(in line: String) -> String {
        guard let regex = TurnMessageRegexCache.genericPath else {
            return line
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: line, range: fullRange)
        guard !matches.isEmpty else {
            return line
        }

        let linkRanges = markdownLinkRanges(in: line)
        let inlineCodeRanges = inlineCodeRanges(in: line)
        let mutableLine = NSMutableString(string: line)
        for match in matches.reversed() {
            let matchRange = match.range
            guard !rangeOverlapsMarkdownLink(matchRange, linkRanges: linkRanges) else {
                continue
            }
            guard !rangeOverlapsMarkdownLink(matchRange, linkRanges: inlineCodeRanges) else {
                continue
            }
            guard isEligiblePathTokenRange(matchRange, in: nsLine) else {
                continue
            }

            let token = nsLine.substring(with: matchRange)
            guard let parsed = parseFileReference(token) else {
                continue
            }

            let replacement = "[\(parsed.label)](\(escapeMarkdownLinkDestination(parsed.destination)))"
            mutableLine.replaceCharacters(in: matchRange, with: replacement)
        }

        return String(mutableLine)
    }

    // Converts inline-code file refs (`/path/File.swift:42`) into compact markdown links.
    private static func linkifyInlineCodeFileReferences(in line: String) -> String {
        guard let regex = TurnMessageRegexCache.inlineCodeContent else {
            return line
        }

        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: line, range: fullRange)
        guard !matches.isEmpty else {
            return line
        }

        let linkRanges = markdownLinkRanges(in: line)
        let mutableLine = NSMutableString(string: line)
        for match in matches.reversed() {
            let fullMatchRange = match.range
            guard !rangeOverlapsMarkdownLink(fullMatchRange, linkRanges: linkRanges) else {
                continue
            }
            guard match.numberOfRanges > 1 else {
                continue
            }

            let tokenRange = match.range(at: 1)
            guard tokenRange.location != NSNotFound, tokenRange.length > 0 else {
                continue
            }

            let token = nsLine.substring(with: tokenRange)
            guard let parsed = parseFileReference(token) else {
                continue
            }

            let replacement = "[\(parsed.label)](\(escapeMarkdownLinkDestination(parsed.destination)))"
            mutableLine.replaceCharacters(in: fullMatchRange, with: replacement)
        }

        return String(mutableLine)
    }

    private static func markdownLinkRanges(in line: String) -> [NSRange] {
        TurnMessageRegexCache.markdownLinkRanges(in: line)
    }

    private static func inlineCodeRanges(in line: String) -> [NSRange] {
        TurnMessageRegexCache.inlineCodeRanges(in: line)
    }

    private static func isEligiblePathTokenRange(_ range: NSRange, in line: NSString) -> Bool {
        guard range.location != NSNotFound, range.length > 0 else {
            return false
        }

        let token = line.substring(with: range)
        if token.hasPrefix("//") {
            return false
        }

        let contextStart = max(0, range.location - 3)
        let contextLength = range.location - contextStart
        let leadingContext = contextLength > 0
            ? line.substring(with: NSRange(location: contextStart, length: contextLength))
            : ""
        if leadingContext.hasSuffix("://") {
            return false
        }

        let previousChar: String = range.location > 0
            ? line.substring(with: NSRange(location: range.location - 1, length: 1))
            : ""
        if token.hasPrefix("/"), isLikelyDomainCharacter(previousChar) {
            return false
        }

        return true
    }

    private static func rangeOverlapsMarkdownLink(_ range: NSRange, linkRanges: [NSRange]) -> Bool {
        TurnMessageRegexCache.rangeOverlaps(range, protectedRanges: linkRanges)
    }

    private static func escapeMarkdownLinkDestination(_ destination: String) -> String {
        destination
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    private static func parseFileReference(_ rawReference: String) -> (label: String, destination: String)? {
        var candidate = rawReference
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))

        while let last = candidate.last, ",.;)]}".contains(last) {
            candidate.removeLast()
        }

        if candidate.hasPrefix("(") {
            candidate.removeFirst()
        }

        guard candidate.hasPrefix("/") || candidate.contains("/") else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: (candidate as NSString).length)

        var path = candidate
        var lineNumber: String?

        if let lineRegex = TurnMessageRegexCache.filenameWithLine,
           let match = lineRegex.firstMatch(in: candidate, range: fullRange),
           match.numberOfRanges >= 3 {
            let nsCandidate = candidate as NSString
            path = nsCandidate.substring(with: match.range(at: 1))
            lineNumber = nsCandidate.substring(with: match.range(at: 2))
        }

        let basename = (path as NSString).lastPathComponent
        guard !basename.isEmpty else {
            return nil
        }
        guard basename.contains(".") || lineNumber != nil else {
            return nil
        }

        let label: String
        let destination: String
        if let lineNumber {
            label = "\(basename) (line \(lineNumber))"
            destination = "\(path):\(lineNumber)"
        } else {
            label = basename
            destination = path
        }

        return (label, destination)
    }

    private static func replaceMatches(
        in text: String,
        regex: NSRegularExpression?,
        template: String
    ) -> String {
        TurnMessageRegexCache.replaceMatches(in: text, regex: regex, template: template)
    }

    private static func isLikelyDomainCharacter(_ value: String) -> Bool {
        guard value.count == 1, let scalar = value.unicodeScalars.first else {
            return false
        }
        if CharacterSet.alphanumerics.contains(scalar) {
            return true
        }
        return scalar == UnicodeScalar(".")
    }
}
