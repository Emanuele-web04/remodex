// FILE: RunningThreadSpinner.swift
// Purpose: Shared rounded spinner for a thread that is currently running.
// Layer: View Component
// Exports: RunningThreadSpinner
// Depends on: SwiftUI

import SwiftUI

/// Compact running-state indicator shared by sidebar rows and composer controls.
struct RunningThreadSpinner: View {
    var size: CGFloat = 15
    var color: Color = .gray
    var lineWidth: CGFloat = 3

    @State private var isSpinning = false

    private var strokeWidth: CGFloat {
        lineWidth * 2 / 3
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: strokeWidth)

            Circle()
                .trim(from: 0.16, to: 0.72)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                )
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(
                    .linear(duration: 0.85).repeatForever(autoreverses: false),
                    value: isSpinning
                )
        }
        .frame(width: size, height: size)
        .onAppear {
            isSpinning = true
        }
        .accessibilityHidden(true)
    }
}
