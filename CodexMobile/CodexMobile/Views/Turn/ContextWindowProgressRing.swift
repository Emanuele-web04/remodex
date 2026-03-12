// FILE: ContextWindowProgressRing.swift
// Purpose: Compact progress indicator for context window token usage in composer/meta rows.
// Layer: View Component
// Exports: ContextWindowProgressRing
// Depends on: SwiftUI, HapticFeedback

import SwiftUI

struct ContextWindowProgressRing: View {
    let usage: ContextWindowUsage?
    let onRefresh: (() async -> Void)?
    @State private var isShowingPopover = false
    @State private var isRefreshing = false

    private let ringSize: CGFloat = 18
    private let lineWidth: CGFloat = 2.25
    private let tapTargetSize: CGFloat = 20

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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context window")
        .accessibilityValue(usageAccessibilityValue)
        .popover(isPresented: $isShowingPopover) {
            popoverContent
                .presentationCompactAdaptation(.popover)
        }
    }

    private var popoverContent: some View {
        VStack(spacing: 8) {
            Text("Context window:")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)

            if let usage {
                Text("\(usage.percentUsed)% full")
                    .font(AppFont.headline())

                Text("\(usage.tokensUsedFormatted) / \(usage.tokenLimitFormatted) tokens used")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            } else {
                Text("Unavailable")
                    .font(AppFont.headline())

                Text("Waiting for token usage from the runtime")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if let onRefresh {
                Divider()

                Button {
                    guard !isRefreshing else { return }
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    isRefreshing = true

                    Task {
                        await onRefresh()
                        await MainActor.run {
                            isRefreshing = false
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(AppFont.system(size: 12, weight: .semibold))
                        }

                        Text(isRefreshing ? "Refreshing..." : "Refresh")
                            .font(AppFont.subheadline(weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }
        }
        .padding()
        .frame(minWidth: 180)
    }

    private var usageAccessibilityValue: String {
        if let usage {
            return "\(usage.percentUsed) percent used"
        }
        return "Usage unavailable"
    }

    private func ringColor(for usage: ContextWindowUsage) -> Color {
        switch usage.fractionUsed {
        case 0.85...: return .red
        case 0.65..<0.85: return .orange
        default: return Color(.systemGray2)
        }
    }
}
