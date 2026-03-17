// FILE: TurnTimelineReducer.swift
// Purpose: Projects raw service timelines into render-ready message lists.
// Layer: View Helper
// Exports: TurnTimelineReducer, TurnTimelineProjection
// Depends on: CodexMessage

import Foundation

struct TurnTimelineProjection {
    let messages: [CodexMessage]
}

enum TurnTimelineReducer {
    // ─── ENTRY POINT ─────────────────────────────────────────────

    // Applies all render-only timeline transforms in one pass.
    static func project(messages: [CodexMessage]) -> TurnTimelineProjection {
        let visibleMessages = removeHiddenSystemMarkers(in: messages)
        let reordered = enforceIntraTurnOrder(in: visibleMessages)
        let collapsedThinking = collapseConsecutiveThinkingMessages(in: reordered)
        let dedupedFileChanges = removeDuplicateFileChangeMessages(in: collapsedThinking)
        let dedupedSubagentActions = removeDuplicateSubagentActionMessages(in: dedupedFileChanges)
        let dedupedAssistant = removeDuplicateAssistantMessages(in: dedupedSubagentActions)
        return TurnTimelineProjection(messages: dedupedAssistant)
    }

    // Resolves where the viewport should anchor when assistant output starts streaming.
    static func assistantResponseAnchorMessageID(
        in messages: [CodexMessage],
        activeTurnID: String?
    ) -> String? {
        if let activeTurnID,
           let message = messages.last(where: { $0.role == .assistant && $0.turnId == activeTurnID }) {
            return message.id
        }

        return messages.last(where: { $0.role == .assistant && $0.isStreaming })?.id
    }

    // Ensures correct visual order within each turn: user → thinking → assistant → file changes.
    // Works on non-consecutive messages: collects ALL indices per turnId across the entire
    // array, sorts each turn's messages by role priority, and places them back into their
    // original slot positions. Messages without a turnId are never moved.
    //
    // Multi-item turns (thinking → response → thinking → response) are detected by checking
    // whether a thinking row arrives after an assistant row in chronological order. When
    // detected, only user messages are floated to the top; the interleaved flow is preserved.
    static func enforceIntraTurnOrder(in messages: [CodexMessage]) -> [CodexMessage] {
        // Collect indices belonging to each turnId (may be scattered across the array).
        var indicesByTurn: [String: [Int]] = [:]
        for (index, message) in messages.enumerated() {
            guard let turnId = message.turnId, !turnId.isEmpty else { continue }
            indicesByTurn[turnId, default: []].append(index)
        }

        var result = messages

        for (_, indices) in indicesByTurn {
            guard indices.count > 1 else { continue }

            let turnMessages = indices.map { result[$0] }

            let sorted: [CodexMessage]
            if hasInterleavedAssistantThinkingFlow(turnMessages) {
                // Multi-item turn: only ensure user messages precede all others.
                // Preserve the interleaved thinking → response → thinking → response order.
                sorted = turnMessages.sorted { a, b in
                    let aIsUser = a.role == .user
                    let bIsUser = b.role == .user
                    if aIsUser != bIsUser { return aIsUser }
                    return a.orderIndex < b.orderIndex
                }
            } else {
                // Single-item turn: apply normal role-based ordering.
                sorted = turnMessages.sorted { a, b in
                    let pA = intraTurnPriority(a)
                    let pB = intraTurnPriority(b)
                    if pA != pB { return pA < pB }
                    return a.orderIndex < b.orderIndex
                }
            }

            // Place sorted messages back into the same slot positions.
            for (i, originalIndex) in indices.enumerated() {
                result[originalIndex] = sorted[i]
            }
        }

        return result
    }

    // Detects multi-item turns where thinking/reasoning appears on BOTH sides of an
    // assistant message (thinking → response → thinking). This distinguishes true
    // interleaved flows from single-item turns where events arrived out of order.
    private static func hasInterleavedAssistantThinkingFlow(_ turnMessages: [CodexMessage]) -> Bool {
        // Multiple distinct assistant item IDs = definitive multi-item turn.
        let distinctAssistantItemIds = Set(
            turnMessages
                .filter { $0.role == .assistant }
                .compactMap { normalizedIdentifier($0.itemId) }
        )
        if distinctAssistantItemIds.count > 1 {
            return true
        }

        // Check pattern: thinking → assistant → thinking (reasoning on both sides).
        let ordered = turnMessages.sorted { $0.orderIndex < $1.orderIndex }
        var hasThinkingBeforeAssistant = false
        var seenAssistant = false
        for message in ordered {
            if message.role == .assistant {
                seenAssistant = true
            } else if message.role == .system, message.kind == .thinking {
                if !seenAssistant {
                    hasThinkingBeforeAssistant = true
                } else if hasThinkingBeforeAssistant {
                    return true
                }
            }
        }
        return false
    }

