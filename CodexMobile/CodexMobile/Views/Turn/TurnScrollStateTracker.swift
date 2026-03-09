// FILE: TurnScrollStateTracker.swift
// Purpose: Contains pure rules for bottom-anchor scroll state transitions.
// Layer: View Helper
// Exports: TurnScrollStateTracker
// Depends on: CoreGraphics

import CoreGraphics

struct TurnScrollStateTracker {
    static let bottomThreshold: CGFloat = 12

    // Returns true when the bottom anchor is within viewport tolerance.
    static func isScrolledToBottom(
        bottomAnchorMaxY: CGFloat,
        viewportHeight: CGFloat,
        hasMessages: Bool,
        threshold: CGFloat = bottomThreshold
    ) -> Bool {
        guard hasMessages else {
            return true
        }
        return bottomAnchorMaxY <= viewportHeight + threshold
    }

    static func shouldShowScrollToLatestButton(messageCount: Int, isScrolledToBottom: Bool) -> Bool {
        messageCount > 0 && !isScrolledToBottom
    }
}
