// FILE: CodexService+History.swift
// Purpose: Parses thread/read history payloads into normalized timeline messages.
// Layer: Service
// Exports: CodexService history parsing helpers
// Depends on: CodexMessage, JSONValue

import Foundation
import UIKit

extension CodexService {
    // Decodes thread/read(includeTurns=true) payload into chronological message timeline.
    func decodeMessagesFromThreadRead(threadId: String, threadObject: [String: JSONValue]) -> [CodexMessage] {
        let baseDate = decodeHistoryBaseDate(from: threadObject)
        let turns = threadObject["turns"]?.arrayValue ?? []

        var offset: TimeInterval = 0
        var result: [CodexMessage] = []

        for turnValue in turns {
            guard let turnObject = turnValue.objectValue else { continue }
            let turnID = turnObject["id"]?.stringValue
            let turnTimestamp = decodeHistoryTimestamp(from: turnObject)
            let items = turnObject["items"]?.arrayValue ?? []

            for itemValue in items {
                guard let itemObject = itemValue.objectValue,
                      let itemType = itemObject["type"]?.stringValue else {
                    continue
                }

                let syntheticTimestamp = (turnTimestamp ?? baseDate).addingTimeInterval(offset)
                let timestamp = decodeHistoryTimestamp(from: itemObject) ?? syntheticTimestamp
                offset += 0.001
                let itemID = itemObject["id"]?.stringValue
                let decodedText = decodeItemText(from: itemObject)
                let imageAttachments = decodeImageAttachments(from: itemObject)

                switch normalizedItemType(itemType) {
                case "usermessage":
                    appendHistoryMessage(
                        to: &result,
                        role: .user,
                        text: decodedText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp,
                        attachments: imageAttachments
                    )

                case "agentmessage", "assistantmessage":
                    appendHistoryMessage(
                        to: &result,
                        role: .assistant,
                        kind: .chat,
                        text: decodedText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp,
                        attachments: imageAttachments
                    )

                case "message":
                    let role = itemObject["role"]?.stringValue?.lowercased() ?? ""
                    let mappedRole: CodexMessageRole = role.contains("user") ? .user : .assistant

                    appendHistoryMessage(
                        to: &result,
                        role: mappedRole,
                        kind: .chat,
                        text: decodedText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp,
                        attachments: imageAttachments
                    )

                case "reasoning":
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: .thinking,
                        text: decodeReasoningItemText(from: itemObject),
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp
                    )

                case "filechange":
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: .fileChange,
                        text: decodeFileChangeItemText(from: itemObject),
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp
                    )

                case "toolcall":
                    guard let decodedToolCall = decodeHistoryToolCallItem(from: itemObject) else { continue }
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: decodedToolCall.kind,
                        text: decodedToolCall.text,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp
                    )

                case "diff":
                    guard let decodedFileChangeText = decodeHistoryDiffItemText(from: itemObject) else { continue }
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: .fileChange,
                        text: decodedFileChangeText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp
                    )

