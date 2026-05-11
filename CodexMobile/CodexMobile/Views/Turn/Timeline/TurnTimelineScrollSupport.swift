// FILE: TurnTimelineScrollSupport.swift
// Purpose: Provides scroll geometry batching and UIKit axis clamping for the timeline.
// Layer: View Support
// Exports: ScrollBottomGeometry, TurnTimelineRenderItemsCacheSignature, VerticalScrollAxisGuard, ScrollGeometryCoalescer
// Depends on: SwiftUI, UIKit

import SwiftUI
import UIKit

struct ScrollBottomGeometry: Equatable {
    let isAtBottom: Bool
    let viewportHeight: CGFloat
    let contentHeight: CGFloat

    static func from(_ geometry: ScrollGeometry) -> ScrollBottomGeometry {
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
        return ScrollBottomGeometry(
            isAtBottom: isAtBottom,
            viewportHeight: viewportHeight,
            contentHeight: geometry.contentSize.height
        )
    }
}

// Keeps scroll-only body passes from deeply hashing every hydrated message.
struct TurnTimelineRenderItemsCacheSignature: Equatable {
    let threadID: String
    let timelineChangeToken: Int
    let visibleTailCount: Int
    let messageCount: Int
    let firstMessageID: String?
    let lastMessageID: String?
    let completedTurnIDsHash: Int
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
    var pending: (old: ScrollBottomGeometry, new: ScrollBottomGeometry)?
    var applyTask: Task<Void, Never>?

    func record(old: ScrollBottomGeometry, new: ScrollBottomGeometry) {
        if let pending {
            self.pending = (old: pending.old, new: new)
        } else {
            pending = (old: old, new: new)
        }
    }

    func cancel() {
        applyTask?.cancel()
        applyTask = nil
        pending = nil
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
