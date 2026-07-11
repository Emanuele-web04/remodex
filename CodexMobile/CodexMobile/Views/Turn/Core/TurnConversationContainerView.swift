// FILE: TurnConversationContainerView.swift
// Purpose: Composes the turn timeline, empty state, composer slot, and top overlays into one focused container.
// Layer: View Component
// Exports: TurnConversationContainerView
// Depends on: SwiftUI, TurnTimelineView

import SwiftUI

struct TurnConversationContainerView: View {
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
    let errorMessage: String?
    let composerRecoveryAccessory: AnyView?
    let onReportError: (String) -> Void
    let onDismissError: () -> Void
    let hasRemoteEarlierMessages: Bool
    let hasLocallyProjectedEarlierMessages: Bool
    let usesPaginatedHistory: Bool
    let initialTurnsLoaded: Bool
    let isLoadingRemoteEarlierMessages: Bool
    let olderHistoryLoadErrorMessage: String?
    let isAwaitingAssistantResponse: Binding<Bool>
    let isComposerFocused: Bool
    let isComposerAutocompletePresented: Bool
    let emptyState: AnyView
    let composer: AnyView
    let structuredPromptReplacementComposer: ((CodexMessage) -> AnyView)?
    let repositoryLoadingToastOverlay: AnyView
    let usageToastOverlay: AnyView
    let isRepositoryLoadingToastVisible: Bool
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void
    let onRevealEarlierMessages: (Int) -> Void
    let onLoadRemoteEarlierMessages: () -> Void
    let onRetryEarlierMessages: (@escaping () -> Void) -> Void
    let onTapOutsideComposer: () -> Void

    @State private var isShowingPinnedPlanSheet = false

    // Keeps accessory-only chats informative instead of showing a blank viewport.
    private func timelineEmptyState(for messageLayout: TimelineMessageLayout) -> AnyView {
        guard messageLayout.timelineMessages.isEmpty else {
            return emptyState
        }

        if messageLayout.activeStructuredPromptMessage != nil {
            return AnyView(EmptyView())
        }

        if let pinnedTaskPlanMessage = messageLayout.pinnedTaskPlanMessage {
            let snapshot = PlanAccessorySnapshot(message: pinnedTaskPlanMessage)
            let summary = snapshot.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return AnyView(
                AccessoryBackedEmptyState(
                    systemImage: snapshot.status.symbolName,
                    tint: snapshot.status.tint,
                    title: snapshot.status == .inProgress ? "Plan in progress" : "Plan ready",
                    summary: summary.isEmpty ? "Codex has prepared a plan for this chat." : summary,
                    detail: "Open the plan card above the composer to review the current steps."
                )
            )
        }

        return emptyState
    }

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        // Keep this split synchronous with `messages`: cached layout refreshes can
        // be starved by rapid assistant streaming and hide a just-sent user row.
        let messageLayout = Self.buildMessageLayout(
            from: messages,
            activeTurnID: activeTurnID,
            planSessionSource: planSessionSource
        )

