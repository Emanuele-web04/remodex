// FILE: CodexService+IncomingAssistant.swift
// Purpose: Handles assistant-specific incoming events (delta/start/completed) and identity normalization.
// Layer: Service
// Exports: CodexService assistant incoming handlers
// Depends on: CodexService+Incoming shared routing helpers

import Foundation

private struct AssistantEventIdentity {
    let turnId: String?
    let itemId: String?
    let sourceItemKey: String?
    let phase: String?
}

private struct AssistantEventContext {
    let threadId: String
    let identity: AssistantEventIdentity
}

extension CodexService {
    // Appends streaming assistant text deltas from stable + legacy namespaces.
    func appendAgentDelta(from paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)

        guard let delta = extractAssistantDeltaText(
            from: paramsObject,
            eventObject: eventObject
        ) else { return }

        // Late/replayed deltas for finished turns still merge into closed rows via
        // applyLateTerminalAssistantDelta, but they must never revive running UI.
        let isReplayedEvent = isReplayedBridgeEvent(paramsObject)
        // Rollout bootstrap catch-up (scoped via isApplyingReplayedBridgeEvent) keeps
        // the thread running but must append text as closed history, not streaming.
        let appliesAsReplay = isReplayedEvent || isApplyingReplayedBridgeEvent

        if let directThreadId = extractThreadID(from: paramsObject),
           !directThreadId.isEmpty,
           !isReplayedEvent,
           turnTerminalState(
               for: extractTurnID(from: paramsObject),
               threadId: directThreadId
           ) == nil {
            markThreadAsRunning(directThreadId)
        }

        guard let context = resolveAssistantEventContext(
            paramsObject: paramsObject,
            eventObject: eventObject,
            requiresTurnId: true
        ),
        let turnId = context.identity.turnId else {
            return
        }

