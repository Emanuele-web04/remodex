// FILE: TurnScrollStateTracker.swift
// Purpose: Contains pure rules for bottom-anchor scroll state transitions.
// Layer: View Helper
// Exports: TurnScrollStateTracker
// Depends on: CoreGraphics

import CoreGraphics
import Foundation

struct TurnScrollStateTracker {
    static let bottomThreshold: CGFloat = 12
    static let userScrollCooldown: TimeInterval = 0.25

    static func shouldShowScrollToLatestButton(messageCount: Int, isScrolledToBottom: Bool) -> Bool {
        messageCount > 0 && !isScrolledToBottom
    }

    static func isAutomaticScrollingPaused(
        isUserDragging: Bool,
        cooldownUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        if isUserDragging {
            return true
        }

        guard let cooldownUntil else {
            return false
        }
        return now < cooldownUntil
    }

    static func cooldownDeadline(after date: Date = Date()) -> Date {
        date.addingTimeInterval(userScrollCooldown)
    }
}
