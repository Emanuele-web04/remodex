// FILE: GoalStatusChip.swift
// Purpose: Compact composer-carousel goal capsule with an inline expandable detail card.
// Layer: View Component
// Exports: GoalStatusChip
// Depends on: SwiftUI, CodexThreadGoal, GlassStatusPill, RemodexIcon

import SwiftUI

struct GoalStatusChip: View {
    let goal: CodexThreadGoal
    let isThreadRunning: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void
    var onResume: () -> Void = {}
    var onPause: () -> Void = {}
    var onExpansionChange: (Bool) -> Void = { _ in }

    @State private var isExpanded = false
    @State private var isShowingRemoveConfirmation = false
    @State private var observedAt = Date()

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if isExpanded {
                detailCard
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                let nextExpansionState = !isExpanded
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    isExpanded = nextExpansionState
                }
                onExpansionChange(nextExpansionState)
            } label: {
                GlassStatusPill {
                    RemodexIcon.image(
                        systemName: "remodex.goal",
                        size: 14,
                        weight: .medium,
                        relativeTo: .caption
                    )
                    .foregroundStyle(.secondary)

                    Text("Goal \(goal.status.displayLabel.lowercased())")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    elapsedLabel
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Goal \(goal.status.displayLabel), \(elapsedText(now: Date()))")
            .accessibilityHint(isExpanded ? "Collapses goal details" : "Expands goal details")
        }
        .onChange(of: goal) { _, _ in
            observedAt = Date()
        }
        .confirmationDialog(
            "Remove this goal?",
            isPresented: $isShowingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Goal", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Codex stops pursuing the objective and forgets its progress accounting.")
        }
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(goal.objective)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Spacer(minLength: 0)

                if goal.status.isResumable {
                    detailAction(systemName: "play.circle", label: "Resume goal", action: onResume)
                } else if goal.status == .active {
                    detailAction(systemName: "pause.circle", label: "Pause goal", action: onPause)
                }

                detailAction(systemName: "pencil", label: "Edit goal", action: onEdit)
                detailAction(systemName: "trash.circle", label: "Remove goal") {
                    isShowingRemoveConfirmation = true
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 330)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        }
    }

    private func detailAction(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            action()
        } label: {
            RemodexIcon.image(systemName: systemName, size: 18, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var elapsedLabel: some View {
        Group {
            if goal.status == .active && isThreadRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedText(now: context.date))
                }
            } else {
                Text(elapsedText(now: observedAt))
            }
        }
        .font(AppFont.caption().monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func elapsedText(now: Date) -> String {
        let liveSeconds = goal.status == .active && isThreadRunning
            ? max(0, Int(now.timeIntervalSince(observedAt)))
            : 0
        return Self.formatElapsedSeconds(goal.timeUsedSeconds + liveSeconds)
    }

    static func formatElapsedSeconds(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let remainingSeconds = clamped % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(remainingSeconds)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }
}

#if DEBUG
#Preview("Goal Status Chip") {
    let goal = CodexThreadGoal(object: [
        "threadId": .string("thread-1"),
        "objective": .string("Reduce p95 checkout latency below 120 ms while keeping the correctness suite green"),
        "status": .string("blocked"),
        "tokensUsed": .integer(12_500),
        "timeUsedSeconds": .integer(11_839),
        "createdAt": .integer(1),
        "updatedAt": .integer(1),
    ])!

    return GoalStatusChip(
        goal: goal,
        isThreadRunning: false,
        onEdit: {},
        onRemove: {}
    )
    .padding()
}
#endif
