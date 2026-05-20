// FILE: TerminalRunningIndicator.swift
// Purpose: Compact ">_" terminal glyph with blinking cursor, shown while an assistant block is running.
// Layer: View Component
// Exports: TerminalRunningIndicator

import SwiftUI

struct TerminalRunningIndicator: View {
    var body: some View {
        Text("Remodex is thinking...")
            .font(AppFont.body())
            .foregroundStyle(.secondary)
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
