// FILE: TurnPlanModeComponents.swift
// Purpose: Renders inline plan cards, composer plan affordances, and structured question cards.
// Layer: View Component
// Exports: PlanSystemCard, PlanExecutionAccessory, PlanExecutionSheet, StructuredUserInputAccessory,
//   StructuredUserInputSheet, StructuredUserInputCard
// Depends on: SwiftUI, CodexService, CodexMessage, StructuredUserInputCardView

import SwiftUI

struct PlanSystemCard: View {
    @Environment(CodexService.self) private var codex

    let message: CodexMessage

    private var threadMessages: [CodexMessage] {
        codex.messages(for: message.threadId)
    }

    private var bodyText: String {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders: Set<String> = ["Planning..."]
        guard !trimmed.isEmpty, !placeholders.contains(trimmed) else {
            return ""
        }
        return trimmed
    }

    private var explanationText: String? {
        let trimmed = message.planState?.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        guard trimmed != bodyText else {
            return nil
        }
        return trimmed
    }

    private var rawInferredQuestionnaire: InferredPlanQuestionnaire? {
        resolvedInferredPlanQuestionnaire(
            bodyText: bodyText,
            message: message,
            threadMessages: threadMessages,
            shouldRecoverFallback: codex.allowsInferredPlanQuestionnaireFallback(for: message.threadId),
            windowEndOrderIndex: nextPlanMessageOrderIndex,
            parse: InferredPlanQuestionnaireParser.parse
        )
    }

    private var inferredQuestionnaire: InferredPlanQuestionnaire? {
        rawInferredQuestionnaire
    }

