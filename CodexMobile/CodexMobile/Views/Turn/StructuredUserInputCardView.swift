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
    let onSelectOption: (_ questionID: String, _ optionLabel: String) -> Void
    let onSubmit: (_ answersByQuestionID: [String: [String]]) -> Void

    @State private var selectedOptionsByQuestionID: [String: String] = [:]
    @State private var typedAnswersByQuestionID: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                if index > 0 {
                    Divider().opacity(0.2)
                }
                questionSection(question)
            }

            submitButton
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.8))
                .stroke(Color.secondary.opacity(0.08))
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

            if !question.options.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
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
        let isSelected = selectedOptionsByQuestionID[questionID] == option.label

        return Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            selectedOptionsByQuestionID[questionID] = option.label
            onSelectOption(questionID, option.label)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(isSelected ? Color(.plan) : Color.clear)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle().stroke(isSelected ? Color(.plan) : Color(.separator), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(AppFont.subheadline(weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color(.plan) : .primary)

                    if let desc = option.trimmedDescription {
                        Text(desc)
                            .font(AppFont.caption())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
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
        .disabled(isSubmitting)
    }

    // MARK: - Submit

    private var isSubmitDisabled: Bool {
        isSubmitting || hasSubmittedResponse || !questions.allSatisfy { question in
            resolvedAnswer(for: question) != nil
        }
    }

    private var submitButton: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback()
            let answers = questions.reduce(into: [String: [String]]()) { result, question in
                if let answer = resolvedAnswer(for: question) {
                    result[question.id] = [answer]
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

    private func resolvedAnswer(for question: CodexStructuredUserInputQuestion) -> String? {
        let typed = typedAnswersByQuestionID[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed, !typed.isEmpty { return typed }

        let selected = selectedOptionsByQuestionID[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selected, !selected.isEmpty { return selected }

        return nil
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
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.8))
                .stroke(Color.secondary.opacity(0.08))
        }
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
            onSelectOption: { _, _ in },
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
            onSelectOption: { _, _ in },
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
            onSelectOption: { _, _ in },
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
            onSelectOption: { _, _ in },
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
            ],
            isSubmitting: false,
            hasSubmittedResponse: false,
            onSelectOption: { _, _ in },
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
            onSelectOption: { _, _ in },
            onSubmit: { _ in }
        )
        .padding(.horizontal, 16)
    }
    .background(Color(.systemBackground))
}
