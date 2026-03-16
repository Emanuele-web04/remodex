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

    private var steps: [CodexPlanStep] {
        message.planState?.steps ?? []
    }

    private var completedStepCount: Int {
        steps.filter { $0.status == .completed }.count
    }

    private var totalStepCount: Int {
        steps.count
    }

    // Surfaces the next actionable row so the collapsed accessory stays informative.
    private var highlightedStep: CodexPlanStep? {
        steps.first(where: { $0.status == .inProgress })
            ?? steps.first(where: { $0.status == .pending })
            ?? steps.last
    }

    private var summaryText: String {
        if let highlightedStep {
            return highlightedStep.step
        }

        let explanation = message.planState?.explanation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explanation.isEmpty {
            return explanation
        }

        let body = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "Open plan details" : body
    }

    private var progressText: String {
        guard totalStepCount > 0 else { return nilTextFallback }
        return "\(completedStepCount)/\(totalStepCount)"
    }

    private var statusLabel: String {
        if steps.contains(where: { $0.status == .inProgress }) {
            return "In progress"
        }
        if totalStepCount > 0, completedStepCount == totalStepCount {
            return "Completed"
        }
        return "Pending"
    }

    private var statusColor: Color {
        if steps.contains(where: { $0.status == .inProgress }) {
            return .orange
        }
        if totalStepCount > 0, completedStepCount == totalStepCount {
            return .green
        }
        return Color(.plan)
    }

    private let nilTextFallback = "Plan"

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onTap()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checklist")
                    .font(AppFont.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.plan))
                    .frame(width: 32, height: 32)
                    .background(Color(.plan).opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Plan")
                            .font(AppFont.caption(weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(statusLabel)
                            .font(AppFont.caption2(weight: .medium))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(statusColor.opacity(0.12), in: Capsule())

                        if message.isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }

                    Text(summaryText)
                        .font(AppFont.subheadline(weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                Text(progressText)
                    .font(AppFont.headline(weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .buttonStyle(.plain)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityLabel("Open active plan")
        .accessibilityHint("Shows the current plan steps in a sheet")
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

// MARK: - Previews

private enum PlanModePreviewData {
    static let threadID = "thread_preview_plan"

    static let activePlanMessage = CodexMessage(
        threadId: threadID,
        role: .system,
        kind: .plan,
        text: "Preparing the rollout in small, safe steps so the response stays visible while work is happening.",
        isStreaming: true,
        planState: CodexPlanState(
            explanation: "The assistant is organizing the work before execution.",
            steps: [
                CodexPlanStep(step: "Inspect the current conversation layout and top overlay behavior", status: .completed),
                CodexPlanStep(step: "Move the active plan out of the timeline overlay and into a compact accessory", status: .inProgress),
                CodexPlanStep(step: "Open the full task list in a sheet when the compact row is tapped", status: .pending),
            ]
        )
    )

    static let completedPlanMessage = CodexMessage(
        threadId: threadID,
        role: .system,
        kind: .plan,
        text: "All plan tasks are done.",
        planState: CodexPlanState(
            explanation: "This is how the compact row looks once every step is complete.",
            steps: [
                CodexPlanStep(step: "Review the old overlay behavior", status: .completed),
                CodexPlanStep(step: "Replace it with a compact accessory above the composer", status: .completed),
                CodexPlanStep(step: "Present the full plan inside a sheet", status: .completed),
            ]
        )
    )
}

private struct PlanExecutionPreviewScene: View {
    @State private var isShowingSheet = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        previewUserBubble(
                            "Can you fix the plan card? Right now it covers the assistant response."
                        )

                        previewAssistantBubble(
                            """
                            I moved the plan summary out of the overlay area so the response stays readable.
                            The active plan now lives above the composer and opens in a sheet.
                            """
                        )

                        // Leaves room so the accessory + composer stack can sit above the scroll content.
                        Color.clear
                            .frame(height: 180)
                    }
                    .padding(16)
                }

                VStack(spacing: 10) {
                    PlanExecutionAccessory(message: PlanModePreviewData.activePlanMessage) {
                        isShowingSheet = true
                    }
                    .padding(.horizontal, 12)

                    previewComposer
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
                .background(
                    LinearGradient(
                        colors: [
                            Color(.systemGroupedBackground).opacity(0),
                            Color(.systemGroupedBackground).opacity(0.92),
                            Color(.systemGroupedBackground),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Plan Preview")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $isShowingSheet) {
            PlanExecutionSheet(message: PlanModePreviewData.activePlanMessage)
        }
    }

    private func previewUserBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)

            Text(text)
                .font(AppFont.body())
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func previewAssistantBubble(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(AppFont.body())
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Spacer(minLength: 48)
        }
    }

    private var previewComposer: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(AppFont.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color(.secondarySystemBackground), in: Circle())

            Text("Ask Codex to continue...")
                .font(AppFont.body())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.circle.fill")
                .font(AppFont.system(size: 24, weight: .semibold))
                .foregroundStyle(Color(.plan))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

#Preview("Plan Accessory In Chat") {
    PlanExecutionPreviewScene()
}

#Preview("Plan Sheet") {
    PlanExecutionSheet(message: PlanModePreviewData.activePlanMessage)
}

#Preview("Plan Accessory Completed") {
    VStack {
        PlanExecutionAccessory(message: PlanModePreviewData.completedPlanMessage) { }
            .padding(16)
        Spacer()
    }
    .background(Color(.systemGroupedBackground))
}
