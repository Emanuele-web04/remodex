// FILE: TurnTimelineRows.swift
// Purpose: Renders timeline row groups and message-row accessories.
// Layer: View Component
// Exports: AssistantBlockAccessoryState, TurnTimelineRowsSection
// Depends on: SwiftUI, TurnTimelineRenderProjection, MessageRow, CodexMessage

import SwiftUI

struct AssistantBlockAccessoryState: Equatable {
    let copyText: String?
    let showsRunningIndicator: Bool
    let allowsCopy: Bool
    let blockDiffText: String?
    let blockDiffEntries: [TurnFileChangeSummaryEntry]?
    let blockRevertPresentation: AssistantRevertPresentation?
    let blockRevertMessage: CodexMessage?

    init(
        copyText: String?,
        showsRunningIndicator: Bool,
        allowsCopy: Bool = false,
        blockDiffText: String?,
        blockDiffEntries: [TurnFileChangeSummaryEntry]?,
        blockRevertPresentation: AssistantRevertPresentation?,
        blockRevertMessage: CodexMessage?
    ) {
        self.copyText = copyText
        self.showsRunningIndicator = showsRunningIndicator
        self.allowsCopy = allowsCopy
        self.blockDiffText = blockDiffText
        self.blockDiffEntries = blockDiffEntries
        self.blockRevertPresentation = blockRevertPresentation
        self.blockRevertMessage = blockRevertMessage
    }

    static func == (lhs: AssistantBlockAccessoryState, rhs: AssistantBlockAccessoryState) -> Bool {
        lhs.copyText == rhs.copyText
            && lhs.showsRunningIndicator == rhs.showsRunningIndicator
            && lhs.allowsCopy == rhs.allowsCopy
            && lhs.blockDiffText == rhs.blockDiffText
            && lhs.blockDiffEntries == rhs.blockDiffEntries
            && lhs.blockRevertPresentation == rhs.blockRevertPresentation
            && blockRevertMessageSignature(lhs.blockRevertMessage) == blockRevertMessageSignature(rhs.blockRevertMessage)
    }

    func replacingCopyText(_ copyText: String?) -> AssistantBlockAccessoryState {
        AssistantBlockAccessoryState(
            copyText: copyText,
            showsRunningIndicator: showsRunningIndicator,
            allowsCopy: allowsCopy,
            blockDiffText: blockDiffText,
            blockDiffEntries: blockDiffEntries,
            blockRevertPresentation: blockRevertPresentation,
            blockRevertMessage: blockRevertMessage
        )
    }

    func replacingRunningIndicator(_ showsRunningIndicator: Bool) -> AssistantBlockAccessoryState {
        AssistantBlockAccessoryState(
            copyText: copyText,
            showsRunningIndicator: showsRunningIndicator,
            allowsCopy: allowsCopy,
            blockDiffText: blockDiffText,
            blockDiffEntries: blockDiffEntries,
            blockRevertPresentation: blockRevertPresentation,
            blockRevertMessage: blockRevertMessage
        )
    }

    func mergingRehomedAccessoryState(_ state: AssistantBlockAccessoryState) -> AssistantBlockAccessoryState {
        AssistantBlockAccessoryState(
            copyText: copyText ?? state.copyText,
            showsRunningIndicator: showsRunningIndicator || state.showsRunningIndicator,
            allowsCopy: allowsCopy || state.allowsCopy,
            blockDiffText: blockDiffText ?? state.blockDiffText,
            blockDiffEntries: blockDiffEntries ?? state.blockDiffEntries,
            blockRevertPresentation: blockRevertPresentation ?? state.blockRevertPresentation,
            blockRevertMessage: blockRevertMessage ?? state.blockRevertMessage
        )
    }

    private static func blockRevertMessageSignature(_ message: CodexMessage?) -> AssistantBlockRevertMessageSignature? {
        guard let message else { return nil }
        return AssistantBlockRevertMessageSignature(message)
    }
}

private struct AssistantBlockRevertMessageSignature: Equatable {
    let id: String
    let role: CodexMessageRole
    let kind: CodexMessageKind
    let turnId: String?
    let itemId: String?
    let isStreaming: Bool
    let textSignature: CodexMessageTextRenderSignature

    init(_ message: CodexMessage) {
        self.id = message.id
        self.role = message.role
        self.kind = message.kind
        self.turnId = message.turnId
        self.itemId = message.itemId
        self.isStreaming = message.isStreaming
        self.textSignature = message.textRenderSignature
    }
}

