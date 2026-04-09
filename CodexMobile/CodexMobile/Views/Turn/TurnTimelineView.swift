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

// ─── Tool Burst Projection ─────────────────────────────────────

struct TurnTimelineToolBurstGroup: Identifiable, Equatable {
    static let collapsedVisibleCount = 5

    let id: String
    let messages: [CodexMessage]

    init(messages: [CodexMessage]) {
        self.messages = messages
        self.id = "tool-burst:\(messages.first?.id ?? "unknown")"
    }

    var pinnedMessages: [CodexMessage] {
        Array(messages.prefix(Self.collapsedVisibleCount))
    }

    var overflowMessages: [CodexMessage] {
        Array(messages.dropFirst(Self.collapsedVisibleCount))
    }

    var hiddenCount: Int {
        overflowMessages.count
    }
}

enum TurnTimelineRenderItem: Identifiable, Equatable {
    case message(CodexMessage)
    case toolBurst(TurnTimelineToolBurstGroup)

    var id: String {
        switch self {
        case .message(let message):
            return message.id
        case .toolBurst(let group):
            return group.id
        }
    }
}

enum TurnTimelineRenderProjection {
    // Groups long contiguous tool-call runs into one stable container so the main
    // timeline height stays bounded without introducing nested scrolling.
    static func project(messages: [CodexMessage]) -> [TurnTimelineRenderItem] {
        var items: [TurnTimelineRenderItem] = []
        var bufferedToolMessages: [CodexMessage] = []

        func flushBufferedToolMessages() {
            guard !bufferedToolMessages.isEmpty else { return }
            if bufferedToolMessages.count > TurnTimelineToolBurstGroup.collapsedVisibleCount {
                items.append(.toolBurst(TurnTimelineToolBurstGroup(messages: bufferedToolMessages)))
            } else {
                items.append(contentsOf: bufferedToolMessages.map(TurnTimelineRenderItem.message))
            }
            bufferedToolMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            guard isToolBurstCandidate(message) else {
                flushBufferedToolMessages()
                items.append(.message(message))
                continue
            }

            if let previous = bufferedToolMessages.last,
               !canShareToolBurst(previous: previous, incoming: message) {
                flushBufferedToolMessages()
            }

            bufferedToolMessages.append(message)
        }

        flushBufferedToolMessages()
        return items
    }

    private static func isToolBurstCandidate(_ message: CodexMessage) -> Bool {
        guard message.role == .system else {
            return false
        }

        switch message.kind {
        case .toolActivity, .commandExecution:
            return true
        case .thinking, .chat, .plan, .userInputPrompt, .fileChange, .subagentAction:
            return false
        }
    }