                case "commandexecution":
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: .commandExecution,
                        text: decodeCommandExecutionItemText(from: itemObject),
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp
                    )

                case "enteredreviewmode":
                    let normalizedReviewLabel = decodeHistoryFirstString(
                        forAnyKey: ["review"],
                        in: .object(itemObject)
                    ) ?? "changes"
                    let message = "Reviewing \(normalizedReviewLabel)..."
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: .commandExecution,
                        text: message,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp
                    )

                case "exitedreviewmode":
                    guard let reviewText = decodeHistoryFirstString(
                        forAnyKey: ["review"],
                        in: .object(itemObject)
                    ) else { continue }
                    appendHistoryMessage(
                        to: &result,
                        role: .assistant,
                        kind: .chat,
                        text: reviewText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp
                    )

                case "contextcompaction":
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: .commandExecution,
                        text: "Context compacted",
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp
                    )

                case "plan":
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: .plan,
                        text: decodePlanItemText(from: itemObject),
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp,
                        planState: decodeHistoryPlanState(from: itemObject)
                    )

                case let collabType where collabType == "collabagenttoolcall"
                    || collabType == "collabtoolcall"
                    || collabType.hasPrefix("collabagentspawn")
                    || collabType.hasPrefix("collabwaiting")
                    || collabType.hasPrefix("collabclose")
                    || collabType.hasPrefix("collabresume")
                    || collabType.hasPrefix("collabagentinteraction"):
                    guard let subagentAction = decodeSubagentActionItem(from: itemObject) else {
                        continue
                    }
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: .subagentAction,
                        text: subagentAction.summaryText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp,
                        subagentAction: subagentAction
                    )

                default:
                    continue
                }
            }
        }

        return result
    }

    func decodeHistoryBaseDate(from threadObject: [String: JSONValue]) -> Date {
        if let rawCreatedAt = threadObject["createdAt"]?.doubleValue {
            return decodeUnixTimestamp(rawCreatedAt)
        }
        if let rawCreatedAt = threadObject["created_at"]?.doubleValue {
            return decodeUnixTimestamp(rawCreatedAt)
        }

        if let rawUpdatedAt = threadObject["updatedAt"]?.doubleValue {
            return decodeUnixTimestamp(rawUpdatedAt)
        }
        if let rawUpdatedAt = threadObject["updated_at"]?.doubleValue {
            return decodeUnixTimestamp(rawUpdatedAt)
        }

        if let rawCreatedAt = threadObject["createdAt"]?.stringValue,
           let parsed = parseHistoryDateString(rawCreatedAt) {
            return parsed
        }
        if let rawCreatedAt = threadObject["created_at"]?.stringValue,
           let parsed = parseHistoryDateString(rawCreatedAt) {
            return parsed
        }

        // Deterministic fallback avoids reshuffling on every sync when server omits timestamps.
        return Date(timeIntervalSince1970: 0)
    }

    func decodeUnixTimestamp(_ rawValue: Double) -> Date {
        let secondsValue = rawValue > 10_000_000_000 ? rawValue / 1000 : rawValue
        return Date(timeIntervalSince1970: secondsValue)
    }

    func decodeItemText(from itemObject: [String: JSONValue]) -> String {
        let contentItems = itemObject["content"]?.arrayValue ?? []

        let textParts = contentItems.compactMap { value -> String? in
            guard let object = value.objectValue else { return nil }
            let inputType = normalizedItemType(object["type"]?.stringValue?.lowercased() ?? "")

            if inputType == "text", let text = object["text"]?.stringValue {
                return text
            }

            if inputType == "inputtext" || inputType == "outputtext" || inputType == "message",
               let text = object["text"]?.stringValue {
                return text
            }

            if inputType == "skill" {
                let skillID = object["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let skillName = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = (skillID?.isEmpty == false) ? skillID : skillName
                if let resolved, !resolved.isEmpty {
                    return "$\(resolved)"
                }
            }

            if inputType == "text",
               let dataText = object["data"]?.objectValue?["text"]?.stringValue {
                return dataText
            }

            return nil
        }

        let joined = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            return joined
        }

        if let directText = itemObject["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directText.isEmpty {
            return directText
        }

        if let nestedText = itemObject["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nestedText.isEmpty {
            return nestedText
        }

        return ""
    }

    // Extracts user images from history payload and converts them into renderable thumbnail attachments.
    func decodeImageAttachments(from itemObject: [String: JSONValue]) -> [CodexImageAttachment] {
        let contentItems = itemObject["content"]?.arrayValue ?? []
        var attachments: [CodexImageAttachment] = []

        for value in contentItems {
            guard let object = value.objectValue else { continue }
            let rawType = object["type"]?.stringValue ?? ""
            let normalizedType = normalizedItemType(rawType)
            guard normalizedType == "image" || normalizedType == "localimage" else {
                continue
            }

            let sourceURL = object["url"]?.stringValue
                ?? object["image_url"]?.stringValue
                ?? object["path"]?.stringValue
            let payloadDataURL: String?
            if let sourceURL, sourceURL.lowercased().hasPrefix("data:image") {
                payloadDataURL = sourceURL
            } else {
                payloadDataURL = nil
            }

            let thumbnailBase64: String
            if let payloadDataURL,
               let rawImageData = decodeDataURIImageData(payloadDataURL),
               let thumbnail = makeThumbnailBase64JPEG(from: rawImageData) {
                thumbnailBase64 = thumbnail
            } else {
                thumbnailBase64 = ""
            }

            attachments.append(
                CodexImageAttachment(
                    thumbnailBase64JPEG: thumbnailBase64,
                    payloadDataURL: payloadDataURL,
                    sourceURL: sourceURL
                )
            )
        }

        return attachments
    }

    func mergeHistoryMessages(_ existing: [CodexMessage], _ history: [CodexMessage]) -> [CodexMessage] {
        let activeThreadIDs = Set(activeTurnIdByThread.keys)
        let runningIDs = runningThreadIDs
        return Self.mergeHistoryMessages(existing, history, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningIDs)
    }

    nonisolated static func mergeHistoryMessages(
        _ existing: [CodexMessage],
        _ history: [CodexMessage],
        activeThreadIDs: Set<String>,
        runningThreadIDs: Set<String>
    ) -> [CodexMessage] {
        if existing.isEmpty {
            // History messages arrive in server order; assign sequential orderIndex values
            // so that the stable sort preserves server-provided chronology.
            var sorted = history.sorted(by: { $0.createdAt < $1.createdAt })
            for index in sorted.indices {
                sorted[index].orderIndex = CodexMessageOrderCounter.next()
            }
            return sorted
        }

        var merged = existing

        for message in history {
            if message.role == .assistant,
               let turnId = message.turnId, !turnId.isEmpty,
               let index = merged.lastIndex(where: { candidate in
                   candidate.role == .assistant
                       && candidate.turnId == turnId
                       && normalizedMessageText(candidate.text) == normalizedMessageText(message.text)
               }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            // Fallback: match assistant by turnId alone when text-based matching missed
            // (e.g. history arrives while streaming is in progress, or itemId mismatch).
            if message.role == .assistant,
               let turnId = message.turnId, !turnId.isEmpty,
               let incomingItemId = normalizedHistoryIdentifier(message.itemId),
               let index = merged.lastIndex(where: { candidate in
                   candidate.role == .assistant
                       && candidate.turnId == turnId
                       && (normalizedHistoryIdentifier(candidate.itemId) == nil
                           || normalizedHistoryIdentifier(candidate.itemId) == incomingItemId)
               }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            // Legacy fallback for servers that still omit assistant item ids in history snapshots.
            if message.role == .assistant,
               let turnId = message.turnId, !turnId.isEmpty,
               normalizedHistoryIdentifier(message.itemId) == nil,
               let index = merged.lastIndex(where: { candidate in
                   candidate.role == .assistant
                       && candidate.turnId == turnId
                       && normalizedHistoryIdentifier(candidate.itemId) == nil
               }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            // Forced resume snapshots can materialize a real assistant itemId after the
            // live row was already created with a placeholder/stale identity. When the
            // turn is still active, prefer merging into the streaming row instead of
            // appending a second assistant bubble for the same response.
            if message.role == .assistant,
               let turnId = message.turnId, !turnId.isEmpty,
               (activeThreadIDs.contains(message.threadId) || runningThreadIDs.contains(message.threadId)),
               let index = merged.lastIndex(where: { candidate in
                   candidate.role == .assistant
                       && candidate.turnId == turnId
                       && candidate.isStreaming
               }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            if message.role == .user,
               let turnId = message.turnId, !turnId.isEmpty,
               let index = merged.lastIndex(where: { candidate in
                   candidate.role == .user
                       && candidate.deliveryState != .failed
                       && normalizedMessageText(candidate.text) == normalizedMessageText(message.text)
                       && attachmentSignature(for: candidate.attachments) == attachmentSignature(for: message.attachments)
                       && (candidate.turnId == nil || candidate.turnId == turnId)
               }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            // Reconcile turn-scoped thinking snapshots even when the streamed row
            // carries a synthetic itemId (e.g. "turn:ABC|kind:thinking") that differs
            // from the server's real itemId or nil.
            if message.role == .system,
               message.kind == .thinking,
               let turnId = message.turnId, !turnId.isEmpty,
               let index = merged.lastIndex(where: { candidate in
                   candidate.role == .system
                       && candidate.kind == .thinking
                       && candidate.turnId == turnId
               }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            // Reconcile turn-scoped file change items even when the streamed row
            // has a synthetic itemId that differs from the server's real one.
            if message.role == .system,
               message.kind == .fileChange,
               let turnId = message.turnId, !turnId.isEmpty,
               let index = merged.lastIndex(where: { candidate in
                   candidate.role == .system
                       && candidate.kind == .fileChange
                       && (candidate.turnId == nil || candidate.turnId == turnId)
               }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            // Rebind generic tool rows when a live synthetic row gets a real history item id later.
            if message.role == .system,
               message.kind == .toolActivity,
               let turnId = message.turnId, !turnId.isEmpty {
                let candidateIndices = merged.indices.filter { index in
                    let candidate = merged[index]
                    return candidate.role == .system
                        && candidate.kind == .toolActivity
                        && candidate.turnId == turnId
                }

                if let itemIndex = candidateIndices.last(where: { index in
                    let candidateItemId = normalizedHistoryIdentifier(merged[index].itemId)
                    let incomingItemId = normalizedHistoryIdentifier(message.itemId)
                    return candidateItemId != nil && candidateItemId == incomingItemId
                }) {
                    merged[itemIndex] = reconcileExistingMessage(merged[itemIndex], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                    continue
                }

                if candidateIndices.count == 1,
                   let index = candidateIndices.last,
                   isProvisionalToolActivityRow(merged[index]),
                   shouldReconcileToolActivityRow(
                    merged[index],
                    with: message,
                    requiresExactText: false
                   ) {
                    merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                    continue
                }

                if candidateIndices.count > 1 {
                    let reconcilableIndices = candidateIndices.filter { index in
                        shouldReconcileToolActivityRow(
                            merged[index],
                            with: message,
                            requiresExactText: true
                        )
                    }

                    if reconcilableIndices.count == 1,
                       let index = reconcilableIndices.last {
                        merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                        continue
                    }
                }
            }

            // Dedupes command rows when incoming/history command formatting differs only by shell quoting.
            if message.role == .system,
               message.kind == .commandExecution,
               let turnId = message.turnId, !turnId.isEmpty,
               let incomingCommandKey = normalizedCommandExecutionPreviewKey(from: message.text),
               let index = merged.lastIndex(where: { candidate in
                   guard candidate.role == .system,
                         candidate.kind == .commandExecution,
                         candidate.turnId == turnId,
                         let candidateCommandKey = normalizedCommandExecutionPreviewKey(from: candidate.text) else {
                       return false
                   }
                   return candidateCommandKey == incomingCommandKey
               }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            // Reconcile turn-scoped command execution items by turnId when text-based
            // dedup above did not match (e.g. synthetic vs real itemId).
            if message.role == .system,
               message.kind == .commandExecution,
               let turnId = message.turnId, !turnId.isEmpty,
               let index = merged.lastIndex(where: { candidate in
                   candidate.role == .system
                       && candidate.kind == .commandExecution
                       && candidate.turnId == turnId
               }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            let key = historyMessageKey(for: message)
            if let index = merged.firstIndex(where: { historyMessageKey(for: $0) == key }) {
                merged[index] = reconcileExistingMessage(merged[index], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            if message.role == .user,
               let pendingIndex = merged.lastIndex(where: { candidate in
                   candidate.role == .user
                       && candidate.deliveryState == .pending
                       && normalizedMessageText(candidate.text) == normalizedMessageText(message.text)
                       && attachmentSignature(for: candidate.attachments) == attachmentSignature(for: message.attachments)
               }) {
                merged[pendingIndex] = reconcileExistingMessage(merged[pendingIndex], with: message, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningThreadIDs)
                continue
            }

            merged.append(message)
        }

        merged.sort(by: { $0.orderIndex < $1.orderIndex })
        return merged
    }

    func decodeHistoryTimestamp(from object: [String: JSONValue]) -> Date? {
        let numericKeys = [
            "createdAt",
            "created_at",
            "timestamp",
            "time",
            "updatedAt",
            "updated_at",
        ]

        for key in numericKeys {
            if let value = object[key]?.doubleValue {
                return decodeUnixTimestamp(value)
            }
            if let value = object[key]?.intValue {
                return decodeUnixTimestamp(Double(value))
            }
            if let value = object[key]?.stringValue {
                if let numeric = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return decodeUnixTimestamp(numeric)
                }
                if let parsed = parseHistoryDateString(value) {
                    return parsed
                }
            }
        }

        return nil
    }

    func parseHistoryDateString(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) {
            return date
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: trimmed)
    }

    func reconcileExistingMessage(_ localMessage: CodexMessage, with serverMessage: CodexMessage) -> CodexMessage {
        let activeThreadIDs = Set(activeTurnIdByThread.keys)
        let runningIDs = runningThreadIDs
        return Self.reconcileExistingMessage(localMessage, with: serverMessage, activeThreadIDs: activeThreadIDs, runningThreadIDs: runningIDs)
    }

    nonisolated static func reconcileExistingMessage(
        _ localMessage: CodexMessage,
        with serverMessage: CodexMessage,
        activeThreadIDs: Set<String>,
        runningThreadIDs: Set<String>
    ) -> CodexMessage {
        var value = localMessage
        let threadIsActive = activeThreadIDs.contains(localMessage.threadId) || runningThreadIDs.contains(localMessage.threadId)
        let preservesRunningPresentation = threadIsActive
            && (
                localMessage.turnId == nil
                || serverMessage.turnId == nil
                || localMessage.turnId == serverMessage.turnId
            )

        if value.deliveryState == .pending {
            value.deliveryState = .confirmed
        }

        if value.turnId == nil {
            value.turnId = serverMessage.turnId
        }
        let localItemId = normalizedHistoryIdentifier(value.itemId)
        let serverItemId = normalizedHistoryIdentifier(serverMessage.itemId)
        if localItemId == nil
            || (
                preservesRunningPresentation
                    && value.role == .assistant
                    && localMessage.isStreaming
                    && serverItemId != nil
                    && localItemId != serverItemId
            )
            || (
                value.role == .system
                    && value.kind == .toolActivity
                    && serverItemId != nil
                    && !hasStableToolActivityIdentity(localItemId)
                    && localItemId != serverItemId
            ) {
            value.itemId = serverItemId
        }
        if value.kind == .chat && serverMessage.kind != .chat {
            value.kind = serverMessage.kind
        }
        if value.attachments.isEmpty && !serverMessage.attachments.isEmpty {
            value.attachments = serverMessage.attachments
        }

        if value.role == .assistant {
            let serverText = normalizedMessageText(serverMessage.text)
            if !serverText.isEmpty {
                value.text = preservesRunningPresentation
                    ? mergeStreamingSnapshotText(existingText: value.text, incomingText: serverMessage.text)
                    : serverMessage.text
            }
            value.isStreaming = preservesRunningPresentation
                ? (localMessage.isStreaming || serverMessage.isStreaming || runningThreadIDs.contains(localMessage.threadId))
                : false
        } else if value.role == .system {
            let serverText = normalizedMessageText(serverMessage.text)
            if !serverText.isEmpty {
                value.text = preservesRunningPresentation && localMessage.isStreaming
                    ? mergeStreamingSnapshotText(existingText: value.text, incomingText: serverMessage.text)
                    : serverMessage.text
            }
            value.isStreaming = preservesRunningPresentation
                ? (localMessage.isStreaming || serverMessage.isStreaming || runningThreadIDs.contains(localMessage.threadId))
                : false
        }

        return value
    }

    nonisolated static func historyMessageKey(for message: CodexMessage) -> String {
        if let itemId = message.itemId, !itemId.isEmpty {
            return "item:\(message.role.rawValue):\(message.kind.rawValue):\(itemId)"
        }

        return [
            message.role.rawValue,
            message.turnId ?? "no-turn",
            message.text,
            attachmentSignature(for: message.attachments),
        ].joined(separator: "|")
    }

    nonisolated static func normalizedMessageText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func normalizedHistoryIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func shouldReconcileToolActivityRow(
        _ localMessage: CodexMessage,
        with serverMessage: CodexMessage,
        requiresExactText: Bool
    ) -> Bool {
        let localItemId = normalizedHistoryIdentifier(localMessage.itemId)
        let serverItemId = normalizedHistoryIdentifier(serverMessage.itemId)
        if let localItemId, let serverItemId, localItemId == serverItemId {
            return true
        }

        let localHasStableIdentity = hasStableToolActivityIdentity(localItemId)
        let serverHasStableIdentity = hasStableToolActivityIdentity(serverItemId)
        if localHasStableIdentity && serverHasStableIdentity {
            return false
        }

        let localLines = normalizedToolActivityLines(from: localMessage.text)
        let serverLines = normalizedToolActivityLines(from: serverMessage.text)
        if localLines.isEmpty || serverLines.isEmpty {
            return !localHasStableIdentity || !serverHasStableIdentity
        }

        if localLines == serverLines {
            return true
        }

        guard !requiresExactText else {
            return false
        }

        return localLines.starts(with: serverLines) || serverLines.starts(with: localLines)
    }

    nonisolated static func hasStableToolActivityIdentity(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return !(value.hasPrefix("turn:") && value.contains("|kind:\(CodexMessageKind.toolActivity.rawValue)"))
    }

    // Treats only streaming/skeleton tool rows as safe to rebind by text alone.
    nonisolated static func isProvisionalToolActivityRow(_ message: CodexMessage) -> Bool {
        let itemId = normalizedHistoryIdentifier(message.itemId)
        guard !hasStableToolActivityIdentity(itemId) else {
            return false
        }

        return message.isStreaming || normalizedToolActivityLines(from: message.text).isEmpty
    }

    nonisolated static func normalizedToolActivityLines(from text: String) -> [String] {
        normalizedMessageText(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    // Merges a resume/history snapshot into the local streaming buffer without
    // losing already-rendered tokens when the server snapshot is slightly stale.
    nonisolated static func mergeStreamingSnapshotText(existingText: String, incomingText: String) -> String {
        if existingText.isEmpty {
            return incomingText
        }

        if incomingText == existingText {
            return existingText
        }

        if existingText.hasSuffix(incomingText) {
            return existingText
        }

        if incomingText.count > existingText.count, incomingText.hasPrefix(existingText) {
            return incomingText
        }

        if existingText.count > incomingText.count, existingText.hasPrefix(incomingText) {
            return existingText
        }

        let maxOverlap = min(existingText.count, incomingText.count)
        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                if existingText.suffix(overlap) == incomingText.prefix(overlap) {
                    return existingText + incomingText.dropFirst(overlap)
                }
            }
        }

        return incomingText
    }

    nonisolated static func attachmentSignature(for attachments: [CodexImageAttachment]) -> String {
        attachments
            .map { attachment in
                attachment.payloadDataURL ?? attachment.sourceURL ?? attachment.thumbnailBase64JPEG
            }
            .joined(separator: "|")
    }

    func normalizedItemType(_ rawType: String) -> String {
        rawType
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    nonisolated static func normalizedCommandExecutionPreviewKey(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let statusPrefixes: Set<String> = ["running", "completed", "failed", "stopped"]
        let tokens = trimmed
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else {
            return nil
        }

        let commandTokens: [String]
        if let first = tokens.first,
           statusPrefixes.contains(first.lowercased()) {
            commandTokens = Array(tokens.dropFirst())
        } else {
            commandTokens = tokens
        }

        guard !commandTokens.isEmpty else {
            return nil
        }

        let unquoted = commandTokens.map { token in
            token
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        .joined(separator: " ")

        let collapsedWhitespace = unquoted.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let normalized = collapsedWhitespace.lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    // Centralizes history-item -> CodexMessage mapping without changing ordering behavior.
    func appendHistoryMessage(
        to result: inout [CodexMessage],
        role: CodexMessageRole,
        kind: CodexMessageKind = .chat,
        text: String,
        threadId: String,
        turnId: String?,
        itemId: String?,
        createdAt: Date,
        attachments: [CodexImageAttachment] = [],
        planState: CodexPlanState? = nil,
        subagentAction: CodexSubagentAction? = nil
    ) {
        guard !text.isEmpty || !attachments.isEmpty || subagentAction != nil else {
            return
        }

        result.append(
            CodexMessage(
                threadId: threadId,
                role: role,
                kind: kind,
                text: text,
                createdAt: createdAt,
                turnId: turnId,
                itemId: itemId,
                isStreaming: false,
                deliveryState: .confirmed,
                attachments: attachments,
                planState: planState,
                subagentAction: subagentAction
            )
        )
    }

    // Parses `data:image/...;base64,...` payloads into raw image bytes.
    func decodeDataURIImageData(_ dataURI: String) -> Data? {
        guard let commaIndex = dataURI.firstIndex(of: ",") else {
            return nil
        }

        let metadata = dataURI[..<commaIndex].lowercased()
        guard metadata.hasPrefix("data:image"),
              metadata.contains(";base64") else {
            return nil
        }

        let payloadStart = dataURI.index(after: commaIndex)
        let base64Part = String(dataURI[payloadStart...])
        return Data(base64Encoded: base64Part)
    }

    // Produces the persisted 70x70 JPEG thumbnail preview used in message rows.
    func makeThumbnailBase64JPEG(from imageData: Data, side: CGFloat = 70) -> String? {
        guard let image = UIImage(data: imageData) else {
            return nil
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let rendered = renderer.image { _ in
            let sourceSize = image.size
            let scale = max(side / sourceSize.width, side / sourceSize.height)
            let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let origin = CGPoint(
                x: (side - scaledSize.width) / 2,
                y: (side - scaledSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }

        guard let jpegData = rendered.jpegData(compressionQuality: 0.8) else {
            return nil
        }

        return jpegData.base64EncodedString()
    }

    func decodeReasoningItemText(from itemObject: [String: JSONValue]) -> String {
        let summary = decodeHistoryStringParts(itemObject["summary"]).joined(separator: "\n")
        let content = decodeHistoryStringParts(itemObject["content"]).joined(separator: "\n\n")

        var sections: [String] = []
        if !summary.isEmpty {
            sections.append(summary)
        }
        if !content.isEmpty {
            sections.append(content)
        }

        if sections.isEmpty {
            return "Thinking..."
        }

        return sections.joined(separator: "\n\n")
    }

    func decodePlanItemText(from itemObject: [String: JSONValue]) -> String {
        let decodedText = decodeItemText(from: itemObject)
        if !decodedText.isEmpty {
            return decodedText
        }

        let summary = decodeHistoryStringParts(itemObject["summary"]).joined(separator: "\n")
        if !summary.isEmpty {
            return summary
        }

        return "Planning..."
    }

    func decodeHistoryPlanState(from itemObject: [String: JSONValue]) -> CodexPlanState? {
        let explanation = decodeHistoryNormalizedPlanText(itemObject["explanation"])
            ?? decodeHistoryNormalizedPlanText(itemObject["summary"])
        let steps = (itemObject["plan"]?.arrayValue ?? []).compactMap { stepValue -> CodexPlanStep? in
            guard let stepObject = stepValue.objectValue,
                  let step = decodeHistoryNormalizedPlanText(stepObject["step"]),
                  let rawStatus = decodeHistoryNormalizedPlanText(stepObject["status"]),
                  let status = CodexPlanStepStatus(rawValue: rawStatus) else {
                return nil
            }

            return CodexPlanStep(step: step, status: status)
        }

        guard explanation != nil || !steps.isEmpty else {
            return nil
        }

        return CodexPlanState(explanation: explanation, steps: steps)
    }

    // Parses collabAgentToolCall payloads into a stable summary row the timeline can render.
    func decodeSubagentActionItem(from itemObject: [String: JSONValue]) -> CodexSubagentAction? {
        ingestSubagentIdentityMetadata(from: itemObject)

        let receiverThreadIds = decodeSubagentReceiverThreadIDs(from: itemObject)
        let receiverAgents = decodeSubagentReceiverAgents(
            from: itemObject,
            fallbackThreadIds: receiverThreadIds
        )
        let agentStates = decodeSubagentAgentStates(from: itemObject)

        let rawTool = firstStringValue(in: itemObject, keys: ["tool", "name"])
        let tool = rawTool ?? inferToolFromEventType(itemObject) ?? "spawnAgent"
        let status = firstStringValue(in: itemObject, keys: ["status"]) ?? "in_progress"
        let prompt = firstStringValue(in: itemObject, keys: ["prompt", "task", "message"])
        let model = normalizedIdentifier(
            firstStringValue(
                in: itemObject,
                keys: ["model", "modelName", "model_name", "requestedModel", "requested_model"]
            )
        )

        guard !receiverThreadIds.isEmpty
            || !receiverAgents.isEmpty
            || !agentStates.isEmpty
            || prompt != nil
            || model != nil else {
            return nil
        }

        return CodexSubagentAction(
            tool: tool,
            status: status,
            prompt: prompt,
            model: model,
            receiverThreadIds: receiverThreadIds,
            receiverAgents: receiverAgents,
            agentStates: agentStates
        )
    }

    private func ingestSubagentIdentityMetadata(from itemObject: [String: JSONValue]) {
        func upsertIdentity(threadId: String?, agentId: String?, nickname: String?, role: String?) {
            upsertSubagentIdentity(
                threadId: threadId,
                agentId: agentId,
                nickname: nickname,
                role: role
            )
        }

        let extracted = extractSubagentIdentity(from: itemObject)
        upsertIdentity(
            threadId: extracted.threadId,
            agentId: extracted.agentId,
            nickname: extracted.nickname,
            role: extracted.role
        )

        upsertIdentity(
            threadId: firstStringValue(in: itemObject, keys: ["newThreadId", "new_thread_id"]),
            agentId: firstStringValue(in: itemObject, keys: ["newAgentId", "new_agent_id"]),
            nickname: firstStringValue(in: itemObject, keys: ["newAgentNickname", "new_agent_nickname"]),
            role: firstStringValue(in: itemObject, keys: ["newAgentRole", "new_agent_role"])
        )

        upsertIdentity(
            threadId: firstStringValue(in: itemObject, keys: ["receiverThreadId", "receiver_thread_id"]),
            agentId: firstStringValue(in: itemObject, keys: ["receiverAgentId", "receiver_agent_id"]),
            nickname: firstStringValue(in: itemObject, keys: ["receiverAgentNickname", "receiver_agent_nickname"]),
            role: firstStringValue(in: itemObject, keys: ["receiverAgentRole", "receiver_agent_role"])
        )

        let receiverThreadIds = decodeSubagentReceiverThreadIDs(from: itemObject)
        let receiverAgents = decodeSubagentReceiverAgents(from: itemObject, fallbackThreadIds: receiverThreadIds)
        for agent in receiverAgents {
            upsertIdentity(
                threadId: agent.threadId,
                agentId: agent.agentId,
                nickname: agent.nickname,
                role: agent.role
            )
        }

        if let statuses = firstValue(forAnyKey: ["statuses"], in: .object(itemObject))?.objectValue {
            for (threadId, rawStatus) in statuses {
                guard let statusObject = rawStatus.objectValue else { continue }
                upsertIdentity(
                    threadId: threadId,
                    agentId: firstStringValue(in: statusObject, keys: ["agentId", "agent_id"]),
                    nickname: firstStringValue(
                        in: statusObject,
                        keys: ["agentNickname", "agent_nickname", "receiverAgentNickname", "receiver_agent_nickname"]
                    ),
                    role: firstStringValue(
                        in: statusObject,
                        keys: ["agentRole", "agent_role", "receiverAgentRole", "receiver_agent_role", "agentType", "agent_type"]
                    )
                )
            }
        }

        if let statusEntries = firstValue(forAnyKey: ["agentStatuses", "agent_statuses"], in: .object(itemObject))?.arrayValue {
            for rawEntry in statusEntries {
                guard let entry = rawEntry.objectValue else { continue }
                upsertIdentity(
                    threadId: firstStringValue(in: entry, keys: ["threadId", "thread_id", "receiverThreadId", "receiver_thread_id"]),
                    agentId: firstStringValue(in: entry, keys: ["agentId", "agent_id"]),
                    nickname: firstStringValue(
                        in: entry,
                        keys: ["agentNickname", "agent_nickname", "receiverAgentNickname", "receiver_agent_nickname"]
                    ),
                    role: firstStringValue(
                        in: entry,
                        keys: ["agentRole", "agent_role", "receiverAgentRole", "receiver_agent_role", "agentType", "agent_type"]
                    )
                )
            }
        }
    }

    private func extractSubagentIdentity(from object: [String: JSONValue]) -> CodexSubagentIdentityEntry {
        let sourceObject = object["source"]?.objectValue
        let subAgentObject = sourceObject?["subAgent"]?.objectValue ?? sourceObject?["sub_agent"]?.objectValue
        let threadSpawnObject = subAgentObject?["thread_spawn"]?.objectValue ?? subAgentObject?["threadSpawn"]?.objectValue

        return CodexSubagentIdentityEntry(
            threadId: normalizedIdentifier(
                firstStringValue(
                    in: object,
                    keys: ["threadId", "thread_id", "conversationId", "conversation_id", "receiverThreadId", "receiver_thread_id"]
                )
            ) ?? normalizedIdentifier(firstStringValue(in: threadSpawnObject, keys: ["threadId", "thread_id"])),
            agentId: normalizedIdentifier(firstStringValue(in: object, keys: ["agentId", "agent_id", "id"]))
                ?? normalizedIdentifier(firstStringValue(in: threadSpawnObject, keys: ["agentId", "agent_id", "id"]))
                ?? normalizedIdentifier(firstStringValue(in: subAgentObject, keys: ["agentId", "agent_id", "id"])),
            nickname: normalizedIdentifier(
                firstStringValue(in: object, keys: ["agentNickname", "agent_nickname", "nickname"])
            ) ?? normalizedIdentifier(firstStringValue(in: threadSpawnObject, keys: ["agentNickname", "agent_nickname", "nickname", "name"]))
                ?? normalizedIdentifier(firstStringValue(in: subAgentObject, keys: ["agentNickname", "agent_nickname", "nickname", "name"])),
            role: normalizedIdentifier(
                firstStringValue(in: object, keys: ["agentRole", "agent_role", "agentType", "agent_type"])
            ) ?? normalizedIdentifier(firstStringValue(in: threadSpawnObject, keys: ["agentRole", "agent_role", "agentType", "agent_type"]))
                ?? normalizedIdentifier(firstStringValue(in: subAgentObject, keys: ["agentRole", "agent_role", "agentType", "agent_type"]))
        )
    }

    // Infers the collab tool type from the event's `type` field when `tool` is missing.
    private func inferToolFromEventType(_ itemObject: [String: JSONValue]) -> String? {
        guard let rawType = firstStringValue(in: itemObject, keys: ["type"]) else { return nil }
        let normalized = rawType.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        if normalized.contains("spawn") { return "spawnAgent" }
        if normalized.contains("waiting") || normalized.contains("wait") { return "wait" }
        if normalized.contains("close") { return "closeAgent" }
        if normalized.contains("resume") { return "resumeAgent" }
        if normalized.contains("sendinput") || normalized.contains("interaction") { return "sendInput" }
        return nil
    }

    private func decodeHistoryNormalizedPlanText(_ value: JSONValue?) -> String? {
        let flattened = decodeHistoryStringParts(value).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else {
            return nil
        }
        return flattened
    }

    private func decodeSubagentReceiverThreadIDs(from itemObject: [String: JSONValue]) -> [String] {
        // Try plural array first.
        let candidate = firstValue(
            forAnyKey: ["receiverThreadIds", "receiver_thread_ids", "threadIds", "thread_ids"],
            in: .object(itemObject)
        )
        if let values = candidate?.arrayValue {
            var threadIds: [String] = []
            for value in values {
                if let threadId = normalizedIdentifier(value.stringValue),
                   !threadIds.contains(threadId) {
                    threadIds.append(threadId)
                }
            }
            if !threadIds.isEmpty { return threadIds }
        }

        // Fallback: singular top-level field (Codex CLI sends one event per agent).
        if let singularId = normalizedIdentifier(
            firstStringValue(
                in: itemObject,
                keys: [
                    "receiverThreadId", "receiver_thread_id",
                    "threadId", "thread_id",
                    "newThreadId", "new_thread_id",
                ]
            )
        ) {
            return [singularId]
        }

        return []
    }

    private func decodeSubagentReceiverAgents(
        from itemObject: [String: JSONValue],
        fallbackThreadIds: [String]
    ) -> [CodexSubagentRef] {
        let candidate = firstValue(
            forAnyKey: ["receiverAgents", "receiver_agents", "agents"],
            in: .object(itemObject)
        )
        if candidate?.arrayValue == nil || candidate?.arrayValue?.isEmpty == true {
            // Codex CLI sends singular top-level identity fields per event.
            return buildSyntheticAgentRefs(from: itemObject, fallbackThreadIds: fallbackThreadIds)
        }
        let values = candidate!.arrayValue!

        return values.enumerated().compactMap { index, value in
            guard let object = value.objectValue else { return nil }

            let fallbackThreadId = index < fallbackThreadIds.count ? fallbackThreadIds[index] : nil
            let threadId = normalizedIdentifier(
                firstStringValue(
                    in: object,
                    keys: [
                        "threadId", "thread_id",
                        "receiverThreadId", "receiver_thread_id",
                        "newThreadId", "new_thread_id",
                    ]
                ) ?? fallbackThreadId
            )
            guard let threadId else { return nil }

            return CodexSubagentRef(
                threadId: threadId,
                agentId: normalizedIdentifier(
                    firstStringValue(
                        in: object,
                        keys: [
                            "agentId", "agent_id",
                            "receiverAgentId", "receiver_agent_id",
                            "newAgentId", "new_agent_id",
                            "id",
                        ]
                    )
                ),
                nickname: normalizedIdentifier(
                    firstStringValue(
                        in: object,
                        keys: [
                            "agentNickname", "agent_nickname",
                            "receiverAgentNickname", "receiver_agent_nickname",
                            "newAgentNickname", "new_agent_nickname",
                            "nickname", "name",
                        ]
                    )
                ),
                role: normalizedIdentifier(
                    firstStringValue(
                        in: object,
                        keys: [
                            "agentRole", "agent_role",
                            "receiverAgentRole", "receiver_agent_role",
                            "newAgentRole", "new_agent_role",
                            "agentType", "agent_type",
                        ]
                    )
                ),
                model: normalizedIdentifier(
                    firstStringValue(
                        in: object,
                        keys: [
                            "modelProvider", "model_provider",
                            "modelProviderId", "model_provider_id",
                            "modelName", "model_name",
                            "model",
                        ]
                    )
                ),
                prompt: normalizedIdentifier(
                    firstStringValue(
                        in: object,
                        keys: ["prompt", "instructions", "instruction", "task", "message"]
                    )
                )
            )
        }
    }

    private func decodeSubagentAgentStates(from itemObject: [String: JSONValue]) -> [String: CodexSubagentState] {
        let candidate = firstValue(
            forAnyKey: ["statuses", "agentsStates", "agents_states", "agentStates", "agent_states"],
            in: .object(itemObject)
        )

        if let object = candidate?.objectValue {
            var decoded: [String: CodexSubagentState] = [:]
            for (rawThreadId, value) in object {
                let stateObject = value.objectValue
                let threadId = normalizedIdentifier(rawThreadId)
                    ?? normalizedIdentifier(firstStringValue(in: stateObject, keys: ["threadId", "thread_id"]))
                guard let threadId else { continue }

                decoded[threadId] = CodexSubagentState(
                    threadId: threadId,
                    status: firstStringValue(in: stateObject, keys: ["status"]) ?? "unknown",
                    message: firstStringValue(in: stateObject, keys: ["message", "text", "delta", "summary"])
                )
            }
            return decoded
        }

        if let values = candidate?.arrayValue {
            var decoded: [String: CodexSubagentState] = [:]
            for value in values {
                guard let object = value.objectValue,
                      let threadId = normalizedIdentifier(firstStringValue(in: object, keys: ["threadId", "thread_id"])) else {
                    continue
                }

                decoded[threadId] = CodexSubagentState(
                    threadId: threadId,
                    status: firstStringValue(in: object, keys: ["status"]) ?? "unknown",
                    message: firstStringValue(in: object, keys: ["message", "text", "delta", "summary"])
                )
            }
            return decoded
        }

        return [:]
    }

    // Builds a single-element agent ref array from top-level fields when the Codex CLI sends
    // one event per agent with singular fields (new_agent_nickname, receiver_thread_id, etc.)
    // instead of a nested receiverAgents array.
    private func buildSyntheticAgentRefs(
        from itemObject: [String: JSONValue],
        fallbackThreadIds: [String]
    ) -> [CodexSubagentRef] {
        guard let threadId = fallbackThreadIds.first
            ?? normalizedIdentifier(
                firstStringValue(
                    in: itemObject,
                    keys: [
                        "receiverThreadId", "receiver_thread_id",
                        "threadId", "thread_id",
                        "newThreadId", "new_thread_id",
                    ]
                )
            ) else {
            return []
        }

        let nickname = normalizedIdentifier(
            firstStringValue(
                in: itemObject,
                keys: [
                    "newAgentNickname", "new_agent_nickname",
                    "agentNickname", "agent_nickname",
                    "receiverAgentNickname", "receiver_agent_nickname",
                ]
            )
        )
        let role = normalizedIdentifier(
            firstStringValue(
                in: itemObject,
                keys: [
                    "receiverAgentRole", "receiver_agent_role",
                    "newAgentRole", "new_agent_role",
                    "agentRole", "agent_role",
                    "agentType", "agent_type",
                ]
            )
        )
        let agentId = normalizedIdentifier(
            firstStringValue(
                in: itemObject,
                keys: [
                    "newAgentId", "new_agent_id",
                    "agentId", "agent_id",
                ]
            )
        )
        let model = normalizedIdentifier(
            firstStringValue(
                in: itemObject,
                keys: [
                    "modelProvider", "model_provider",
                    "modelProviderId", "model_provider_id",
                    "modelName", "model_name",
                    "model",
                ]
            )
        )
        let prompt = normalizedIdentifier(
            firstStringValue(
                in: itemObject,
                keys: ["prompt", "instructions", "instruction", "task", "message"]
            )
        )

        return [CodexSubagentRef(
            threadId: threadId,
            agentId: agentId,
            nickname: nickname,
            role: role,
            model: model,
            prompt: prompt
        )]
    }

    func decodeCommandExecutionItemText(from itemObject: [String: JSONValue]) -> String {
        let status = decodeHistoryNestedStatus(from: itemObject) ?? "completed"
        let phase = normalizedHistoryCommandPhase(status)
        let command = decodeHistoryFirstString(
            forAnyKey: ["command", "cmd", "raw_command", "rawCommand", "input", "invocation"],
            in: .object(itemObject)
        ) ?? "command"
        return "\(phase) \(shortHistoryCommand(command))"
    }

    func normalizedHistoryCommandPhase(_ rawStatus: String) -> String {
        let normalized = rawStatus
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.contains("fail") || normalized.contains("error") {
            return "failed"
        }
        if normalized.contains("cancel") || normalized.contains("abort") || normalized.contains("interrupt") {
            return "stopped"
        }
        if normalized.contains("complete") || normalized.contains("success") || normalized.contains("done") {
            return "completed"
        }
        return "running"
    }

    func shortHistoryCommand(_ rawCommand: String, maxLength: Int = 92) -> String {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "command" }

        let collapsedWhitespace = trimmed.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let unwrapped = unwrapHistoryShellCommandIfPresent(collapsedWhitespace)
        let normalized = unwrapped.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let tokens = normalized
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return "command" }

        let preview = tokens.joined(separator: " ")
        if preview.count <= maxLength {
            return preview
        }
        let cutoffIndex = preview.index(preview.startIndex, offsetBy: maxLength - 1)
        return String(preview[..<cutoffIndex]) + "…"
    }

    private func unwrapHistoryShellCommandIfPresent(_ command: String) -> String {
        let tokens = command
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !tokens.isEmpty else { return command }

        let shellNames = ["bash", "zsh", "sh", "fish"]
        var shellIndex = 0

        if tokens.count >= 2 {
            let first = tokens[0].lowercased()
            let second = tokens[1].lowercased()
            if (first == "env" || first.hasSuffix("/env")),
               shellNames.contains(where: { second == $0 || second.hasSuffix("/\($0)") }) {
                shellIndex = 1
            }
        }

        let shell = tokens[shellIndex].lowercased()
        guard shellNames.contains(where: { shell == $0 || shell.hasSuffix("/\($0)") }) else {
            return command
        }

        var index = shellIndex + 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "-c" || token == "-lc" || token == "-cl" || token == "-ic" || token == "-ci" {
                index += 1
                guard index < tokens.count else { return command }
                return stripHistoryWrappingQuotes(from: tokens[index...].joined(separator: " "))
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            return stripHistoryWrappingQuotes(from: tokens[index...].joined(separator: " "))
        }

        return command
    }

    private func stripHistoryWrappingQuotes(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }

        if (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
            || (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    func decodeFileChangeItemText(from itemObject: [String: JSONValue]) -> String {
        let status = itemObject["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStatus = (status?.isEmpty == false) ? status! : "completed"

        var sections: [String] = ["Status: \(normalizedStatus)"]
        let changes = decodeHistoryFileChangeEntries(from: itemObject["changes"])
        let renderedChanges = changes.map { entry -> String in
            var body = "Path: \(entry.path)\nKind: \(entry.kind)"
            if let totals = entry.inlineTotals {
                body += "\nTotals: +\(totals.additions) -\(totals.deletions)"
            }
            if !entry.diff.isEmpty {
                body += "\n\n```diff\n\(entry.diff)\n```"
            }
            return body
        }

        if !renderedChanges.isEmpty {
            sections.append(renderedChanges.joined(separator: "\n\n---\n\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    // Splits history tool items into dedicated file-change rows or compact generic activity rows.
    func decodeHistoryToolCallItem(from itemObject: [String: JSONValue]) -> (kind: CodexMessageKind, text: String)? {
        if let fileChangeText = decodeHistoryToolCallFileChangeText(from: itemObject) {
            return (.fileChange, fileChangeText)
        }
        if let activityText = decodeHistoryToolActivityText(from: itemObject) {
            return (.toolActivity, activityText)
        }
        return nil
    }

    func decodeHistoryDiffItemText(from itemObject: [String: JSONValue]) -> String? {
        decodeHistoryToolCallFileChangeText(from: itemObject)
    }

    func decodeHistoryToolCallFileChangeText(from itemObject: [String: JSONValue]) -> String? {
        let status = decodeHistoryNestedStatus(from: itemObject) ?? "completed"

        var synthetic = itemObject
        if synthetic["status"] == nil {
            synthetic["status"] = .string(status)
        }

        if synthetic["changes"] == nil,
           let extractedChanges = decodeHistoryFirstValue(
               forAnyKey: [
                   "changes",
                   "file_changes",
                   "fileChanges",
                   "files",
                   "edits",
                   "modified_files",
                   "modifiedFiles",
                   "patches",
               ],
               in: .object(itemObject)
           ) {
            synthetic["changes"] = extractedChanges
        }

        let fileEntries = decodeHistoryFileChangeEntries(from: synthetic["changes"])
        if !fileEntries.isEmpty {
            return decodeFileChangeItemText(from: synthetic)
        }

        if let diff = decodeHistoryFirstString(
            forAnyKey: ["diff", "unified_diff", "unifiedDiff", "patch"],
            in: .object(itemObject)
        ) {
            let trimmedDiff = diff.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDiff.isEmpty {
                return "Status: \(status)\n\n```diff\n\(trimmedDiff)\n```"
            }
        }

        return nil
    }

    func decodeHistoryToolActivityText(from itemObject: [String: JSONValue]) -> String? {
        if let output = decodeHistoryFirstString(
            forAnyKey: [
                "text",
                "message",
                "summary",
                "stdout",
                "stderr",
                "output_text",
                "outputText",
            ],
            in: .object(itemObject)
        ) {
            let lines = output
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 140 }
            let acceptedPrefixes = [
                "running ",
                "read ",
                "search ",
                "searched ",
                "exploring ",
                "list ",
                "listing ",
                "open ",
                "opened ",
                "find ",
                "finding ",
                "edit ",
                "edited ",
                "write ",
                "wrote ",
                "apply ",
                "applied ",
            ]
            let activityLines = lines.filter { line in
                let lower = line.lowercased()
                return acceptedPrefixes.contains { lower.hasPrefix($0) }
            }
            if !activityLines.isEmpty {
                return activityLines.joined(separator: "\n")
            }
        }

        let nestedTool = itemObject["tool"]?.objectValue
        let nestedCall = itemObject["call"]?.objectValue
        let descriptor = firstNonEmptyString([
            itemObject["kind"]?.stringValue,
            itemObject["name"]?.stringValue,
            itemObject["tool"]?.stringValue,
            itemObject["tool_name"]?.stringValue,
            itemObject["toolName"]?.stringValue,
            itemObject["title"]?.stringValue,
            nestedTool?["kind"]?.stringValue,
            nestedTool?["name"]?.stringValue,
            nestedTool?["type"]?.stringValue,
            nestedTool?["title"]?.stringValue,
            nestedCall?["kind"]?.stringValue,
            nestedCall?["name"]?.stringValue,
            nestedCall?["type"]?.stringValue,
            nestedCall?["title"]?.stringValue,
        ])
        let summary = toolActivitySummaryLine(
            descriptor: descriptor,
            rawStatus: decodeHistoryNestedStatus(from: itemObject),
            isCompleted: true
        )
        return summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary
    }

    func decodeHistoryFileChangeEntries(
        from rawChanges: JSONValue?
    ) -> [(path: String, kind: String, diff: String, inlineTotals: (additions: Int, deletions: Int)?)] {
        var changeObjects: [[String: JSONValue]] = []

        if let array = rawChanges?.arrayValue {
            for value in array {
                if let object = value.objectValue {
                    changeObjects.append(object)
                }
            }
        } else if let objectMap = rawChanges?.objectValue {
            for key in objectMap.keys.sorted() {
                guard var object = objectMap[key]?.objectValue else { continue }
                if object["path"] == nil {
                    object["path"] = .string(key)
                }
                changeObjects.append(object)
            }
        }

        return changeObjects.map { changeObject in
            let path = decodeHistoryChangePath(from: changeObject)
            let kind = decodeHistoryChangeKind(from: changeObject)
            var diff = decodeHistoryChangeDiff(from: changeObject)
            let totals = decodeHistoryChangeInlineTotals(from: changeObject)
            if diff.isEmpty,
               let content = changeObject["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty {
                diff = synthesizeHistoryUnifiedDiffFromContent(content, kind: kind, path: path)
            }
            return (path: path, kind: kind, diff: diff, inlineTotals: totals)
        }
    }

    func decodeHistoryChangePath(from changeObject: [String: JSONValue]) -> String {
        let candidates = [
            changeObject["path"]?.stringValue,
            changeObject["file"]?.stringValue,
            changeObject["file_path"]?.stringValue,
            changeObject["filePath"]?.stringValue,
            changeObject["relative_path"]?.stringValue,
            changeObject["relativePath"]?.stringValue,
            changeObject["new_path"]?.stringValue,
            changeObject["newPath"]?.stringValue,
            changeObject["to"]?.stringValue,
            changeObject["target"]?.stringValue,
            changeObject["name"]?.stringValue,
            changeObject["old_path"]?.stringValue,
            changeObject["oldPath"]?.stringValue,
            changeObject["from"]?.stringValue,
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return "unknown"
    }

    func decodeHistoryChangeKind(from changeObject: [String: JSONValue]) -> String {
        if let kindString = changeObject["kind"]?.stringValue,
           !kindString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return kindString
        }
        if let actionString = changeObject["action"]?.stringValue,
           !actionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return actionString
        }
        if let kindType = changeObject["kind"]?.objectValue?["type"]?.stringValue,
           !kindType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return kindType
        }
        if let typeString = changeObject["type"]?.stringValue,
           !typeString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return typeString
        }
        return "update"
    }

    func decodeHistoryChangeDiff(from changeObject: [String: JSONValue]) -> String {
        let diff = changeObject["diff"]?.stringValue
            ?? changeObject["unified_diff"]?.stringValue
            ?? changeObject["unifiedDiff"]?.stringValue
            ?? changeObject["patch"]?.stringValue
            ?? changeObject["delta"]?.stringValue
            ?? ""
        return diff.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func decodeHistoryChangeInlineTotals(
        from changeObject: [String: JSONValue]
    ) -> (additions: Int, deletions: Int)? {
        let additions = decodeHistoryNumericField(
            from: changeObject,
            keys: [
                "additions",
                "lines_added",
                "line_additions",
                "lineAdditions",
                "added",
                "insertions",
                "inserted",
                "num_added",
            ]
        ) ?? 0
        let deletions = decodeHistoryNumericField(
            from: changeObject,
            keys: [
                "deletions",
                "lines_deleted",
                "line_deletions",
                "lineDeletions",
                "removed",
                "deleted",
                "num_deleted",
                "num_removed",
            ]
        ) ?? 0

        guard additions > 0 || deletions > 0 else { return nil }
        return (additions: additions, deletions: deletions)
    }

    func decodeHistoryNumericField(
        from object: [String: JSONValue],
        keys: [String]
    ) -> Int? {
        for key in keys {
            if let intValue = object[key]?.intValue {
                return intValue
            }
            if let doubleValue = object[key]?.doubleValue {
                return Int(doubleValue)
            }
            if let stringValue = object[key]?.stringValue,
               let parsed = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    func synthesizeHistoryUnifiedDiffFromContent(
        _ content: String,
        kind: String,
        path: String
    ) -> String {
        let normalizedKind = kind.lowercased()
        let contentLines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if normalizedKind.contains("add") || normalizedKind.contains("create") {
            var lines: [String] = [
                "diff --git a/\(path) b/\(path)",
                "new file mode 100644",
                "--- /dev/null",
                "+++ b/\(path)",
            ]
            lines.append(contentsOf: contentLines.map { "+\($0)" })
            return lines.joined(separator: "\n")
        }

        if normalizedKind.contains("delete") || normalizedKind.contains("remove") {
            var lines: [String] = [
                "diff --git a/\(path) b/\(path)",
                "deleted file mode 100644",
                "--- a/\(path)",
                "+++ /dev/null",
            ]
            lines.append(contentsOf: contentLines.map { "-\($0)" })
            return lines.joined(separator: "\n")
        }

        return ""
    }

    func decodeHistoryNestedStatus(from itemObject: [String: JSONValue]) -> String? {
        decodeHistoryFirstString(
            forAnyKey: ["status"],
            in: .object(itemObject)
        )
    }

    func decodeHistoryFirstString(
        forAnyKey keys: [String],
        in root: JSONValue,
        maxDepth: Int = 8
    ) -> String? {
        for key in keys {
            if let value = decodeHistoryFirstValue(forKey: key, in: root, maxDepth: maxDepth) {
                if let text = value.stringValue {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }

                if let flattened = decodeHistoryFlattenText(from: value, maxDepth: maxDepth),
                   !flattened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return flattened.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    func decodeHistoryFirstValue(
        forAnyKey keys: [String],
        in root: JSONValue,
        maxDepth: Int = 8
    ) -> JSONValue? {
        for key in keys {
            if let value = decodeHistoryFirstValue(forKey: key, in: root, maxDepth: maxDepth) {
                return value
            }
        }
        return nil
    }

    func decodeHistoryFirstValue(
        forKey key: String,
        in root: JSONValue,
        maxDepth: Int = 8
    ) -> JSONValue? {
        guard maxDepth >= 0 else { return nil }

        switch root {
        case .object(let object):
            if let value = object[key], !decodeHistoryIsEmptyJSONValue(value) {
                return value
            }
            for value in object.values {
                if let match = decodeHistoryFirstValue(forKey: key, in: value, maxDepth: maxDepth - 1) {
                    return match
                }
            }
        case .array(let array):
            for value in array {
                if let match = decodeHistoryFirstValue(forKey: key, in: value, maxDepth: maxDepth - 1) {
                    return match
                }
            }
        default:
            break
        }
        return nil
    }

    func decodeHistoryFlattenText(from root: JSONValue, maxDepth: Int = 8) -> String? {
        guard maxDepth >= 0 else { return nil }
        switch root {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .array(let values):
            let parts = values.compactMap { decodeHistoryFlattenText(from: $0, maxDepth: maxDepth - 1) }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: "\n")
        case .object(let object):
            let preferredKeys = ["text", "message", "summary", "output_text", "outputText", "content", "output"]
            for key in preferredKeys {
                if let value = object[key],
                   let preferred = decodeHistoryFlattenText(from: value, maxDepth: maxDepth - 1) {
                    return preferred
                }
            }
            for value in object.values {
                if let nested = decodeHistoryFlattenText(from: value, maxDepth: maxDepth - 1) {
                    return nested
                }
            }
            return nil
        default:
            return nil
        }
    }

    func decodeHistoryIsEmptyJSONValue(_ value: JSONValue) -> Bool {
        switch value {
        case .null:
            return true
        case .string(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let values):
            return values.isEmpty
        case .object(let object):
            return object.isEmpty
        default:
            return false
        }
    }

    func decodeHistoryStringParts(_ value: JSONValue?) -> [String] {
        guard let value else { return [] }

        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case .array(let values):
            return values.compactMap { candidate in
                if let text = candidate.stringValue {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }

                if let object = candidate.objectValue,
                   let text = object["text"]?.stringValue {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }

                return nil
            }
        case .object(let object):
            if let text = object["text"]?.stringValue {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [trimmed]
            }
            return []
        default:
            return []
        }
    }
}
