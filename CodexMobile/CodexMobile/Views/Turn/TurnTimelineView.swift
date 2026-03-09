// FILE: TurnTimelineView.swift
// Purpose: Renders timeline scrolling, bottom-anchor behavior and the footer container.
// Layer: View Component
// Exports: TurnTimelineView
// Depends on: SwiftUI, TurnTimelineReducer, TurnScrollStateTracker, MessageRow

import SwiftUI

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
    private let scrollCoordinateSpaceID = "turn-scroll-coordinate-space"

    /// Number of messages to show per page.  Only the tail slice is rendered;
    /// scrolling to the top reveals a "Load earlier messages" button.
    private static var pageSize: Int { 40 }

    @State private var visibleTailCount: Int = pageSize
    @State private var viewportHeight: CGFloat = 0
    // Cached per-render artifacts to avoid O(n) recomputation inside the body.
    @State private var cachedBlockInfoByMessageID: [String: String] = [:]
    @State private var cachedLastFileChangeMessageID: String? = nil
    @State private var blockInfoInputKey: Int = 0

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
                .onChange(of: threadID) { _, _ in
                    visibleTailCount = Self.pageSize
                    isScrolledToBottom = true
                    shouldAnchorToAssistantResponse = false
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
                                    showInlineCommit: message.id == cachedLastFileChangeMessageID
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
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: TurnScrollBottomAnchorMaxYPreferenceKey.self,
                                        value: geometry.frame(in: .named(scrollCoordinateSpaceID)).maxY
                                    )
                                }
                            )
                            .allowsHitTesting(false)
                            .padding(.bottom, 12)
                    }
                }
                .accessibilityIdentifier("turn.timeline.scrollview")
                .coordinateSpace(name: scrollCoordinateSpaceID)
                .background(Color(.systemBackground))
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        onTapOutsideComposer()
                    }
                )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    guard newHeight != viewportHeight else { return }
                    viewportHeight = newHeight
                }
                .onPreferenceChange(TurnScrollBottomAnchorMaxYPreferenceKey.self) { bottomAnchorMaxY in
                    updateScrolledToBottom(
                        bottomAnchorMaxY: bottomAnchorMaxY,
                        viewportHeight: viewportHeight
                    )
                }
                // Observe a lightweight revision token so scroll/layout updates do not compare huge message arrays.
                .onChange(of: timelineChangeToken) { _, _ in
                    recomputeBlockInfoIfNeeded()
                }
                .onChange(of: messages.count) { _, _ in
                    if shouldAnchorToAssistantResponse {
                        anchorToAssistantResponseIfNeeded(using: proxy)
                        return
                    }

                    if isScrolledToBottom {
                        scrollToBottom(using: proxy, animated: false)
                    }
                }
                .onChange(of: isThreadRunning) { _, _ in
                    recomputeBlockInfoIfNeeded()
                }
                .onChange(of: threadID) { _, _ in
                    visibleTailCount = Self.pageSize
                    isScrolledToBottom = true
                    shouldAnchorToAssistantResponse = false
                    recomputeBlockInfoIfNeeded()
                }
                .onChange(of: activeTurnID) { _, _ in
                    recomputeBlockInfoIfNeeded()
                    anchorToAssistantResponseIfNeeded(using: proxy)
                }
                .onChange(of: latestTurnTerminalState) { _, _ in
                    recomputeBlockInfoIfNeeded()
                }
                .onChange(of: stoppedTurnIDs) { _, _ in
                    recomputeBlockInfoIfNeeded()
                }
                // Keeps footer pinned to bottom without adding a solid spacer block above it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    footer(scrollToBottomAction: {
                        scrollToBottom(using: proxy, animated: true)
                    })
                }
                .onAppear {
                    recomputeBlockInfoIfNeeded()
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
    }

    // Hashes structural fields that drive block aggregation and inline commit placement.
    // Excludes message.text intentionally: text hashing is O(n) over potentially large
    // strings and the copy-button text is hidden during streaming anyway.  Structural
    // changes (count, isStreaming flip, isThreadRunning) already trigger a fresh recompute
    // that picks up the final text content.
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
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            composer()
        }
        .animation(.easeInOut(duration: 0.2), value: shouldShowScrollToLatestButton)
    }

    private var shouldShowScrollToLatestButton: Bool {
        TurnScrollStateTracker.shouldShowScrollToLatestButton(
            messageCount: messages.count,
            isScrolledToBottom: isScrolledToBottom
        )
    }

    private func updateScrolledToBottom(bottomAnchorMaxY: CGFloat, viewportHeight: CGFloat) {
        guard viewportHeight > 0 else { return }

        let nextValue = TurnScrollStateTracker.isScrolledToBottom(
            bottomAnchorMaxY: bottomAnchorMaxY,
            viewportHeight: viewportHeight,
            hasMessages: !messages.isEmpty
        )

        if nextValue != isScrolledToBottom {
            isScrolledToBottom = nextValue
        }
    }

    private func anchorToAssistantResponseIfNeeded(using proxy: ScrollViewProxy) {
        guard shouldAnchorToAssistantResponse,
              let assistantMessageID = TurnTimelineReducer.assistantResponseAnchorMessageID(
                in: Array(visibleMessages),
                activeTurnID: activeTurnID
              ) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(assistantMessageID, anchor: .top)
        }
        shouldAnchorToAssistantResponse = false
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

    // Scrolls to the bottom sentinel; used by manual jump button and pin-to-bottom behavior.
    // Runs synchronously to avoid a 1-frame lag between content growth and scroll update
    // that causes isScrolledToBottom to briefly flip and the layout to jitter.
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

private struct TurnScrollBottomAnchorMaxYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TurnFloatingButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
