// FILE: CodexRateLimitStatus.swift
// Purpose: Models ChatGPT rate-limit buckets shown in the in-app status sheet.
// Layer: Model
// Exports: CodexRateLimitBucket, CodexRateLimitWindow, CodexRateLimitDisplayRow

import Foundation

struct CodexRateLimitWindow: Equatable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Date?

    var clampedUsedPercent: Int {
        min(max(usedPercent, 0), 100)
    }

    var remainingPercent: Int {
        max(0, 100 - clampedUsedPercent)
    }
}

struct CodexRateLimitDisplayRow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let window: CodexRateLimitWindow
}

struct CodexRateLimitBucket: Identifiable, Equatable, Sendable {
    let limitId: String
    let limitName: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?

    var id: String { limitId }

    var primaryOrSecondary: CodexRateLimitWindow? {
        primary ?? secondary
    }

    // Splits combined primary/secondary windows into the rows the status sheet should actually render.
    var displayRows: [CodexRateLimitDisplayRow] {
        var rows: [CodexRateLimitDisplayRow] = []

        if let primary {
            rows.append(
                CodexRateLimitDisplayRow(
                    id: "\(limitId)-primary",
                    label: Self.label(for: primary, fallback: limitName ?? limitId),
                    window: primary
                )
            )
        }

        if let secondary {
            rows.append(
                CodexRateLimitDisplayRow(
                    id: "\(limitId)-secondary",
                    label: Self.label(for: secondary, fallback: limitName ?? limitId),
                    window: secondary
                )
            )
        }

        return rows
    }

    var sortDurationMins: Int {
        primaryOrSecondary?.windowDurationMins ?? Int.max
    }

    var displayLabel: String {
        if let durationLabel = Self.durationLabel(minutes: primaryOrSecondary?.windowDurationMins) {
            return durationLabel
        }

        let trimmedName = limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        return limitId
    }

    // Normalizes mixed payload shapes into one visible row per logical window label.
    static func visibleDisplayRows(from buckets: [CodexRateLimitBucket]) -> [CodexRateLimitDisplayRow] {
        let rows = buckets.flatMap(\.displayRows)
        var dedupedByLabel: [String: CodexRateLimitDisplayRow] = [:]

        for row in rows {
            if let existing = dedupedByLabel[row.label] {
                dedupedByLabel[row.label] = preferredDisplayRow(existing, row)
            } else {
                dedupedByLabel[row.label] = row
            }
        }

        return dedupedByLabel.values.sorted { lhs, rhs in
            let lhsDuration = lhs.window.windowDurationMins ?? Int.max
            let rhsDuration = rhs.window.windowDurationMins ?? Int.max
            if lhsDuration == rhsDuration {
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            return lhsDuration < rhsDuration
        }
    }

    private static func label(for window: CodexRateLimitWindow, fallback: String) -> String {
        durationLabel(minutes: window.windowDurationMins) ?? fallback
    }

    private static func preferredDisplayRow(
        _ current: CodexRateLimitDisplayRow,
        _ candidate: CodexRateLimitDisplayRow
    ) -> CodexRateLimitDisplayRow {
        if candidate.window.clampedUsedPercent != current.window.clampedUsedPercent {
            return candidate.window.clampedUsedPercent > current.window.clampedUsedPercent ? candidate : current
        }

        switch (current.window.resetsAt, candidate.window.resetsAt) {
        case (.none, .some):
            return candidate
        case (.some, .none):
            return current
        case let (.some(currentReset), .some(candidateReset)):
            return candidateReset < currentReset ? candidate : current
        case (.none, .none):
            return current
        }
    }

    private static func durationLabel(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }

        let weekMinutes = 7 * 24 * 60
        let dayMinutes = 24 * 60

        if minutes % weekMinutes == 0 {
            return minutes == weekMinutes ? "Weekly" : "\(minutes / weekMinutes)w"
        }

        if minutes % dayMinutes == 0 {
            return "\(minutes / dayMinutes)d"
        }

        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }

        return "\(minutes)m"
    }
}
