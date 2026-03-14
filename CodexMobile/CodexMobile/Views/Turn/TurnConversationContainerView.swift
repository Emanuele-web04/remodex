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
    let emptyState: AnyView
    let composer: AnyView
    let repositoryLoadingToastOverlay: AnyView
    let usageToastOverlay: AnyView
    let isRepositoryLoadingToastVisible: Bool
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapOutsideComposer: () -> Void

    // Pins only the checklist-style plan card that includes task rows and statuses.
    private var pinnedTaskPlanMessage: CodexMessage? {
        messages.last { $0.showsPinnedTaskChecklist }
    }

    // Keeps the checklist card from rendering twice once it moves into the top overlay.
    private var timelineMessages: [CodexMessage] {
        guard let pinnedTaskPlanMessage else { return messages }
        return messages.filter { $0.id != pinnedTaskPlanMessage.id }
    }

    // Avoids showing the generic "new chat" empty state behind a pinned plan-only overlay.
    private var timelineEmptyState: AnyView {
        guard pinnedTaskPlanMessage != nil, timelineMessages.isEmpty else {
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
            VStack(spacing: 0) {
                TurnTimelineView(
                    threadID: threadID,
                    messages: timelineMessages,
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
                    onRetryUserMessage: onRetryUserMessage,
                    onTapAssistantRevert: onTapAssistantRevert,
                    onTapOutsideComposer: onTapOutsideComposer
                ) {
                    timelineEmptyState
                } composer: {
                    composer
                }
            }

            VStack(spacing: 0) {
                if let pinnedTaskPlanMessage {
                    PlanSystemCard(message: pinnedTaskPlanMessage)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
                }

                repositoryLoadingToastOverlay
                if !isRepositoryLoadingToastVisible {
                    usageToastOverlay
                }
            }
        }
    }
}

private extension CodexMessage {
    var showsPinnedTaskChecklist: Bool {
        guard role == .system, kind == .plan else {
            return false
        }
        return !(planState?.steps.isEmpty ?? true)
    }
}
