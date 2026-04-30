// FILE: TurnTimelineRenderProjection.swift
// Purpose: Builds lightweight render items from raw timeline messages.
// Layer: View Model / Projection
// Exports: TurnTimelineRenderProjection, TurnTimelineRenderItem, timeline grouping models
// Depends on: Foundation, CodexMessage, AssistantMarkdownImageReferenceParser, CodeCommentDirectiveParser

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
        let fileChangePlan = fileChangeCollapsePlan(in: messages)
        let finalCollapsePlan = previousMessagesCollapsePlan(
            in: messages,
            completedTurnIDs: completedTurnIDs
        )
        let hiddenIndices = Set(finalCollapsePlan.values.flatMap(\.indices))
            .union(fileChangePlan.hiddenIndices)
        let groupByInsertionIndex = finalCollapsePlan.values.reduce(into: [Int: PreviousMessagesCollapse]()) { result, collapse in
            result[collapse.insertionIndex] = collapse
        }

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
            if let group = groupByInsertionIndex[index] {
                flushBufferedToolMessages()
                items.append(.previousMessages(group.group))
            }

            if hiddenIndices.contains(index) {
                continue
            }

            let renderedMessage = fileChangePlan.replacementByIndex[index] ?? message
            guard isToolBurstCandidate(message) else {
                flushBufferedToolMessages()
                items.append(.message(renderedMessage))
                continue
            }

            if let previous = bufferedToolMessages.last,
               !canShareToolBurst(previous: previous, incoming: renderedMessage) {
                flushBufferedToolMessages()
            }

            bufferedToolMessages.append(renderedMessage)
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

    static func collapsedPreviousMessageIDs(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>
    ) -> Set<String> {
        Set(previousMessagesCollapsePlan(
            in: messages,
            completedTurnIDs: completedTurnIDs
        ).values.flatMap { collapse in
            collapse.indices.map { messages[$0].id }
        })
    }

    private struct PreviousMessagesCollapse {
        let insertionIndex: Int
        let indices: [Int]
        let group: TurnTimelinePreviousMessagesGroup
    }

    private struct FileChangeCollapsePlan {
        let hiddenIndices: Set<Int>
        let replacementByIndex: [Int: CodexMessage]
    }

    // Shows one end-of-turn file table even when the bridge streams multiple file-change snapshots.
    private static func fileChangeCollapsePlan(in messages: [CodexMessage]) -> FileChangeCollapsePlan {
        var groups: [String: [Int]] = [:]
        var blockStart = messages.startIndex

        for index in messages.indices {
            if messages[index].role == .user {
                blockStart = messages.index(after: index)
                continue
            }

            let message = messages[index]
            guard message.role == .system,
                  message.kind == .fileChange,
                  !message.isStreaming else {
                continue
            }

            let key = normalizedIdentifier(message.turnId)
                .map { "turn:\($0)" }
                ?? "block:\(blockStart)"
            groups[key, default: []].append(index)
        }

        var hiddenIndices = Set<Int>()
        var replacementByIndex: [Int: CodexMessage] = [:]

        for indices in groups.values where indices.count > 1 {
            guard let targetIndex = indices.max() else { continue }
            let fileChangeMessages = indices.map { messages[$0] }
            guard let presentation = FileChangeBlockPresentationBuilder.build(from: fileChangeMessages) else {
                continue
            }

            hiddenIndices.formUnion(indices.filter { $0 != targetIndex })
            var replacement = messages[targetIndex]
            replacement.text = presentation.bodyText
            replacementByIndex[targetIndex] = replacement
        }

        return FileChangeCollapsePlan(
            hiddenIndices: hiddenIndices,
            replacementByIndex: replacementByIndex
        )
    }

    // Finds completed final answers and the same-turn status/tool rows that should sit behind the disclosure.
    private static func previousMessagesCollapsePlan(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>
    ) -> [Int: PreviousMessagesCollapse] {
        guard !completedTurnIDs.isEmpty else {
            return [:]
        }

        let resolvedFinalAssistantIndexByTurn = finalAssistantIndexByTurn(
            in: messages,
            completedTurnIDs: completedTurnIDs
        )
        var plan: [Int: PreviousMessagesCollapse] = [:]
        for (turnID, finalIndex) in resolvedFinalAssistantIndexByTurn {
            let lowerBound = lastUserIndexBefore(finalIndex, in: messages, turnID: turnID).map { $0 + 1 } ?? messages.startIndex
            let hiddenIndices = previousMessageIndices(
                in: messages,
                turnID: turnID,
                finalIndex: finalIndex,
                lowerBound: lowerBound
            )

            guard !hiddenIndices.isEmpty else {
                continue
            }

            let hiddenMessages = hiddenIndices.map { messages[$0] }
            plan[finalIndex] = PreviousMessagesCollapse(
                insertionIndex: lowerBound,
                indices: hiddenIndices,
                group: TurnTimelinePreviousMessagesGroup(
                    finalMessage: messages[finalIndex],
                    messages: hiddenMessages
                )
            )
        }

        return plan
    }

    private static func finalAssistantIndexByTurn(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>
    ) -> [String: Int] {
        var preferredFinalIndexByTurn: [String: Int] = [:]
        var fallbackFinalIndexByTurn: [String: Int] = [:]

        for index in messages.indices {
            let message = messages[index]
            guard message.role == .assistant,
                  !message.isStreaming,
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let turnID = normalizedIdentifier(message.turnId),
                  completedTurnIDs.contains(turnID) else {
                continue
            }

            fallbackFinalIndexByTurn[turnID] = index
            if !isAssistantPriorityArtifactOnly(message) {
                preferredFinalIndexByTurn[turnID] = index
            }
        }

        return preferredFinalIndexByTurn.merging(fallbackFinalIndexByTurn) { preferred, _ in preferred }
    }

    private static func previousMessageIndices(
        in messages: [CodexMessage],
        turnID: String,
        finalIndex: Int,
        lowerBound: Int
    ) -> [Int] {
        messages.indices.filter { index in
            guard index >= lowerBound, index != finalIndex else {
                return false
            }
            let candidate = messages[index]
            return normalizedIdentifier(candidate.turnId) == turnID
                && candidate.role != .user
                && !isPriorityVisibleMessage(candidate)
        }
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

    // Keeps user-critical artifacts visible beside the final answer instead of burying them in the disclosure.
    private static func isPriorityVisibleMessage(_ message: CodexMessage) -> Bool {
        if message.role == .system {
            switch message.kind {
            case .fileChange, .subagentAction, .userInputPrompt:
                return true
            case .thinking, .toolActivity, .commandExecution, .chat, .plan:
                return false
            }
        }

        return isAssistantPriorityArtifactOnly(message)
    }

    private static func isAssistantPriorityArtifactOnly(_ message: CodexMessage) -> Bool {
        guard message.role == .assistant, !message.isStreaming else {
            return false
        }

        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return false
        }

        let imageReferences = AssistantMarkdownImageReferenceParser.references(in: text)
        if !imageReferences.isEmpty {
            let textWithoutImages = AssistantMarkdownImageReferenceParser
                .visibleTextRemovingImageSyntax(from: text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if textWithoutImages.isEmpty {
                return true
            }
        }

        let codeCommentContent = CodeCommentDirectiveParser.parse(from: text)
        return codeCommentContent.hasFindings
            && codeCommentContent.fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
