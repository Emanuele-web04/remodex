// FILE: SidebarActivitySection.swift
// Purpose: Groups the global task list into priority work and calendar sections.
// Layer: Sidebar presentation

import Foundation

enum SidebarActivitySectionKind: String, CaseIterable, Identifiable {
    case priority, today, yesterday, previousWeek, earlier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .priority: return "Priority"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previousWeek: return "Previous 7 days"
        case .earlier: return "Earlier"
        }
    }
}

struct SidebarActivitySection: Identifiable {
    let kind: SidebarActivitySectionKind
    let threads: [CodexThread]
    var id: SidebarActivitySectionKind { kind }

    static func makeSections(
        from sortedThreads: [CodexThread],
        runBadges: [String: CodexThreadRunBadgeState],
        now: Date,
        calendar: Calendar = .current
    ) -> [SidebarActivitySection] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? yesterday
        let grouped = Dictionary(grouping: sortedThreads) { thread -> SidebarActivitySectionKind in
            if runBadges[thread.id] != nil { return .priority }
            guard let date = thread.updatedAt ?? thread.createdAt else { return .earlier }
            if date >= today { return .today }
            if date >= yesterday { return .yesterday }
            if date >= weekAgo { return .previousWeek }
            return .earlier
        }
        return SidebarActivitySectionKind.allCases.compactMap { kind in
            guard let threads = grouped[kind], !threads.isEmpty else { return nil }
            return SidebarActivitySection(kind: kind, threads: threads)
        }
    }
}
