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
    static func parse(from rawText: String) -> CodeCommentDirectiveContent {
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

    private static func parseFinding(from payload: String) -> CodeCommentDirectiveFinding? {
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

    private static func parseAttributes(from payload: String) -> [String: String] {
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

    private static func inferPriority(from title: String) -> Int? {
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

    private static func strippingPriorityPrefix(from title: String) -> String {
        guard let titlePriorityRegex else { return title }

        let fullRange = NSRange(location: 0, length: (title as NSString).length)
        let stripped = titlePriorityRegex.stringByReplacingMatches(in: title, range: fullRange, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseDirectiveWhitespace(in text: String) -> String {
        let collapsedNewlines = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        let cleanedLines = collapsedNewlines
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return cleanedLines.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
