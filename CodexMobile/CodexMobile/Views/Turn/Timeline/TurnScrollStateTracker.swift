// FILE: TurnScrollStateTracker.swift
// Purpose: Contains pure rules for bottom-anchor scroll state transitions.
// Layer: View Helper
// Exports: TurnAutoScrollMode, TurnScrollStateTracker
// Depends on: CoreGraphics

import CoreGraphics
import Foundation

enum TurnAutoScrollMode {
    case followBottom
    case anchorAssistantResponse
    case manual
}

struct TurnScrollStateTracker {
    static let bottomThreshold: CGFloat = 12
    static let userScrollCooldown: TimeInterval = 0.25
    static let contentHeightCorrectionThreshold: CGFloat = 1

    static func shouldShowScrollToLatestButton(messageCount: Int, isScrolledToBottom: Bool) -> Bool {
        messageCount > 0 && !isScrolledToBottom
    }

    // User drag owns the viewport immediately, including while a one-shot
    // assistant anchor is waiting for its first renderable row.
    static func modeAfterUserDragBegan(currentMode: TurnAutoScrollMode) -> TurnAutoScrollMode {
        return .manual
    }

    static func modeAfterSendBegan(
        shouldAnchorToAssistantResponse: Bool
    ) -> TurnAutoScrollMode {
        shouldAnchorToAssistantResponse ? .anchorAssistantResponse : .followBottom
    }

    // Restores follow-bottom only when the gesture finishes at the bottom;
    // otherwise the timeline stays manual and leaves control with the user.
    static func modeAfterUserDragEnded(
        currentMode: TurnAutoScrollMode,
        isScrolledToBottom: Bool
    ) -> TurnAutoScrollMode {
        guard currentMode != .anchorAssistantResponse else {
            return currentMode
        }
        return isScrolledToBottom ? .followBottom : .manual
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

    // Follow-bottom represents app-owned scroll intent; user-owned scrolls switch
    // to manual before geometry can pull the viewport back to the tail.
    static func shouldPinDuringGeometryChange(
        currentMode: TurnAutoScrollMode,
        isAutomaticScrollingPaused: Bool
    ) -> Bool {
        guard !isAutomaticScrollingPaused else {
            return false
        }

        switch currentMode {
        case .followBottom:
            return true
        case .anchorAssistantResponse:
            return false
        case .manual:
            return false
        }
    }

    // Suppresses only the transient false-bottom frame caused by a queued app scroll.
    static func shouldIgnoreTransientNotBottomGeometry(
        currentMode: TurnAutoScrollMode,
        hasPendingFollowBottomScroll: Bool,
        isAutomaticScrollingPaused: Bool
    ) -> Bool {
        currentMode == .followBottom
            && hasPendingFollowBottomScroll
            && !isAutomaticScrollingPaused
    }

    // Once a real not-bottom geometry update is accepted, follow intent becomes user-owned.
    static func modeAfterAcceptedNotBottomGeometry(currentMode: TurnAutoScrollMode) -> TurnAutoScrollMode {
        currentMode == .followBottom ? .manual : currentMode
    }

    // Opening any live turn should show the newest streamed content immediately.
    // A non-empty active-turn id counts as live evidence while the explicit
    // running flag is still hydrating after a thread switch.
    static func shouldOpenAtLiveTail(
        isThreadRunning: Bool,
        activeTurnID: String?,
        isSendInFlight: Bool,
        hasStreamingTail: Bool
    ) -> Bool {
        let normalizedActiveTurnID = activeTurnID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasActiveTurn = normalizedActiveTurnID?.isEmpty == false
        return isThreadRunning || hasActiveTurn || isSendInFlight || hasStreamingTail
    }

    static func shouldReleaseInitialHistoryAnchorForLiveTail(
        shouldOpenAtLiveTail: Bool,
        hasInitialResponseStartAnchor: Bool,
        shouldAnchorToAssistantResponse: Bool,
        isAutomaticScrollingPaused: Bool
    ) -> Bool {
        shouldOpenAtLiveTail
            && hasInitialResponseStartAnchor
            && !shouldAnchorToAssistantResponse
            && !isAutomaticScrollingPaused
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
