// FILE: TerminalRunningIndicator.swift
// Purpose: Pending assistant status label with a lightweight shimmer while a block is running.
// Layer: View Component
// Exports: TerminalRunningIndicator, TerminalRunningIndicatorLayout, StreamingAssistantPlaceholderSlot

import SwiftUI

enum TerminalRunningIndicatorLayout {
    // Shared with timeline bottom padding and the hidden streaming-assistant slot so
    // the first assistant delta does not jump past the thinking placeholder height.
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

// Reserves scroll space for a hidden empty streaming assistant row.
struct StreamingAssistantPlaceholderSlot: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Color.clear
            .frame(
                height: TerminalRunningIndicatorLayout.reservedRowHeight(
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                )
            )
            .accessibilityHidden(true)
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
