// FILE: TurnTimelineView.swift
// Purpose: Renders timeline scrolling, bottom-anchor behavior and the footer container.
// Layer: View Component
// Exports: TurnTimelineView
// Depends on: SwiftUI, TurnTimelineReducer, TurnScrollStateTracker, MessageRow

import SwiftUI

struct AssistantBlockAccessoryState: Equatable {
    let copyText: String?
    let showsRunningIndicator: Bool
    let blockDiffText: String?
    let blockDiffEntries: [TurnFileChangeSummaryEntry]?
    let blockRevertPresentation: AssistantRevertPresentation?
}

struct TurnTimelineView<EmptyState: View, Composer: View>: View {
    let threadID: String
    let messages: [CodexMessage]
    let timelineChangeToken: Int
    let activeTurnID: String?
    let isThreadRunning: Bool
    let latestTurnTerminalState: CodexTurnTerminalState?
    let stoppedTurnIDs: Set<String>
    let assistantRevertStatesByMessageID: [String: AssistantRevertPresentation]
    let isRetryAvailable: Bool
    let errorMessage: String?
    let hidesErrorMessage: Bool

    @Binding var shouldAnchorToAssistantResponse: Bool
    @Binding var isScrolledToBottom: Bool
    let isComposerFocused: Bool
    let isComposerAutocompletePresented: Bool

    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void
    let onTapOutsideComposer: () -> Void
    @ViewBuilder let emptyState: () -> EmptyState
    @ViewBuilder let composer: () -> Composer

    private let scrollBottomAnchorID = "turn-scroll-bottom-anchor"
    /// Number of messages to show per page.  Only the tail slice is rendered;
    /// scrolling to the top reveals a "Load earlier messages" button.
    private static var pageSize: Int { 40 }

    @State private var visibleTailCount: Int = pageSize
    @State private var viewportHeight: CGFloat = 0
    // Cached per-render artifacts to avoid O(n) recomputation inside the body.
    @State private var cachedBlockInfoByMessageID: [String: AssistantBlockAccessoryState] = [:]
    @State private var cachedNewestStreamingMessageID: String? = nil
    @State private var blockInfoInputKey: Int = 0
    @State private var scrollSessionThreadID: String?
    @State private var autoScrollMode: TurnAutoScrollMode = .followBottom
    @State private var initialRecoverySnapPendingThreadID: String?
    @State private var initialRecoverySnapTask: Task<Void, Never>?
    @State private var followBottomScrollTask: Task<Void, Never>?
    @State private var isUserDraggingScroll = false
    @State private var userScrollCooldownUntil: Date?

    /// The tail slice of messages currently rendered in the timeline.
    private var visibleMessages: ArraySlice<CodexMessage> {
        let startIndex = max(messages.count - visibleTailCount, 0)
        return messages[startIndex...]
    }

    private var hasEarlierMessages: Bool {
        visibleTailCount < messages.count
    }

