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

// Keep Textual selection out of the scrolling timeline. This is shared by both
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

// Normalizes streaming placeholders once so assistant rows do not render transient status text
// as if it were final message content.
func timelineDisplayText(for message: CodexMessage) -> String {
    let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if message.isStreaming {
        if trimmedText.isEmpty || timelineStreamingPlaceholderTexts.contains(trimmedText) {
            return ""
        }
    }
    return trimmedText
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

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
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

    // Computed once per body evaluation and reused by all sub-views.
    private var displayText: String {
        if message.role == .assistant,
           message.isStreaming,
           let throttledAssistantDisplayText {
            return throttledAssistantDisplayText
        }

        return timelineDisplayText(for: message)
    }

    var body: some View {
        let text = displayText
        let renderModel = MessageRowRenderModelCache.model(for: message, displayText: text)
        Group {
            switch message.role {
            case .user:
                userBubble(text: text)
            case .assistant:
                assistantView(text: text, renderModel: renderModel)
            case .system:
                VStack(alignment: .leading, spacing: 8) {
                    SystemMessageContentView(
                        message: message,
                        text: text,
                        renderModel: renderModel,
                        showsStreamingAnimations: showsStreamingAnimations,
                        subagentOpenAction: subagentOpenAction,
                        onSelectText: { selectableTextSheet = $0 }
                    )
                    if let assistantBlockAccessoryState, hasTurnEndActions {
                        assistantTurnEndActions(accessoryState: assistantBlockAccessoryState)
                    }
                    if let assistantBlockAccessoryState {
                        CopyBlockButton(
                            text: assistantBlockAccessoryState.copyText,
                            isRunning: assistantBlockAccessoryState.showsRunningIndicator
                        )
                    }
                }
                // Keep block-end actions pinned left when a system row is the last item in a turn.
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .onDisappear {
            assistantDisplayUpdateTask?.cancel()
            assistantDisplayUpdateTask = nil
        }
    }

    private func userBubble(text: String) -> some View {
        UserMessageBubble(
            message: message,
            text: text,
            isRetryAvailable: isRetryAvailable,
            onRetryUserMessage: onRetryUserMessage
        )
    }

    private func assistantView(text: String, renderModel: MessageRowRenderModel) -> some View {
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
        // Copy only the visible prose. Image-only artifact rows should not expose a
        // second copy affordance for the hidden markdown image syntax.
        let assistantCopyText: String? = {
            if !trimmedVisibleAssistantText.isEmpty {
                return trimmedVisibleAssistantText
            }
            return trailingAssistantImageReferences.isEmpty ? assistantBlockAccessoryState?.copyText : nil
        }()
        return VStack(alignment: .leading, spacing: 8) {
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
                            constrainsToAvailableWidth: true
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

            if !suppressNativeProposedPlanShell && message.isStreaming && showsStreamingAnimations {
                TypingIndicator()
            }

            if !suppressNativeProposedPlanShell,
               let assistantBlockAccessoryState,
               hasTurnEndActions {
                assistantTurnEndActions(accessoryState: assistantBlockAccessoryState)
            }

            if !suppressNativeProposedPlanShell, let assistantBlockAccessoryState {
                CopyBlockButton(
                    text: assistantCopyText,
                    isRunning: assistantBlockAccessoryState.showsRunningIndicator
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            selectableTextActions(text: text, usesMarkdownSelection: true)
        }
    }

    private var hasTurnEndActions: Bool {
        AssistantTurnEndActionVisibility.shouldShow(
            accessoryState: assistantBlockAccessoryState
        )
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
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                selectableTextSheet = SelectableMessageTextSheetState(
                    role: message.role,
                    text: trimmedText,
                    usesMarkdownSelection: usesMarkdownSelection
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

        let nextText = timelineDisplayText(for: message)
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
