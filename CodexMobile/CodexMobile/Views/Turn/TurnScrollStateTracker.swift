// FILE: TurnScrollStateTracker.swift
// Purpose: Contains pure rules for bottom-anchor scroll state transitions.
// Layer: View Helper
// Exports: TurnScrollStateTracker
// Depends on: CoreGraphics

import CoreGraphics

struct TurnScrollStateTracker {
    static let bottomThreshold: CGFloat = 12

    static func shouldShowScrollToLatestButton(messageCount: Int, isScrolledToBottom: Bool) -> Bool {
        messageCount > 0 && !isScrolledToBottom
    }
}
