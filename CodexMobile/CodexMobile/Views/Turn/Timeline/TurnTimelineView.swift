// FILE: TurnTimelineView.swift
// Purpose: Coordinates timeline scrolling, bottom-anchor behavior and render caches.
// Layer: View Component
// Exports: TurnTimelineView
// Depends on: SwiftUI, TurnTimelineRenderProjection, TurnTimelineReducer, TurnTimelineRows

import SwiftUI

// Groups derived timeline state so handlers can refresh caches with a single
// @State assignment instead of several frame-adjacent mutations.
private struct TurnTimelineRenderCacheState: Equatable {
    var blockInfoByMessageID: [String: AssistantBlockAccessoryState] = [:]
    var newestStreamingMessageID: String?
    var renderItemsSignature: TurnTimelineRenderItemsCacheSignature?
    var renderItemsShapeSignature: Int?
    var visibleRenderItems: [TurnTimelineRenderItem] = []
    var blockInfoInputKey: Int?
}

// Keeps the pending status visually in the timeline while removing it from
// the streaming message stack that changes height on every assistant delta.
private struct StickyPendingAssistantIndicatorRow: View, Equatable {
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
    let horizontalPadding: CGFloat

    var body: some View {
        HStack {
            TerminalRunningIndicator()
            Spacer(minLength: 0)
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .frame(width: viewportWidth, alignment: .leading)
        .allowsHitTesting(false)
    }
}

struct TurnTimelineView<EmptyState: View, Composer: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let threadID: String
    let messages: [CodexMessage]
    let timelineChangeToken: Int
    let activeTurnID: String?
    let isThreadRunning: Bool
    let isSendInFlight: Bool
    let latestTurnTerminalState: CodexTurnTerminalState?
    let completedTurnIDs: Set<String>
    let stoppedTurnIDs: Set<String>
    let assistantRevertStatesByMessageID: [String: AssistantRevertPresentation]
    let planSessionSource: CodexPlanSessionSource?
    let allowsAssistantPlanFallbackRecovery: Bool
    let threadMessagesForPlanMatching: [CodexMessage]
    let currentWorkingDirectory: String?
    let isRetryAvailable: Bool
    let errorMessage: String?
    let hidesErrorMessage: Bool
    let onReportError: (String) -> Void
    let onDismissError: () -> Void
    let hasRemoteEarlierMessages: Bool
    let hasLocallyProjectedEarlierMessages: Bool
    let usesPaginatedHistory: Bool
    let initialTurnsLoaded: Bool
    let isLoadingRemoteEarlierMessages: Bool
    let olderHistoryLoadErrorMessage: String?

    @Binding var shouldAnchorToAssistantResponse: Bool
    let isComposerFocused: Bool
    let isComposerAutocompletePresented: Bool

    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void
    let onRevealEarlierMessages: (Int) -> Void
    let onLoadRemoteEarlierMessages: () -> Void
    let onRetryEarlierMessages: (@escaping () -> Void) -> Void
    let onTapOutsideComposer: () -> Void
    @ViewBuilder let emptyState: () -> EmptyState
    @ViewBuilder let composer: () -> Composer

    private let scrollBottomAnchorID = "turn-scroll-bottom-anchor"
    /// Number of messages to show per page.  Only the tail slice is rendered;
    /// scrolling to the top reveals a "Load earlier messages" button.
    private static var pageSize: Int { 40 }
    private static var initialVisibleTailCount: Int { 80 }
    /// Heavy-chat staged warmup is temporarily disabled until geometry settles reliably.
    private static var initialWarmTailCount: Int { 0 }
    private static var scrollToLatestButtonLift: CGFloat { 44 + 8 }
    private static var pendingAssistantIndicatorBottomLift: CGFloat { 4 }
    private static var pendingAssistantIndicatorContentGap: CGFloat { 16 }
    private static var scrollGeometryCoalescingDelayNanoseconds: UInt64 { 16_000_000 }

    @State private var visibleTailCount: Int = initialVisibleTailCount
    @State private var isScrolledToBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var renderCacheState = TurnTimelineRenderCacheState()
    @State private var scrollSessionThreadID: String?
    @State private var autoScrollMode: TurnAutoScrollMode = .followBottom
    @State private var initialRecoverySnapPendingThreadID: String?
    @State private var initialRecoverySnapTask: Task<Void, Never>?
    @State private var followBottomScrollTask: Task<Void, Never>?
    @State private var pendingAssistantBottomSnapTask: Task<Void, Never>?
    @State private var progressiveTailRevealTask: Task<Void, Never>?
    @State private var isProgressivelyRevealingRecentTail = false
    @State private var isUserDraggingScroll = false
    @State private var userScrollCooldownUntil: Date?
    @State private var pendingRemoteEarlierLoadMessageCount: Int?
    @State private var isLocalEarlierRevealPending = false
    @State private var isRetryingEarlierHistoryLoad = false
    @State private var localEarlierRevealTask: Task<Void, Never>?
    @State private var scrollGeometryCoalescer = ScrollGeometryCoalescer()

    /// The service supplies paginated render windows; legacy full-history threads still slice locally.
    private var visibleMessages: ArraySlice<CodexMessage> {
        if usesPaginatedHistory {
            return messages[...]
        }

        let startIndex = max(messages.count - visibleTailCount, 0)
        return messages[startIndex...]
    }

    // Renders appended/removed rows immediately if SwiftUI reaches body before the
    // lifecycle cache refresh. Assistant text-only deltas still use the cached rows.
    private var visibleRenderItems: [TurnTimelineRenderItem] {
        let visibleSlice = visibleMessages
        guard renderItemsShapeSignature(for: visibleSlice) != renderCacheState.renderItemsShapeSignature else {
            return renderCacheState.visibleRenderItems
        }

        return TurnTimelineRenderProjection.project(
            messages: Array(visibleSlice),
            completedTurnIDs: completedTurnIDs,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning
        )
    }

    private func renderItemsShapeSignature(for messages: ArraySlice<CodexMessage>) -> Int {
        var hasher = Hasher()
        hasher.combine(threadID)
        hasher.combine(visibleTailCount)
        hasher.combine(messages.count)
        hasher.combine(activeTurnID)
        hasher.combine(isThreadRunning)
        hasher.combine(completedTurnIDs)

        if let message = messages.first {
            hasher.combine(message.id)
            hasher.combine(message.orderIndex)
        }

        if let message = messages.last {
            hasher.combine(message.id)
            hasher.combine(message.role)
            hasher.combine(message.kind)
            hasher.combine(message.turnId)
            hasher.combine(message.deliveryState)
            hasher.combine(message.isStreaming)
            hasher.combine(message.orderIndex)
        }

        return hasher.finalize()
    }

    private var hasEarlierMessages: Bool {
        if isInitialEarlierPageLoading {
            return true
        }

        if usesPaginatedHistory {
            return hasRemoteEarlierMessages
                || hasLocallyProjectedEarlierMessages
                || isRemoteEarlierLoadPending
                || isLoadingRemoteEarlierMessages
                || isLocalEarlierRevealPending
                || olderHistoryLoadErrorMessage != nil
        }

        return visibleTailCount < messages.count
            || hasLocallyProjectedEarlierMessages
            || hasRemoteEarlierMessages
            || isRemoteEarlierLoadPending
            || isLocalEarlierRevealPending
            || olderHistoryLoadErrorMessage != nil
    }

