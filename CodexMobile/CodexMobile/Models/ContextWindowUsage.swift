// FILE: ContextWindowUsage.swift
// Purpose: Model for thread-level token usage / context window state.
// Layer: Model
// Exports: ContextWindowUsage

import Foundation

struct ContextWindowUsage: Equatable, Sendable {
    // Fallback for new chats or runtimes that cannot report context usage yet.
    static let zero = ContextWindowUsage(tokensUsed: 0, tokenLimit: 0)

    let tokensUsed: Int
    let tokenLimit: Int

    var tokensRemaining: Int {
        max(0, tokenLimit - tokensUsed)
    }

    var fractionUsed: Double {
        guard tokenLimit > 0 else { return 0 }
        return min(1, Double(tokensUsed) / Double(tokenLimit))
    }

    var percentUsed: Int {
        Int((fractionUsed * 100).rounded())
    }

    var percentRemaining: Int {
        max(0, 100 - percentUsed)
    }

    var tokensUsedFormatted: String {
        Self.formatTokenCount(tokensUsed)
    }

    var tokenLimitFormatted: String {
        Self.formatTokenCount(tokenLimit)
    }

    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000
            return String(format: "%.1fM", value)
        } else if count >= 1_000 {
            let value = Double(count) / 1_000
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))K"
                : String(format: "%.1fK", value)
        }
        return "\(count)"
    }
}
