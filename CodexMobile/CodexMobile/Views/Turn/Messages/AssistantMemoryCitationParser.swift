// Removes Codex's memory attribution envelope from presentation text only.
// Run before clipping or splitting streaming Markdown so metadata cannot become prose.
import Foundation

nonisolated enum AssistantMemoryCitationParser {
    private static let openingTag = "<oai-mem-citation>"
    private static let closingTag = "</oai-mem-citation>"

    static func visibleText(in text: String, isStreaming: Bool) -> String {
        guard text.contains("<") else { return text }
        // Most answers have no metadata. Avoid splitting their entire Markdown body.
        if !text.contains(openingTag) {
            guard isStreaming else { return text }
            let lastLineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let lastLine = text[lastLineStart...].trimmingCharacters(in: .whitespaces)
            guard !lastLine.isEmpty, openingTag.hasPrefix(lastLine) else {
                return text
            }
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var visibleLines: [String] = []
        var insideCitation = false
        var removedMetadata = false
        var fence: (marker: Character, count: Int)?
        var inlineBackticks: Int?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if insideCitation {
                if let close = line.range(of: closingTag) {
                    insideCitation = false
                    let suffix = String(line[close.upperBound...])
                    if !suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                        visibleLines.append(suffix)
                    }
                }
                continue
            }

            if let currentFence = fence {
                let run = trimmed.prefix { $0 == currentFence.marker }
                if run.count >= currentFence.count,
                   trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
                visibleLines.append(String(line))
                continue
            }

            // Indented code, fenced code, and inline code examples stay literal.
            let indentation = line.prefix { $0 == " " || $0 == "\t" }
            let isIndentedCode = indentation.count >= 4 || indentation.contains("\t")
            if inlineBackticks == nil, !isIndentedCode {
                if let marker = trimmed.first, marker == "`" || marker == "~" {
                    let count = trimmed.prefix { $0 == marker }.count
                    if count >= 3 {
                        fence = (marker, count)
                        visibleLines.append(String(line))
                        continue
                    }
                }

                if trimmed.hasPrefix(openingTag) {
                    removedMetadata = true
                    if let close = trimmed.range(of: closingTag) {
                        let suffix = String(trimmed[close.upperBound...])
                        if !suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                            visibleLines.append(suffix)
                        }
                    } else {
                        // Also hide incomplete envelopes saved after an interrupted turn.
                        insideCitation = true
                    }
                    continue
                }

                // Withhold an opening tag arriving across several streaming deltas.
                if isStreaming, index == lines.count - 1,
                   !trimmed.isEmpty, openingTag.hasPrefix(trimmed) {
                    removedMetadata = true
                    continue
                }
            }

            visibleLines.append(String(line))
            if !isIndentedCode {
                updateInlineBackticks(in: line, openCount: &inlineBackticks)
            }
        }

        guard removedMetadata else { return text }
        var result = visibleLines.joined(separator: "\n")
        while result.last?.isWhitespace == true { result.removeLast() }
        return result
    }

    private static func updateInlineBackticks(in line: Substring, openCount: inout Int?) {
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\\", openCount == nil {
                index = line.index(after: index)
                if index < line.endIndex { index = line.index(after: index) }
            } else if line[index] == "`" {
                let start = index
                while index < line.endIndex, line[index] == "`" {
                    index = line.index(after: index)
                }
                let count = line.distance(from: start, to: index)
                if openCount == nil { openCount = count }
                else if openCount == count { openCount = nil }
            } else {
                index = line.index(after: index)
            }
        }
    }
}
