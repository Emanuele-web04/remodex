// FILE: StreamingInlineMarkupAutoCloser.swift
// Purpose: Virtually closes unterminated inline markdown spans so streaming text styles immediately.
// Layer: Turn UI rendering support
// Exports: StreamingInlineMarkupAutoCloser
// Depends on: Foundation

import Foundation

// While the assistant is still typing, an open inline span (`code`, **bold**) would render its
// raw marker characters and then collapse into styling once the closing marker streams in - a
// visible back-and-forth. This helper rewrites the still-streaming block for rendering only:
// spans that already have content get a virtual closer (so they style from the first character
// and the real closer later parses to an identical result), and a bare trailing opener with no
// content yet is held back instead of flashing raw. Fenced code blocks are left untouched.
enum StreamingInlineMarkupAutoCloser {
    static func autoClosed(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var insideFence = false
        var insideCode = false
        var codeOpenerIndex = text.startIndex
        var codeHasContent = false
        var insideBold = false
        var boldOpenerIndex = text.startIndex
        var boldHasContent = false

        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
            } else if !insideFence {
                scanInlineMarkers(
                    in: line,
                    isLastLine: lineEnd == text.endIndex,
                    insideCode: &insideCode,
                    codeOpenerIndex: &codeOpenerIndex,
                    codeHasContent: &codeHasContent,
                    insideBold: &insideBold,
                    boldOpenerIndex: &boldOpenerIndex,
                    boldHasContent: &boldHasContent
                )
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }

        // Inside an open fence every marker is literal; the parser already renders an
        // unterminated fence as a code block, so there is nothing to stabilize.
        guard !insideFence, insideCode || insideBold else {
            return text
        }

        // A bare bold opener at the tail (no content yet) would auto-close to "****", which
        // CommonMark renders as literal asterisks. Hold the opener back for a frame instead.
        // A bare opener is always the last marker, so nothing after it needs closing.
        if insideBold, !boldHasContent {
            return String(text[..<boldOpenerIndex])
        }
        if insideCode, !codeHasContent {
            var held = String(text[..<codeOpenerIndex])
            if insideBold {
                held = trimmingTrailingWhitespace(held) + "**"
            }
            return held
        }

        var closed = text
        if insideCode {
            closed += "`"
        }
        if insideBold {
            // "**bold **" would parse as literal asterisks (closer after whitespace), so the
            // rendering copy drops the invisible trailing whitespace before closing.
            if !insideCode {
                closed = trimmingTrailingWhitespace(closed)
            }
            closed += "**"
        }
        return closed
    }

    // Tracks inline code / bold delimiter state across one line. Code-span state deliberately
    // survives line breaks (CommonMark joins them inside a paragraph), while fence detection
    // stays line-based to match StreamingMarkdownBlockSplitter.
    private static func scanInlineMarkers(
        in line: Substring,
        isLastLine: Bool,
        insideCode: inout Bool,
        codeOpenerIndex: inout String.Index,
        codeHasContent: inout Bool,
        insideBold: inout Bool,
        boldOpenerIndex: inout String.Index,
        boldHasContent: inout Bool
    ) {
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]

            if character == "\\" {
                // Escaped marker: skip it, but it still counts as span content.
                index = line.index(after: index)
                if index < line.endIndex {
                    index = line.index(after: index)
                }
                if insideCode { codeHasContent = true }
                if insideBold { boldHasContent = true }
                continue
            }

            if character == "`" {
                if insideCode {
                    insideCode = false
                    // The completed code span itself is content for an enclosing bold span.
                    if insideBold { boldHasContent = true }
                } else {
                    insideCode = true
                    codeOpenerIndex = index
                    codeHasContent = false
                }
                index = line.index(after: index)
                continue
            }

            if character == "*", !insideCode {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "*" {
                    let afterMarker = line.index(after: next)
                    if insideBold {
                        insideBold = false
                        boldHasContent = false
                    } else if afterMarker < line.endIndex, !line[afterMarker].isWhitespace {
                        // CommonMark left-flanking rule: an opener must be followed by
                        // non-whitespace. "2 ** 3" stays a literal operator.
                        insideBold = true
                        boldOpenerIndex = index
                        boldHasContent = false
                    } else if afterMarker == line.endIndex, isLastLine {
                        // "**" at the very end of the streaming text is ambiguous: the
                        // next delta decides. Track it so the bare opener is held back
                        // instead of flashing raw asterisks.
                        insideBold = true
                        boldOpenerIndex = index
                        boldHasContent = false
                    }
                    // "**" followed by whitespace (or at a non-final line end) is
                    // literal per the flanking rule: fall through without toggling.
                    index = afterMarker
                    continue
                }
            }

            if !character.isWhitespace {
                if insideCode { codeHasContent = true }
                if insideBold { boldHasContent = true }
            }
            index = line.index(after: index)
        }
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace else { break }
            end = previous
        }
        return end == text.endIndex ? text : String(text[..<end])
    }
}
