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
    let shouldAnchorToAssistantResponse: Binding<Bool>
    let isScrolledToBottom: Binding<Bool>
    let isComposerFocused: Bool
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

    // Avoids showing the generic "new chat" empty state behind a pinned plan-only accessory.
    private var timelineEmptyState: AnyView {
        guard messageLayout.pinnedTaskPlanMessage != nil,
              messageLayout.timelineMessages.isEmpty else {
            return emptyState
        }
        return AnyView(
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
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
                shouldAnchorToAssistantResponse: shouldAnchorToAssistantResponse,
                isScrolledToBottom: isScrolledToBottom,
                isComposerFocused: isComposerFocused,
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
        }
        .onChange(of: threadID) { _, _ in
            rebuildMessageLayoutIfNeeded(force: true)
        }
        .onChange(of: timelineChangeToken) { _, _ in
            rebuildMessageLayoutIfNeeded()
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

            composer
        }
        .animation(.easeInOut(duration: 0.18), value: messageLayout.pinnedTaskPlanMessage?.id)
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

    // Separates pinned plan content from renderable timeline rows in one pass.
    private static func buildMessageLayout(from messages: [CodexMessage]) -> TimelineMessageLayout {
        var timelineMessages: [CodexMessage] = []
        timelineMessages.reserveCapacity(messages.count)
        var pinnedTaskPlanMessage: CodexMessage?

        for message in messages {
            if message.shouldDisplayPinnedPlanAccessory {
                pinnedTaskPlanMessage = message
            } else if message.isPlanSystemMessage {
                continue
            } else {
                timelineMessages.append(message)
            }
        }

        return TimelineMessageLayout(
            timelineMessages: timelineMessages,
            pinnedTaskPlanMessage: pinnedTaskPlanMessage
        )
    }
}

private struct TimelineMessageLayout: Equatable {
    let timelineMessages: [CodexMessage]
    let pinnedTaskPlanMessage: CodexMessage?

    static let empty = TimelineMessageLayout(
        timelineMessages: [],
        pinnedTaskPlanMessage: nil
    )
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
}
