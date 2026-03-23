// FILE: TerminalRunningIndicator.swift
// Purpose: Compact ">_" terminal glyph with blinking cursor, shown while an assistant block is running.
// Layer: View Component
// Exports: TerminalRunningIndicator

import SwiftUI

struct TerminalRunningIndicator: View {
    @State private var cursorOpacity: Double = 1

    var body: some View {
        HStack(spacing: 6) {
            glyph
            Text("Remodex is thinking...")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .overlay { ShimmerLabelMask() }
                .mask(
                    Text("Remodex is thinking...")
                        .font(AppFont.caption())
                )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                cursorOpacity = 0.18
            }
        }
        .accessibilityLabel("Remodex is thinking")
    }

    private var glyph: some View {
        HStack(alignment: .bottom, spacing: 1) {
            Text(">")
                .font(AppFont.mono(.caption2))
       
               
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.secondary)
                .frame(width: 4, height: 1)
                .padding(.bottom, 2)
                .opacity(cursorOpacity)
                .offset(x: 0, y: -1)
        }
        .foregroundStyle(.secondary)
        .frame(width: 12, height: 12)
               .padding(5)
               .background(
                   Circle()
                       .fill(Color.primary.opacity(0.02))
                       .overlay(
                           Circle()
                               .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                       )
               )
               .contentShape(Circle())
    }
}

// Same gradient-sweep as ShimmerMask in TurnMessageComponents but tuned for a short label.
private struct ShimmerLabelMask: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.35), location: 0.4),
                    .init(color: .white.opacity(0.35), location: 0.6),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: w * 0.5)
            .offset(x: phase * w)
            .onAppear {
                withAnimation(.easeInOut(duration: 4.0).repeatForever(autoreverses: false)) {
                    phase = 5
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview("Terminal Running Indicator") {
    VStack(alignment: .leading, spacing: 32) {
        // Standalone
        TerminalRunningIndicator()

        // In context — simulated assistant block
        VStack(alignment: .leading, spacing: 12) {
            Text("Here is the beginning of an assistant response that is still streaming content...")
                .font(AppFont.body())
                .foregroundStyle(.primary)

            TerminalRunningIndicator()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 16)
    }
    .padding(.vertical, 40)
}
