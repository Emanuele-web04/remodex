// FILE: StructuredUserInputCardView.swift
// Purpose: Self-contained plan-mode question card, independent of CodexService for easy preview.
// Layer: View Component
// Exports: StructuredUserInputCardView
// Depends on: SwiftUI, CodexCollaboration

import SwiftUI

struct StructuredUserInputCardView: View {
    let questions: [CodexStructuredUserInputQuestion]
    let isSubmitting: Bool
    let hasSubmittedResponse: Bool
    let isInteractionLocked: Bool
    let onSelectOption: (_ questionID: String, _ optionLabel: String) -> Void
    let secondaryActionTitle: String?
    let onSecondaryAction: (() -> Void)?
    let onSubmit: (_ answersByQuestionID: [String: [String]]) -> Void

    @State private var selectedOptionsByQuestionID: [String: [String]] = [:]
    @State private var typedAnswersByQuestionID: [String: String] = [:]
    @State private var currentQuestionIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow

            if let currentQuestion {
                questionSection(currentQuestion)
                    .id(currentQuestion.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            actionRow
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentQuestionIndex)
        // If the server refreshes the prompt in place, treat it like a fresh form.
        .onChange(of: questionSignature) { _, _ in
            resetStoredAnswers()
            currentQuestionIndex = 0
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Questions")
                .font(AppFont.mono(.caption))
                .foregroundStyle(.secondary)

            if questions.count > 1 {
                Circle()
                    .fill(Color(.separator).opacity(0.6))
                    .frame(width: 3, height: 3)

                progressHeader
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Question section

    @ViewBuilder
    private func questionSection(_ question: CodexStructuredUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header = question.trimmedHeader {
                Text(header.uppercased())
                    .font(AppFont.caption2(weight: .medium))
                    .foregroundStyle(.secondary)
                    .kerning(0.4)
            }

            Text(question.trimmedPrompt)
                .font(AppFont.body())
                .foregroundStyle(.primary)

            if let selectionLimit = question.selectionLimitDescription {
                Text(selectionLimit)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if !question.options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(question.options) { option in
                        optionRow(option, questionID: question.id)
                    }
                }
            }

            if question.needsFreeformField {
                answerField(question)
            }
        }
    }

    // MARK: - Option row

    private func optionRow(_ option: CodexStructuredUserInputOption, questionID: String) -> some View {
        let isSelected = selectedOptionsByQuestionID[questionID]?.contains(option.label) == true

        return Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                toggleOptionSelection(option.label, for: questionID, question: question(for: questionID))
            }
            onSelectOption(questionID, option.label)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(AppFont.subheadline(weight: .medium))
                        .foregroundStyle(isSelected ? Color(.plan) : .primary)

                    if let desc = option.trimmedDescription {
                        Text(desc)
                            .font(AppFont.caption())
                            .foregroundStyle(isSelected ? Color(.plan).opacity(0.6) : .secondary)
                    }
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(AppFont.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(.plan))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color(.plan).opacity(0.08) : Color(.systemBackground).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? Color(.plan).opacity(0.3) : Color(.separator).opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isInteractionBusy)
    }

    // MARK: - Answer field

    @ViewBuilder
    private func answerField(_ question: CodexStructuredUserInputQuestion) -> some View {
        let binding = Binding(
            get: { typedAnswersByQuestionID[question.id] ?? "" },
            set: { typedAnswersByQuestionID[question.id] = $0 }
        )

        Group {
            if question.isSecret {
                SecureField(question.answerFieldPlaceholder, text: binding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField(question.answerFieldPlaceholder, text: binding, axis: .vertical)
                    .textInputAutocapitalization(.sentences)
            }
        }
        .font(AppFont.body())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(isInteractionBusy)
    }

    // MARK: - Flow controls

    private var currentQuestion: CodexStructuredUserInputQuestion? {
        guard questions.indices.contains(currentQuestionIndex) else {
            return nil
        }

        return questions[currentQuestionIndex]
    }

    private func question(for questionID: String) -> CodexStructuredUserInputQuestion? {
        questions.first(where: { $0.id == questionID })
    }

    private var questionSignature: [QuestionSignature] {
        questions.map(QuestionSignature.init)
    }

    private var progressHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(currentQuestionIndex + 1) of \(questions.count)")
                .font(AppFont.mono(.caption2))
                .foregroundStyle(.secondary)

            stepRail
        }
    }

    private var stepRail: some View {
        HStack(spacing: 3) {
            ForEach(0..<questions.count, id: \.self) { index in
                Capsule()
                    .fill(stepRailTint(at: index))
                    .frame(width: 10, height: 3)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentQuestionIndex)
    }

    private func stepRailTint(at index: Int) -> Color {
        if index < currentQuestionIndex {
            // Answered — solid
            return Color.primary.opacity(0.72)
        } else if index == currentQuestionIndex {
            // Active
            return Color(.plan).opacity(0.72)
        } else {
            // Upcoming
            return Color(.separator).opacity(0.22)
        }
    }

    private var canMoveForward: Bool {
        guard let currentQuestion else { return false }
        return resolvedAnswers(for: currentQuestion) != nil
    }

    private var isInteractionBusy: Bool {
        isSubmitting || isInteractionLocked
    }

    private var isSubmitDisabled: Bool {
        isInteractionBusy || hasSubmittedResponse || !questions.allSatisfy { question in
            resolvedAnswers(for: question) != nil
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if currentQuestionIndex > 0 {
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        currentQuestionIndex = max(currentQuestionIndex - 1, 0)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(AppFont.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(AppFont.subheadline(weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .foregroundColor(isInteractionBusy ? Color(.tertiaryLabel) : Color(.secondaryLabel))
                .background(Color(.quaternarySystemFill), in: Capsule())
                .disabled(isInteractionBusy)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if let secondaryActionTitle {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        onSecondaryAction?()
                    } label: {
                        Text(secondaryActionTitle)
                            .font(AppFont.subheadline(weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(
                        (isInteractionBusy || hasSubmittedResponse || onSecondaryAction == nil)
                            ? Color(.tertiaryLabel)
                            : Color(.secondaryLabel)
                    )
                    .background(Color(.quaternarySystemFill), in: Capsule())
                    .disabled(isInteractionBusy || hasSubmittedResponse || onSecondaryAction == nil)
                }

                if currentQuestionIndex < max(questions.count - 1, 0) {
                    nextButton
                } else {
                    submitButton
                }
            }
        }
    }

    private var nextButton: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                currentQuestionIndex = min(currentQuestionIndex + 1, max(questions.count - 1, 0))
            }
        } label: {
            HStack(spacing: 4) {
                Text("Next")
                    .font(AppFont.subheadline(weight: .medium))
                Image(systemName: "chevron.right")
                    .font(AppFont.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .foregroundColor(canMoveForward ? Color.white : Color(.tertiaryLabel))
        .background(
            canMoveForward
                ? AnyShapeStyle(Color(.plan))
                : AnyShapeStyle(Color(.quaternarySystemFill)),
            in: Capsule()
        )
        .disabled(!canMoveForward || isInteractionBusy)
    }

    private var submitButton: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback()
            let answers = questions.reduce(into: [String: [String]]()) { result, question in
                if let answer = resolvedAnswers(for: question) {
                    result[question.id] = answer
                }
            }
            onSubmit(answers)
        } label: {
            HStack(spacing: 6) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.white)
                }
                Text(isSubmitting ? "Sending..." : "Send")
                    .font(AppFont.subheadline(weight: .medium))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .foregroundColor(isSubmitDisabled ? Color(.tertiaryLabel) : Color.white)
        .background(
            isSubmitDisabled
                ? AnyShapeStyle(Color(.quaternarySystemFill))
                : AnyShapeStyle(Color(.plan)),
            in: Capsule()
        )
        .disabled(isSubmitDisabled)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func resolvedAnswers(for question: CodexStructuredUserInputQuestion) -> [String]? {
        let typed = typedAnswersByQuestionID[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed, !typed.isEmpty { return [typed] }

        let selected = (selectedOptionsByQuestionID[question.id] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !selected.isEmpty { return selected }

        return nil
    }

    private func toggleOptionSelection(
        _ optionLabel: String,
        for questionID: String,
        question: CodexStructuredUserInputQuestion?
    ) {
        let limit = max(question?.selectionLimit ?? 1, 1)
        var selected = selectedOptionsByQuestionID[questionID] ?? []

        if let existingIndex = selected.firstIndex(of: optionLabel) {
            selected.remove(at: existingIndex)
        } else if limit == 1 {
            selected = [optionLabel]
        } else if selected.count < limit {
            selected.append(optionLabel)
        }

        selectedOptionsByQuestionID[questionID] = selected
    }

    private func resetStoredAnswers() {
        selectedOptionsByQuestionID = [:]
        typedAnswersByQuestionID = [:]
    }
}

private struct QuestionSignature: Hashable {
    struct OptionSignature: Hashable {
        let label: String
        let description: String
    }

    let id: String
    let header: String
    let question: String
    let isOther: Bool
    let isSecret: Bool
    let selectionLimit: Int?
    let options: [OptionSignature]

    init(_ question: CodexStructuredUserInputQuestion) {
        self.id = question.id
        self.header = question.header
        self.question = question.question
        self.isOther = question.isOther
        self.isSecret = question.isSecret
        self.selectionLimit = question.selectionLimit
        self.options = question.options.map {
            OptionSignature(label: $0.label, description: $0.description)
        }
    }
}

// MARK: - Card container (shared with PlanSystemCard)

struct PlanModeCardContainer<Content: View>: View {
    let title: String
    let showsProgress: Bool
    let content: Content

    init(
        title: String,
        showsProgress: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.showsProgress = showsProgress
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.secondary)

                if showsProgress {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Question model helpers (package-visible)

extension CodexStructuredUserInputQuestion {
    var trimmedHeader: String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var trimmedPrompt: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var needsFreeformField: Bool {
        options.isEmpty || isOther || isSecret
    }

    var answerFieldPlaceholder: String {
        isOther ? "Other answer" : "Your answer"
    }

    var selectionLimitDescription: String? {
        guard let selectionLimit, selectionLimit > 1 else {
            return nil
        }
        return "Select up to \(selectionLimit)"
    }
}

extension CodexStructuredUserInputOption {
    var trimmedDescription: String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Previews

#Preview("Multiple choice") {
    ScrollView {
        StructuredUserInputCardView(
            questions: [
                CodexStructuredUserInputQuestion(
                    id: "q1",
                    header: "Architecture",
                    question: "How should the new networking layer be structured?",
                    isOther: false,
                    isSecret: false,
                    options: [
                        CodexStructuredUserInputOption(label: "Async/Await", description: "Modern Swift concurrency with structured tasks"),
                        CodexStructuredUserInputOption(label: "Combine", description: "Reactive streams using Apple's Combine framework"),
                        CodexStructuredUserInputOption(label: "Callbacks", description: "Traditional completion handler pattern"),
                    ]
                )
            ],
            isSubmitting: false,
            hasSubmittedResponse: false,
            isInteractionLocked: false,
            onSelectOption: { _, _ in },
            secondaryActionTitle: nil,
            onSecondaryAction: nil,
            onSubmit: { _ in }
        )
        .padding(.horizontal, 16)
    }
    .background(Color(.systemBackground))
}

#Preview("Freeform text") {
    ScrollView {
        StructuredUserInputCardView(
            questions: [
                CodexStructuredUserInputQuestion(
                    id: "q1",
                    header: "Naming",
                    question: "What should the new module be called?",
                    isOther: false,
                    isSecret: false,
                    options: []
                )
            ],
            isSubmitting: false,
            hasSubmittedResponse: false,
            isInteractionLocked: false,
            onSelectOption: { _, _ in },
            secondaryActionTitle: nil,
            onSecondaryAction: nil,
            onSubmit: { _ in }
        )
        .padding(.horizontal, 16)
    }
    .background(Color(.systemBackground))
}

#Preview("Secret input") {
    ScrollView {
        StructuredUserInputCardView(
            questions: [
                CodexStructuredUserInputQuestion(
                    id: "q1",
                    header: "Credentials",
                    question: "Enter the API key for the staging environment:",
                    isOther: false,
                    isSecret: true,
                    options: []
                )
            ],
            isSubmitting: false,
            hasSubmittedResponse: false,
            isInteractionLocked: false,
            onSelectOption: { _, _ in },
            secondaryActionTitle: nil,
            onSecondaryAction: nil,
            onSubmit: { _ in }
        )
        .padding(.horizontal, 16)
    }
    .background(Color(.systemBackground))
}

#Preview("Options + Other") {
    ScrollView {
        StructuredUserInputCardView(
            questions: [
                CodexStructuredUserInputQuestion(
                    id: "q1",
                    header: "Deployment",
                    question: "Where should this service be deployed?",
                    isOther: true,
                    isSecret: false,
                    options: [
                        CodexStructuredUserInputOption(label: "AWS", description: "Amazon Web Services EC2/ECS"),
                        CodexStructuredUserInputOption(label: "GCP", description: "Google Cloud Run"),
                        CodexStructuredUserInputOption(label: "Self-hosted", description: "On-premise VPS"),
                    ]
                )
            ],
            isSubmitting: false,
            hasSubmittedResponse: false,
            isInteractionLocked: false,
            onSelectOption: { _, _ in },
            secondaryActionTitle: nil,
            onSecondaryAction: nil,
            onSubmit: { _ in }
        )
        .padding(.horizontal, 16)
    }
    .background(Color(.systemBackground))
}

#Preview("Multi-question form") {
    ScrollView {
        StructuredUserInputCardView(
            questions: [
                CodexStructuredUserInputQuestion(
                    id: "q1",
                    header: "Scope",
                    question: "Should the refactor include the legacy API endpoints?",
                    isOther: false,
                    isSecret: false,
                    options: [
                        CodexStructuredUserInputOption(label: "Yes", description: "Migrate everything at once"),
                        CodexStructuredUserInputOption(label: "No", description: "Only new endpoints for now"),
                    ]
                ),
                CodexStructuredUserInputQuestion(
                    id: "q2",
                    header: "Testing",
                    question: "What's the minimum test coverage target?",
                    isOther: false,
                    isSecret: false,
                    options: []
                ),
                CodexStructuredUserInputQuestion(
                    id: "q3",
                    header: "Timeline",
                    question: "When should the migration be completed?",
                    isOther: true,
                    isSecret: false,
                    options: [
                        CodexStructuredUserInputOption(label: "This sprint", description: "2-week delivery window"),
                        CodexStructuredUserInputOption(label: "Next quarter", description: "Phased rollout with buffer"),
                    ]
                ),
            ],
            isSubmitting: false,
            hasSubmittedResponse: false,
            isInteractionLocked: false,
            onSelectOption: { _, _ in },
            secondaryActionTitle: nil,
            onSecondaryAction: nil,
            onSubmit: { _ in }
        )
        .padding(.horizontal, 16)
    }
    .background(Color(.systemBackground))
}

#Preview("Submitting state") {
    ScrollView {
        StructuredUserInputCardView(
            questions: [
                CodexStructuredUserInputQuestion(
                    id: "q1",
                    header: "",
                    question: "Should I proceed with the migration?",
                    isOther: false,
                    isSecret: false,
                    options: [
                        CodexStructuredUserInputOption(label: "Yes", description: ""),
                        CodexStructuredUserInputOption(label: "No", description: ""),
                    ]
                )
            ],
            isSubmitting: true,
            hasSubmittedResponse: false,
            isInteractionLocked: false,
            onSelectOption: { _, _ in },
            secondaryActionTitle: nil,
            onSecondaryAction: nil,
            onSubmit: { _ in }
        )
        .padding(.horizontal, 16)
    }
    .background(Color(.systemBackground))
}