    private var nextPlanMessageOrderIndex: Int? {
        threadMessages
            .filter { candidate in
                candidate.id != message.id
                    && candidate.role == .system
                    && candidate.kind == .plan
                    && candidate.orderIndex > message.orderIndex
            }
            .map(\.orderIndex)
            .min()
    }
    var body: some View {
        PlanModeCardContainer(title: "Plan", showsProgress: message.isStreaming) {
            if let inferredQuestionnaire {
                if let introText = inferredQuestionnaire.introText {
                    MarkdownTextView(text: introText, profile: .assistantProse)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let explanationText {
                    MarkdownTextView(text: explanationText, profile: .assistantProse)
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
            } else if !bodyText.isEmpty {
                MarkdownTextView(text: bodyText, profile: .assistantProse)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let explanationText {
                MarkdownTextView(text: explanationText, profile: .assistantProse)
            }

            if inferredQuestionnaire == nil,
               let explanationText,
               !bodyText.isEmpty,
               explanationText != bodyText {
                Text(explanationText)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }

            if let steps = message.planState?.steps, !steps.isEmpty {
                PlanStepList(steps: steps)
            }
        }
    }
}

private struct NormalizedQuestionSignature: Hashable {
    let question: String
    let options: [String]

    init(_ question: CodexStructuredUserInputQuestion) {
        self.question = question.question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.options = question.options.map {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

func resolvedInferredPlanQuestionnaire(
    bodyText: String,
    message: CodexMessage,
    threadMessages: [CodexMessage],
    shouldRecoverFallback: Bool = true,
    windowEndOrderIndex: Int? = nil,
    parse: (String) -> InferredPlanQuestionnaire?
) -> InferredPlanQuestionnaire? {
    // Prefer native requestUserInput when it exists, but still recover clearly
    // structured plain-text fallbacks if the runtime regresses inside the same thread.
    guard shouldRecoverFallback,
          let questionnaire = parse(bodyText),
          !hasMatchingNativeStructuredPrompt(
            for: questionnaire,
            message: message,
            threadMessages: threadMessages,
            windowEndOrderIndex: windowEndOrderIndex
          ) else {
        return nil
    }

    return questionnaire
}

private func hasMatchingNativeStructuredPrompt(
    for questionnaire: InferredPlanQuestionnaire,
    message: CodexMessage,
    threadMessages: [CodexMessage],
    windowEndOrderIndex: Int?
) -> Bool {
    let inferredSignature = normalizedQuestionSignature(for: questionnaire.questions)

    return threadMessages.contains { candidate in
        guard candidate.kind == .userInputPrompt,
              let request = candidate.structuredUserInputRequest else {
            return false
        }

        if let messageTurnId = message.turnId, let candidateTurnId = candidate.turnId {
            return messageTurnId == candidateTurnId
        }

        guard candidate.orderIndex >= message.orderIndex else {
            return false
        }
        if let windowEndOrderIndex,
           candidate.orderIndex >= windowEndOrderIndex {
            return false
        }

        return normalizedQuestionSignature(for: request.questions) == inferredSignature
    }
}

private func normalizedQuestionSignature(
    for questions: [CodexStructuredUserInputQuestion]
) -> [NormalizedQuestionSignature] {
    questions.map(NormalizedQuestionSignature.init)
}

struct InferredPlanQuestionnaireCard: View {
    @Environment(CodexService.self) private var codex

    let message: CodexMessage
    let questionnaire: InferredPlanQuestionnaire

    @State private var isSubmitting = false
    @State private var hasSubmittedResponse = false

    var body: some View {
        StructuredUserInputCardView(
            questions: questionnaire.questions,
            isSubmitting: isSubmitting,
            hasSubmittedResponse: hasSubmittedResponse,
            onSelectOption: { _, _ in },
            onSubmit: { answers in
                submitAnswers(answers)
            }
        )
    }

    private func submitAnswers(_ answersByQuestionID: [String: [String]]) {
        guard answersByQuestionID.count == questionnaire.questions.count else {
            return
        }

        isSubmitting = true
        hasSubmittedResponse = true
        Task { @MainActor in
            do {
                try await codex.submitInferredPlanQuestionnaireResponse(
                    threadId: message.threadId,
                    questions: questionnaire.questions,
                    answersByQuestionID: answersByQuestionID
                )
                isSubmitting = false
            } catch {
                isSubmitting = false
                hasSubmittedResponse = false
                codex.lastErrorMessage = codex.userFacingTurnErrorMessage(from: error)
            }
        }
    }
}

struct ProposedPlanResultCard: View {
    @Environment(CodexService.self) private var codex

    let threadId: String
    let proposedPlan: CodexProposedPlan
    let isStreaming: Bool
    let canImplement: Bool

    @State private var isImplementing = false
    @State private var hasStartedImplementation = false

    private var canRenderImplementationAction: Bool {
        canImplement && !isStreaming && !proposedPlan.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isImplementationLocked: Bool {
        isImplementing || hasStartedImplementation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proposed plan")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(.primary)

            MarkdownTextView(text: proposedPlan.body, profile: .assistantProse)
                .fixedSize(horizontal: false, vertical: true)

            if canRenderImplementationAction {
                Button {
                    implementPlan()
                } label: {
                    HStack(spacing: 8) {
                        if isImplementationLocked {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(AppFont.system(size: 14, weight: .semibold))
                        }
                        Text(isImplementationLocked ? "Starting implementation…" : "Implement plan")
                            .font(AppFont.subheadline(weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isImplementationLocked)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(.separator).opacity(0.12))
                )
        )
    }

    private func implementPlan() {
        guard canRenderImplementationAction, !isImplementationLocked else {
            return
        }

        isImplementing = true
        Task { @MainActor in
            do {
                try await codex.implementProposedPlan(
                    threadId: threadId,
                    proposedPlan: proposedPlan
                )
                isImplementing = false
                hasStartedImplementation = true
            } catch {
                isImplementing = false
                hasStartedImplementation = false
                codex.lastErrorMessage = codex.userFacingTurnErrorMessage(from: error)
            }
        }
    }
}

struct PlanExecutionAccessory: View {
    let message: CodexMessage
    let onTap: () -> Void

    // Maps the live message into a previewable snapshot so the visual card can stay isolated.
    private var snapshot: PlanAccessorySnapshot {
        PlanAccessorySnapshot(message: message)
    }

    var body: some View {
        PlanAccessoryCard(snapshot: snapshot, onTap: onTap)
    }
}

struct PlanExecutionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let message: CodexMessage

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PlanSystemCard(message: message)
                }
                .padding(16)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Active plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct StructuredUserInputCard: View {
    @Environment(CodexService.self) private var codex

    let request: CodexStructuredUserInputRequest

    @State private var isSubmitting = false
    @State private var hasSubmittedResponse = false

    var body: some View {
        StructuredUserInputCardView(
            questions: request.questions,
            isSubmitting: isSubmitting,
            hasSubmittedResponse: hasSubmittedResponse,
            onSelectOption: { _, _ in },
            onSubmit: { answers in
                submitAnswers(answers)
            }
        )
    }

    private func submitAnswers(_ answersByQuestionID: [String: [String]]) {
        guard answersByQuestionID.count == request.questions.count else {
            return
        }

        isSubmitting = true
        hasSubmittedResponse = true
        Task { @MainActor in
            do {
                try await codex.respondToStructuredUserInput(
                    requestID: request.requestID,
                    answersByQuestionID: answersByQuestionID
                )
                isSubmitting = false
            } catch {
                isSubmitting = false
                hasSubmittedResponse = false
                codex.lastErrorMessage = codex.userFacingTurnErrorMessage(from: error)
            }
        }
    }
}

struct StructuredUserInputAccessory: View {
    let message: CodexMessage
    let onTap: () -> Void

    private var questionCount: Int {
        message.structuredUserInputRequest?.questions.count ?? 0
    }

    var body: some View {
        Button(action: onTap) {
            PlanModeCardContainer(title: "Input needed", showsProgress: false) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(questionCount == 1 ? "Codex needs one answer" : "Codex needs \(questionCount) answers")
                            .font(AppFont.subheadline(weight: .medium))
                            .foregroundStyle(.primary)

                        Text("Open the prompt to review the plan and respond.")
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.up.circle.fill")
                        .font(AppFont.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(.plan))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct StructuredUserInputSheet: View {
    @Environment(\.dismiss) private var dismiss

    let requestMessage: CodexMessage
    let planMessage: CodexMessage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let planMessage {
                        PlanSystemCard(message: planMessage)
                    }

                    if let request = requestMessage.structuredUserInputRequest {
                        StructuredUserInputCard(request: request)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Questions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct PlanStepList: View {
    let steps: [CodexPlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps) { step in
                PlanStepRow(step: step)
            }
        }
    }
}

private struct PlanStepRow: View {
    let step: CodexPlanStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .font(AppFont.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.step)
                    .font(AppFont.body())
                    .foregroundStyle(.primary)

                Text(statusLabel)
                    .font(AppFont.caption2(weight: .medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }
        }
    }

    private var statusLabel: String {
        switch step.status {
        case .pending:
            return "Pending"
        case .inProgress:
            return "In progress"
        case .completed:
            return "Completed"
        }
    }

    private var statusSymbol: String {
        switch step.status {
        case .pending:
            return "circle"
        case .inProgress:
            return "clock"
        case .completed:
            return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch step.status {
        case .pending:
            return .secondary
        case .inProgress:
            return .orange
        case .completed:
            return .green
        }
    }
}

struct InferredPlanQuestionnaire: Hashable {
    let introText: String?
    let questions: [CodexStructuredUserInputQuestion]
    let outroText: String?
}

enum InferredPlanQuestionnaireParser {
    static func parseAssistantMessage(_ text: String) -> InferredPlanQuestionnaire? {
        if hasAssistantQuestionnaireCue(in: text) {
            return parse(text)
        }

        if let choiceListQuestionnaire = parseAssistantChoiceList(text) {
            return choiceListQuestionnaire
        }

        // Some plan-mode fallbacks skip the "question for you" preamble and go straight
        // into a numbered decision list. Recover those into the native UI too.
        guard hasStructuredAssistantQuestionnaireShape(in: text) else {
            return nil
        }

        return parse(text)
    }

    static func parse(_ text: String) -> InferredPlanQuestionnaire? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let lines = trimmed.components(separatedBy: .newlines)
        var introLines: [String] = []
        var blocks: [QuestionBlock] = []
        var currentBlock: QuestionBlock?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = questionNumber(from: line) {
                if let currentBlock {
                    blocks.append(currentBlock)
                }
                currentBlock = QuestionBlock(number: number, lines: [questionBody(from: line)])
                continue
            }

            if currentBlock != nil {
                currentBlock?.lines.append(line)
            } else {
                introLines.append(line)
            }
        }

        if let currentBlock {
            blocks.append(currentBlock)
        }

        let parsedQuestions = blocks.map(parseQuestionBlock)
        let usableParsedQuestions = dropTrailingIncompleteQuestions(from: parsedQuestions)
        let questions = usableParsedQuestions.compactMap(\.question)
        guard !questions.isEmpty, questions.count == usableParsedQuestions.count else {
            return nil
        }

        let hasEnoughStructure = questions.count >= 2 || questions.contains(where: { !$0.options.isEmpty })
        guard hasEnoughStructure else {
            return nil
        }

        guard usableParsedQuestions.allSatisfy(\.isQuestionLike) else {
            return nil
        }

        let introText = normalizeTextBlock(introLines)
        let outroText = normalizeTextBlock(usableParsedQuestions.flatMap(\.outroLines))

        return InferredPlanQuestionnaire(
            introText: introText,
            questions: questions,
            outroText: outroText
        )
    }

    private static func parseQuestionBlock(_ block: QuestionBlock) -> ParsedQuestionBlock {
        var promptLines: [String] = []
        var optionLines: [String] = []
        var outroLines: [String] = []
        var reachedOutro = false

        for rawLine in block.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                if !reachedOutro, !optionLines.isEmpty {
                    continue
                }
                if reachedOutro {
                    outroLines.append(line)
                } else {
                    promptLines.append(line)
                }
                continue
            }

            if shouldTreatAsOutroLine(line) {
                reachedOutro = true
            }

            if reachedOutro {
                outroLines.append(line)
                continue
            }

            if let option = bulletText(from: line) {
                optionLines.append(option)
            } else if !optionLines.isEmpty {
                let lastIndex = optionLines.index(before: optionLines.endIndex)
                optionLines[lastIndex] = "\(optionLines[lastIndex]) \(line)".trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                promptLines.append(line)
            }
        }

        let rawPrompt = normalizeTextBlock(promptLines) ?? ""
        guard !rawPrompt.isEmpty else {
            return ParsedQuestionBlock(question: nil, outroLines: outroLines)
        }

        let explicitOptions = optionLines.map { optionLine in
            CodexStructuredUserInputOption(label: optionLine, description: "")
        }
        let inlineOptions = explicitOptions.isEmpty ? inferredInlineOptions(from: rawPrompt) : nil
        let prompt = inlineOptions?.question ?? rawPrompt
        let options = inlineOptions?.options ?? explicitOptions

        let selectionLimit = inferredSelectionLimit(from: prompt)
        let question = CodexStructuredUserInputQuestion(
            id: "inferred_plan_q_\(block.number)",
            header: "",
            question: prompt,
            isOther: false,
            isSecret: false,
            selectionLimit: selectionLimit,
            options: options
        )

        return ParsedQuestionBlock(question: question, outroLines: outroLines)
    }

    private static func questionNumber(from line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(
            of: #"^\**\s*|\s*\**$"#,
            with: "",
            options: .regularExpression
        )

        guard let match = normalized.range(
            of: #"^\d+[\.\)]\s+"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let prefix = String(normalized[..<match.upperBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = prefix.replacingOccurrences(
            of: #"[^\d]"#,
            with: "",
            options: .regularExpression
        )

        return Int(digits)
    }

    private static func questionBody(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(
            of: #"^\**\s*|\s*\**$"#,
            with: "",
            options: .regularExpression
        )

        guard let match = normalized.range(
            of: #"^\d+[\.\)]\s+"#,
            options: .regularExpression
        ) else {
            return normalized
        }

        return String(normalized[match.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bulletText(from line: String) -> String? {
        let prefixes = ["• ", "- ", "* ", "+ ", "•", "-", "*", "+"]
        for prefix in prefixes {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func inferredSelectionLimit(from prompt: String) -> Int? {
        let lowered = prompt.lowercased()
        if lowered.contains("up to two") || lowered.contains("choose two") || lowered.contains("pick two") {
            return 2
        }
        if lowered.contains("up to three") || lowered.contains("choose three") || lowered.contains("pick three") {
            return 3
        }
        return nil
    }

    private static func shouldTreatAsOutroLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.hasPrefix("once you answer")
            || lowered.hasPrefix("if you answer")
            || lowered.hasPrefix("when you answer")
            || lowered.hasPrefix("after you answer")
            || lowered.hasPrefix("i’ll turn this into")
            || lowered.hasPrefix("i'll turn this into")
            || lowered.hasPrefix("then i’ll")
            || lowered.hasPrefix("then i'll")
    }

    private static func hasAssistantQuestionnaireCue(in text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("questions for you")
            || lowered.contains("question for you")
            || lowered.contains("quick questions")
            || lowered.contains("a few questions")
            || lowered.contains("need your input")
            || lowered.contains("need your answer")
            || lowered.contains("need your answers")
            || lowered.contains("answer these")
            || lowered.contains("once you answer")
            || lowered.contains("if you answer")
            || lowered.contains("when you answer")
            || lowered.contains("after you answer")
    }

    private static func parseAssistantChoiceList(_ text: String) -> InferredPlanQuestionnaire? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let lines = trimmed.components(separatedBy: .newlines)
        guard let cueIndex = lines.firstIndex(where: { isAssistantChoiceCue($0) }) else {
            return nil
        }

        let introText = normalizeTextBlock(Array(lines[..<cueIndex]))
        let optionLines = Array(lines[(cueIndex + 1)...])
        let optionBlocks = numberedOptionBlocks(from: optionLines)
        guard optionBlocks.count >= 2 else {
            return nil
        }

        let options = optionBlocks.compactMap(makeChoiceListOption)
        guard options.count >= 2 else {
            return nil
        }

        return InferredPlanQuestionnaire(
            introText: introText,
            questions: [
                CodexStructuredUserInputQuestion(
                    id: "inferred_plan_next_step",
                    header: "Next step",
                    question: "What should Codex produce next?",
                    isOther: false,
                    isSecret: false,
                    options: options
                ),
            ],
            outroText: nil
        )
    }

    private static func hasStructuredAssistantQuestionnaireShape(in text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let lines = trimmed.components(separatedBy: .newlines)
        let numberedQuestionLines = lines.filter { questionNumber(from: $0) != nil }
        let bulletLines = lines.filter { bulletText(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }
        let questionMarkCount = lines.reduce(into: 0) { partialResult, line in
            partialResult += line.filter { $0 == "?" }.count
        }

        if numberedQuestionLines.count >= 2 && questionMarkCount >= 1 {
            return true
        }

        if numberedQuestionLines.count >= 1 && !bulletLines.isEmpty {
            return true
        }

        return false
    }

    private static func isAssistantChoiceCue(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.contains("one of these")
            || lowered.contains("turn this into")
            || lowered.contains("choose one")
            || lowered.contains("pick one")
    }

    private static func numberedOptionBlocks(from lines: [String]) -> [QuestionBlock] {
        var blocks: [QuestionBlock] = []
        var currentBlock: QuestionBlock?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = questionNumber(from: line) {
                if let currentBlock {
                    blocks.append(currentBlock)
                }
                currentBlock = QuestionBlock(number: number, lines: [questionBody(from: line)])
                continue
            }

            guard currentBlock != nil else {
                continue
            }

            currentBlock?.lines.append(line)
        }

        if let currentBlock {
            blocks.append(currentBlock)
        }

        return blocks
    }

    private static func makeChoiceListOption(from block: QuestionBlock) -> CodexStructuredUserInputOption? {
        let normalizedLines = block.lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstLine = normalizedLines.first else {
            return nil
        }

        let description = normalizedLines.dropFirst().joined(separator: "\n")
        return CodexStructuredUserInputOption(
            label: firstLine,
            description: description
        )
    }

    private static func inferredInlineOptions(
        from prompt: String
    ) -> (question: String, options: [CodexStructuredUserInputOption])? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?"),
              let colonIndex = trimmed.firstIndex(of: ":") else {
            return nil
        }

        let question = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "?"
        var optionsText = String(trimmed[trimmed.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !optionsText.isEmpty else {
            return nil
        }
        if optionsText.hasSuffix("?") {
            optionsText.removeLast()
        }

        let normalizedOptionsText = optionsText
            .replacingOccurrences(of: ", or ", with: ", ", options: [.caseInsensitive])
            .replacingOccurrences(of: " or ", with: ", ", options: [.caseInsensitive])
            .replacingOccurrences(of: ", and ", with: ", ", options: [.caseInsensitive])
            .replacingOccurrences(of: " and ", with: ", ", options: [.caseInsensitive])

        let optionLabels = normalizedOptionsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard optionLabels.count >= 2, optionLabels.count <= 6 else {
            return nil
        }

        let options = optionLabels.map { label in
            CodexStructuredUserInputOption(label: label, description: "")
        }
        return (question, options)
    }

    private static func dropTrailingIncompleteQuestions(
        from parsedQuestions: [ParsedQuestionBlock]
    ) -> [ParsedQuestionBlock] {
        var usableQuestions = parsedQuestions
        while let last = usableQuestions.last, !last.isQuestionLike {
            usableQuestions.removeLast()
        }
        return usableQuestions
    }

    private static func normalizeTextBlock(_ lines: [String]) -> String? {
        let normalized = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reduce(into: [String]()) { result, line in
                if line.isEmpty {
                    if result.last != "" {
                        result.append("")
                    }
                } else {
                    result.append(line)
                }
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct QuestionBlock {
    let number: Int
    var lines: [String]
}

private struct ParsedQuestionBlock {
    let question: CodexStructuredUserInputQuestion?
    let outroLines: [String]

    var isQuestionLike: Bool {
        guard let question else {
            return false
        }

        return question.question.contains("?") || !question.options.isEmpty
    }
}

#Preview("Plan Sheet") {
    PlanExecutionSheet(message: PlanAccessoryPreviewFixtures.activeMessage)
        .environment(CodexService())
}
