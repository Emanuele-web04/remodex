// FILE: TurnMessageComponents.swift
// Purpose: SwiftUI views for rendering message rows and lightweight timeline banners.
// Layer: View Components
// Exports: MessageRow
// Depends on: SwiftUI, TurnMarkdownTextRendering, TurnMessageRegexCache, SkillReferenceFormatter,
//   ThinkingDisclosureParser, CodeCommentDirectiveParser, TurnFileChangeSummaryParser,
//   TurnMessageCaches, TurnMarkdownModels, TurnDiffRenderer, SystemMessageContentView,
//   UserMessageBubble, AssistantTurnEndActionsView

import SwiftUI
import UIKit

// Keep RemodexTextKit selection out of the scrolling timeline. This is shared by both
// plain markdown rows and Mermaid-interleaved markdown segments.
let enablesInlineMarkdownSelectionInTimeline = false

private let timelineStreamingPlaceholderTexts: Set<String> = [
    "...",
    "Applying file changes...",
    "Updating...",
    "Coordinating agents...",
    "Planning...",
    "Waiting for input...",
]
private let timelinePlaceholderCheckByteLimit = 128
private let timelineFullTrimByteLimit = 64_000
private let timelineActionTextTrimByteLimit = 64_000

private func messageRowTextSignature(_ text: String) -> String {
    return TurnTextCacheKey.stableFingerprint(for: text)
}

private struct MessageRowMessageSignature: Equatable {
    let id: String
    let threadId: String
    let role: CodexMessageRole
    let kind: CodexMessageKind
    let assistantPhase: String?
    let textFingerprint: CodexMessageTextRenderSignature
    let fileMentions: [String]
    let skillMentions: [String]
    let pluginMentions: [String]
    let turnId: String?
    let itemId: String?
    let isStreaming: Bool
    let deliveryState: CodexMessageDeliveryState
    let attachments: [MessageRowAttachmentSignature]
    let planState: MessageRowPlanStateSignature?
    let planPresentation: CodexPlanPresentation?
    let proposedPlan: MessageRowProposedPlanSignature?
    let subagentAction: MessageRowSubagentActionSignature?
    let structuredUserInputRequest: MessageRowStructuredInputRequestSignature?
    let orderIndex: Int

    init(_ message: CodexMessage) {
        self.id = message.id
        self.threadId = message.threadId
        self.role = message.role
        self.kind = message.kind
        self.assistantPhase = message.assistantPhase
        self.textFingerprint = message.textRenderSignature
        self.fileMentions = message.fileMentions
        self.skillMentions = message.skillMentions
        self.pluginMentions = message.pluginMentions
        self.turnId = message.turnId
        self.itemId = message.itemId
        self.isStreaming = message.isStreaming
        self.deliveryState = message.deliveryState
        self.attachments = message.attachments.map(MessageRowAttachmentSignature.init)
        self.planState = message.planState.map(MessageRowPlanStateSignature.init)
        self.planPresentation = message.planPresentation
        self.proposedPlan = message.proposedPlan.map(MessageRowProposedPlanSignature.init)
        self.subagentAction = message.subagentAction.map(MessageRowSubagentActionSignature.init)
        self.structuredUserInputRequest = message.structuredUserInputRequest
            .map(MessageRowStructuredInputRequestSignature.init)
        self.orderIndex = message.orderIndex
    }
}

private struct MessageRowAttachmentSignature: Equatable {
    let id: String
    let thumbnailFingerprint: CodexTextContentFingerprint
    let payloadFingerprint: CodexTextContentFingerprint?
    let sourceFingerprint: CodexTextContentFingerprint?

    init(_ attachment: CodexImageAttachment) {
        self.id = attachment.id
        self.thumbnailFingerprint = attachment.thumbnailContentFingerprint
        self.payloadFingerprint = attachment.payloadContentFingerprint
        self.sourceFingerprint = attachment.sourceContentFingerprint
    }
}

private struct MessageRowProposedPlanSignature: Equatable {
    let bodyFingerprint: String
    let summaryFingerprint: String?

    init(_ plan: CodexProposedPlan) {
        self.bodyFingerprint = messageRowTextSignature(plan.body)
        self.summaryFingerprint = plan.summary.map(messageRowTextSignature)
    }
}

private struct MessageRowPlanStateSignature: Equatable {
    let explanationFingerprint: String?
    let steps: [MessageRowPlanStepSignature]

