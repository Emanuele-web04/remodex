// FILE: TurnTimelineBlockAccessories.swift
// Purpose: Builds per-block assistant actions for copy, diff, revert and running indicators.
// Layer: View Support
// Exports: TurnTimelineView.assistantBlockInfo, TurnTimelineView.rehomeCollapsedFinalAccessoryStates
// Depends on: TurnTimelineRenderProjection, FileChangeBlockPresentationCache

import Foundation

extension TurnTimelineView {
    private static var blockCopyTextByteLimit: Int { 64_000 }
    private static var eagerBlockDiffByteLimit: Int { 96_000 }
    private static var smallWhitespaceScanByteLimit: Int { 512 }

    /// For each message index, returns the aggregated assistant block text if the message
    /// is the last non-user message before the next user message (or end of list).
    /// Returns nil for all other indices.
    static func assistantBlockInfo(
        for messages: [CodexMessage],
        activeTurnID: String?,
        isThreadRunning: Bool,
        isCopySuppressedByRunState: Bool? = nil,
        latestTurnTerminalState: CodexTurnTerminalState?,
        stoppedTurnIDs: Set<String>,
        revertStatesByMessageID: [String: AssistantRevertPresentation] = [:]
    ) -> [AssistantBlockAccessoryState?] {
        var result = [AssistantBlockAccessoryState?](repeating: nil, count: messages.count)
        let latestBlockEnd = messages.lastIndex(where: { $0.role != .user })
        var i = messages.count - 1
        while i >= 0 {
            guard messages[i].role != .user else { i -= 1; continue }
            // Walk backward to collect the current assistant/system block.
            let blockEnd = i
            var blockStart = i
            while blockStart > 0 && messages[blockStart - 1].role != .user {
                blockStart -= 1
            }

            var blockTurnID: String?
            var fileChangeMessages: [CodexMessage] = []
            var blockRevert: (presentation: AssistantRevertPresentation, message: CodexMessage)?

            for index in blockStart...blockEnd {
                let message = messages[index]
                if message.role == .system, message.kind == .fileChange, !message.isStreaming {
                    fileChangeMessages.append(message)
                }
            }

            for index in stride(from: blockEnd, through: blockStart, by: -1) {
                let message = messages[index]
                if blockTurnID == nil, let turnID = message.turnId {
                    blockTurnID = turnID
                }
                if blockRevert == nil, let presentation = revertStatesByMessageID[message.id] {
                    blockRevert = (presentation, message)
                }
                if blockTurnID != nil, blockRevert != nil {
                    break
                }
            }

            let isLatestBlock = latestBlockEnd == blockEnd
            let copyAllowed = shouldShowCopyButton(
                blockTurnID: blockTurnID,
                isCopySuppressedByRunState: isCopySuppressedByRunState ?? isThreadRunning,
                isLatestBlock: isLatestBlock,
                latestTurnTerminalState: latestTurnTerminalState,
                stoppedTurnIDs: stoppedTurnIDs
            )
            let copyText = copyAllowed
                ? blockCopyText(in: blockStart...blockEnd, messages: messages)
                : nil

            let showsRunningIndicator = shouldShowRunningIndicator(
                blockTurnID: blockTurnID,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                isLatestBlock: isLatestBlock,
                latestTurnTerminalState: latestTurnTerminalState,
                stoppedTurnIDs: stoppedTurnIDs
            )

            let shouldBuildBlockDiff = shouldEagerlyBuildBlockDiff(for: fileChangeMessages)
            let blockDiffPresentation = fileChangeMessages.isEmpty || !shouldBuildBlockDiff
                ? nil
                : FileChangeBlockPresentationCache.presentation(from: fileChangeMessages)
            let blockDiffText = blockDiffPresentation?.bodyText
            let blockDiffEntries = blockDiffPresentation?.entries

            if copyAllowed || showsRunningIndicator || blockDiffEntries != nil || blockRevert != nil {
                result[blockEnd] = AssistantBlockAccessoryState(
                    copyText: copyText,
                    showsRunningIndicator: showsRunningIndicator,
                    allowsCopy: copyAllowed,
                    blockDiffText: blockDiffText,
                    blockDiffEntries: blockDiffEntries,
                    blockRevertPresentation: blockRevert?.presentation,
                    blockRevertMessage: blockRevert?.message
                )
            }
            i = blockStart - 1
        }
        return result
    }