    private var isRemoteEarlierLoadPending: Bool {
        pendingRemoteEarlierLoadMessageCount != nil
    }

    private var isInitialEarlierPageLoading: Bool {
        !initialTurnsLoaded && !messages.isEmpty && !isThreadRunning
    }

    private var isRunStartingOrRunning: Bool {
        isThreadRunning || isSendInFlight
    }

    private var isEarlierHistoryInteractionActive: Bool {
            isInitialEarlierPageLoading
            || isRemoteEarlierLoadPending
            || isLoadingRemoteEarlierMessages
            || isLocalEarlierRevealPending
            || isRetryingEarlierHistoryLoad
    }

    private var shouldWarmRecentTailProgressively: Bool {
        isProgressivelyRevealingRecentTail
            && messages.count > visibleTailCount
    }

    private var isRecentTailWarmupActive: Bool {
        shouldStageHeavyThreadOpen
            && visibleTailCount < min(messages.count, Self.initialVisibleTailCount)
    }

    // Catches delayed tail updates without hashing the whole render window each body pass.
    private var visibleMessagesBoundarySignature: Int {
        let visibleSlice = visibleMessages
        var hasher = Hasher()
        hasher.combine(threadID)
        hasher.combine(visibleTailCount)
        hasher.combine(visibleSlice.count)
        if let message = visibleSlice.first {
            hasher.combine(message.id)
            hasher.combine(message.orderIndex)
        }
        if let message = visibleSlice.last {
            hasher.combine(message.id)
            hasher.combine(message.role)
            hasher.combine(message.kind)
            hasher.combine(message.turnId)
            hasher.combine(message.deliveryState)
            hasher.combine(message.isStreaming)
            hasher.combine(message.orderIndex)
        }
        return hasher.finalize()
    }

    private var shouldShowFullTimelineLoader: Bool {
        shouldWarmRecentTailProgressively && visibleTailCount == 0
    }

