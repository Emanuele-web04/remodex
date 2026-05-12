// FILE: TurnTimelineBlockAccessories.swift
// Purpose: Builds per-block assistant actions for copy, diff, revert and running indicators.
// Layer: View Support
// Exports: TurnTimelineView.assistantBlockInfo, TurnTimelineView.rehomeCollapsedFinalAccessoryStates
// Depends on: TurnTimelineRenderProjection, FileChangeBlockPresentationCache

import Foundation

extension TurnTimelineView {
    /// For each message index, returns the aggregated assistant block text if the message
    /// is the last non-user message before the next user message (or end of list).
    /// Returns nil for all other indices.
    static func assistantBlockInfo(
        for messages: [CodexMessage],
        activeTurnID: String?,
        isThreadRunning: Bool,
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

            var blockTextParts: [String] = []
            blockTextParts.reserveCapacity(blockEnd - blockStart + 1)
            var blockTurnID: String?
            var fileChangeMessages: [CodexMessage] = []
            var blockRevert: (presentation: AssistantRevertPresentation, message: CodexMessage)?

            for index in blockStart...blockEnd {
                let message = messages[index]
                let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    blockTextParts.append(trimmedText)
                }
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

            let blockText = blockTextParts.joined(separator: "\n\n")
            let isLatestBlock = latestBlockEnd == blockEnd
            let copyText: String?
            if !blockText.isEmpty,
               shouldShowCopyButton(
                blockTurnID: blockTurnID,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                isLatestBlock: isLatestBlock,
                latestTurnTerminalState: latestTurnTerminalState,
                stoppedTurnIDs: stoppedTurnIDs
               ) {
                copyText = blockText
            } else {
                copyText = nil
            }

            let showsRunningIndicator = shouldShowRunningIndicator(
                blockTurnID: blockTurnID,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                isLatestBlock: isLatestBlock,
                latestTurnTerminalState: latestTurnTerminalState,
                stoppedTurnIDs: stoppedTurnIDs
            )

            let blockDiffPresentation = fileChangeMessages.isEmpty
                ? nil
                : FileChangeBlockPresentationCache.presentation(from: fileChangeMessages)
            let blockDiffText = blockDiffPresentation?.bodyText
            let blockDiffEntries = blockDiffPresentation?.entries

            if copyText != nil || showsRunningIndicator || blockDiffEntries != nil || blockRevert != nil {
                result[blockEnd] = AssistantBlockAccessoryState(
                    copyText: copyText,
                    showsRunningIndicator: showsRunningIndicator,
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

            let finalCopyText = finalMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            updated[finalMessage.id] = sourceState.replacingCopyText(finalCopyText.isEmpty ? nil : finalCopyText)
        }
        return updated
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

    private static func normalizedTurnID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    // Keeps Copy aligned with real run completion instead of per-message streaming heuristics.
    private static func shouldShowCopyButton(
        blockTurnID: String?,
        activeTurnID: String?,
        isThreadRunning: Bool,
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

        guard isThreadRunning else {
            return true
        }

        if let blockTurnID, let activeTurnID {
            return blockTurnID != activeTurnID
        }

        return !isLatestBlock
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