    init(_ planState: CodexPlanState) {
        self.explanationFingerprint = planState.explanation.map(messageRowTextSignature)
        self.steps = planState.steps.map(MessageRowPlanStepSignature.init)
    }
}

private struct MessageRowPlanStepSignature: Equatable {
    let id: String
    let stepFingerprint: String
    let status: CodexPlanStepStatus

    init(_ step: CodexPlanStep) {
        self.id = step.id
        self.stepFingerprint = messageRowTextSignature(step.step)
        self.status = step.status
    }
}

private struct MessageRowSubagentActionSignature: Equatable {
    let tool: String
    let status: String
    let promptFingerprint: String?
    let model: String?
    let receiverThreadIds: [String]
    let receiverAgents: [MessageRowSubagentRefSignature]
    let agentStates: [MessageRowSubagentStateSignature]

    init(_ action: CodexSubagentAction) {
        self.tool = action.tool
        self.status = action.status
        self.promptFingerprint = action.prompt.map(messageRowTextSignature)
        self.model = action.model
        self.receiverThreadIds = action.receiverThreadIds
        self.receiverAgents = action.receiverAgents.map(MessageRowSubagentRefSignature.init)
        self.agentStates = action.agentStates
            .keys
            .sorted()
            .compactMap { key in action.agentStates[key].map(MessageRowSubagentStateSignature.init) }
    }
}

private struct MessageRowSubagentRefSignature: Equatable {
    let threadId: String
    let agentId: String?
    let nickname: String?
    let role: String?
    let model: String?
    let promptFingerprint: String?

    init(_ ref: CodexSubagentRef) {
        self.threadId = ref.threadId
        self.agentId = ref.agentId
        self.nickname = ref.nickname
        self.role = ref.role
        self.model = ref.model
        self.promptFingerprint = ref.prompt.map(messageRowTextSignature)
    }
}

private struct MessageRowSubagentStateSignature: Equatable {
    let threadId: String
    let status: String
    let messageFingerprint: String?

    init(_ state: CodexSubagentState) {
        self.threadId = state.threadId
        self.status = state.status
        self.messageFingerprint = state.message.map(messageRowTextSignature)
    }
}

private struct MessageRowStructuredInputRequestSignature: Equatable {
    let requestID: JSONValue
    let questions: [MessageRowStructuredInputQuestionSignature]

    init(_ request: CodexStructuredUserInputRequest) {
        self.requestID = request.requestID
        self.questions = request.questions.map(MessageRowStructuredInputQuestionSignature.init)
    }
}

private struct MessageRowStructuredInputQuestionSignature: Equatable {
    let id: String
    let headerFingerprint: String
    let questionFingerprint: String
    let isOther: Bool
    let isSecret: Bool
    let selectionLimit: Int?
    let options: [MessageRowStructuredInputOptionSignature]

    init(_ question: CodexStructuredUserInputQuestion) {
        self.id = question.id
        self.headerFingerprint = messageRowTextSignature(question.header)
        self.questionFingerprint = messageRowTextSignature(question.question)
        self.isOther = question.isOther
        self.isSecret = question.isSecret
        self.selectionLimit = question.selectionLimit
        self.options = question.options.map(MessageRowStructuredInputOptionSignature.init)
    }
}

private struct MessageRowStructuredInputOptionSignature: Equatable {
    let id: String
    let labelFingerprint: String
    let descriptionFingerprint: String

    init(_ option: CodexStructuredUserInputOption) {
        self.id = option.id
        self.labelFingerprint = messageRowTextSignature(option.label)
        self.descriptionFingerprint = messageRowTextSignature(option.description)
    }
}

private struct TimelineShowMoreTextButton: View {
    let hiddenByteCount: Int
    let onTap: () -> Void

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onTap()
        } label: {
            HStack(spacing: 6) {
                RemodexIcon.image(systemName: "chevron.down")
                    .font(AppFont.caption(weight: .semibold))
                Text("Show more")
                    .font(AppFont.caption(weight: .semibold))
                Text(hiddenSizeLabel)
                    .font(AppFont.mono(.caption2))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show more text")
        .accessibilityValue(hiddenSizeLabel)
    }

    private var hiddenSizeLabel: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(hiddenByteCount),
            countStyle: .file
        )
    }
}