    // Keeps larger accessibility text inside a slightly roomier gutter so assistant
    // prose does not read as edge-to-edge when Dynamic Type is bumped up.
    private var timelineHorizontalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 16
    }

    private var pendingAssistantIndicatorReservedHeight: CGFloat {
        TerminalRunningIndicatorLayout.reservedRowHeight(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    // Empty streaming assistant rows are projected away; keep their footprint in the stack.
    private var pendingStreamingAssistantPlaceholderID: String? {
        guard isRunStartingOrRunning else { return nil }

        let renderedMessageIDs = Set(
            renderCacheState.visibleRenderItems.compactMap { item -> String? in
                guard case .message(let message) = item else { return nil }
                return message.id
            }
        )

        for message in messages.reversed() {
            guard message.role == .assistant,
                  message.isStreaming,
                  message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !renderedMessageIDs.contains(message.id) else {
                continue
            }
            return message.id
        }
        return nil
    }

    private var shouldStageHeavyThreadOpen: Bool {
        false
    }

    private var planMatchingFingerprint: Int {
        var hasher = Hasher()
        for message in threadMessagesForPlanMatching where message.kind == .userInputPrompt {
            hasher.combine(message.id)
            hasher.combine(message.turnId)
            hasher.combine(message.orderIndex)
            hasher.combine(message.structuredUserInputRequest?.requestID)
            hasher.combine(message.structuredUserInputRequest?.questions)
        }
        return hasher.finalize()
    }

    private func renderItemsCacheSignature(for messages: ArraySlice<CodexMessage>) -> TurnTimelineRenderItemsCacheSignature {
        TurnTimelineCacheKeyBuilder.renderItemsSignature(
            threadID: threadID,
            timelineChangeToken: timelineChangeToken,
            visibleTailCount: visibleTailCount,
            messages: messages,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning,
            completedTurnIDs: completedTurnIDs
        )
    }

    var body: some View {
        if messages.isEmpty && !hasEarlierMessages && olderHistoryLoadErrorMessage == nil && !isLoadingRemoteEarlierMessages {
            // Keep new/empty chats static to avoid scroll indicators and inert scrolling.
            emptyTimelineState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .contentShape(Rectangle())
                .onTapGesture {
                    onTapOutsideComposer()
                }
                .simultaneousGesture(emptyStateKeyboardDismissGesture)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    footer()
                }
                .onAppear {
                    beginScrollSessionIfNeeded()
                }
                .onChange(of: threadID) { _, _ in
                    beginScrollSessionIfNeeded(force: true)
                }
        } else {
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    let contentWidth = timelineContentWidth(for: viewport.size.width)
                    let showsStickyPendingAssistantIndicator = shouldShowStickyPendingAssistantIndicator
                    ScrollView(.vertical) {
                        TurnTimelineRowsSection(
                            shouldWarmRecentTailProgressively: shouldWarmRecentTailProgressively,
                            hasEarlierMessages: hasEarlierMessages,
                            isLoadingEarlierMessages: isInitialEarlierPageLoading
                                || isLoadingRemoteEarlierMessages
                                || isRemoteEarlierLoadPending
                                || isLocalEarlierRevealPending
                                || isRetryingEarlierHistoryLoad,
                            earlierMessagesErrorMessage: olderHistoryLoadErrorMessage,
                            renderItems: visibleRenderItems,
                            showsGlobalRunningIndicator: showsStickyPendingAssistantIndicator,
                            isRetryAvailable: isRetryAvailable,
                            cachedBlockInfoByMessageID: renderCacheState.blockInfoByMessageID,
                            planSessionSource: planSessionSource,
                            allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                            completedTurnIDs: completedTurnIDs,
                            threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                            currentWorkingDirectory: currentWorkingDirectory,
                            planMatchingFingerprint: planMatchingFingerprint,
                            newestStreamingMessageID: renderCacheState.newestStreamingMessageID,
                            autoScrollMode: autoScrollMode,
                            onRetryUserMessage: onRetryUserMessage,
                            onTapAssistantRevert: onTapAssistantRevert,
                            onTapSubagent: onTapSubagent,
                            onLoadEarlierMessages: handleLoadEarlierMessages,
                            pendingStreamingAssistantPlaceholderID: pendingStreamingAssistantPlaceholderID
                        )
                        // SwiftUI can otherwise let a streaming text row report an
                        // over-wide ideal size, which makes the vertical timeline pan sideways.
                        .frame(width: contentWidth, alignment: .leading)
                        .padding(.horizontal, timelineHorizontalPadding)
                        .frame(width: viewport.size.width, alignment: .leading)
                        .clipped()
                        .background(VerticalScrollAxisGuard())
                        .padding(.top, 12)
                        .padding(.bottom, timelineRowsBottomPadding(
                            showsStickyPendingAssistantIndicator: showsStickyPendingAssistantIndicator
                        ))

                        // Keep bottom anchor outside the message stack so it is always
                        // reachable by scrollTo regardless of VStack layout timing.
                        Color.clear
                            .frame(width: contentWidth, height: 1)
                            .padding(.horizontal, timelineHorizontalPadding)
                            .frame(width: viewport.size.width, alignment: .leading)
                            .clipped()
                            .id(scrollBottomAnchorID)
                            .allowsHitTesting(false)
                    }
                    .accessibilityIdentifier("turn.timeline.scrollview")
                    .background(Color(.systemBackground))
                    .overlay(alignment: .bottom) {
                        if showsStickyPendingAssistantIndicator {
                            StickyPendingAssistantIndicatorRow(
                                contentWidth: contentWidth,
                                viewportWidth: viewport.size.width,
                                horizontalPadding: timelineHorizontalPadding
                            )
                            .equatable()
                            .padding(.bottom, Self.pendingAssistantIndicatorBottomLift)
                            .transition(.opacity)
                        }
                    }
                    .overlay {
                        if shouldShowFullTimelineLoader {
                            timelineLoadingOverlay
                        }
                    }
                    .frame(width: viewport.size.width)
                    .defaultScrollAnchor(initialScrollAnchor, for: .initialOffset)
                    .defaultScrollAnchor(.top, for: .sizeChanges)
                    .modifier(
                        TurnTimelineScrollObserverModifier(
                            isGeometryTrackingEnabled: shouldTrackScrollGeometry,
                            onTapOutsideComposer: onTapOutsideComposer,
                            onScrollPhaseChange: { oldPhase, newPhase in
                                handleScrollPhaseChange(from: oldPhase, to: newPhase)
                            },
                            onScrollGeometryChange: { old, new in
                                handleScrollGeometryChange(old: old, new: new, using: proxy)
                            }
                        )
                    )
                    .modifier(timelineHistoryChangeHandlers(using: proxy))
                    .modifier(timelineRenderChangeHandlers(using: proxy))
                    .onChange(of: visibleMessagesBoundarySignature) { _, _ in
                        handleVisibleMessagesChange(using: proxy)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        footer(scrollToBottomAction: {
                            handleScrollToLatestButtonTap(using: proxy)
                        })
                    }
                    .onAppear {
                        debugTimelineLog("onAppear threadID=\(threadID) messageCount=\(messages.count)")
                        beginScrollSessionIfNeeded()
                        recomputeRenderItemsAndBlockInfoIfNeeded()
                        scheduleProgressiveTailRevealIfNeeded()
                        handleTimelineMutation(using: proxy)
                    }
                    .onDisappear {
                        debugTimelineLog("onDisappear threadID=\(threadID)")
                        cancelScrollTasks()
                    }
                }
            }
        }
    }

    // Keeps the padded timeline exactly viewport-wide so streaming rows cannot
    // expand the vertical ScrollView into a horizontally draggable surface.
    private func timelineContentWidth(for viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - (timelineHorizontalPadding * 2))
    }

    private func recomputeRenderItemsIfNeeded() {
        recomputeTimelineRenderCacheIfNeeded(rebuildBlockInfo: false)
    }

    private func recomputeBlockInfoIfNeeded() {
        recomputeTimelineRenderCacheIfNeeded(rebuildRenderItems: false)
    }

    private func recomputeRenderItemsAndBlockInfoIfNeeded() {
        recomputeTimelineRenderCacheIfNeeded()
    }

    // Rebuilds derived row/accessory state and commits it as one SwiftUI state update.
    private func recomputeTimelineRenderCacheIfNeeded(
        rebuildRenderItems: Bool = true,
        rebuildBlockInfo: Bool = true
    ) {
        let visibleSlice = visibleMessages
        let visible = Array(visibleSlice)
        var nextState = renderCacheState
        var didChange = false
        let shapeSignature = renderItemsShapeSignature(for: visibleSlice)

        // Block-info placement depends on collapsed render items, so keep the
        // projection fresh before deriving accessory state.
        if rebuildRenderItems || rebuildBlockInfo {
            let signature = renderItemsCacheSignature(for: visibleSlice)
            if signature != nextState.renderItemsSignature {
                nextState.visibleRenderItems = TurnTimelineRenderProjection.project(
                    messages: visible,
                    completedTurnIDs: completedTurnIDs,
                    activeTurnID: activeTurnID,
                    isThreadRunning: isThreadRunning
                )
                nextState.renderItemsSignature = signature
                nextState.renderItemsShapeSignature = shapeSignature
                didChange = true
            }
        }

        if rebuildBlockInfo {
            let key = blockInfoInputKey(for: visible)
            if nextState.blockInfoInputKey != key {
                nextState.blockInfoInputKey = key

                let cachedBlockInfo = Self.assistantBlockInfo(
                    for: visible,
                    activeTurnID: activeTurnID,
                    isThreadRunning: isThreadRunning,
                    isCopySuppressedByRunState: isRunStartingOrRunning,
                    latestTurnTerminalState: latestTurnTerminalState,
                    stoppedTurnIDs: stoppedTurnIDs,
                    revertStatesByMessageID: assistantRevertStatesByMessageID
                )

                let initialBlockInfoByMessageID = [String: AssistantBlockAccessoryState](
                    uniqueKeysWithValues: zip(visible, cachedBlockInfo).compactMap { message, blockText in
                        guard let blockText else { return nil }
                        return (message.id, blockText)
                    }
                )
                let updated = Self.rehomeCollapsedFinalAccessoryStates(
                    initialBlockInfoByMessageID,
                    messages: visible,
                    completedTurnIDs: completedTurnIDs
                )
                nextState.blockInfoByMessageID = Self.rehomeHiddenAccessoryStates(
                    updated,
                    messages: visible,
                    renderItems: nextState.visibleRenderItems
                )
                nextState.newestStreamingMessageID = visible.last(where: { $0.isStreaming })?.id
                didChange = true
            }
        }

        if didChange {
            renderCacheState = nextState
        }
    }

    // Hashes the fields that change copy-block aggregation or inline action placement.
    // Include message text too because thread/resume can reconcile completed rows in place.
    private func blockInfoInputKey(for messages: [CodexMessage]) -> Int {
        TurnTimelineCacheKeyBuilder.blockInfoInputKey(
            messages: messages,
            isThreadRunning: isThreadRunning,
            isSendInFlight: isSendInFlight,
            activeTurnID: activeTurnID,
            latestTurnTerminalState: latestTurnTerminalState,
            completedTurnIDs: completedTurnIDs,
            stoppedTurnIDs: stoppedTurnIDs,
            assistantRevertStatesByMessageID: assistantRevertStatesByMessageID
        )
    }
    @ViewBuilder
    private var emptyTimelineState: some View {
        if isThreadRunning {
            TurnTimelineRunningEmptyState()
        } else {
            emptyState()
        }
    }

    // Keeps the composer/footer visually stable so scrolling does not animate the bottom inset.
    private func footer(scrollToBottomAction: (() -> Void)? = nil) -> some View {
        TurnTimelineFooterContainer(
            hidesErrorMessage: hidesErrorMessage,
            errorMessage: errorMessage,
            onReportError: onReportError,
            onDismissError: onDismissError,
            shouldShowScrollToLatestButton: shouldShowScrollToLatestButton,
            scrollToLatestButtonLift: Self.scrollToLatestButtonLift,
            onScrollToLatest: scrollToBottomAction,
            composer: composer
        )
    }

    // Restores swipe-to-dismiss in brand-new chats without putting a drag
    // recognizer back on top of the composer footer itself.
    private var emptyStateKeyboardDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard isComposerFocused else { return }
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                guard value.translation.height < -20 else { return }
                onTapOutsideComposer()
            }
    }

    private var shouldShowScrollToLatestButton: Bool {
        TurnScrollStateTracker.shouldShowScrollToLatestButton(
            messageCount: messages.count,
            isScrolledToBottom: isScrolledToBottom
        )
    }

    private var initialScrollAnchor: UnitPoint {
        .bottom
    }

    private var shouldShowPendingAssistantResponse: Bool {
        TurnTimelinePendingAssistantState.isWaitingForAssistantResponse(
            shouldAnchorToAssistantResponse: shouldAnchorToAssistantResponse,
            messages: messages
        )
    }

    // Keep the thinking label pinned above the composer for the whole run, even while
    // assistant prose and late tool rows stream into the scroll stack above it.
    private var shouldShowStickyPendingAssistantIndicator: Bool {
        TurnTimelinePendingAssistantState.shouldShowIndicator(
            isRunStartingOrRunning: isRunStartingOrRunning
        )
    }

    private func timelineRowsBottomPadding(showsStickyPendingAssistantIndicator: Bool) -> CGFloat {
        guard showsStickyPendingAssistantIndicator else {
            return 12
        }

        return 12
            + pendingAssistantIndicatorReservedHeight
            + Self.pendingAssistantIndicatorContentGap
    }

    // Scroll geometry resumes after the optimistic send gap and assistant anchor settle.
    private var shouldTrackScrollGeometry: Bool {
        TurnTimelinePendingAssistantState.shouldTrackScrollGeometry(
            shouldAnchorToAssistantResponse: shouldAnchorToAssistantResponse,
            autoScrollMode: autoScrollMode,
            isWaitingForAssistantResponse: shouldShowPendingAssistantResponse
        )
    }

    private func handleLoadEarlierMessages() {
        guard !isEarlierHistoryInteractionActive else {
            return
        }

        progressiveTailRevealTask?.cancel()
        progressiveTailRevealTask = nil
        scrollGeometryCoalescer.cancel()
        isProgressivelyRevealingRecentTail = false

        let hasLegacyLocalRowsToReveal = !usesPaginatedHistory && visibleTailCount < messages.count
        // Reveal already-cached rows first; only hit the remote cursor once local history is exhausted.
        if hasLegacyLocalRowsToReveal || hasLocallyProjectedEarlierMessages {
            localEarlierRevealTask?.cancel()
            isLocalEarlierRevealPending = true
            onRevealEarlierMessages(Self.pageSize)
            if !usesPaginatedHistory {
                withAnimation(.easeOut(duration: 0.15)) {
                    visibleTailCount = min(visibleTailCount + Self.pageSize, messages.count + Self.pageSize)
                }
            }
            scheduleLocalEarlierRevealCompletion()
            return
        }

        if hasRemoteEarlierMessages {
            guard !isLoadingRemoteEarlierMessages else {
                return
            }
            pendingRemoteEarlierLoadMessageCount = messages.count
            onLoadRemoteEarlierMessages()
            return
        }

        if olderHistoryLoadErrorMessage != nil {
            let expectedThreadID = threadID
            isRetryingEarlierHistoryLoad = true
            onRetryEarlierMessages {
                guard scrollSessionThreadID == expectedThreadID else {
                    return
                }
                isRetryingEarlierHistoryLoad = false
            }
        }
    }

    // Debounces the top button so a single tap cannot consume many local pages before SwiftUI lays out.
    private func scheduleLocalEarlierRevealCompletion() {
        let expectedThreadID = threadID
        localEarlierRevealTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled,
                  scrollSessionThreadID == expectedThreadID else {
                return
            }
            isLocalEarlierRevealPending = false
            localEarlierRevealTask = nil
        }
    }

    private func handleScrollToLatestButtonTap(using proxy: ScrollViewProxy) {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        shouldAnchorToAssistantResponse = false
        autoScrollMode = .followBottom
        initialRecoverySnapPendingThreadID = nil
        isUserDraggingScroll = false
        userScrollCooldownUntil = nil
        pendingAssistantBottomSnapTask?.cancel()
        pendingAssistantBottomSnapTask = nil
        scrollToBottom(using: proxy, animated: true)
    }

    // Resets per-thread scroll intent so each opened conversation gets one fresh
    // post-layout recovery snap and starts in bottom-follow mode.
    private func beginScrollSessionIfNeeded(force: Bool = false) {
        guard force || scrollSessionThreadID != threadID else { return }

        cancelScrollTasks()
        scrollSessionThreadID = threadID
        visibleTailCount = shouldStageHeavyThreadOpen
            ? Self.initialWarmTailCount
            : min(messages.count, Self.initialVisibleTailCount)
        isScrolledToBottom = true
        isUserDraggingScroll = false
        userScrollCooldownUntil = nil
        pendingRemoteEarlierLoadMessageCount = nil
        isLocalEarlierRevealPending = false
        isRetryingEarlierHistoryLoad = false
        localEarlierRevealTask?.cancel()
        localEarlierRevealTask = nil
        autoScrollMode = shouldAnchorToAssistantResponse ? .anchorAssistantResponse : .followBottom
        initialRecoverySnapPendingThreadID = shouldAnchorToAssistantResponse ? nil : threadID
        isProgressivelyRevealingRecentTail = shouldStageHeavyThreadOpen
    }

    // Cancels any delayed scroll work so old thread sessions cannot move the new one.
    private func cancelScrollTasks() {
        initialRecoverySnapTask?.cancel()
        initialRecoverySnapTask = nil
        followBottomScrollTask?.cancel()
        followBottomScrollTask = nil
        pendingAssistantBottomSnapTask?.cancel()
        pendingAssistantBottomSnapTask = nil
        progressiveTailRevealTask?.cancel()
        progressiveTailRevealTask = nil
        isProgressivelyRevealingRecentTail = false
        pendingRemoteEarlierLoadMessageCount = nil
        isLocalEarlierRevealPending = false
        isRetryingEarlierHistoryLoad = false
        localEarlierRevealTask?.cancel()
        localEarlierRevealTask = nil
    }

    // Keeps the remote "Load earlier" affordance visible while a page is in flight.
    private func handleMessageCountChange(oldCount: Int, newCount: Int) {
        recomputeRenderItemsIfNeeded()
        guard let pendingCount = pendingRemoteEarlierLoadMessageCount else {
            return
        }
        if newCount > pendingCount || newCount > oldCount {
            pendingRemoteEarlierLoadMessageCount = nil
        }
    }

    // If the service finishes without adding rows, let the normal cursor/error flags decide visibility.
    private func handleRemoteEarlierLoadingChange(isLoading: Bool) {
        guard !isLoading,
              pendingRemoteEarlierLoadMessageCount != nil else {
            return
        }
        pendingRemoteEarlierLoadMessageCount = nil
    }

    // Timeline mutations still drive block-info refresh and assistant anchoring,
    // but geometry decides when follow-bottom should actually fire.
    private func timelineHistoryChangeHandlers(using proxy: ScrollViewProxy) -> TurnTimelineHistoryChangeHandlersModifier {
        TurnTimelineHistoryChangeHandlersModifier(
            timelineChangeToken: timelineChangeToken,
            messageCount: messages.count,
            isLoadingRemoteEarlierMessages: isLoadingRemoteEarlierMessages,
            initialTurnsLoaded: initialTurnsLoaded,
            hasRemoteEarlierMessages: hasRemoteEarlierMessages,
            olderHistoryLoadErrorMessage: olderHistoryLoadErrorMessage,
            onTimelineChange: { handleTimelineChange(using: proxy) },
            onMessageCountChange: handleMessageCountChange,
            onRemoteEarlierLoadingChange: handleRemoteEarlierLoadingChange,
            onInitialHistoryLoaded: { handleInitialHistoryLoaded(using: proxy) },
            onRemoteEarlierAvailabilityChange: handleRemoteEarlierAvailabilityChange,
            onOlderHistoryErrorChange: handleOlderHistoryErrorChange
        )
    }

    private func timelineRenderChangeHandlers(using proxy: ScrollViewProxy) -> TurnTimelineRenderChangeHandlersModifier {
        TurnTimelineRenderChangeHandlersModifier(
            isThreadRunning: isThreadRunning,
            isSendInFlight: isSendInFlight,
            threadID: threadID,
            activeTurnID: activeTurnID,
            latestTurnTerminalState: latestTurnTerminalState,
            completedTurnIDs: completedTurnIDs,
            stoppedTurnIDs: stoppedTurnIDs,
            visibleTailCount: visibleTailCount,
            shouldAnchorToAssistantResponse: shouldAnchorToAssistantResponse,
            onThreadRunningChange: { handleThreadRunningChange(using: proxy) },
            onSendInFlightChange: { handleSendInFlightChange(using: proxy) },
            onThreadIDChange: { handleThreadIDChange(using: proxy) },
            onActiveTurnIDChange: { handleActiveTurnIDChange(using: proxy) },
            onTerminalStateChange: handleTerminalStateChange,
            onCompletedTurnIDsChange: handleCompletedTurnIDsChange,
            onStoppedTurnIDsChange: handleStoppedTurnIDsChange,
            onVisibleTailCountChange: handleVisibleTailCountChange,
            onAssistantAnchorChange: { handleAssistantAnchorChange($0, using: proxy) }
        )
    }

    private func handleTimelineChange(using proxy: ScrollViewProxy) {
        debugTimelineLog(
            "timelineChangeToken changed token=\(timelineChangeToken) "
                + "messageCount=\(messages.count) visibleTail=\(visibleTailCount)"
        )
        recomputeRenderItemsAndBlockInfoIfNeeded()
        scheduleProgressiveTailRevealIfNeeded()
        handleTimelineMutation(using: proxy)
    }

    private func handleVisibleMessagesChange(using proxy: ScrollViewProxy) {
        debugTimelineLog(
            "visible messages changed token=\(timelineChangeToken) "
                + "messageCount=\(messages.count) visibleTail=\(visibleTailCount)"
        )
        recomputeRenderItemsAndBlockInfoIfNeeded()
        handleTimelineMutation(using: proxy)
    }

    private func handleRemoteEarlierAvailabilityChange(_ newValue: Bool) {
        if !newValue {
            pendingRemoteEarlierLoadMessageCount = nil
        }
    }

    private func handleOlderHistoryErrorChange(_ newValue: String?) {
        if newValue != nil {
            pendingRemoteEarlierLoadMessageCount = nil
        }
    }

    private func handleThreadRunningChange(using proxy: ScrollViewProxy) {
        debugTimelineLog("isThreadRunning changed value=\(isThreadRunning)")
        // Run-state changes alter the sticky pending row and bottom inset before
        // the first assistant item exists, so treat them like a timeline mutation.
        recomputeRenderItemsAndBlockInfoIfNeeded()
        handleTimelineMutation(using: proxy)
    }

    private func handleSendInFlightChange(using proxy: ScrollViewProxy) {
        debugTimelineLog("isSendInFlight changed value=\(isSendInFlight)")
        // Sending mode is the optimistic-user-row gap between tap and turn/start.
        // Re-run normal mutation handling so the row is measured while still pending.
        recomputeRenderItemsAndBlockInfoIfNeeded()
        handleTimelineMutation(using: proxy)
    }

    private func handleThreadIDChange(using proxy: ScrollViewProxy) {
        debugTimelineLog("threadID changed to=\(threadID)")
        beginScrollSessionIfNeeded(force: true)
        recomputeRenderItemsAndBlockInfoIfNeeded()
        scheduleProgressiveTailRevealIfNeeded()
        handleTimelineMutation(using: proxy)
    }

    private func handleActiveTurnIDChange(using proxy: ScrollViewProxy) {
        debugTimelineLog("activeTurnID changed to=\(activeTurnID ?? "nil")")
        recomputeBlockInfoIfNeeded()
        handleTimelineMutation(using: proxy)
    }

    private func handleTerminalStateChange() {
        debugTimelineLog("latestTurnTerminalState changed to=\(String(describing: latestTurnTerminalState))")
        recomputeBlockInfoIfNeeded()
    }

    private func handleCompletedTurnIDsChange() {
        debugTimelineLog("completedTurnIDs changed count=\(completedTurnIDs.count)")
        recomputeRenderItemsAndBlockInfoIfNeeded()
    }

    private func handleStoppedTurnIDsChange() {
        debugTimelineLog("stoppedTurnIDs changed count=\(stoppedTurnIDs.count)")
        recomputeBlockInfoIfNeeded()
    }

    private func handleVisibleTailCountChange() {
        debugTimelineLog("visibleTailCount changed value=\(visibleTailCount) totalMessages=\(messages.count)")
        recomputeRenderItemsAndBlockInfoIfNeeded()
    }

    private func handleAssistantAnchorChange(_ newValue: Bool, using proxy: ScrollViewProxy) {
        if newValue {
            autoScrollMode = .anchorAssistantResponse
            handleTimelineMutation(using: proxy)
        } else if autoScrollMode == .anchorAssistantResponse {
            autoScrollMode = isScrolledToBottom ? .followBottom : .manual
        }
    }

    // Initial history hydration can finish after SwiftUI has already chosen a provisional offset.
    // Re-arm the recovery snap once the first authoritative page is available.
    private func handleInitialHistoryLoaded(using proxy: ScrollViewProxy) {
        guard scrollSessionThreadID == threadID,
              !messages.isEmpty,
              autoScrollMode == .followBottom,
              !shouldAnchorToAssistantResponse,
              !shouldPauseAutomaticScrolling else {
            return
        }

        initialRecoverySnapTask?.cancel()
        initialRecoverySnapTask = nil
        initialRecoverySnapPendingThreadID = threadID
        performInitialRecoverySnapIfNeeded(using: proxy)
    }

    private var timelineLoadingOverlay: some View {
        TurnTimelineLoadingOverlay()
    }

    // Stages the recent tail for heavy chats so thread switches avoid building dozens
    // of rich markdown rows in one main-thread burst. The last 3 opened chats stay warm.
    private func scheduleProgressiveTailRevealIfNeeded() {
        let targetTailCount = min(messages.count, Self.initialVisibleTailCount)

        guard targetTailCount > 0 else {
            return
        }

        guard shouldStageHeavyThreadOpen else {
            if visibleTailCount < targetTailCount {
                visibleTailCount = targetTailCount
            }
            if messages.count > Self.initialVisibleTailCount {
                TurnTimelineWarmThreadCache.remember(threadID)
            }
            isProgressivelyRevealingRecentTail = false
            return
        }

        guard isScrolledToBottom,
              !shouldPauseAutomaticScrolling,
              autoScrollMode == .followBottom else {
            isProgressivelyRevealingRecentTail = false
            progressiveTailRevealTask?.cancel()
            progressiveTailRevealTask = nil
            return
        }

        guard !TurnTimelineWarmThreadCache.contains(threadID) else {
            if visibleTailCount < targetTailCount {
                visibleTailCount = targetTailCount
            }
            isProgressivelyRevealingRecentTail = false
            return
        }

        guard visibleTailCount < targetTailCount else {
            TurnTimelineWarmThreadCache.remember(threadID)
            isProgressivelyRevealingRecentTail = false
            return
        }

        guard progressiveTailRevealTask == nil else { return }

        let expectedThreadID = threadID

        isProgressivelyRevealingRecentTail = true
        progressiveTailRevealTask = Task { @MainActor in
            defer {
                if scrollSessionThreadID == expectedThreadID {
                    isProgressivelyRevealingRecentTail = false
                }
                progressiveTailRevealTask = nil
            }

            try? await Task.sleep(nanoseconds: 35_000_000)

            guard !Task.isCancelled,
                  scrollSessionThreadID == expectedThreadID,
                  isScrolledToBottom,
                  !shouldPauseAutomaticScrolling,
                  autoScrollMode == .followBottom else {
                return
            }

            let liveTargetTailCount = min(messages.count, Self.initialVisibleTailCount)
            if visibleTailCount < liveTargetTailCount {
                visibleTailCount = liveTargetTailCount
            }
            TurnTimelineWarmThreadCache.remember(expectedThreadID)
        }
    }

    // Lets the first-open bottom snap learn the viewport even while initial history is loading.
    private var shouldProcessInitialRecoveryGeometry: Bool {
        initialRecoverySnapPendingThreadID == threadID && !messages.isEmpty
    }

    // Coalesces scroll geometry into a small helper so the SwiftUI modifier chain stays type-checkable.
    private func handleScrollGeometryChange(
        old: ScrollBottomGeometry,
        new: ScrollBottomGeometry,
        using proxy: ScrollViewProxy
    ) {
        guard !isEarlierHistoryInteractionActive || shouldProcessInitialRecoveryGeometry else { return }

        // Coalesce into a single commit per display-frame window so SwiftUI
        // does not receive several geometry-driven state mutations per frame.
        scrollGeometryCoalescer.record(old: old, new: new)
        guard scrollGeometryCoalescer.applyTask == nil else { return }
        debugTimelineLog("geometry change scheduled for frame coalesced apply")
        scrollGeometryCoalescer.applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.scrollGeometryCoalescingDelayNanoseconds)
            scrollGeometryCoalescer.applyTask = nil
            guard let pending = scrollGeometryCoalescer.pending else { return }
            scrollGeometryCoalescer.pending = nil
            guard !Task.isCancelled else { return }
            guard !isEarlierHistoryInteractionActive || shouldProcessInitialRecoveryGeometry else { return }
            applyScrollGeometryUpdate(
                old: pending.old,
                new: pending.new,
                using: proxy
            )
        }
    }

    // Stops follow-bottom as soon as the user drags away so queued snaps cannot fight the gesture.
    private func handleScrolledToBottomChanged(_ nextValue: Bool) {
        guard nextValue != isScrolledToBottom else { return }

        // Ignore transient "not at bottom" geometry while a newly selected chat is still
        // performing its initial recovery snap, otherwise fast chat switches can downgrade
        // follow-bottom to manual before the first bottom jump lands.
        if !nextValue,
           initialRecoverySnapPendingThreadID == threadID,
           autoScrollMode == .followBottom {
            return
        }

        if isProgressivelyRevealingRecentTail,
           autoScrollMode == .followBottom,
           !nextValue {
            return
        }

        // Content growth can briefly report "not bottom" before the queued
        // follow snap lands; only user scroll phases should make that visible.
        if !nextValue,
           TurnScrollStateTracker.shouldIgnoreTransientNotBottomGeometry(
            currentMode: autoScrollMode,
            hasPendingFollowBottomScroll: followBottomScrollTask != nil,
            isAutomaticScrollingPaused: shouldPauseAutomaticScrolling
           ) {
            return
        }

        if !nextValue {
            // Cancel queued app snaps once geometry confirms the viewport is away
            // from bottom; transient content-growth frames are filtered above.
            followBottomScrollTask?.cancel()
            followBottomScrollTask = nil
            progressiveTailRevealTask?.cancel()
            progressiveTailRevealTask = nil
            isProgressivelyRevealingRecentTail = false
        }

        isScrolledToBottom = nextValue
        if nextValue {
            if autoScrollMode != .anchorAssistantResponse {
                autoScrollMode = .followBottom
            }
            scheduleProgressiveTailRevealIfNeeded()
        } else {
            autoScrollMode = TurnScrollStateTracker.modeAfterAcceptedNotBottomGeometry(
                currentMode: autoScrollMode
            )
        }
    }

    // Gives user drag intent precedence over follow-bottom so streaming never wrestles the scroll gesture.
    private func handleUserScrollDragChanged() {
        guard !isUserDraggingScroll else { return }
        isUserDraggingScroll = true
        userScrollCooldownUntil = nil
        initialRecoverySnapPendingThreadID = nil
        initialRecoverySnapTask?.cancel()
        initialRecoverySnapTask = nil
        followBottomScrollTask?.cancel()
        followBottomScrollTask = nil
        pendingAssistantBottomSnapTask?.cancel()
        pendingAssistantBottomSnapTask = nil
        progressiveTailRevealTask?.cancel()
        progressiveTailRevealTask = nil
        isProgressivelyRevealingRecentTail = false
        autoScrollMode = TurnScrollStateTracker.modeAfterUserDragBegan(currentMode: autoScrollMode)
    }

    // Preserves user-controlled deceleration for a short cooldown before auto-follow can resume.
    private func handleUserScrollDragEnded() {
        isUserDraggingScroll = false
        userScrollCooldownUntil = TurnScrollStateTracker.cooldownDeadline()
        autoScrollMode = TurnScrollStateTracker.modeAfterUserDragEnded(
            currentMode: autoScrollMode,
            isScrolledToBottom: isScrolledToBottom
        )
    }

    // Mirrors user-driven scroll phases without pausing auto-follow during programmatic animations.
    private func handleScrollPhaseChange(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        switch newPhase {
        case .tracking, .interacting:
            handleUserScrollDragChanged()
        case .decelerating:
            let wasUserTouchingScroll = oldPhase == .tracking || oldPhase == .interacting
            if wasUserTouchingScroll {
                handleUserScrollDragEnded()
            }
        case .idle:
            let wasUserTouchingScroll = oldPhase == .tracking || oldPhase == .interacting
            if wasUserTouchingScroll {
                handleUserScrollDragEnded()
            }
        case .animating:
            return
        @unknown default:
            return
        }
    }

    // Repairs the initial white/blank viewport race by snapping to bottom multiple
    // times with increasing delays until the full VStack layout has settled.
    private func performInitialRecoverySnapIfNeeded(using proxy: ScrollViewProxy) {
        guard initialRecoverySnapPendingThreadID == threadID,
              initialRecoverySnapTask == nil,
              !messages.isEmpty,
              viewportHeight > 0,
              autoScrollMode == .followBottom,
              !shouldPauseAutomaticScrolling,
              !shouldAnchorToAssistantResponse else {
            return
        }

        let expectedThreadID = threadID
        // Delays in nanoseconds: yield, 16ms, 50ms, 100ms — covers typical layout settle times.
        let snapDelays: [UInt64] = [0, 16_000_000, 50_000_000, 100_000_000]
        initialRecoverySnapTask = Task { @MainActor in
            for delay in snapDelays {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(nanoseconds: delay)
                }

                guard !Task.isCancelled,
                      initialRecoverySnapPendingThreadID == expectedThreadID,
                      scrollSessionThreadID == expectedThreadID,
                      !messages.isEmpty,
                      viewportHeight > 0,
                      autoScrollMode == .followBottom,
                      !shouldPauseAutomaticScrolling,
                      !shouldAnchorToAssistantResponse else {
                    break
                }

                scrollToBottom(using: proxy, animated: false)
            }
            let shouldKeepRecoveryPending = !initialTurnsLoaded
                && isInitialEarlierPageLoading
                && autoScrollMode == .followBottom
                && !shouldPauseAutomaticScrolling
            if !shouldKeepRecoveryPending {
                initialRecoverySnapPendingThreadID = nil
            }
            initialRecoverySnapTask = nil
        }
    }

    private func anchorToAssistantResponseIfNeeded(using proxy: ScrollViewProxy) -> Bool {
        guard shouldAnchorToAssistantResponse,
              let assistantMessageID = TurnTimelineReducer.assistantResponseAnchorMessageID(
                in: Array(visibleMessages),
                activeTurnID: activeTurnID
              ) else {
            return false
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(assistantMessageID, anchor: .top)
        }
        // Break the .onChange chain by deferring the binding write to avoid
        // AttributeGraph cycles when the parent re-renders in response.
        DispatchQueue.main.async {
            shouldAnchorToAssistantResponse = false
        }
        autoScrollMode = .followBottom
        initialRecoverySnapPendingThreadID = nil
        pendingAssistantBottomSnapTask?.cancel()
        pendingAssistantBottomSnapTask = nil
        return true
    }

    // Keep mutation handling narrow so scroll geometry remains the follow-bottom source of truth.
    private func handleTimelineMutation(using proxy: ScrollViewProxy) {
        guard !shouldPauseAutomaticScrolling else { return }
        performInitialRecoverySnapIfNeeded(using: proxy)

        if autoScrollMode == .anchorAssistantResponse {
            if !anchorToAssistantResponseIfNeeded(using: proxy),
               shouldShowPendingAssistantResponse {
                // The assistant row does not exist yet; keep the optimistic user
                // bubble and pending thinking indicator anchored at the bottom.
                schedulePendingAssistantBottomSnap(using: proxy)
            }
        }
    }

    // The user row and sticky thinking indicator can appear one layout pass before the
    // assistant row exists; defer the bottom snap until that provisional stack is measurable.
    private func schedulePendingAssistantBottomSnap(using proxy: ScrollViewProxy) {
        guard pendingAssistantBottomSnapTask == nil else { return }
        let expectedThreadID = threadID
        let snapDelays: [UInt64] = [0, 16_000_000, 50_000_000]
        pendingAssistantBottomSnapTask = Task { @MainActor in
            defer { pendingAssistantBottomSnapTask = nil }
            for delay in snapDelays {
                if delay == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(nanoseconds: delay)
                }

                guard !Task.isCancelled,
                      scrollSessionThreadID == expectedThreadID,
                      autoScrollMode == .anchorAssistantResponse,
                      shouldShowPendingAssistantResponse,
                      !shouldPauseAutomaticScrolling else {
                    return
                }

                scrollToBottom(using: proxy, animated: delay != 0)
            }
        }
    }

    /// Coalesces rapid follow-bottom scrolls into at most one per display frame,
    /// preventing discrete jumps on every streaming delta.
    private func scheduleFollowBottomScroll(using proxy: ScrollViewProxy) {
        guard followBottomScrollTask == nil else { return }
        let expectedThreadID = threadID
        followBottomScrollTask = Task { @MainActor in
            defer { followBottomScrollTask = nil }
            try? await Task.sleep(nanoseconds: 16_000_000) // ~1 display frame
            guard !Task.isCancelled,
                  scrollSessionThreadID == expectedThreadID,
                  !shouldPauseAutomaticScrolling else {
                return
            }
            guard autoScrollMode == .followBottom || shouldPinTimelineToBottomDuringGeometryChange else {
                return
            }
            proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
        }
    }

    private var shouldPauseAutomaticScrolling: Bool {
        TurnScrollStateTracker.isAutomaticScrollingPaused(
            isUserDragging: isUserDraggingScroll,
            cooldownUntil: userScrollCooldownUntil
        )
    }

    // Follow-bottom owns bottom pinning; assistant anchoring waits for a real assistant row
    // so a new chat's first user bubble is not snapped around by geometry changes.
    private var shouldPinTimelineToBottomDuringGeometryChange: Bool {
        return TurnScrollStateTracker.shouldPinDuringGeometryChange(
            currentMode: autoScrollMode,
            isAutomaticScrollingPaused: shouldPauseAutomaticScrolling
        )
    }

    // Scrolls to the bottom sentinel; used by manual jump button and initial recovery snap.
    // Streaming follow-bottom uses the throttled scheduleFollowBottomScroll instead.
    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        guard !messages.isEmpty else { return }

        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
        }
    }

    /// Single deferred commit for all scroll-geometry–driven state changes.
    /// Called once per runloop turn by the coalescer.
    private func applyScrollGeometryUpdate(
        old: ScrollBottomGeometry,
        new: ScrollBottomGeometry,
        using proxy: ScrollViewProxy
    ) {
        let isSuppressingBottomCorrectionsForWarmup = isRecentTailWarmupActive
            && autoScrollMode == .followBottom
        let viewportHeightChanged = new.viewportHeight > 0
            && abs(new.viewportHeight - old.viewportHeight) > 2
        let shouldPinToBottom = shouldPinTimelineToBottomDuringGeometryChange
        let shouldScheduleFollowBottom = viewportHeightChanged
            && shouldPinToBottom
            && !isSuppressingBottomCorrectionsForWarmup
        let shouldCorrectForContentHeight = !isSuppressingBottomCorrectionsForWarmup
            && TurnScrollStateTracker.shouldCorrectBottomAfterContentHeightChange(
                previousHeight: old.contentHeight,
                newHeight: new.contentHeight,
                isPinnedToBottom: shouldPinToBottom
            )
        let bottomChanged = new.isAtBottom != old.isAtBottom
            && !(isSuppressingBottomCorrectionsForWarmup && !new.isAtBottom)
        let nextViewportHeight = new.viewportHeight

        Task { @MainActor in
            if nextViewportHeight > 0, abs(nextViewportHeight - viewportHeight) > 1 {
                viewportHeight = nextViewportHeight
                performInitialRecoverySnapIfNeeded(using: proxy)
            }
            if shouldScheduleFollowBottom || shouldCorrectForContentHeight {
                scheduleFollowBottomScroll(using: proxy)
            }
            if bottomChanged {
                handleScrolledToBottomChanged(new.isAtBottom)
            }
        }
        debugTimelineLog(
            "applyScrollGeometryUpdate oldBottom=\(old.isAtBottom) newBottom=\(new.isAtBottom) "
                + "oldViewport=\(Int(old.viewportHeight)) newViewport=\(Int(new.viewportHeight)) "
                + "oldContent=\(Int(old.contentHeight)) newContent=\(Int(new.contentHeight)) "
                + "pinned=\(shouldPinTimelineToBottomDuringGeometryChange) "
                + "warmupSuppressed=\(isSuppressingBottomCorrectionsForWarmup) "
                + "userDragging=\(isUserDraggingScroll)"
        )
    }

    // Scroll callbacks hit this often; keep logging fully lazy and non-mutating.
    private func debugTimelineLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard Self.isTimelineDebugLoggingEnabled else { return }
        print("[TimelineDebug] \(message())")
        #endif
    }
}

