// FILE: TurnSessionDiffSummary.swift
// Purpose: Computes per-chat diff totals and recognizes hidden push reset markers.
// Layer: View Support
// Exports: TurnSessionDiffTotals, TurnSessionDiffSummaryCalculator, TurnSessionDiffResetMarker
// Depends on: CodexMessage, TurnFileChangeSummaryParser

import Foundation

struct TurnSessionDiffTotals: Equatable {
    let additions: Int
    let deletions: Int
    let distinctDiffCount: Int

    var hasChanges: Bool {
        additions > 0 || deletions > 0
    }
}

enum TurnSessionDiffScope {
    case unpushedSession
    case wholeThread
}

enum TurnSessionDiffResetMarker {
    static let manualPushItemID = "git.push.reset.marker"

    // Creates the hidden payload persisted after a successful manual push.
    static func text(branch: String, remote: String?) -> String {
        let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRemote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedRemote, !normalizedRemote.isEmpty, !normalizedBranch.isEmpty {
            return "Push completed on \(normalizedRemote)/\(normalizedBranch)."
        }
        if !normalizedBranch.isEmpty {
            return "Push completed on \(normalizedBranch)."
        }
        return "Push completed on remote."
    }

    // Keeps reset detection stable across persisted hidden markers and legacy visible messages.
    static func isResetMessage(_ message: CodexMessage) -> Bool {
        guard message.role == .system else { return false }
        if message.itemId == manualPushItemID {
            return true
        }

        let normalizedText = message.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedText.hasPrefix("push completed on ")
            || normalizedText.hasPrefix("commit & push completed.")
    }
}

enum TurnSessionDiffSummaryCalculator {
    // Sums distinct file-change messages for either the whole conversation
    // or only the unpushed tail after the latest successful push.
    static func totals(
        from messages: [CodexMessage],
        scope: TurnSessionDiffScope = .unpushedSession
    ) -> TurnSessionDiffTotals? {
        let relevantMessages = relevantMessages(in: messages, scope: scope)
        var seenKeys: Set<String> = []
        var additions = 0
        var deletions = 0
        var distinctDiffCount = 0

        for message in relevantMessages {
            guard message.role == .system, message.kind == .fileChange else { continue }
            guard let summary = TurnFileChangeSummaryParser.parse(from: message.text) else { continue }

            // Collapse streaming/final duplicates only within the same turn so repeated
            // edits across separate turns still count toward the unpushed badge.
            let dedupeKey = TurnFileChangeSummaryParser.dedupeKey(from: message.text)
                .map { summaryKey in
                    let turnScope = message.turnId?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return "\(turnScope ?? "message-id:\(message.id)")|\(summaryKey)"
                }
                ?? "message-id:\(message.id)"
            guard seenKeys.insert(dedupeKey).inserted else { continue }

            additions += summary.entries.reduce(0) { $0 + $1.additions }
            deletions += summary.entries.reduce(0) { $0 + $1.deletions }
            distinctDiffCount += 1
        }

        let totals = TurnSessionDiffTotals(
            additions: additions,
            deletions: deletions,
            distinctDiffCount: distinctDiffCount
        )
        return totals.hasChanges ? totals : nil
    }

    private static func relevantMessages(
        in messages: [CodexMessage],
        scope: TurnSessionDiffScope
    ) -> ArraySlice<CodexMessage> {
        switch scope {
        case .unpushedSession:
            return messagesAfterMostRecentPush(in: messages)
        case .wholeThread:
            return messages[...]
        }
    }

    // Treats push success messages as a reset marker so per-chat badges reflect only
    // the current unpushed portion of the conversation.
    private static func messagesAfterMostRecentPush(in messages: [CodexMessage]) -> ArraySlice<CodexMessage> {
        guard let lastPushIndex = messages.lastIndex(where: TurnSessionDiffResetMarker.isResetMessage) else {
            return messages[...]
        }
        let nextIndex = messages.index(after: lastPushIndex)
        return messages[nextIndex...]
    }
}
