// FILE: TurnTimelineRenderProjection.swift
// Purpose: Builds lightweight render items from raw timeline messages.
// Layer: View Model / Projection
// Exports: TurnTimelineRenderProjection, TurnTimelineRenderItem, timeline grouping models
// Depends on: Foundation, CodexMessage

import Foundation

// ─── Render Item Models ───────────────────────────────────────

struct TurnTimelineToolBurstGroup: Identifiable, Equatable {
    static let collapsedVisibleCount = 5

    let id: String
    let messages: [CodexMessage]

    init(messages: [CodexMessage]) {
        self.messages = messages
        self.id = "tool-burst:\(messages.first?.id ?? "unknown")"
    }

    var pinnedMessages: [CodexMessage] {
        Array(messages.prefix(Self.collapsedVisibleCount))
    }

    var overflowMessages: [CodexMessage] {
        Array(messages.dropFirst(Self.collapsedVisibleCount))
    }

    var hiddenCount: Int {
        overflowMessages.count
    }
}

struct TurnTimelinePreviousMessagesGroup: Identifiable, Equatable {
    let id: String
    let finalMessageID: String
    let messages: [CodexMessage]

    init(finalMessage: CodexMessage, messages: [CodexMessage]) {
        self.id = "previous-messages:\(finalMessage.id)"
        self.finalMessageID = finalMessage.id
        self.messages = messages
    }

    var hiddenCount: Int {
        messages.count
    }
}

enum TurnTimelineRenderItem: Identifiable, Equatable {
    case message(CodexMessage)
    case toolBurst(TurnTimelineToolBurstGroup)
    case previousMessages(TurnTimelinePreviousMessagesGroup)

    var id: String {
        switch self {
        case .message(let message):
            return message.id
        case .toolBurst(let group):
            return group.id
        case .previousMessages(let group):
            return group.id
        }
    }
}

// ─── Projection ────────────────────────────────────────────────

enum TurnTimelineRenderProjection {
    // Groups tool runs and completed-turn preamble rows so the visible timeline stays compact.
    static func project(messages: [CodexMessage], completedTurnIDs: Set<String> = []) -> [TurnTimelineRenderItem] {
        var items: [TurnTimelineRenderItem] = []
        var bufferedToolMessages: [CodexMessage] = []
        let finalCollapsePlan = previousMessagesCollapsePlan(
            in: messages,
            completedTurnIDs: completedTurnIDs
        )
        let hiddenIndices = Set(finalCollapsePlan.values.flatMap(\.indices))
        let groupByStartIndex = Dictionary(
            uniqueKeysWithValues: finalCollapsePlan.values.map { ($0.startIndex, $0) }
        )

        func flushBufferedToolMessages() {
            guard !bufferedToolMessages.isEmpty else { return }
            if bufferedToolMessages.count > TurnTimelineToolBurstGroup.collapsedVisibleCount {
                items.append(.toolBurst(TurnTimelineToolBurstGroup(messages: bufferedToolMessages)))
            } else {
                items.append(contentsOf: bufferedToolMessages.map(TurnTimelineRenderItem.message))
            }
            bufferedToolMessages.removeAll(keepingCapacity: true)
        }

        for (index, message) in messages.enumerated() {
            if let group = groupByStartIndex[index] {
                flushBufferedToolMessages()
                items.append(.previousMessages(group.group))
            }

            if hiddenIndices.contains(index) {
                continue
            }

            guard isToolBurstCandidate(message) else {
                flushBufferedToolMessages()
                items.append(.message(message))
                continue
            }

            if let previous = bufferedToolMessages.last,
               !canShareToolBurst(previous: previous, incoming: message) {
                flushBufferedToolMessages()
            }

            bufferedToolMessages.append(message)
        }

        flushBufferedToolMessages()
        return items
    }

    static func collapsedFinalMessageIDs(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>
    ) -> Set<String> {
        Set(previousMessagesCollapsePlan(
            in: messages,
            completedTurnIDs: completedTurnIDs
        ).keys.map { messages[$0].id })
    }

    private struct PreviousMessagesCollapse {
        let startIndex: Int
        let indices: [Int]
        let group: TurnTimelinePreviousMessagesGroup
    }

    // Finds completed final answers and the same-turn status/tool rows that should sit behind the disclosure.
    private static func previousMessagesCollapsePlan(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>
    ) -> [Int: PreviousMessagesCollapse] {
        guard !completedTurnIDs.isEmpty else {
            return [:]
        }

        let finalAssistantIndexByTurn = messages.indices.reduce(into: [String: Int]()) { result, index in
            let message = messages[index]
            guard message.role == .assistant,
                  !message.isStreaming,
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let turnID = normalizedIdentifier(message.turnId),
                  completedTurnIDs.contains(turnID) else {
                return
            }
            result[turnID] = index
        }

        var plan: [Int: PreviousMessagesCollapse] = [:]
        for (turnID, finalIndex) in finalAssistantIndexByTurn {
            let lowerBound = lastUserIndexBefore(finalIndex, in: messages, turnID: turnID).map { $0 + 1 } ?? messages.startIndex
            let hiddenIndices = messages.indices.filter { index in
                guard index >= lowerBound, index < finalIndex else {
                    return false
                }
                let candidate = messages[index]
                return normalizedIdentifier(candidate.turnId) == turnID
                    && candidate.role != .user
            }

            guard let startIndex = hiddenIndices.first else {
                continue
            }

            let hiddenMessages = hiddenIndices.map { messages[$0] }
            plan[finalIndex] = PreviousMessagesCollapse(
                startIndex: startIndex,
                indices: hiddenIndices,
                group: TurnTimelinePreviousMessagesGroup(
                    finalMessage: messages[finalIndex],
                    messages: hiddenMessages
                )
            )
        }

        return plan
    }

    private static func lastUserIndexBefore(_ index: Int, in messages: [CodexMessage], turnID: String) -> Int? {
        messages.indices.reversed().first { candidateIndex in
            guard candidateIndex < index else {
                return false
            }
            let candidate = messages[candidateIndex]
            return candidate.role == .user
                && normalizedIdentifier(candidate.turnId) == turnID
        }
    }

    private static func isToolBurstCandidate(_ message: CodexMessage) -> Bool {
        guard message.role == .system else {
            return false
        }

        switch message.kind {
        case .toolActivity, .commandExecution:
            return true
        case .thinking, .chat, .plan, .userInputPrompt, .fileChange, .subagentAction:
            return false
        }
    }

    // Late turn ids can arrive mid-stream, so only split when both rows already
    // have distinct stable turn ids.
    private static func canShareToolBurst(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        let previousTurnID = normalizedIdentifier(previous.turnId)
        let incomingTurnID = normalizedIdentifier(incoming.turnId)

        guard let previousTurnID, let incomingTurnID else {
            return true
        }

        return previousTurnID == incomingTurnID
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
