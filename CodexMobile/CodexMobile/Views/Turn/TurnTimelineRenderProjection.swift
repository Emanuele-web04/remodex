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
        let previousReplacementByIndex = finalCollapsePlan.reduce(into: [Int: CodexMessage]()) { result, entry in
            if let replacement = entry.value.replacementFinalMessage {
                result[entry.key] = replacement
            }
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
                if group.group.hiddenCount > 0 {
                    items.append(.previousMessages(group.group))
                }
            }

            if hiddenIndices.contains(index) {
                continue
            }

            let renderedMessage = previousReplacementByIndex[index] ?? fileChangePlan.replacementByIndex[index] ?? message
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
        return mergeAdjacentFileChangeItems(items)
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
        let replacementFinalMessage: CodexMessage?
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

    // Late file-change events can land as adjacent cards from neighboring turns.
    // Present the final submitted file list as one table; duplicate paths are summed by the builder.
    private static func mergeAdjacentFileChangeItems(
        _ items: [TurnTimelineRenderItem]
    ) -> [TurnTimelineRenderItem] {
        var mergedItems: [TurnTimelineRenderItem] = []
        var pendingFileChanges: [CodexMessage] = []

        func flushPendingFileChanges() {
            guard !pendingFileChanges.isEmpty else { return }
            defer { pendingFileChanges.removeAll(keepingCapacity: true) }

            guard pendingFileChanges.count > 1,
                  let presentation = FileChangeBlockPresentationBuilder.build(from: pendingFileChanges),
                  var replacement = pendingFileChanges.last else {
                mergedItems.append(contentsOf: pendingFileChanges.map(TurnTimelineRenderItem.message))
                return
            }

            replacement.text = presentation.bodyText
            mergedItems.append(.message(replacement))
        }

        for item in items {
            guard case .message(let message) = item,
                  message.role == .system,
                  message.kind == .fileChange,
                  !message.isStreaming else {
                flushPendingFileChanges()
                mergedItems.append(item)
                continue
            }

            pendingFileChanges.append(message)
        }

        flushPendingFileChanges()
        return mergedItems
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
            let hiddenSelection = previousMessageSelection(
                in: messages,
                turnID: turnID,
                finalIndex: finalIndex,
                lowerBound: lowerBound
            )

            guard !hiddenSelection.hiddenIndices.isEmpty else {
                continue
            }

            let hiddenMessages = hiddenSelection.groupIndices.map { messages[$0] }
            let replacementFinalMessage = finalMessageReplacingCollapsedArtifacts(
                finalMessage: messages[finalIndex],
                collapsedMessages: hiddenMessages,
                generatedImageArtifacts: hiddenSelection.generatedImageArtifactIndices.map { messages[$0] }
            )
            plan[finalIndex] = PreviousMessagesCollapse(
                insertionIndex: lowerBound,
                indices: hiddenSelection.hiddenIndices,
                group: TurnTimelinePreviousMessagesGroup(
                    finalMessage: messages[finalIndex],
                    messages: hiddenMessages
                ),
                replacementFinalMessage: replacementFinalMessage
            )
        }

        return plan
    }

    private static func finalAssistantIndexByTurn(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>
    ) -> [String: Int] {
        var preferredFinalIndexByTurn: [String: Int] = [:]
        var phasedFinalIndexByTurn: [String: Int] = [:]
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
            if isFinalAnswerAssistantPhase(message.assistantPhase) {
                phasedFinalIndexByTurn[turnID] = index
            }
            if !isAssistantPriorityArtifactOnly(message) {
                preferredFinalIndexByTurn[turnID] = index
            }
        }

        return phasedFinalIndexByTurn
            .merging(preferredFinalIndexByTurn) { phased, _ in phased }
            .merging(fallbackFinalIndexByTurn) { preferred, _ in preferred }
    }

    private struct PreviousMessageSelection {
        let hiddenIndices: [Int]
        let groupIndices: [Int]
        let generatedImageArtifactIndices: [Int]
    }

    private static func previousMessageSelection(
        in messages: [CodexMessage],
        turnID: String,
        finalIndex: Int,
        lowerBound: Int
    ) -> PreviousMessageSelection {
        let finalMessage = messages[finalIndex]
        var hiddenIndices: [Int] = []
        var groupIndices: [Int] = []
        var generatedImageArtifactIndices: [Int] = []

        for index in messages.indices {
            guard index >= lowerBound, index != finalIndex else {
                continue
            }
            let candidate = messages[index]
            guard normalizedIdentifier(candidate.turnId) == turnID,
                  candidate.role != .user else {
                continue
            }

            if isGeneratedImageArtifactOnly(candidate) {
                hiddenIndices.append(index)
                generatedImageArtifactIndices.append(index)
                continue
            }

            if isReplayOfFinalAssistant(candidate, finalMessage: finalMessage) {
                hiddenIndices.append(index)
                if shouldPreserveReplayAsPreviousMessage(candidate, finalMessage: finalMessage) {
                    groupIndices.append(index)
                }
                continue
            }

            if !isPriorityVisibleMessage(candidate, finalMessage: finalMessage) {
                hiddenIndices.append(index)
                groupIndices.append(index)
            }
        }

        return PreviousMessageSelection(
            hiddenIndices: hiddenIndices,
            groupIndices: groupIndices,
            generatedImageArtifactIndices: generatedImageArtifactIndices
        )
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
    private static func isPriorityVisibleMessage(_ message: CodexMessage, finalMessage: CodexMessage? = nil) -> Bool {
        if message.role == .system {
            switch message.kind {
            case .fileChange, .subagentAction, .userInputPrompt:
                return true
            case .thinking, .toolActivity, .commandExecution, .chat, .plan:
                return false
            }
        }

        if let finalMessage,
           isGeneratedImageArtifactAlreadyInFinal(message, finalMessage: finalMessage) {
            return false
        }
        return isAssistantPriorityArtifactOnly(message)
    }

    private static func isReplayOfFinalAssistant(_ message: CodexMessage, finalMessage: CodexMessage) -> Bool {
        guard message.role == .assistant,
              finalMessage.role == .assistant else {
            return false
        }

        if isCommentaryAssistantPhase(message.assistantPhase),
           isFinalAnswerAssistantPhase(finalMessage.assistantPhase) {
            return false
        }

        if isGeneratedImageArtifactAlreadyInFinal(message, finalMessage: finalMessage) {
            return true
        }

        let candidateText = normalizedVisibleAssistantText(message.text)
        let finalText = normalizedVisibleAssistantText(finalMessage.text)
        guard candidateText.count >= 24, finalText.count >= candidateText.count else {
            return false
        }
        return finalText == candidateText || finalText.contains(candidateText)
    }

    private static func shouldPreserveReplayAsPreviousMessage(
        _ message: CodexMessage,
        finalMessage: CodexMessage
    ) -> Bool {
        if isCommentaryAssistantPhase(message.assistantPhase),
           isFinalAnswerAssistantPhase(finalMessage.assistantPhase) {
            return true
        }
        if isFinalAnswerAssistantPhase(message.assistantPhase) {
            return false
        }

        let candidateText = normalizedVisibleAssistantText(message.text)
        let finalText = normalizedVisibleAssistantText(finalMessage.text)
        guard candidateText.count >= 24,
              finalText.hasPrefix(candidateText),
              !looksLikeFinalAnswerText(candidateText) else {
            return false
        }
        return true
    }

    private static func looksLikeFinalAnswerText(_ text: String) -> Bool {
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return lowered.hasPrefix("tldr")
            || lowered.hasPrefix("tl;dr")
            || lowered.hasPrefix("tl:dr")
            || lowered.hasPrefix("summary")
            || lowered.hasPrefix("final")
            || lowered.hasPrefix("done")
    }

    private static func finalMessageReplacingCollapsedArtifacts(
        finalMessage: CodexMessage,
        collapsedMessages: [CodexMessage],
        generatedImageArtifacts: [CodexMessage]
    ) -> CodexMessage? {
        var replacement = finalMessage
        var replacementText = finalMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)

        replacementText = collapsedMessages.reduce(replacementText) { text, collapsedMessage in
            guard collapsedMessage.role == .assistant else {
                return text
            }
            return textRemovingReplay(from: text, replayText: collapsedMessage.text)
        }

        var appendedImagePaths = Set(AssistantMarkdownImageReferenceParser.references(in: replacementText).map(\.path))
        let artifactTexts = generatedImageArtifacts.compactMap { artifact -> String? in
            let artifactText = artifact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artifactText.isEmpty else {
                return nil
            }

            let missingPaths = AssistantMarkdownImageReferenceParser.references(in: artifactText)
                .map(\.path)
                .filter { !appendedImagePaths.contains($0) }
            guard !missingPaths.isEmpty else {
                return nil
            }

            missingPaths.forEach { appendedImagePaths.insert($0) }
            return artifactText
        }

        if !artifactTexts.isEmpty {
            replacementText = ([replacementText] + artifactTexts)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }

        guard replacementText != finalMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        replacement.text = replacementText
        return replacement
    }

    private static func textRemovingReplay(from text: String, replayText: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplay = replayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedReplay.count >= 24,
              trimmedText.count > trimmedReplay.count else {
            return text
        }

        let range: Range<String.Index>?
        if trimmedText.hasPrefix(trimmedReplay) {
            range = trimmedText.startIndex..<trimmedText.index(trimmedText.startIndex, offsetBy: trimmedReplay.count)
        } else {
            range = trimmedText.range(of: trimmedReplay)
        }

        guard let range else {
            return text
        }

        let remainder = (trimmedText[..<range.lowerBound] + trimmedText[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? text : remainder
    }

    private static func isGeneratedImageArtifactAlreadyInFinal(_ message: CodexMessage, finalMessage: CodexMessage) -> Bool {
        guard message.role == .assistant,
              finalMessage.role == .assistant,
              isGeneratedImageArtifactOnly(message) else {
            return false
        }

        let artifactPaths = Set(AssistantMarkdownImageReferenceParser.references(in: message.text).map(\.path))
        guard !artifactPaths.isEmpty,
              artifactPaths.allSatisfy({ AssistantMarkdownImageReferenceParser.isCodexGeneratedImagePath($0) }) else {
            return false
        }

        let finalPaths = Set(AssistantMarkdownImageReferenceParser.references(in: finalMessage.text).map(\.path))
        return artifactPaths.isSubset(of: finalPaths)
    }

    private static func isGeneratedImageArtifactOnly(_ message: CodexMessage) -> Bool {
        guard message.role == .assistant,
              !message.isStreaming,
              isAssistantPriorityArtifactOnly(message) else {
            return false
        }

        let imageReferences = AssistantMarkdownImageReferenceParser.references(in: message.text)
        return !imageReferences.isEmpty
            && imageReferences.allSatisfy(\.isCodexGeneratedImage)
    }

    private static func normalizedVisibleAssistantText(_ text: String) -> String {
        AssistantMarkdownImageReferenceParser
            .visibleTextRemovingImageSyntax(from: text)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func isCommentaryAssistantPhase(_ phase: String?) -> Bool {
        phase == "commentary"
    }

    private static func isFinalAnswerAssistantPhase(_ phase: String?) -> Bool {
        phase == "final_answer"
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
