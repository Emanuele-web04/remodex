// FILE: StreamingUIInteractionMonitor.swift
// Purpose: Tracks live user interaction (timeline scroll drags, composer typing) so
//   heavy streaming rows can back off while the main thread is gesture-bound.
// Layer: Service Support
// Exports: StreamingUIInteractionMonitor
// Depends on: Foundation

import Foundation

/// Heavy streaming rows can re-layout the timeline while the user scrolls or types.
/// Views report interaction here so `CodexService` can slow those rows down without
/// making assistant prose feel delayed.
@MainActor
enum StreamingUIInteractionMonitor {
    /// Typing is only known via discrete text-change events, so treat the composer
    /// as active for a short window after the last keystroke.
    static let composerTypingActivityWindow: TimeInterval = 0.75

    private(set) static var isScrollInteractionActive = false
    private static var lastComposerKeystrokeAt: Date?

    static func setScrollInteractionActive(_ active: Bool) {
        isScrollInteractionActive = active
    }

    static func noteComposerKeystroke(now: Date = Date()) {
        lastComposerKeystrokeAt = now
    }

    static func isInteractionActive(now: Date = Date()) -> Bool {
        if isScrollInteractionActive {
            return true
        }
        guard let lastComposerKeystrokeAt else {
            return false
        }
        return now.timeIntervalSince(lastComposerKeystrokeAt) < composerTypingActivityWindow
    }
}