        if !isReplayedEvent,
           turnTerminalState(for: turnId, threadId: context.threadId) == nil {
            markThreadAsRunning(context.threadId)
            if activeTurnID(for: context.threadId) == nil {
                setActiveTurnID(turnId, for: context.threadId)
                threadIdByTurnID[turnId] = context.threadId
                activeTurnId = turnId
                setProtectedRunningFallback(false, for: context.threadId)
            }
        }
        clearMirroredRunningCatchupNeeded(for: context.threadId)
        appendAssistantDelta(
            threadId: context.threadId,
            turnId: turnId,
            itemId: context.identity.itemId,
            assistantPhase: context.identity.phase,
            delta: delta,
            isReplay: appliesAsReplay
        )
    }

    // Mirrors a user message coming from a desktop-origin rollout so reopened
    // threads can show the prompt before the next history reconciliation.
    func appendMirroredUserMessage(from paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return
        }
        if let turnId {
            threadIdByTurnID[turnId] = threadId
        }

        let text = firstNonEmptyString([
            paramsObject["message"]?.stringValue,
            paramsObject["text"]?.stringValue,
        ])
        guard let text else { return }
        let createdAt = decodeHistoryTimestamp(from: paramsObject)
        let itemId = firstNonEmptyString([
            paramsObject["itemId"]?.stringValue,
            paramsObject["id"]?.stringValue,
        ])

        markMirroredRunningCatchupNeeded(for: threadId)
        appendConfirmedMirroredUserMessage(
            threadId: threadId,
            turnId: turnId,
            text: text,
            itemId: itemId,
            createdAt: createdAt
        )
    }

    // Finalizes assistant text when item completion carries canonical content.
    func appendCompletedAgentText(from paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)

        let itemObject = extractIncomingItemObject(from: paramsObject, eventObject: eventObject)
        guard let itemObject else {
            // Some legacy codex/event notifications carry only plain final message text.
            let text = paramsObject["message"]?.stringValue
                ?? eventObject?["message"]?.stringValue
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            guard let context = resolveAssistantEventContext(
                paramsObject: paramsObject,
                eventObject: eventObject
            ) else { return }
            let turnId = assistantCompletionTurnId(
                context: context,
                paramsObject: paramsObject,
                eventObject: eventObject,
                itemObject: nil
            )
            let appliesAsReplay = isReplayedBridgeEvent(paramsObject) || isApplyingReplayedBridgeEvent
            if !appliesAsReplay,
               isDesktopMirroredBridgeEvent(paramsObject),
               let turnId {
                appendAssistantDelta(
                    threadId: context.threadId,
                    turnId: turnId,
                    itemId: context.identity.itemId,
                    assistantPhase: context.identity.phase,
                    delta: text,
                    isReplay: false
                )
                return
            }
            completeAssistantMessage(
                threadId: context.threadId,
                turnId: turnId,
                itemId: context.identity.itemId,
                sourceItemKey: context.identity.sourceItemKey,
                assistantPhase: context.identity.phase,
                text: text
            )
            return
        }

        let itemType = normalizedItemType(itemObject["type"]?.stringValue ?? "")
        // Non-active Desktop turns mirror user prompts through item/completed only
        // (no item/started), so the prompt must upsert from here as well.
        if handleMirroredUserMessageItem(
            itemObject: itemObject,
            paramsObject: paramsObject,
            itemType: itemType
        ) {
            return
        }

        if isCompletedGeneratedImageItemType(itemType) {
            appendCompletedGeneratedImageItem(
                itemObject: itemObject,
                paramsObject: paramsObject,
                eventObject: eventObject
            )
            return
        }

        if handleStructuredItemLifecycle(
            itemObject: itemObject,
            paramsObject: paramsObject,
            itemType: itemType,
            isCompleted: true
        ) {
            return
        }

        if itemType == "exitedreviewmode" {
            guard let text = extractCompletedReviewText(from: itemObject), !text.isEmpty else {
                return
            }

            guard let context = resolveAssistantEventContext(
                paramsObject: paramsObject,
                eventObject: eventObject,
                itemObject: itemObject
            ) else { return }
            completeAssistantMessage(
                threadId: context.threadId,
                turnId: context.identity.turnId,
                itemId: context.identity.itemId,
                sourceItemKey: context.identity.sourceItemKey,
                assistantPhase: context.identity.phase,
                text: text
            )
            return
        }

        guard isAssistantMessageItem(
            itemType: itemType,
            role: itemObject["role"]?.stringValue
        ) else {
            return
        }

        let text = extractIncomingMessageText(from: itemObject)
        guard !text.isEmpty else { return }

        guard let context = resolveAssistantEventContext(
            paramsObject: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject
        ) else { return }
        let turnId = assistantCompletionTurnId(
            context: context,
            paramsObject: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject
        )
        completeAssistantMessage(
            threadId: context.threadId,
            turnId: turnId,
            itemId: context.identity.itemId,
            sourceItemKey: context.identity.sourceItemKey,
            assistantPhase: context.identity.phase,
            text: text
        )
    }

    func isCompletedGeneratedImageItemType(_ itemType: String) -> Bool {
        itemType == "imagegeneration"
            || itemType == "imagegenerationcall"
            || itemType == "imagegenerationend"
            || itemType == "imageview"
    }

    // Converts live generated-image completion items into the same markdown preview used by history.
    func appendCompletedGeneratedImageItem(
        itemObject: IncomingParamsObject,
        paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?
    ) {
        let itemType = normalizedItemType(itemObject["type"]?.stringValue ?? "")
        let itemId = extractAssistantMessageItemID(
            paramsObject: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject
        ) ?? ""
        let imagePath = firstNonEmptyString([
            firstStringValue(in: itemObject, keys: ["saved_path", "savedPath", "path", "file_path"]),
            firstStringValue(in: eventObject, keys: ["saved_path", "savedPath", "path", "file_path"]),
            firstStringValue(in: paramsObject, keys: ["saved_path", "savedPath", "path", "file_path"])
        ])
        guard let imagePath, Self.isGeneratedImagePath(imagePath) else {
            debugRuntimeLog("generated image item dropped type=\(itemType) item=\(itemId) reason=missing-path")
            return
        }

        guard let context = resolveAssistantEventContext(
            paramsObject: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject
        ) else {
            debugRuntimeLog("generated image item dropped type=\(itemType) item=\(itemId) path=\(URL(fileURLWithPath: imagePath).lastPathComponent) reason=missing-context")
            return
        }

        appendGeneratedImageReference(
            threadId: context.threadId,
            turnId: context.identity.turnId,
            itemId: context.identity.itemId,
            imagePath: imagePath
        )
        debugRuntimeLog("generated image item appended type=\(itemType) thread=\(context.threadId) turn=\(context.identity.turnId ?? "") item=\(context.identity.itemId ?? "") path=\(URL(fileURLWithPath: imagePath).lastPathComponent)")
    }

    // Creates streaming assistant placeholder when an assistant item starts.
    func handleItemStarted(_ paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)

        // Replayed starts are only ordering hints; deltas create closed history rows.
        if isReplayedBridgeEvent(paramsObject) {
            return
        }

        let lifecycleTurnID = extractTurnID(from: paramsObject)
        let lifecycleThreadID = resolveThreadID(
            from: paramsObject,
            turnIdHint: lifecycleTurnID
        )
        // Replayed item lifecycle events for finished turns must not revive running UI.
        if turnTerminalState(for: lifecycleTurnID, threadId: lifecycleThreadID) != nil {
            return
        }

        if let directThreadId = extractThreadID(from: paramsObject),
           !directThreadId.isEmpty,
           !isReplayedBridgeEvent(paramsObject) {
            markThreadAsRunning(directThreadId)
        }

        guard let itemObject = extractIncomingItemObject(from: paramsObject, eventObject: eventObject) else {
            return
        }

        let itemType = normalizedItemType(itemObject["type"]?.stringValue ?? "")
        if handleMirroredUserMessageItem(
            itemObject: itemObject,
            paramsObject: paramsObject,
            itemType: itemType
        ) {
            return
        }

        if handleStructuredItemLifecycle(
            itemObject: itemObject,
            paramsObject: paramsObject,
            itemType: itemType,
            isCompleted: false
        ) {
            return
        }

        if itemType == "exitedreviewmode" {
            guard let context = resolveAssistantEventContext(
                paramsObject: paramsObject,
                eventObject: eventObject,
                itemObject: itemObject,
                requiresTurnId: true
            ),
            let turnId = context.identity.turnId else {
                return
            }
            beginAssistantMessage(
                threadId: context.threadId,
                turnId: turnId,
                itemId: context.identity.itemId,
                assistantPhase: context.identity.phase
            )
            return
        }

        guard isAssistantMessageItem(
            itemType: itemType,
            role: itemObject["role"]?.stringValue
        ) else {
            return
        }

        guard let context = resolveAssistantEventContext(
            paramsObject: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject,
            requiresTurnId: true
        ),
        let turnId = context.identity.turnId else {
            return
        }
        beginAssistantMessage(
            threadId: context.threadId,
            turnId: turnId,
            itemId: context.identity.itemId,
            assistantPhase: context.identity.phase
        )
    }
}

