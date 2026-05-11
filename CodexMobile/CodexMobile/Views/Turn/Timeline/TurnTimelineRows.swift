// FILE: TurnTimelineRows.swift
// Purpose: Renders timeline row groups and message-row accessories.
// Layer: View Component
// Exports: AssistantBlockAccessoryState, TurnTimelineRowsSection
// Depends on: SwiftUI, TurnTimelineRenderProjection, MessageRow

import SwiftUI

struct AssistantBlockAccessoryState: Equatable {
    let copyText: String?
    let showsRunningIndicator: Bool
    let blockDiffText: String?
    let blockDiffEntries: [TurnFileChangeSummaryEntry]?
    let blockRevertPresentation: AssistantRevertPresentation?
    let blockRevertMessage: CodexMessage?

    func replacingCopyText(_ copyText: String?) -> AssistantBlockAccessoryState {
        AssistantBlockAccessoryState(
            copyText: copyText,
            showsRunningIndicator: showsRunningIndicator,
            blockDiffText: blockDiffText,
            blockDiffEntries: blockDiffEntries,
            blockRevertPresentation: blockRevertPresentation,
            blockRevertMessage: blockRevertMessage
        )
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
                    currentWorkingDirectory: currentWorkingDirectory,
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
                        Image(systemName: "chevron.right")
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
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void

    @State private var isExpanded = false

    private var title: String {
        group.hiddenCount == 1 ? "1 previous message" : "\(group.hiddenCount) previous messages"
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
                    Image(systemName: "chevron.right")
                        .font(AppFont.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 1)
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
                        onRetryUserMessage: onRetryUserMessage,
                        onTapAssistantRevert: onTapAssistantRevert,
                        onTapSubagent: onTapSubagent
                    )
                }
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                        onRetryUserMessage: onRetryUserMessage,
                        onTapAssistantRevert: onTapAssistantRevert,
                        onTapSubagent: onTapSubagent
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var earlierMessagesButtonTitle: String {
        if isLoadingEarlierMessages {
            return "Loading earlier messages..."
        }
        return earlierMessagesErrorMessage ?? "Load earlier messages"
    }
}