private extension TurnTimelineView {
    static var isTimelineDebugLoggingEnabled: Bool { false }
}

// Keeps scroll-specific observers out of the main SwiftUI body so type-checking stays predictable.
private struct TurnTimelineScrollObserverModifier: ViewModifier {
    let isGeometryTrackingEnabled: Bool
    let onTapOutsideComposer: () -> Void
    let onScrollPhaseChange: (ScrollPhase, ScrollPhase) -> Void
    let onScrollGeometryChange: (ScrollBottomGeometry, ScrollBottomGeometry) -> Void

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    onTapOutsideComposer()
                }
            )
            // Track real scroll phases instead of layering a competing drag gesture on top.
            .onScrollPhaseChange { oldPhase, newPhase in
                onScrollPhaseChange(oldPhase, newPhase)
            }
            .onScrollGeometryChange(for: ScrollBottomGeometry.self) { geometry in
                ScrollBottomGeometry.from(geometry)
            } action: { old, new in
                guard isGeometryTrackingEnabled else { return }
                onScrollGeometryChange(old, new)
            }
    }
}

// Coalesces high-frequency observer callbacks without mutating SwiftUI state from onChange.
private final class MainQueueUpdateCoalescer {
    private var isScheduled = false
    private var pendingAction: (() -> Void)?