private extension CodexService {
    // Upserts Desktop-mirrored user prompts delivered as item lifecycle events
    // (item/started for active turns, item/completed for non-active ones).
    func handleMirroredUserMessageItem(
        itemObject: IncomingParamsObject,
        paramsObject: IncomingParamsObject,
        itemType: String
    ) -> Bool {
        guard isDesktopMirroredBridgeEvent(paramsObject) else {
            return false
        }

        let role = itemObject["role"]?.stringValue?.lowercased() ?? ""
        let isUserMessage = itemType == "usermessage"
            || (itemType == "message" && role.contains("user"))
        guard isUserMessage else {
            return false
        }

        let turnId = extractTurnID(from: paramsObject)
        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: turnId) else {
            return true
        }
        if let turnId {
            threadIdByTurnID[turnId] = threadId
        }

        let text = extractIncomingMessageText(from: itemObject)
        guard !text.isEmpty else {
            return true
        }

        markMirroredRunningCatchupNeeded(for: threadId)
        appendConfirmedMirroredUserMessage(
            threadId: threadId,
            turnId: turnId,
            text: text,
            itemId: itemObject["id"]?.stringValue,
            createdAt: decodeHistoryTimestamp(from: paramsObject)
        )
        return true
    }

    // Extracts assistant delta text across stable + legacy codex/event envelopes.
    func extractAssistantDeltaText(
        from paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?
    ) -> String? {
        let delta = paramsObject["delta"]?.stringValue
            ?? eventObject?["delta"]?.stringValue
            ?? paramsObject["event"]?.objectValue?["delta"]?.stringValue
        guard let delta else {
            return nil
        }
        return delta.isEmpty ? nil : delta
    }

    // Normalizes assistant turn/item identity before routing to timeline state.
    func extractAssistantEventIdentity(
        paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?,
        itemObject: IncomingParamsObject? = nil
    ) -> AssistantEventIdentity {
        let turnId = extractTurnID(from: paramsObject)
            ?? extractLegacyTurnIDForAgentEvent(
                from: paramsObject,
                eventObject: eventObject
            )
        let itemId = extractAssistantMessageItemID(
            paramsObject: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject
        )
        return AssistantEventIdentity(
            turnId: turnId,
            itemId: itemId,
            sourceItemKey: extractRemodexSourceItemKey(
                paramsObject: paramsObject,
                eventObject: eventObject,
                itemObject: itemObject
            ),
            phase: extractAssistantPhase(
                paramsObject: paramsObject,
                eventObject: eventObject,
                itemObject: itemObject
            )
        )
    }

    // The local bridge derives this from the source turn plus message content. It is not a
    // provider id and is used only to reconcile the same assistant item across source handoffs.
    func extractRemodexSourceItemKey(
        paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?,
        itemObject: IncomingParamsObject?
    ) -> String? {
        firstNonEmptyString([
            paramsObject["remodexSourceItemKey"]?.stringValue,
            eventObject?["remodexSourceItemKey"]?.stringValue,
            itemObject?["remodexSourceItemKey"]?.stringValue,
            paramsObject["item"]?.objectValue?["remodexSourceItemKey"]?.stringValue,
            eventObject?["item"]?.objectValue?["remodexSourceItemKey"]?.stringValue,
        ])
    }

    // Resolves assistant event context and preserves turn->thread mapping when available.
    func resolveAssistantEventContext(
        paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?,
        itemObject: IncomingParamsObject? = nil,
        requiresTurnId: Bool = false
    ) -> AssistantEventContext? {
        let identity = extractAssistantEventIdentity(
            paramsObject: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject
        )

        if requiresTurnId, identity.turnId == nil {
            return nil
        }

        guard let threadId = resolveThreadID(from: paramsObject, turnIdHint: identity.turnId) else {
            return nil
        }

        if let turnId = identity.turnId {
            threadIdByTurnID[turnId] = threadId
        }

        return AssistantEventContext(threadId: threadId, identity: identity)
    }

    // Codex app-server can emit final_answer text before task_complete without
    // repeating turnId; bind that terminal text to the active turn for this thread.
    func assistantCompletionTurnId(
        context: AssistantEventContext,
        paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?,
        itemObject: IncomingParamsObject?
    ) -> String? {
        if let turnId = context.identity.turnId {
            return turnId
        }
        guard isFinalAnswerPhase(paramsObject: paramsObject, eventObject: eventObject, itemObject: itemObject) else {
            return nil
        }
        return activeTurnIdByThread[context.threadId]
    }

    func isFinalAnswerPhase(
        paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?,
        itemObject: IncomingParamsObject?
    ) -> Bool {
        let phase = extractAssistantPhase(
            paramsObject: paramsObject,
            eventObject: eventObject,
            itemObject: itemObject
        )
        return phase == "final_answer"
    }

    func extractAssistantPhase(
        paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?,
        itemObject: IncomingParamsObject?
    ) -> String? {
        normalizedAssistantPhase(firstNonEmptyString([
            paramsObject["phase"]?.stringValue,
            eventObject?["phase"]?.stringValue,
            itemObject?["phase"]?.stringValue,
            paramsObject["event"]?.objectValue?["phase"]?.stringValue,
        ]))
    }

    // Checks if an incoming item payload should render as assistant prose.
    func isAssistantMessageItem(itemType: String, role: String?) -> Bool {
        let normalizedRole = role?.lowercased() ?? ""
        return itemType == "agentmessage"
            || itemType == "assistantmessage"
            || itemType == "exitedreviewmode"
            || (itemType == "message" && !normalizedRole.contains("user"))
    }

    // Review mode exits deliver the final review text under `review` instead of message content.
    func extractCompletedReviewText(from itemObject: IncomingParamsObject) -> String? {
        let reviewText = firstNonEmptyString([
            itemObject["review"]?.stringValue,
            firstString(forKey: "review", in: .object(itemObject)),
        ])
        return reviewText?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Legacy codex/event assistant notifications can encode turn id in params.id.
    func extractLegacyTurnIDForAgentEvent(
        from paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?
    ) -> String? {
        if let turnId = normalizedIdentifier(paramsObject["id"]?.stringValue),
           paramsObject["msg"] != nil || paramsObject["event"] != nil {
            return turnId
        }

        if let turnId = normalizedIdentifier(eventObject?["turn"]?.objectValue?["id"]?.stringValue) {
            return turnId
        }

        if let turnId = normalizedIdentifier(
            paramsObject["event"]?.objectValue?["turn"]?.objectValue?["id"]?.stringValue
        ) {
            return turnId
        }

        return nil
    }

    // Assistant payloads can carry ids across item_id/message_id/id variants.
    func extractAssistantMessageItemID(
        paramsObject: IncomingParamsObject,
        eventObject: IncomingParamsObject?,
        itemObject: IncomingParamsObject? = nil
    ) -> String? {
        let candidates: [String?] = [
            itemObject?["id"]?.stringValue,
            itemObject?["itemId"]?.stringValue,
            itemObject?["item_id"]?.stringValue,
            itemObject?["messageId"]?.stringValue,
            itemObject?["message_id"]?.stringValue,
            paramsObject["itemId"]?.stringValue,
            paramsObject["item_id"]?.stringValue,
            paramsObject["messageId"]?.stringValue,
            paramsObject["message_id"]?.stringValue,
            paramsObject["item"]?.objectValue?["id"]?.stringValue,
            paramsObject["item"]?.objectValue?["itemId"]?.stringValue,
            paramsObject["item"]?.objectValue?["item_id"]?.stringValue,
            paramsObject["item"]?.objectValue?["messageId"]?.stringValue,
            paramsObject["item"]?.objectValue?["message_id"]?.stringValue,
            eventObject?["itemId"]?.stringValue,
            eventObject?["item_id"]?.stringValue,
            eventObject?["messageId"]?.stringValue,
            eventObject?["message_id"]?.stringValue,
            eventObject?["item"]?.objectValue?["id"]?.stringValue,
            eventObject?["item"]?.objectValue?["itemId"]?.stringValue,
            eventObject?["item"]?.objectValue?["item_id"]?.stringValue,
            eventObject?["item"]?.objectValue?["messageId"]?.stringValue,
            eventObject?["item"]?.objectValue?["message_id"]?.stringValue,
            paramsObject["event"]?.objectValue?["item"]?.objectValue?["id"]?.stringValue,
            paramsObject["event"]?.objectValue?["messageId"]?.stringValue,
            paramsObject["event"]?.objectValue?["message_id"]?.stringValue,
            eventObject?["id"]?.stringValue,
        ]

        for candidate in candidates {
            if let normalized = normalizedIdentifier(candidate) {
                return normalized
            }
        }
        return nil
    }
}
