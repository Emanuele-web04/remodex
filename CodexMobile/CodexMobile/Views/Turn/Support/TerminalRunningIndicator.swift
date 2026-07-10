// FILE: TerminalRunningIndicator.swift
// Purpose: Pending assistant status label with a lightweight shimmer while a block is running.
// Layer: View Component
// Exports: TerminalRunningIndicator, TerminalRunningIndicatorLayout

import SwiftUI

enum TerminalRunningIndicatorLayout {
    // Fixed row height so the indicator never reflows while assistant deltas
    // stream into the rows above it.
    static func reservedRowHeight(isAccessibilitySize: Bool) -> CGFloat {
        isAccessibilitySize ? 56 : 24
    }
}

struct TerminalRunningIndicator: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ShimmerText(
            text: "Remodex is thinking",
            font: AppFont.body(),
            foregroundStyle: .secondary
        )
        .frame(
            minHeight: TerminalRunningIndicatorLayout.reservedRowHeight(
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            ),
            alignment: .leading
        )
        .accessibilityLabel("Remodex is thinking")
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