        ZStack(alignment: .top) {
            TurnTimelineView(
                threadID: threadID,
                messages: messageLayout.timelineMessages,
                timelineChangeToken: timelineChangeToken,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                runStartGeneration: runStartGeneration,
                isSendInFlight: isSendInFlight,
                latestTurnTerminalState: latestTurnTerminalState,
                completedTurnIDs: completedTurnIDs,
                stoppedTurnIDs: stoppedTurnIDs,
                assistantRevertStatesByMessageID: assistantRevertStatesByMessageID,
                planSessionSource: planSessionSource,
                allowsAssistantPlanFallbackRecovery: allowsAssistantPlanFallbackRecovery,
                threadMessagesForPlanMatching: threadMessagesForPlanMatching,
                currentWorkingDirectory: currentWorkingDirectory,
                isRetryAvailable: !isThreadRunning,
                errorMessage: errorMessage,
                hidesErrorMessage: composerRecoveryAccessory != nil,
                onReportError: onReportError,
                onDismissError: onDismissError,
                hasRemoteEarlierMessages: hasRemoteEarlierMessages,
                hasLocallyProjectedEarlierMessages: hasLocallyProjectedEarlierMessages,
                usesPaginatedHistory: usesPaginatedHistory,
                initialTurnsLoaded: initialTurnsLoaded,
                isLoadingRemoteEarlierMessages: isLoadingRemoteEarlierMessages,
                olderHistoryLoadErrorMessage: olderHistoryLoadErrorMessage,
                isAwaitingAssistantResponse: isAwaitingAssistantResponse,
                isComposerFocused: isComposerFocused,
                isComposerAutocompletePresented: isComposerAutocompletePresented,
                onRetryUserMessage: onRetryUserMessage,
                onTapAssistantRevert: onTapAssistantRevert,
                onTapSubagent: onTapSubagent,
                onRevealEarlierMessages: onRevealEarlierMessages,
                onLoadRemoteEarlierMessages: onLoadRemoteEarlierMessages,
                onRetryEarlierMessages: onRetryEarlierMessages,
                onTapOutsideComposer: onTapOutsideComposer
            ) {
                timelineEmptyState(for: messageLayout)
            } composer: {
                composerWithPinnedPlanAccessory(for: messageLayout)
            }

            VStack(spacing: 0) {
                repositoryLoadingToastOverlay
                if !isRepositoryLoadingToastVisible {
                    usageToastOverlay
                }
            }
        }
        .onChange(of: messageLayout.pinnedTaskPlanMessage?.id) { _, newValue in
            if newValue == nil {
                isShowingPinnedPlanSheet = false
            }
        }
        .sheet(isPresented: $isShowingPinnedPlanSheet) {
            if let pinnedTaskPlanMessage = messageLayout.pinnedTaskPlanMessage {
                PlanExecutionSheet(message: pinnedTaskPlanMessage)
            }
        }
    }

    // Keeps the active plan discoverable without covering the message timeline.
    private func composerWithPinnedPlanAccessory(for messageLayout: TimelineMessageLayout) -> some View {
        VStack(spacing: 8) {
            if let composerRecoveryAccessory {
                composerRecoveryAccessory
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let activeStructuredPromptMessage = messageLayout.activeStructuredPromptMessage,
               let structuredPromptReplacementComposer {
                structuredPromptReplacementComposer(activeStructuredPromptMessage)
            } else {
                composer
            }
        }
        // The active plan renders as a capsule inside the composer's carousel
        // row; the environment carries it there without widening the composer API.
        .environment(\.pinnedPlanAccessory, messageLayout.pinnedTaskPlanMessage.map { message in
            PinnedPlanAccessoryContext(snapshot: PlanAccessorySnapshot(message: message)) {
                isShowingPinnedPlanSheet = true
            }
        })
        .animation(.easeInOut(duration: 0.18), value: messageLayout.activeStructuredPromptMessage?.id)
    }

    // Separates pinned plan content from renderable timeline rows in one pass.
    private static func buildMessageLayout(
        from messages: [CodexMessage],
        activeTurnID: String?,
        planSessionSource: CodexPlanSessionSource?
    ) -> TimelineMessageLayout {
        var timelineMessages: [CodexMessage] = []
        timelineMessages.reserveCapacity(messages.count)
        let pinnedTaskPlanMessage = pinnedTaskPlanMessage(
            from: messages,
            activeTurnID: activeTurnID
        )
        var activeStructuredPromptMessage: CodexMessage?
        let canReplaceComposerWithPrompt = planSessionSource?.isNative == true

        for message in messages {
            if message.isTaskProgressPlanMessage {
                // Progress snapshots belong only in the compact composer chip.
                // Older snapshots stay hidden even after a newer one completes.
                continue
            } else if message.shouldDisplayInlinePlanResult {
                timelineMessages.append(message)
            } else if message.isPlanSystemMessage {
                continue
            } else {
                timelineMessages.append(message)
                if canReplaceComposerWithPrompt,
                   message.shouldDisplayComposerStructuredPrompt {
                    activeStructuredPromptMessage = message
                }
            }
        }

        if let activeStructuredPromptMessage,
           let activeIndex = timelineMessages.lastIndex(where: { $0.id == activeStructuredPromptMessage.id }) {
            timelineMessages.remove(at: activeIndex)
        }

        return TimelineMessageLayout(
            timelineMessages: timelineMessages,
            pinnedTaskPlanMessage: pinnedTaskPlanMessage,
            activeStructuredPromptMessage: activeStructuredPromptMessage
        )
    }

    // Litter keeps every update_plan snapshot. Only the newest snapshot may
    // drive the chip. Prefer the active turn so a late replay from an older turn
    // cannot replace or clear the plan that currently belongs above the composer.
    static func pinnedTaskPlanMessage(
        from messages: [CodexMessage],
        activeTurnID: String? = nil
    ) -> CodexMessage? {
        let normalizedActiveTurnID = activeTurnID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeTurnPlan: CodexMessage? = normalizedActiveTurnID.flatMap { activeTurnID in
            guard !activeTurnID.isEmpty else {
                return nil
            }
            return messages.last { message in
                message.isTaskProgressPlanMessage
                    && message.turnId?.trimmingCharacters(in: .whitespacesAndNewlines) == activeTurnID
            }
        }
        guard let latest = activeTurnPlan
                ?? messages.last(where: { $0.isTaskProgressPlanMessage }),
              latest.shouldDisplayPinnedPlanAccessory else {
            return nil
        }
        return latest
    }
}

