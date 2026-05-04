// FILE: TurnPlanModeComponents.swift
// Purpose: Renders inline plan cards, composer plan affordances, and structured question cards.
// Layer: View Component
// Exports: PlanSystemCard, PlanExecutionAccessory, PlanExecutionSheet, StructuredUserInputCard
// Depends on: SwiftUI, CodexService, CodexMessage, StructuredUserInputCardView

import SwiftUI

struct PlanSystemCard: View {
    let message: CodexMessage

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

    var body: some View {
        PlanModeCardContainer(title: "Plan", showsProgress: message.isStreaming) {
            if !bodyText.isEmpty {
                MarkdownTextView(text: bodyText, profile: .assistantProse)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let explanationText {
                MarkdownTextView(text: explanationText, profile: .assistantProse)
            }

            if let explanationText, !bodyText.isEmpty {
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

#Preview("Plan Sheet") {
    PlanExecutionSheet(message: PlanAccessoryPreviewFixtures.activeMessage)
}
