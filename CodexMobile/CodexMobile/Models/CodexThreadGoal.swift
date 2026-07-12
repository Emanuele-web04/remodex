// FILE: CodexThreadGoal.swift
// Purpose: Models the Codex app-server persisted thread goal (`thread/goal/*` API).
// Layer: Model
// Exports: CodexThreadGoal, CodexThreadGoalStatus
// Depends on: JSONValue

import Foundation

// Mirrors the app-server v2 `ThreadGoalStatus` wire values (camelCase).
enum CodexThreadGoalStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete

    // Terminal states cannot continue without user action replacing the goal.
    var isTerminal: Bool {
        self == .budgetLimited || self == .complete
    }

    // Only active goals drive automatic continuation on the app-server.
    var canContinue: Bool {
        self == .active
    }

    // States the user can resume back to `active` from the UI.
    var isResumable: Bool {
        switch self {
        case .paused, .blocked, .usageLimited:
            return true
        case .active, .budgetLimited, .complete:
            return false
        }
    }

    var displayLabel: String {
        switch self {
        case .active:
            return "Active"
        case .paused:
            return "Paused"
        case .blocked:
            return "Blocked"
        case .usageLimited:
            return "Usage Limited"
        case .budgetLimited:
            return "Budget Limited"
        case .complete:
            return "Complete"
        }
    }

    var symbolName: String {
        switch self {
        case .active:
            return "target"
        case .paused:
            return "pause.circle"
        case .blocked:
            return "exclamationmark.octagon"
        case .usageLimited:
            return "hourglass.bottomhalf.filled"
        case .budgetLimited:
            return "gauge.with.needle"
        case .complete:
            return "checkmark.circle"
        }
    }
}

// Mirrors the app-server v2 `ThreadGoal` payload delivered by
// `thread/goal/get|set` responses and `thread/goal/updated` notifications.
struct CodexThreadGoal: Equatable, Sendable {
    let threadId: String
    let objective: String
    let status: CodexThreadGoalStatus
    let tokenBudget: Int?
    let tokensUsed: Int
    let timeUsedSeconds: Int
    let createdAt: Int
    let updatedAt: Int

    init?(object: [String: JSONValue]?) {
        guard let object,
              let threadId = object["threadId"]?.stringValue, !threadId.isEmpty,
              let objective = object["objective"]?.stringValue,
              let rawStatus = object["status"]?.stringValue,
              let status = CodexThreadGoalStatus(rawValue: rawStatus) else {
            return nil
        }

        self.threadId = threadId
        self.objective = objective
        self.status = status
        self.tokenBudget = object["tokenBudget"]?.intValue
        self.tokensUsed = object["tokensUsed"]?.intValue ?? 0
        self.timeUsedSeconds = object["timeUsedSeconds"]?.intValue ?? 0
        self.createdAt = object["createdAt"]?.intValue ?? 0
        self.updatedAt = object["updatedAt"]?.intValue ?? 0
    }

    // Compact usage summary matching the Codex TUI status indicator:
    // budgeted goals show tokens, unbudgeted goals show elapsed goal time.
    var usageSummary: String {
        if let tokenBudget {
            return "\(Self.formatTokenCount(tokensUsed)) / \(Self.formatTokenCount(tokenBudget)) tokens"
        }
        return Self.formatElapsedSeconds(timeUsedSeconds)
    }

    var remainingTokens: Int? {
        guard let tokenBudget else { return nil }
        return max(0, tokenBudget - tokensUsed)
    }

    static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            let value = Double(count) / 1_000
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value))K"
                : String(format: "%.1fK", value)
        }
        return "\(count)"
    }

    static func formatElapsedSeconds(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(clamped)s"
    }
}
