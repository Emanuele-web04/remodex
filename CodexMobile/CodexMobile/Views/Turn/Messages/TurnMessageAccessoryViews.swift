// FILE: TurnMessageAccessoryViews.swift
// Purpose: Shared lightweight controls and labels used by turn message rows.
// Layer: View Component
// Exports: DiffCountsLabel, TypingIndicator, ApprovalBanner, AssistantTurnEndActionVisibility
// Depends on: SwiftUI

import SwiftUI

/// Compact `+N -M` label in green/red. Caller applies `.font()`.
struct DiffCountsLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)")
                .foregroundStyle(Color.green)
            Text("-\(deletions)")
                .foregroundStyle(Color.red)
        }
    }
}

struct TypingIndicator: View {
    private let trackWidth: CGFloat = 26
    private let trackHeight: CGFloat = 6
    private let highlightWidth: CGFloat = 16
    private let duration: TimeInterval = 1.0
    @State private var shimmerOffset: CGFloat = -21

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: trackWidth, height: trackHeight)
            .overlay {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.secondary.opacity(0.04),
                                Color.secondary.opacity(0.42),
                                Color.secondary.opacity(0.04),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: highlightWidth, height: trackHeight)
                    .offset(x: shimmerOffset)
            }
            .clipShape(Capsule(style: .continuous))
            .onAppear {
                guard shimmerOffset < 0 else { return }
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    shimmerOffset = 21
                }
            }
            .accessibilityHidden(true)
    }
}

struct ApprovalBanner: View {
    let request: CodexApprovalRequest
    let isLoading: Bool
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval request", systemImage: "checkmark.shield")
                .font(AppFont.subheadline())

            if let command = request.command, !command.isEmpty {
                Text(command)
                    .font(AppFont.mono(.callout))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(AppFont.callout())
            } else {
                Text(request.method)
                    .font(AppFont.callout())
            }

            HStack {
                Button("Approve", action: {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onApprove()
                })
                .buttonStyle(.borderedProminent)

                Button("Deny", role: .destructive, action: {
                    HapticFeedback.shared.triggerImpactFeedback()
                    onDecline()
                })
                .buttonStyle(.bordered)
            }
            .disabled(isLoading)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

enum AssistantTurnEndActionVisibility {
    // Ties Diff/Revert to the block's own streaming state so interrupted and
    // turn-less recovered rows keep their end-of-turn controls once settled.
    static func shouldShow(accessoryState: AssistantBlockAccessoryState?) -> Bool {
        guard let accessoryState, !accessoryState.showsRunningIndicator else { return false }
        return accessoryState.blockRevertPresentation != nil
            || accessoryState.blockDiffEntries != nil
    }
}
