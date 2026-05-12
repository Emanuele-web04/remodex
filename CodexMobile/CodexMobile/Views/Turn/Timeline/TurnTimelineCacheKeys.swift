// FILE: TurnTimelineCacheKeys.swift
// Purpose: Builds lightweight signatures for timeline render and block accessory caches.
// Layer: View Support
// Exports: TurnTimelineCacheKeyBuilder
// Depends on: Foundation, CodexMessage

import Foundation

enum TurnTimelineCacheKeyBuilder {
    static func renderItemsSignature(
        threadID: String,
        timelineChangeToken: Int,
        visibleTailCount: Int,
        messages: ArraySlice<CodexMessage>,
        completedTurnIDs: Set<String>
    ) -> TurnTimelineRenderItemsCacheSignature {
        var hasher = Hasher()
        hasher.combine(completedTurnIDs)
        return TurnTimelineRenderItemsCacheSignature(
            threadID: threadID,
            timelineChangeToken: timelineChangeToken,
            visibleTailCount: visibleTailCount,
            messageCount: messages.count,
            firstMessageID: messages.first?.id,
            lastMessageID: messages.last?.id,
            completedTurnIDsHash: hasher.finalize()
        )
    }

    // During streaming, text changes every delta. Hash only the length for live rows
    // to avoid O(text_length) work per frame, then hash full finalized text for reconciliation.
    static func blockInfoInputKey(
        messages: [CodexMessage],
        isThreadRunning: Bool,
        activeTurnID: String?,
        latestTurnTerminalState: CodexTurnTerminalState?,
        completedTurnIDs: Set<String>,
        stoppedTurnIDs: Set<String>,
        assistantRevertStatesByMessageID: [String: AssistantRevertPresentation]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(messages.count)
        hasher.combine(isThreadRunning)
        hasher.combine(activeTurnID)
        hasher.combine(latestTurnTerminalState)
        hasher.combine(completedTurnIDs)
        hasher.combine(stoppedTurnIDs)
        hasher.combine(assistantRevertStatesByMessageID)

        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.role)
            hasher.combine(message.kind)
            hasher.combine(message.turnId)
            hasher.combine(message.isStreaming)
            if message.isStreaming {
                hasher.combine(message.text.count)
            } else {
                hasher.combine(message.text)
            }
        }

        return hasher.finalize()
    }
}