    var body: some View {
        if messages.isEmpty {
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
                ScrollView {
                    VStack(spacing: 0) {
                        // Keep the conversation virtualized in the common case so heavy
                        // markdown/system rows do not all re-layout while the user scrolls.
                        LazyVStack(spacing: 20) {
                            timelineRows
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        // Keep bottom anchor outside the message stack so it is always laid out.
                        Color.clear
                            .frame(height: 1)
                            .id(scrollBottomAnchorID)
                            .allowsHitTesting(false)
                            .padding(.bottom, 12)
                    }
                }
                .accessibilityIdentifier("turn.timeline.scrollview")
                .background(Color(.systemBackground))
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        onTapOutsideComposer()
                    }
                )
                // Track real scroll phases instead of layering a competing drag gesture on top.
                .onScrollPhaseChange { oldPhase, newPhase in
                    handleScrollPhaseChange(from: oldPhase, to: newPhase)
                }
                .onScrollGeometryChange(for: ScrollBottomGeometry.self) { geometry in
                    let vh = geometry.visibleRect.height
                    let isAtBottom: Bool
                    if geometry.contentSize.height <= 0 || vh <= 0 {
                        isAtBottom = true
                    } else if geometry.contentSize.height <= vh {
                        isAtBottom = true
                    } else {
                        isAtBottom = geometry.visibleRect.maxY
                            >= geometry.contentSize.height - TurnScrollStateTracker.bottomThreshold
                    }
                    return ScrollBottomGeometry(
                        isAtBottom: isAtBottom,
                        viewportHeight: vh,
                        contentHeight: geometry.contentSize.height
                    )
                } action: { old, new in
                    if new.viewportHeight > 0,
                       abs(new.viewportHeight - old.viewportHeight) > 2 {
                        viewportHeight = new.viewportHeight
                        performInitialRecoverySnapIfNeeded(using: proxy)
                        if shouldPinTimelineToBottomDuringGeometryChange {
                            scheduleFollowBottomScroll(using: proxy)
                        }
                    }
                    if TurnScrollStateTracker.shouldCorrectBottomAfterContentHeightChange(
                        previousHeight: old.contentHeight,
                        newHeight: new.contentHeight,
                        isPinnedToBottom: shouldPinTimelineToBottomDuringGeometryChange
                    ) {
                        scheduleFollowBottomScroll(using: proxy)
                    }
                    if new.isAtBottom != old.isAtBottom {
                        handleScrolledToBottomChanged(new.isAtBottom)
                    }
                }
                // Timeline mutations still drive block-info refresh and assistant anchoring,
                // but geometry decides when follow-bottom should actually fire.
                .onChange(of: timelineChangeToken) { _, _ in
                    recomputeBlockInfoIfNeeded()
                    handleTimelineMutation(using: proxy)
                }
                .onChange(of: isThreadRunning) { _, _ in
                    recomputeBlockInfoIfNeeded()
                }
                .onChange(of: threadID) { _, _ in
                    beginScrollSessionIfNeeded(force: true)
                    recomputeBlockInfoIfNeeded()
                    handleTimelineMutation(using: proxy)
                }
                .onChange(of: activeTurnID) { _, _ in
                    recomputeBlockInfoIfNeeded()
                    handleTimelineMutation(using: proxy)
                }
                .onChange(of: latestTurnTerminalState) { _, _ in
                    recomputeBlockInfoIfNeeded()
                }
                .onChange(of: stoppedTurnIDs) { _, _ in
                    recomputeBlockInfoIfNeeded()
                }
                .onChange(of: visibleTailCount) { _, _ in
                    // Loading older rows changes the visible slice even when the underlying
                    // timeline revision is unchanged, so refresh slice-scoped accessories now.
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
                        autoScrollMode = .followBottom
                        initialRecoverySnapPendingThreadID = nil
                        isUserDraggingScroll = false
                        userScrollCooldownUntil = nil
                        scrollToBottom(using: proxy, animated: true)
                    })
                }
                .onAppear {
                    beginScrollSessionIfNeeded()
                    recomputeBlockInfoIfNeeded()
                    handleTimelineMutation(using: proxy)
                }
                .onDisappear {
                    cancelScrollTasks()
                }
            }
        }
    }

    @ViewBuilder
    private var timelineRows: some View {
        if hasEarlierMessages {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    visibleTailCount = min(
                        visibleTailCount + Self.pageSize,
                        messages.count
                    )
                }
            } label: {
                Text("Load earlier messages")
                    .font(AppFont.subheadline())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }

        ForEach(visibleMessages) { message in
            MessageRow(
                message: message,
                isRetryAvailable: isRetryAvailable,
                onRetryUserMessage: onRetryUserMessage,
                assistantBlockAccessoryState: cachedBlockInfoByMessageID[message.id],
                // Keep streaming adornments stable while follow-bottom is active so
                // transient bottom-geometry flips during content growth do not
                // add/remove indicator height and make the viewport bounce.
                showsStreamingAnimations: autoScrollMode == .followBottom
                    && message.id == cachedNewestStreamingMessageID,
                assistantRevertAction: onTapAssistantRevert,
                subagentOpenAction: onTapSubagent
            )
            .equatable()
            .id(message.id)
        }
    }

    /// Recomputes assistant-block copy data and the inline-commit target only when inputs actually changed.
    /// Works over the visible slice only so cost stays bounded regardless of total history.
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

        let updated = [String: AssistantBlockAccessoryState](
            uniqueKeysWithValues: zip(visible, cachedBlockInfo).compactMap { message, blockText in
                guard let blockText else { return nil }
                return (message.id, blockText)
            }
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
        var hasher = Hasher()
        hasher.combine(messages.count)
        hasher.combine(isThreadRunning)
        hasher.combine(activeTurnID)
        hasher.combine(latestTurnTerminalState)
        hasher.combine(stoppedTurnIDs)

        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.role)
            hasher.combine(message.kind)
            hasher.combine(message.turnId)
            hasher.combine(message.isStreaming)
            // During streaming, text changes every delta — hash only the length to avoid
            // O(text_length) hashing per frame. Once finalized, hash full text for reconciliation.
            if message.isStreaming {
                hasher.combine(message.text.count)
            } else {
                hasher.combine(message.text)
            }
        }

        return hasher.finalize()
    }

    @ViewBuilder
    private var emptyTimelineState: some View {
        if isThreadRunning {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text("Working on it...")
                    .font(AppFont.title3(weight: .semibold))
                Text("The run is still active. You can stop it below if needed.")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Spacer()
            }
        } else {
            emptyState()
        }
    }

    // Keeps the composer/footer visually stable so scrolling does not animate the bottom inset.
    private func footer(scrollToBottomAction: (() -> Void)? = nil) -> some View {
        let footerContent = VStack(spacing: 0) {
            if !hidesErrorMessage, let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            composer()
        }

        return footerContent
            // Let the composer own vertical drags so internal text scrolling
            // does not compete with keyboard-dismiss gestures on the footer.
            .overlay(alignment: .top) {
                if shouldShowScrollToLatestButton, let scrollToBottomAction {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        shouldAnchorToAssistantResponse = false
                        scrollToBottomAction()
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(AppFont.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .adaptiveGlass(.regular, in: Circle())
                    }
                    .frame(width: 44, height: 44)
                    .buttonStyle(TurnFloatingButtonPressStyle())
                    .contentShape(Circle())
                    .accessibilityLabel("Scroll to latest message")
                    .offset(y: -(44 + 18))
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: shouldShowScrollToLatestButton)
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

    // Resets per-thread scroll intent so each opened conversation gets one fresh
    // post-layout recovery snap and starts in bottom-follow mode.
    private func beginScrollSessionIfNeeded(force: Bool = false) {
        guard force || scrollSessionThreadID != threadID else { return }

        cancelScrollTasks()
        scrollSessionThreadID = threadID
        visibleTailCount = Self.pageSize
        isScrolledToBottom = true
        isUserDraggingScroll = false
        userScrollCooldownUntil = nil
        autoScrollMode = shouldAnchorToAssistantResponse ? .anchorAssistantResponse : .followBottom
        initialRecoverySnapPendingThreadID = threadID
    }

    // Cancels any delayed scroll work so old thread sessions cannot move the new one.
    private func cancelScrollTasks() {
        initialRecoverySnapTask?.cancel()
        initialRecoverySnapTask = nil
        followBottomScrollTask?.cancel()
        followBottomScrollTask = nil
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

        if nextValue {
            isScrolledToBottom = true
            if autoScrollMode != .anchorAssistantResponse {
                autoScrollMode = .followBottom
            }
        } else {
            isScrolledToBottom = false
            // Only disengage follow-bottom from user scroll gestures, not from
            // transient geometry changes caused by content growth. The scroll phase
            // handler already sets .manual when the user actively drags.
            if autoScrollMode == .manual || autoScrollMode == .anchorAssistantResponse {
                followBottomScrollTask?.cancel()
                followBottomScrollTask = nil
            }
        }
    }

    // Gives user drag intent precedence over follow-bottom so streaming never wrestles the scroll gesture.
    private func handleUserScrollDragChanged() {
        guard !isUserDraggingScroll else { return }
        isUserDraggingScroll = true
        userScrollCooldownUntil = nil
        followBottomScrollTask?.cancel()
        followBottomScrollTask = nil
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

    // Repairs the initial white/blank viewport race by doing a deferred snap, then
    // one follow-up verification snap after the footer/lazy rows finish settling.
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
        initialRecoverySnapTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  initialRecoverySnapPendingThreadID == expectedThreadID,
                  scrollSessionThreadID == expectedThreadID,
                  !messages.isEmpty,
                  viewportHeight > 0,
                  autoScrollMode == .followBottom,
                  !shouldPauseAutomaticScrolling,
                  !shouldAnchorToAssistantResponse else {
                initialRecoverySnapTask = nil
                return
            }

            scrollToBottom(using: proxy, animated: false)

            // A second snap one frame later fixes the common case where the composer
            // inset or lazy cell heights settle just after the first recovery jump.
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled,
                  initialRecoverySnapPendingThreadID == expectedThreadID,
                  scrollSessionThreadID == expectedThreadID,
                  !messages.isEmpty,
                  viewportHeight > 0,
                  autoScrollMode == .followBottom,
                  !shouldPauseAutomaticScrolling,
                  !shouldAnchorToAssistantResponse else {
                initialRecoverySnapTask = nil
                return
            }

            scrollToBottom(using: proxy, animated: false)
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
        autoScrollMode = .manual
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
        guard !shouldPauseAutomaticScrolling, isScrolledToBottom else {
            return false
        }

        switch autoScrollMode {
        case .followBottom:
            return true
        case .anchorAssistantResponse:
            return TurnTimelineReducer.assistantResponseAnchorMessageID(
                in: Array(visibleMessages),
                activeTurnID: activeTurnID
            ) == nil
        case .manual:
            return false
        }
    }

    /// For each message index, returns the aggregated assistant block text if the message
    /// is the last non-user message before the next user message (or end of list).
    /// Returns nil for all other indices.
    static func assistantBlockInfo(
        for messages: [CodexMessage],
        activeTurnID: String?,
        isThreadRunning: Bool,
        latestTurnTerminalState: CodexTurnTerminalState?,
        stoppedTurnIDs: Set<String>,
        revertStatesByMessageID: [String: AssistantRevertPresentation] = [:]
    ) -> [AssistantBlockAccessoryState?] {
        var result = [AssistantBlockAccessoryState?](repeating: nil, count: messages.count)
        let latestBlockEnd = messages.lastIndex(where: { $0.role != .user })
        var i = messages.count - 1
        while i >= 0 {
            guard messages[i].role != .user else { i -= 1; continue }
            // Found end of an assistant block — walk backwards to collect all non-user messages.
            let blockEnd = i
            var blockStart = i
            while blockStart > 0 && messages[blockStart - 1].role != .user {
                blockStart -= 1
            }
            let blockText = messages[blockStart...blockEnd]
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let blockTurnID = messages[blockStart...blockEnd]
                .reversed()
                .compactMap(\.turnId)
                .first
            let isLatestBlock = latestBlockEnd == blockEnd
            let copyText: String?
            if !blockText.isEmpty,
               shouldShowCopyButton(
                blockTurnID: blockTurnID,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                isLatestBlock: isLatestBlock,
                latestTurnTerminalState: latestTurnTerminalState,
                stoppedTurnIDs: stoppedTurnIDs
               ) {
                copyText = blockText
            } else {
                copyText = nil
            }

            let showsRunningIndicator = shouldShowRunningIndicator(
                blockTurnID: blockTurnID,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                isLatestBlock: isLatestBlock,
                latestTurnTerminalState: latestTurnTerminalState,
                stoppedTurnIDs: stoppedTurnIDs
            )

            // Aggregate file-change entries across the block for the turn-end Diff button.
            let fileChangeMessages = messages[blockStart...blockEnd].filter {
                $0.role == .system && $0.kind == .fileChange && !$0.isStreaming
            }
            let blockDiffEntries: [TurnFileChangeSummaryEntry]? = fileChangeMessages.isEmpty ? nil : {
                var allEntries: [TurnFileChangeSummaryEntry] = []
                for msg in fileChangeMessages {
                    if let parsed = TurnFileChangeSummaryParser.parse(from: msg.text) {
                        allEntries.append(contentsOf: parsed.entries)
                    }
                }
                return allEntries.isEmpty ? nil : allEntries
            }()
            let blockDiffText: String? = fileChangeMessages.isEmpty ? nil :
                fileChangeMessages.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")

            // Use the last assistant revert presentation in this block.
            let blockRevert = messages[blockStart...blockEnd]
                .reversed()
                .compactMap { revertStatesByMessageID[$0.id] }
                .first

            if copyText != nil || showsRunningIndicator || blockDiffEntries != nil || blockRevert != nil {
                result[blockEnd] = AssistantBlockAccessoryState(
                    copyText: copyText,
                    showsRunningIndicator: showsRunningIndicator,
                    blockDiffText: blockDiffText,
                    blockDiffEntries: blockDiffEntries,
                    blockRevertPresentation: blockRevert
                )
            }
            i = blockStart - 1
        }
        return result
    }

    // Keeps Copy aligned with real run completion instead of per-message streaming heuristics.
    private static func shouldShowCopyButton(
        blockTurnID: String?,
        activeTurnID: String?,
        isThreadRunning: Bool,
        isLatestBlock: Bool,
        latestTurnTerminalState: CodexTurnTerminalState?,
        stoppedTurnIDs: Set<String>
    ) -> Bool {
        if let blockTurnID, stoppedTurnIDs.contains(blockTurnID) {
            return false
        }

        if isLatestBlock, latestTurnTerminalState == .stopped {
            return false
        }

        guard isThreadRunning else {
            return true
        }

        if let blockTurnID, let activeTurnID {
            return blockTurnID != activeTurnID
        }

        return !isLatestBlock
    }

    // Keeps the terminal loader attached to the block that still belongs to the active run.
    private static func shouldShowRunningIndicator(
        blockTurnID: String?,
        activeTurnID: String?,
        isThreadRunning: Bool,
        isLatestBlock: Bool,
        latestTurnTerminalState: CodexTurnTerminalState?,
        stoppedTurnIDs: Set<String>
    ) -> Bool {
        guard isThreadRunning else {
            return false
        }

        if isLatestBlock, latestTurnTerminalState == .stopped {
            return false
        }

        if let blockTurnID, stoppedTurnIDs.contains(blockTurnID) {
            return false
        }

        if let blockTurnID, let activeTurnID {
            return blockTurnID == activeTurnID
        }

        return isLatestBlock
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
}

private struct ScrollBottomGeometry: Equatable {
    let isAtBottom: Bool
    let viewportHeight: CGFloat
    let contentHeight: CGFloat
}

private struct TurnFloatingButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
