// FILE: PlanAccessoryCard.swift
// Purpose: Hosts the compact active-plan accessory as a standalone, previewable view.
// Layer: View Component
// Exports: PlanAccessoryCard, PlanAccessorySnapshot, PlanAccessoryPreviewFixtures
// Depends on: SwiftUI, CodexMessage, CodexCollaboration

import SwiftUI

enum PlanAccessoryStatus: Equatable {
    case pending
    case inProgress
    case completed

    var label: String {
        switch self {
        case .pending:
            return "Pending"
        case .inProgress:
            return "In progress"
        case .completed:
            return "Completed"
        }
    }

    var symbolName: String {
        switch self {
        case .pending:
            return "list.bullet.clipboard"
        case .inProgress:
            return "clock.fill"
        case .completed:
            return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            return Color(.plan)
        case .inProgress:
            return .orange
        case .completed:
            return .green
        }
    }
}

struct PlanAccessorySnapshot: Equatable {
    let title: String
    let summary: String
    let status: PlanAccessoryStatus
    let completedStepCount: Int
    let totalStepCount: Int
    let isStreaming: Bool
    let stepStatuses: [CodexPlanStepStatus]

    init(
        title: String = "Plan",
        summary: String,
        status: PlanAccessoryStatus,
        completedStepCount: Int,
        totalStepCount: Int,
        isStreaming: Bool = false,
        stepStatuses: [CodexPlanStepStatus] = []
    ) {
        self.title = title
        self.summary = summary
        self.status = status
        self.completedStepCount = completedStepCount
        self.totalStepCount = totalStepCount
        self.isStreaming = isStreaming
        self.stepStatuses = stepStatuses
    }

    init(message: CodexMessage) {
        let steps = message.planState?.steps ?? []
        let completedStepCount = steps.filter { $0.status == .completed }.count
        let totalStepCount = steps.count
        let status = Self.resolveStatus(from: steps, completedStepCount: completedStepCount)

        self.init(
            summary: Self.resolveSummary(from: message, steps: steps),
            status: status,
            completedStepCount: completedStepCount,
            totalStepCount: totalStepCount,
            isStreaming: message.isStreaming,
            stepStatuses: steps.map(\.status)
        )
    }

    var progressText: String? {
        guard totalStepCount > 0 else { return nil }
        return "\(completedStepCount)/\(totalStepCount)"
    }

    var progressDescription: String {
        guard totalStepCount > 0 else { return status.label }
        return "\(completedStepCount) of \(totalStepCount) complete"
    }

    private static func resolveStatus(
        from steps: [CodexPlanStep],
        completedStepCount: Int
    ) -> PlanAccessoryStatus {
        if steps.contains(where: { $0.status == .inProgress }) {
            return .inProgress
        }
        if !steps.isEmpty, completedStepCount == steps.count {
            return .completed
        }
        return .pending
    }

    private static func resolveSummary(from message: CodexMessage, steps: [CodexPlanStep]) -> String {
        if let highlightedStep = steps.first(where: { $0.status == .inProgress })
            ?? steps.first(where: { $0.status == .pending })
            ?? steps.last {
            return highlightedStep.step
        }

        let explanation = normalizedPlanText(message.planState?.explanation)
        if let explanation {
            return explanation
        }

        let body = normalizedPlanText(message.text)
        return body ?? "Open plan details"
    }

    // Filters placeholder copy so the compact UI only surfaces useful context.
    private static func normalizedPlanText(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Planning..." else {
            return nil
        }
        return trimmed
    }
}

/// Shared glass-backed card used by above-composer accessories (plan, subagent, etc.).
struct GlassAccessoryCard<LeadingMarker: View, Header: View, Summary: View, Trailing: View>: View {
    let onTap: () -> Void
    @ViewBuilder let leadingMarker: () -> LeadingMarker
    @ViewBuilder let header: () -> Header
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onTap()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                leadingMarker()

                VStack(alignment: .leading, spacing: 5) {
                    header()
                    summary()
                }

                Spacer(minLength: 0)

                trailing()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.clear)
                    .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            )
        }
        .buttonStyle(.plain)
    }
}

struct PlanAccessoryCard: View {
    let snapshot: PlanAccessorySnapshot
    let onTap: () -> Void

    var body: some View {
        GlassAccessoryCard(onTap: onTap) {
            leadingMarker
        } header: {
            headerRow
        } summary: {
            summaryRow
        } trailing: {
            trailingMetric
        }
        .accessibilityLabel("Open active plan")
        .accessibilityValue("\(snapshot.status.label), \(snapshot.progressDescription)")
        .accessibilityHint("Shows the current plan steps in a sheet")
    }

