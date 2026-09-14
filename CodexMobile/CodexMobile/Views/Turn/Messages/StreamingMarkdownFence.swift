// FILE: StreamingMarkdownFence.swift
// Purpose: Tracks matching fenced-code delimiters in streaming Markdown.
// Layer: Turn UI rendering support
// Depends on: Foundation

import Foundation

struct StreamingMarkdownFence {
    private var marker: Character?
    private var length = 0

    var isOpen: Bool { marker != nil }

    // Returns true for a fence delimiter or a line inside an open fence.
    mutating func consume(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let wasOpen = isOpen
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return wasOpen
        }
        let run = trimmed.prefix(while: { $0 == first })
        guard run.count >= 3 else { return wasOpen }
        let remainder = trimmed.dropFirst(run.count)

        if let marker {
            if first == marker, run.count >= length,
               remainder.allSatisfy(\.isWhitespace) {
                self.marker = nil
                length = 0
            }
        } else {
            // Backtick fence info strings cannot contain another backtick.
            guard first != "`" || !remainder.contains("`") else { return false }
            marker = first
            length = run.count
        }
        return true
    }
}
