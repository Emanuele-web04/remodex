// FILE: SidebarRelativeTimeFormatter.swift
// Purpose: Provides compact relative timing labels for sidebar rows.
// Layer: View Helper
// Exports: SidebarRelativeTimeFormatter

import Foundation

enum SidebarRelativeTimeFormatter {
    static func compactLabel(for thread: CodexThread, now: Date = Date()) -> String? {
        guard let referenceDate = thread.updatedAt ?? thread.createdAt else {
            return nil
        }
        return compactRelativeTime(from: referenceDate, to: now)
    }

    static func compactRelativeTime(from date: Date, to now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(date))

        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        let day: TimeInterval = 24 * hour
        let week: TimeInterval = 7 * day
        let month: TimeInterval = 30 * day
        let year: TimeInterval = 365 * day

        if interval >= year {
            return "\(Int(interval / year))y"
        }
        if interval >= month {
            return "\(Int(interval / month))mo"
        }
        if interval >= week {
            return "\(Int(interval / week))w"
        }
        if interval >= day {
            return "\(Int(interval / day))d"
        }
        if interval >= hour {
            return "\(Int(interval / hour))h"
        }
        if interval >= minute {
            return "\(Int(interval / minute))m"
        }
        return "now"
    }
}