    private var leadingMarker: some View {
        ZStack {
            Circle()
                .fill(snapshot.status.tint.opacity(0.1))
                .frame(width: 22, height: 22)

            Circle()
                .fill(snapshot.status.tint)
                .frame(width: 7, height: 7)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(snapshot.title)
                .font(AppFont.mono(.caption2))
                .foregroundStyle(.secondary)

            Circle()
                .fill(Color(.separator).opacity(0.6))
                .frame(width: 3, height: 3)

            Text(snapshot.status.label)
                .font(AppFont.caption(weight: .regular))
                .foregroundStyle(snapshot.status.tint)

            if !snapshot.stepStatuses.isEmpty {
                stepRail
                    .padding(.leading, 2)
            }

            if snapshot.isStreaming {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.8)
                    .padding(.leading, 2)
            }
        }
    }

    private var summaryRow: some View {
        Text(snapshot.summary)
            .font(AppFont.subheadline(weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .multilineTextAlignment(.leading)
    }

    private var trailingMetric: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let progressText = snapshot.progressText {
                Text(progressText)
                    .font(AppFont.mono(.caption))
                    .foregroundStyle(.primary)
            } else {
                Text(snapshot.status.label)
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(snapshot.status.tint)
            }
        }
        .frame(minWidth: 36, alignment: .trailing)
    }

    private var stepRail: some View {
        HStack(spacing: 3) {
            ForEach(Array(snapshot.stepStatuses.enumerated()), id: \.offset) { _, status in
                Capsule()
                    .fill(stepTint(for: status))
                    .frame(width: 10, height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private func stepTint(for status: CodexPlanStepStatus) -> Color {
        switch status {
        case .pending:
            return Color(.separator).opacity(0.22)
        case .inProgress:
            return snapshot.status.tint.opacity(0.72)
        case .completed:
            return Color.primary.opacity(0.72)
        }
    }
}

enum PlanAccessoryPreviewFixtures {
    static let threadID = "thread_preview_plan_accessory"

    static let activeMessage = CodexMessage(
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

    static let pendingMessage = CodexMessage(
        threadId: threadID,
        role: .system,
        kind: .plan,
        text: "Planning...",
        planState: CodexPlanState(
            explanation: "The task has been broken down and is waiting to begin.",
            steps: [
                CodexPlanStep(step: "Confirm the runtime contract for plan updates", status: .pending),
                CodexPlanStep(step: "Split the accessory into a reusable component", status: .pending),
                CodexPlanStep(step: "Add focused previews for visual iteration", status: .pending),
            ]
        )
    )

    static let completedMessage = CodexMessage(
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

private struct PlanAccessoryPreviewGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                previewSection(
                    title: "Live plan",
                    snapshot: PlanAccessorySnapshot(message: PlanAccessoryPreviewFixtures.activeMessage)
                )

                previewSection(
                    title: "Queued plan",
                    snapshot: PlanAccessorySnapshot(message: PlanAccessoryPreviewFixtures.pendingMessage)
                )

                previewSection(
                    title: "Completed plan",
                    snapshot: PlanAccessorySnapshot(message: PlanAccessoryPreviewFixtures.completedMessage)
                )
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func previewSection(title: String, snapshot: PlanAccessorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppFont.caption(weight: .medium))
                .foregroundStyle(.secondary)

            PlanAccessoryCard(snapshot: snapshot) { }
        }
    }
}

private struct PlanAccessoryCardOnlyPreview: View {
    let snapshot: PlanAccessorySnapshot

    var body: some View {
        VStack {
            PlanAccessoryCard(snapshot: snapshot) { }
                .padding(16)
            Spacer(minLength: 0)
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct PlanAccessoryInContextPreview: View {
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        previewUserBubble("Could you improve the compact plan row so it feels clearer while a task is running?")
                        previewAssistantBubble(
                            """
                            I split the plan row into a dedicated component so the UI can be previewed in isolation.
                            The card below now mirrors the live state without needing the full timeline to render.
                            """
                        )
                        Color.clear
                            .frame(height: 180)
                    }
                    .padding(16)
                }

                VStack(spacing: 10) {
                    PlanAccessoryCard(snapshot: PlanAccessorySnapshot(message: PlanAccessoryPreviewFixtures.activeMessage)) { }
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
            .navigationTitle("Plan Accessory")
            .navigationBarTitleDisplayMode(.inline)
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

#Preview("Plan Accessory Gallery") {
    PlanAccessoryPreviewGallery()
}

#Preview("Plan Card Only - Active") {
    PlanAccessoryCardOnlyPreview(
        snapshot: PlanAccessorySnapshot(message: PlanAccessoryPreviewFixtures.activeMessage)
    )
}

#Preview("Plan Card Only - Pending") {
    PlanAccessoryCardOnlyPreview(
        snapshot: PlanAccessorySnapshot(message: PlanAccessoryPreviewFixtures.pendingMessage)
    )
}

#Preview("Plan Card Only - Completed") {
    PlanAccessoryCardOnlyPreview(
        snapshot: PlanAccessorySnapshot(message: PlanAccessoryPreviewFixtures.completedMessage)
    )
}

#Preview("Plan Accessory In Context") {
    PlanAccessoryInContextPreview()
}
