// FILE: CodexService+IncomingAssistant.swift
// Purpose: Handles assistant-specific incoming events (delta/start/completed) and identity normalization.
// Layer: Service
// Exports: CodexService assistant incoming handlers
// Depends on: CodexService+Incoming shared routing helpers

import Foundation

private struct AssistantEventIdentity {
    let turnId: String?
    let itemId: String?
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

        if let directThreadId = extractThreadID(from: paramsObject), !directThreadId.isEmpty {
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

        markThreadAsRunning(context.threadId)
        clearMirroredRunningCatchupNeeded(for: context.threadId)
        appendAssistantDelta(
            threadId: context.threadId,
            turnId: turnId,
            itemId: context.identity.itemId,
            delta: delta
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

        markMirroredRunningCatchupNeeded(for: threadId)
        appendConfirmedMirroredUserMessage(
            threadId: threadId,
            turnId: turnId,
            text: text
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
            completeAssistantMessage(
                threadId: context.threadId,
                turnId: context.identity.turnId,
                itemId: context.identity.itemId,
                text: text
            )
            return
        }

        let itemType = normalizedItemType(itemObject["type"]?.stringValue ?? "")
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
        completeAssistantMessage(
            threadId: context.threadId,
            turnId: context.identity.turnId,
            itemId: context.identity.itemId,
            text: text
        )
    }

    // Creates streaming assistant placeholder when an assistant item starts.
    func handleItemStarted(_ paramsObject: IncomingParamsObject?) {
        guard let paramsObject else { return }
        let eventObject = envelopeEventObject(from: paramsObject)

        if let directThreadId = extractThreadID(from: paramsObject), !directThreadId.isEmpty {
            markThreadAsRunning(directThreadId)
        }

        guard let itemObject = extractIncomingItemObject(from: paramsObject, eventObject: eventObject) else {
            return
        }

        let itemType = normalizedItemType(itemObject["type"]?.stringValue ?? "")
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
                itemId: context.identity.itemId
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
            itemId: context.identity.itemId
        )
    }
}

private extension CodexService {
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
        return AssistantEventIdentity(turnId: turnId, itemId: itemId)
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
