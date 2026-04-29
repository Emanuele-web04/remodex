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
        let collapsedThinking = collapseThinkingMessages(in: reordered)
        let withoutCommandThinkingEchoes = removeRedundantThinkingCommandActivityMessages(in: collapsedThinking)
        let dedupedUsers = removeDuplicateUserMessages(in: withoutCommandThinkingEchoes)
        let dedupedFileChanges = removeDuplicateFileChangeMessages(in: dedupedUsers)
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

    // Ensures correct visual order within each turn: user → activity → assistant → trailing file changes.
    // Works on non-consecutive messages: collects ALL indices per turnId across the entire
    // array, sorts each turn's messages by role priority, and places them back into their
    // original slot positions. Messages without a turnId are never moved.
    //
    // Multi-item turns (thinking/tool activity → response → more activity → response) are
    // detected by checking whether activity arrives on BOTH sides of an assistant row. When
    // detected, only the original turn-opening user can be floated forward. Later user
    // steer prompts must stay in-place so they do not jump above already-rendered output.
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
            if hasInterleavedUserFlow(turnMessages) {
                // Steer can append a later user row into the still-active turn before the
                // assistant emits another distinct item. Preserve chronology so that user
                // prompt stays visible near the tail instead of jumping to the turn start.
                sorted = turnMessages.sorted { $0.orderIndex < $1.orderIndex }
            } else if hasInterleavedAssistantActivityFlow(turnMessages) {
                // Multi-item turn: keep the streamed interleaving intact. If the turn has
                // only one user prompt, we can still float that original opener forward.
                // Once a second user row exists, treat it as an in-turn steer and preserve
                // full chronological order so it stays near the bottom of the active run.
                let userCount = turnMessages.reduce(into: 0) { partialResult, message in
                    if message.role == .user {
                        partialResult += 1
                    }
                }
                let openingUserID = userCount == 1
                    ? turnMessages
                        .filter { $0.role == .user }
                        .min(by: { $0.orderIndex < $1.orderIndex })?
                        .id
                    : nil

                sorted = turnMessages.sorted { a, b in
                    let aIsOpeningUser = openingUserID != nil && a.id == openingUserID
                    let bIsOpeningUser = openingUserID != nil && b.id == openingUserID
                    if aIsOpeningUser != bIsOpeningUser { return aIsOpeningUser }
                    return a.orderIndex < b.orderIndex
                }
            } else {
                // Single-item turn: apply normal role-based ordering.
                sorted = turnMessages.sorted { a, b in
                    let pA = intraTurnPriority(a)
                    let pB = intraTurnPriority(b)
                    if pA != pB { return pA < pB }
                    return intraTurnTieBreak(a, b)
                }
            }

            // Place sorted messages back into the same slot positions.
            for (i, originalIndex) in indices.enumerated() {
                result[originalIndex] = sorted[i]
            }
        }

        return result
    }

    // Detects steer-like flows where a later user prompt is appended inside the same turn.
    // In those cases the original event order is authoritative for rendering.
    private static func hasInterleavedUserFlow(_ turnMessages: [CodexMessage]) -> Bool {
        let ordered = turnMessages.sorted { $0.orderIndex < $1.orderIndex }
        var seenNonUser = false

        for message in ordered {
            if message.role == .user {
                if seenNonUser {
                    return true
                }
            } else {
                seenNonUser = true
            }
        }

        return false
    }

    // Detects multi-item turns where visible system activity appears on BOTH sides of an
    // assistant message (thinking/tool → response → thinking/tool). This distinguishes true
    // interleaved flows from single-item turns where events arrived out of order.
    private static func hasInterleavedAssistantActivityFlow(_ turnMessages: [CodexMessage]) -> Bool {
        // Distinct assistant items with distinct text are real multi-message turns, but
        // file-change cards still need semantic trailing placement after the final answer.
        var distinctAssistantTexts: Set<String> = []
        var distinctAssistantItemIDs: Set<String> = []
        for message in turnMessages where message.role == .assistant {
            let text = normalizedMessageText(message.text)
            if !text.isEmpty {
                distinctAssistantTexts.insert(text)
            }
            if let itemID = normalizedIdentifier(message.itemId) {
                distinctAssistantItemIDs.insert(itemID)
            }
        }
        let hasFileChangeCard = turnMessages.contains { $0.role == .system && $0.kind == .fileChange }
        if !hasFileChangeCard,
           distinctAssistantTexts.count > 1,
           distinctAssistantItemIDs.count > 1 {
            return true
        }

        // Check pattern: activity → assistant → activity (system activity on both sides).
        let ordered = turnMessages.sorted { $0.orderIndex < $1.orderIndex }
        var hasActivityBeforeAssistant = false
        var seenAssistant = false
        for message in ordered {
            if message.role == .assistant {
                seenAssistant = true
            } else if isInterleavableSystemActivity(message) {
                if !seenAssistant {
                    hasActivityBeforeAssistant = true
                } else if hasActivityBeforeAssistant {
                    return true
                }
            }
        }
        return false
    }

    private static func isInterleavableSystemActivity(_ message: CodexMessage) -> Bool {
        guard message.role == .system else {
            return false
        }

        switch message.kind {
        case .thinking, .toolActivity, .commandExecution:
            return true
        case .chat, .plan, .userInputPrompt, .fileChange, .subagentAction:
            return false
        }
    }

    private static func intraTurnPriority(_ message: CodexMessage) -> Int {
        switch message.role {
        case .user:
            return 0
        case .system:
            switch message.kind {
            case .thinking:
                return 1
            case .toolActivity:
                return 2
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

    // Late terminal replays can arrive with a newer raw order index; stable closed assistant
    // rows should still render by their semantic creation time inside one turn.
    private static func intraTurnTieBreak(_ a: CodexMessage, _ b: CodexMessage) -> Bool {
        if a.role == .assistant,
           b.role == .assistant,
           !a.isStreaming,
           !b.isStreaming,
           a.createdAt != b.createdAt {
            return a.createdAt < b.createdAt
        }

        return a.orderIndex < b.orderIndex
    }

    // Hides persisted technical markers that exist only to reset per-chat diff totals.
    private static func removeHiddenSystemMarkers(in messages: [CodexMessage]) -> [CodexMessage] {
        messages.filter { message in
            !(message.role == .system && message.itemId == TurnSessionDiffResetMarker.manualPushItemID)
        }
    }

    // Collapses repeated thinking placeholders/activity rows within one turn segment so
    // tool cards can interleave without leaving stacked empty thinking rows behind.
    static func collapseThinkingMessages(in messages: [CodexMessage]) -> [CodexMessage] {
        var result: [CodexMessage] = []
        result.reserveCapacity(messages.count)

        for message in messages {
            guard message.role == .system, message.kind == .thinking else {
                result.append(message)
                continue
            }

            guard let previousIndex = latestReusableThinkingIndex(in: result, for: message) else {
                result.append(message)
                continue
            }

            var previous = result[previousIndex]
            let incoming = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !incoming.isEmpty {
                previous.text = mergeThinkingText(existing: previous.text, incoming: incoming)
            }

            // The newest thinking row should own the final streaming/completed state.
            previous.isStreaming = message.isStreaming
            previous.turnId = message.turnId ?? previous.turnId
            previous.itemId = message.itemId ?? previous.itemId
            result[previousIndex] = previous
        }

        return result
    }

    // Reuses the latest thinking row in the current system segment until user/assistant content resumes.
    private static func latestReusableThinkingIndex(
        in messages: [CodexMessage],
        for incoming: CodexMessage
    ) -> Int? {
        for index in messages.indices.reversed() {
            let candidate = messages[index]
            if candidate.role == .assistant || candidate.role == .user {
                break
            }

            guard candidate.role == .system, candidate.kind == .thinking else {
                continue
            }

            if shouldMergeThinkingRows(previous: candidate, incoming: incoming) {
                return index
            }
        }

        return nil
    }

    // Coalesces thinking rows inside one system segment even when identifiers arrive late.
    private static func shouldMergeThinkingRows(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        let previousItemId = normalizedIdentifier(previous.itemId)
        let incomingItemId = normalizedIdentifier(incoming.itemId)
        if let previousItemId, let incomingItemId,
           previousItemId == incomingItemId {
            return true
        }

        guard hasCompatibleThinkingTurnScope(previous: previous, incoming: incoming) else {
            return false
        }

        if isPlaceholderThinkingRow(previous) {
            return true
        }

        let previousHasStableIdentity = hasStableThinkingIdentity(previous)
        let incomingHasStableIdentity = hasStableThinkingIdentity(incoming)

        if previousHasStableIdentity,
           incomingHasStableIdentity,
           previousItemId != nil,
           incomingItemId != nil {
            return false
        }

        if isPlaceholderThinkingRow(incoming) {
            return !previousHasStableIdentity
        }

        if !previousHasStableIdentity || !incomingHasStableIdentity {
            return thinkingSnapshotsOverlap(previous: previous, incoming: incoming)
        }

        return false
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Allows late turn ids to attach to the current system segment without crossing turn boundaries.
    private static func hasCompatibleThinkingTurnScope(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        let previousTurnId = normalizedIdentifier(previous.turnId)
        let incomingTurnId = normalizedIdentifier(incoming.turnId)
        guard let previousTurnId, let incomingTurnId else {
            return true
        }
        return previousTurnId == incomingTurnId
    }

    // Treats synthetic turn-scoped thinking ids as unstable so a later real item can reuse the row.
    private static func hasStableThinkingIdentity(_ message: CodexMessage) -> Bool {
        guard let itemId = normalizedIdentifier(message.itemId) else {
            return false
        }
        return !(itemId.hasPrefix("turn:") && itemId.contains("|kind:\(CodexMessageKind.thinking.rawValue)"))
    }

    // Identifies placeholder-only rows that should be reused instead of stacked.
    private static func isPlaceholderThinkingRow(_ message: CodexMessage) -> Bool {
        ThinkingDisclosureParser.normalizedThinkingContent(from: message.text).isEmpty
    }

    // Merges streaming/history snapshots only when their visible reasoning content overlaps.
    private static func thinkingSnapshotsOverlap(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        let previousText = ThinkingDisclosureParser.normalizedThinkingContent(from: previous.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingText = ThinkingDisclosureParser.normalizedThinkingContent(from: incoming.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !previousText.isEmpty, !incomingText.isEmpty else {
            return previousText.isEmpty || incomingText.isEmpty
        }

        let previousLower = previousText.lowercased()
        let incomingLower = incomingText.lowercased()
        return previousLower == incomingLower
            || previousLower.contains(incomingLower)
            || incomingLower.contains(previousLower)
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

    // Hides command-status echoes that are already rendered as dedicated command cards.
    private static func removeRedundantThinkingCommandActivityMessages(
        in messages: [CodexMessage]
    ) -> [CodexMessage] {
        let commandKeysByTurn = messages.reduce(into: [String: Set<String>]()) { partialResult, message in
            guard message.role == .system,
                  message.kind == .commandExecution,
                  let turnId = normalizedIdentifier(message.turnId),
                  let commandKey = commandActivityKey(from: message.text) else {
                return
            }
            partialResult[turnId, default: Set<String>()].insert(commandKey)
        }

        guard !commandKeysByTurn.isEmpty else {
            return messages
        }

        return messages.filter { message in
            guard message.role == .system,
                  message.kind == .thinking,
                  let turnId = normalizedIdentifier(message.turnId),
                  let commandKeys = commandKeysByTurn[turnId] else {
                return true
            }

            let normalizedThinking = ThinkingDisclosureParser.normalizedThinkingContent(from: message.text)
            let lines = normalizedThinking
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard !lines.isEmpty else {
                return true
            }

            return !lines.allSatisfy { line in
                guard let commandKey = commandActivityKey(from: line) else {
                    return false
                }
                return commandKeys.contains(commandKey)
            }
        }
    }

    private static func commandActivityKey(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard tokens.count >= 2 else {
            return nil
        }

        let status = tokens[0].lowercased()
        guard status == "running"
            || status == "completed"
            || status == "failed"
            || status == "stopped" else {
            return nil
        }

        let command = tokens
            .dropFirst()
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return command.isEmpty ? nil : command
    }

    // Collapses optimistic phone-send rows with their confirmed runtime echoes so
    // a locally-started turn does not render duplicate user prompts.
    static func removeDuplicateUserMessages(in messages: [CodexMessage]) -> [CodexMessage] {
        var result: [CodexMessage] = []
        result.reserveCapacity(messages.count)

        for message in messages {
            guard message.role == .user else {
                result.append(message)
                continue
            }

            // Only fold the phone-send echo when there is a single clear local source row.
            let matchingIndices = result.indices.reversed().filter { index in
                shouldMergeUserMessages(previous: result[index], incoming: message)
            }
            guard matchingIndices.count == 1,
                  let previousIndex = matchingIndices.first else {
                result.append(message)
                continue
            }

            result[previousIndex] = mergedUserMessage(previous: result[previousIndex], incoming: message)
        }

        return result
    }

    private static func shouldMergeUserMessages(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        guard previous.role == .user,
              incoming.role == .user,
              previous.threadId == incoming.threadId,
              normalizedMessageText(previous.text) == normalizedMessageText(incoming.text),
              userMessageMetadataLooksCompatible(previous: previous, incoming: incoming) else {
            return false
        }

        let previousTurnId = normalizedIdentifier(previous.turnId)
        let incomingTurnId = normalizedIdentifier(incoming.turnId)
        if let previousTurnId, let incomingTurnId {
            return previousTurnId == incomingTurnId
                && previous.deliveryState == .pending
                && incoming.deliveryState == .confirmed
                && abs(incoming.createdAt.timeIntervalSince(previous.createdAt)) <= 12
        }

        // Allow only the phone-send upgrade path: optimistic local row without turnId
        // becoming the confirmed runtime echo once the turn exists.
        let isPendingToConfirmedUpgrade = previous.deliveryState == .pending
            && incoming.deliveryState == .confirmed
        let isTurnBindingUpgrade = previousTurnId == nil && incomingTurnId != nil
        guard isPendingToConfirmedUpgrade || isTurnBindingUpgrade else {
            return false
        }

        return abs(incoming.createdAt.timeIntervalSince(previous.createdAt)) <= 12
    }

    private static func mergedUserMessage(previous: CodexMessage, incoming: CodexMessage) -> CodexMessage {
        var merged = previous

        if merged.deliveryState == .pending || incoming.deliveryState == .confirmed {
            merged.deliveryState = incoming.deliveryState
        }
        if merged.turnId == nil {
            merged.turnId = incoming.turnId
        }
        if merged.itemId == nil {
            merged.itemId = incoming.itemId
        }
        if merged.fileMentions.isEmpty && !incoming.fileMentions.isEmpty {
            merged.fileMentions = incoming.fileMentions
        }
        if merged.attachments.isEmpty && !incoming.attachments.isEmpty {
            merged.attachments = incoming.attachments
        }

        let incomingText = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !incomingText.isEmpty {
            merged.text = incoming.text
        }

        return merged
    }

    private static func normalizedMessageText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attachmentSignature(for message: CodexMessage) -> String {
        message.attachments
            .map(\.stableIdentityKey)
            .joined(separator: "|")
    }

    private static func fileMentionsSignature(for fileMentions: [String]) -> String {
        fileMentions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "|")
    }

    private static func userMessageMetadataLooksCompatible(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        let previousFileMentions = fileMentionsSignature(for: previous.fileMentions)
        let incomingFileMentions = fileMentionsSignature(for: incoming.fileMentions)
        if !previousFileMentions.isEmpty,
           !incomingFileMentions.isEmpty,
           previousFileMentions != incomingFileMentions {
            return false
        }

        let previousAttachments = attachmentSignature(for: previous)
        let incomingAttachments = attachmentSignature(for: incoming)
        if !previousAttachments.isEmpty,
           !incomingAttachments.isEmpty,
           previousAttachments != incomingAttachments {
            return false
        }

        return true
    }

    // Hides duplicated assistant rows caused by mixed completion/history payloads.
    static func removeDuplicateAssistantMessages(in messages: [CodexMessage]) -> [CodexMessage] {
        var seenKeys: Set<String> = []
        var seenNoTurnByText: [String: Date] = [:]
        var seenTurnText: [String: AssistantTurnTextObservation] = [:]
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

            if isAssistantBlockReplay(in: result, incoming: message) {
                continue
            }

            if let turnId = message.turnId, !turnId.isEmpty {
                if let exactReplayIndex = result.indices.reversed().first(where: {
                    shouldMergeExactAssistantReplay(previous: result[$0], incoming: message)
                }) {
                    result[exactReplayIndex] = mergedExactAssistantReplay(
                        previous: result[exactReplayIndex],
                        incoming: message
                    )
                    continue
                }

                if let replayIndex = result.indices.reversed().first(where: {
                    shouldMergeAssistantReplay(previous: result[$0], incoming: message)
                }) {
                    let previousText = result[replayIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if previousText.count >= normalizedText.count || previousText.contains(normalizedText) {
                        continue
                    }

                    var merged = result[replayIndex]
                    merged.text = message.text
                    merged.isStreaming = message.isStreaming
                    if merged.itemId == nil {
                        merged.itemId = message.itemId
                    }
                    result[replayIndex] = merged
                    continue
                }

                let dedupeScope = normalizedIdentifier(message.itemId)
                let key = "\(turnId)|\(dedupeScope ?? "no-item")|\(normalizedText)"
                if seenKeys.contains(key) {
                    continue
                }

                let hasStableIdentity = dedupeScope != nil
                let turnTextKey = "\(turnId)|\(normalizedText)"
                if let previous = seenTurnText[turnTextKey],
                   abs(message.createdAt.timeIntervalSince(previous.createdAt)) <= 12,
                   !previous.hasStableIdentity || !hasStableIdentity {
                    continue
                }
                seenKeys.insert(key)
                seenTurnText[turnTextKey] = AssistantTurnTextObservation(
                    createdAt: message.createdAt,
                    hasStableIdentity: hasStableIdentity
                )
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

    private struct AssistantTurnTextObservation {
        let createdAt: Date
        let hasStableIdentity: Bool
    }

    // Folds duplicate final-answer items even when history/live replay assigned different stable item ids.
    private static func shouldMergeExactAssistantReplay(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        guard previous.role == .assistant,
              incoming.role == .assistant,
              previous.threadId == incoming.threadId,
              normalizedIdentifier(previous.turnId) == normalizedIdentifier(incoming.turnId) else {
            return false
        }

        let previousText = normalizedMessageText(previous.text)
        let incomingText = normalizedMessageText(incoming.text)
        guard previousText.count >= 24,
              previousText == incomingText else {
            return false
        }

        return true
    }

    private static func mergedExactAssistantReplay(previous: CodexMessage, incoming: CodexMessage) -> CodexMessage {
        var merged = previous
        merged.isStreaming = previous.isStreaming && incoming.isStreaming
        if merged.turnId == nil {
            merged.turnId = incoming.turnId
        }
        if normalizedIdentifier(merged.itemId) == nil || isProvisionalAssistantIdentity(merged.itemId) {
            merged.itemId = incoming.itemId ?? merged.itemId
        }
        if incoming.text.count > merged.text.count {
            merged.text = incoming.text
        }
        return merged
    }

    // Collapses persisted replay rows where a late delta duplicated part of the final answer.
    private static func shouldMergeAssistantReplay(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        guard previous.role == .assistant,
              incoming.role == .assistant,
              previous.threadId == incoming.threadId,
              normalizedIdentifier(previous.turnId) == normalizedIdentifier(incoming.turnId) else {
            return false
        }

        let previousItemId = normalizedIdentifier(previous.itemId)
        let incomingItemId = normalizedIdentifier(incoming.itemId)
        if let previousItemId, let incomingItemId, previousItemId != incomingItemId {
            return false
        }
        guard isProvisionalAssistantIdentity(previousItemId) || isProvisionalAssistantIdentity(incomingItemId) else {
            return false
        }

        let previousText = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingText = incoming.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard min(previousText.count, incomingText.count) >= 24 else {
            return false
        }

        return previousText.contains(incomingText) || incomingText.contains(previousText)
    }

    // Detects final-completion replays that resend all prior assistant rows for a turn.
    private static func isAssistantBlockReplay(in messages: [CodexMessage], incoming: CodexMessage) -> Bool {
        AssistantReplayDeduper.isReplayMessage(
            in: messages,
            threadId: incoming.threadId,
            turnId: incoming.turnId,
            text: incoming.text,
            excludingMessageID: incoming.id
        )
    }

    private static func isProvisionalAssistantIdentity(_ itemId: String?) -> Bool {
        guard let itemId else {
            return true
        }
        return itemId.hasPrefix("turn:") || itemId.hasPrefix("rollout-")
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
    // Falls back to full normalized text so even unparseable messages with identical content get deduped.
    private static func duplicateFileChangeKey(for message: CodexMessage) -> String? {
        let turnLabel = normalizedIdentifier(message.turnId) ?? "turnless"

        if let summaryKey = TurnFileChangeSummaryParser.dedupeKey(from: message.text) {
            return "\(turnLabel)|\(summaryKey)"
        }

        let normalizedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return nil
        }
        return "\(turnLabel)|\(normalizedText)"
    }

    // Captures the parts of a file-change row that matter for timeline dedupe.
    // Produces a signature even for turnless rows (local/streaming) so a later
    // snapshot with a real turnId can supersede them via path overlap.
    private static func fileChangeDedupSignature(for message: CodexMessage) -> FileChangeDedupSignature? {
        guard message.role == .system,
              message.kind == .fileChange else {
            return nil
        }

        let turnId = normalizedIdentifier(message.turnId)
        let key = duplicateFileChangeKey(for: message)
        let entries = TurnFileChangeSummaryParser.parse(from: message.text)?.entries ?? []

        let paths = Set(
            entries.map(\.path)
        )
        let singleEntryDescriptor: FileChangeSingleEntryDescriptor? = {
            guard entries.count == 1, let entry = entries.first else { return nil }
            return FileChangeSingleEntryDescriptor(
                path: entry.path,
                additions: entry.additions,
                deletions: entry.deletions,
                action: entry.action
            )
        }()

        // Need at least a key or paths to participate in dedup.
        guard key != nil || !paths.isEmpty || singleEntryDescriptor != nil else {
            return nil
        }

        return FileChangeDedupSignature(
            turnId: turnId,
            key: key,
            paths: paths,
            singleEntryDescriptor: singleEntryDescriptor,
            isStreaming: message.isStreaming
        )
    }

    // Treats newer file-change snapshots as authoritative only when they describe the
    // same turn (or a turnless→turnful upgrade) and either the same dedupe key or a
    // provisional-to-final snapshot upgrade with matching paths.
    private static func fileChangeMessage(
        _ newer: FileChangeDedupSignature,
        supersedes older: FileChangeDedupSignature
    ) -> Bool {
        let sameTurn: Bool
        if let newerTurn = newer.turnId, let olderTurn = older.turnId {
            sameTurn = newerTurn == olderTurn
        } else {
            // One or both are turnless — allow matching if paths overlap.
            sameTurn = older.turnId == nil || newer.turnId == nil
        }
        guard sameTurn else {
            return false
        }

        if let newerKey = newer.key, let olderKey = older.key, newerKey == olderKey {
            return true
        }

        if let newerSingle = newer.singleEntryDescriptor,
           let olderSingle = older.singleEntryDescriptor,
           (older.isStreaming || older.turnId == nil),
           singleFileChangeLooksLikePathUpgrade(newer: newerSingle, older: olderSingle) {
            return true
        }

        guard !newer.paths.isEmpty, !older.paths.isEmpty else {
            return false
        }

        // Turnless local row superseded by a real snapshot that now covers the same or a wider file set.
        if older.turnId == nil,
           newer.turnId != nil,
           older.paths.isSubset(of: newer.paths) {
            return true
        }

        // A finalized aggregate snapshot should replace provisional per-file rows from the same turn.
        if older.isStreaming,
           !newer.isStreaming,
           older.paths.isSubset(of: newer.paths) {
            return true
        }

        return false
    }

    private static func singleFileChangeLooksLikePathUpgrade(
        newer: FileChangeSingleEntryDescriptor,
        older: FileChangeSingleEntryDescriptor
    ) -> Bool {
        guard newer.additions == older.additions,
              newer.deletions == older.deletions,
              newer.action == older.action else {
            return false
        }

        let newerPath = normalizedFileChangePath(newer.path)
        let olderPath = normalizedFileChangePath(older.path)
        guard !newerPath.isEmpty, !olderPath.isEmpty, newerPath != olderPath else {
            return false
        }

        let newerHasDirectory = newerPath.contains("/")
        let olderHasDirectory = olderPath.contains("/")
        guard newerHasDirectory != olderHasDirectory else {
            return false
        }

        let longerPath = newerPath.count >= olderPath.count ? newerPath : olderPath
        let shorterPath = newerPath.count >= olderPath.count ? olderPath : newerPath
        return longerPath.hasSuffix("/" + shorterPath)
    }

    private static func normalizedFileChangePath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct FileChangeDedupSignature: Equatable {
    let turnId: String?
    let key: String?
    let paths: Set<String>
    let singleEntryDescriptor: FileChangeSingleEntryDescriptor?
    let isStreaming: Bool
}

private struct FileChangeSingleEntryDescriptor: Equatable {
    let path: String
    let additions: Int
    let deletions: Int
    let action: TurnFileChangeAction?
}
