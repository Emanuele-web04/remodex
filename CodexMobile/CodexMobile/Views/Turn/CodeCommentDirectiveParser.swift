// FILE: CodeCommentDirectiveParser.swift
// Purpose: Parses ::code-comment directives from assistant prose into structured findings.
// Layer: Parser
// Exports: CodeCommentDirectiveFinding, CodeCommentDirectiveContent, CodeCommentDirectiveParser
// Depends on: Foundation

import Foundation

struct CodeCommentDirectiveFinding: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let file: String
    let startLine: Int?
    let endLine: Int?
    let priority: Int?
    let confidence: Double?
}

struct CodeCommentDirectiveContent: Equatable {
    let findings: [CodeCommentDirectiveFinding]
    let fallbackText: String

    var hasFindings: Bool { !findings.isEmpty }
}

enum CodeCommentDirectiveParser {
    private static let directiveRegex = try? NSRegularExpression(
        pattern: #"::code-comment\{((?:[^"\\}]|\\.|"([^"\\]|\\.)*")*)\}"#
    )
    private static let quotedAttributeRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9_-]*)="((?:[^"\\]|\\.)*)""#
    )
    private static let bareAttributeRegex = try? NSRegularExpression(
        pattern: #"([A-Za-z][A-Za-z0-9_-]*)=([^\s}]+)"#
    )
    private static let titlePriorityRegex = try? NSRegularExpression(pattern: #"^\s*\[(P\d+)\]\s*"#, options: [.caseInsensitive])

    // Extracts review findings directives from assistant prose and leaves the remaining text renderable.
    nonisolated static func parse(from rawText: String) -> CodeCommentDirectiveContent {
        if let jsonContent = parseJSONFindingContent(from: rawText) {
            return jsonContent
        }

        guard let directiveRegex else {
            return CodeCommentDirectiveContent(findings: [], fallbackText: rawText)
        }

        let nsText = rawText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = directiveRegex.matches(in: rawText, range: fullRange)
        guard !matches.isEmpty else {
            return CodeCommentDirectiveContent(findings: [], fallbackText: rawText)
        }

        var findings: [CodeCommentDirectiveFinding] = []
        let remainingText = NSMutableString(string: rawText)

        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let payload = nsText.substring(with: match.range(at: 1))
            if let finding = parseFinding(from: payload) {
                findings.insert(finding, at: 0)
                remainingText.replaceCharacters(in: match.range, with: "")
            }
        }

        let cleanedFallback = collapseDirectiveWhitespace(in: String(remainingText))
        return CodeCommentDirectiveContent(findings: findings, fallbackText: cleanedFallback)
    }

    private nonisolated static func parseJSONFindingContent(from rawText: String) -> CodeCommentDirectiveContent? {
        let extraction = extractJSONCandidates(from: rawText)
        guard !extraction.candidates.isEmpty else {
            return nil
        }

        var parsedFindings: [CodeCommentDirectiveFinding] = []
        var summaryCandidates: [String] = []

        for candidate in extraction.candidates {
            guard let data = candidate.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                continue
            }

            let candidateFindings = findings(from: value)
            if !candidateFindings.isEmpty {
                parsedFindings.append(contentsOf: candidateFindings)
            }
            if let summary = summaryText(from: value)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                summaryCandidates.append(summary)
            }
        }

        guard !parsedFindings.isEmpty || !summaryCandidates.isEmpty else {
            return nil
        }

        let extractedFallbackText = collapseDirectiveWhitespace(in: extraction.fallbackText)
        let fallbackText = extractedFallbackText.isEmpty
            ? (summaryCandidates.first.map(collapseDirectiveWhitespace(in:)) ?? "")
            : extractedFallbackText
        return CodeCommentDirectiveContent(findings: parsedFindings, fallbackText: fallbackText)
    }

    private nonisolated static func extractJSONCandidates(from rawText: String) -> JSONCandidateExtraction {
        var candidates: [String] = []
        var remainingText = rawText

        let fencedExtractions = extractFencedJSONCandidates(from: remainingText)
        if !fencedExtractions.candidates.isEmpty {
            candidates.append(contentsOf: fencedExtractions.candidates)
            remainingText = fencedExtractions.fallbackText
        }

        let inlineExtractions = extractInlineJSONCandidates(from: remainingText)
        if !inlineExtractions.candidates.isEmpty {
            candidates.append(contentsOf: inlineExtractions.candidates)
            remainingText = inlineExtractions.fallbackText
        }

        let trimmedRemainingText = remainingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidates.isEmpty,
           (trimmedRemainingText.hasPrefix("{") || trimmedRemainingText.hasPrefix("[")) {
            candidates.append(trimmedRemainingText)
            remainingText = ""
        }

        return JSONCandidateExtraction(candidates: candidates, fallbackText: remainingText)
    }

    private nonisolated static func extractFencedJSONCandidates(from rawText: String) -> JSONCandidateExtraction {
        let nsText = rawText as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let fenceRegex = try? NSRegularExpression(
            pattern: #"```(?:json|javascript)?\s*\n([\s\S]*?)\n```"#,
            options: [.caseInsensitive]
        )
        guard let fenceRegex else {
            return JSONCandidateExtraction(candidates: [], fallbackText: rawText)
        }

        var candidates: [String] = []
        let remainingText = NSMutableString(string: rawText)

        for match in fenceRegex.matches(in: rawText, range: fullRange).reversed() where match.numberOfRanges >= 2 {
            let bodyRange = match.range(at: 1)
            guard bodyRange.location != NSNotFound else {
                continue
            }

            let candidate = nsText.substring(with: bodyRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.hasPrefix("{") || candidate.hasPrefix("[") else {
                continue
            }

            candidates.insert(candidate, at: 0)
            remainingText.replaceCharacters(in: match.range, with: "")
        }

        return JSONCandidateExtraction(candidates: candidates, fallbackText: String(remainingText))
    }

    private nonisolated static func extractInlineJSONCandidates(from rawText: String) -> JSONCandidateExtraction {
        var candidates: [String] = []
        var rangesToRemove: [Range<String.Index>] = []
        var index = rawText.startIndex

        while index < rawText.endIndex {
            let character = rawText[index]
            guard (character == "{" || character == "["),
                  isLikelyJSONBoundary(in: rawText, at: index),
                  let candidateRange = balancedJSONRange(in: rawText, startingAt: index) else {
                index = rawText.index(after: index)
                continue
            }

            let candidate = String(rawText[candidateRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = candidate.data(using: .utf8),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data),
               !findings(from: value).isEmpty {
                candidates.append(candidate)
                rangesToRemove.append(candidateRange)
                index = candidateRange.upperBound
            } else {
                index = rawText.index(after: index)
            }
        }

        let fallbackText = removingRanges(rangesToRemove, from: rawText)
        return JSONCandidateExtraction(candidates: candidates, fallbackText: fallbackText)
    }

    private nonisolated static func isLikelyJSONBoundary(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else {
            return true
        }

        let previousIndex = text.index(before: index)
        let previousCharacter = text[previousIndex]
        return previousCharacter.isWhitespace || previousCharacter.isNewline
    }

    private nonisolated static func balancedJSONRange(
        in text: String,
        startingAt startIndex: String.Index
    ) -> Range<String.Index>? {
        let openingCharacter = text[startIndex]
        let closingCharacter: Character = (openingCharacter == "{") ? "}" : "]"
        var depth = 0
        var isInsideString = false
        var isEscaping = false
        var index = startIndex

        while index < text.endIndex {
            let character = text[index]

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else {
                if character == "\"" {
                    isInsideString = true
                } else if character == openingCharacter {
                    depth += 1
                } else if character == closingCharacter {
                    depth -= 1
                    if depth == 0 {
                        return startIndex..<text.index(after: index)
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    private nonisolated static func removingRanges(
        _ ranges: [Range<String.Index>],
        from text: String
    ) -> String {
        guard !ranges.isEmpty else {
            return text
        }

        var output = text
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            output.removeSubrange(range)
        }
        return output
    }

    private nonisolated static func findings(from value: JSONValue) -> [CodeCommentDirectiveFinding] {
        switch value {
        case .array(let items):
            return items.compactMap(parseFinding(from:))

        case .object(let object):
            if let findingItems = firstArrayValue(
                in: object,
                keys: ["findings", "issues", "reviewFindings", "review_findings", "comments"]
            ) {
                return findingItems.compactMap(parseFinding(from:))
            }

            if let singleFinding = parseFinding(from: value) {
                return [singleFinding]
            }

            return []

        default:
            return []
        }
    }

    private nonisolated static func summaryText(from value: JSONValue) -> String? {
        guard case .object(let object) = value else {
            return nil
        }

        return firstStringValue(
            in: object,
            keys: ["summary", "message", "text", "reviewSummary", "review_summary", "overall_explanation", "overallExplanation"]
        )
    }

    private nonisolated static func parseFinding(from payload: String) -> CodeCommentDirectiveFinding? {
        let attributes = parseAttributes(from: payload)
        guard let rawTitle = attributes["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty,
              let body = attributes["body"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty,
              let file = attributes["file"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !file.isEmpty else {
            return nil
        }

        let inferredPriority = inferPriority(from: rawTitle)
        let normalizedTitle = strippingPriorityPrefix(from: rawTitle)
        let explicitPriority = attributes["priority"].flatMap(Int.init)
        let startLine = attributes["start"].flatMap(Int.init)
        let endLine = attributes["end"].flatMap(Int.init)
        let confidence = attributes["confidence"].flatMap(Double.init)

        return CodeCommentDirectiveFinding(
            id: "\(file)|\(startLine ?? -1)|\(endLine ?? -1)|\(normalizedTitle)",
            title: normalizedTitle.isEmpty ? rawTitle : normalizedTitle,
            body: body,
            file: file,
            startLine: startLine,
            endLine: endLine,
            priority: explicitPriority ?? inferredPriority,
            confidence: confidence
        )
    }

    private nonisolated static func parseFinding(from value: JSONValue) -> CodeCommentDirectiveFinding? {
        guard let object = value.objectValue else {
            return nil
        }

        let codeLocation = firstObjectValue(in: object, keys: ["code_location", "codeLocation", "location"])
        let lineRange = firstObjectValue(in: codeLocation, keys: ["line_range", "lineRange"])

        guard let rawTitle = firstStringValue(
            in: object,
            keys: ["title", "headline", "summary", "name"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty,
              let body = firstStringValue(
                in: object,
                keys: ["body", "message", "description", "content"]
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty,
              let file = firstStringValue(
                in: object,
                keys: ["file", "path", "filePath", "file_path", "filename"]
              )?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? firstStringValue(
                    in: codeLocation,
                    keys: ["file", "path", "filePath", "file_path", "filename", "absolute_file_path", "absoluteFilePath"]
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !file.isEmpty else {
            return nil
        }

        let inferredPriority = inferPriority(from: rawTitle)
        let normalizedTitle = strippingPriorityPrefix(from: rawTitle)
        let explicitPriority = firstIntValue(in: object, keys: ["priority", "severity"])
            ?? parsePriority(from: firstStringValue(in: object, keys: ["severity"]))
        let startLine = firstIntValue(in: object, keys: ["start", "startLine", "start_line", "line", "lineStart"])
            ?? firstIntValue(in: codeLocation, keys: ["start", "startLine", "start_line", "line", "lineStart"])
            ?? firstIntValue(in: lineRange, keys: ["start", "startLine", "start_line", "line", "lineStart"])
        let endLine = firstIntValue(in: object, keys: ["end", "endLine", "end_line", "lineEnd"])
            ?? firstIntValue(in: codeLocation, keys: ["end", "endLine", "end_line", "lineEnd"])
            ?? firstIntValue(in: lineRange, keys: ["end", "endLine", "end_line", "lineEnd"])
            ?? startLine
        let confidence = firstDoubleValue(in: object, keys: ["confidence", "confidence_score", "score"])

        return CodeCommentDirectiveFinding(
            id: "\(file)|\(startLine ?? -1)|\(endLine ?? -1)|\(normalizedTitle)",
            title: normalizedTitle.isEmpty ? rawTitle : normalizedTitle,
            body: body,
            file: file,
            startLine: startLine,
            endLine: endLine,
            priority: explicitPriority ?? inferredPriority,
            confidence: confidence
        )
    }

    private nonisolated static func parseAttributes(from payload: String) -> [String: String] {
        var attributes: [String: String] = [:]
        guard let quotedAttributeRegex, let bareAttributeRegex else {
            return attributes
        }

        let nsPayload = payload as NSString
        let fullRange = NSRange(location: 0, length: nsPayload.length)
        let quotedMatches = quotedAttributeRegex.matches(in: payload, range: fullRange)
        var occupiedRanges: [NSRange] = []

        for match in quotedMatches where match.numberOfRanges >= 3 {
            let key = nsPayload.substring(with: match.range(at: 1))
            let value = nsPayload.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
            attributes[key] = value
            occupiedRanges.append(match.range)
        }

        let bareMatches = bareAttributeRegex.matches(in: payload, range: fullRange)
        for match in bareMatches where match.numberOfRanges >= 3 {
            guard !occupiedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else {
                continue
            }

            let key = nsPayload.substring(with: match.range(at: 1))
            let value = nsPayload.substring(with: match.range(at: 2))
            attributes[key] = value
        }

        return attributes
    }

    private nonisolated static func inferPriority(from title: String) -> Int? {
        guard let titlePriorityRegex else { return nil }

        let nsTitle = title as NSString
        let fullRange = NSRange(location: 0, length: nsTitle.length)
        guard let match = titlePriorityRegex.firstMatch(in: title, range: fullRange),
              match.numberOfRanges > 1 else {
            return nil
        }

        let token = nsTitle.substring(with: match.range(at: 1)).uppercased()
        return Int(token.dropFirst())
    }

    private nonisolated static func strippingPriorityPrefix(from title: String) -> String {
        guard let titlePriorityRegex else { return title }

        let fullRange = NSRange(location: 0, length: (title as NSString).length)
        let stripped = titlePriorityRegex.stringByReplacingMatches(in: title, range: fullRange, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func collapseDirectiveWhitespace(in text: String) -> String {
        let collapsedNewlines = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        let cleanedLines = collapsedNewlines
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return cleanedLines.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func firstArrayValue(
        in object: [String: JSONValue],
        keys: [String]
    ) -> [JSONValue]? {
        for key in keys {
            if let value = object[key]?.arrayValue {
                return value
            }
        }
        return nil
    }

    private nonisolated static func firstStringValue(
        in object: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue {
                return value
            }
        }
        return nil
    }

    private nonisolated static func firstObjectValue(
        in object: [String: JSONValue]?,
        keys: [String]
    ) -> [String: JSONValue] {
        guard let object else {
            return [:]
        }

        for key in keys {
            if let value = object[key]?.objectValue {
                return value
            }
        }
        return [:]
    }

    private nonisolated static func firstIntValue(
        in object: [String: JSONValue],
        keys: [String]
    ) -> Int? {
        for key in keys {
            if let value = object[key]?.intValue {
                return value
            }
            if let stringValue = object[key]?.stringValue, let value = Int(stringValue) {
                return value
            }
        }
        return nil
    }

    private nonisolated static func firstDoubleValue(
        in object: [String: JSONValue],
        keys: [String]
    ) -> Double? {
        for key in keys {
            if let value = object[key]?.doubleValue {
                return value
            }
            if let stringValue = object[key]?.stringValue, let value = Double(stringValue) {
                return value
            }
        }
        return nil
    }

    private nonisolated static func parsePriority(from severity: String?) -> Int? {
        guard let normalizedSeverity = severity?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalizedSeverity.isEmpty else {
            return nil
        }

        switch normalizedSeverity {
        case "critical", "blocker", "p0", "0":
            return 0
        case "high", "p1", "1":
            return 1
        case "medium", "moderate", "p2", "2":
            return 2
        case "low", "minor", "p3", "3":
            return 3
        default:
            return Int(normalizedSeverity)
        }
    }
}

private struct JSONCandidateExtraction {
    let candidates: [String]
    let fallbackText: String
}