    private static func intraTurnPriority(_ message: CodexMessage) -> Int {
        switch message.role {
        case .user:
            return 0
        case .system:
            switch message.kind {
            case .thinking:
                return 1
            case .commandExecution:
                return 2
            case .subagentAction:
                return 3
            case .chat:
                return 4
            case .plan:
                return 4
            case .userInputPrompt:
                return 6
            case .fileChange:
                // Keep edited-file cards at the end of the turn timeline.
                return 5
            }
        case .assistant:
            return 4
        }
    }

    // Hides persisted technical markers that exist only to reset per-chat diff totals.
    private static func removeHiddenSystemMarkers(in messages: [CodexMessage]) -> [CodexMessage] {
        messages.filter { message in
            !(message.role == .system && message.itemId == TurnSessionDiffResetMarker.manualPushItemID)
        }
    }

    // Collapses noisy back-to-back thinking rows into one visual row (render-only).
    static func collapseConsecutiveThinkingMessages(in messages: [CodexMessage]) -> [CodexMessage] {
        var result: [CodexMessage] = []
        result.reserveCapacity(messages.count)

        for message in messages {
            guard message.role == .system, message.kind == .thinking else {
                result.append(message)
                continue
            }

            guard var previous = result.last,
                  previous.role == .system,
                  previous.kind == .thinking else {
                result.append(message)
                continue
            }

            guard shouldMergeThinkingRows(previous: previous, incoming: message) else {
                result.append(message)
                continue
            }

            let incoming = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !incoming.isEmpty {
                previous.text = mergeThinkingText(existing: previous.text, incoming: incoming)
            }

            // The newest thinking row should own the final streaming/completed state.
            previous.isStreaming = message.isStreaming
            previous.turnId = message.turnId ?? previous.turnId
            previous.itemId = message.itemId ?? previous.itemId
            result[result.count - 1] = previous
        }

        return result
    }

