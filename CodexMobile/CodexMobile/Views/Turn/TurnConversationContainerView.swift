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
    let latestTurnTerminalState: CodexTurnTerminalState?
    let stoppedTurnIDs: Set<String>
    let assistantRevertStatesByMessageID: [String: AssistantRevertPresentation]
    let errorMessage: String?
    let connectionRecoveryAccessory: AnyView?
    let shouldAnchorToAssistantResponse: Binding<Bool>
    let isScrolledToBottom: Binding<Bool>
    let isComposerFocused: Bool
    let isComposerAutocompletePresented: Bool
    let emptyState: AnyView
    let composer: AnyView
    let repositoryLoadingToastOverlay: AnyView
    let usageToastOverlay: AnyView
    let isRepositoryLoadingToastVisible: Bool
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void
    let onTapOutsideComposer: () -> Void

    @State private var isShowingPinnedPlanSheet = false
    @State private var isShowingPinnedStructuredUserInputSheet = false
    @State private var lastAutoPresentedStructuredUserInputMessageID: String?
    @State private var cachedMessageLayout = TimelineMessageLayout.empty
    @State private var lastMessageLayoutThreadID: String?
    @State private var lastMessageLayoutToken: Int = -1

    // Falls back to a one-off rebuild during first render, then keeps later renders on cached derived state.
    private var messageLayout: TimelineMessageLayout {
        guard lastMessageLayoutThreadID == threadID,
              lastMessageLayoutToken == timelineChangeToken else {
            return Self.buildMessageLayout(from: messages)
        }
        return cachedMessageLayout
    }

    // Keeps accessory-only chats informative instead of showing a blank viewport.
    private var timelineEmptyState: AnyView {
        guard messageLayout.timelineMessages.isEmpty else {
            return emptyState
        }

        if let pinnedStructuredUserInputMessage = messageLayout.pinnedStructuredUserInputMessage {
            let questionCount = pinnedStructuredUserInputMessage.structuredUserInputRequest?.questions.count ?? 0
            let title = questionCount == 1 ? "One answer needed" : "Answers needed"
            let summary: String
            if questionCount <= 0 {
                summary = "Codex is waiting for your input before it can continue."
            } else if questionCount == 1 {
                summary = "Codex is waiting for one answer before it can continue."
            } else {
                summary = "Codex is waiting for \(questionCount) answers before it can continue."
            }
            return AnyView(
                AccessoryBackedEmptyState(
                    systemImage: "questionmark.circle",
                    tint: Color(.plan),
                    title: title,
                    summary: summary,
                    detail: "Open the prompt above the composer to review the questions and reply."
                )
            )
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
        ZStack(alignment: .top) {
            TurnTimelineView(
                threadID: threadID,
                messages: messageLayout.timelineMessages,
                timelineChangeToken: timelineChangeToken,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                latestTurnTerminalState: latestTurnTerminalState,
                stoppedTurnIDs: stoppedTurnIDs,
                assistantRevertStatesByMessageID: assistantRevertStatesByMessageID,
                isRetryAvailable: !isThreadRunning,
                errorMessage: errorMessage,
                hidesErrorMessage: connectionRecoveryAccessory != nil,
                shouldAnchorToAssistantResponse: shouldAnchorToAssistantResponse,
                isScrolledToBottom: isScrolledToBottom,
                isComposerFocused: isComposerFocused,
                isComposerAutocompletePresented: isComposerAutocompletePresented,
                onRetryUserMessage: onRetryUserMessage,
                onTapAssistantRevert: onTapAssistantRevert,
                onTapSubagent: onTapSubagent,
                onTapOutsideComposer: onTapOutsideComposer
            ) {
                timelineEmptyState
            } composer: {
                composerWithPinnedPlanAccessory
            }

            VStack(spacing: 0) {
                repositoryLoadingToastOverlay
                if !isRepositoryLoadingToastVisible {
                    usageToastOverlay
                }
            }
        }
        .onAppear {
            rebuildMessageLayoutIfNeeded(force: true)
            autoPresentStructuredUserInputIfNeeded()
        }
        .onChange(of: threadID) { _, _ in
            lastAutoPresentedStructuredUserInputMessageID = nil
            rebuildMessageLayoutIfNeeded(force: true)
            autoPresentStructuredUserInputIfNeeded()
        }
        .onChange(of: timelineChangeToken) { _, _ in
            rebuildMessageLayoutIfNeeded()
            autoPresentStructuredUserInputIfNeeded()
        }
        .onChange(of: messageLayout.pinnedTaskPlanMessage?.id) { _, newValue in
            if newValue == nil {
                isShowingPinnedPlanSheet = false
            }
        }
        .onChange(of: messageLayout.pinnedStructuredUserInputMessage?.id) { _, newValue in
            guard let newValue else {
                isShowingPinnedStructuredUserInputSheet = false
                return
            }

            if lastAutoPresentedStructuredUserInputMessageID != newValue {
                lastAutoPresentedStructuredUserInputMessageID = newValue
                isShowingPinnedStructuredUserInputSheet = true
            }
        }
        .sheet(isPresented: $isShowingPinnedPlanSheet) {
            if let pinnedTaskPlanMessage = messageLayout.pinnedTaskPlanMessage {
                PlanExecutionSheet(message: pinnedTaskPlanMessage)
            }
        }
        .sheet(isPresented: $isShowingPinnedStructuredUserInputSheet) {
            if let pinnedStructuredUserInputMessage = messageLayout.pinnedStructuredUserInputMessage {
                StructuredUserInputSheet(
                    requestMessage: pinnedStructuredUserInputMessage,
                    planMessage: messageLayout.pinnedTaskPlanMessage
                )
            }
        }
    }

    // Keeps the active plan discoverable without covering the message timeline.
    private var composerWithPinnedPlanAccessory: some View {
        VStack(spacing: 8) {
            if let pinnedTaskPlanMessage = messageLayout.pinnedTaskPlanMessage {
                PlanExecutionAccessory(message: pinnedTaskPlanMessage) {
                    isShowingPinnedPlanSheet = true
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let pinnedStructuredUserInputMessage = messageLayout.pinnedStructuredUserInputMessage {
                StructuredUserInputAccessory(message: pinnedStructuredUserInputMessage) {
                    isShowingPinnedStructuredUserInputSheet = true
                }
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let connectionRecoveryAccessory {
                connectionRecoveryAccessory
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            composer
        }
        .animation(.easeInOut(duration: 0.18), value: messageLayout.pinnedTaskPlanMessage?.id)
        .animation(.easeInOut(duration: 0.18), value: messageLayout.pinnedStructuredUserInputMessage?.id)
    }

    // Rebuilds the plan/timeline split only when the thread or timeline token really changed.
    private func rebuildMessageLayoutIfNeeded(force: Bool = false) {
        guard force
                || lastMessageLayoutThreadID != threadID
                || lastMessageLayoutToken != timelineChangeToken else {
            return
        }

        lastMessageLayoutThreadID = threadID
        lastMessageLayoutToken = timelineChangeToken
        cachedMessageLayout = Self.buildMessageLayout(from: messages)
    }

    // Auto-opens a newly pending prompt once per request id so reconnect-replayed questions do not stay buried.
    private func autoPresentStructuredUserInputIfNeeded() {
        guard let pinnedStructuredUserInputMessage = messageLayout.pinnedStructuredUserInputMessage else {
            return
        }

        guard lastAutoPresentedStructuredUserInputMessageID != pinnedStructuredUserInputMessage.id else {
            return
        }

        lastAutoPresentedStructuredUserInputMessageID = pinnedStructuredUserInputMessage.id
        isShowingPinnedStructuredUserInputSheet = true
    }

    // Separates pinned plan content from renderable timeline rows in one pass.
    private static func buildMessageLayout(from messages: [CodexMessage]) -> TimelineMessageLayout {
        var timelineMessages: [CodexMessage] = []
        timelineMessages.reserveCapacity(messages.count)
        var pinnedTaskPlanMessage: CodexMessage?
        var pinnedStructuredUserInputMessage: CodexMessage?

        for message in messages {
            if message.shouldDisplayPinnedPlanAccessory {
                pinnedTaskPlanMessage = message
            } else if message.shouldDisplayPinnedStructuredUserInputAccessory {
                pinnedStructuredUserInputMessage = message
            } else if message.isPlanSystemMessage {
                continue
            } else {
                timelineMessages.append(message)
            }
        }

        return TimelineMessageLayout(
            timelineMessages: timelineMessages,
            pinnedTaskPlanMessage: pinnedTaskPlanMessage,
            pinnedStructuredUserInputMessage: pinnedStructuredUserInputMessage
        )
    }
}

private struct TimelineMessageLayout: Equatable {
    let timelineMessages: [CodexMessage]
    let pinnedTaskPlanMessage: CodexMessage?
    let pinnedStructuredUserInputMessage: CodexMessage?

    static let empty = TimelineMessageLayout(
        timelineMessages: [],
        pinnedTaskPlanMessage: nil,
        pinnedStructuredUserInputMessage: nil
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
                Image(systemName: systemImage)
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

    // Hides terminal 3/3-style plans so only genuinely active plans stay pinned above the composer.
    var shouldDisplayPinnedPlanAccessory: Bool {
        guard isPlanSystemMessage else {
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

    var shouldDisplayPinnedStructuredUserInputAccessory: Bool {
        role == .system
            && kind == .userInputPrompt
            && structuredUserInputRequest != nil
    }
}