private struct TurnTimelineMessageRow: View {
    @Environment(\.inlineCommitAndPushAction) private var inlineCommitAndPushAction
    @Environment(\.inlineCommitAndPushPhase) private var inlineCommitAndPushPhase

    let message: CodexMessage
    let isRetryAvailable: Bool
    let cachedBlockInfoByMessageID: [String: AssistantBlockAccessoryState]
    let planSessionSource: CodexPlanSessionSource?
    let allowsAssistantPlanFallbackRecovery: Bool
    let completedTurnIDs: Set<String>
    let threadMessagesForPlanMatching: [CodexMessage]
    let currentWorkingDirectory: String?
    let planMatchingFingerprint: Int
    let newestStreamingMessageID: String?
    let autoScrollMode: TurnAutoScrollMode
    let showsGlobalRunningIndicator: Bool
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void

    var body: some View {
        MessageRow(
            message: message,
            isRetryAvailable: isRetryAvailable,
            onRetryUserMessage: onRetryUserMessage,
            assistantBlockAccessoryState: assistantBlockAccessoryState,
            planSessionSource: planSessionSource,
            allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
            assistantTurnCompleted: message.turnId.map(completedTurnIDs.contains) ?? false,
            threadMessagesForPlanMatching: threadMessagesForPlanMatching,
            currentWorkingDirectory: currentWorkingDirectory,
            planMatchingFingerprint: planMatchingFingerprint,
            showsStreamingAnimations: autoScrollMode == .followBottom
                && message.id == newestStreamingMessageID,
            inlineCommitAndPushAction: inlineCommitAndPushAction,
            inlineCommitAndPushPhase: inlineCommitAndPushPhase,
            assistantRevertAction: onTapAssistantRevert,
            subagentOpenAction: onTapSubagent
        )
        .equatable()
        .id(message.id)
    }

    private var assistantBlockAccessoryState: AssistantBlockAccessoryState? {
        let state = cachedBlockInfoByMessageID[message.id]
        return showsGlobalRunningIndicator
            ? state?.replacingRunningIndicator(false)
            : state
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
    let currentWorkingDirectory: String?
    let planMatchingFingerprint: Int
    let newestStreamingMessageID: String?
    let autoScrollMode: TurnAutoScrollMode
    let showsGlobalRunningIndicator: Bool
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
        VStack(alignment: .leading, spacing: 14) {
            ForEach(group.pinnedMessages) { message in
                TurnTimelineMessageRow(
                    message: message,
                    isRetryAvailable: isRetryAvailable,
                    cachedBlockInfoByMessageID: cachedBlockInfoByMessageID,
                    planSessionSource: planSessionSource,
                    allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                    completedTurnIDs: completedTurnIDs,
                    threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                    currentWorkingDirectory: currentWorkingDirectory,
                    planMatchingFingerprint: planMatchingFingerprint,
                    newestStreamingMessageID: newestStreamingMessageID,
                    autoScrollMode: autoScrollMode,
                    showsGlobalRunningIndicator: showsGlobalRunningIndicator,
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
                        RemodexIcon.image(systemName: "chevron.right")
                            .font(AppFont.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
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
                        currentWorkingDirectory: currentWorkingDirectory,
                        planMatchingFingerprint: planMatchingFingerprint,
                        newestStreamingMessageID: newestStreamingMessageID,
                        autoScrollMode: autoScrollMode,
                        showsGlobalRunningIndicator: showsGlobalRunningIndicator,
                        onRetryUserMessage: onRetryUserMessage,
                        onTapAssistantRevert: onTapAssistantRevert,
                        onTapSubagent: onTapSubagent
                    )
                }
            }
        }
    }
}

private struct TurnTimelinePreviousMessagesView: View {
    let group: TurnTimelinePreviousMessagesGroup
    let isRetryAvailable: Bool
    let cachedBlockInfoByMessageID: [String: AssistantBlockAccessoryState]
    let planSessionSource: CodexPlanSessionSource?
    let allowsAssistantPlanFallbackRecovery: Bool
    let completedTurnIDs: Set<String>
    let threadMessagesForPlanMatching: [CodexMessage]
    let currentWorkingDirectory: String?
    let planMatchingFingerprint: Int
    let newestStreamingMessageID: String?
    let autoScrollMode: TurnAutoScrollMode
    let showsGlobalRunningIndicator: Bool
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void

    @State private var isExpanded = false