    func schedule(_ action: @escaping () -> Void) {
        pendingAction = action
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let action = pendingAction
            pendingAction = nil
            isScheduled = false
            action?()
        }
    }
}

// Groups history/loading observers separately from rendering to avoid one huge ViewBuilder expression.
private struct TurnTimelineHistoryChangeHandlersModifier: ViewModifier {
    @State private var timelineChangeCoalescer = MainQueueUpdateCoalescer()

    let timelineChangeToken: Int
    let messageCount: Int
    let isLoadingRemoteEarlierMessages: Bool
    let initialTurnsLoaded: Bool
    let hasRemoteEarlierMessages: Bool
    let olderHistoryLoadErrorMessage: String?

    let onTimelineChange: () -> Void
    let onMessageCountChange: (Int, Int) -> Void
    let onRemoteEarlierLoadingChange: (Bool) -> Void
    let onInitialHistoryLoaded: () -> Void
    let onRemoteEarlierAvailabilityChange: (Bool) -> Void
    let onOlderHistoryErrorChange: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: timelineChangeToken) { _, _ in
                timelineChangeCoalescer.schedule(onTimelineChange)
            }
            .onChange(of: messageCount) { oldCount, newCount in
                performAfterSwiftUIUpdate {
                    onMessageCountChange(oldCount, newCount)
                }
            }
            .onChange(of: isLoadingRemoteEarlierMessages) { _, newValue in
                performAfterSwiftUIUpdate {
                    onRemoteEarlierLoadingChange(newValue)
                }
            }
            .onChange(of: initialTurnsLoaded) { _, didLoad in
                if didLoad {
                    performAfterSwiftUIUpdate(onInitialHistoryLoaded)
                }
            }
            .onChange(of: hasRemoteEarlierMessages) { _, newValue in
                performAfterSwiftUIUpdate {
                    onRemoteEarlierAvailabilityChange(newValue)
                }
            }
            .onChange(of: olderHistoryLoadErrorMessage) { _, newValue in
                performAfterSwiftUIUpdate {
                    onOlderHistoryErrorChange(newValue)
                }
            }
    }

    private func performAfterSwiftUIUpdate(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }
}

