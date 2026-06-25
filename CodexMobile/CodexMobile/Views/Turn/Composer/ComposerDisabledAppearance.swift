// FILE: ComposerDisabledAppearance.swift
// Purpose: Shared disabled-state colors and opacity for composer controls on Liquid Glass surfaces.
// Layer: View Helper
// Exports: ComposerDisabledAppearance
// Depends on: SwiftUI, AppFont

import SwiftUI

enum ComposerDisabledAppearance {
    static let controlOpacity: Double = 0.45

    static var captionFont: Font { AppFont.caption() }
    static var captionColor: Color { Color.secondary }

    static func sendForeground(isDisabled: Bool, enabled: Color) -> Color {
        isDisabled ? Color.secondary : enabled
    }

    static func sendBackground(isDisabled: Bool, enabled: Color) -> Color {
        isDisabled ? Color(.tertiarySystemFill) : enabled
    }

    static func queueBadgeBackground(isPaused: Bool) -> Color {
        isPaused ? Color(.tertiarySystemFill) : Color(.secondarySystemFill)
    }

    static func queueBadgeForeground(isPaused: Bool) -> Color {
        isPaused ? Color.secondary : Color.primary
    }
}

#if DEBUG
#Preview("Composer disabled send") {
    HStack(spacing: 12) {
        RemodexCircleBadge(
            systemName: "arrow.up",
            foreground: ComposerDisabledAppearance.sendForeground(isDisabled: true, enabled: .primary),
            background: ComposerDisabledAppearance.sendBackground(isDisabled: true, enabled: .white)
        )
        RemodexCircleBadge(
            systemName: "arrow.up",
            foreground: ComposerDisabledAppearance.sendForeground(isDisabled: false, enabled: .primary),
            background: ComposerDisabledAppearance.sendBackground(isDisabled: false, enabled: .white)
        )
    }
    .padding()
    .background(Color.black)
}
#endif
