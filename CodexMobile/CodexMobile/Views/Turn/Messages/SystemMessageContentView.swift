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
    let actionText: String
    let renderModel: MessageRowRenderModel
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
            if isContextCompactionNotice(text) {
                contextCompactionNoticeView(text: text)
            } else {
                defaultSystemView(text: text)
            }
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
                    .font(AppFont.body(weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contextMenu {
            selectableTextActions(text: actionText, usesMarkdownSelection: false)
        }
    }

    @ViewBuilder
    private var fileChangeSystemView: some View {
        let renderState = renderModel.fileChangeState ?? FileChangeRenderState(
            summary: nil,
            actionEntries: [],
            bodyText: text,
            detailBodyText: actionText
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
                    detailBodyText: renderState.detailBodyText,
                    messageID: message.id
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                selectableTextActions(text: actionText, usesMarkdownSelection: false)
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

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            selectableTextActions(text: actionText, usesMarkdownSelection: false)
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
                selectableTextActions(text: actionText, usesMarkdownSelection: false)
            }
    }

    private func contextCompactionNoticeView(text: String) -> some View {
        HStack(spacing: 14) {
            contextCompactionDivider

            HStack(spacing: 8) {
                RemodexIcon.image(systemName: "doc.text")
                    .font(AppFont.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(AppFont.title3(weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .fixedSize(horizontal: true, vertical: false)

            contextCompactionDivider
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .contextMenu {
            selectableTextActions(text: actionText, usesMarkdownSelection: false)
        }
    }

    private var contextCompactionDivider: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.42))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    // Keeps the synthetic compaction marker visually separate from adjacent transcript text.
    private func isContextCompactionNotice(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "Context compacted"
    }

    @ViewBuilder
    private func selectableTextActions(text: String, usesMarkdownSelection: Bool) -> some View {
        if let selectableText = timelineSelectableActionText(text) {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onSelectText(
                    SelectableMessageTextSheetState(
                        role: message.role,
                        text: selectableText,
                        usesMarkdownSelection: usesMarkdownSelection
                    )
                )
            } label: {
                Label("Select Text", systemImage: "text.cursor")
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                UIPasteboard.general.string = selectableText
            } label: {
                RemodexIcon.menuLabel("Copy", systemName: "doc.on.doc")
            }
        }
    }
}
