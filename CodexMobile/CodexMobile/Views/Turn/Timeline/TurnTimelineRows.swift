// FILE: TurnTimelineRows.swift
// Purpose: Renders timeline row groups and message-row accessories.
// Layer: View Component
// Exports: AssistantBlockAccessoryState, TurnTimelineRowsSection
// Depends on: SwiftUI, RemodexTextKit, TurnTimelineRenderProjection, MessageRow, CodexMessage

import RemodexTextKit
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
        blockDiffText: String? = nil,
        blockDiffEntries: [TurnFileChangeSummaryEntry]? = nil,
        blockRevertPresentation: AssistantRevertPresentation? = nil,
        blockRevertMessage: CodexMessage? = nil
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

    func suppressingCopyAndRunningAccessory() -> AssistantBlockAccessoryState {
        AssistantBlockAccessoryState(
            copyText: nil,
            showsRunningIndicator: false,
            allowsCopy: false,
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

enum TurnTimelineToolBurstAccessoryResolver {
    static func copyFooterState(
        for group: TurnTimelineToolBurstGroup,
        statesByMessageID: [String: AssistantBlockAccessoryState],
        suppressesRunningIndicator: Bool
    ) -> AssistantBlockAccessoryState? {
        guard let hostMessage = group.latestMessage,
              let state = statesByMessageID[hostMessage.id] else {
            return nil
        }

        let resolvedState = suppressesRunningIndicator
            ? state.replacingRunningIndicator(false)
            : state
        guard resolvedState.showsRunningIndicator
            || (resolvedState.allowsCopy && resolvedState.copyText != nil) else {
            return nil
        }
        return resolvedState
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
    let movesCopyAndRunningToGroupFooter: Bool
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
        let resolvedState = showsGlobalRunningIndicator
            ? state?.replacingRunningIndicator(false)
            : state
        return movesCopyAndRunningToGroupFooter
            ? resolvedState?.suppressingCopyAndRunningAccessory()
            : resolvedState
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
            if isExpanded {
                ForEach(group.overflowMessages) { message in
                    toolMessageRow(message)
                }
            }

            // Keep the newest call immediately visible. The disclosure belongs
            // below the tool rows in both collapsed and expanded states.
            if let latestMessage = group.latestMessage {
                toolMessageRow(latestMessage)
            }

            if group.hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        RemodexIcon.image(systemName: "chevron.right", size: 13, relativeTo: .body)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text("\(summaryCountLabel) \(summaryNounLabel)")
                            .font(AppFont.body(weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let footerState = TurnTimelineToolBurstAccessoryResolver.copyFooterState(
                for: group,
                statesByMessageID: cachedBlockInfoByMessageID,
                suppressesRunningIndicator: showsGlobalRunningIndicator
            ) {
                CopyBlockButton(
                    text: footerState.allowsCopy ? footerState.copyText : nil,
                    isRunning: footerState.showsRunningIndicator
                )
            }
        }
    }

    private func toolMessageRow(_ message: CodexMessage) -> some View {
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
            movesCopyAndRunningToGroupFooter: message.id == group.latestMessage?.id,
            onRetryUserMessage: onRetryUserMessage,
            onTapAssistantRevert: onTapAssistantRevert,
            onTapSubagent: onTapSubagent
        )
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
                        movesCopyAndRunningToGroupFooter: false,
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

private struct TurnTimelineCommandGroupView: View {
    let group: TurnTimelineCommandGroup
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
        group.commandCount == 1 ? "Ran 1 command" : "Ran \(group.commandCount) commands"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    RemodexIcon.image(systemName: "terminal", size: 14, relativeTo: .body)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(AppFont.body(weight: .regular))
                        .foregroundStyle(.secondary)
                    RemodexIcon.image(systemName: "chevron.right", size: 13, relativeTo: .body)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isExpanded ? "Collapse commands" : "Expand commands")

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
                        movesCopyAndRunningToGroupFooter: false,
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
                        movesCopyAndRunningToGroupFooter: false,
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
                case .commandGroup(let group):
                    TurnTimelineCommandGroupView(
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
        // One selection scope for the whole timeline: starting a selection in any
        // markdown row clears the active selection in every other row.
        .remodex.textSelectionScope()
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
