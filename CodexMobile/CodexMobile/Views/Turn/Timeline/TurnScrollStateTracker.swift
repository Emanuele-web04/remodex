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
    // A reopened live turn first shows its coherent response boundary, then
    // returns to normal live-follow once that one-shot placement has settled.
    case anchorTurnStartThenFollow
    case manual
}

struct TurnScrollStateTracker {
    static let bottomThreshold: CGFloat = 12
    static let userScrollCooldown: TimeInterval = 0.25
    static let contentHeightCorrectionThreshold: CGFloat = 1
    // Give a reopened live turn enough time to be read from its response
    // boundary before its next delta is allowed to reclaim the live tail.
    static let initialLiveTurnStartAnchorDwellNanoseconds: UInt64 = 1_200_000_000

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
        case .anchorAssistantResponse, .anchorTurnStartThenFollow:
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

    // A local send is explicit user intent to enter the new turn at its live tail.
    // Reopening an already-running desktop turn is different: first show its
    // opener/response boundary so the user has context before live-follow resumes.
    static func shouldOpenAtLiveTail(
        isSendInFlight: Bool
    ) -> Bool {
        isSendInFlight
    }

    // Live evidence still matters while choosing how much of a reopened thread
    // to render. It must not, by itself, decide the initial scroll position.
    static func hasLiveTurnEvidence(
        isThreadRunning: Bool,
        activeTurnID: String?,
        hasStreamingTail: Bool
    ) -> Bool {
        let normalizedActiveTurnID = activeTurnID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasActiveTurn = normalizedActiveTurnID?.isEmpty == false
        return isThreadRunning || hasActiveTurn || hasStreamingTail
    }

    static func modeForInitialResponseStartAnchor(
        hasLiveTurnEvidence: Bool
    ) -> TurnAutoScrollMode {
        hasLiveTurnEvidence ? .anchorTurnStartThenFollow : .manual
    }

    static func modeAfterInitialResponseStartAnchorDwell(
        currentMode: TurnAutoScrollMode,
        isAutomaticScrollingPaused: Bool
    ) -> TurnAutoScrollMode {
        guard currentMode == .anchorTurnStartThenFollow,
              !isAutomaticScrollingPaused else {
            return currentMode
        }
        return .followBottom
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
