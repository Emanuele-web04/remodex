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

    @State private var isShowingPinnedPlanSheet = false

    // Pins the latest plan message so it appears as a compact accessory above the composer
    // instead of rendering inline in the timeline where it can overlay chat messages.
    private var pinnedTaskPlanMessage: CodexMessage? {
        messages.last { $0.isPlanSystemMessage }
    }

    // Filters ALL plan system messages from the timeline so they never render inline.
    // The latest one is surfaced via the composer plan accessory + sheet instead.
    private var timelineMessages: [CodexMessage] {
        messages.filter { !$0.isPlanSystemMessage }
    }

    // Avoids showing the generic "new chat" empty state behind a pinned plan-only accessory.
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
                composerWithPinnedPlanAccessory
            }

            VStack(spacing: 0) {
                repositoryLoadingToastOverlay
                if !isRepositoryLoadingToastVisible {
                    usageToastOverlay
                }
            }
        }
        .onChange(of: pinnedTaskPlanMessage?.id) { _, newValue in
            if newValue == nil {
                isShowingPinnedPlanSheet = false
            }
        }
        .sheet(isPresented: $isShowingPinnedPlanSheet) {
            if let pinnedTaskPlanMessage {
                PlanExecutionSheet(message: pinnedTaskPlanMessage)
            }
        }
    }

    // Keeps the active plan discoverable without covering the message timeline.
    private var composerWithPinnedPlanAccessory: some View {
        VStack(spacing: 8) {
            if let pinnedTaskPlanMessage {
                PlanExecutionAccessory(message: pinnedTaskPlanMessage) {
                    isShowingPinnedPlanSheet = true
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            composer
        }
        .animation(.easeInOut(duration: 0.18), value: pinnedTaskPlanMessage?.id)
    }
}

private extension CodexMessage {
    var isPlanSystemMessage: Bool {
        role == .system && kind == .plan
    }
}
