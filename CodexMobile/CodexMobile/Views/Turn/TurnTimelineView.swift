// FILE: TurnTimelineView.swift
// Purpose: Renders timeline scrolling, bottom-anchor behavior and the footer container.
// Layer: View Component
// Exports: TurnTimelineView
// Depends on: SwiftUI, TurnTimelineReducer, TurnScrollStateTracker, MessageRow

import SwiftUI

private enum TurnAutoScrollMode {
    case followBottom
    case anchorAssistantResponse
    case manual
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

    @Binding var shouldAnchorToAssistantResponse: Bool
    @Binding var isScrolledToBottom: Bool

    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
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
    @State private var cachedBlockInfoByMessageID: [String: String] = [:]
    @State private var cachedLastFileChangeMessageID: String? = nil
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
                        LazyVStack(spacing: 20) {
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
                                    assistantRevertPresentation: assistantRevertStatesByMessageID[message.id],
                                    copyBlockText: cachedBlockInfoByMessageID[message.id],
                                    showInlineCommit: message.id == cachedLastFileChangeMessageID,
                                    showsStreamingAnimations: isScrolledToBottom
                                        && message.id == cachedNewestStreamingMessageID
                                )
                                .equatable()
                                .environment(\.assistantRevertAction, onTapAssistantRevert)
                                .id(message.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                        // Keep bottom anchor outside LazyVStack so it is always laid out.
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
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            handleUserScrollDragChanged()
                        }
                        .onEnded { _ in
                            handleUserScrollDragEnded()
                        }
                )
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
                    return ScrollBottomGeometry(isAtBottom: isAtBottom, viewportHeight: vh)
                } action: { old, new in
                    if new.viewportHeight != old.viewportHeight, new.viewportHeight > 0 {
                        viewportHeight = new.viewportHeight
                        performInitialRecoverySnapIfNeeded(using: proxy)
                    }
                    if new.isAtBottom != old.isAtBottom {
                        handleScrolledToBottomChanged(new.isAtBottom)
                    }
                }
                // React to every timeline mutation so streamed text growth stays pinned
                // when the user is already at the bottom.
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

    /// Recomputes assistantBlockInfo and lastFileChangeIndex only when inputs actually changed.
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
            stoppedTurnIDs: stoppedTurnIDs
        )
        cachedBlockInfoByMessageID = Dictionary(
            uniqueKeysWithValues: zip(visible, cachedBlockInfo).compactMap { message, blockText in
                guard let blockText else { return nil }
                return (message.id, blockText)
            }
        )
        cachedLastFileChangeMessageID = !isThreadRunning
            ? visible.last(where: { $0.role == .system && $0.kind == .fileChange })?.id
            : nil
        cachedNewestStreamingMessageID = visible.last(where: { $0.isStreaming })?.id
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

    private func footer(scrollToBottomAction: (() -> Void)? = nil) -> some View {
        VStack(spacing: 0) {
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            composer()
        }
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
            followBottomScrollTask?.cancel()
            followBottomScrollTask = nil
            isScrolledToBottom = false
            if autoScrollMode != .anchorAssistantResponse {
                autoScrollMode = .manual
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
        if autoScrollMode != .anchorAssistantResponse, !isScrolledToBottom {
            autoScrollMode = .manual
        }
    }

    // Preserves user-controlled deceleration for a short cooldown before auto-follow can resume.
    private func handleUserScrollDragEnded() {
        isUserDraggingScroll = false
        userScrollCooldownUntil = TurnScrollStateTracker.cooldownDeadline()
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

    // Centralizes all automatic scrolling so first-load recovery, response anchoring,
    // and bottom-following do not compete with one another.
    private func handleTimelineMutation(using proxy: ScrollViewProxy) {
        guard !shouldPauseAutomaticScrolling else { return }
        performInitialRecoverySnapIfNeeded(using: proxy)

        switch autoScrollMode {
        case .anchorAssistantResponse:
            _ = anchorToAssistantResponseIfNeeded(using: proxy)
        case .followBottom:
            if isScrolledToBottom {
                scheduleFollowBottomScroll(using: proxy)
            }
        case .manual:
            return
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
                  autoScrollMode == .followBottom,
                  !shouldPauseAutomaticScrolling,
                  isScrolledToBottom else {
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

    /// For each message index, returns the aggregated assistant block text if the message
    /// is the last non-user message before the next user message (or end of list).
    /// Returns nil for all other indices.
    static func assistantBlockInfo(
        for messages: [CodexMessage],
        activeTurnID: String?,
        isThreadRunning: Bool,
        latestTurnTerminalState: CodexTurnTerminalState?,
        stoppedTurnIDs: Set<String>
    ) -> [String?] {
        var result = [String?](repeating: nil, count: messages.count)
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
            if !blockText.isEmpty,
               shouldShowCopyButton(
                blockTurnID: blockTurnID,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                isLatestBlock: isLatestBlock,
                latestTurnTerminalState: latestTurnTerminalState,
                stoppedTurnIDs: stoppedTurnIDs
               ) {
                result[blockEnd] = blockText
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
}

private struct TurnFloatingButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
