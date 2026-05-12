// FILE: TurnTimelineView.swift
// Purpose: Coordinates timeline scrolling, bottom-anchor behavior and render caches.
// Layer: View Component
// Exports: TurnTimelineView
// Depends on: SwiftUI, TurnTimelineRenderProjection, TurnTimelineReducer, TurnTimelineRows

import SwiftUI

struct TurnTimelineView<EmptyState: View, Composer: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let threadID: String
    let messages: [CodexMessage]
    let timelineChangeToken: Int
    let activeTurnID: String?
    let isThreadRunning: Bool
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
    @Binding var isScrolledToBottom: Bool
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
    private static var scrollToLatestButtonLift: CGFloat { 44 + 18 }
    private static var scrollGeometryCoalescingDelayNanoseconds: UInt64 { 16_000_000 }

    @State private var visibleTailCount: Int = initialVisibleTailCount
    @State private var viewportHeight: CGFloat = 0
    // Cached per-render artifacts to avoid O(n) recomputation inside the body.
    @State private var cachedBlockInfoByMessageID: [String: AssistantBlockAccessoryState] = [:]
    @State private var cachedNewestStreamingMessageID: String? = nil
    @State private var cachedRenderItems: [TurnTimelineRenderItem] = []
    @State private var cachedRenderItemsSignature: TurnTimelineRenderItemsCacheSignature?
    @State private var blockInfoInputKey: Int = 0
    @State private var scrollSessionThreadID: String?
    @State private var autoScrollMode: TurnAutoScrollMode = .followBottom
    @State private var initialRecoverySnapPendingThreadID: String?
    @State private var initialRecoverySnapTask: Task<Void, Never>?
    @State private var followBottomScrollTask: Task<Void, Never>?
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

    private var visibleRenderItems: [TurnTimelineRenderItem] {
        let signature = renderItemsCacheSignature(for: visibleMessages)
        if signature == cachedRenderItemsSignature {
            return cachedRenderItems
        }
        return TurnTimelineRenderProjection.project(
            messages: Array(visibleMessages),
            completedTurnIDs: completedTurnIDs
        )
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

    private var shouldShowFullTimelineLoader: Bool {
        shouldWarmRecentTailProgressively && visibleTailCount == 0
    }

    // Keeps larger accessibility text inside a slightly roomier gutter so assistant
    // prose does not read as edge-to-edge when Dynamic Type is bumped up.
    private var timelineHorizontalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 16
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
                            isRetryAvailable: isRetryAvailable,
                            cachedBlockInfoByMessageID: cachedBlockInfoByMessageID,
                            planSessionSource: planSessionSource,
                            allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                            completedTurnIDs: completedTurnIDs,
                            threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                            currentWorkingDirectory: currentWorkingDirectory,
                            planMatchingFingerprint: planMatchingFingerprint,
                            newestStreamingMessageID: cachedNewestStreamingMessageID,
                            autoScrollMode: autoScrollMode,
                            onRetryUserMessage: onRetryUserMessage,
                            onTapAssistantRevert: onTapAssistantRevert,
                            onTapSubagent: onTapSubagent,
                            onLoadEarlierMessages: handleLoadEarlierMessages
                        )
                        // SwiftUI can otherwise let a streaming text row report an
                        // over-wide ideal size, which makes the vertical timeline pan sideways.
                        .frame(width: contentWidth, alignment: .leading)
                        .padding(.horizontal, timelineHorizontalPadding)
                        .frame(width: viewport.size.width, alignment: .leading)
                        .clipped()
                        .background(VerticalScrollAxisGuard())
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
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.top, for: .sizeChanges)
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            onTapOutsideComposer()
                        }
                    )
                    // Track real scroll phases instead of layering a competing drag gesture on top.
	                    .onScrollPhaseChange { oldPhase, newPhase in
	                        debugTimelineLog("scroll phase changed old=\(String(describing: oldPhase)) new=\(String(describing: newPhase))")
	                        handleScrollPhaseChange(from: oldPhase, to: newPhase)
	                    }
	                    .onScrollGeometryChange(for: ScrollBottomGeometry.self) { geometry in
	                        ScrollBottomGeometry.from(geometry)
	                    } action: { old, new in
                        guard !isEarlierHistoryInteractionActive else { return }
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
                            guard !isEarlierHistoryInteractionActive else { return }
                            applyScrollGeometryUpdate(
                                old: pending.old,
                                new: pending.new,
                                using: proxy
                            )
                        }
                    }
                    // Timeline mutations still drive block-info refresh and assistant anchoring,
                    // but geometry decides when follow-bottom should actually fire.
                    .onChange(of: timelineChangeToken) { _, _ in
                        debugTimelineLog(
                            "timelineChangeToken changed token=\(timelineChangeToken) "
                                + "messageCount=\(messages.count) visibleTail=\(visibleTailCount)"
                        )
                        recomputeRenderItemsIfNeeded()
                        recomputeBlockInfoIfNeeded()
                        scheduleProgressiveTailRevealIfNeeded()
                        handleTimelineMutation(using: proxy)
                    }
                    .onChange(of: messages.count) { oldCount, newCount in
                        handleMessageCountChange(oldCount: oldCount, newCount: newCount)
                    }
                    .onChange(of: isLoadingRemoteEarlierMessages) { _, newValue in
                        handleRemoteEarlierLoadingChange(isLoading: newValue)
                    }
                    .onChange(of: hasRemoteEarlierMessages) { _, newValue in
                        if !newValue {
                            pendingRemoteEarlierLoadMessageCount = nil
                        }
                    }
                    .onChange(of: olderHistoryLoadErrorMessage) { _, newValue in
                        if newValue != nil {
                            pendingRemoteEarlierLoadMessageCount = nil
                        }
                    }
                    .onChange(of: isThreadRunning) { _, _ in
                        debugTimelineLog("isThreadRunning changed value=\(isThreadRunning)")
                        recomputeBlockInfoIfNeeded()
                    }
                    .onChange(of: threadID) { _, _ in
                        debugTimelineLog("threadID changed to=\(threadID)")
                        beginScrollSessionIfNeeded(force: true)
                        recomputeRenderItemsIfNeeded()
                        recomputeBlockInfoIfNeeded()
                        scheduleProgressiveTailRevealIfNeeded()
                        handleTimelineMutation(using: proxy)
                    }
                    .onChange(of: activeTurnID) { _, _ in
                        debugTimelineLog("activeTurnID changed to=\(activeTurnID ?? "nil")")
                        recomputeBlockInfoIfNeeded()
                        handleTimelineMutation(using: proxy)
                    }
                    .onChange(of: latestTurnTerminalState) { _, _ in
                        debugTimelineLog("latestTurnTerminalState changed to=\(String(describing: latestTurnTerminalState))")
                        recomputeBlockInfoIfNeeded()
                    }
                    .onChange(of: completedTurnIDs) { _, _ in
                        debugTimelineLog("completedTurnIDs changed count=\(completedTurnIDs.count)")
                        recomputeRenderItemsIfNeeded()
                        recomputeBlockInfoIfNeeded()
                    }
                    .onChange(of: stoppedTurnIDs) { _, _ in
                        debugTimelineLog("stoppedTurnIDs changed count=\(stoppedTurnIDs.count)")
                        recomputeBlockInfoIfNeeded()
                    }
                    .onChange(of: visibleTailCount) { _, _ in
                        debugTimelineLog("visibleTailCount changed value=\(visibleTailCount) totalMessages=\(messages.count)")
                        recomputeRenderItemsIfNeeded()
                        recomputeBlockInfoIfNeeded()
                    }
                    .onChange(of: shouldAnchorToAssistantResponse) { _, newValue in
                        if newValue {
                            autoScrollMode = .anchorAssistantResponse
                            handleTimelineMutation(using: proxy)
                        } else if autoScrollMode == .anchorAssistantResponse {
                            autoScrollMode = isScrolledToBottom ? .followBottom : .manual
                        }
                    }
                    // Keeps footer pinned to bottom without adding a solid spacer block above it.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        footer(scrollToBottomAction: {
                            handleScrollToLatestButtonTap(using: proxy)
                        })
                    }
                    .onAppear {
                        debugTimelineLog("onAppear threadID=\(threadID) messageCount=\(messages.count)")
                        beginScrollSessionIfNeeded()
                        recomputeRenderItemsIfNeeded()
                        recomputeBlockInfoIfNeeded()
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
        let signature = renderItemsCacheSignature(for: visibleMessages)
        guard signature != cachedRenderItemsSignature else { return }
        cachedRenderItemsSignature = signature
        cachedRenderItems = TurnTimelineRenderProjection.project(
            messages: Array(visibleMessages),
            completedTurnIDs: completedTurnIDs
        )
    }

    private func recomputeBlockInfoIfNeeded() {
        let visible = Array(visibleMessages)
        let key = blockInfoInputKey(for: visible)
        guard key != blockInfoInputKey else { return }
        blockInfoInputKey = key

        let cachedBlockInfo = Self.assistantBlockInfo(
            for: visible,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning,
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
        if updated != cachedBlockInfoByMessageID {
            cachedBlockInfoByMessageID = updated
        }

        let newestStreamingMessageID = visible.last(where: { $0.isStreaming })?.id
        if newestStreamingMessageID != cachedNewestStreamingMessageID {
            cachedNewestStreamingMessageID = newestStreamingMessageID
        }
    }

    // Hashes the fields that change copy-block aggregation or inline action placement.
    // Include message text too because thread/resume can reconcile completed rows in place.
    private func blockInfoInputKey(for messages: [CodexMessage]) -> Int {
        TurnTimelineCacheKeyBuilder.blockInfoInputKey(
            messages: messages,
            isThreadRunning: isThreadRunning,
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
        initialRecoverySnapPendingThreadID = threadID
        isProgressivelyRevealingRecentTail = shouldStageHeavyThreadOpen
    }

    // Cancels any delayed scroll work so old thread sessions cannot move the new one.
    private func cancelScrollTasks() {
        initialRecoverySnapTask?.cancel()
        initialRecoverySnapTask = nil
        followBottomScrollTask?.cancel()
        followBottomScrollTask = nil
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

        if nextValue {
            isScrolledToBottom = true
            if autoScrollMode != .anchorAssistantResponse {
                autoScrollMode = .followBottom
            }
            scheduleProgressiveTailRevealIfNeeded()
        } else {
            isScrolledToBottom = false
            autoScrollMode = TurnScrollStateTracker.modeAfterAcceptedNotBottomGeometry(
                currentMode: autoScrollMode
            )
            // Cancel queued app snaps once geometry confirms the viewport is away
            // from bottom; transient content-growth frames are filtered above.
            if autoScrollMode == .manual || autoScrollMode == .anchorAssistantResponse {
                followBottomScrollTask?.cancel()
                followBottomScrollTask = nil
            }
            progressiveTailRevealTask?.cancel()
            progressiveTailRevealTask = nil
            isProgressivelyRevealingRecentTail = false
        }
    }

    // Gives user drag intent precedence over follow-bottom so streaming never wrestles the scroll gesture.
    private func handleUserScrollDragChanged() {
        guard !isUserDraggingScroll else { return }
        isUserDraggingScroll = true
        userScrollCooldownUntil = nil
        followBottomScrollTask?.cancel()
        followBottomScrollTask = nil
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
            initialRecoverySnapPendingThreadID = nil
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
        shouldAnchorToAssistantResponse = false
        autoScrollMode = .followBottom
        initialRecoverySnapPendingThreadID = nil
        return true
    }

    // Keep mutation handling narrow so scroll geometry remains the follow-bottom source of truth.
    private func handleTimelineMutation(using proxy: ScrollViewProxy) {
        guard !shouldPauseAutomaticScrolling else { return }
        performInitialRecoverySnapIfNeeded(using: proxy)

        if autoScrollMode == .anchorAssistantResponse {
            _ = anchorToAssistantResponseIfNeeded(using: proxy)
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

    // Keeps the footer/timeline geometry transition stable while waiting for the first
    // assistant row to exist, so sending a message cannot leave a temporarily blank viewport.
    private var shouldPinTimelineToBottomDuringGeometryChange: Bool {
        let assistantAnchorTargetExists: Bool
        if autoScrollMode == .anchorAssistantResponse {
            assistantAnchorTargetExists = TurnTimelineReducer.assistantResponseAnchorMessageID(
                in: Array(visibleMessages),
                activeTurnID: activeTurnID
            ) != nil
        } else {
            assistantAnchorTargetExists = false
        }
        return TurnScrollStateTracker.shouldPinDuringGeometryChange(
            currentMode: autoScrollMode,
            isScrolledToBottom: isScrolledToBottom,
            isAutomaticScrollingPaused: shouldPauseAutomaticScrolling,
            assistantAnchorTargetExists: assistantAnchorTargetExists
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

        if new.viewportHeight > 0 {
            if abs(new.viewportHeight - viewportHeight) > 1 {
                viewportHeight = new.viewportHeight
            }
            performInitialRecoverySnapIfNeeded(using: proxy)
            if viewportHeightChanged,
               shouldPinTimelineToBottomDuringGeometryChange,
               !isSuppressingBottomCorrectionsForWarmup {
                scheduleFollowBottomScroll(using: proxy)
            }
        }
        if !isSuppressingBottomCorrectionsForWarmup,
           TurnScrollStateTracker.shouldCorrectBottomAfterContentHeightChange(
            previousHeight: old.contentHeight,
            newHeight: new.contentHeight,
            isPinnedToBottom: shouldPinTimelineToBottomDuringGeometryChange
        ) {
            scheduleFollowBottomScroll(using: proxy)
        }
        if new.isAtBottom != old.isAtBottom,
           !(isSuppressingBottomCorrectionsForWarmup && !new.isAtBottom) {
            handleScrolledToBottomChanged(new.isAtBottom)
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
