// FILE: GoalStatusChip.swift
// Purpose: Compact goal capsule above the composer: icon, one-line objective, ongoing time,
//          stop/remove controls, and a chevron that expands the full objective text.
// Layer: View Component
// Exports: GoalStatusChip
// Depends on: SwiftUI, CodexThreadGoal, AdaptiveGlassModifier, AppFont, HapticFeedback

import SwiftUI

struct GoalStatusChip: View {
    let goal: CodexThreadGoal
    let isThreadRunning: Bool
    // Opens the goal management sheet (edit, budget, full lifecycle).
    let onTap: () -> Void
    // Pauses an active goal ("stop" without losing state).
    let onStop: () -> Void
    // Resumes a paused/blocked/limited goal.
    let onResume: () -> Void
    // Clears the goal entirely (confirmed inline).
    let onRemove: () -> Void

    @State private var isExpanded = false
    @State private var isShowingRemoveConfirmation = false
    // Baseline for the live ticking clock while the goal keeps running.
    @State private var observedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            if isExpanded {
                Text(goal.objective)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        }
        .onChange(of: goal) { _, _ in
            observedAt = Date()
        }
        .confirmationDialog(
            "Remove this goal?",
            isPresented: $isShowingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Goal", role: .destructive) {
                onRemove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Codex stops pursuing the objective and forgets its progress accounting.")
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onTap()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: goal.status.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 16, height: 16)

                    Text(goal.objective)
                        .font(AppFont.subheadline(weight: .medium))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    ongoingTimeLabel
                        .layoutPriority(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Goal \(goal.status.displayLabel). \(goal.objective)")
            .accessibilityHint("Opens goal details")

            Spacer(minLength: 4)

            controlButtons
        }
    }

    // Live elapsed time: accrues visually only while the goal is active and the
    // thread is actually running, mirroring the Codex TUI status indicator.
    private var ongoingTimeLabel: some View {
        Group {
            if goal.status == .active && isThreadRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(liveElapsedText(now: context.date))
                }
            } else {
                Text(CodexThreadGoal.formatElapsedSeconds(goal.timeUsedSeconds))
            }
        }
        .font(AppFont.subheadline(weight: .semibold).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var controlButtons: some View {
        HStack(spacing: 4) {
            if goal.status == .active {
                controlButton(systemName: "stop.fill", accessibilityLabel: "Pause goal") {
                    onStop()
                }
            } else if goal.status.isResumable {
                controlButton(systemName: "play.fill", accessibilityLabel: "Resume goal") {
                    onResume()
                }
            }

            controlButton(systemName: "xmark", accessibilityLabel: "Remove goal") {
                isShowingRemoveConfirmation = true
            }

            controlButton(
                systemName: "chevron.down",
                accessibilityLabel: isExpanded ? "Collapse goal text" : "Expand goal text"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            }
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
    }

    private func controlButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func liveElapsedText(now: Date) -> String {
        let liveSeconds = max(0, Int(now.timeIntervalSince(observedAt)))
        return CodexThreadGoal.formatElapsedSeconds(goal.timeUsedSeconds + liveSeconds)
    }

    private var statusColor: Color {
        switch goal.status {
        case .active:
            return .purple
        case .paused:
            return .secondary
        case .blocked, .usageLimited, .budgetLimited:
            return .orange
        case .complete:
            return .green
        }
    }
}

#if DEBUG
#Preview("Goal Status Chip") {
    let goal = CodexThreadGoal(object: [
        "threadId": .string("thread-1"),
        "objective": .string("Reduce p95 checkout latency below 120 ms while keeping the correctness suite green"),
        "status": .string("active"),
        "tokenBudget": .integer(200_000),
        "tokensUsed": .integer(12_500),
        "timeUsedSeconds": .integer(3_720),
        "createdAt": .integer(1),
        "updatedAt": .integer(1),
    ])!

    return VStack(spacing: 14) {
        GoalStatusChip(
            goal: goal,
            isThreadRunning: true,
            onTap: {},
            onStop: {},
            onResume: {},
            onRemove: {}
        )
    }
    .padding()
}
#endif