    private var title: String {
        group.hiddenCount == 1 ? "1 previous message" : "\(group.hiddenCount) previous messages"
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(height: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(AppFont.body(weight: .regular))
                        .foregroundStyle(.secondary)
                    RemodexIcon.image(systemName: "chevron.right")
                        .font(AppFont.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isExpanded ? "Collapse previous messages" : "Expand previous messages")

            if isExpanded {
                ForEach(group.messages) { message in
                    TurnTimelineMessageRow(
                        message: message,
                        isRetryAvailable: isRetryAvailable,
                        cachedBlockInfoByMessageID: cachedBlockInfoByMessageID,
                        planSessionSource: planSessionSource,
                        allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                        completedTurnIDs: completedTurnIDs,
                        threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                        currentWorkingDirectory: currentWorkingDirectory,
                        planMatchingFingerprint: planMatchingFingerprint,
                        newestStreamingMessageID: newestStreamingMessageID,
                        autoScrollMode: autoScrollMode,
                        showsGlobalRunningIndicator: showsGlobalRunningIndicator,
                        onRetryUserMessage: onRetryUserMessage,
                        onTapAssistantRevert: onTapAssistantRevert,
                        onTapSubagent: onTapSubagent
                    )
                }
            }

            divider
        }
        .id(group.id)
    }
}

struct TurnTimelineRowsSection: View {
    let shouldWarmRecentTailProgressively: Bool
    let hasEarlierMessages: Bool
    let isLoadingEarlierMessages: Bool
    let earlierMessagesErrorMessage: String?
    let renderItems: [TurnTimelineRenderItem]
    let showsGlobalRunningIndicator: Bool
    let isRetryAvailable: Bool
    let cachedBlockInfoByMessageID: [String: AssistantBlockAccessoryState]
    let planSessionSource: CodexPlanSessionSource?
    let allowsAssistantPlanFallbackRecovery: Bool
    let completedTurnIDs: Set<String>
    let threadMessagesForPlanMatching: [CodexMessage]
    let currentWorkingDirectory: String?
    let planMatchingFingerprint: Int
    let newestStreamingMessageID: String?
    let autoScrollMode: TurnAutoScrollMode
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void
    let onLoadEarlierMessages: () -> Void
    let pendingStreamingAssistantPlaceholderID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    HStack(spacing: 8) {
                        if isLoadingEarlierMessages {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(earlierMessagesButtonTitle)
                    }
                    .font(AppFont.body(weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingEarlierMessages)
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
                        currentWorkingDirectory: currentWorkingDirectory,
                        planMatchingFingerprint: planMatchingFingerprint,
                        newestStreamingMessageID: newestStreamingMessageID,
                        autoScrollMode: autoScrollMode,
                        showsGlobalRunningIndicator: shouldUseGlobalRunningIndicator,
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
                        currentWorkingDirectory: currentWorkingDirectory,
                        planMatchingFingerprint: planMatchingFingerprint,
                        newestStreamingMessageID: newestStreamingMessageID,
                        autoScrollMode: autoScrollMode,
                        showsGlobalRunningIndicator: shouldUseGlobalRunningIndicator,
                        onRetryUserMessage: onRetryUserMessage,
                        onTapAssistantRevert: onTapAssistantRevert,
                        onTapSubagent: onTapSubagent
                    )
                case .previousMessages(let group):
                    TurnTimelinePreviousMessagesView(
                        group: group,
                        isRetryAvailable: isRetryAvailable,
                        cachedBlockInfoByMessageID: cachedBlockInfoByMessageID,
                        planSessionSource: planSessionSource,
                        allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                        completedTurnIDs: completedTurnIDs,
                        threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                        currentWorkingDirectory: currentWorkingDirectory,
                        planMatchingFingerprint: planMatchingFingerprint,
                        newestStreamingMessageID: newestStreamingMessageID,
                        autoScrollMode: autoScrollMode,
                        showsGlobalRunningIndicator: shouldUseGlobalRunningIndicator,
                        onRetryUserMessage: onRetryUserMessage,
                        onTapAssistantRevert: onTapAssistantRevert,
                        onTapSubagent: onTapSubagent
                    )
                }
            }

            if let pendingStreamingAssistantPlaceholderID {
                StreamingAssistantPlaceholderSlot()
                    .id(pendingStreamingAssistantPlaceholderID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldUseGlobalRunningIndicator: Bool {
        showsGlobalRunningIndicator
    }

    private var earlierMessagesButtonTitle: String {
        if isLoadingEarlierMessages {
            return "Loading earlier messages..."
        }
        return earlierMessagesErrorMessage ?? "Load earlier messages"
    }
}
