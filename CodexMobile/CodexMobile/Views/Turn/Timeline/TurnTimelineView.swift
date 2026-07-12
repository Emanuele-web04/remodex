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

struct TurnTimelineView<EmptyState: View, Composer: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let threadID: String
    let messages: [CodexMessage]
    let timelineChangeToken: Int
    let activeTurnID: String?
    let isThreadRunning: Bool
    let runStartGeneration: Int
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

    @Binding var isAwaitingAssistantResponse: Bool
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
    private static var scrollGeometryCoalescingDelayNanoseconds: UInt64 { 16_000_000 }

    @State private var visibleTailCount: Int = initialVisibleTailCount
    @State private var isScrolledToBottom = true
    @State private var renderCacheState = TurnTimelineRenderCacheState()
    @State private var scrollSessionThreadID: String?
    @State private var autoScrollMode: TurnScrollOwnership = .followBottom
    @State private var progressiveTailRevealTask: Task<Void, Never>?
    @State private var isProgressivelyRevealingRecentTail = false
    @State private var isUserTouchingScroll = false
    @State private var pendingRemoteEarlierLoadMessageCount: Int?
    @State private var isLocalEarlierRevealPending = false
    @State private var isRetryingEarlierHistoryLoad = false
    @State private var localEarlierRevealTask: Task<Void, Never>?
    @State private var scrollGeometryCoalescer = ScrollGeometryCoalescer()
    @State private var nativeScrollController = TurnTimelineNativeScrollController()

    /// The service supplies paginated render windows; legacy full-history threads still slice locally.
    private var visibleMessages: ArraySlice<CodexMessage> {
        if usesPaginatedHistory
            || hasLiveTurnEvidence
            || shouldOpenAtLiveTail {
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
                            showsGlobalRunningIndicator: shouldShowTimelineRunningIndicator,
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
                        .background(
                            VerticalScrollAxisGuard(
                                nativeScrollController: nativeScrollController
                            )
                        )
                        .padding(.top, 12)
                        .padding(.bottom, 12)

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
                    .overlay {
                        if shouldShowFullTimelineLoader {
                            timelineLoadingOverlay
                        }
                    }
                    .frame(width: viewport.size.width)
                    // Each conversation gets a fresh native scroll session, so
                    // initialOffset cannot inherit deceleration or offset from another chat.
                    .id(threadID)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    // While following the stream, anchor content-size growth to the bottom so the
                    // scroll view keeps the newest line pinned natively (GPU-driven, no per-frame
                    // scrollTo chase). When the user has scrolled up to read, anchor to the top so
                    // incoming content grows below their position without yanking them around.
                    .defaultScrollAnchor(sizeChangeScrollAnchor, for: .sizeChanges)
                    .modifier(
                        TurnTimelineScrollObserverModifier(
                            onTapOutsideComposer: onTapOutsideComposer,
                            onScrollPhaseChange: { oldPhase, newPhase in
                                handleScrollPhaseChange(from: oldPhase, to: newPhase, using: proxy)
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
                        StreamingUIInteractionMonitor.setScrollInteractionActive(false)
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
        var materializedVisible: [CodexMessage]?
        var projectionResult: TurnTimelineRenderProjection.Result?
        var nextState = renderCacheState
        var didChange = false
        let shapeSignature = renderItemsShapeSignature(for: visibleSlice)

        func visibleMessagesArray() -> [CodexMessage] {
            if let materializedVisible {
                return materializedVisible
            }
            let visible = Array(visibleSlice)
            materializedVisible = visible
            return visible
        }

        // Block-info placement depends on collapsed render items, so keep the
        // projection fresh before deriving accessory state.
        if rebuildRenderItems || rebuildBlockInfo {
            let signature = renderItemsCacheSignature(for: visibleSlice)
            if signature != nextState.renderItemsSignature {
                let result = TurnTimelineRenderProjection.result(
                    messages: visibleMessagesArray(),
                    completedTurnIDs: completedTurnIDs,
                    activeTurnID: activeTurnID,
                    isThreadRunning: isThreadRunning
                )
                projectionResult = result
                nextState.visibleRenderItems = result.renderItems
                nextState.renderItemsSignature = signature
                nextState.renderItemsShapeSignature = shapeSignature
                didChange = true
            }
        }

        if rebuildBlockInfo {
            let key = blockInfoInputKey(for: visibleSlice)
            if nextState.blockInfoInputKey != key {
                nextState.blockInfoInputKey = key
                let visible = visibleMessagesArray()

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
                let collapseMetadata = projectionResult?.metadata ?? TurnTimelineRenderProjection.collapseMetadata(
                    in: visible,
                    completedTurnIDs: completedTurnIDs,
                    activeTurnID: activeTurnID,
                    isThreadRunning: isThreadRunning
                )
                let updated = Self.rehomeCollapsedFinalAccessoryStates(
                    initialBlockInfoByMessageID,
                    messages: visible,
                    collapsedFinalMessageIDs: collapseMetadata.collapsedFinalMessageIDs,
                    hiddenMessageIDs: collapseMetadata.collapsedPreviousMessageIDs
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
    private func blockInfoInputKey(for messages: ArraySlice<CodexMessage>) -> Int {
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
            isScrolledToBottom: isScrolledToBottom,
            ownership: autoScrollMode
        )
    }

    private var shouldOpenAtLiveTail: Bool {
        TurnScrollStateTracker.shouldOpenAtLiveTail(
            isSendInFlight: isSendInFlight
        )
    }

    // Keep all rows for a running/recovered turn so live growth cannot land
    // outside the rendered window. This is deliberately separate from the
    // local-send tail policy below.
    private var hasLiveTurnEvidence: Bool {
        TurnScrollStateTracker.hasLiveTurnEvidence(
            isThreadRunning: isThreadRunning,
            activeTurnID: activeTurnID,
            // Live rows often arrive before thread/read has rehydrated the
            // explicit running fields during a fast sidebar switch.
            hasStreamingTail: messages.suffix(12).contains(where: \.isStreaming)
        )
    }

    // Native content-growth anchor: bottom while actively following the stream (so growth pins
    // the newest line without a manual chase), top otherwise so reading history stays put.
    private var sizeChangeScrollAnchor: UnitPoint {
        shouldPinTimelineToBottomDuringGeometryChange ? .bottom : .top
    }

    private var shouldShowPendingAssistantResponse: Bool {
        TurnTimelinePendingAssistantState.isWaitingForAssistantResponse(
            isAwaitingAssistantResponse: isAwaitingAssistantResponse,
            messages: messages
        )
    }

    // Keep the thinking row rendered as the last timeline row for the whole run,
    // even while assistant prose and late tool rows stream in above it.
    private var shouldShowTimelineRunningIndicator: Bool {
        TurnTimelinePendingAssistantState.shouldShowIndicator(
            isRunStartingOrRunning: isRunStartingOrRunning
        )
    }

    // Scroll geometry resumes after the optimistic send gap resolves to a real assistant row.
    private var shouldTrackScrollGeometry: Bool {
        TurnTimelinePendingAssistantState.shouldTrackScrollGeometry(
            isAwaitingAssistantResponse: isAwaitingAssistantResponse,
            autoScrollMode: autoScrollMode,
            isWaitingForAssistantResponse: shouldShowPendingAssistantResponse
        )
    }

    private func handleLoadEarlierMessages() {
        guard !isEarlierHistoryInteractionActive else {
            return
        }

        // Loading older history is explicit user ownership of the viewport.
        isAwaitingAssistantResponse = false
        transitionScrollOwnership(.loadEarlier)
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
        nativeScrollController.cancelUserMomentum()
        isAwaitingAssistantResponse = false
        transitionScrollOwnership(.jumpToLatest)
        isUserTouchingScroll = false
        // Drop a queued pre-tap geometry commit and let app ownership maintain
        // the bottom if the animated jump initially lands short.
        scrollGeometryCoalescer.cancel()
        scrollGeometryCoalescer.markLatestObservedNotAtBottom()
        isScrolledToBottom = true
        scheduleFollowBottomScroll(
            using: proxy,
            delayNanoseconds: 0,
            animation: .easeInOut(duration: 0.2)
        )
    }

    private func transitionScrollOwnership(_ event: TurnScrollEvent) {
        autoScrollMode = TurnScrollStateTracker.ownership(
            after: event,
            current: autoScrollMode
        )
    }

    // Resets per-thread ownership. The keyed ScrollView applies its native
    // initial bottom anchor; later layout growth is repaired by the same
    // follow-bottom invariant used for streaming.
    private func beginScrollSessionIfNeeded(force: Bool = false) {
        guard force || scrollSessionThreadID != threadID else { return }

        cancelScrollTasks()
        scrollSessionThreadID = threadID
        visibleTailCount = shouldStageHeavyThreadOpen
            ? Self.initialWarmTailCount
            : min(messages.count, Self.initialVisibleTailCount)
        isScrolledToBottom = true
        isUserTouchingScroll = false
        pendingRemoteEarlierLoadMessageCount = nil
        isLocalEarlierRevealPending = false
        isRetryingEarlierHistoryLoad = false
        localEarlierRevealTask?.cancel()
        localEarlierRevealTask = nil
        transitionScrollOwnership(
            .conversationOpened(isAwaitingAssistantResponse: isAwaitingAssistantResponse)
        )
        isProgressivelyRevealingRecentTail = shouldStageHeavyThreadOpen
    }

    // Cancels any delayed scroll work so old thread sessions cannot move the new one.
    private func cancelScrollTasks() {
        scrollGeometryCoalescer.cancel()
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

    // Timeline mutations still drive block-info refresh and pending-response resolution,
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
            runStartGeneration: runStartGeneration,
            latestTurnTerminalState: latestTurnTerminalState,
            completedTurnIDs: completedTurnIDs,
            stoppedTurnIDs: stoppedTurnIDs,
            visibleTailCount: visibleTailCount,
            isAwaitingAssistantResponse: isAwaitingAssistantResponse,
            onThreadRunningChange: { handleThreadRunningChange(using: proxy) },
            onSendInFlightChange: { handleSendInFlightChange(using: proxy) },
            onThreadIDChange: { handleThreadIDChange(using: proxy) },
            onActiveTurnIDChange: { handleActiveTurnIDChange(using: proxy) },
            onRunStartGenerationChange: { handleRunStartGenerationChange(using: proxy) },
            onTerminalStateChange: { handleTerminalStateChange(using: proxy) },
            onCompletedTurnIDsChange: { handleCompletedTurnIDsChange(using: proxy) },
            onStoppedTurnIDsChange: { handleStoppedTurnIDsChange(using: proxy) },
            onVisibleTailCountChange: handleVisibleTailCountChange,
            onAwaitingAssistantResponseChange: { handleAwaitingAssistantResponseChange($0, using: proxy) }
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
        // Run-state changes toggle the in-timeline running indicator row before
        // the first assistant item exists, so treat them like a timeline mutation.
        recomputeRenderItemsAndBlockInfoIfNeeded()
        handleTimelineMutation(using: proxy)
    }

    private func handleSendInFlightChange(using proxy: ScrollViewProxy) {
        debugTimelineLog("isSendInFlight changed value=\(isSendInFlight)")
        if isSendInFlight {
            transitionScrollOwnership(
                .sendBegan(isAwaitingAssistantResponse: isAwaitingAssistantResponse)
            )
            isScrolledToBottom = true
            if !isAwaitingAssistantResponse {
                scrollToBottom(using: proxy)
            }
        }
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
        recomputeRenderItemsAndBlockInfoIfNeeded()
        handleTimelineMutation(using: proxy)
    }

    private func handleRunStartGenerationChange(using proxy: ScrollViewProxy) {
        debugTimelineLog("runStartGeneration changed value=\(runStartGeneration)")
        recomputeRenderItemsAndBlockInfoIfNeeded()
        handleTimelineMutation(using: proxy)
    }

    private func handleTerminalStateChange(using proxy: ScrollViewProxy) {
        debugTimelineLog("latestTurnTerminalState changed to=\(String(describing: latestTurnTerminalState))")
        recomputeBlockInfoIfNeeded()
    }

    private func handleCompletedTurnIDsChange(using proxy: ScrollViewProxy) {
        debugTimelineLog("completedTurnIDs changed count=\(completedTurnIDs.count)")
        recomputeRenderItemsAndBlockInfoIfNeeded()
    }

    private func handleStoppedTurnIDsChange(using proxy: ScrollViewProxy) {
        debugTimelineLog("stoppedTurnIDs changed count=\(stoppedTurnIDs.count)")
        recomputeBlockInfoIfNeeded()
    }

    private func handleVisibleTailCountChange() {
        debugTimelineLog("visibleTailCount changed value=\(visibleTailCount) totalMessages=\(messages.count)")
        recomputeRenderItemsAndBlockInfoIfNeeded()
    }

    private func handleAwaitingAssistantResponseChange(_ newValue: Bool, using proxy: ScrollViewProxy) {
        if newValue {
            transitionScrollOwnership(.assistantResponseRequested)
            handleTimelineMutation(using: proxy)
        } else if autoScrollMode == .awaitingAssistantResponse {
            let effectiveBottom = TurnScrollStateTracker.effectiveBottomState(
                committedIsAtBottom: isScrolledToBottom,
                latestObservedIsAtBottom: scrollGeometryCoalescer.latestObservedIsAtBottom
            )
            isScrolledToBottom = effectiveBottom
            transitionScrollOwnership(.assistantResponseCleared(isAtBottom: effectiveBottom))
        }
    }

    // Initial history hydration is just another app-owned timeline mutation.
    // The bottom invariant repairs any post-hydration geometry drift.
    private func handleInitialHistoryLoaded(using proxy: ScrollViewProxy) {
        guard scrollSessionThreadID == threadID,
              !messages.isEmpty,
              !isAwaitingAssistantResponse,
              !shouldPauseAutomaticScrolling else {
            return
        }
        handleTimelineMutation(using: proxy)
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

    // Coalesces scroll geometry into a small helper so the SwiftUI modifier chain stays type-checkable.
    private func handleScrollGeometryChange(
        old: ScrollBottomState,
        new: ScrollBottomState,
        using proxy: ScrollViewProxy
    ) {
        // Physical observation stays current even while the first response is pending.
        // The gate below suppresses SwiftUI commits; geometry never transfers ownership.
        scrollGeometryCoalescer.observe(new)
        guard shouldTrackScrollGeometry else { return }

        // Coalesce into a single commit per display-frame window so SwiftUI
        // does not receive several geometry-driven state mutations per frame.
        scrollGeometryCoalescer.record(old: old, new: new)
        debugTimelineLog("geometry change scheduled for frame coalesced apply")
        scrollGeometryCoalescer.scheduleApply(
            after: Self.scrollGeometryCoalescingDelayNanoseconds
        ) { old, new in
            applyScrollGeometryUpdate(
                old: old,
                new: new,
                using: proxy
            )
        }
    }

    // Records physical position only. Ownership changes exclusively through
    // explicit reducer events, never because layout temporarily moved the bottom.
    private func handleScrolledToBottomChanged(_ nextValue: Bool) {
        guard nextValue != isScrolledToBottom else { return }
        isScrolledToBottom = nextValue
        if nextValue {
            scheduleProgressiveTailRevealIfNeeded()
        }
    }

    // Touch-down pauses queued corrections without claiming user ownership until
    // ScrollPhase confirms an actual interaction.
    private func handleUserScrollTrackingBegan() {
        isUserTouchingScroll = true
        scrollGeometryCoalescer.cancelFollowBottom()
    }

    private func handleUserScrollInteractionBegan() {
        isUserTouchingScroll = true
        isAwaitingAssistantResponse = false
        scrollGeometryCoalescer.cancelFollowBottom()
        progressiveTailRevealTask?.cancel()
        progressiveTailRevealTask = nil
        isProgressivelyRevealingRecentTail = false
        transitionScrollOwnership(.userInteractionBegan)
    }

    // Finalizes ownership only after deceleration reaches idle, so a flick that
    // naturally lands at the bottom can re-enable follow mode.
    private func handleUserScrollInteractionEnded(using proxy: ScrollViewProxy) {
        isUserTouchingScroll = false
        let effectiveBottom = TurnScrollStateTracker.effectiveBottomState(
            committedIsAtBottom: isScrolledToBottom,
            latestObservedIsAtBottom: scrollGeometryCoalescer.latestObservedIsAtBottom
        )
        isScrolledToBottom = effectiveBottom
        transitionScrollOwnership(.userInteractionEnded(isAtBottom: effectiveBottom))
        handleTimelineMutation(using: proxy)
    }

    // Mirrors user-driven scroll phases without pausing auto-follow during programmatic animations.
    private func handleScrollPhaseChange(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        using proxy: ScrollViewProxy
    ) {
        updateStreamingInteractionMonitor(from: oldPhase, to: newPhase)
        switch newPhase {
        case .tracking:
            handleUserScrollTrackingBegan()
        case .interacting:
            handleUserScrollInteractionBegan()
        case .decelerating:
            if oldPhase == .tracking, autoScrollMode != .user {
                // Defensive fallback for a direct tracking -> decelerating phase
                // transition: deceleration itself proves a user-owned gesture.
                handleUserScrollInteractionBegan()
            }
            isUserTouchingScroll = false
        case .idle:
            if oldPhase == .tracking || oldPhase == .interacting || oldPhase == .decelerating {
                handleUserScrollInteractionEnded(using: proxy)
            }
        case .animating:
            return
        @unknown default:
            return
        }
    }

    // Heavy streaming row flushes back off while a user drag/flick owns the main thread.
    // Deceleration keeps the backoff (hitches are just as visible there); programmatic
    // animations and idle release it.
    private func updateStreamingInteractionMonitor(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        switch newPhase {
        case .tracking, .interacting:
            StreamingUIInteractionMonitor.setScrollInteractionActive(true)
        case .decelerating:
            let wasUserTouchingScroll = oldPhase == .tracking || oldPhase == .interacting
            if !wasUserTouchingScroll {
                StreamingUIInteractionMonitor.setScrollInteractionActive(false)
            }
        case .idle, .animating:
            StreamingUIInteractionMonitor.setScrollInteractionActive(false)
        @unknown default:
            StreamingUIInteractionMonitor.setScrollInteractionActive(false)
        }
    }

    private func resolveAssistantResponseIfNeeded(using proxy: ScrollViewProxy) -> Bool {
        guard isAwaitingAssistantResponse,
              TurnTimelineReducer.assistantResponseMessageID(
                in: Array(visibleMessages),
                activeTurnID: activeTurnID
              ) != nil else {
            return false
        }

        let expectedThreadID = threadID
        // The assistant row only resolves the pending-send state. It never becomes a top
        // scroll target: the whole live turn remains bottom-owned from send through completion.
        transitionScrollOwnership(.assistantResponseResolved)
        let effectiveBottom = TurnScrollStateTracker.effectiveBottomState(
            committedIsAtBottom: isScrolledToBottom,
            latestObservedIsAtBottom: scrollGeometryCoalescer.latestObservedIsAtBottom
        )
        isScrolledToBottom = effectiveBottom
        if !effectiveBottom {
            scheduleFollowBottomScroll(using: proxy)
        }
        // Defer the parent binding write to avoid mutating the observation graph
        // from inside the timeline-change callback that discovered the row.
        DispatchQueue.main.async {
            guard scrollSessionThreadID == expectedThreadID,
                  autoScrollMode == .followBottom else { return }
            isAwaitingAssistantResponse = false
        }
        return true
    }

    // One mutation path maintains whichever target currently belongs to the app.
    private func handleTimelineMutation(using proxy: ScrollViewProxy) {
        guard !shouldPauseAutomaticScrolling else { return }

        if autoScrollMode == .awaitingAssistantResponse {
            if !resolveAssistantResponseIfNeeded(using: proxy),
               shouldShowPendingAssistantResponse {
                // Until the response row exists, the optimistic user row and
                // thinking indicator are the current app-owned bottom target.
                scheduleFollowBottomScroll(using: proxy)
            }
        } else if autoScrollMode == .followBottom, !isScrolledToBottom {
            scheduleFollowBottomScroll(using: proxy)
        }
    }

    /// Coalesces rapid follow-bottom corrections without invalidating the SwiftUI tree.
    /// Native size-change anchoring handles smooth streaming; this fallback is an
    /// understated one-shot animation whose lock survives until logical completion.
    private func scheduleFollowBottomScroll(
        using proxy: ScrollViewProxy,
        delayNanoseconds: UInt64 = 16_000_000,
        animation: Animation = .smooth(duration: 0.12, extraBounce: 0)
    ) {
        let expectedThreadID = threadID
        scrollGeometryCoalescer.scheduleFollowBottom(after: delayNanoseconds) { completion in
            guard scrollSessionThreadID == expectedThreadID,
                  !shouldPauseAutomaticScrolling else {
                completion()
                return
            }
            guard shouldPinTimelineToBottomDuringGeometryChange else {
                completion()
                return
            }
            withAnimation(
                animation,
                completionCriteria: .logicallyComplete
            ) {
                proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
            } completion: {
                completion()
            }
        }
    }

    private var shouldPauseAutomaticScrolling: Bool {
        isUserTouchingScroll
    }

    // Both live-follow states own bottom pinning; the pending-response state only waits
    // for a real assistant row and never introduces a second scroll target.
    private var shouldPinTimelineToBottomDuringGeometryChange: Bool {
        TurnScrollStateTracker.shouldPinDuringGeometryChange(
            ownership: autoScrollMode,
            isAutomaticScrollingPaused: shouldPauseAutomaticScrolling
        )
    }

    // Immediate send-time placement; animated follow corrections use the
    // completion-held single-flight path above.
    private func scrollToBottom(using proxy: ScrollViewProxy) {
        guard !messages.isEmpty else { return }
        proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
    }

    /// Single deferred commit for all scroll-geometry–driven state changes.
    /// Called once per runloop turn by the coalescer.
    private func applyScrollGeometryUpdate(
        old: ScrollBottomState,
        new: ScrollBottomState,
        using proxy: ScrollViewProxy
    ) {
        let isSuppressingBottomCorrectionsForWarmup = isRecentTailWarmupActive
            && autoScrollMode == .followBottom
        let shouldScheduleFollowBottom = TurnScrollStateTracker.shouldCorrectObservedBottomDrift(
            observedIsAtBottom: new.isAtBottom,
            ownership: autoScrollMode,
            isAutomaticScrollingPaused: shouldPauseAutomaticScrolling
        )
            && !isSuppressingBottomCorrectionsForWarmup
        let bottomChanged = TurnScrollStateTracker.shouldReconcileBottomState(
            observedIsAtBottom: new.isAtBottom,
            committedIsAtBottom: isScrolledToBottom,
            isSuppressingNotBottom: isSuppressingBottomCorrectionsForWarmup
        )
        if shouldScheduleFollowBottom {
            scheduleFollowBottomScroll(using: proxy)
        }
        if bottomChanged {
            handleScrolledToBottomChanged(new.isAtBottom)
        }
        debugTimelineLog(
            "applyScrollGeometryUpdate oldBottom=\(old.isAtBottom) newBottom=\(new.isAtBottom) "
                + "pinned=\(shouldPinTimelineToBottomDuringGeometryChange) "
                + "warmupSuppressed=\(isSuppressingBottomCorrectionsForWarmup) "
                + "userTouching=\(isUserTouchingScroll)"
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
    let onTapOutsideComposer: () -> Void
    let onScrollPhaseChange: (ScrollPhase, ScrollPhase) -> Void
    let onScrollGeometryChange: (ScrollBottomState, ScrollBottomState) -> Void

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
            .onScrollGeometryChange(for: ScrollBottomState.self) { geometry in
                ScrollBottomState.from(geometry)
            } action: { old, new in
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
    let runStartGeneration: Int
    let latestTurnTerminalState: CodexTurnTerminalState?
    let completedTurnIDs: Set<String>
    let stoppedTurnIDs: Set<String>
    let visibleTailCount: Int
    let isAwaitingAssistantResponse: Bool

    let onThreadRunningChange: () -> Void
    let onSendInFlightChange: () -> Void
    let onThreadIDChange: () -> Void
    let onActiveTurnIDChange: () -> Void
    let onRunStartGenerationChange: () -> Void
    let onTerminalStateChange: () -> Void
    let onCompletedTurnIDsChange: () -> Void
    let onStoppedTurnIDsChange: () -> Void
    let onVisibleTailCountChange: () -> Void
    let onAwaitingAssistantResponseChange: (Bool) -> Void

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
            .onChange(of: runStartGeneration) { _, _ in
                performAfterSwiftUIUpdate(onRunStartGenerationChange)
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
            .onChange(of: isAwaitingAssistantResponse) { _, newValue in
                performAfterSwiftUIUpdate {
                    onAwaitingAssistantResponseChange(newValue)
                }
            }
    }

    private func performAfterSwiftUIUpdate(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }
}
