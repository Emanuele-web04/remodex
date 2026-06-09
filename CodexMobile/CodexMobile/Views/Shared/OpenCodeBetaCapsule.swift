// FILE: OpenCodeBetaCapsule.swift
// Purpose: Shared Beta capsule for OpenCode surfaces (composer pill, sidebar rows).
// Layer: View Component
// Exports: OpenCodeBetaCapsule
// Depends on: SwiftUI, AppFont

import SwiftUI

struct OpenCodeBetaCapsule: View {
    var body: some View {
        Text("Beta")
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .accessibilityLabel("OpenCode beta")
    }
}

#if DEBUG
#Preview("OpenCode beta capsule") {
    OpenCodeBetaCapsule()
        .padding()
}
#endif
