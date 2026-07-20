// FILE: TurnTimelineCommandGroupView.swift
// Purpose: Renders a collapsible group of completed command and trace rows.
// Layer: View Component
// Exports: TurnTimelineCommandGroupView
// Depends on: SwiftUI, TurnTimelineRenderProjection, TurnTimelineMessageRow

import SwiftUI

struct TurnTimelineCommandGroupView: View {
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
    let autoScrollMode: TurnScrollOwnership
    let showsGlobalRunningIndicator: Bool
    let onRetryUserMessage: (String) -> Void
    let onTapAssistantRevert: (CodexMessage) -> Void
    let onTapSubagent: (CodexSubagentThreadPresentation) -> Void

    @State private var isExpanded = false

    private var title: String {
        var parts = [group.commandCount == 1 ? "Ran 1 command" : "Ran \(group.commandCount) commands"]
        if group.failedCommandCount > 0 {
            parts.append("\(group.failedCommandCount) failed")
        }
        if group.stoppedCommandCount > 0 {
            parts.append("\(group.stoppedCommandCount) stopped")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggleExpanded) {
                HStack(spacing: 8) {
                    RemodexIcon.image(systemName: "terminal", size: 17, relativeTo: .body)
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
                ForEach(group.orderedMessages) { message in
                    groupedMessageRow(message)
                }
            } else {
                ForEach(group.collapsedDetailMessages) { message in
                    groupedMessageRow(message)
                }
            }

            if let footerState = TurnTimelineCommandGroupAccessoryResolver.copyFooterState(
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
        .id(group.id)
    }

    private func groupedMessageRow(_ message: CodexMessage) -> some View {
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
            movesCopyAndRunningToGroupFooter: message.id == group.accessoryHostMessage?.id,
            onRetryUserMessage: onRetryUserMessage,
            onTapAssistantRevert: onTapAssistantRevert,
            onTapSubagent: onTapSubagent
        )
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded.toggle()
        }
    }
}
