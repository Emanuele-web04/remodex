// FILE: ShimmerText.swift
// Purpose: AI-style thinking shimmer — a repeating light wave sweeps across label text.
// Layer: View Component
// Exports: ShimmerText
// Depends on: SwiftUI, AppFont

import SwiftUI

/// Repeating highlight band masked to glyphs. Base text stays muted; only the wave brightens.
struct ShimmerText: View, Equatable {
    let text: String
    let font: Font
    var foregroundStyle: Color = .secondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let bandWidth: CGFloat = 60
    private static let animationDuration: TimeInterval = 1.65

    var body: some View {
        label
            .overlay {
                if !reduceMotion {
                    shimmerWave
                        .mask(label)
                        .allowsHitTesting(false)
                }
            }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foregroundStyle)
    }

    private var shimmerWave: some View {
        GeometryReader { proxy in
            let travelDistance = proxy.size.width + Self.bandWidth

            LinearGradient(
                colors: waveColors,
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Self.bandWidth)
            .offset(x: -Self.bandWidth)
            .blendMode(.plusLighter)
            .keyframeAnimator(initialValue: CGFloat.zero, repeating: true) { content, offset in
                content.offset(x: offset)
            } keyframes: { _ in
                LinearKeyframe(travelDistance, duration: Self.animationDuration)
            }
        }
    }

    // Narrow clear → bright → clear band reads as a moving wave over secondary text.
    private var waveColors: [Color] {
        let highlight = Color.white
        let edge = colorScheme == .dark ? 0.18 : 0.12
        let peak = colorScheme == .dark ? 0.95 : 0.82
        return [
            .clear,
            highlight.opacity(edge),
            highlight.opacity(peak),
            highlight.opacity(edge),
            .clear,
        ]
    }

    static func == (lhs: ShimmerText, rhs: ShimmerText) -> Bool {
        lhs.text == rhs.text && lhs.foregroundStyle == rhs.foregroundStyle
    }
}

#Preview("Shimmer Text") {
    VStack(alignment: .leading, spacing: 24) {
        ShimmerText(
            text: "Remodex is thinking",
            font: AppFont.body(),
            foregroundStyle: .secondary
        )

        ShimmerText(
            text: "Loading workspace context",
            font: AppFont.caption(),
            foregroundStyle: Color(uiColor: .tertiaryLabel)
        )
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.systemBackground))
}
