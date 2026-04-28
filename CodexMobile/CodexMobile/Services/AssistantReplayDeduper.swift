// FILE: AssistantReplayDeduper.swift
// Purpose: Shared pure helpers for suppressing flattened assistant replay rows.
// Layer: Service Utility
// Exports: AssistantReplayDeduper
// Depends on: CodexMessage

import Foundation

enum AssistantReplayDeduper {
    // Removes assistant rows that are exact replays of assistant bubbles already seen in the same response block.
    nonisolated static func dedupeBlockReplays(in messages: [CodexMessage]) -> [CodexMessage] {
        var result: [CodexMessage] = []
        result.reserveCapacity(messages.count)

        for message in messages {
            if message.role == .assistant,
               isReplayMessage(
                   in: result,
                   threadId: message.threadId,
                   turnId: message.turnId,
                   text: message.text
               ) {
                continue
            }
            result.append(message)
        }

        return result
    }

    // Detects either a flattened multi-bubble replay or a long exact final-answer replay.
    nonisolated static func isReplayMessage(
        in messages: [CodexMessage],
        threadId: String,
        turnId: String?,
        text: String,
        excludingMessageID: String? = nil
    ) -> Bool {
        if exactReplayMessageIndex(
            in: messages,
            threadId: threadId,
            turnId: turnId,
            text: text,
            excludingMessageID: excludingMessageID
        ) != nil {
            return true
        }

        return blockReplayMessageIndices(
            in: messages,
            threadId: threadId,
            turnId: turnId,
            text: text,
            excludingMessageID: excludingMessageID
        ) != nil
    }

    // Finds a prior long assistant answer with the same text in the same visible response block.
    nonisolated static func exactReplayMessageIndex(
        in messages: [CodexMessage],
        threadId: String,
        turnId: String?,
        text: String,
        excludingMessageID: String? = nil,
        minimumCharacterCount: Int = 80
    ) -> Int? {
        let replayText = normalizedReplayText(text)
        guard replayText.count >= minimumCharacterCount else {
            return nil
        }

        let candidateIndices = responseBlockAssistantIndices(
            in: messages,
            threadId: threadId,
            turnId: turnId,
            excludingMessageID: excludingMessageID
        )
        return candidateIndices.reversed().first { index in
            normalizedReplayText(messages[index].text) == replayText
        }
    }

    // Finds prior assistant row indices when `text` is just their flattened replay.
    nonisolated static func blockReplayMessageIndices(
        in messages: [CodexMessage],
        threadId: String,
        turnId: String?,
        text: String,
        excludingMessageID: String? = nil
    ) -> [Int]? {
        let replayText = normalizedReplayText(text)
        guard !replayText.isEmpty else {
            return nil
        }

        let normalizedTurnId = normalizedIdentifier(turnId)
        let turnScopedIndices: [Int]
        if let normalizedTurnId {
            turnScopedIndices = messages.indices.filter { index in
                let candidate = messages[index]
                return candidate.role == .assistant
                    && candidate.threadId == threadId
                    && candidate.id != excludingMessageID
                    && normalizedIdentifier(candidate.turnId) == normalizedTurnId
                    && !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        } else {
            turnScopedIndices = []
        }

        if let exactMatch = blockReplayMatch(in: messages, candidateIndices: turnScopedIndices, text: replayText) {
            return exactMatch
        }

        let responseBlockIndices = responseBlockAssistantIndices(
            in: messages,
            threadId: threadId,
            turnId: turnId,
            excludingMessageID: excludingMessageID
        )
        return blockReplayMatch(in: messages, candidateIndices: responseBlockIndices, text: replayText)
    }

    private nonisolated static func normalizedReplayText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func responseBlockAssistantIndices(
        in messages: [CodexMessage],
        threadId: String,
        turnId: String?,
        excludingMessageID: String?
    ) -> [Int] {
        let normalizedTurnId = normalizedIdentifier(turnId)
        let lastUserIndex = messages.indices.reversed().first { index in
            let candidate = messages[index]
            return candidate.threadId == threadId && candidate.role == .user
        }
        let blockStartIndex = lastUserIndex.map { $0 + 1 } ?? messages.startIndex
        return messages.indices.filter { index in
            guard index >= blockStartIndex else {
                return false
            }
            let candidate = messages[index]
            let candidateTurnId = normalizedIdentifier(candidate.turnId)
            return candidate.role == .assistant
                && candidate.threadId == threadId
                && candidate.id != excludingMessageID
                && (normalizedTurnId == nil || candidateTurnId == nil || candidateTurnId == normalizedTurnId)
                && !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private nonisolated static func blockReplayMatch(
        in messages: [CodexMessage],
        candidateIndices: [Int],
        text replayText: String
    ) -> [Int]? {
        guard candidateIndices.count >= 2 else {
            return nil
        }

        let existingBlockText = candidateIndices
            .map { messages[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n")
        return normalizedReplayText(existingBlockText) == replayText ? candidateIndices : nil
    }
}
