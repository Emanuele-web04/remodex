// FILE: TurnScrollStateTracker.swift
// Purpose: Contains pure rules for bottom-anchor scroll state transitions.
// Layer: View Helper
// Exports: TurnScrollOwnership, TurnScrollEvent, TurnScrollStateTracker
// Depends on: CoreGraphics

import CoreGraphics
import Foundation

enum TurnScrollOwnership: Equatable {
    enum AppTarget: Equatable {
        case bottom
        case assistantResponse
    }

    case app(AppTarget)
    case user

    static var followBottom: Self { .app(.bottom) }
    static var anchorAssistantResponse: Self { .app(.assistantResponse) }
    static var manual: Self { .user }

    var allowsStreamingAnimations: Bool {
        self != .user
    }

    var exposesScrollToLatest: Bool {
        self == .user
    }
}

enum TurnScrollEvent: Equatable {
    case conversationOpened(shouldAnchorAssistantResponse: Bool)
    case loadEarlier
    case jumpToLatest
    case sendBegan(shouldAnchorAssistantResponse: Bool)
    case assistantAnchorRequested
    case assistantAnchorResolved
    case assistantAnchorCleared(isAtBottom: Bool)
    case userInteractionBegan
    case userInteractionEnded(isAtBottom: Bool)
}

struct TurnScrollStateTracker {
    static let bottomThreshold: CGFloat = 12

    static func shouldShowScrollToLatestButton(
        messageCount: Int,
        isScrolledToBottom: Bool,
        ownership: TurnScrollOwnership
    ) -> Bool {
        messageCount > 0 && ownership.exposesScrollToLatest && !isScrolledToBottom
    }

    // This is the only writer for scroll ownership. Geometry is deliberately
    // absent: layout can report physical drift, but only explicit app intent or
    // real user interaction may transfer viewport ownership.
    static func ownership(
        after event: TurnScrollEvent,
        current: TurnScrollOwnership
    ) -> TurnScrollOwnership {
        switch event {
        case .conversationOpened(let shouldAnchor), .sendBegan(let shouldAnchor):
            return shouldAnchor ? .anchorAssistantResponse : .followBottom
        case .loadEarlier, .userInteractionBegan:
            return .user
        case .jumpToLatest:
            return .followBottom
        case .assistantAnchorRequested:
            return .anchorAssistantResponse
        case .assistantAnchorResolved:
            guard current == .anchorAssistantResponse else { return current }
            return .followBottom
        case .assistantAnchorCleared(let isAtBottom):
            guard current == .anchorAssistantResponse else { return current }
            return isAtBottom ? .followBottom : .user
        case .userInteractionEnded(let isAtBottom):
            guard current == .user else { return current }
            return isAtBottom ? .followBottom : .user
        }
    }

    // Geometry commits are intentionally delayed by one frame. Gesture-end must use the newest
    // observed value so a stale committed `true` cannot re-enable follow-bottom during release.
    static func effectiveBottomState(
        committedIsAtBottom: Bool,
        latestObservedIsAtBottom: Bool?
    ) -> Bool {
        latestObservedIsAtBottom ?? committedIsAtBottom
    }

    // Reconcile geometry against the view's committed state, not only against the previous
    // geometry sample. This repairs optimistic programmatic-scroll state if the scroll lands short.
    static func shouldReconcileBottomState(
        observedIsAtBottom: Bool,
        committedIsAtBottom: Bool,
        isSuppressingNotBottom: Bool
    ) -> Bool {
        observedIsAtBottom != committedIsAtBottom
            && !(isSuppressingNotBottom && !observedIsAtBottom)
    }

    // App-owned bottom intent is maintained as an invariant. The assistant target
    // is handled separately until its renderable row exists.
    static func shouldPinDuringGeometryChange(
        ownership: TurnScrollOwnership,
        isAutomaticScrollingPaused: Bool,
        isWaitingForAssistantResponse: Bool = false
    ) -> Bool {
        guard !isAutomaticScrollingPaused else {
            return false
        }
        return ownership == .followBottom
            || (ownership == .anchorAssistantResponse && isWaitingForAssistantResponse)
    }

    static func shouldCorrectObservedBottomDrift(
        observedIsAtBottom: Bool,
        ownership: TurnScrollOwnership,
        isAutomaticScrollingPaused: Bool
    ) -> Bool {
        !observedIsAtBottom
            && shouldPinDuringGeometryChange(
                ownership: ownership,
                isAutomaticScrollingPaused: isAutomaticScrollingPaused
            )
    }

    // A local send keeps the full live tail rendered even before explicit running
    // evidence has propagated back into the thread snapshot.
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

}
