// FILE: StreamingMarkdownBlockSplitter.swift
// Purpose: Pure settled/active block splitting and seam-spacing classification for streaming markdown.
// Layer: Turn UI rendering support
// Exports: StreamingMarkdownBlockSplitter
// Depends on: CoreGraphics, Foundation

import CoreGraphics
import Foundation

// Pure text logic behind StreamingAssistantMarkdownTextView: where the stable "settled" prefix
// ends, where the still-streaming "active" block begins, and how wide the seam between the two
// rendered halves must be to reproduce RemodexTextKit's own inter-block spacing.
enum StreamingMarkdownBlockSplitter {
    // Splits the text into the settled prefix (all closed top-level blocks) and the active
    // trailing block. A blank line outside a code fence ends a block; an open fence keeps its
    // content in the active block so a still-typing fence never reflows the settled history.
    static func split(_ text: String) -> (settled: String, active: String) {
        guard !text.isEmpty else { return ("", "") }

        let lines = text.components(separatedBy: "\n")
        var insideFence = false
        var pendingBoundary = false
        var sawContent = false
        var lastBlockStartLine = 0

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFenceMarker = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")

            if isFenceMarker {
                if pendingBoundary { lastBlockStartLine = index; pendingBoundary = false }
                sawContent = true
                insideFence.toggle()
                continue
            }

            if insideFence {
                if pendingBoundary { lastBlockStartLine = index; pendingBoundary = false }
                sawContent = true
                continue
            }

            if trimmed.isEmpty {
                if sawContent { pendingBoundary = true }
            } else {
                if pendingBoundary { lastBlockStartLine = index; pendingBoundary = false }
                sawContent = true
            }
        }

        guard lastBlockStartLine > 0 else { return ("", text) }

        let settled = lines[0..<lastBlockStartLine].joined(separator: "\n")
        let active = lines[lastBlockStartLine...].joined(separator: "\n")
        return (settled, active)
    }

    // Seam edge facing down from the settled half: driven by the first line of the active block.
    static func topSpacingMultiplier(forBlockStarting active: String) -> CGFloat {
        guard let line = firstNonBlankLine(of: active) else { return 0 }
        return classify(line).topMultiplier
    }

    // Seam edge facing up from the active half: driven by the last settled block's kind.
    static func bottomSpacingMultiplier(forLastBlockOf settled: String) -> CGFloat {
        // The last settled block's kind is set by its first line, so reuse the splitter.
        let lastBlock = split(settled).active
        guard let line = firstNonBlankLine(of: lastBlock) else { return 0 }
        return classify(line).bottomMultiplier
    }

    private enum BlockKind {
        case paragraph, heading, code, table, thematicBreak, blockquote, list

        // Font-relative `blockSpacing` from RemodexTextKit's default styles. Single source of
        // truth for the settled<->active seam, mirroring (grep these if the library changes):
        //   DefaultParagraphStyle      .blockSpacing(.fontScaled(top: 0.8))
        //   DefaultHeadingStyle        .blockSpacing(.fontScaled(top: 1.6, bottom: 0.8))
        //   DefaultCodeBlockStyle      .blockSpacing(.fontScaled(top: 0.88, bottom: 0))
        //   DefaultTableStyle          .blockSpacing(.fontScaled(top: 1.6, bottom: 1.6))
        //   DividerThematicBreakStyle  .blockSpacing(.fontScaled(top: 1.6, bottom: 1.6))
        // Blockquote and list leave `blockSpacing` unset (resolved by surrounding styles), so
        // their values here are a paragraph-like approximation of the resolved gap.
        var topMultiplier: CGFloat {
            switch self {
            case .paragraph: return 0.8
            case .heading: return 1.6
            case .code: return 0.88
            case .table, .thematicBreak: return 1.6
            case .blockquote, .list: return 0.8
            }
        }

        var bottomMultiplier: CGFloat {
            switch self {
            case .paragraph, .code, .blockquote, .list: return 0
            case .heading: return 0.8
            case .table, .thematicBreak: return 1.6
            }
        }
    }

    private static func firstNonBlankLine(of text: String) -> String? {
        // Scan line by line and stop at the first non-blank one, so a long active block
        // never materializes its whole line array just to read its leading line.
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let trimmed = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return nil
    }

    private static func classify(_ trimmedLine: String) -> BlockKind {
        if trimmedLine.hasPrefix("#") { return .heading }
        if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") { return .code }
        if trimmedLine.hasPrefix(">") { return .blockquote }
        if trimmedLine.hasPrefix("|") { return .table }
        if isThematicBreak(trimmedLine) { return .thematicBreak }
        if isListMarker(trimmedLine) { return .list }
        return .paragraph
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    private static func isListMarker(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        // Ordered list: digits followed by "." or ")" and a space.
        var sawDigit = false
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            sawDigit = true
            index = line.index(after: index)
        }
        guard sawDigit, index < line.endIndex else { return false }
        let marker = line[index]
        guard marker == "." || marker == ")" else { return false }
        let afterMarker = line.index(after: index)
        return afterMarker < line.endIndex && line[afterMarker] == " "
    }
}