    // Late turn ids can arrive mid-stream, so only split when both rows already
    // have distinct stable turn ids.
    private static func canShareToolBurst(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        let previousTurnID = normalizedIdentifier(previous.turnId)
        let incomingTurnID = normalizedIdentifier(incoming.turnId)

        guard let previousTurnID, let incomingTurnID else {
            return true
        }

        return previousTurnID == incomingTurnID
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct TurnTimelineMessageRow: View {
    let message: CodexMessage
    let isRetryAvailable: Bool
    let cachedBlockInfoByMessageID: [String: AssistantBlockAccessoryState]
    let planSessionSource: CodexPlanSessionSource?
    let allowsAssistantPlanFallbackRecovery: Bool
    let completedTurnIDs: Set<String>
    let threadMessagesForPlanMatching: [CodexMessage]
    let planMatchingFingerprint: Int
    let newestStreamingMessageID: String?
    let autoScrollMode: TurnAutoScrollMode
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void

    var body: some View {
        MessageRow(
            message: message,
            isRetryAvailable: isRetryAvailable,
            onRetryUserMessage: onRetryUserMessage,
            assistantBlockAccessoryState: cachedBlockInfoByMessageID[message.id],
            planSessionSource: planSessionSource,
            allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
            assistantTurnCompleted: message.turnId.map(completedTurnIDs.contains) ?? false,
            threadMessagesForPlanMatching: threadMessagesForPlanMatching,
            planMatchingFingerprint: planMatchingFingerprint,
            showsStreamingAnimations: autoScrollMode == .followBottom
                && message.id == newestStreamingMessageID,
            assistantRevertAction: onTapAssistantRevert,
            subagentOpenAction: onTapSubagent
        )
        .equatable()
        .id(message.id)
    }
}

private struct TurnTimelineToolBurstView: View {
    let group: TurnTimelineToolBurstGroup
    let isRetryAvailable: Bool
    let cachedBlockInfoByMessageID: [String: AssistantBlockAccessoryState]
    let planSessionSource: CodexPlanSessionSource?
    let allowsAssistantPlanFallbackRecovery: Bool
    let completedTurnIDs: Set<String>
    let threadMessagesForPlanMatching: [CodexMessage]
    let planMatchingFingerprint: Int
    let newestStreamingMessageID: String?
    let autoScrollMode: TurnAutoScrollMode
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void

    @State private var isExpanded = false

    private var summaryCountLabel: String {
        "+\(group.hiddenCount)"
    }

    private var summaryNounLabel: String {
        group.hiddenCount == 1 ? "tool call" : "tool calls"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(group.pinnedMessages) { message in
                TurnTimelineMessageRow(
                    message: message,
                    isRetryAvailable: isRetryAvailable,
                    cachedBlockInfoByMessageID: cachedBlockInfoByMessageID,
                    planSessionSource: planSessionSource,
                    allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                    completedTurnIDs: completedTurnIDs,
                    threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                    planMatchingFingerprint: planMatchingFingerprint,
                    newestStreamingMessageID: newestStreamingMessageID,
                    autoScrollMode: autoScrollMode,
                    onRetryUserMessage: onRetryUserMessage,
                    onTapAssistantRevert: onTapAssistantRevert,
                    onTapSubagent: onTapSubagent
                )
            }

            if group.hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(AppFont.system(size: 10, weight: .semibold))
                        (
                            Text(summaryCountLabel)
                                .font(AppFont.subheadline(weight: .medium))
                                .foregroundStyle(.secondary)
                            +
                            Text(" " + summaryNounLabel)
                                .font(AppFont.subheadline())
                                .foregroundStyle(.tertiary)
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                ForEach(group.overflowMessages) { message in
                    TurnTimelineMessageRow(
                        message: message,
                        isRetryAvailable: isRetryAvailable,
                        cachedBlockInfoByMessageID: cachedBlockInfoByMessageID,
                        planSessionSource: planSessionSource,
                        allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                        completedTurnIDs: completedTurnIDs,
                        threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                        planMatchingFingerprint: planMatchingFingerprint,
                        newestStreamingMessageID: newestStreamingMessageID,
                        autoScrollMode: autoScrollMode,
                        onRetryUserMessage: onRetryUserMessage,
                        onTapAssistantRevert: onTapAssistantRevert,
                        onTapSubagent: onTapSubagent
                    )
                }
            }
        }
    }
}

private struct TurnTimelineRowsSection: View {
    let shouldWarmRecentTailProgressively: Bool
    let hasEarlierMessages: Bool
    let visibleMessages: ArraySlice<CodexMessage>
    let isRetryAvailable: Bool
    let cachedBlockInfoByMessageID: [String: AssistantBlockAccessoryState]
    let planSessionSource: CodexPlanSessionSource?
    let allowsAssistantPlanFallbackRecovery: Bool
    let completedTurnIDs: Set<String>
    let threadMessagesForPlanMatching: [CodexMessage]
    let planMatchingFingerprint: Int
    let newestStreamingMessageID: String?
    let autoScrollMode: TurnAutoScrollMode
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void
    let onLoadEarlierMessages: () -> Void

    private var renderItems: [TurnTimelineRenderItem] {
        TurnTimelineRenderProjection.project(messages: Array(visibleMessages))
    }

    var body: some View {
        if shouldWarmRecentTailProgressively {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading recent messages...")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if hasEarlierMessages {
            Button(action: onLoadEarlierMessages) {
                Text("Load earlier messages")
                    .font(AppFont.subheadline())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }

        ForEach(renderItems) { item in
            switch item {
            case .message(let message):
                TurnTimelineMessageRow(
                    message: message,
                    isRetryAvailable: isRetryAvailable,
                    cachedBlockInfoByMessageID: cachedBlockInfoByMessageID,
                    planSessionSource: planSessionSource,
                    allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                    completedTurnIDs: completedTurnIDs,
                    threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                    planMatchingFingerprint: planMatchingFingerprint,
                    newestStreamingMessageID: newestStreamingMessageID,
                    autoScrollMode: autoScrollMode,
                    onRetryUserMessage: onRetryUserMessage,
                    onTapAssistantRevert: onTapAssistantRevert,
                    onTapSubagent: onTapSubagent
                )
            case .toolBurst(let group):
                TurnTimelineToolBurstView(
                    group: group,
                    isRetryAvailable: isRetryAvailable,
                    cachedBlockInfoByMessageID: cachedBlockInfoByMessageID,
                    planSessionSource: planSessionSource,
                    allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                    completedTurnIDs: completedTurnIDs,
                    threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                    planMatchingFingerprint: planMatchingFingerprint,
                    newestStreamingMessageID: newestStreamingMessageID,
                    autoScrollMode: autoScrollMode,
                    onRetryUserMessage: onRetryUserMessage,
                    onTapAssistantRevert: onTapAssistantRevert,
                    onTapSubagent: onTapSubagent
                )
            }
        }
    }
}

private struct TurnTimelineFooterContainer<Composer: View>: View {
    let hidesErrorMessage: Bool
    let errorMessage: String?
    let shouldShowScrollToLatestButton: Bool
    let scrollToLatestButtonLift: CGFloat
    let onScrollToLatest: (() -> Void)?
    @ViewBuilder let composer: () -> Composer