// Keeps render/turn-state observers in a second small modifier for faster SwiftUI type-checking.
private struct TurnTimelineRenderChangeHandlersModifier: ViewModifier {
    let isThreadRunning: Bool
    let isSendInFlight: Bool
    let threadID: String
    let activeTurnID: String?
    let latestTurnTerminalState: CodexTurnTerminalState?
    let completedTurnIDs: Set<String>
    let stoppedTurnIDs: Set<String>
    let visibleTailCount: Int
    let shouldAnchorToAssistantResponse: Bool

    let onThreadRunningChange: () -> Void
    let onSendInFlightChange: () -> Void
    let onThreadIDChange: () -> Void
    let onActiveTurnIDChange: () -> Void
    let onTerminalStateChange: () -> Void
    let onCompletedTurnIDsChange: () -> Void
    let onStoppedTurnIDsChange: () -> Void
    let onVisibleTailCountChange: () -> Void
    let onAssistantAnchorChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isThreadRunning) { _, _ in
                performAfterSwiftUIUpdate(onThreadRunningChange)
            }
            .onChange(of: isSendInFlight) { _, _ in
                performAfterSwiftUIUpdate(onSendInFlightChange)
            }
            .onChange(of: threadID) { _, _ in
                performAfterSwiftUIUpdate(onThreadIDChange)
            }
            .onChange(of: activeTurnID) { _, _ in
                performAfterSwiftUIUpdate(onActiveTurnIDChange)
            }
            .onChange(of: latestTurnTerminalState) { _, _ in
                performAfterSwiftUIUpdate(onTerminalStateChange)
            }
            .onChange(of: completedTurnIDs) { _, _ in
                performAfterSwiftUIUpdate(onCompletedTurnIDsChange)
            }
            .onChange(of: stoppedTurnIDs) { _, _ in
                performAfterSwiftUIUpdate(onStoppedTurnIDsChange)
            }
            .onChange(of: visibleTailCount) { _, _ in
                performAfterSwiftUIUpdate(onVisibleTailCountChange)
            }
            .onChange(of: shouldAnchorToAssistantResponse) { _, newValue in
                performAfterSwiftUIUpdate {
                    onAssistantAnchorChange(newValue)
                }
            }
    }

    private func performAfterSwiftUIUpdate(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }
}
