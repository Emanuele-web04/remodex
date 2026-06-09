// FILE: SidebarProviderBadge.swift
// Purpose: Compact runtime provider glyph for sidebar thread rows.
// Layer: View Component
// Exports: SidebarProviderBadge
// Depends on: SwiftUI, RuntimeProviderLogo, TurnComposerMetaMapper, CodexModelOption, CodexService

import SwiftUI

struct SidebarProviderBadge: View {
    let provider: String?

    private var normalizedProvider: String {
        CodexModelOption.normalizedProvider(provider ?? "codex")
    }

    var body: some View {
        RuntimeProviderLogoView(provider: normalizedProvider, size: 13)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Sidebar provider badge") {
    HStack(spacing: 8) {
        SidebarProviderBadge(provider: "codex")
        SidebarProviderBadge(provider: "opencode")
        OpenCodeBetaCapsule()
    }
    .padding()
    .environment(CodexService())
}
#endif