    var body: some View {
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

        footerContent
            .overlay(alignment: .top) {
                if shouldShowScrollToLatestButton, let onScrollToLatest {
                    scrollToLatestButton(action: onScrollToLatest)
                        .offset(y: -scrollToLatestButtonLift)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: shouldShowScrollToLatestButton)
    }

    private func scrollToLatestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

struct TurnTimelineView<EmptyState: View, Composer: View>: View {
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
    /// Heavy-chat staged warmup is temporarily disabled until geometry settles reliably.
    private static var initialWarmTailCount: Int { 0 }
    private static var scrollToLatestButtonLift: CGFloat { 44 + 18 }

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
    @State private var progressiveTailRevealTask: Task<Void, Never>?
    @State private var isProgressivelyRevealingRecentTail = false
    @State private var isUserDraggingScroll = false
    @State private var userScrollCooldownUntil: Date?
    @State private var scrollGeometryCoalescer = ScrollGeometryCoalescer()
    @State private var timelineDebugSequence = 0
    @State private var lastTimelineGeometryLogBucket: Int?

    /// The tail slice of messages currently rendered in the timeline.
    private var visibleMessages: ArraySlice<CodexMessage> {
        let startIndex = max(messages.count - visibleTailCount, 0)
        return messages[startIndex...]
    }

    private var hasEarlierMessages: Bool {
        visibleTailCount < messages.count
    }

    private var shouldWarmRecentTailProgressively: Bool {
        isProgressivelyRevealingRecentTail
            && messages.count > visibleTailCount
    }

    private var isRecentTailWarmupActive: Bool {
        shouldStageHeavyThreadOpen
            && visibleTailCount < min(messages.count, Self.pageSize)
    }

    private var shouldShowFullTimelineLoader: Bool {
        shouldWarmRecentTailProgressively && visibleTailCount == 0
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
                    VStack(spacing: 20) {
                        TurnTimelineRowsSection(
                            shouldWarmRecentTailProgressively: shouldWarmRecentTailProgressively,
                            hasEarlierMessages: hasEarlierMessages,
                            visibleMessages: visibleMessages,
                            isRetryAvailable: isRetryAvailable,
                            cachedBlockInfoByMessageID: cachedBlockInfoByMessageID,
                            planSessionSource: planSessionSource,
                            allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                            completedTurnIDs: completedTurnIDs,
                            threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                            planMatchingFingerprint: planMatchingFingerprint,
                            newestStreamingMessageID: cachedNewestStreamingMessageID,
                            autoScrollMode: autoScrollMode,
                            onRetryUserMessage: onRetryUserMessage,
                            onTapAssistantRevert: onTapAssistantRevert,
                            onTapSubagent: onTapSubagent,
                            onLoadEarlierMessages: handleLoadEarlierMessages
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                    // Keep bottom anchor outside the message stack so it is always
                    // reachable by scrollTo regardless of VStack layout timing.
                    Color.clear
                        .frame(height: 1)
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
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
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
                    logTimelineGeometryChangeIfNeeded(old: old, new: new)
                    // Coalesce into a single commit per runloop turn so SwiftUI
                    // sees at most one @State mutation instead of several per frame.
                    scrollGeometryCoalescer.pending = (old, new)
                    guard !scrollGeometryCoalescer.isScheduled else { return }
                    scrollGeometryCoalescer.isScheduled = true
                    debugTimelineLog("geometry change scheduled for coalesced apply")
                    DispatchQueue.main.async {
                        scrollGeometryCoalescer.isScheduled = false
                        guard let pending = scrollGeometryCoalescer.pending else { return }
                        scrollGeometryCoalescer.pending = nil
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
                    recomputeBlockInfoIfNeeded()
                    scheduleProgressiveTailRevealIfNeeded()
                    handleTimelineMutation(using: proxy)
                }
                .onChange(of: isThreadRunning) { _, _ in
                    debugTimelineLog("isThreadRunning changed value=\(isThreadRunning)")
                    recomputeBlockInfoIfNeeded()
                }
                .onChange(of: threadID) { _, _ in
                    debugTimelineLog("threadID changed to=\(threadID)")
                    beginScrollSessionIfNeeded(force: true)
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
                .onChange(of: stoppedTurnIDs) { _, _ in
                    debugTimelineLog("stoppedTurnIDs changed count=\(stoppedTurnIDs.count)")
                    recomputeBlockInfoIfNeeded()
                }
                .onChange(of: visibleTailCount) { _, _ in
                    debugTimelineLog("visibleTailCount changed value=\(visibleTailCount) totalMessages=\(messages.count)")
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
        TurnTimelineFooterContainer(
            hidesErrorMessage: hidesErrorMessage,
            errorMessage: errorMessage,
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
        progressiveTailRevealTask?.cancel()
        progressiveTailRevealTask = nil
        isProgressivelyRevealingRecentTail = false
        withAnimation(.easeOut(duration: 0.15)) {
            visibleTailCount = min(visibleTailCount + Self.pageSize, messages.count)
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
            : min(messages.count, Self.pageSize)
        isScrolledToBottom = true
        isUserDraggingScroll = false
        userScrollCooldownUntil = nil
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
    }

    private var timelineLoadingOverlay: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Loading chat...")
                .font(AppFont.title3(weight: .semibold))
            Text("Preparing recent messages for this conversation.")
                .font(AppFont.body())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // Stages the recent tail for heavy chats so thread switches avoid building dozens
    // of rich markdown rows in one main-thread burst. The last 3 opened chats stay warm.
    private func scheduleProgressiveTailRevealIfNeeded() {
        let targetTailCount = min(messages.count, Self.pageSize)

        guard targetTailCount > 0 else {
            return
        }

        guard shouldStageHeavyThreadOpen else {
            if visibleTailCount < targetTailCount {
                visibleTailCount = targetTailCount
            }
            if messages.count > Self.pageSize {
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

            let liveTargetTailCount = min(messages.count, Self.pageSize)
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

        if nextValue {
            isScrolledToBottom = true
            if autoScrollMode != .anchorAssistantResponse {
                autoScrollMode = .followBottom
            }
            scheduleProgressiveTailRevealIfNeeded()
        } else {
            isScrolledToBottom = false
            // Only disengage follow-bottom from user scroll gestures, not from
            // transient geometry changes caused by content growth. The scroll phase
            // handler already sets .manual when the user actively drags.
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

    private func logTimelineGeometryChangeIfNeeded(old: ScrollBottomGeometry, new: ScrollBottomGeometry) {
        let delta = max(
            abs(new.contentHeight - old.contentHeight),
            abs(new.viewportHeight - old.viewportHeight)
        )
        let bucket = Int(delta / 20)
        guard bucket != lastTimelineGeometryLogBucket || new.isAtBottom != old.isAtBottom else {
            return
        }
        lastTimelineGeometryLogBucket = bucket
        debugTimelineLog(
            "geometry changed bucket=\(bucket) oldBottom=\(old.isAtBottom) newBottom=\(new.isAtBottom) "
                + "contentDelta=\(Int(new.contentHeight - old.contentHeight)) "
                + "viewportDelta=\(Int(new.viewportHeight - old.viewportHeight))"
        )
    }

    private func debugTimelineLog(_ message: String) {
        timelineDebugSequence += 1
        print("[TimelineDebug] #\(timelineDebugSequence) \(message)")
    }
}

private struct ScrollBottomGeometry: Equatable {
    let isAtBottom: Bool
    let viewportHeight: CGFloat
    let contentHeight: CGFloat
}

/// Batches rapid `onScrollGeometryChange` callbacks so at most one @State
/// commit reaches SwiftUI per runloop turn, preventing the
/// "tried to update multiple times per frame" cycling.
@MainActor
private final class ScrollGeometryCoalescer {
    var pending: (old: ScrollBottomGeometry, new: ScrollBottomGeometry)?
    var isScheduled = false
}

@MainActor
private enum TurnTimelineWarmThreadCache {
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

private struct TurnFloatingButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
