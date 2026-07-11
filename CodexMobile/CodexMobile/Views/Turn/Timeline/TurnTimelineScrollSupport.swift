// FILE: TurnTimelineScrollSupport.swift
// Purpose: Provides scroll geometry batching and UIKit axis clamping for the timeline.
// Layer: View Support
// Exports: ScrollBottomState, TurnTimelineRenderItemsCacheSignature, TurnTimelineRenderItemsCache,
//   TurnTimelinePendingAssistantState, VerticalScrollAxisGuard, ScrollGeometryCoalescer
// Depends on: SwiftUI, UIKit, CodexMessage, TurnTimelineRenderProjection

import SwiftUI
import UIKit

struct ScrollBottomState: Equatable {
    let isAtBottom: Bool

    static func from(_ geometry: ScrollGeometry) -> ScrollBottomState {
        let viewportHeight = geometry.visibleRect.height
        let isAtBottom: Bool
        if geometry.contentSize.height <= 0 || viewportHeight <= 0 {
            isAtBottom = true
        } else if geometry.contentSize.height <= viewportHeight {
            isAtBottom = true
        } else {
            isAtBottom = geometry.visibleRect.maxY
                >= geometry.contentSize.height - TurnScrollStateTracker.bottomThreshold
        }
        return ScrollBottomState(isAtBottom: isAtBottom)
    }
}

// Keeps scroll-only body passes from deeply hashing every hydrated message.
struct TurnTimelineRenderItemsCacheSignature: Equatable {
    let threadID: String
    let timelineChangeToken: Int
    let visibleTailCount: Int
    let activeTurnID: String?
    let isThreadRunning: Bool
    let messageCount: Int
    let firstMessageID: String?
    let lastMessageID: String?
    let completedTurnIDsHash: Int
}

// Shares projection results between the body read and lifecycle handlers so
// streaming updates do not rebuild timeline render items twice per signature.
final class TurnTimelineRenderItemsCache {
    private var cachedSignature: TurnTimelineRenderItemsCacheSignature?
    private var cachedItems: [TurnTimelineRenderItem] = []

    func items(
        for signature: TurnTimelineRenderItemsCacheSignature,
        messages: ArraySlice<CodexMessage>,
        completedTurnIDs: Set<String>,
        projector: (([CodexMessage], Set<String>) -> [TurnTimelineRenderItem])? = nil
    ) -> [TurnTimelineRenderItem] {
        if signature == cachedSignature {
            return cachedItems
        }

        let sourceMessages = Array(messages)
        let projectedItems = projector.map { $0(sourceMessages, completedTurnIDs) }
            ?? TurnTimelineRenderProjection.project(
                messages: sourceMessages,
                completedTurnIDs: completedTurnIDs
            )
        cachedSignature = signature
        cachedItems = projectedItems
        return projectedItems
    }
}

enum TurnTimelinePendingAssistantState {
    // The optimistic user row appears before the first assistant row; keep both
    // the thinking indicator and bottom anchor active during that short gap.
    static func isWaitingForAssistantResponse(
        shouldAnchorToAssistantResponse: Bool,
        messages: [CodexMessage]
    ) -> Bool {
        shouldAnchorToAssistantResponse
            && messages.last?.role == .user
    }

    static func shouldTrackScrollGeometry(
        shouldAnchorToAssistantResponse: Bool,
        autoScrollMode: TurnScrollOwnership,
        isWaitingForAssistantResponse: Bool
    ) -> Bool {
        !shouldAnchorToAssistantResponse
            && autoScrollMode != .anchorAssistantResponse
            && !isWaitingForAssistantResponse
    }

    static func shouldShowIndicator(isRunStartingOrRunning: Bool) -> Bool {
        return isRunStartingOrRunning
    }
}

// Pins SwiftUI's backing UIScrollView to the vertical axis when an oversized row
// briefly makes UIKit preserve a horizontal content offset.
struct VerticalScrollAxisGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> VerticalScrollAxisGuardView {
        VerticalScrollAxisGuardView()
    }

    func updateUIView(_ uiView: VerticalScrollAxisGuardView, context: Context) {
        uiView.attachToNearestScrollViewIfNeeded()
    }
}

