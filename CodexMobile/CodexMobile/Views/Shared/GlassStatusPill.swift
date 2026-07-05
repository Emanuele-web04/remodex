// FILE: GlassStatusPill.swift
// Purpose: Shared compact Liquid Glass "pill" shell for composer-adjacent status capsules.
// Layer: View Component
// Exports: GlassStatusPill
// Depends on: SwiftUI, AdaptiveGlassModifier

import SwiftUI

/// Unified compact capsule shell used by composer-adjacent status pills
/// (file changes, active plan). Owns the Liquid Glass background, hairline
/// stroke, padding, and horizontal stack so every pill stays visually in sync.
/// Callers inject the leading marker, label, and trailing metric as content.
struct GlassStatusPill<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .adaptiveGlass(.regular, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        }
        .contentShape(Capsule())
    }
}
