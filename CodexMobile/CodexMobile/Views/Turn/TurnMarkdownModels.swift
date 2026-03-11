// FILE: TurnMarkdownModels.swift
// Purpose: Markdown segment types, render profile, and segment parser.
// Layer: Model
// Exports: MarkdownSegment, MarkdownRenderProfile, SkillReferenceReplacementStyle, parseMarkdownSegments
// Depends on: Foundation

import Foundation

enum MarkdownSegment {
    case prose(String)
    case codeBlock(language: String?, code: String)
}

enum MarkdownRenderProfile {
    case assistantProse
    case fileChangeSystem
}

extension MarkdownRenderProfile {
    var cacheKey: String {
        switch self {
        case .assistantProse:
            return "assistantProse"
        case .fileChangeSystem:
            return "fileChangeSystem"
        }
    }
}

enum SkillReferenceReplacementStyle {
    case mentionToken
    case displayName
}

// Splits assistant/system text into prose and fenced code blocks for rich rendering.
func parseMarkdownSegments(_ text: String) -> [MarkdownSegment] {
    guard let regex = MarkdownSegmentRegexCache.codeFence else { return [.prose(text)] }

    var segments: [MarkdownSegment] = []
    let nsText = text as NSString
    var lastEnd = 0

    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    for match in matches {
        let matchStart = match.range.location
        if matchStart > lastEnd {
            let prose = nsText.substring(with: NSRange(location: lastEnd, length: matchStart - lastEnd))
                .trimmingCharacters(in: .newlines)
            if !prose.isEmpty {
                segments.append(.prose(prose))
            }
        }

        let lang = nsText.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let code = nsText.substring(with: match.range(at: 2))
        segments.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: code))
        lastEnd = match.range.location + match.range.length
    }

    if lastEnd < nsText.length {
        let trailing = nsText.substring(from: lastEnd).trimmingCharacters(in: .newlines)
        if !trailing.isEmpty {
            segments.append(.prose(trailing))
        }
    }

    if segments.isEmpty {
        segments.append(.prose(text))
    }

    return segments
}

enum MarkdownSegmentRegexCache {
    // Accepts full fence info strings (for example: c++, objective-c, shell-session),
    // but only when the fence starts its own line. This avoids accidental matches from
    // prose like: `blocco ```bash` that would otherwise swallow the rest of the message.
    static let codeFence = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}```([^\n`]*)\n([\s\S]*?)(?:\n[ \t]{0,3}```|$)"#
    )
}