    // Preserves separate reasoning blocks when they come from different item ids.
    private static func shouldMergeThinkingRows(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        let previousItemId = normalizedIdentifier(previous.itemId)
        let incomingItemId = normalizedIdentifier(incoming.itemId)
        if let previousItemId, let incomingItemId {
            return previousItemId == incomingItemId
        }
        if previousItemId != nil || incomingItemId != nil {
            return false
        }

        let previousTurnId = normalizedIdentifier(previous.turnId)
        let incomingTurnId = normalizedIdentifier(incoming.turnId)
        guard previousTurnId == incomingTurnId else {
            return false
        }
        return previousTurnId != nil
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Preserves useful activity lines while still allowing newer thinking snapshots to win.
    private static func mergeThinkingText(existing: String, incoming: String) -> String {
        let existingTrimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTrimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incomingTrimmed.isEmpty else { return existingTrimmed }
        guard !existingTrimmed.isEmpty else { return incomingTrimmed }

        let placeholderValues: Set<String> = ["thinking..."]
        let existingLower = existingTrimmed.lowercased()
        let incomingLower = incomingTrimmed.lowercased()

        if placeholderValues.contains(incomingLower) {
            return existingTrimmed
        }
        if placeholderValues.contains(existingLower) {
            return incomingTrimmed
        }

        if incomingLower == existingLower {
            return incomingTrimmed
        }
        if incomingTrimmed.contains(existingTrimmed) {
            return incomingTrimmed
        }
        if existingTrimmed.contains(incomingTrimmed) {
            return existingTrimmed
        }

        return "\(existingTrimmed)\n\(incomingTrimmed)"
    }

    // Hides duplicated assistant rows caused by mixed completion/history payloads.
    static func removeDuplicateAssistantMessages(in messages: [CodexMessage]) -> [CodexMessage] {
        var seenKeys: Set<String> = []
        var seenNoTurnByText: [String: Date] = [:]
        var result: [CodexMessage] = []
        result.reserveCapacity(messages.count)

        for message in messages {
            guard message.role == .assistant else {
                result.append(message)
                continue
            }

            let normalizedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else {
                result.append(message)
                continue
            }

            if let turnId = message.turnId, !turnId.isEmpty {
                let dedupeScope = message.itemId?.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = "\(turnId)|\(dedupeScope ?? "no-item")|\(normalizedText)"
                if seenKeys.contains(key) {
                    continue
                }
                seenKeys.insert(key)
                result.append(message)
                continue
            }

            if let previous = seenNoTurnByText[normalizedText],
               abs(message.createdAt.timeIntervalSince(previous)) <= 12 {
                continue
            }

            seenNoTurnByText[normalizedText] = message.createdAt
            result.append(message)
        }

        return result
    }

    // Keeps only the newest matching file-change card when multiple event channels emit the same diff.
    static func removeDuplicateFileChangeMessages(in messages: [CodexMessage]) -> [CodexMessage] {
        let signatures = messages.map { fileChangeDedupSignature(for: $0) }
        var supersededIndices: Set<Int> = []

        for olderIndex in messages.indices {
            guard let olderSignature = signatures[olderIndex] else {
                continue
            }

            for newerIndex in messages.indices where newerIndex > olderIndex {
                guard let newerSignature = signatures[newerIndex],
                      fileChangeMessage(newerSignature, supersedes: olderSignature) else {
                    continue
                }
                supersededIndices.insert(olderIndex)
                break
            }
        }

        return messages.enumerated().compactMap { index, message in
            if signatures[index] != nil, supersededIndices.contains(index) {
                return nil
            }
            return message
        }
    }

    // Collapses back-to-back subagent cards when the first one is only a transient
    // placeholder and the second one carries the real child-thread payload.
    static func removeDuplicateSubagentActionMessages(in messages: [CodexMessage]) -> [CodexMessage] {
        var result: [CodexMessage] = []
        result.reserveCapacity(messages.count)

        for message in messages {
            guard let action = message.subagentAction,
                  message.role == .system,
                  message.kind == .subagentAction else {
                result.append(message)
                continue
            }

            guard let previous = result.last,
                  let previousAction = previous.subagentAction,
                  shouldMergeSubagentActionMessages(
                      previous: previous,
                      previousAction: previousAction,
                      incoming: message,
                      incomingAction: action
                  ) else {
                result.append(message)
                continue
            }

            result[result.count - 1] = preferredSubagentActionMessage(previous: previous, incoming: message)
        }

        return result
    }

    private static func shouldMergeSubagentActionMessages(
        previous: CodexMessage,
        previousAction: CodexSubagentAction,
        incoming: CodexMessage,
        incomingAction: CodexSubagentAction
    ) -> Bool {
        guard previous.role == .system,
              previous.kind == .subagentAction,
              previous.threadId == incoming.threadId,
              normalizedIdentifier(previous.turnId) == normalizedIdentifier(incoming.turnId),
              previousAction.normalizedTool == incomingAction.normalizedTool,
              previous.text == incoming.text else {
            return false
        }

        guard let previousItemId = normalizedIdentifier(previous.itemId),
              let incomingItemId = normalizedIdentifier(incoming.itemId) else {
            return false
        }
        if previousItemId != incomingItemId {
            return false
        }

        let previousRows = previousAction.agentRows
        let incomingRows = incomingAction.agentRows

        if previousRows.isEmpty && !incomingRows.isEmpty {
            return true
        }

        if previousRows == incomingRows {
            return true
        }

        return false
    }

    private static func preferredSubagentActionMessage(previous: CodexMessage, incoming: CodexMessage) -> CodexMessage {
        let previousRows = previous.subagentAction?.agentRows ?? []
        let incomingRows = incoming.subagentAction?.agentRows ?? []

        if previousRows.isEmpty && !incomingRows.isEmpty {
            return incoming
        }

        if incoming.isStreaming != previous.isStreaming {
            return incoming.isStreaming ? previous : incoming
        }

        return incoming.orderIndex >= previous.orderIndex ? incoming : previous
    }

    // Keys file-change cards by turn + rendered payload so repeated turn/diff snapshots collapse to one row.
    private static func duplicateFileChangeKey(for message: CodexMessage) -> String? {
        guard let turnId = normalizedIdentifier(message.turnId) else {
            return nil
        }

        if let summaryKey = TurnFileChangeSummaryParser.dedupeKey(from: message.text) {
            return "\(turnId)|\(summaryKey)"
        }

        let normalizedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return nil
        }
        return "\(turnId)|\(normalizedText)"
    }

    // Captures the parts of a file-change row that matter for timeline dedupe.
    private static func fileChangeDedupSignature(for message: CodexMessage) -> FileChangeDedupSignature? {
        guard message.role == .system,
              message.kind == .fileChange,
              let turnId = normalizedIdentifier(message.turnId),
              let key = duplicateFileChangeKey(for: message) else {
            return nil
        }

        let paths = Set(
            TurnFileChangeSummaryParser.parse(from: message.text)?
                .entries
                .map(\.path) ?? []
        )

        return FileChangeDedupSignature(
            turnId: turnId,
            key: key,
            paths: paths,
            isStreaming: message.isStreaming
        )
    }

    // Treats newer file-change snapshots as authoritative only when they describe the
    // same turn and either the same dedupe key or a provisional-to-final snapshot upgrade.
    private static func fileChangeMessage(
        _ newer: FileChangeDedupSignature,
        supersedes older: FileChangeDedupSignature
    ) -> Bool {
        guard newer.turnId == older.turnId else {
            return false
        }

        if newer.key == older.key {
            return true
        }

        guard !newer.paths.isEmpty, !older.paths.isEmpty else {
            return false
        }

        if older.isStreaming && !newer.isStreaming && newer.paths == older.paths {
            return true
        }

        return false
    }
}

private struct FileChangeDedupSignature {
    let turnId: String
    let key: String
    let paths: Set<String>
    let isStreaming: Bool
}
