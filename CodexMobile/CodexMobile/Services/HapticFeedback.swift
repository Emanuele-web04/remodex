// FILE: HapticFeedback.swift
// Purpose: Centralized haptic feedback utility for premium button interactions.
// Layer: Service
// Exports: HapticFeedback
// Depends on: UIKit

import UIKit

class HapticFeedback {
    static let shared = HapticFeedback()

    private init() {}

    func triggerImpactFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}