private struct TimelineMessageLayout: Equatable {
    let timelineMessages: [CodexMessage]
    let pinnedTaskPlanMessage: CodexMessage?
    let activeStructuredPromptMessage: CodexMessage?

    static let empty = TimelineMessageLayout(
        timelineMessages: [],
        pinnedTaskPlanMessage: nil,
        activeStructuredPromptMessage: nil
    )
}

private struct AccessoryBackedEmptyState: View {
    let systemImage: String
    let tint: Color
    let title: String
    let summary: String
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                RemodexIcon.image(systemName: systemImage)
                    .font(AppFont.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .fill(tint.opacity(0.12))
                    )

                Text(title)
                    .font(AppFont.title3(weight: .semibold))
                    .multilineTextAlignment(.center)

                Text(summary)
                    .font(AppFont.body())
                    .foregroundStyle(.primary.opacity(0.9))
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

extension CodexMessage {
    var isPlanSystemMessage: Bool {
        role == .system && kind == .plan
    }

    // Structured todo-list state is task progress even if an old bridge or
    // cached message incorrectly labeled it as a result. Real proposed-plan
    // results do not carry mutable step statuses.
    var isTaskProgressPlanMessage: Bool {
        guard isPlanSystemMessage else {
            return false
        }
        if resolvedPlanPresentation?.isProgressAccessory == true {
            return true
        }

        let steps = planState?.steps ?? []
        guard !steps.isEmpty else {
            return false
        }
        let proposedBody = proposedPlan?.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return proposedBody == nil || proposedBody == "Planning..."
    }

    // Hides terminal 3/3-style plans so only genuinely active plans stay pinned above the composer.
    var shouldDisplayPinnedPlanAccessory: Bool {
        guard isTaskProgressPlanMessage else {
            return false
        }

        if isStreaming {
            return true
        }

        let steps = planState?.steps ?? []
        guard !steps.isEmpty else {
            return false
        }

        return steps.contains { $0.status != .completed }
    }

    var shouldDisplayInlinePlanResult: Bool {
        guard isPlanSystemMessage, !isTaskProgressPlanMessage else {
            return false
        }

        if resolvedPlanPresentation == .resultCompletedItem {
            return hasRenderablePlanResult
        }

        guard resolvedPlanPresentation?.isInlineResultVisible == true else {
            return false
        }

        return proposedPlan != nil
    }

    private var hasRenderablePlanResult: Bool {
        let placeholders: Set<String> = ["Planning..."]
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return proposedPlan != nil || (!trimmedText.isEmpty && !placeholders.contains(trimmedText))
    }

    var shouldDisplayComposerStructuredPrompt: Bool {
        role == .system && kind == .userInputPrompt && structuredUserInputRequest != nil
    }
}
