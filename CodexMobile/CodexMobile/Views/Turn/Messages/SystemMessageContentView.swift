// FILE: SystemMessageContentView.swift
// Purpose: Renders non-user/non-assistant prose system message content in timeline rows.
// Layer: View Component
// Exports: SystemMessageContentView
// Depends on: SwiftUI, UIKit, MessageRowRenderModel, turn system cards

import SwiftUI
import UIKit

struct SystemMessageContentView: View {
    let message: CodexMessage
    let text: String
    let renderModel: MessageRowRenderModel
    let showsStreamingAnimations: Bool
    let subagentOpenAction: ((CodexSubagentThreadPresentation) -> Void)?
    let onSelectText: (SelectableMessageTextSheetState) -> Void

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .thinking:
            thinkingSystemView
        case .toolActivity:
            toolActivitySystemView
        case .fileChange:
            fileChangeSystemView
        case .commandExecution:
            commandExecutionSystemView
        case .subagentAction:
            subagentActionSystemView
        case .plan:
            planSystemView
        case .userInputPrompt:
            userInputPromptSystemView
        case .chat:
            defaultSystemView(text: text)
        }
    }

    private var thinkingSystemView: some View {
        ThinkingSystemBlock(
            messageID: message.id,
            isStreaming: message.isStreaming,
            thinkingText: renderModel.thinkingText ?? "",
            thinkingContent: renderModel.thinkingContent ?? ThinkingDisclosureContent(sections: [], fallbackText: ""),
            activityPreview: renderModel.thinkingActivityPreview
        )
    }

    private var toolActivitySystemView: some View {
        let joined = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return VStack(alignment: .leading, spacing: 4) {
            if !joined.isEmpty {
                Text(joined)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if message.isStreaming && showsStreamingAnimations {
                TypingIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contextMenu {
            selectableTextActions(text: text, usesMarkdownSelection: false)
        }
    }

    @ViewBuilder
    private var fileChangeSystemView: some View {
        let renderState = renderModel.fileChangeState ?? FileChangeRenderState(
            summary: nil,
            actionEntries: [],
            bodyText: text
        )
        let actionEntries = renderState.actionEntries
        let hasActionRows = !actionEntries.isEmpty
        let allEntries = hasActionRows ? actionEntries : (renderState.summary?.entries ?? [])
        let fallbackText = renderState.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)

        if message.isStreaming {
            fileChangeStreamingSystemView(
                entries: allEntries,
                fallbackText: fallbackText
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                FileChangeSummaryBox(
                    entries: allEntries,
                    fallbackText: fallbackText,
                    messageID: message.id
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                selectableTextActions(text: text, usesMarkdownSelection: false)
            }
        }
    }

    private func fileChangeStreamingSystemView(
        entries: [TurnFileChangeSummaryEntry],
        fallbackText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
                Text(fallbackText.isEmpty ? text : fallbackText)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(entries) { entry in
                    FileChangeInlineActionRow(entry: entry)
                }
            }

            if showsStreamingAnimations {
                TypingIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            selectableTextActions(text: text, usesMarkdownSelection: false)
        }
    }

    @ViewBuilder
    private var commandExecutionSystemView: some View {
        if !text.isEmpty, let commandStatus = renderModel.commandStatus {
            CommandExecutionStatusCard(status: commandStatus, itemId: message.itemId)
        } else {
            defaultSystemView(text: text)
        }
    }

    @ViewBuilder
    private var subagentActionSystemView: some View {
        if let subagentAction = message.subagentAction {
            SubagentActionCard(
                parentThreadId: message.threadId,
                action: subagentAction,
                isStreaming: message.isStreaming && showsStreamingAnimations,
                onOpenSubagent: subagentOpenAction
            )
        } else {
            defaultSystemView(text: text)
        }
    }

    @ViewBuilder
    private var planSystemView: some View {
        if message.resolvedPlanPresentation?.isInlineResultVisible == true,
           let proposedPlan = message.proposedPlan {
            ProposedPlanResultCard(
                threadId: message.threadId,
                proposedPlan: proposedPlan,
                isStreaming: message.isStreaming,
                canImplement: message.resolvedPlanPresentation == .resultReady
            )
        } else {
            PlanSystemCard(message: message)
        }
    }

    @ViewBuilder
    private var userInputPromptSystemView: some View {
        if let request = message.structuredUserInputRequest {
            StructuredUserInputCard(request: request)
                .id(request.requestID)
        } else {
            defaultSystemView(text: text)
        }
    }

    private func defaultSystemView(text: String) -> some View {
        Text(text)
            .font(AppFont.footnote())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contextMenu {
                selectableTextActions(text: text, usesMarkdownSelection: false)
            }
    }

    @ViewBuilder
    private func selectableTextActions(text: String, usesMarkdownSelection: Bool) -> some View {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onSelectText(
                    SelectableMessageTextSheetState(
                        role: message.role,
                        text: trimmedText,
                        usesMarkdownSelection: usesMarkdownSelection
                    )
                )
            } label: {
                Label("Select Text", systemImage: "text.cursor")
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                UIPasteboard.general.string = trimmedText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}