// Normalizes streaming placeholders once so assistant rows do not render transient status text
// as if it were final message content.
func timelineDisplayWindow(
    for message: CodexMessage,
    expansionLevel: Int = 0
) -> TimelineTextClippingPolicy.DisplayWindow {
    let rawText = message.text
    if message.isStreaming, isTimelineStreamingPlaceholder(rawText) {
        return TimelineTextClippingPolicy.DisplayWindow(text: "", isPartial: false, hiddenByteCount: 0)
    }
    let displaySource = timelineTrimmedDisplaySource(rawText)
    guard !displaySource.isEmpty else {
        return TimelineTextClippingPolicy.DisplayWindow(text: "", isPartial: false, hiddenByteCount: 0)
    }
    return TimelineTextClippingPolicy.displayWindow(
        for: message,
        text: displaySource,
        expansionLevel: expansionLevel
    )
}

func timelineDisplayText(for message: CodexMessage) -> String {
    timelineDisplayWindow(for: message).text
}

private func isTimelineStreamingPlaceholder(_ text: String) -> Bool {
    guard text.utf8.count <= timelinePlaceholderCheckByteLimit else {
        return false
    }
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedText.isEmpty || timelineStreamingPlaceholderTexts.contains(trimmedText)
}

private func timelineTrimmedDisplaySource(_ text: String) -> String {
    guard text.utf8.count > timelineFullTrimByteLimit else {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
}

// Keeps user actions faithful to the underlying message even when display text is clipped.
func timelineActionText(for message: CodexMessage) -> String {
    if message.isStreaming, isTimelineStreamingPlaceholder(message.text) {
        return ""
    }
    return message.text
}

// Context-menu actions may receive the full unclipped row. Avoid trimming huge strings while
// still suppressing empty small messages.
func timelineSelectableActionText(_ text: String) -> String? {
    guard !text.isEmpty else { return nil }
    guard text.utf8.count <= timelineActionTextTrimByteLimit else {
        return text
    }
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedText.isEmpty ? nil : trimmedText
}

// ─── Message row ────────────────────────────────────────────────────

struct MessageRow: View, Equatable {
    let message: CodexMessage
    let isRetryAvailable: Bool
    let onRetryUserMessage: (String) -> Void
    // Keeps the end-of-block accessory aligned with the active assistant turn.
    var assistantBlockAccessoryState: AssistantBlockAccessoryState? = nil
    var planSessionSource: CodexPlanSessionSource? = nil
    var allowsAssistantPlanFallbackRecovery: Bool = false
    var assistantTurnCompleted: Bool = false
    var threadMessagesForPlanMatching: [CodexMessage] = []
    var currentWorkingDirectory: String? = nil
    // Narrow token for inferred-plan fallback invalidation; this changes only when the
    // relevant native structured prompts change, not on every unrelated service mutation.
    var planMatchingFingerprint: Int = 0
    // Disables timer-driven adornments while the user reads older content.
    var showsStreamingAnimations: Bool = true
    // Passed as init params so .equatable() can invalidate only for row-visible action state.
    var inlineCommitAndPushAction: (() -> Void)? = nil
    var inlineCommitAndPushPhase: InlineCommitAndPushPhase? = nil
    var assistantRevertAction: ((CodexMessage) -> Void)? = nil
    var subagentOpenAction: ((CodexSubagentThreadPresentation) -> Void)? = nil
    @State private var selectableTextSheet: SelectableMessageTextSheetState?
    @State private var throttledAssistantDisplayText: String?
    @State private var pendingAssistantDisplayText: String?
    @State private var assistantDisplayUpdateTask: Task<Void, Never>?
    @State private var textExpansionLevel = 0

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        MessageRowMessageSignature(lhs.message) == MessageRowMessageSignature(rhs.message)
            && lhs.isRetryAvailable == rhs.isRetryAvailable
            && lhs.assistantBlockAccessoryState == rhs.assistantBlockAccessoryState
            && lhs.planSessionSource == rhs.planSessionSource
            && lhs.allowsAssistantPlanFallbackRecovery == rhs.allowsAssistantPlanFallbackRecovery
            && lhs.assistantTurnCompleted == rhs.assistantTurnCompleted
            && lhs.currentWorkingDirectory == rhs.currentWorkingDirectory
            && lhs.planMatchingFingerprint == rhs.planMatchingFingerprint
            && lhs.showsStreamingAnimations == rhs.showsStreamingAnimations
            && (lhs.inlineCommitAndPushAction != nil) == (rhs.inlineCommitAndPushAction != nil)
            && lhs.inlineCommitAndPushPhase == rhs.inlineCommitAndPushPhase
    }

    private var displayWindow: TimelineTextClippingPolicy.DisplayWindow {
        timelineDisplayWindow(for: message, expansionLevel: textExpansionLevel)
    }

    // Reuses the body-scoped display window so large clipped rows are not scanned twice.
    private func displayText(from window: TimelineTextClippingPolicy.DisplayWindow) -> String {
        if message.role == .assistant,
           message.isStreaming,
           let throttledAssistantDisplayText {
            return throttledAssistantDisplayText
        }

        return window.text
    }

    var body: some View {
        let window = displayWindow
        let text = displayText(from: window)
        let actionText = timelineActionText(for: message)
        let renderModel = MessageRowRenderModelCache.model(for: message, displayText: text)
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            Group {
                switch message.role {
                case .user:
                    userBubble(
                        text: text,
                        actionText: actionText,
                        isProgressiveTextWindow: window.isPartial
                    )
                case .assistant:
                    assistantView(text: text, actionText: actionText, renderModel: renderModel)
                case .system:
                    VStack(alignment: .leading, spacing: 8) {
                        SystemMessageContentView(
                            message: message,
                            text: text,
                            actionText: actionText,
                            renderModel: renderModel,
                            showsStreamingAnimations: showsStreamingAnimations,
                            subagentOpenAction: subagentOpenAction,
                            onSelectText: { selectableTextSheet = $0 }
                        )
                        if let assistantBlockAccessoryState, hasTurnEndActions {
                            assistantTurnEndActions(accessoryState: assistantBlockAccessoryState)
                        }
                        if let assistantBlockAccessoryState,
                           shouldRenderSystemCopyAccessory(assistantBlockAccessoryState) {
                            CopyBlockButton(
                                text: assistantBlockAccessoryState.allowsCopy
                                    ? assistantBlockAccessoryState.copyText
                                    : nil,
                                isRunning: assistantBlockAccessoryState.showsRunningIndicator
                            )
                        }
                    }
                    // Keep block-end actions pinned left when a system row is the last item in a turn.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if window.isPartial {
                TimelineShowMoreTextButton(
                    hiddenByteCount: window.hiddenByteCount,
                    onTap: expandVisibleText
                )
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
            }
        }
        .sheet(item: $selectableTextSheet) { sheet in
            SelectableMessageTextSheet(state: sheet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onAppear {
            synchronizeAssistantDisplayText(immediate: true)
        }
        .onChange(of: message.text) { _, _ in
            synchronizeAssistantDisplayText(immediate: !message.isStreaming)
        }
        .onChange(of: message.isStreaming) { _, isStreaming in
            synchronizeAssistantDisplayText(immediate: !isStreaming)
        }
        .onChange(of: textExpansionLevel) { _, _ in
            synchronizeAssistantDisplayText(immediate: true)
        }
        .onDisappear {
            assistantDisplayUpdateTask?.cancel()
            assistantDisplayUpdateTask = nil
        }
    }

    private func userBubble(
        text: String,
        actionText: String,
        isProgressiveTextWindow: Bool
    ) -> some View {
        UserMessageBubble(
            message: message,
            text: text,
            actionText: actionText,
            isProgressiveTextWindow: isProgressiveTextWindow,
            isRetryAvailable: isRetryAvailable,
            onRetryUserMessage: onRetryUserMessage
        )
    }

    private func assistantView(text: String, actionText: String, renderModel: MessageRowRenderModel) -> some View {
        let commentContent = renderModel.codeCommentContent
        let bodyText = commentContent?.fallbackText ?? text
        let mermaidContent = renderModel.mermaidContent
        let shouldParseStructuredAssistantContent = !message.isStreaming
        let assistantProposedPlanCandidate = shouldParseStructuredAssistantContent
            && commentContent == nil && mermaidContent == nil
            ? (message.proposedPlan ?? CodexProposedPlanParser.parse(from: bodyText))
            : nil
        let currentPlanSessionSource = planSessionSource
        let isNativePlanSession = currentPlanSessionSource != nil && currentPlanSessionSource != .compatibilityFallback
        let proposedPlan = !isNativePlanSession
            ? (assistantProposedPlanCandidate
                ?? (
                    commentContent == nil
                        && mermaidContent == nil
                        && currentPlanSessionSource == .compatibilityFallback
                        && InferredPlanQuestionnaireParser.parseAssistantMessage(bodyText) == nil
                    ? CodexProposedPlanParser.parseAssistantFallback(from: bodyText)
                            : nil
                ))
            : nil
        let renderedPlanText = assistantProposedPlanCandidate == nil
            ? bodyText
            : (
                CodexProposedPlanParser.containsEnvelope(in: bodyText)
                    ? (CodexProposedPlanParser.removingEnvelope(from: bodyText) ?? "")
                    : ""
            )
        let inferredQuestionnaire = shouldParseStructuredAssistantContent && commentContent == nil
            ? resolvedInferredPlanQuestionnaire(
                bodyText: bodyText,
                message: message,
                threadMessages: threadMessagesForPlanMatching,
                shouldRecoverFallback: allowsAssistantPlanFallbackRecovery,
                parse: InferredPlanQuestionnaireParser.parseAssistantMessage
            )
            : nil
        let visibleAssistantText = renderedPlanText
        let suppressNativeProposedPlanShell = isNativePlanSession
            && assistantProposedPlanCandidate != nil
            && visibleAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inferredQuestionnaire == nil
            && mermaidContent == nil
        let usesCachedAssistantImageContent = !message.isStreaming && visibleAssistantText == bodyText
        let assistantImageReferences = usesCachedAssistantImageContent
            ? renderModel.assistantImageReferences
            : []
        let assistantInlineContentSegments = usesCachedAssistantImageContent
            ? renderModel.assistantInlineContentSegments
            : []
        let trailingAssistantImageReferences = assistantImageReferences.filter { !$0.isTemporaryScreenshotImage }
        let visibleAssistantTextWithoutImageSyntax = assistantImageReferences.isEmpty
            ? visibleAssistantText
            : (renderModel.assistantTextWithoutImageSyntax ?? visibleAssistantText)
        let trimmedVisibleAssistantText = visibleAssistantTextWithoutImageSyntax
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVisibleAssistantText = !trimmedVisibleAssistantText.isEmpty
        let rendersTemporaryImagesInline = !assistantInlineContentSegments.isEmpty
            && !message.isStreaming
            && mermaidContent == nil
            && proposedPlan == nil
            && inferredQuestionnaire == nil
        let hasRenderableAssistantContent = hasVisibleAssistantText
            || proposedPlan != nil
            || !trailingAssistantImageReferences.isEmpty
            || rendersTemporaryImagesInline
        // Copy the full underlying text even when the rendered row is clipped.
        // Image-only artifact rows still avoid a duplicate copy affordance.
        let assistantCopyText: String? = {
            if !actionText.isEmpty {
                return actionText
            }
            if !trimmedVisibleAssistantText.isEmpty {
                return trimmedVisibleAssistantText
            }
            return trailingAssistantImageReferences.isEmpty ? assistantBlockAccessoryState?.copyText : nil
        }()
        return VStack(alignment: .leading, spacing: 4) {
            if let commentContent, commentContent.hasFindings {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(commentContent.findings) { finding in
                        CodeCommentFindingCard(finding: finding)
                    }
                }
            }

            if hasRenderableAssistantContent {
                if let mermaidContent {
                    MermaidMarkdownContentView(content: mermaidContent)
                } else if let inferredQuestionnaire {
                    if let introText = inferredQuestionnaire.introText {
                        MarkdownTextView(
                            text: introText,
                            profile: .assistantProse,
                            enablesSelection: enablesInlineMarkdownSelectionInTimeline,
                            constrainsToAvailableWidth: true
                        )
                    }

                    InferredPlanQuestionnaireCard(
                        message: message,
                        questionnaire: inferredQuestionnaire
                    )

                    if let outroText = inferredQuestionnaire.outroText {
                        Text(outroText)
                            .font(AppFont.footnote())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let proposedPlan {
                    // Compatibility-mode proposed plans still render inline from assistant text.
                    if !renderedPlanText.isEmpty {
                        MarkdownTextView(
                            text: renderedPlanText,
                            profile: .assistantProse,
                            enablesSelection: enablesInlineMarkdownSelectionInTimeline,
                            constrainsToAvailableWidth: true
                        )
                    }

                    ProposedPlanResultCard(
                        threadId: message.threadId,
                        proposedPlan: proposedPlan,
                        isStreaming: message.isStreaming,
                        canImplement: assistantTurnCompleted
                    )
                } else if rendersTemporaryImagesInline {
                    ForEach(assistantInlineContentSegments) { segment in
                        switch segment {
                        case .text(_, let segmentText):
                            MarkdownTextView(
                                text: segmentText,
                                profile: .assistantProse,
                                enablesSelection: enablesInlineMarkdownSelectionInTimeline,
                                constrainsToAvailableWidth: true
                            )
                        case .image(let reference):
                            AssistantMarkdownImagePreviewButton(
                                reference: reference,
                                currentWorkingDirectory: currentWorkingDirectory
                            )
                        }
                    }
                } else if message.isStreaming {
                    if hasVisibleAssistantText {
                        StreamingAssistantMarkdownTextView(
                            text: visibleAssistantTextWithoutImageSyntax,
                            enablesSelection: enablesInlineMarkdownSelectionInTimeline,
                            constrainsToAvailableWidth: true,
                            animatesReveal: showsStreamingAnimations
                        )
                    }
                } else {
                    if hasVisibleAssistantText {
                        MarkdownTextView(
                            text: visibleAssistantTextWithoutImageSyntax,
                            profile: .assistantProse,
                            enablesSelection: enablesInlineMarkdownSelectionInTimeline,
                            constrainsToAvailableWidth: true
                        )
                    }
                }

                if !trailingAssistantImageReferences.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(trailingAssistantImageReferences) { reference in
                            AssistantMarkdownImagePreviewButton(
                                reference: reference,
                                currentWorkingDirectory: currentWorkingDirectory
                            )
                        }
                    }
                }
            }

            if !suppressNativeProposedPlanShell,
               let assistantBlockAccessoryState,
               hasTurnEndActions {
                assistantTurnEndActions(accessoryState: assistantBlockAccessoryState)
            }

            if !suppressNativeProposedPlanShell,
               let assistantBlockAccessoryState,
               shouldRenderAssistantCopyAccessory(assistantBlockAccessoryState) {
                CopyBlockButton(
                    text: assistantBlockAccessoryState.allowsCopy ? assistantCopyText : nil,
                    isRunning: assistantBlockAccessoryState.showsRunningIndicator
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            selectableTextActions(text: actionText, usesMarkdownSelection: true)
        }
    }

    private var hasTurnEndActions: Bool {
        // Tail Revert / Commit & Push controls are paused for now.
        // return AssistantTurnEndActionVisibility.shouldShow(
        //     accessoryState: assistantBlockAccessoryState
        // )
        return false
    }

    private func shouldRenderSystemCopyAccessory(_ state: AssistantBlockAccessoryState) -> Bool {
        state.showsRunningIndicator || (state.allowsCopy && state.copyText != nil)
    }

    // Assistant rows get their copy payload from the row text, so the accessory state
    // carries the copy permission separately from the potentially large text value.
    private func shouldRenderAssistantCopyAccessory(_ state: AssistantBlockAccessoryState) -> Bool {
        state.showsRunningIndicator || state.allowsCopy
    }

    private func expandVisibleText() {
        textExpansionLevel += 1
        synchronizeAssistantDisplayText(immediate: true)
    }

    private func assistantTurnEndActions(accessoryState: AssistantBlockAccessoryState) -> some View {
        AssistantTurnEndActionsView(
            message: message,
            accessoryState: accessoryState,
            inlineCommitAndPushAction: inlineCommitAndPushAction,
            inlineCommitAndPushPhase: inlineCommitAndPushPhase,
            assistantRevertAction: assistantRevertAction
        )
    }

    @ViewBuilder
    private func selectableTextActions(text: String, usesMarkdownSelection: Bool) -> some View {
        if let selectableText = timelineSelectableActionText(text) {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                selectableTextSheet = SelectableMessageTextSheetState(
                    role: message.role,
                    text: selectableText,
                    usesMarkdownSelection: usesMarkdownSelection
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

    // Throttles only the assistant row's visible text during streaming so markdown/layout
    // work stays local to that cell instead of firing on every token delta.
    private func synchronizeAssistantDisplayText(immediate: Bool) {
        guard message.role == .assistant else {
            throttledAssistantDisplayText = nil
            pendingAssistantDisplayText = nil
            assistantDisplayUpdateTask?.cancel()
            assistantDisplayUpdateTask = nil
            return
        }

        let nextText = timelineDisplayWindow(for: message, expansionLevel: textExpansionLevel).text
        pendingAssistantDisplayText = nextText

        guard message.isStreaming else {
            assistantDisplayUpdateTask?.cancel()
            assistantDisplayUpdateTask = nil
            throttledAssistantDisplayText = nextText
            return
        }

        if immediate {
            assistantDisplayUpdateTask?.cancel()
            assistantDisplayUpdateTask = nil
            throttledAssistantDisplayText = nextText
            return
        }

        if assistantDisplayUpdateTask != nil {
            return
        }

        assistantDisplayUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            throttledAssistantDisplayText = pendingAssistantDisplayText ?? nextText
            assistantDisplayUpdateTask = nil
        }
    }
}
