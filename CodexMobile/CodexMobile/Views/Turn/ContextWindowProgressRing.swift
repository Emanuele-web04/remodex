// FILE: ContextWindowProgressRing.swift
// Purpose: Compact progress indicator for context window token usage in composer/meta rows.
// Layer: View Component
// Exports: ContextWindowProgressRing
// Depends on: SwiftUI, HapticFeedback, UsageStatusSummaryContent

import SwiftUI

struct ContextWindowProgressRing: View {
    let usage: ContextWindowUsage?
    let rateLimitBuckets: [CodexRateLimitBucket]
    let isLoadingRateLimits: Bool
    let rateLimitsErrorMessage: String?
    let shouldAutoRefreshStatus: Bool
    let onRefreshStatus: (() async -> Void)?
    @State private var isShowingPopover = false
    @State private var isRefreshing = false

    private let ringSize: CGFloat = 18
    private let lineWidth: CGFloat = 2.25
    private let tapTargetSize: CGFloat = 36

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            isShowingPopover = true
        } label: {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: lineWidth)

                if let usage {
                    Circle()
                        .trim(from: 0, to: usage.fractionUsed)
                        .stroke(ringColor(for: usage), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    Text("\(usage.percentUsed)")
                        .font(AppFont.system(size: 6, weight: .semibold))
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(ringColor(for: usage))
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color(.systemGray2))
                }
            }
            .frame(width: ringSize, height: ringSize)
            .frame(width: tapTargetSize, height: tapTargetSize)
            .adaptiveGlass(.regular, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context window")
        .accessibilityValue(usageAccessibilityValue)
        .popover(isPresented: $isShowingPopover) {
            popoverContent
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: isShowingPopover) { _, isPresented in
            guard isPresented, shouldAutoRefreshStatus else { return }
            refreshStatus(triggerHaptic: false)
        }
    }

    private var popoverContent: some View {
        UsageStatusSummaryContent(
            contextWindowUsage: usage,
            rateLimitBuckets: rateLimitBuckets,
            isLoadingRateLimits: isLoadingRateLimits,
            rateLimitsErrorMessage: rateLimitsErrorMessage,
            contextPlacement: .bottom,
            refreshControl: onRefreshStatus.map { _ in
                UsageStatusRefreshControl(
                    title: "Refresh",
                    isRefreshing: isRefreshing,
                    action: { refreshStatus() }
                )
            }
        )
        .padding()
        .frame(minWidth: 260)
    }

    private var usageAccessibilityValue: String {
        if let usage {
            return "\(usage.percentUsed) percent used"
        }
        return "Usage unavailable"
    }

    private func ringColor(for usage: ContextWindowUsage) -> Color {
        switch usage.fractionUsed {
        case 0.85...: return .primary
        case 0.65..<0.85: return .secondary
        default: return Color(.systemGray2)
        }
    }

    // Refreshes both thread context usage and account windows for the compact status popover.
    private func refreshStatus(triggerHaptic: Bool = true) {
        guard !isRefreshing, let onRefreshStatus else { return }
        if triggerHaptic {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
        }
        isRefreshing = true

        Task {
            await onRefreshStatus()
            await MainActor.run {
                isRefreshing = false
            }
        }
    }
}
