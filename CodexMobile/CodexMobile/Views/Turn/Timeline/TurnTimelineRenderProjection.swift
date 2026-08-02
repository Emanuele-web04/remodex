// FILE: TurnTimelineRenderProjection.swift
// Purpose: Builds lightweight render items from raw timeline messages.
// Layer: View Model / Projection
// Exports: TurnTimelineRenderProjection, TurnTimelineRenderItem, timeline grouping models
// Depends on: Foundation, CodexMessage, AssistantMarkdownImageReferenceParser, CodeCommentDirectiveParser

import Foundation

// ─── Render Item Models ───────────────────────────────────────

struct TurnTimelineToolBurstGroup: Identifiable, Equatable {
    static let collapseThreshold = 4

    let id: String
    let messages: [CodexMessage]

    init(messages: [CodexMessage]) {
        self.messages = messages
        self.id = "tool-burst:\(messages.first?.id ?? "unknown")"
    }

    var overflowMessages: ArraySlice<CodexMessage> {
        messages.dropLast()
    }

    var latestMessage: CodexMessage? {
        messages.last
    }

    var visibleMessages: ArraySlice<CodexMessage> {
        messages.suffix(1)
    }

    var hiddenCount: Int {
        max(messages.count - 1, 0)
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

struct TurnTimelineCommandGroup: Identifiable, Equatable {
    let id: String
    let messages: [CodexMessage]
    let orderedMessages: [CodexMessage]
    let traceMessages: [CodexMessage]
    let collapsedDetailMessages: [CodexMessage]
    let failedCommandCount: Int
    let stoppedCommandCount: Int
    let toolCallCount: Int

    init(messages: [CodexMessage], orderedMessages: [CodexMessage]? = nil) {
        let resolvedOrderedMessages = orderedMessages ?? messages
        self.messages = messages
        self.orderedMessages = resolvedOrderedMessages
        self.traceMessages = resolvedOrderedMessages.filter {
            $0.role == .system && $0.kind == .thinking
        }
        self.collapsedDetailMessages = resolvedOrderedMessages.filter { message in
            guard message.role == .system else { return false }
            return message.kind == .thinking || message.kind == .fileChange
        }
        var failedCommandCount = 0
        var stoppedCommandCount = 0
        for message in messages {
            switch Self.commandStatusWord(in: message) {
            case "failed":
                failedCommandCount += 1
            case "stopped":
                stoppedCommandCount += 1
            default:
                break
            }
        }
        self.failedCommandCount = failedCommandCount
        self.stoppedCommandCount = stoppedCommandCount
        // Tool rows ride inside the disclosure without ever counting as commands.
        // They coalesce lines per tool, so the entries are what the title reports.
        self.toolCallCount = resolvedOrderedMessages.reduce(into: 0) { total, message in
            guard message.role == .system, message.kind == .toolActivity else { return }
            total += message.text
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .count
        }
        // Tool-only groups carry no command rows, so fall back to the first
        // ordered row to keep the identity stable and collision-free.
        self.id = "command-group:\((messages.first ?? resolvedOrderedMessages.first)?.id ?? "unknown")"
    }

    var commandCount: Int {
        messages.count
    }

    // Folded tool rows carry no accessory state, so a run ending with one (a
    // terminal write after the last exec) would strip the group's copy button
    // and running indicator. Host the footer on the last row that can own it.
    var accessoryHostMessage: CodexMessage? {
        orderedMessages.last { !($0.role == .system && $0.kind == .toolActivity) }
            ?? messages.last
    }

    var hasUnsuccessfulCommands: Bool {
        failedCommandCount > 0 || stoppedCommandCount > 0
    }

    private static func commandStatusWord(in message: CodexMessage) -> String? {
        message.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased()
    }
}

enum TurnTimelineRenderItem: Identifiable, Equatable {
    case message(CodexMessage)
    case toolBurst(TurnTimelineToolBurstGroup)
    case commandGroup(TurnTimelineCommandGroup)
    case previousMessages(TurnTimelinePreviousMessagesGroup)

    var id: String {
        switch self {
        case .message(let message):
            return message.id
        case .toolBurst(let group):
            return group.id
        case .commandGroup(let group):
            return group.id
        case .previousMessages(let group):
            return group.id
        }
    }
}

// ─── Projection ────────────────────────────────────────────────

enum TurnTimelineRenderProjection {
    private static let largeArtifactTextByteLimit = 64_000
    private static let eagerFileChangeCollapseByteLimit = 96_000
    private static let smallWhitespaceScanByteLimit = 512

    struct Result {
        let renderItems: [TurnTimelineRenderItem]
        let metadata: CollapseMetadata
    }

    struct CollapseMetadata {
        let collapsedFinalMessageIDs: Set<String>
        let collapsedPreviousMessageIDs: Set<String>
    }

    // Groups tool runs and completed-turn preamble rows so the visible timeline stays compact.
    static func project(
        messages: [CodexMessage],
        completedTurnIDs: Set<String> = [],
        activeTurnID: String? = nil,
        isThreadRunning: Bool = false
    ) -> [TurnTimelineRenderItem] {
        renderItems(
            messages: messages,
            finalCollapsePlan: resolvedPreviousMessagesCollapsePlan(
                in: messages,
                completedTurnIDs: completedTurnIDs,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning
            ),
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning
        )
    }

    static func result(
        messages: [CodexMessage],
        completedTurnIDs: Set<String> = [],
        activeTurnID: String? = nil,
        isThreadRunning: Bool = false
    ) -> Result {
        let plan = resolvedPreviousMessagesCollapsePlan(
            in: messages,
            completedTurnIDs: completedTurnIDs,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning
        )
        return Result(
            renderItems: renderItems(
                messages: messages,
                finalCollapsePlan: plan,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning
            ),
            metadata: collapseMetadata(from: plan, messages: messages)
        )
    }

    static func collapseMetadata(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>,
        activeTurnID: String? = nil,
        isThreadRunning: Bool = false
    ) -> CollapseMetadata {
        collapseMetadata(
            from: resolvedPreviousMessagesCollapsePlan(
                in: messages,
                completedTurnIDs: completedTurnIDs,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning
            ),
            messages: messages
        )
    }

    private static func renderItems(
        messages: [CodexMessage],
        finalCollapsePlan: [Int: PreviousMessagesCollapse],
        activeTurnID: String?,
        isThreadRunning: Bool
    ) -> [TurnTimelineRenderItem] {
        var items: [TurnTimelineRenderItem] = []
        var bufferedToolMessages: [CodexMessage] = []
        var bufferedCommandMessages: [CodexMessage] = []
        var bufferedCommandOrderedMessages: [CodexMessage] = []
        var bufferedCommandPendingToolActivity: [CodexMessage] = []
        var bufferedCommandTrailingFileChanges: [CodexMessage] = []
        let fileChangePlan = fileChangeCollapsePlan(in: messages)
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
        let latestUserMessageIndex = messages.lastIndex { $0.role == .user }

        func flushBufferedToolMessages() {
            guard !bufferedToolMessages.isEmpty else { return }
            if bufferedToolMessages.count > TurnTimelineToolBurstGroup.collapseThreshold {
                items.append(.toolBurst(TurnTimelineToolBurstGroup(messages: bufferedToolMessages)))
            } else {
                items.append(contentsOf: bufferedToolMessages.map(TurnTimelineRenderItem.message))
            }
            bufferedToolMessages.removeAll(keepingCapacity: true)
        }

        // Tool rows only count as command detail; they never inflate "Ran N commands".
        func commitBufferedCommandPendingToolActivity() {
            guard !bufferedCommandPendingToolActivity.isEmpty else { return }
            bufferedCommandOrderedMessages.append(contentsOf: bufferedCommandPendingToolActivity)
            bufferedCommandPendingToolActivity.removeAll(keepingCapacity: true)
        }

        func belongsToActiveTurn(_ message: CodexMessage, at messageIndex: Int? = nil) -> Bool {
            guard isThreadRunning else { return false }

            let messageTurnID = normalizedIdentifier(message.turnId)
            if let activeTurnID = normalizedIdentifier(activeTurnID) {
                if let messageTurnID {
                    return messageTurnID == activeTurnID
                }
            }

            guard messageTurnID == nil,
                  let latestUserMessageIndex,
                  let messageIndex = messageIndex ?? messages.lastIndex(where: { $0.id == message.id }) else {
                return false
            }
            return messageIndex > latestUserMessageIndex
        }

        let latestActiveToolCallIndex = messages.indices.last(where: { index in
            isToolBurstCandidate(messages[index])
                && belongsToActiveTurn(messages[index], at: index)
        })

        func isOlderActiveToolActivity(_ message: CodexMessage, at messageIndex: Int) -> Bool {
            guard isCommandGroupingToolActivity(message),
                  belongsToActiveTurn(message, at: messageIndex),
                  let latestActiveToolCallIndex else {
                return false
            }
            return messageIndex != latestActiveToolCallIndex
        }

        func flushBufferedCommandMessages(keepsLatestToolCallVisible: Bool = false) {
            commitBufferedCommandPendingToolActivity()

            var deferredToolCall: CodexMessage?
            if keepsLatestToolCallVisible,
               bufferedCommandTrailingFileChanges.isEmpty,
               let latestMessage = bufferedCommandOrderedMessages.last,
               isToolBurstCandidate(latestMessage),
               belongsToActiveTurn(latestMessage) {
                deferredToolCall = bufferedCommandOrderedMessages.removeLast()
                bufferedCommandMessages.removeAll { $0.id == latestMessage.id }
            }

            bufferedCommandPendingToolActivity.removeAll(keepingCapacity: true)

            let groupedToolActivityCount = bufferedCommandOrderedMessages
                .filter(isCommandGroupingToolActivity)
                .count
            if !bufferedCommandMessages.isEmpty {
                items.append(.commandGroup(TurnTimelineCommandGroup(
                    messages: bufferedCommandMessages,
                    orderedMessages: bufferedCommandOrderedMessages
                )))
            } else if groupedToolActivityCount > 1
                || (deferredToolCall != nil && groupedToolActivityCount == 1) {
                // Tool-only runs (apply patch, terminal writes) share the same
                // disclosure as command runs instead of scattering one standalone
                // row per tool call across the turn.
                items.append(.commandGroup(TurnTimelineCommandGroup(
                    messages: [],
                    orderedMessages: bufferedCommandOrderedMessages
                )))
            } else {
                items.append(contentsOf: bufferedCommandOrderedMessages.map(TurnTimelineRenderItem.message))
            }
            if let deferredToolCall {
                items.append(.message(deferredToolCall))
            }
            items.append(contentsOf: bufferedCommandTrailingFileChanges.map(TurnTimelineRenderItem.message))
            bufferedCommandMessages.removeAll(keepingCapacity: true)
            bufferedCommandOrderedMessages.removeAll(keepingCapacity: true)
            bufferedCommandTrailingFileChanges.removeAll(keepingCapacity: true)
        }

        func commitBufferedCommandTrailingFileChanges() {
            guard !bufferedCommandTrailingFileChanges.isEmpty else { return }
            bufferedCommandOrderedMessages.append(contentsOf: bufferedCommandTrailingFileChanges)
            bufferedCommandTrailingFileChanges.removeAll(keepingCapacity: true)
        }

        // Tool rows that led into a run belong to its disclosure, so a desktop
        // mirror that interleaves exec calls with terminal writes still renders
        // one group instead of alternating standalone rows.
        func adoptBufferedToolMessagesIntoOpeningCommandGroup(_ incoming: CodexMessage) -> Bool {
            guard bufferedCommandOrderedMessages.isEmpty,
                  !bufferedToolMessages.isEmpty,
                  bufferedToolMessages.allSatisfy(isCommandGroupingToolActivity),
                  // Adjacency is measured against the row right before the command,
                  // like every other burst check: comparing the oldest buffered row
                  // would fold rows from a previous turn into this group.
                  let previous = bufferedToolMessages.last,
                  canShareToolBurst(previous: previous, incoming: incoming) else {
                return false
            }

            bufferedCommandOrderedMessages.append(contentsOf: bufferedToolMessages)
            bufferedToolMessages.removeAll(keepingCapacity: true)
            return true
        }

        for (index, message) in messages.enumerated() {
            if let group = groupByInsertionIndex[index] {
                flushBufferedToolMessages()
                flushBufferedCommandMessages()
                if group.group.hiddenCount > 0 {
                    items.append(.previousMessages(group.group))
                }
            }

            if hiddenIndices.contains(index) {
                // Completed-turn collapsing must not erase real command boundaries.
                // Reasoning and deduplicated file-change artifacts may sit inside an
                // open command disclosure; hidden commentary still closes it first.
                if !isCommandGroupingCompanion(message) {
                    flushBufferedToolMessages()
                    flushBufferedCommandMessages()
                }
                continue
            }

            let renderedMessage = previousReplacementByIndex[index] ?? fileChangePlan.replacementByIndex[index] ?? message
            if shouldSkipVisualRow(
                renderedMessage,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning
            ) {
                continue
            }

            // A historical Desktop review can arrive after its owning turn has
            // fallen outside the bounded render page. Approved reviews are normal
            // tool history: show them only through that turn's Previous messages
            // disclosure, never as detached rows at the live tail. Denied and
            // otherwise exceptional reviews remain visible for user attention.
            if isApprovedAutoApprovalReview(renderedMessage),
               !belongsToActiveTurn(renderedMessage, at: index) {
                continue
            }

            // Reasoning and inline file changes are command interstitials. File changes
            // remain pending until a later trace/command confirms that they bridge the
            // run; otherwise flush places them back after the command disclosure.
            if !bufferedCommandOrderedMessages.isEmpty,
               isCommandGroupingInterstitial(renderedMessage) {
                flushBufferedToolMessages()
                if let previous = bufferedCommandOrderedMessages.last,
                   !canShareToolBurst(previous: previous, incoming: renderedMessage) {
                    flushBufferedCommandMessages()
                    items.append(.message(renderedMessage))
                } else if isCommandGroupingTrace(renderedMessage) {
                    commitBufferedCommandPendingToolActivity()
                    commitBufferedCommandTrailingFileChanges()
                    bufferedCommandOrderedMessages.append(renderedMessage)
                } else {
                    bufferedCommandTrailingFileChanges.append(renderedMessage)
                }
                continue
            }

            guard isToolBurstCandidate(message) else {
                flushBufferedToolMessages()
                flushBufferedCommandMessages()
                items.append(.message(renderedMessage))
                continue
            }

            // Command disclosures are anchored by finished terminal commands and by
            // finished generic tool calls (apply patch, terminal writes), so patch-only
            // runs group like command runs. A settled tool row only anchors when the
            // plain burst buffer is empty or homogeneous; mixed live runs keep the
            // legacy burst path. Assistant commentary/reasoning remains governed by
            // the completed-turn previous-message projection below.
            let opensCommandGroup = isFinishedCommandToolCall(renderedMessage)
            let anchorsToolOnlyGroup = !opensCommandGroup
                && (
                    isFinishedGroupAnchorToolActivity(renderedMessage)
                        || isOlderActiveToolActivity(renderedMessage, at: index)
                )
                && (
                    !bufferedCommandOrderedMessages.isEmpty
                        || bufferedToolMessages.isEmpty
                        || bufferedToolMessages.allSatisfy(isFinishedGroupAnchorToolActivity)
                )
            if opensCommandGroup || anchorsToolOnlyGroup {
                if !adoptBufferedToolMessagesIntoOpeningCommandGroup(renderedMessage) {
                    flushBufferedToolMessages()
                }
                if let previous = bufferedCommandOrderedMessages.last,
                   !canShareToolBurst(previous: previous, incoming: renderedMessage) {
                    flushBufferedCommandMessages()
                }
                commitBufferedCommandPendingToolActivity()
                commitBufferedCommandTrailingFileChanges()
                if opensCommandGroup {
                    bufferedCommandMessages.append(renderedMessage)
                }
                bufferedCommandOrderedMessages.append(renderedMessage)
                continue
            }

            // Terminal writes, patches and other tool rows interleave with the
            // commands of the same run; folding them into the open disclosure
            // keeps assistant text readable instead of one row per tool call.
            if !bufferedCommandOrderedMessages.isEmpty,
               isCommandGroupingToolActivity(renderedMessage),
               let previous = bufferedCommandOrderedMessages.last,
               canShareToolBurst(previous: previous, incoming: renderedMessage) {
                flushBufferedToolMessages()
                commitBufferedCommandTrailingFileChanges()
                bufferedCommandPendingToolActivity.append(renderedMessage)
                continue
            }

            flushBufferedCommandMessages()
            if let previous = bufferedToolMessages.last,
               !canShareToolBurst(previous: previous, incoming: renderedMessage) {
                flushBufferedToolMessages()
            }
            bufferedToolMessages.append(renderedMessage)
        }

        // Keep the latest call of the active turn readable until another call or
        // assistant text arrives. Once the turn settles, the same projection folds
        // it into the disclosure without needing extra persisted presentation state.
        flushBufferedToolMessages()
        flushBufferedCommandMessages(keepsLatestToolCallVisible: isThreadRunning)
        return mergeAdjacentFileChangeItems(items)
    }

    static func collapsedFinalMessageIDs(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>,
        activeTurnID: String? = nil,
        isThreadRunning: Bool = false
    ) -> Set<String> {
        collapseMetadata(
            in: messages,
            completedTurnIDs: completedTurnIDs,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning
        ).collapsedFinalMessageIDs
    }

    static func collapsedPreviousMessageIDs(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>,
        activeTurnID: String? = nil,
        isThreadRunning: Bool = false
    ) -> Set<String> {
        collapseMetadata(
            in: messages,
            completedTurnIDs: completedTurnIDs,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning
        ).collapsedPreviousMessageIDs
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

            // Stable turn identities are authoritative. Only turnless snapshots
            // fall back to the surrounding user-delimited block.
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
            guard shouldEagerlyCollapseFileChanges(fileChangeMessages) else {
                continue
            }
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

    // Late file-change events can land as adjacent cards. Collapse only within
    // one turn so a previous turn's recap cannot appear under the next prompt.
    private static func mergeAdjacentFileChangeItems(
        _ items: [TurnTimelineRenderItem]
    ) -> [TurnTimelineRenderItem] {
        var mergedItems: [TurnTimelineRenderItem] = []
        var pendingFileChanges: [CodexMessage] = []
        var pendingTurnKey: String?

        func flushPendingFileChanges() {
            guard !pendingFileChanges.isEmpty else { return }
            defer {
                pendingFileChanges.removeAll(keepingCapacity: true)
                pendingTurnKey = nil
            }

            guard pendingFileChanges.count > 1,
                  shouldEagerlyCollapseFileChanges(pendingFileChanges),
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

            let turnKey = fileChangeMergeTurnKey(for: message)
            if pendingTurnKey != nil, pendingTurnKey != turnKey {
                flushPendingFileChanges()
            }
            pendingTurnKey = turnKey
            pendingFileChanges.append(message)
        }

        flushPendingFileChanges()
        return mergedItems
    }

    private static func fileChangeMergeTurnKey(for message: CodexMessage) -> String {
        normalizedIdentifier(message.turnId).map { "turn:\($0)" } ?? "turnless"
    }

    // File-change collapse parses diff bodies; skip eager parsing for very large rows
    // and let the bounded individual timeline cards render instead.
    private static func shouldEagerlyCollapseFileChanges(_ messages: [CodexMessage]) -> Bool {
        var totalBytes = 0
        for message in messages {
            totalBytes += message.text.utf8.count
            if totalBytes > eagerFileChangeCollapseByteLimit {
                return false
            }
        }
        return true
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
        var messageIndicesByTurn: [String: [Int]] = [:]
        var lastUserIndexBeforeFinalByTurn: [String: Int] = [:]
        for index in messages.indices {
            let message = messages[index]
            guard let turnID = normalizedIdentifier(message.turnId) else {
                continue
            }
            messageIndicesByTurn[turnID, default: []].append(index)
            if message.role == .user,
               let finalIndex = resolvedFinalAssistantIndexByTurn[turnID],
               index < finalIndex {
                lastUserIndexBeforeFinalByTurn[turnID] = index
            }
        }

        var plan: [Int: PreviousMessagesCollapse] = [:]
        for (turnID, finalIndex) in resolvedFinalAssistantIndexByTurn {
            let lowerBound = lastUserIndexBeforeFinalByTurn[turnID].map { $0 + 1 } ?? messages.startIndex
            let hiddenSelection = previousMessageSelection(
                in: messages,
                messageIndices: messageIndicesByTurn[turnID] ?? [],
                turnID: turnID,
                finalIndex: finalIndex,
                lowerBound: lowerBound
            )

            guard !hiddenSelection.hiddenIndices.isEmpty else {
                continue
            }

            let hiddenMessages = hiddenSelection.groupIndices
                .map { messages[$0] }
                .filter { !shouldSkipVisualRow($0) }
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

    private static func resolvedPreviousMessagesCollapsePlan(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>,
        activeTurnID: String?,
        isThreadRunning: Bool
    ) -> [Int: PreviousMessagesCollapse] {
        previousMessagesCollapsePlan(
            in: messages,
            completedTurnIDs: completedTurnIDsIncludingFinalAnswerEvidence(
                in: messages,
                completedTurnIDs: completedTurnIDs,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning
            )
        )
    }

    private static func collapseMetadata(
        from plan: [Int: PreviousMessagesCollapse],
        messages: [CodexMessage]
    ) -> CollapseMetadata {
        CollapseMetadata(
            collapsedFinalMessageIDs: Set(plan.keys.map { messages[$0].id }),
            collapsedPreviousMessageIDs: Set(plan.values.flatMap { collapse in
                collapse.indices.map { messages[$0].id }
            })
        )
    }

    // Cold reopen can materialize old rows before turn terminal-state caches.
    // A persisted non-streaming final_answer is safe completion evidence for an
    // older turn, but never for the currently active (or unidentified running) turn.
    private static func completedTurnIDsIncludingFinalAnswerEvidence(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>,
        activeTurnID: String?,
        isThreadRunning: Bool
    ) -> Set<String> {
        // turn/started can omit its id. In that case, protect the newest known
        // turn while the thread is running and still infer older completed turns.
        let protectedRunningTurnID = normalizedIdentifier(activeTurnID)
            ?? (isThreadRunning
                ? messages.reversed().compactMap { normalizedIdentifier($0.turnId) }.first
                : nil)

        var resolved = completedTurnIDs
        for message in messages {
            guard message.role == .assistant,
                  !message.isStreaming,
                  isFinalAnswerAssistantPhase(message.assistantPhase),
                  let turnID = normalizedIdentifier(message.turnId),
                  turnID != protectedRunningTurnID else {
                continue
            }
            resolved.insert(turnID)
        }
        return resolved
    }

    private static func finalAssistantIndexByTurn(
        in messages: [CodexMessage],
        completedTurnIDs: Set<String>
    ) -> [String: Int] {
        var preferredFinalIndexByTurn: [String: Int] = [:]
        var phasedFinalIndexByTurn: [String: Int] = [:]
        var fallbackFinalIndexByTurn: [String: Int] = [:]
        var turnsWithExplicitAssistantPhase = Set<String>()

        for index in messages.indices {
            let message = messages[index]
            guard message.role == .assistant,
                  !message.isStreaming,
                  hasMeaningfulAssistantText(message.text),
                  let turnID = normalizedIdentifier(message.turnId),
                  completedTurnIDs.contains(turnID) else {
                continue
            }

            fallbackFinalIndexByTurn[turnID] = index
            if message.assistantPhase != nil {
                turnsWithExplicitAssistantPhase.insert(turnID)
            }
            if isFinalAnswerAssistantPhase(message.assistantPhase) {
                phasedFinalIndexByTurn[turnID] = index
            }
            if !isAssistantPriorityArtifactOnly(message) {
                preferredFinalIndexByTurn[turnID] = index
            }
        }

        var resolved = phasedFinalIndexByTurn
        for (turnID, index) in preferredFinalIndexByTurn where resolved[turnID] == nil {
            // If the stream carries explicit assistant phases, only a final_answer
            // phase is allowed to own the previous-message disclosure. Commentary
            // updates are live progress, not a final answer to collapse around.
            guard !turnsWithExplicitAssistantPhase.contains(turnID) else { continue }
            resolved[turnID] = index
        }
        for (turnID, index) in fallbackFinalIndexByTurn where resolved[turnID] == nil {
            guard !turnsWithExplicitAssistantPhase.contains(turnID) else { continue }
            resolved[turnID] = index
        }
        return resolved
    }

    private struct PreviousMessageSelection {
        let hiddenIndices: [Int]
        let groupIndices: [Int]
        let generatedImageArtifactIndices: [Int]
    }

    private static func previousMessageSelection(
        in messages: [CodexMessage],
        messageIndices: [Int],
        turnID: String,
        finalIndex: Int,
        lowerBound: Int
    ) -> PreviousMessageSelection {
        let finalMessage = messages[finalIndex]
        var hiddenIndices: [Int] = []
        var groupIndices: [Int] = []
        var generatedImageArtifactIndices: [Int] = []

        for index in messageIndices.drop(while: { $0 < lowerBound }) {
            guard index != finalIndex else {
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

            if isPriorityVisibleMessage(candidate, finalMessage: finalMessage) {
                continue
            }

            // Tool calls and their traces stay compact while a turn is live, then
            // move into the same closed history as the older tool rows once the
            // final answer completes the turn.
            hiddenIndices.append(index)
            groupIndices.append(index)
        }

        return PreviousMessageSelection(
            hiddenIndices: hiddenIndices,
            groupIndices: groupIndices,
            generatedImageArtifactIndices: generatedImageArtifactIndices
        )
    }

    // Keeps user-critical artifacts visible beside the final answer instead of burying them in the disclosure.
    private static func isPriorityVisibleMessage(_ message: CodexMessage, finalMessage: CodexMessage? = nil) -> Bool {
        if message.role == .system {
            switch message.kind {
            case .fileChange, .subagentAction, .userInputPrompt:
                return true
            case .autoApprovalReview:
                // Approved reviews are settled tool history. Keep reviews that
                // failed or may still need attention beside the final answer.
                return message.autoApprovalReview?.status != .approved
            case .plan:
                return message.shouldDisplayInlinePlanResult
            case .thinking, .toolActivity, .commandExecution, .chat:
                return false
            }
        }

        if let finalMessage,
           isGeneratedImageArtifactAlreadyInFinal(message, finalMessage: finalMessage) {
            return false
        }
        return isAssistantPriorityArtifactOnly(message)
    }

    private static func isApprovedAutoApprovalReview(_ message: CodexMessage) -> Bool {
        message.role == .system
            && message.kind == .autoApprovalReview
            && message.autoApprovalReview?.status == .approved
    }

    private static func isReplayOfFinalAssistant(_ message: CodexMessage, finalMessage: CodexMessage) -> Bool {
        guard message.role == .assistant,
              finalMessage.role == .assistant else {
            return false
        }
        guard message.text.utf8.count <= largeArtifactTextByteLimit,
              finalMessage.text.utf8.count <= largeArtifactTextByteLimit else {
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
        guard finalMessage.text.utf8.count <= largeArtifactTextByteLimit else {
            return nil
        }

        var replacement = finalMessage
        var replacementText = finalMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)

        replacementText = collapsedMessages.reduce(replacementText) { text, collapsedMessage in
            guard collapsedMessage.role == .assistant,
                  collapsedMessage.text.utf8.count <= largeArtifactTextByteLimit else {
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
              isGeneratedImageArtifactOnly(message),
              finalMessage.text.utf8.count <= largeArtifactTextByteLimit else {
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
        guard message.text.utf8.count <= largeArtifactTextByteLimit else {
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

    private static func hasMeaningfulAssistantText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.utf8.count <= smallWhitespaceScanByteLimit else { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        case .thinking, .chat, .plan, .userInputPrompt, .autoApprovalReview, .fileChange, .subagentAction:
            return false
        }
    }

    private static func isFinishedCommandToolCall(_ message: CodexMessage) -> Bool {
        guard message.role == .system,
              message.kind == .commandExecution,
              !message.isStreaming else {
            return false
        }

        guard let firstWord = message.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased() else {
            return false
        }

        return firstWord == "completed"
            || firstWord == "failed"
            || firstWord == "stopped"
    }

    private static func isCommandGroupingTrace(_ message: CodexMessage) -> Bool {
        message.role == .system && message.kind == .thinking
    }

    private static func isCommandGroupingInterstitial(_ message: CodexMessage) -> Bool {
        guard message.role == .system else { return false }
        return message.kind == .thinking || message.kind == .fileChange
    }

    private static func isCommandGroupingToolActivity(_ message: CodexMessage) -> Bool {
        message.role == .system && message.kind == .toolActivity
    }

    // A settled generic tool call (apply patch, terminal write, connector read)
    // can anchor a disclosure just like a finished command; streaming rows stay
    // on the live path so the in-progress call remains individually visible.
    private static func isFinishedGroupAnchorToolActivity(_ message: CodexMessage) -> Bool {
        isCommandGroupingToolActivity(message) && !message.isStreaming
    }

    // Rows an open disclosure already absorbs must not close it when the
    // completed-turn projection hides them.
    private static func isCommandGroupingCompanion(_ message: CodexMessage) -> Bool {
        isCommandGroupingInterstitial(message) || isCommandGroupingToolActivity(message)
    }

    // Late turn ids can arrive mid-stream, so split only when both rows already
    // carry distinct stable identities. Commentary rows flush the buffer earlier.
    private static func canShareToolBurst(previous: CodexMessage, incoming: CodexMessage) -> Bool {
        let previousTurnID = normalizedIdentifier(previous.turnId)
        let incomingTurnID = normalizedIdentifier(incoming.turnId)

        guard let previousTurnID, let incomingTurnID else {
            return true
        }
        return previousTurnID == incomingTurnID
    }

    // Drops placeholder-only rows before SwiftUI can reserve timeline spacing for them.
    private static func shouldSkipVisualRow(
        _ message: CodexMessage,
        activeTurnID: String? = nil,
        isThreadRunning: Bool = false
    ) -> Bool {
        if message.role == .assistant,
           message.isStreaming,
           isEmptyStreamingPlaceholderText(message.text) {
            return true
        }

        if isThreadRunning,
           message.role == .system,
           message.kind == .fileChange,
           normalizedIdentifier(message.turnId) == normalizedIdentifier(activeTurnID) {
            return true
        }

        guard message.role == .system,
              message.kind == .thinking else {
            return false
        }

        return isEmptyThinkingPlaceholderText(message.text)
    }

    private static func isEmptyStreamingPlaceholderText(_ text: String) -> Bool {
        guard text.utf8.count <= smallWhitespaceScanByteLimit else {
            return false
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isEmptyThinkingPlaceholderText(_ text: String) -> Bool {
        guard text.utf8.count <= smallWhitespaceScanByteLimit else {
            return false
        }

        return ThinkingDisclosureParser
            .normalizedThinkingContent(from: text)
            .isEmpty
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
