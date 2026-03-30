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
    static let contentHeightCorrectionThreshold: CGFloat = 1

    static func shouldShowScrollToLatestButton(messageCount: Int, isScrolledToBottom: Bool) -> Bool {
        messageCount > 0 && !isScrolledToBottom
    }

    // Re-anchor whenever pinned content meaningfully grows or shrinks so
    // completion-time row removal cannot leave blank space below the timeline.
    static func shouldCorrectBottomAfterContentHeightChange(
        previousHeight: CGFloat,
        newHeight: CGFloat,
        isPinnedToBottom: Bool
    ) -> Bool {
        guard isPinnedToBottom else {
            return false
        }

        guard previousHeight > 0, newHeight > 0 else {
            return false
        }

        return abs(newHeight - previousHeight) > contentHeightCorrectionThreshold
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