    private static func blockCopyText(
        in range: ClosedRange<Int>,
        messages: [CodexMessage]
    ) -> String? {
        guard messages[range.upperBound].role != .assistant else {
            // Assistant rows copy from their own full action text, so avoid duplicating
            // large response bodies into block accessory state during timeline load.
            return nil
        }

        var parts: [String] = []
        var totalBytes = 0
        for index in range {
            let rawText = messages[index].text
            guard hasMeaningfulBlockText(rawText) else { continue }
            totalBytes += rawText.utf8.count
            guard totalBytes <= blockCopyTextByteLimit else {
                return nil
            }
            parts.append(normalizedSmallBlockText(rawText))
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func hasMeaningfulBlockText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.utf8.count <= smallWhitespaceScanByteLimit else { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalizedSmallBlockText(_ text: String) -> String {
        guard text.utf8.count <= smallWhitespaceScanByteLimit else { return text }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldEagerlyBuildBlockDiff(for messages: [CodexMessage]) -> Bool {
        var totalBytes = 0
        for message in messages {
            totalBytes += message.text.utf8.count
            if totalBytes > eagerBlockDiffByteLimit {
                return false
            }
        }
        return true
    }

    static func rehomeCollapsedFinalAccessoryStates(
        _ statesByMessageID: [String: AssistantBlockAccessoryState],
        messages: [CodexMessage],
        completedTurnIDs: Set<String>
    ) -> [String: AssistantBlockAccessoryState] {
        let collapsedFinalMessageIDs = TurnTimelineRenderProjection.collapsedFinalMessageIDs(
            in: messages,
            completedTurnIDs: completedTurnIDs
        )
        guard !collapsedFinalMessageIDs.isEmpty else {
            return statesByMessageID
        }
        let hiddenMessageIDs = TurnTimelineRenderProjection.collapsedPreviousMessageIDs(
            in: messages,
            completedTurnIDs: completedTurnIDs
        )

        var updated = statesByMessageID
        for finalIndex in messages.indices where collapsedFinalMessageIDs.contains(messages[finalIndex].id) {
            let finalMessage = messages[finalIndex]
            let sourceState = updated[finalMessage.id] ?? collapsedBlockAccessoryState(
                forFinalIndex: finalIndex,
                messages: messages,
                hiddenMessageIDs: hiddenMessageIDs,
                statesByMessageID: updated
            )
            guard let sourceState else { continue }

            updated[finalMessage.id] = sourceState.replacingCopyText(
                rehomedFinalCopyText(for: finalMessage.text)
            )
        }
        return updated
    }

    static func rehomeHiddenAccessoryStates(
        _ statesByMessageID: [String: AssistantBlockAccessoryState],
        messages: [CodexMessage],
        renderItems: [TurnTimelineRenderItem]
    ) -> [String: AssistantBlockAccessoryState] {
        let hostIDs = accessoryHostMessageIDs(in: renderItems)
        guard !hostIDs.isEmpty else {
            return statesByMessageID
        }

        var updated = statesByMessageID
        for index in messages.indices {
            let message = messages[index]
            guard let hiddenState = updated[message.id],
                  !hostIDs.contains(message.id),
                  let targetID = nearestAccessoryHostID(
                    before: index,
                    messages: messages,
                    hostIDs: hostIDs
                  ) else {
                continue
            }

            updated[message.id] = nil
            updated[targetID] = updated[targetID]?.mergingRehomedAccessoryState(hiddenState) ?? hiddenState
        }
        return updated
    }

    // Assistant rows can copy from their full action text; keep accessory copy state small.
    private static func rehomedFinalCopyText(for text: String) -> String? {
        guard hasMeaningfulBlockText(text),
              text.utf8.count <= blockCopyTextByteLimit else {
            return nil
        }
        let copyText = normalizedSmallBlockText(text)
        return copyText.isEmpty ? nil : copyText
    }

    // When late tool rows are collapsed after the final answer, their block action
    // state still belongs on the visible final row.
    private static func collapsedBlockAccessoryState(
        forFinalIndex finalIndex: Int,
        messages: [CodexMessage],
        hiddenMessageIDs: Set<String>,
        statesByMessageID: [String: AssistantBlockAccessoryState]
    ) -> AssistantBlockAccessoryState? {
        let finalMessage = messages[finalIndex]
        let finalTurnID = normalizedTurnID(finalMessage.turnId)
        var blockStart = finalIndex
        while blockStart > messages.startIndex && messages[blockStart - 1].role != .user {
            blockStart -= 1
        }

        var blockEnd = finalIndex
        while blockEnd < messages.index(before: messages.endIndex) && messages[blockEnd + 1].role != .user {
            blockEnd += 1
        }

        for index in stride(from: blockEnd, through: blockStart, by: -1) {
            let candidate = messages[index]
            guard candidate.id != finalMessage.id else { continue }
            guard hiddenMessageIDs.contains(candidate.id) else { continue }
            if let finalTurnID, normalizedTurnID(candidate.turnId) != finalTurnID {
                continue
            }
            if let state = statesByMessageID[candidate.id] {
                return state
            }
        }
        return nil
    }

    // Keeps running/copy accessories visible when projection hides the raw block end
    // (for example an empty thinking placeholder or collapsed tool overflow).
    private static func accessoryHostMessageIDs(in renderItems: [TurnTimelineRenderItem]) -> Set<String> {
        var ids = Set<String>()
        for item in renderItems {
            switch item {
            case .message(let message):
                ids.insert(message.id)
            case .toolBurst(let group):
                ids.formUnion(group.pinnedMessages.map(\.id))
            case .previousMessages:
                break
            }
        }
        return ids
    }

    private static func nearestAccessoryHostID(
        before index: Int,
        messages: [CodexMessage],
        hostIDs: Set<String>
    ) -> String? {
        guard index > messages.startIndex else {
            return nil
        }

        for candidateIndex in stride(from: index - 1, through: messages.startIndex, by: -1) {
            let candidate = messages[candidateIndex]
            if candidate.role == .user {
                return nil
            }
            if hostIDs.contains(candidate.id) {
                return candidate.id
            }
        }
        return nil
    }

    private static func normalizedTurnID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    // Mirrors the composer Stop visibility so Copy never appears while the run is still active.
    private static func shouldShowCopyButton(
        blockTurnID: String?,
        isCopySuppressedByRunState: Bool,
        isLatestBlock: Bool,
        latestTurnTerminalState: CodexTurnTerminalState?,
        stoppedTurnIDs: Set<String>
    ) -> Bool {
        if let blockTurnID, stoppedTurnIDs.contains(blockTurnID) {
            return false
        }

        if isLatestBlock, latestTurnTerminalState == .stopped {
            return false
        }

        return !isCopySuppressedByRunState
    }

    // Keeps the terminal loader attached to the block that still belongs to the active run.
    private static func shouldShowRunningIndicator(
        blockTurnID: String?,
        activeTurnID: String?,
        isThreadRunning: Bool,
        isLatestBlock: Bool,
        latestTurnTerminalState: CodexTurnTerminalState?,
        stoppedTurnIDs: Set<String>
    ) -> Bool {
        guard isThreadRunning else {
            return false
        }

        if isLatestBlock, latestTurnTerminalState == .stopped {
            return false
        }

        if let blockTurnID, stoppedTurnIDs.contains(blockTurnID) {
            return false
        }

        if let blockTurnID, let activeTurnID {
            return blockTurnID == activeTurnID
        }

        return isLatestBlock
    }
}
