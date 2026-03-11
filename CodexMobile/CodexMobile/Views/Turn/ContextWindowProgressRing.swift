// FILE: ContextWindowProgressRing.swift
// Purpose: Circular progress indicator for context window token usage.
// Layer: View Component
// Exports: ContextWindowProgressRing

import SwiftUI

struct ContextWindowProgressRing: View {
    let usage: ContextWindowUsage
    var threadId: String = ""
    var isCompacting: Bool = false
    var onCompact: (() -> Void)?
    @State private var isShowingPopover = false

    private let ringSize: CGFloat = 22
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            isShowingPopover = true
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: usage.fractionUsed)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text("\(usage.percentUsed)")
                    .font(AppFont.system(size: 7, weight: .semibold))
                    .foregroundStyle(ringColor)
            }
            .frame(width: ringSize, height: ringSize)
        }
        .buttonStyle(.plain)
        .adaptiveToolbarItem(in: Circle())
        .accessibilityLabel("Context window")
        .accessibilityValue("\(usage.percentUsed) percent used")
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

            Text("\(usage.percentUsed)% full")
                .font(AppFont.headline())

            Text("\(usage.tokensUsedFormatted) / \(usage.tokenLimitFormatted) tokens used")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            if onCompact != nil {
                Divider()

                if isCompacting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Compacting…")
                            .font(AppFont.subheadline())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        onCompact?()
                        isShowingPopover = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                                .font(AppFont.system(size: 13))
                            Text("Compact context")
                                .font(AppFont.subheadline())
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
        .padding()
    }

    private var ringColor: Color {
        switch usage.fractionUsed {
        case 0.85...: return .red
        case 0.65..<0.85: return .orange
        default: return .primary
        }
    }
}