// Internal because UIViewRepresentable witnesses expose this concrete UIView type.
final class VerticalScrollAxisGuardView: UIView {
    private weak var guardedScrollView: UIScrollView?
    private var contentOffsetObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachToNearestScrollViewIfNeeded()
    }

    func attachToNearestScrollViewIfNeeded() {
        guard let scrollView = enclosingScrollView(), guardedScrollView !== scrollView else {
            clampHorizontalOffset()
            return
        }

        guardedScrollView = scrollView
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true

        contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.clampHorizontalOffset()
        }
        boundsObservation = scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.clampHorizontalOffset()
        }
        clampHorizontalOffset()
    }

    private func enclosingScrollView() -> UIScrollView? {
        sequence(first: superview, next: { $0?.superview })
            .first { $0 is UIScrollView } as? UIScrollView
    }

    private func clampHorizontalOffset() {
        guard let scrollView = guardedScrollView else { return }
        let pinnedX = -scrollView.adjustedContentInset.left
        guard abs(scrollView.contentOffset.x - pinnedX) > 0.5 else { return }

        var offset = scrollView.contentOffset
        offset.x = pinnedX
        scrollView.setContentOffset(offset, animated: false)
    }
}

/// Batches rapid `onScrollGeometryChange` callbacks so at most one @State
/// commit reaches SwiftUI per display-frame window, preventing the
/// "tried to update multiple times per frame" cycling.
@MainActor
final class ScrollGeometryCoalescer {
    var pending: (old: ScrollBottomState, new: ScrollBottomState)?
    private(set) var latestObservedIsAtBottom: Bool?
    private var applyTask: Task<Void, Never>?
    private var applyGeneration = 0
    private var followBottomTask: Task<Void, Never>?
    private var followBottomGeneration = 0
    private var isFollowBottomCorrectionAnimating = false

    func record(old: ScrollBottomState, new: ScrollBottomState) {
        if let pending {
            self.pending = (old: pending.old, new: new)
        } else {
            pending = (old: old, new: new)
        }
    }

    func observe(_ state: ScrollBottomState) {
        latestObservedIsAtBottom = state.isAtBottom
    }

    func markLatestObservedNotAtBottom() {
        latestObservedIsAtBottom = false
    }

    func scheduleApply(
        after nanoseconds: UInt64,
        action: @escaping @MainActor (ScrollBottomState, ScrollBottomState) -> Void
    ) {
        guard applyTask == nil else { return }
        applyGeneration &+= 1
        let expectedGeneration = applyGeneration
        applyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self,
                  !Task.isCancelled,
                  applyGeneration == expectedGeneration,
                  let pending else {
                return
            }
            self.pending = nil
            applyTask = nil
            action(pending.old, pending.new)
        }
    }

    func scheduleFollowBottom(
        after nanoseconds: UInt64,
        action: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void
    ) {
        guard followBottomTask == nil, !isFollowBottomCorrectionAnimating else { return }
        followBottomGeneration &+= 1
        let expectedGeneration = followBottomGeneration
        followBottomTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self,
                  !Task.isCancelled,
                  followBottomGeneration == expectedGeneration else {
                return
            }
            followBottomTask = nil
            isFollowBottomCorrectionAnimating = true
            action { [weak self] in
                guard let self,
                      followBottomGeneration == expectedGeneration else {
                    return
                }
                isFollowBottomCorrectionAnimating = false
            }
        }
    }

    func cancelFollowBottom() {
        followBottomGeneration &+= 1
        followBottomTask?.cancel()
        followBottomTask = nil
        isFollowBottomCorrectionAnimating = false
    }

    func cancel() {
        cancelFollowBottom()
        applyGeneration &+= 1
        applyTask?.cancel()
        applyTask = nil
        pending = nil
        latestObservedIsAtBottom = nil
    }
}

@MainActor
enum TurnTimelineWarmThreadCache {
    private static let maxEntries = 3
    private static var recentThreadIDs: [String] = []

    static func contains(_ threadID: String) -> Bool {
        recentThreadIDs.contains(threadID)
    }

    static func remember(_ threadID: String) {
        recentThreadIDs.removeAll { $0 == threadID }
        recentThreadIDs.append(threadID)
        if recentThreadIDs.count > maxEntries {
            recentThreadIDs.removeFirst(recentThreadIDs.count - maxEntries)
        }
    }
}
