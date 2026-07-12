// FILE: CodexService+History.swift
// Purpose: Parses thread/read history payloads into normalized timeline messages.
// Layer: Service
// Exports: CodexService history parsing helpers
// Depends on: CodexMessage, CryptoKit, JSONValue

import CryptoKit
import Foundation
import UIKit

fileprivate struct UserMessageSemanticKey: Equatable {
    let text: String
    let skillMentions: Set<String>
    let pluginMentions: Set<String>

    var hasMentions: Bool {
        !skillMentions.isEmpty || !pluginMentions.isEmpty
    }
}

fileprivate struct CanonicalAssistantTurnKey: Hashable {
    let threadId: String
    let turnId: String
}

fileprivate struct CanonicalAssistantSourceKey: Hashable {
    let threadId: String
    let turnId: String
    let sourceItemKey: String
    let text: String
}

fileprivate struct CanonicalAssistantTurnTextKey: Hashable {
    let threadId: String
    let turnId: String
    let text: String
}

extension CodexService {
    nonisolated static func shouldPreferRecentHistoryWindow(
        existingCount: Int,
        historyCount: Int,
        windowSize: Int = 160
    ) -> Bool {
        let normalizedWindowSize = max(1, windowSize)
        guard existingCount > normalizedWindowSize,
              historyCount > normalizedWindowSize else {
            return false
        }

        // Only trust the local prefix when it is already deep enough to cover the
        // server prefix we are about to skip. Otherwise fall back to canonical merge.
        return existingCount >= (historyCount - normalizedWindowSize)
    }

    // Runs history reconciliation off the main actor and cancels the worker if the caller goes away.
    func mergeHistoryMessagesOffMainActor(
        existing: [CodexMessage],
        history: [CodexMessage],
        activeThreadIDs: Set<String>,
        activeTurnIDs: Set<String>,
        runningThreadIDs: Set<String>,
        preferRecentWindow: Bool
    ) async throws -> [CodexMessage] {
        let mergeTask = Task.detached(priority: .userInitiated) { () throws -> [CodexMessage] in
            if preferRecentWindow {
                return try Self.mergeRecentHistoryWindow(
                    existing,
                    history,
                    activeThreadIDs: activeThreadIDs,
                    activeTurnIDs: activeTurnIDs,
                    runningThreadIDs: runningThreadIDs,
                    windowSize: 160
                )
            }

            return try Self.mergeHistoryMessages(
                existing,
                history,
                activeThreadIDs: activeThreadIDs,
                activeTurnIDs: activeTurnIDs,
                runningThreadIDs: runningThreadIDs
            )
        }

        return try await withTaskCancellationHandler {
            try await mergeTask.value
        } onCancel: {
            mergeTask.cancel()
        }
    }

    // Decodes app-server turn arrays into a chronological message timeline.
    func decodeMessagesFromThreadRead(threadId: String, threadObject: [String: JSONValue]) -> [CodexMessage] {
        let baseDate = decodeHistoryBaseDate(from: threadObject, threadId: threadId)
        let threadTimeZoneIdentifier = decodeHistoryTimeZoneIdentifier(from: threadObject)
        let turns = threadObject["turns"]?.arrayValue ?? []

        var offset: TimeInterval = 0
        var result: [CodexMessage] = []

        for turnValue in turns {
            guard let turnObject = turnValue.objectValue else { continue }
            let turnID = historyTurnID(from: turnObject)
            let turnTimestamp = decodeHistoryTimestamp(from: turnObject)
            let turnTimeZoneIdentifier = decodeHistoryTimeZoneIdentifier(from: turnObject)
                ?? threadTimeZoneIdentifier
            let turnCompleted = historyTurnTerminalState(turnObject) == .completed
            let items = turnObject["items"]?.arrayValue ?? []

            for itemValue in items {
                guard let itemObject = itemValue.objectValue,
                      let itemType = itemObject["type"]?.stringValue else {
                    continue
                }

                let syntheticTimestamp = (turnTimestamp ?? baseDate).addingTimeInterval(offset)
                let timestamp = decodeHistoryTimestamp(from: itemObject) ?? syntheticTimestamp
                let timeZoneIdentifier = decodeHistoryTimeZoneIdentifier(from: itemObject)
                    ?? turnTimeZoneIdentifier
                offset += 0.001
                let itemID = itemObject["id"]?.stringValue
                let sourceItemKey = itemObject["remodexSourceItemKey"]?.stringValue
                let decodedText = decodeItemText(from: itemObject)
                let skillMentions = decodeHistorySkillMentions(from: itemObject)
                let pluginMentions = decodeHistoryPluginMentions(from: itemObject)
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
                        sourceItemKey: sourceItemKey,
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier,
                        skillMentions: skillMentions,
                        pluginMentions: pluginMentions,
                        attachments: imageAttachments
                    )

                case "agentmessage", "assistantmessage":
                    appendHistoryMessage(
                        to: &result,
                        role: .assistant,
                        kind: .chat,
                        assistantPhase: normalizedAssistantPhase(itemObject["phase"]?.stringValue),
                        text: decodedText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        sourceItemKey: sourceItemKey,
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier,
                        attachments: imageAttachments
                    )

                case "message":
                    let role = itemObject["role"]?.stringValue?.lowercased() ?? ""
                    let mappedRole: CodexMessageRole = role.contains("user") ? .user : .assistant

                    appendHistoryMessage(
                        to: &result,
                        role: mappedRole,
                        kind: .chat,
                        assistantPhase: mappedRole == .assistant
                            ? normalizedAssistantPhase(itemObject["phase"]?.stringValue)
                            : nil,
                        text: decodedText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        sourceItemKey: sourceItemKey,
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier,
                        skillMentions: mappedRole == .user ? skillMentions : [],
                        pluginMentions: mappedRole == .user ? pluginMentions : [],
                        attachments: imageAttachments
                    )

                case "imagegeneration", "imagegenerationcall", "imagegenerationend", "imageview":
                    guard let generatedImageText = decodeGeneratedImageMarkdown(from: itemObject) else {
                        continue
                    }
                    appendHistoryMessage(
                        to: &result,
                        role: .assistant,
                        kind: .chat,
                        text: generatedImageText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier
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
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier
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
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier
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
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier
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
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier
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
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier
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
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier
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
                        assistantPhase: normalizedAssistantPhase(itemObject["phase"]?.stringValue),
                        text: reviewText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier
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
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier
                    )

                case "plan", "todolist":
                    let decodedPlanState = decodePlanState(from: itemObject)
                    let decodedPlanText = decodePlanItemText(from: itemObject)
                    guard CodexPlanUpdateVisibilityPolicy.shouldApply(
                        text: decodedPlanText,
                        planState: decodedPlanState
                    ) else {
                        continue
                    }
                    let isProgressPlan = CodexPlanItemPresentationPolicy.isProgressItem(itemObject)
                    appendHistoryMessage(
                        to: &result,
                        role: .system,
                        kind: .plan,
                        text: decodedPlanText,
                        threadId: threadId,
                        turnId: turnID,
                        itemId: itemID,
                        createdAt: timestamp,
                        timeZoneIdentifier: timeZoneIdentifier,
                        planState: finalizedHistoryPlanState(decodedPlanState, turnCompleted: turnCompleted),
                        planPresentation: isProgressPlan || itemID == nil
                            ? .progress
                            : (turnCompleted ? .resultReady : .resultClosed)
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
                        timeZoneIdentifier: timeZoneIdentifier,
                        subagentAction: subagentAction
                    )

                default:
                    continue
                }
            }
        }

        return Self.historyMessagesMergingGeneratedImageArtifacts(result)
    }

    // Extracts persisted turn outcomes from canonical history so render grouping survives app relaunch.
    func decodeTurnTerminalStatesFromThreadRead(_ threadObject: [String: JSONValue]) -> [String: CodexTurnTerminalState] {
        let turns = threadObject["turns"]?.arrayValue ?? []
        var result: [String: CodexTurnTerminalState] = [:]

        for turnValue in turns {
            guard let turnObject = turnValue.objectValue,
                  let turnID = historyTurnID(from: turnObject),
                  !turnID.isEmpty,
                  let terminalState = historyTurnTerminalState(turnObject) else {
                continue
            }
            result[turnID] = terminalState
        }

        return result
    }

    func decodeHistoryBaseDate(from threadObject: [String: JSONValue], threadId: String? = nil) -> Date {
        if let rawCreatedAt = threadObject["createdAt"]?.doubleValue {
            if let date = trustedHistoryDate(CodexTimestampParser.decodeUnixTimestamp(rawCreatedAt)) {
                return date
            }
        }
        if let rawCreatedAt = threadObject["created_at"]?.doubleValue {
            if let date = trustedHistoryDate(CodexTimestampParser.decodeUnixTimestamp(rawCreatedAt)) {
                return date
            }
        }

        if let rawUpdatedAt = threadObject["updatedAt"]?.doubleValue {
            if let date = trustedHistoryDate(CodexTimestampParser.decodeUnixTimestamp(rawUpdatedAt)) {
                return date
            }
        }
        if let rawUpdatedAt = threadObject["updated_at"]?.doubleValue {
            if let date = trustedHistoryDate(CodexTimestampParser.decodeUnixTimestamp(rawUpdatedAt)) {
                return date
            }
        }

        if let rawCreatedAt = threadObject["createdAt"]?.stringValue,
           let parsed = trustedHistoryDate(CodexTimestampParser.parseString(rawCreatedAt)) {
            return parsed
        }
        if let rawCreatedAt = threadObject["created_at"]?.stringValue,
           let parsed = trustedHistoryDate(CodexTimestampParser.parseString(rawCreatedAt)) {
            return parsed
        }

        if let rawUpdatedAt = threadObject["updatedAt"]?.stringValue,
           let parsed = trustedHistoryDate(CodexTimestampParser.parseString(rawUpdatedAt)) {
            return parsed
        }
        if let rawUpdatedAt = threadObject["updated_at"]?.stringValue,
           let parsed = trustedHistoryDate(CodexTimestampParser.parseString(rawUpdatedAt)) {
            return parsed
        }

        if let threadId,
           let localAnchor = existingHistoryFallbackDate(for: threadId) {
            return localAnchor
        }

        // Use a current local anchor rather than epoch, which renders as 1:00 in CET.
        return Date()
    }

    private func existingHistoryFallbackDate(for threadId: String) -> Date? {
        messagesByThread[threadId]?
            .map(\.createdAt)
            .filter { CodexTimestampParser.isTrustworthyServerDate($0) }
            .min()
    }

    func decodeUnixTimestamp(_ rawValue: Double) -> Date {
        CodexTimestampParser.decodeUnixTimestamp(rawValue)
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

            if inputType == "mention" {
                let resolved = firstNonEmptyString([
                    object["name"]?.stringValue,
                    object["id"]?.stringValue,
                    object["path"]?.stringValue,
                ])
                if let resolved, !resolved.isEmpty {
                    return "@\(resolved)"
                }
            }

            if inputType == "text",
               let dataText = object["data"]?.objectValue?["text"]?.stringValue {
                return dataText
            }

            return nil
        }

        let joined = Self.normalizedMessageText(textParts.joined(separator: "\n"))
        if Self.hasMeaningfulHistoryText(joined) {
            return joined
        }

        if let directText = itemObject["text"]?.stringValue {
            let normalizedDirectText = Self.normalizedMessageText(directText)
            if Self.hasMeaningfulHistoryText(normalizedDirectText) {
                return normalizedDirectText
            }
        }

        if let nestedText = itemObject["message"]?.stringValue {
            let normalizedNestedText = Self.normalizedMessageText(nestedText)
            if Self.hasMeaningfulHistoryText(normalizedNestedText) {
                return normalizedNestedText
            }
        }

        return ""
    }

    func decodeHistorySkillMentions(from itemObject: [String: JSONValue]) -> [String] {
        let contentItems = itemObject["content"]?.arrayValue ?? []
        var mentions: [String] = []
        var seen: Set<String> = []

        for value in contentItems {
            guard let object = value.objectValue else { continue }
            let inputType = normalizedItemType(object["type"]?.stringValue?.lowercased() ?? "")
            guard inputType == "skill" else { continue }

            let rawSkill = firstNonEmptyString([
                object["id"]?.stringValue,
                object["name"]?.stringValue,
            ])
            guard let rawSkill else { continue }

            let mention = rawSkill.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = Self.normalizedUserMentionName(mention)
            guard !mention.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            mentions.append(mention)
        }

        return mentions
    }

    func decodeHistoryPluginMentions(from itemObject: [String: JSONValue]) -> [String] {
        let contentItems = itemObject["content"]?.arrayValue ?? []
        var mentions: [String] = []
        var seen: Set<String> = []

        for value in contentItems {
            guard let object = value.objectValue else { continue }
            let inputType = normalizedItemType(object["type"]?.stringValue?.lowercased() ?? "")
            guard inputType == "mention" else { continue }

            let rawMention = firstNonEmptyString([
                object["name"]?.stringValue,
                object["id"]?.stringValue,
                object["path"]?.stringValue,
            ])
            guard let rawMention else { continue }

            let mention = rawMention.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = Self.normalizedUserMentionName(mention)
            guard !mention.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            mentions.append(mention)
        }

        return mentions
    }

    func decodeGeneratedImageMarkdown(from itemObject: [String: JSONValue]) -> String? {
        let imagePath = firstNonEmptyString([
            itemObject["saved_path"]?.stringValue,
            itemObject["savedPath"]?.stringValue,
            itemObject["path"]?.stringValue,
            itemObject["file_path"]?.stringValue
        ])?
        .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let imagePath, Self.isGeneratedImagePath(imagePath) else {
            return nil
        }

        return "![Generated image](\(Self.markdownImagePath(imagePath)))"
    }

    nonisolated static func isGeneratedImagePath(_ path: String) -> Bool {
        let lowercased = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowercased.hasSuffix(".png")
            || lowercased.hasSuffix(".jpg")
            || lowercased.hasSuffix(".jpeg")
            || lowercased.hasSuffix(".gif")
            || lowercased.hasSuffix(".webp")
            || lowercased.hasSuffix(".heic")
            || lowercased.hasSuffix(".heif")
    }

    nonisolated static func markdownImagePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(")") || trimmed.contains(" ") || trimmed.contains("%") {
            let escaped = trimmed
                .replacingOccurrences(of: "%", with: "%25")
                .replacingOccurrences(of: ">", with: "%3E")
                .replacingOccurrences(of: ")", with: "%29")
            return "<\(escaped)>"
        }
        return trimmed
    }

    // Extracts history image payloads into attachments. Small inline data URLs are preserved
    // so mobile can preview images that are outside the workspace allowlist.
    func decodeImageAttachments(from itemObject: [String: JSONValue]) -> [CodexImageAttachment] {
        let contentItems = itemObject["content"]?.arrayValue ?? []
        var attachments: [CodexImageAttachment] = []

        for value in contentItems {
            guard let object = value.objectValue else { continue }
            let rawType = object["type"]?.stringValue ?? ""
            let normalizedType = normalizedItemType(rawType)
            guard normalizedType == "image"
                    || normalizedType == "localimage"
                    || normalizedType == "inputimage"
                    || normalizedType == "outputimage" else {
                continue
            }

            let sourceURL = decodeImageAttachmentSourceURL(from: object)
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
                .sanitizedForStorage(
                    preservingPayloadDataURL: shouldPreserveHistoryImagePayload(payloadDataURL)
                )
            )
        }

        return attachments
    }

    private func shouldPreserveHistoryImagePayload(_ payloadDataURL: String?) -> Bool {
        guard let payloadDataURL else { return false }
        return payloadDataURL.utf8.count <= Self.historyInlineImagePayloadStorageByteLimit
    }

    func decodeImageAttachmentSourceURL(from object: [String: JSONValue]) -> String? {
        decodeHistoryFirstString(
            forAnyKey: ["url", "image_url", "imageUrl", "path"],
            in: .object(object),
            maxDepth: 4
        )
    }

    func mergeHistoryMessages(_ existing: [CodexMessage], _ history: [CodexMessage]) -> [CodexMessage] {
        let activeThreadIDs = Set(activeTurnIdByThread.keys)
        let activeTurnIDs = Set(activeTurnIdByThread.values)
        let runningIDs = runningThreadIDs
        return (try? Self.mergeHistoryMessages(
            existing,
            history,
            activeThreadIDs: activeThreadIDs,
            activeTurnIDs: activeTurnIDs,
            runningThreadIDs: runningIDs
        )) ?? existing
    }

    // Cold/inactive hydration and thread/replaced source handoffs can repair the
    // mirrored tail. Prune only stale mirror-minted rows inside the canonical
    // page's anchored tail: older cached pages and unsent local prompts remain
    // intact, while absent synthetic findings/tools cannot leak forward.
    nonisolated static func existingMessagesForCanonicalSourceReplacement(
        _ existing: [CodexMessage],
        history: [CodexMessage]
    ) -> [CodexMessage] {
        guard !existing.isEmpty, !history.isEmpty else {
            return existing
        }

        func kindsAreCompatible(_ first: CodexMessage, _ second: CodexMessage) -> Bool {
            first.kind == second.kind || first.kind == .chat || second.kind == .chat
        }

        var canonicalTurnByLocalProvisionalTurn: [String: String] = [:]
        for local in existing where local.role == .user {
            guard let localTurnID = normalizedHistoryIdentifier(local.turnId),
                  isProvisionalHistoryTurnIdentifier(localTurnID) else {
                continue
            }
            let canonicalMatches = history.filter { canonical in
                guard canonical.role == .user,
                      let canonicalTurnID = normalizedHistoryIdentifier(canonical.turnId),
                      !isProvisionalHistoryTurnIdentifier(canonicalTurnID) else {
                    return false
                }
                return userMessagesMatchForHistory(local, canonical)
                    && userMessageMetadataLooksCompatible(
                        localMessage: local,
                        serverMessage: canonical,
                        allowAttachmentCountFallback: local.deliveryState == .pending
                    )
            }
            let localOccurrences = existing.filter { candidate in
                candidate.role == .user && userMessagesMatchForHistory(candidate, local)
            }
            if canonicalMatches.count == 1,
               localOccurrences.count == 1,
               let canonicalTurnID = normalizedHistoryIdentifier(canonicalMatches[0].turnId) {
                canonicalTurnByLocalProvisionalTurn[localTurnID] = canonicalTurnID
            }
        }

        func turnsAreCompatible(_ first: CodexMessage, _ second: CodexMessage) -> Bool {
            let firstTurnID = normalizedHistoryIdentifier(first.turnId)
            let secondTurnID = normalizedHistoryIdentifier(second.turnId)
            if firstTurnID == secondTurnID {
                return true
            }
            guard let firstTurnID, let secondTurnID else {
                return false
            }
            return canonicalTurnByLocalProvisionalTurn[firstTurnID] == secondTurnID
        }

        func hasCanonicalCounterpart(_ local: CodexMessage) -> Bool {
            let localItemID = normalizedHistoryIdentifier(local.itemId)
            return history.contains { canonical in
                guard canonical.role == local.role, kindsAreCompatible(local, canonical) else {
                    return false
                }
                if let localItemID,
                   localItemID == normalizedHistoryIdentifier(canonical.itemId) {
                    if CodexSyntheticIdentifiers.isProjectedDesktopUserItemID(localItemID) {
                        return userMessagesMatchForHistory(local, canonical)
                            && turnsAreCompatible(local, canonical)
                    }
                    if CodexSyntheticIdentifiers.isJSONLLineFallbackItemID(localItemID) {
                        return normalizedMessageText(local.text) == normalizedMessageText(canonical.text)
                            && turnsAreCompatible(local, canonical)
                    }
                    return !CodexSyntheticIdentifiers.isMirrorMintedItemID(localItemID)
                        || turnsAreCompatible(local, canonical)
                }
                if local.role == .system,
                   local.kind == .plan,
                   local.resolvedPlanPresentation == .progress,
                   canonical.resolvedPlanPresentation == .progress,
                   turnsAreCompatible(local, canonical) {
                    return true
                }
                let localText = normalizedMessageText(local.text)
                return !localText.isEmpty
                    && localText == normalizedMessageText(canonical.text)
                    && turnsAreCompatible(local, canonical)
            }
        }

        func hasStrongCanonicalAnchor(_ local: CodexMessage) -> Bool {
            let localItemID = normalizedHistoryIdentifier(local.itemId)
            return history.contains { canonical in
                guard canonical.role == local.role, kindsAreCompatible(local, canonical) else {
                    return false
                }
                if let localItemID,
                   localItemID == normalizedHistoryIdentifier(canonical.itemId),
                   !CodexSyntheticIdentifiers.isMirrorMintedItemID(localItemID) {
                    return true
                }
                guard turnsAreCompatible(local, canonical) else {
                    return false
                }
                let localTurnID = normalizedHistoryIdentifier(local.turnId)
                let canonicalTurnID = normalizedHistoryIdentifier(canonical.turnId)
                let hasRealSharedTurn = localTurnID == canonicalTurnID
                    && localTurnID.map { !isProvisionalHistoryTurnIdentifier($0) } == true
                let hasMappedPromptTurn = local.role == .user
                    && localTurnID.flatMap { canonicalTurnByLocalProvisionalTurn[$0] } == canonicalTurnID
                guard hasRealSharedTurn || hasMappedPromptTurn else {
                    return false
                }
                return normalizedMessageText(local.text) == normalizedMessageText(canonical.text)
            }
        }

        let anchoredMessages = existing.filter(hasStrongCanonicalAnchor)
        let anchoredTurnIDs = Set(
            anchoredMessages.compactMap { normalizedHistoryIdentifier($0.turnId) }
        )
        let canonicalTailCandidates = existing.filter { message in
            hasStrongCanonicalAnchor(message)
                || normalizedHistoryIdentifier(message.turnId).map { anchoredTurnIDs.contains($0) } == true
        }
        guard let canonicalTailStartOrder = canonicalTailCandidates.map(\.orderIndex).min() else {
            // With no cross-source proof, ordinary merge is safer than deleting
            // a locally cached transcript merely because the new page is sparse.
            return existing
        }

        return existing.filter { message in
            guard message.orderIndex >= canonicalTailStartOrder else {
                return true
            }
            if message.role == .user, message.deliveryState != .confirmed {
                return true
            }
            let hasMirrorItemID = normalizedHistoryIdentifier(message.itemId)
                .map { CodexSyntheticIdentifiers.isMirrorMintedItemID($0) }
                ?? false
            let hasMirrorTurnID = isProvisionalHistoryTurnIdentifier(message.turnId)
            guard hasMirrorItemID || hasMirrorTurnID else {
                return true
            }
            return hasCanonicalCounterpart(message)
        }
    }

    // When one provisional turn has exactly one local opener and exactly one
    // canonical opener, that prompt is safe proof for the whole turn block.
    // Promote every row together so plans/findings/copy ownership cannot remain
    // split across synthetic and real turn ids after reopen.
    nonisolated static func canonicalizeUniqueProvisionalTurnMappings(
        in messages: inout [CodexMessage],
        history: [CodexMessage]
    ) {
        let localUsersByTurn = Dictionary(
            grouping: messages.filter { message in
                message.role == .user && isProvisionalHistoryTurnIdentifier(message.turnId)
            },
            by: { normalizedHistoryIdentifier($0.turnId) ?? "" }
        )
        for (localTurnID, localUsers) in localUsersByTurn {
            guard !localTurnID.isEmpty, localUsers.count == 1, let localUser = localUsers.first else {
                continue
            }
            let matchingLocalUsers = messages.filter { candidate in
                candidate.role == .user
                    && userMessagesMatchForHistory(candidate, localUser)
                    && userMessageMetadataLooksCompatible(
                        localMessage: candidate,
                        serverMessage: localUser,
                        allowAttachmentCountFallback: candidate.deliveryState == .pending
                    )
            }
            guard matchingLocalUsers.count == 1 else {
                // A partial canonical page cannot tell which repeated local
                // prompt it represents. Leave both turn blocks untouched.
                continue
            }
            let canonicalUsers = history.filter { canonical in
                guard canonical.role == .user,
                      let canonicalTurnID = normalizedHistoryIdentifier(canonical.turnId),
                      !isProvisionalHistoryTurnIdentifier(canonicalTurnID) else {
                    return false
                }
                return userMessagesMatchForHistory(localUser, canonical)
                    && userMessageMetadataLooksCompatible(
                        localMessage: localUser,
                        serverMessage: canonical,
                        allowAttachmentCountFallback: localUser.deliveryState == .pending
                    )
            }
            guard canonicalUsers.count == 1,
                  let canonicalTurnID = normalizedHistoryIdentifier(canonicalUsers[0].turnId) else {
                continue
            }
            for index in messages.indices
                where normalizedHistoryIdentifier(messages[index].turnId) == localTurnID {
                messages[index].turnId = canonicalTurnID
            }
        }
    }

    nonisolated static func mergeHistoryMessages(
        _ existing: [CodexMessage],
        _ history: [CodexMessage],
        activeThreadIDs: Set<String>,
        activeTurnIDs: Set<String>? = nil,
        runningThreadIDs: Set<String>
    ) throws -> [CodexMessage] {
        if existing.isEmpty {
            // History messages arrive in server order; assign sequential orderIndex values
            // so that the stable sort preserves server-provided chronology.
            var sorted = AssistantReplayDeduper.dedupeBlockReplays(in: history)
            healExactDuplicateProviderRows(
                in: &sorted,
                canonicalOrderByMessageID: [:],
                activeThreadIDs: activeThreadIDs,
                activeTurnIDs: activeTurnIDs,
                runningThreadIDs: runningThreadIDs
            )
            for index in sorted.indices {
                sorted[index].orderIndex = CodexMessageOrderCounter.next()
            }
            return historyMessagesMergingGeneratedImageArtifacts(sorted)
        }

        var merged = existing
        canonicalizeUniqueProvisionalTurnMappings(in: &merged, history: history)
        let originalMessageIDs = Set(existing.map(\.id))
        let assistantHistoryCountByTurn = Dictionary(
            grouping: history.filter { $0.role == .assistant }
        ) { $0.turnId ?? "" }
        .mapValues(\.count)
        var processedHistoryMessages = 0
        // Canonical payload order is authoritative for every represented row,
        // including a running thread recovering from a truncated reconnect.
        // Local-only live rows retain their occupied slots below.
        let shouldApplyCanonicalHistoryOrder = true
        var canonicalOrderByMessageID: [String: Int] = [:]

        func recordCanonicalOrder(at index: Int) {
            guard shouldApplyCanonicalHistoryOrder, merged.indices.contains(index) else {
                return
            }
            canonicalOrderByMessageID[merged[index].id] = processedHistoryMessages
        }

        func reconcileMessage(at index: Int, with message: CodexMessage) {
            merged[index] = reconcileExistingMessage(
                merged[index],
                with: message,
                activeThreadIDs: activeThreadIDs,
                activeTurnIDs: activeTurnIDs,
                runningThreadIDs: runningThreadIDs
            )
            recordCanonicalOrder(at: index)
        }

        for message in history {
            processedHistoryMessages &+= 1
            if processedHistoryMessages.isMultiple(of: 32),
               Task.isCancelled {
                throw CancellationError()
            }

            if let incomingSourceItemKey = normalizedHistoryIdentifier(message.sourceItemKey),
               let incomingTurnID = normalizedHistoryIdentifier(message.turnId) {
                let eligibleAliasIndices = merged.indices.filter { index in
                    let candidate = merged[index]
                    return candidate.role == message.role
                        && normalizedHistoryIdentifier(candidate.turnId) == incomingTurnID
                        && normalizedHistoryIdentifier(candidate.sourceItemKey) == incomingSourceItemKey
                        && sourceItemIdentityAllowsReconcile(candidate.itemId, message.itemId)
                        && (candidate.kind == message.kind || candidate.kind == .chat || message.kind == .chat)
                }
                if eligibleAliasIndices.count == 1, let index = eligibleAliasIndices.first {
                    reconcileMessage(at: index, with: message)
                    continue
                }
            }

            if let incomingItemId = normalizedHistoryIdentifier(message.itemId),
               let index = merged.firstIndex(where: { candidate in
                   normalizedHistoryIdentifier(candidate.itemId) == incomingItemId
                       && candidate.role == message.role
                       && (
                           candidate.kind == message.kind
                               || candidate.kind == .chat
                               || message.kind == .chat
                       )
                       && exactHistoryItemIdentityAllowsReconcile(
                           candidate,
                           with: message,
                           itemId: incomingItemId
                       )
               }) {
                reconcileMessage(at: index, with: message)
                continue
            }

            if message.role == .assistant,
               let turnId = message.turnId, !turnId.isEmpty,
               let index = uniqueAssistantHistoryTextMergeIndex(
                   in: merged,
                   message: message,
                   turnId: turnId
               ) {
                reconcileMessage(at: index, with: message)
                continue
            }

            // Forced resume snapshots can materialize a real assistant itemId after the
            // live row was already created with provisional identity. Only merge when
            // the identity is compatible, otherwise stale history can pollute the live row.
            if message.role == .assistant,
               let turnId = message.turnId, !turnId.isEmpty,
               (activeThreadIDs.contains(message.threadId) || runningThreadIDs.contains(message.threadId)),
               let index = merged.lastIndex(where: { candidate in
                   candidate.role == .assistant
                       && candidate.turnId == turnId
                       && candidate.isStreaming
                       && lineFallbackIdentityAllowsTurnScopedReconcile(candidate, with: message)
                       && assistantHistoryIdentityAllowsRunningReconcile(
                           localMessage: candidate,
                           serverMessage: message
                       )
               }) {
                reconcileMessage(at: index, with: message)
                continue
            }

            // Running turn snapshots without item identity are too ambiguous to append
            // beside a live item-scoped assistant row.
            if message.role == .assistant,
               let turnId = message.turnId, !turnId.isEmpty,
               normalizedHistoryIdentifier(message.itemId) == nil,
               (activeThreadIDs.contains(message.threadId) || runningThreadIDs.contains(message.threadId)),
               merged.contains(where: { candidate in
                   candidate.role == .assistant
                       && candidate.turnId == turnId
                       && candidate.isStreaming
                       && hasStableAssistantIdentity(candidate.itemId)
               }) {
                continue
            }

            let threadIsStillActive = activeThreadIDs.contains(message.threadId)
                || runningThreadIDs.contains(message.threadId)

            // After a turn is fully closed, thread/read can return the same single assistant
            // reply with canonical text or a different stable item id. Reconcile that row
            // instead of appending a second final bubble.
            if message.role == .assistant,
               let turnId = message.turnId, !turnId.isEmpty,
               !threadIsStillActive,
               assistantHistoryCountByTurn[turnId] == 1 {
                let candidateIndices = merged.indices.filter { index in
                    let candidate = merged[index]
                    return candidate.role == .assistant
                        && candidate.turnId == turnId
                        && !candidate.isStreaming
                        && lineFallbackIdentityAllowsTurnScopedReconcile(candidate, with: message)
                }

                if candidateIndices.count == 1,
                   let index = candidateIndices.last {
                    if shouldReplaceClosedAssistantMessage(
                        merged[index],
                        with: message
                    ) {
                        reconcileMessage(at: index, with: message)
                    }
                    recordCanonicalOrder(at: index)
                    continue
                }
            }

            if message.role == .user,
               let turnId = message.turnId, !turnId.isEmpty,
               let index = uniqueUserHistoryMergeIndex(
                   in: merged,
                   message: message,
                   turnId: turnId
               ) {
                reconcileMessage(at: index, with: message)
                continue
            }

            // Resolve the remaining composite/text identity before any broad
            // same-turn fallback so identity-less rows still reconcile safely.
            let exactKey = historyMessageKey(for: message)
            if let index = merged.firstIndex(where: { candidate in
                guard historyMessageKey(for: candidate) == exactKey else {
                    return false
                }
                guard let itemId = normalizedHistoryIdentifier(message.itemId),
                      itemId == normalizedHistoryIdentifier(candidate.itemId) else {
                    return true
                }
                return exactHistoryItemIdentityAllowsReconcile(
                    candidate,
                    with: message,
                    itemId: itemId
                )
            }) {
                reconcileMessage(at: index, with: message)
                continue
            }

            // Progress is one mutable plan snapshot per turn. Live Desktop
            // updates use a turn placeholder while history uses todo-list IDs;
            // reconcile the unique progress row instead of duplicating the card.
            if message.role == .system,
               message.kind == .plan,
               message.resolvedPlanPresentation == .progress,
               let turnId = message.turnId, !turnId.isEmpty {
                let candidateIndices = merged.indices.filter { index in
                    let candidate = merged[index]
                    return candidate.role == .system
                        && candidate.kind == .plan
                        && candidate.turnId == turnId
                        && candidate.resolvedPlanPresentation == .progress
                }
                if let index = candidateIndices.min(by: {
                    merged[$0].orderIndex < merged[$1].orderIndex
                }) {
                    let keeperID = merged[index].id
                    reconcileMessage(at: index, with: message)
                    merged.removeAll { candidate in
                        candidate.id != keeperID
                            && candidate.role == .system
                            && candidate.kind == .plan
                            && candidate.turnId == turnId
                            && candidate.resolvedPlanPresentation == .progress
                    }
                    continue
                }
            }

            // Reconcile turn-scoped thinking snapshots even when the streamed row
            // carries a synthetic itemId (e.g. "turn:ABC|kind:thinking") that differs
            // from the server's real itemId or nil.
            if message.role == .system,
               message.kind == .thinking,
               let turnId = message.turnId, !turnId.isEmpty {
                let candidateIndices = merged.indices.filter { index in
                    let candidate = merged[index]
                    return candidate.role == .system
                        && candidate.kind == .thinking
                        && candidate.turnId == turnId
                        && (
                            isProvisionalThinkingIdentifier(candidate.itemId)
                                || isProvisionalThinkingIdentifier(message.itemId)
                        )
                        && lineFallbackIdentityAllowsTurnScopedReconcile(candidate, with: message)
                }
                if candidateIndices.count == 1, let index = candidateIndices.first {
                    reconcileMessage(at: index, with: message)
                    continue
                }
            }

            // Reconcile turn-scoped file change items even when the streamed row
            // has a synthetic itemId that differs from the server's real one.
            // Turnless rows only bind inside this turn's contiguous block so
            // repeated working-tree snapshots cannot move between turns.
            if message.role == .system,
               message.kind == .fileChange,
               let turnId = message.turnId, !turnId.isEmpty {
                let turnBlockRange = Self.contiguousTurnBlockRange(in: merged, turnId: turnId)
                let candidateIndices = merged.indices.filter { candidateIndex in
                    let candidate = merged[candidateIndex]
                    guard candidate.role == .system,
                          candidate.kind == .fileChange,
                          lineFallbackIdentityAllowsTurnScopedReconcile(candidate, with: message),
                          isProvisionalSystemItemIdentifier(candidate.itemId)
                            || isProvisionalSystemItemIdentifier(message.itemId) else {
                        return false
                    }
                    if candidate.turnId == turnId {
                        return true
                    }
                    guard candidate.turnId == nil else {
                        return false
                    }
                    return Self.turnlessFileChangeRowIsClaimable(
                        in: merged,
                        candidateIndex: candidateIndex,
                        turnId: turnId,
                        turnBlockRange: turnBlockRange
                    )
                }
                if candidateIndices.count == 1, let index = candidateIndices.first {
                    reconcileMessage(at: index, with: message)
                    continue
                }
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
                        && lineFallbackIdentityAllowsTurnScopedReconcile(merged[index], with: message)
                }) {
                    reconcileMessage(at: itemIndex, with: message)
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
                    reconcileMessage(at: index, with: message)
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
                        reconcileMessage(at: index, with: message)
                        continue
                    }
                }
            }

            // Dedupes command rows when incoming/history command formatting differs only by shell quoting.
            if message.role == .system,
               message.kind == .commandExecution,
               let turnId = message.turnId, !turnId.isEmpty,
               let incomingCommandKey = normalizedCommandExecutionPreviewKey(from: message.text) {
                let candidateIndices = merged.indices.filter { index in
                    let candidate = merged[index]
                   guard candidate.role == .system,
                         candidate.kind == .commandExecution,
                         candidate.turnId == turnId,
                         lineFallbackIdentityAllowsTurnScopedReconcile(candidate, with: message),
                         isProvisionalSystemItemIdentifier(candidate.itemId)
                            || isProvisionalSystemItemIdentifier(message.itemId),
                         let candidateCommandKey = normalizedCommandExecutionPreviewKey(from: candidate.text) else {
                       return false
                   }
                   return candidateCommandKey == incomingCommandKey
                }
                if candidateIndices.count == 1, let index = candidateIndices.first {
                    reconcileMessage(at: index, with: message)
                    continue
                }
            }

            // Reconcile turn-scoped command execution items by turnId when text-based
            // dedup above did not match (e.g. synthetic vs real itemId).
            if message.role == .system,
               message.kind == .commandExecution,
               let turnId = message.turnId, !turnId.isEmpty {
                let candidateIndices = merged.indices.filter { index in
                    let candidate = merged[index]
                    return candidate.role == .system
                        && candidate.kind == .commandExecution
                        && candidate.turnId == turnId
                        && lineFallbackIdentityAllowsTurnScopedReconcile(candidate, with: message)
                        && (
                            isProvisionalSystemItemIdentifier(candidate.itemId)
                                || isProvisionalSystemItemIdentifier(message.itemId)
                        )
                }
                if candidateIndices.count == 1, let index = candidateIndices.first {
                    reconcileMessage(at: index, with: message)
                    continue
                }
            }

            if message.role == .user {
                let fallbackCandidates = fallbackUserHistoryMergeIndices(
                    in: merged,
                    message: message
                )
                if fallbackCandidates.count == 1,
                   let index = fallbackCandidates.first {
                    reconcileMessage(at: index, with: message)
                    continue
                }

                // Identifier-less history rows with epoch timestamps are already
                // represented locally; appending them creates the visible 1:00 echo.
                if hasFallbackHistoryTimestamp(message.createdAt),
                   !fallbackCandidates.isEmpty {
                    continue
                }

                // Desktop-projected rows with synthetic identity that ambiguously
                // match several real rows are already represented; appending them
                // duplicates the prompt instead of preserving an intentional repeat.
                if fallbackCandidates.count > 1,
                   isProvisionalHistoryTurnIdentifier(message.turnId)
                    || isProvisionalUserItemIdentifier(message.itemId) {
                    continue
                }
            }

            if message.role == .user,
               let pendingIndex = uniquePendingUserHistoryMergeIndex(
                   in: merged,
                   message: message
               ) {
                reconcileMessage(at: pendingIndex, with: message)
                continue
            }

            if message.role == .assistant,
               AssistantReplayDeduper.isReplayMessage(
                   in: merged,
                   threadId: message.threadId,
                   turnId: message.turnId,
                   itemId: message.itemId,
                   text: message.text
               ) {
                continue
            }

            merged.append(message)
            recordCanonicalOrder(at: merged.index(before: merged.endIndex))
        }

        repairCanonicalAssistantSourceIdentityRotations(
            in: &merged,
            history: history,
            canonicalOrderByMessageID: &canonicalOrderByMessageID,
            activeThreadIDs: activeThreadIDs,
            activeTurnIDs: activeTurnIDs,
            runningThreadIDs: runningThreadIDs
        )

        if shouldApplyCanonicalHistoryOrder {
            applyCanonicalHistoryOrder(
                to: &merged,
                canonicalOrderByMessageID: canonicalOrderByMessageID,
                originalMessageIDs: originalMessageIDs
            )
        }
        healExactDuplicateProviderRows(
            in: &merged,
            canonicalOrderByMessageID: canonicalOrderByMessageID,
            activeThreadIDs: activeThreadIDs,
            activeTurnIDs: activeTurnIDs,
            runningThreadIDs: runningThreadIDs
        )
        merged.sort(by: { $0.orderIndex < $1.orderIndex })
        return historyMessagesMergingGeneratedImageArtifacts(merged)
    }

    // Reorders only the turns represented by the canonical payload. Unmatched
    // rows stay in their original gap between canonical neighbours, and turns
    // absent from a partial page remain hard fences instead of being swept to
    // the end of the timeline.
    nonisolated static func applyCanonicalHistoryOrder(
        to messages: inout [CodexMessage],
        canonicalOrderByMessageID: [String: Int],
        originalMessageIDs: Set<String>
    ) {
        guard !canonicalOrderByMessageID.isEmpty else {
            return
        }
        let slotOrderIndices = messages.map(\.orderIndex).sorted()
        let orderedMessages = messages.sorted { $0.orderIndex < $1.orderIndex }
        let canonicalMessages = orderedMessages
            .filter { canonicalOrderByMessageID[$0.id] != nil }
            .sorted { lhs, rhs in
                let lhsOrder = canonicalOrderByMessageID[lhs.id] ?? Int.max
                let rhsOrder = canonicalOrderByMessageID[rhs.id] ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.orderIndex < rhs.orderIndex
            }
        guard !canonicalMessages.isEmpty else {
            return
        }

        var orderedGroupKeys: [String] = []
        var canonicalMessagesByGroup: [String: [CodexMessage]] = [:]
        var turnIDByGroup: [String: String] = [:]
        var groupKeyByCanonicalMessageID: [String: String] = [:]
        for message in canonicalMessages {
            let normalizedTurnID = normalizedHistoryIdentifier(message.turnId)
            let groupKey = normalizedTurnID
                .map { "turn:\($0)" }
                ?? "turnless:\(message.id)"
            if canonicalMessagesByGroup[groupKey] == nil {
                orderedGroupKeys.append(groupKey)
            }
            canonicalMessagesByGroup[groupKey, default: []].append(message)
            groupKeyByCanonicalMessageID[message.id] = groupKey
            if let normalizedTurnID {
                turnIDByGroup[groupKey] = normalizedTurnID
            }
        }

        let canonicalMessageIDs = Set(canonicalMessages.map(\.id))
        let coveredTurnIDs = Set(turnIDByGroup.values)
        func coveredGroupKey(for message: CodexMessage) -> String? {
            if let key = groupKeyByCanonicalMessageID[message.id] {
                return key
            }
            guard let turnID = normalizedHistoryIdentifier(message.turnId) else {
                return nil
            }
            guard coveredTurnIDs.contains(turnID) else {
                return nil
            }
            return "turn:\(turnID)"
        }

        var allMessagesByGroup: [String: [CodexMessage]] = [:]
        var orderedPositionByMessageID: [String: Int] = [:]
        for (position, message) in orderedMessages.enumerated() {
            if orderedPositionByMessageID[message.id] == nil {
                orderedPositionByMessageID[message.id] = position
            }
            if let groupKey = coveredGroupKey(for: message) {
                allMessagesByGroup[groupKey, default: []].append(message)
            }
        }

        // Build each covered turn independently. Canonical rows define the
        // order, while local-only rows retain the gap they occupied between
        // original canonical anchors (A, local X, B stays A, X, B).
        var rebuiltMessagesByGroup: [String: [CodexMessage]] = [:]
        for groupKey in orderedGroupKeys {
            guard let groupCanonicalMessages = canonicalMessagesByGroup[groupKey],
                  !groupCanonicalMessages.isEmpty else {
                continue
            }
            let groupMessages = allMessagesByGroup[groupKey] ?? groupCanonicalMessages
            var canonicalRankByMessageID: [String: Int] = [:]
            for (rank, message) in groupCanonicalMessages.enumerated()
                where canonicalRankByMessageID[message.id] == nil {
                canonicalRankByMessageID[message.id] = rank
            }
            let anchors: [(position: Int, rank: Int)] = groupCanonicalMessages.compactMap { message in
                guard originalMessageIDs.contains(message.id),
                      let position = orderedPositionByMessageID[message.id],
                      let rank = canonicalRankByMessageID[message.id] else {
                    return nil
                }
                return (position, rank)
            }.sorted { $0.position < $1.position }
            var localBuckets = Array(
                repeating: [CodexMessage](),
                count: groupCanonicalMessages.count + 1
            )

            for localMessage in groupMessages where !canonicalMessageIDs.contains(localMessage.id) {
                let localPosition = orderedPositionByMessageID[localMessage.id] ?? Int.max
                let previousAnchor = anchors.last(where: { $0.position < localPosition })
                let nextAnchor = anchors.first(where: { $0.position > localPosition })
                let slot: Int
                if let previousAnchor, let nextAnchor, previousAnchor.rank < nextAnchor.rank {
                    slot = nextAnchor.rank
                } else if let previousAnchor {
                    slot = min(previousAnchor.rank + 1, groupCanonicalMessages.count)
                } else if let nextAnchor {
                    slot = nextAnchor.rank
                } else if groupCanonicalMessages.first?.role == .user {
                    slot = min(1, groupCanonicalMessages.count)
                } else {
                    slot = 0
                }
                localBuckets[slot].append(localMessage)
            }

            var rebuiltGroup: [CodexMessage] = []
            for canonicalIndex in groupCanonicalMessages.indices {
                rebuiltGroup.append(contentsOf: localBuckets[canonicalIndex])
                rebuiltGroup.append(groupCanonicalMessages[canonicalIndex])
            }
            rebuiltGroup.append(contentsOf: localBuckets[groupCanonicalMessages.count])
            rebuiltMessagesByGroup[groupKey] = rebuiltGroup
        }

        let uncoveredMessages = orderedMessages.filter { coveredGroupKey(for: $0) == nil }
        var anchoredSegmentByGroup: [String: Int] = [:]
        for groupKey in orderedGroupKeys {
            let originalPositions = (allMessagesByGroup[groupKey] ?? []).compactMap { message -> Int? in
                guard originalMessageIDs.contains(message.id) else {
                    return nil
                }
                return orderedPositionByMessageID[message.id]
            }
            guard let anchorPosition = originalPositions.min() else {
                continue
            }
            anchoredSegmentByGroup[groupKey] = orderedMessages[..<anchorPosition].reduce(into: 0) { count, message in
                if coveredGroupKey(for: message) == nil {
                    count += 1
                }
            }
        }

        // A group introduced wholly by history normally follows the cached
        // transcript. If the only trailing cache is an unsent/failed prompt,
        // however, that prompt is newer and must remain after recovered history.
        let firstPendingFence = uncoveredMessages.firstIndex(where: {
            $0.role == .user && $0.deliveryState != .confirmed
        })
        var resolvedSegmentByGroup = anchoredSegmentByGroup
        for (groupIndex, groupKey) in orderedGroupKeys.enumerated()
            where resolvedSegmentByGroup[groupKey] == nil {
            let naturalAnchorPosition = (allMessagesByGroup[groupKey] ?? [])
                .compactMap { orderedPositionByMessageID[$0.id] }
                .min()
                ?? orderedMessages.count
            let naturalSegment = orderedMessages[..<naturalAnchorPosition].reduce(into: 0) { count, message in
                if coveredGroupKey(for: message) == nil {
                    count += 1
                }
            }
            let previousSegment = orderedGroupKeys[..<groupIndex]
                .reversed()
                .compactMap { anchoredSegmentByGroup[$0] }
                .first
            let followingSegment = orderedGroupKeys[(groupIndex + 1)...]
                .compactMap { anchoredSegmentByGroup[$0] }
                .first
            let canonicalNeighbourSegment = previousSegment == followingSegment
                ? previousSegment
                : nil
            let segmentBeforePending = firstPendingFence.map { min(naturalSegment, $0) }
                ?? naturalSegment
            resolvedSegmentByGroup[groupKey] = canonicalNeighbourSegment ?? segmentBeforePending
        }

        var groupKeysBySegment: [Int: [String]] = [:]
        for groupKey in orderedGroupKeys {
            let segment = min(
                max(resolvedSegmentByGroup[groupKey] ?? uncoveredMessages.count, 0),
                uncoveredMessages.count
            )
            groupKeysBySegment[segment, default: []].append(groupKey)
        }

        var rebuiltTimeline: [CodexMessage] = []
        for segment in 0...uncoveredMessages.count {
            for groupKey in groupKeysBySegment[segment] ?? [] {
                rebuiltTimeline.append(contentsOf: rebuiltMessagesByGroup[groupKey] ?? [])
            }
            if segment < uncoveredMessages.count {
                rebuiltTimeline.append(uncoveredMessages[segment])
            }
        }

        guard rebuiltTimeline.count == slotOrderIndices.count else {
            return
        }
        for index in rebuiltTimeline.indices {
            rebuiltTimeline[index].orderIndex = slotOrderIndices[index]
        }
        messages = rebuiltTimeline
    }

    // Repairs duplicates already persisted by older reconnect replay. Only an
    // exact item identity is eligible; semantic similarity never deletes an
    // intentional repeat with a different provider id.
    nonisolated static func healExactDuplicateProviderRows(
        in messages: inout [CodexMessage],
        canonicalOrderByMessageID: [String: Int],
        activeThreadIDs: Set<String>,
        activeTurnIDs: Set<String>? = nil,
        runningThreadIDs: Set<String>
    ) {
        let orderedIndices = messages.indices.sorted { messages[$0].orderIndex < messages[$1].orderIndex }
        var keeperIndicesByKey: [String: [Int]] = [:]
        var duplicateIndices: [Int] = []

        for index in orderedIndices {
            let message = messages[index]
            guard message.role == .system || message.role == .assistant,
                  let itemId = normalizedHistoryIdentifier(message.itemId) else {
                continue
            }
            let key = "\(message.threadId)|\(message.role.rawValue)|\(itemId)"
            let keeperIndex = keeperIndicesByKey[key]?.first(where: { candidateIndex in
                let candidate = messages[candidateIndex]
                return candidate.kind == message.kind
                    || candidate.kind == .chat
                    || message.kind == .chat
            })
            guard let keeperIndex else {
                keeperIndicesByKey[key, default: []].append(index)
                continue
            }

            let keeperIsCanonical = canonicalOrderByMessageID[messages[keeperIndex].id] != nil
            let duplicateIsCanonical = canonicalOrderByMessageID[message.id] != nil
            let upgradesGenericKind = messages[keeperIndex].kind == .chat && message.kind != .chat
            if (
                !keeperIsCanonical
                    && (duplicateIsCanonical || message.text.utf8.count > messages[keeperIndex].text.utf8.count)
            ) || upgradesGenericKind {
                let preservedOrderIndex = messages[keeperIndex].orderIndex
                messages[keeperIndex] = reconcileExistingMessage(
                    messages[keeperIndex],
                    with: message,
                    activeThreadIDs: activeThreadIDs,
                    activeTurnIDs: activeTurnIDs,
                    runningThreadIDs: runningThreadIDs
                )
                messages[keeperIndex].orderIndex = preservedOrderIndex
            }
            duplicateIndices.append(index)
        }

        for index in duplicateIndices.sorted(by: >) {
            messages.remove(at: index)
        }
    }

    // Desktop live state and canonical history can assign different stable provider ids to the
    // same assistant item. Match them through the bridge's deterministic turn + text source alias;
    // normal app-server history can derive that alias even though it does not carry the field.
    // Active turns additionally require the orphan to precede the canonical copy unless the alias
    // is exact, so a newer intentional same-text item is never folded into history.
    nonisolated static func repairCanonicalAssistantSourceIdentityRotations(
        in messages: inout [CodexMessage],
        history: [CodexMessage],
        canonicalOrderByMessageID: inout [String: Int],
        activeThreadIDs: Set<String>,
        activeTurnIDs: Set<String>? = nil,
        runningThreadIDs: Set<String>
    ) {
        let canonicalAssistantRows = history.filter { message in
            message.role == .assistant
                && normalizedHistoryIdentifier(message.turnId) != nil
                && normalizedHistoryIdentifier(message.itemId) != nil
                && hasMeaningfulHistoryText(message.text)
        }
        guard !canonicalAssistantRows.isEmpty else {
            return
        }

        var canonicalItemIDsByTurn: [CanonicalAssistantTurnKey: Set<String>] = [:]
        for message in history where message.role == .assistant {
            guard let turnId = normalizedHistoryIdentifier(message.turnId),
                  let itemId = normalizedHistoryIdentifier(message.itemId) else {
                continue
            }
            canonicalItemIDsByTurn[
                CanonicalAssistantTurnKey(threadId: message.threadId, turnId: turnId),
                default: []
            ].insert(itemId)
        }

        let canonicalRowsBySource = Dictionary(grouping: canonicalAssistantRows) { message in
            let turnId = normalizedHistoryIdentifier(message.turnId) ?? ""
            return CanonicalAssistantSourceKey(
                threadId: message.threadId,
                turnId: turnId,
                sourceItemKey: normalizedHistoryIdentifier(message.sourceItemKey)
                    ?? remodexAssistantSourceItemKey(turnId: turnId, text: message.text)
                    ?? "",
                text: normalizedMessageText(message.text)
            )
        }
        let localIndicesByTurnText = Dictionary(
            grouping: messages.indices.filter { index in
                let message = messages[index]
                return message.role == .assistant
                    && !message.isStreaming
                    && normalizedHistoryIdentifier(message.turnId) != nil
                    && hasMeaningfulHistoryText(message.text)
            },
            by: { index in
                let message = messages[index]
                return CanonicalAssistantTurnTextKey(
                    threadId: message.threadId,
                    turnId: normalizedHistoryIdentifier(message.turnId) ?? "",
                    text: normalizedMessageText(message.text)
                )
            }
        )

        var repairs: [(orphanMessageId: String, duplicateMessageIds: [String], canonical: CodexMessage)] = []
        var claimedMessageIDs: Set<String> = []

        for (sourceKey, canonicalRows) in canonicalRowsBySource where canonicalRows.count == 1 {
            guard !isProvisionalHistoryTurnIdentifier(sourceKey.turnId),
                  let canonical = canonicalRows.first,
                  let canonicalItemID = normalizedHistoryIdentifier(canonical.itemId) else {
                continue
            }

            let turnKey = CanonicalAssistantTurnKey(
                threadId: sourceKey.threadId,
                turnId: sourceKey.turnId
            )
            let canonicalTurnItemIDs = canonicalItemIDsByTurn[turnKey] ?? []
            let turnTextKey = CanonicalAssistantTurnTextKey(
                threadId: sourceKey.threadId,
                turnId: sourceKey.turnId,
                text: sourceKey.text
            )
            let matchingLocalIndices = localIndicesByTurnText[turnTextKey] ?? []
            let canonicalHasExplicitSourceAlias = normalizedHistoryIdentifier(
                canonical.sourceItemKey
            ) != nil
            let orphanIndices = matchingLocalIndices.filter { index in
                let candidate = messages[index]
                let candidateItemID = normalizedHistoryIdentifier(candidate.itemId)
                let candidateSourceKey = normalizedHistoryIdentifier(candidate.sourceItemKey)
                return candidateItemID != canonicalItemID
                    && (candidateItemID.map { !canonicalTurnItemIDs.contains($0) } ?? true)
                    && (canonicalHasExplicitSourceAlias
                        ? (candidateSourceKey == nil || candidateSourceKey == sourceKey.sourceItemKey)
                        : candidateSourceKey == sourceKey.sourceItemKey)
            }
            guard orphanIndices.count == 1,
                  let orphanIndex = orphanIndices.first,
                  !claimedMessageIDs.contains(messages[orphanIndex].id) else {
                continue
            }

            let canonicalDuplicateIndices = matchingLocalIndices.filter { index in
                index != orphanIndex
                    && normalizedHistoryIdentifier(messages[index].itemId) == canonicalItemID
            }
            let orphanSourceKey = normalizedHistoryIdentifier(messages[orphanIndex].sourceItemKey)
            let turnIsActive = activeThreadIDs.contains(sourceKey.threadId)
                ? (activeTurnIDs?.contains(sourceKey.turnId) ?? true)
                : runningThreadIDs.contains(sourceKey.threadId)
            let hasExactSourceProof = !sourceKey.sourceItemKey.isEmpty
                && orphanSourceKey == sourceKey.sourceItemKey
            if turnIsActive, !hasExactSourceProof {
                guard let earliestCanonicalOrderIndex = canonicalDuplicateIndices
                    .map({ messages[$0].orderIndex })
                    .min(),
                      messages[orphanIndex].orderIndex < earliestCanonicalOrderIndex else {
                    continue
                }
            }
            let duplicateMessageIDs = canonicalDuplicateIndices.map { messages[$0].id }
            guard duplicateMessageIDs.allSatisfy({ !claimedMessageIDs.contains($0) }) else {
                continue
            }

            claimedMessageIDs.insert(messages[orphanIndex].id)
            claimedMessageIDs.formUnion(duplicateMessageIDs)
            repairs.append((
                orphanMessageId: messages[orphanIndex].id,
                duplicateMessageIds: duplicateMessageIDs,
                canonical: canonical
            ))
        }

        for repair in repairs {
            guard let orphanIndex = messages.firstIndex(where: { $0.id == repair.orphanMessageId }),
                  let canonicalItemID = normalizedHistoryIdentifier(repair.canonical.itemId) else {
                continue
            }

            let preservedOrderIndex = messages[orphanIndex].orderIndex
            var repaired = reconcileExistingMessage(
                messages[orphanIndex],
                with: repair.canonical,
                activeThreadIDs: activeThreadIDs,
                activeTurnIDs: activeTurnIDs,
                runningThreadIDs: runningThreadIDs
            )
            for duplicateMessageID in repair.duplicateMessageIds {
                guard let duplicate = messages.first(where: { $0.id == duplicateMessageID }) else {
                    continue
                }
                if repaired.attachments.isEmpty, !duplicate.attachments.isEmpty {
                    repaired.attachments = duplicate.attachments
                }
            }
            repaired.itemId = canonicalItemID
            if let canonicalSourceKey = normalizedHistoryIdentifier(repair.canonical.sourceItemKey) {
                repaired.sourceItemKey = canonicalSourceKey
            }
            repaired.orderIndex = preservedOrderIndex
            messages[orphanIndex] = repaired

            let canonicalOrder = repair.duplicateMessageIds.compactMap {
                canonicalOrderByMessageID[$0]
            }.min()
            if let canonicalOrder {
                canonicalOrderByMessageID[repair.orphanMessageId] = canonicalOrder
            }
            for duplicateMessageID in repair.duplicateMessageIds {
                canonicalOrderByMessageID.removeValue(forKey: duplicateMessageID)
            }

            let duplicateIndices = repair.duplicateMessageIds.compactMap { duplicateMessageID in
                messages.firstIndex(where: { $0.id == duplicateMessageID })
            }
            for duplicateIndex in duplicateIndices.sorted(by: >) {
                messages.remove(at: duplicateIndex)
            }
        }
    }

    // Keeps running-thread reopen bounded to the recent transcript tail so A/B switching
    // does not repeatedly reconcile the entire chat while output is still streaming.
    nonisolated static func mergeRecentHistoryWindow(
        _ existing: [CodexMessage],
        _ history: [CodexMessage],
        activeThreadIDs: Set<String>,
        activeTurnIDs: Set<String>? = nil,
        runningThreadIDs: Set<String>,
        windowSize: Int
    ) throws -> [CodexMessage] {
        let normalizedWindowSize = max(1, windowSize)
        guard !existing.isEmpty,
              shouldPreferRecentHistoryWindow(
                existingCount: existing.count,
                historyCount: history.count,
                windowSize: normalizedWindowSize
              ) else {
            return try mergeHistoryMessages(
                existing,
                history,
                activeThreadIDs: activeThreadIDs,
                activeTurnIDs: activeTurnIDs,
                runningThreadIDs: runningThreadIDs
            )
        }

        let prefixCount = max(existing.count - normalizedWindowSize, 0)
        let stablePrefix = Array(existing.prefix(prefixCount))
        let recentExisting = Array(existing.suffix(normalizedWindowSize))
        let recentHistory = Array(history.suffix(normalizedWindowSize))
        let mergedTail = try mergeHistoryMessages(
            recentExisting,
            recentHistory,
            activeThreadIDs: activeThreadIDs,
            activeTurnIDs: activeTurnIDs,
            runningThreadIDs: runningThreadIDs
        )
        let boundaryOverlapKeys = Set(stablePrefix.suffix(32).map(Self.historyMessageKey))
        let filteredTail = mergedTail.filter { !boundaryOverlapKeys.contains(historyMessageKey(for: $0)) }
        return stablePrefix + filteredTail
    }

    func decodeHistoryTimestamp(from object: [String: JSONValue]) -> Date? {
        let numericKeys = [
            "createdAt",
            "created_at",
            "startedAt",
            "started_at",
            "completedAt",
            "completed_at",
            "endedAt",
            "ended_at",
            "timestamp",
            "time",
            "updatedAt",
            "updated_at",
        ]

        for key in numericKeys {
            if let value = object[key]?.doubleValue {
                if let date = trustedHistoryDate(CodexTimestampParser.decodeUnixTimestamp(value)) {
                    return date
                }
            }
            if let value = object[key]?.intValue {
                if let date = trustedHistoryDate(CodexTimestampParser.decodeUnixTimestamp(Double(value))) {
                    return date
                }
            }
            if let value = object[key]?.stringValue {
                if let parsed = trustedHistoryDate(CodexTimestampParser.parseString(value)) {
                    return parsed
                }
            }
        }

        return nil
    }

    func decodeHistoryTimeZoneIdentifier(from object: [String: JSONValue]) -> String? {
        for key in ["timeZoneIdentifier", "timezoneIdentifier", "timeZone", "timezone", "time_zone"] {
            guard let rawValue = object[key]?.stringValue else {
                continue
            }
            let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty,
               TimeZone(identifier: trimmedValue) != nil {
                return trimmedValue
            }
        }
        return nil
    }

    func trustedHistoryDate(_ date: Date?) -> Date? {
        guard let date,
              CodexTimestampParser.isTrustworthyServerDate(date) else {
            return nil
        }
        return date
    }

    func parseHistoryDateString(_ value: String) -> Date? {
        CodexTimestampParser.parseString(value)
    }

    func historyTurnID(from turnObject: [String: JSONValue]) -> String? {
        firstNonEmptyString([
            turnObject["id"]?.stringValue,
            turnObject["turnId"]?.stringValue,
            turnObject["turn_id"]?.stringValue,
        ])
    }

    func reconcileExistingMessage(_ localMessage: CodexMessage, with serverMessage: CodexMessage) -> CodexMessage {
        let activeThreadIDs = Set(activeTurnIdByThread.keys)
        let activeTurnIDs = Set(activeTurnIdByThread.values)
        let runningIDs = runningThreadIDs
        return Self.reconcileExistingMessage(
            localMessage,
            with: serverMessage,
            activeThreadIDs: activeThreadIDs,
            activeTurnIDs: activeTurnIDs,
            runningThreadIDs: runningIDs
        )
    }

    nonisolated static func reconcileExistingMessage(
        _ localMessage: CodexMessage,
        with serverMessage: CodexMessage,
        activeThreadIDs: Set<String>,
        activeTurnIDs: Set<String>? = nil,
        runningThreadIDs: Set<String>
    ) -> CodexMessage {
        var value = localMessage
        let threadIsActive = activeThreadIDs.contains(localMessage.threadId) || runningThreadIDs.contains(localMessage.threadId)
        let normalizedLocalTurnID = normalizedHistoryIdentifier(localMessage.turnId)
        let normalizedServerTurnID = normalizedHistoryIdentifier(serverMessage.turnId)
        let threadHasExplicitActiveTurn = activeThreadIDs.contains(localMessage.threadId)
        let turnIsActive: Bool
        if threadHasExplicitActiveTurn, let activeTurnIDs {
            turnIsActive = normalizedLocalTurnID.map { activeTurnIDs.contains($0) } == true
                || normalizedServerTurnID.map { activeTurnIDs.contains($0) } == true
        } else {
            // turn/started may not provide a usable turn id. In that case the
            // per-thread running fallback still owns the live presentation.
            turnIsActive = threadIsActive
        }
        let preservesRunningPresentation = threadIsActive
            && turnIsActive
            && localMessage.isStreaming
            && (
                localMessage.turnId == nil
                || serverMessage.turnId == nil
                || localMessage.turnId == serverMessage.turnId
            )

        if value.deliveryState == .pending {
            value.deliveryState = .confirmed
        }
        if value.sourceItemKey == nil {
            value.sourceItemKey = serverMessage.sourceItemKey
        }

        if CodexTimestampParser.isTrustworthyServerDate(serverMessage.createdAt),
           abs(value.createdAt.timeIntervalSince(serverMessage.createdAt)) > 0.5 {
            value.createdAt = serverMessage.createdAt
        }

        if value.turnId == nil {
            value.turnId = serverMessage.turnId
        } else if let serverTurnId = normalizedServerTurnID,
                  isProvisionalHistoryTurnIdentifier(value.turnId),
                  !isProvisionalHistoryTurnIdentifier(serverTurnId) {
            value.turnId = serverTurnId
        }
        let localItemId = normalizedHistoryIdentifier(value.itemId)
        let serverItemId = normalizedHistoryIdentifier(serverMessage.itemId)
        let shouldUpgradeSyntheticUserItemId = value.role == .user
            && serverItemId != nil
            && (
                isSyntheticDesktopUserItemIdentifier(localItemId)
                    || localItemId.map { CodexSyntheticIdentifiers.isMirrorMintedItemID($0) } == true
            )
            && !isSyntheticDesktopUserItemIdentifier(serverItemId)
            && serverItemId.map { CodexSyntheticIdentifiers.isMirrorMintedItemID($0) } != true
        let shouldAttachMissingItemId = localItemId == nil
        let shouldUpgradeProvisionalAssistantItemId = value.role == .assistant
            && serverItemId != nil
            && localItemId != serverItemId
            && localItemId.map { CodexSyntheticIdentifiers.isMirrorMintedItemID($0) } == true
            && serverItemId.map { CodexSyntheticIdentifiers.isMirrorMintedItemID($0) } != true
        let shouldRebindRunningAssistantItem = preservesRunningPresentation
            && value.role == .assistant
            && localMessage.isStreaming
            && serverItemId != nil
            && localItemId != serverItemId
            && !hasStableAssistantIdentity(localItemId)
        let shouldUpgradeProvisionalSystemItemId = value.role == .system
            && serverItemId != nil
            && localItemId != serverItemId
            && isProvisionalSystemItemIdentifier(localItemId)
        let shouldRebindProgressPlanItemId = value.role == .system
            && value.kind == .plan
            && value.resolvedPlanPresentation == .progress
            && serverMessage.resolvedPlanPresentation == .progress
            && serverItemId != nil
            && localItemId != serverItemId
        if shouldAttachMissingItemId
            || shouldUpgradeSyntheticUserItemId
            || shouldUpgradeProvisionalAssistantItemId
            || shouldRebindRunningAssistantItem
            || shouldUpgradeProvisionalSystemItemId
            || shouldRebindProgressPlanItemId
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
        if let assistantPhase = serverMessage.assistantPhase {
            value.assistantPhase = assistantPhase
        }
        if let planState = serverMessage.planState {
            value.planState = planState
        }
        if let planPresentation = serverMessage.planPresentation {
            value.planPresentation = planPresentation
        }
        if serverMessage.resolvedPlanPresentation == .progress {
            // A previously misclassified todo-list can persist a parsed
            // "Planning..." proposal. Canonical progress state must clear it.
            value.proposedPlan = nil
        } else if let proposedPlan = serverMessage.proposedPlan {
            value.proposedPlan = proposedPlan
        }
        if let subagentAction = serverMessage.subagentAction {
            value.subagentAction = subagentAction
        }
        if let structuredUserInputRequest = serverMessage.structuredUserInputRequest {
            value.structuredUserInputRequest = structuredUserInputRequest
        }
        if value.attachments.isEmpty && !serverMessage.attachments.isEmpty {
            value.attachments = serverMessage.attachments
        }
        if value.role == .user {
            if value.fileMentions.isEmpty && !serverMessage.fileMentions.isEmpty {
                value.fileMentions = serverMessage.fileMentions
            }
            if value.skillMentions.isEmpty && !serverMessage.skillMentions.isEmpty {
                value.skillMentions = serverMessage.skillMentions
            }
            if value.pluginMentions.isEmpty && !serverMessage.pluginMentions.isEmpty {
                value.pluginMentions = serverMessage.pluginMentions
            }
            if shouldPreferIncomingUserPresentationText(existing: value, incoming: serverMessage) {
                value.text = serverMessage.text
            }
        }

        if value.role == .assistant {
            if hasMeaningfulHistoryText(serverMessage.text) {
                if preservesRunningPresentation {
                    if assistantHistoryIdentityAllowsRunningReconcile(
                        localMessage: localMessage,
                        serverMessage: serverMessage
                    ) {
                        value.text = mergeAssistantRunningSnapshotText(
                            existingText: value.text,
                            incomingText: serverMessage.text
                        )
                    }
                } else {
                    value.text = serverMessage.text
                }
            }
            value.isStreaming = preservesRunningPresentation
                ? (localMessage.isStreaming || serverMessage.isStreaming)
                : false
        } else if value.role == .system {
            if hasMeaningfulHistoryText(serverMessage.text) {
                value.text = preservesRunningPresentation && localMessage.isStreaming
                    ? mergeStreamingSnapshotText(existingText: value.text, incomingText: serverMessage.text)
                    : serverMessage.text
            }
            value.isStreaming = preservesRunningPresentation
                ? (localMessage.isStreaming || serverMessage.isStreaming)
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
            message.role == .user ? userSemanticHistoryTextKey(for: message) : historyTextKey(for: message.text),
            attachmentSignature(for: message.attachments),
        ].joined(separator: "|")
    }

    nonisolated private static let historyLargeTextByteLimit = 64_000
    nonisolated private static let historySmallWhitespaceScanByteLimit = 512
    nonisolated private static let historyInlineImagePayloadStorageByteLimit = 12_000_000
    nonisolated private static let identitylessUserHistoryEchoWindow: TimeInterval = 2

    nonisolated static func normalizedMessageText(_ text: String) -> String {
        guard text.utf8.count <= Self.historyLargeTextByteLimit else {
            return text
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func hasMeaningfulHistoryText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.utf8.count <= Self.historySmallWhitespaceScanByteLimit else { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func historyTextsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count <= Self.historyLargeTextByteLimit,
              rhs.utf8.count <= Self.historyLargeTextByteLimit else {
            return lhs == rhs
        }

        if normalizedMessageText(lhs) == normalizedMessageText(rhs) {
            return true
        }

        let lhsKey = canonicalUserMessageKey(text: lhs)
        let rhsKey = canonicalUserMessageKey(text: rhs)
        return lhsKey.hasMentions && lhsKey == rhsKey
    }

    nonisolated static func userMessagesMatchForHistory(_ lhs: CodexMessage, _ rhs: CodexMessage) -> Bool {
        userMessageMatchesTextForHistory(
            lhs,
            text: rhs.text,
            skillMentions: rhs.skillMentions,
            pluginMentions: rhs.pluginMentions
        )
    }

    nonisolated static func userMessageMatchesTextForHistory(
        _ message: CodexMessage,
        text: String,
        skillMentions: [String] = [],
        pluginMentions: [String] = []
    ) -> Bool {
        if historyTextsMatch(message.text, text) {
            return true
        }

        guard message.text.utf8.count <= Self.historyLargeTextByteLimit,
              text.utf8.count <= Self.historyLargeTextByteLimit else {
            return false
        }

        let lhsKey = canonicalUserMessageKey(
            text: message.text,
            skillMentions: message.skillMentions,
            pluginMentions: message.pluginMentions
        )
        let rhsKey = canonicalUserMessageKey(
            text: text,
            skillMentions: skillMentions,
            pluginMentions: pluginMentions
        )
        return lhsKey.hasMentions && lhsKey == rhsKey
    }

    nonisolated static func userSemanticHistoryTextKey(for message: CodexMessage) -> String {
        let key = canonicalUserMessageKey(
            text: message.text,
            skillMentions: message.skillMentions,
            pluginMentions: message.pluginMentions
        )
        guard key.hasMentions else {
            return historyTextKey(for: message.text)
        }

        return [
            key.text,
            "skills:\(key.skillMentions.sorted().joined(separator: ","))",
            "plugins:\(key.pluginMentions.sorted().joined(separator: ","))",
        ].joined(separator: "|")
    }

    private nonisolated static func canonicalUserMessageKey(
        text: String,
        skillMentions: [String] = [],
        pluginMentions: [String] = []
    ) -> UserMessageSemanticKey {
        var normalizedText = normalizedMessageText(text)
        var skillSet = Set(skillMentions.map(normalizedUserMentionName).filter { !$0.isEmpty })
        var pluginSet = Set(pluginMentions.map(normalizedUserMentionName).filter { !$0.isEmpty })

        let extracted = extractInlineUserMentionTokens(from: normalizedText)
        normalizedText = extracted.text
        skillSet.formUnion(extracted.skillMentions)
        pluginSet.formUnion(extracted.pluginMentions)

        for skill in skillSet {
            normalizedText = removingBoundedUserMentionPhrase("$\(skill)", from: normalizedText)
            normalizedText = removingBoundedUserMentionPhrase("/\(skill)", from: normalizedText)
            normalizedText = removingBoundedUserMentionPhrase(displayNameForUserMention(skill), from: normalizedText)
        }
        for plugin in pluginSet {
            normalizedText = removingBoundedUserMentionPhrase("@\(plugin)", from: normalizedText)
        }

        return UserMessageSemanticKey(
            text: canonicalUserMessageBodyText(normalizedText),
            skillMentions: skillSet,
            pluginMentions: pluginSet
        )
    }

    nonisolated static func normalizedUserMentionName(_ rawName: String) -> String {
        rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private nonisolated static func extractInlineUserMentionTokens(
        from text: String
    ) -> (text: String, skillMentions: Set<String>, pluginMentions: Set<String>) {
        guard text.utf8.count <= Self.historyLargeTextByteLimit,
              let regex = try? NSRegularExpression(
                pattern: #"(?<!\S)([$/@])([A-Za-z0-9][A-Za-z0-9._-]*)(?=[\s,.;:!?)\]}>]|$)"#
              ) else {
            return (text, [], [])
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var working = text
        var skills: Set<String> = []
        var plugins: Set<String> = []

        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let triggerRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text),
                  let fullRange = Range(match.range, in: working) else {
                continue
            }

            let trigger = String(text[triggerRange])
            let name = normalizedUserMentionName(String(text[nameRange]))
            guard !name.isEmpty else { continue }

            if trigger == "$" || trigger == "/" {
                skills.insert(name)
            } else if trigger == "@" {
                plugins.insert(name)
            }
            working.replaceSubrange(fullRange, with: "")
        }

        return (working, skills, plugins)
    }

    private nonisolated static func removingBoundedUserMentionPhrase(_ phrase: String, from text: String) -> String {
        let normalizedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPhrase.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"(?<!\S)"# + NSRegularExpression.escapedPattern(for: normalizedPhrase) + #"(?=[\s,.;:!?)\]}>]|$)"#,
                options: [.caseInsensitive]
              ) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    private nonisolated static func displayNameForUserMention(_ rawName: String) -> String {
        let parts = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: true) { $0 == "-" || $0 == "_" }
            .map { part -> String in
                let token = String(part)
                return token.prefix(1).uppercased() + token.dropFirst().lowercased()
            }
        return parts.isEmpty ? rawName : parts.joined(separator: " ")
    }

    private nonisolated static func canonicalUserMessageBodyText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    nonisolated static func shouldPreferIncomingUserPresentationText(
        existing: CodexMessage,
        incoming: CodexMessage
    ) -> Bool {
        guard existing.role == .user,
              incoming.role == .user,
              hasMeaningfulHistoryText(incoming.text),
              userMessagesMatchForHistory(existing, incoming) else {
            return false
        }

        let existingHasMentionMetadata = !existing.skillMentions.isEmpty || !existing.pluginMentions.isEmpty
        let incomingHasMentionMetadata = !incoming.skillMentions.isEmpty || !incoming.pluginMentions.isEmpty
        return !existingHasMentionMetadata && incomingHasMentionMetadata
    }

    // History keys must not embed megabyte-scale message bodies, but they still need a
    // full-text digest so pagination overlap does not collapse distinct long rows.
    nonisolated static func historyTextKey(for text: String) -> String {
        let normalized = normalizedMessageText(text)
        guard normalized.utf8.count > Self.historyLargeTextByteLimit else {
            return normalized
        }
        return "large:\(stableHistoryTextFingerprint(for: normalized))"
    }

    nonisolated static func stableHistoryTextFingerprint(for text: String) -> String {
        return CodexTextContentFingerprint.cacheKey(for: text)
    }

    // Mirrors the bridge's source-neutral alias for an event_msg/response_item pair. Normal
    // app-server history omits remodexSourceItemKey, so deriving it here preserves exact replay
    // identity without falling back to unsafe turn + text matching on partial history windows.
    nonisolated static func remodexAssistantSourceItemKey(turnId: String, text: String) -> String? {
        guard let normalizedTurnId = normalizedHistoryIdentifier(turnId) else {
            return nil
        }
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(normalizedText.utf8))
        let textHash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(normalizedTurnId):\(textHash)"
    }

    nonisolated static func normalizedHistoryIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Finds the contiguous timeline block owned by one turn; turnless artifact
    // rows inside that range may be rebound without stealing adjacent turns.
    nonisolated static func contiguousTurnBlockRange(
        in messages: [CodexMessage],
        turnId: String
    ) -> Range<Int>? {
        guard let startIndex = messages.firstIndex(where: { $0.turnId == turnId }) else {
            return nil
        }
        let endIndex = messages.indices.first { index in
            guard index > startIndex else {
                return false
            }
            let message = messages[index]
            if let candidateTurnId = message.turnId, !candidateTurnId.isEmpty {
                return candidateTurnId != turnId
            }
            // A user prompt without a turn id still marks a boundary: the next
            // turn's opener lands before turn/started tags it, and this turn's
            // artifacts must not reach past it (a mid-turn steer closing the
            // block early costs at most a transient duplicate, never a steal).
            return message.role == .user
        } ?? messages.endIndex
        return startIndex..<endIndex
    }

    // Single rule for claiming a TURNLESS file-change row into a turn, shared
    // by live reconciliation (Messages) and history merge: inside the turn's
    // contiguous block the row is claimable; before the turn has any anchored
    // row, only a lone bootstrap row above any user boundary may bind. A
    // transient duplicate is the accepted failure mode — stealing an adjacent
    // turn's table is not.
    nonisolated static func turnlessFileChangeRowIsClaimable(
        in messages: [CodexMessage],
        candidateIndex: Int,
        turnId: String,
        turnBlockRange: Range<Int>?
    ) -> Bool {
        guard messages.indices.contains(candidateIndex) else {
            return false
        }
        if let turnBlockRange {
            return turnBlockRange.contains(candidateIndex)
        }

        // Once any turn is anchored, a lone turnless row is some finished
        // turn's tail artifact; rebinding it to a newer turn stole tables
        // (Desktop-driven turns mirror their user row late, so "no user row
        // yet" proves nothing).
        guard !messages.contains(where: {
            Self.normalizedHistoryIdentifier($0.turnId) != nil
        }) else {
            return false
        }

        // A user prompt after the candidate marks a turn boundary: the row
        // belongs to the finished turn above it, not to this one.
        guard !messages[(candidateIndex + 1)...].contains(where: { $0.role == .user }) else {
            return false
        }

        let candidate = messages[candidateIndex]
        let bootstrapRows = messages.filter {
            $0.role == .system
                && $0.kind == .fileChange
                && Self.normalizedHistoryIdentifier($0.turnId) == nil
        }
        return bootstrapRows.count == 1 && bootstrapRows[0].id == candidate.id
    }

    // Desktop-projected snapshots synthesize turn ids and prompt item ids when
    // the raw Desktop state lacks the real identifiers (see
    // CodexSyntheticIdentifiers). Those ids are provisional: the same prompt
    // can also arrive under its real app-server identity, so synthetic ids
    // must merge with the real row (and upgrade to its identity) instead of
    // forming a second row.
    nonisolated static func isSyntheticDesktopTurnIdentifier(_ turnId: String?) -> Bool {
        guard let turnId = normalizedHistoryIdentifier(turnId) else {
            return false
        }
        return CodexSyntheticIdentifiers.isProjectedDesktopTurnID(turnId)
    }

    nonisolated static func isProvisionalHistoryTurnIdentifier(_ turnId: String?) -> Bool {
        guard let turnId = normalizedHistoryIdentifier(turnId) else {
            return false
        }
        return CodexSyntheticIdentifiers.isProjectedDesktopTurnID(turnId)
            || CodexSyntheticIdentifiers.isBridgeMintedTurnID(turnId)
    }

    nonisolated static func isSyntheticDesktopUserItemIdentifier(_ itemId: String?) -> Bool {
        guard let itemId = normalizedHistoryIdentifier(itemId) else {
            return false
        }
        return CodexSyntheticIdentifiers.isProjectedDesktopUserItemID(itemId)
    }

    nonisolated static func isProvisionalUserItemIdentifier(_ itemId: String?) -> Bool {
        guard let itemId = normalizedHistoryIdentifier(itemId) else {
            return true
        }
        return CodexSyntheticIdentifiers.isProjectedDesktopUserItemID(itemId)
            || CodexSyntheticIdentifiers.isMirrorMintedItemID(itemId)
    }

    // Rollout mirrors tag reasoning rows with synthetic "rollout-*" item ids
    // and live streams may use turn-scoped placeholders; both are provisional
    // and must merge with the real reasoning identity of the same turn.
    nonisolated static func isProvisionalThinkingIdentifier(_ itemId: String?) -> Bool {
        guard let itemId = normalizedHistoryIdentifier(itemId) else {
            return true
        }
        return CodexSyntheticIdentifiers.isMirrorMintedItemID(itemId)
    }

    nonisolated static func isProvisionalSystemItemIdentifier(_ itemId: String?) -> Bool {
        guard let itemId = normalizedHistoryIdentifier(itemId) else {
            return true
        }
        return CodexSyntheticIdentifiers.isMirrorMintedItemID(itemId)
            || itemId.hasPrefix("remodex-jsonl-")
    }

    nonisolated static func exactHistoryItemIdentityAllowsReconcile(
        _ candidate: CodexMessage,
        with message: CodexMessage,
        itemId: String
    ) -> Bool {
        let needsSemanticProof = CodexSyntheticIdentifiers.isJSONLLineFallbackItemID(itemId)
            || (
                candidate.role == .user
                    && CodexSyntheticIdentifiers.isProjectedDesktopUserItemID(itemId)
            )
        guard needsSemanticProof else {
            return true
        }
        if candidate.role == .user {
            return userMessagesMatchForHistory(candidate, message)
                && userMessageMetadataLooksCompatible(
                    localMessage: candidate,
                    serverMessage: message,
                    allowAttachmentCountFallback: candidate.deliveryState == .pending
                )
        }
        let candidateText = normalizedMessageText(candidate.text)
        let candidateTurnID = normalizedHistoryIdentifier(candidate.turnId)
        let incomingTurnID = normalizedHistoryIdentifier(message.turnId)
        return !candidateText.isEmpty
            && candidateText == normalizedMessageText(message.text)
            && candidateTurnID == incomingTurnID
            && candidateTurnID.map { !isProvisionalHistoryTurnIdentifier($0) } == true
    }

    nonisolated static func lineFallbackIdentityAllowsTurnScopedReconcile(
        _ candidate: CodexMessage,
        with message: CodexMessage
    ) -> Bool {
        let candidateItemID = normalizedHistoryIdentifier(candidate.itemId)
        let incomingItemID = normalizedHistoryIdentifier(message.itemId)
        let hasLineFallback = candidateItemID
            .map { CodexSyntheticIdentifiers.isJSONLLineFallbackItemID($0) } == true
            || incomingItemID
                .map { CodexSyntheticIdentifiers.isJSONLLineFallbackItemID($0) } == true
        guard hasLineFallback else {
            return true
        }
        let candidateTurnID = normalizedHistoryIdentifier(candidate.turnId)
        let incomingTurnID = normalizedHistoryIdentifier(message.turnId)
        return candidateTurnID == incomingTurnID
            && candidateTurnID.map { !isProvisionalHistoryTurnIdentifier($0) } == true
    }

    // Turn identities are mergeable when either side lacks a real turn id;
    // two distinct real turn ids stay separate so intentionally repeated
    // sends keep one row per turn.
    nonisolated static func mirroredUserTurnIdentityAllowsMerge(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsTurnId = normalizedHistoryIdentifier(lhs),
              let rhsTurnId = normalizedHistoryIdentifier(rhs) else {
            return true
        }
        if lhsTurnId == rhsTurnId {
            return true
        }
        return isProvisionalHistoryTurnIdentifier(lhsTurnId)
            || isProvisionalHistoryTurnIdentifier(rhsTurnId)
    }

    // Mirrors t3code's provider-message identity as closely as the mobile schema allows.
    nonisolated static func stableAssistantMessageID(threadId: String, turnId: String?, itemId: String?) -> String? {
        guard let itemId = normalizedHistoryIdentifier(itemId) else {
            return nil
        }
        return "assistant:\(threadId):item:\(itemId)"
    }

    // Real provider item ids must not be rebound to a different history item mid-stream.
    nonisolated static func hasStableAssistantIdentity(_ itemId: String?) -> Bool {
        guard let itemId = normalizedHistoryIdentifier(itemId) else {
            return false
        }
        return !CodexSyntheticIdentifiers.isMirrorMintedItemID(itemId)
    }

    // Source aliases are semantic bridge hints, not provider identities. They may collide when
    // two real assistant items intentionally contain the same text, so only use them to bridge
    // one mirror identity and one provider identity (or the exact same item id).
    nonisolated static func sourceItemIdentityAllowsReconcile(
        _ existingItemId: String?,
        _ incomingItemId: String?
    ) -> Bool {
        let existing = normalizedHistoryIdentifier(existingItemId)
        let incoming = normalizedHistoryIdentifier(incomingItemId)
        guard let existing, let incoming else {
            return false
        }
        if existing == incoming {
            return true
        }
        return CodexSyntheticIdentifiers.isMirrorMintedItemID(existing)
            != CodexSyntheticIdentifiers.isMirrorMintedItemID(incoming)
    }

    // Running assistant rows may absorb history only when the provider item identity agrees.
    nonisolated static func assistantHistoryIdentityAllowsRunningReconcile(
        localMessage: CodexMessage,
        serverMessage: CodexMessage
    ) -> Bool {
        let localItemId = normalizedHistoryIdentifier(localMessage.itemId)
        let serverItemId = normalizedHistoryIdentifier(serverMessage.itemId)

        if let localItemId, let serverItemId {
            return localItemId == serverItemId || !hasStableAssistantIdentity(localItemId)
        }

        if let localItemId, serverItemId == nil {
            return !hasStableAssistantIdentity(localItemId)
        }

        return true
    }

    // History can revisit an assistant turn multiple times while local rows still
    // have provisional identity. Only reconcile by text when the candidate is unique.
    nonisolated static func uniqueAssistantHistoryTextMergeIndex(
        in messages: [CodexMessage],
        message: CodexMessage,
        turnId: String
    ) -> Int? {
        guard message.text.utf8.count <= Self.historyLargeTextByteLimit else {
            return nil
        }
        let normalizedText = normalizedMessageText(message.text)
        guard !normalizedText.isEmpty else {
            return nil
        }

        let normalizedTurnId = normalizedHistoryIdentifier(turnId) ?? turnId
        let candidates = messages.indices.filter { index in
            let candidate = messages[index]
            let candidateTurnId = normalizedHistoryIdentifier(candidate.turnId)
            let hasSourceLocalLineIdentity = normalizedHistoryIdentifier(candidate.itemId)
                .map { CodexSyntheticIdentifiers.isJSONLLineFallbackItemID($0) } == true
                || normalizedHistoryIdentifier(message.itemId)
                    .map { CodexSyntheticIdentifiers.isJSONLLineFallbackItemID($0) } == true
            if hasSourceLocalLineIdentity,
               isProvisionalHistoryTurnIdentifier(candidateTurnId)
                || isProvisionalHistoryTurnIdentifier(normalizedTurnId) {
                return false
            }
            return candidate.role == .assistant
                && (candidateTurnId == nil || candidateTurnId == normalizedTurnId)
                && normalizedMessageText(candidate.text) == normalizedText
        }

        guard candidates.count == 1,
              let index = candidates.last else {
            return nil
        }

        let localItemId = normalizedHistoryIdentifier(messages[index].itemId)
        let incomingItemId = normalizedHistoryIdentifier(message.itemId)
        if let localItemId, let incomingItemId, localItemId != incomingItemId,
           hasStableAssistantIdentity(localItemId),
           hasStableAssistantIdentity(incomingItemId) {
            return nil
        }

        return index
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
        return !CodexSyntheticIdentifiers.isPlaceholderItemID(value, kind: .toolActivity)
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
        guard text.utf8.count <= Self.historyLargeTextByteLimit else {
            return []
        }
        return normalizedMessageText(text)
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

        guard existingText.utf8.count <= Self.historyLargeTextByteLimit,
              incomingText.utf8.count <= Self.historyLargeTextByteLimit else {
            return incomingText.utf8.count > existingText.utf8.count ? incomingText : existingText
        }

        if existingText.hasSuffix(incomingText) {
            return existingText
        }

        if incomingText.count > existingText.count, incomingText.hasPrefix(existingText) {
            let suffix = incomingText.dropFirst(existingText.count)
            if !existingText.isEmpty, suffix.range(of: existingText) != nil {
                return existingText
            }
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

    // Assistant history snapshots can be flattened across messages during reconnect.
    // Keep the live bubble anchored to live deltas unless history is an exact/stale match.
    nonisolated static func mergeAssistantRunningSnapshotText(existingText: String, incomingText: String) -> String {
        if existingText.isEmpty {
            return incomingText
        }

        if incomingText == existingText {
            return existingText
        }

        guard existingText.utf8.count <= Self.historyLargeTextByteLimit,
              incomingText.utf8.count <= Self.historyLargeTextByteLimit else {
            return existingText
        }

        if existingText.hasSuffix(incomingText) {
            return existingText
        }

        if existingText.count > incomingText.count, existingText.hasPrefix(incomingText) {
            return existingText
        }

        return existingText
    }

    // Closed-turn snapshots are only allowed to replace the visible assistant reply
    // when they are clearly the same message and at least as complete.
    nonisolated static func shouldReplaceClosedAssistantMessage(
        _ localMessage: CodexMessage,
        with serverMessage: CodexMessage
    ) -> Bool {
        guard localMessage.text.utf8.count <= Self.historyLargeTextByteLimit,
              serverMessage.text.utf8.count <= Self.historyLargeTextByteLimit else {
            guard hasMeaningfulHistoryText(serverMessage.text) else {
                return false
            }
            return !hasMeaningfulHistoryText(localMessage.text)
                || localMessage.text == serverMessage.text
        }

        let localText = normalizedMessageText(localMessage.text)
        let serverText = normalizedMessageText(serverMessage.text)

        guard !serverText.isEmpty else {
            return false
        }

        if localText.isEmpty || localText == serverText {
            return true
        }

        if localText.count > serverText.count, localText.hasPrefix(serverText) {
            return false
        }

        if looksLikeFlattenedAssistantReplacement(localText: localText, serverText: serverText) {
            return false
        }

        return true
    }

    // Rejects closed assistant replacements that look like multiple assistant rows
    // collapsed into one payload instead of a single canonical final message.
    nonisolated static func looksLikeFlattenedAssistantReplacement(localText: String, serverText: String) -> Bool {
        if serverText.hasPrefix(localText) {
            let suffix = serverText.dropFirst(localText.count)
            return suffix.range(of: "\n\n") != nil || suffix.range(of: localText) != nil
        }

        if let range = serverText.range(of: localText),
           range.lowerBound != serverText.startIndex {
            return true
        }

        return serverText.range(of: "\n\n") != nil
    }

    nonisolated static func attachmentSignature(for attachments: [CodexImageAttachment]) -> String {
        attachments
            .map(\.stableIdentityKey)
            .joined(separator: "|")
    }

    nonisolated static func fileMentionsSignature(for fileMentions: [String]) -> String {
        fileMentions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "|")
    }

    nonisolated static func userMessageMetadataLooksCompatible(
        localMessage: CodexMessage,
        serverMessage: CodexMessage,
        allowAttachmentCountFallback: Bool = false
    ) -> Bool {
        let localFileMentions = fileMentionsSignature(for: localMessage.fileMentions)
        let serverFileMentions = fileMentionsSignature(for: serverMessage.fileMentions)
        if !localFileMentions.isEmpty,
           !serverFileMentions.isEmpty,
           localFileMentions != serverFileMentions {
            return false
        }

        let localAttachments = attachmentSignature(for: localMessage.attachments)
        let serverAttachments = attachmentSignature(for: serverMessage.attachments)
        if !localAttachments.isEmpty,
           !serverAttachments.isEmpty,
           localAttachments != serverAttachments {
            // Pending image sends can return with a different server attachment identity
            // even though the user row is the same prompt/image count.
            return allowAttachmentCountFallback
                && localMessage.attachments.count == serverMessage.attachments.count
        }

        return true
    }

    nonisolated static func shouldReconcileUserHistoryMessage(
        _ candidate: CodexMessage,
        with message: CodexMessage,
        turnId: String
    ) -> Bool {
        guard candidate.role == .user,
              candidate.deliveryState != .failed,
              userMessagesMatchForHistory(candidate, message) else {
            return false
        }

        let candidateTurnId = normalizedHistoryIdentifier(candidate.turnId)
        let allowsAttachmentCountFallback = candidate.deliveryState == .pending
            || candidateTurnId == turnId
        guard userMessageMetadataLooksCompatible(
            localMessage: candidate,
            serverMessage: message,
            allowAttachmentCountFallback: allowsAttachmentCountFallback
        ) else {
            return false
        }
        return candidateTurnId == nil
            || candidateTurnId == turnId
            || isProvisionalHistoryTurnIdentifier(candidateTurnId)
            || isProvisionalHistoryTurnIdentifier(turnId)
    }

    nonisolated static func shouldReconcilePendingUserHistoryMessage(
        _ candidate: CodexMessage,
        with message: CodexMessage
    ) -> Bool {
        guard candidate.role == .user,
              candidate.deliveryState == .pending,
              userMessagesMatchForHistory(candidate, message),
              userMessageMetadataLooksCompatible(
                localMessage: candidate,
                serverMessage: message,
                allowAttachmentCountFallback: true
              ) else {
            return false
        }

        return true
    }

    nonisolated static func uniqueUserHistoryMergeIndex(
        in merged: [CodexMessage],
        message: CodexMessage,
        turnId: String
    ) -> Int? {
        let matchingIndices = merged.indices.filter { index in
            shouldReconcileUserHistoryMessage(merged[index], with: message, turnId: turnId)
        }

        if matchingIndices.count == 1 {
            return matchingIndices[0]
        }

        // If a previous reopen already persisted an epoch-timestamp echo, bind new
        // history to the real-dated row so the duplicate does not keep multiplying.
        let nonFallbackMatches = matchingIndices.filter { index in
            !hasFallbackHistoryTimestamp(merged[index].createdAt)
        }
        if nonFallbackMatches.count == 1 {
            return nonFallbackMatches[0]
        }

        // Keep intentionally repeated sends separate when more than one real row fits.
        return nil
    }

    nonisolated static func uniquePendingUserHistoryMergeIndex(
        in merged: [CodexMessage],
        message: CodexMessage
    ) -> Int? {
        // Pending rows are especially easy to confuse during phone-started turns.
        let matchingIndices = merged.indices.filter { index in
            shouldReconcilePendingUserHistoryMessage(merged[index], with: message)
        }

        guard matchingIndices.count == 1 else {
            return nil
        }

        return matchingIndices[0]
    }

    nonisolated static func fallbackUserHistoryMergeIndices(
        in merged: [CodexMessage],
        message: CodexMessage
    ) -> [Int] {
        let incomingItemId = normalizedHistoryIdentifier(message.itemId)
        guard message.role == .user,
              incomingItemId == nil || isProvisionalUserItemIdentifier(incomingItemId) else {
            return []
        }

        let rawIncomingTurnId = normalizedHistoryIdentifier(message.turnId)
        let incomingTurnIdIsSynthetic = isProvisionalHistoryTurnIdentifier(rawIncomingTurnId)
        let incomingTurnId = incomingTurnIdIsSynthetic ? nil : rawIncomingTurnId
        // Synthetic Desktop identity marks a projected row whose prompt the
        // timeline may already hold under its real identity; projected snapshots
        // also stamp thread-level fallback dates, so timestamps cannot veto.
        let incomingHasSyntheticIdentity = incomingTurnIdIsSynthetic || incomingItemId != nil
        let incomingHasFallbackTimestamp = hasFallbackHistoryTimestamp(message.createdAt)

        return merged.indices.filter { index in
            let candidate = merged[index]
            guard candidate.threadId == message.threadId,
                  candidate.role == .user,
                  candidate.deliveryState != .failed,
                  userMessagesMatchForHistory(candidate, message),
                  userMessageMetadataLooksCompatible(
                    localMessage: candidate,
                    serverMessage: message,
                    allowAttachmentCountFallback: candidate.deliveryState == .pending
                  ) else {
                return false
            }

            let rawCandidateTurnId = normalizedHistoryIdentifier(candidate.turnId)
            let candidateTurnId = isProvisionalHistoryTurnIdentifier(rawCandidateTurnId) ? nil : rawCandidateTurnId
            if let incomingTurnId, let candidateTurnId {
                return incomingTurnId == candidateTurnId
            }
            if incomingHasSyntheticIdentity {
                return true
            }
            if incomingHasFallbackTimestamp {
                return true
            }
            if incomingTurnId == nil,
               abs(candidate.createdAt.timeIntervalSince(message.createdAt)) <= Self.identitylessUserHistoryEchoWindow {
                return true
            }
            if incomingTurnId == nil,
               !hasFallbackHistoryTimestamp(candidate.createdAt),
               candidate.deliveryState != .pending {
                return false
            }
            return true
        }
    }

    nonisolated static func hasFallbackHistoryTimestamp(_ date: Date) -> Bool {
        !CodexTimestampParser.isTrustworthyServerDate(date)
    }

    func normalizedItemType(_ rawType: String) -> String {
        rawType
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    func normalizedAssistantPhase(_ rawPhase: String?) -> String? {
        guard let rawPhase else {
            return nil
        }
        let normalized = rawPhase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    nonisolated static func normalizedCommandExecutionPreviewKey(from text: String) -> String? {
        guard text.utf8.count <= Self.historyLargeTextByteLimit else {
            return nil
        }
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
        assistantPhase: String? = nil,
        text: String,
        threadId: String,
        turnId: String?,
        itemId: String?,
        sourceItemKey: String? = nil,
        createdAt: Date,
        timeZoneIdentifier: String? = nil,
        skillMentions: [String] = [],
        pluginMentions: [String] = [],
        attachments: [CodexImageAttachment] = [],
        planState: CodexPlanState? = nil,
        planPresentation: CodexPlanPresentation? = nil,
        subagentAction: CodexSubagentAction? = nil
    ) {
        guard !text.isEmpty
            || !attachments.isEmpty
            || planState != nil
            || subagentAction != nil else {
            return
        }

        result.append(
            CodexMessage(
                id: role == .assistant
                    ? (Self.stableAssistantMessageID(threadId: threadId, turnId: turnId, itemId: itemId) ?? UUID().uuidString)
                    : UUID().uuidString,
                threadId: threadId,
                role: role,
                kind: kind,
                assistantPhase: role == .assistant ? normalizedAssistantPhase(assistantPhase) : nil,
                text: text,
                skillMentions: skillMentions,
                pluginMentions: pluginMentions,
                createdAt: createdAt,
                timeZoneIdentifier: timeZoneIdentifier,
                turnId: turnId,
                itemId: itemId,
                sourceItemKey: sourceItemKey,
                isStreaming: false,
                deliveryState: .confirmed,
                attachments: attachments,
                planState: planState,
                planPresentation: planPresentation,
                proposedPlan: role == .assistant && text.utf8.count <= Self.historyLargeTextByteLimit
                    ? CodexProposedPlanParser.parse(from: text)
                    : nil,
                subagentAction: subagentAction
            )
        )
    }

    // Canonical history may store generated-image artifacts as separate items; the
    // timeline presents them inside the final assistant answer for that turn.
    nonisolated static func historyMessagesMergingGeneratedImageArtifacts(_ messages: [CodexMessage]) -> [CodexMessage] {
        var result = messages
        let turnIds = Array(Set(result.compactMap(\.turnId)))
        for turnId in turnIds {
            let assistantIndices = result.indices.filter { index in
                result[index].role == .assistant && result[index].turnId == turnId
            }
            let imageOnlyIndices = assistantIndices.filter { index in
                Self.isHistoryGeneratedImageArtifactOnly(result[index].text)
            }
            guard !imageOnlyIndices.isEmpty,
                  let targetIndex = assistantIndices.last(where: { index in
                      !imageOnlyIndices.contains(index)
                          && result[index].assistantPhase == "final_answer"
                  }) else {
                continue
            }

            let existingText = result[targetIndex].text
            guard existingText.utf8.count <= Self.historyLargeTextByteLimit else {
                continue
            }
            let existingImagePaths = Set(AssistantMarkdownImageReferenceParser.references(in: existingText).map(\.path))
            let imageText = imageOnlyIndices
                .filter { index in
                    AssistantMarkdownImageReferenceParser.references(in: result[index].text).contains { reference in
                        !existingImagePaths.contains(reference.path)
                    }
                }
                .map { result[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            guard !imageText.isEmpty else {
                continue
            }
            result[targetIndex].text = [existingText, imageText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }

        let removedIds = Set(result.indices.filter { index in
            if let turnId = result[index].turnId,
               Self.isHistoryGeneratedImageArtifactOnly(result[index].text) {
                return result.contains { candidate in
                    candidate.id != result[index].id
                        && candidate.role == .assistant
                        && candidate.turnId == turnId
                        && candidate.text.utf8.count <= Self.historyLargeTextByteLimit
                        && !Self.isHistoryGeneratedImageArtifactOnly(candidate.text)
                        && AssistantMarkdownImageReferenceParser.references(in: candidate.text).contains { reference in
                            result[index].text.contains(reference.path)
                        }
                }
            }
            return false
        }.map { result[$0].id })
        return result.filter { !removedIds.contains($0.id) }
    }

    nonisolated static func isHistoryGeneratedImageArtifactOnly(_ text: String) -> Bool {
        guard text.utf8.count <= Self.historyLargeTextByteLimit else {
            return false
        }
        let imageReferences = AssistantMarkdownImageReferenceParser.references(in: text)
        guard !imageReferences.isEmpty,
              imageReferences.allSatisfy(\.isCodexGeneratedImage) else {
            return false
        }
        return AssistantMarkdownImageReferenceParser
            .visibleTextRemovingImageSyntax(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
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
            return ""
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

        // Keep transport emptiness distinct from presentation placeholders so
        // history reconciliation can discard plan items with no visible payload.
        return ""
    }

    func decodePlanState(from itemObject: [String: JSONValue]) -> CodexPlanState? {
        let explanation = decodeNormalizedPlanText(itemObject["explanation"])
            ?? decodeNormalizedPlanText(itemObject["summary"])
        let steps = (itemObject["plan"]?.arrayValue ?? []).compactMap { stepValue -> CodexPlanStep? in
            guard let stepObject = stepValue.objectValue,
                  let step = decodeNormalizedPlanText(stepObject["step"]),
                  let rawStatus = decodeNormalizedPlanText(stepObject["status"]),
                  let status = CodexPlanStepStatus(wireValue: rawStatus) else {
                return nil
            }

            return CodexPlanStep(step: step, status: status)
        }

        guard explanation != nil || !steps.isEmpty else {
            return nil
        }

        return CodexPlanState(explanation: explanation, steps: steps)
    }

    // Closed turns should not restore a stale "active" plan accessory from history.
    func finalizedHistoryPlanState(_ planState: CodexPlanState?, turnCompleted: Bool) -> CodexPlanState? {
        guard turnCompleted,
              let planState,
              !planState.steps.isEmpty,
              planState.steps.contains(where: { $0.status != .completed }) else {
            return planState
        }

        return CodexPlanState(
            explanation: planState.explanation,
            steps: planState.steps.map { step in
                CodexPlanStep(id: step.id, step: step.step, status: .completed)
            }
        )
    }

    func isCompletedHistoryTurn(_ turnObject: [String: JSONValue]) -> Bool {
        historyTurnTerminalState(turnObject) == .completed
    }

    func historyTurnTerminalState(_ turnObject: [String: JSONValue]) -> CodexTurnTerminalState? {
        let statusObject = turnObject["status"]?.objectValue
        let rawStatus = firstNonEmptyString([
            turnObject["status"]?.stringValue,
            statusObject?["type"]?.stringValue,
            statusObject?["statusType"]?.stringValue,
            statusObject?["status_type"]?.stringValue,
            turnObject["result"]?.stringValue,
        ]) ?? ""

        return threadTerminalState(from: normalizeThreadStatusType(rawStatus))
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

    private func decodeNormalizedPlanText(_ value: JSONValue?) -> String? {
        let flattened = Self.normalizedMessageText(decodeHistoryStringParts(value).joined(separator: "\n"))
        guard Self.hasMeaningfulHistoryText(flattened) else {
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
        let previewSource = rawCommand.utf8.count <= Self.historyLargeTextByteLimit
            ? rawCommand
            : String(rawCommand.prefix(maxLength))
        let trimmed = previewSource.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // Splits history tool items into dedicated command, file-change, or compact generic activity rows.
    func decodeHistoryToolCallItem(from itemObject: [String: JSONValue]) -> (kind: CodexMessageKind, text: String)? {
        if isHistoryCommandToolCall(itemObject),
           let commandText = decodeHistoryCommandToolCallText(from: itemObject) {
            return (.commandExecution, commandText)
        }
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
            let trimmedDiff = Self.normalizedMessageText(diff)
            if Self.hasMeaningfulHistoryText(trimmedDiff) {
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
            guard output.utf8.count <= Self.historyLargeTextByteLimit else {
                return nil
            }
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
                "capture ",
                "captured ",
                "check ",
                "checked ",
                "create ",
                "created ",
                "edit ",
                "edited ",
                "request ",
                "requested ",
                "run ",
                "ran ",
                "update ",
                "updated ",
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

    func isHistoryCommandToolCall(_ itemObject: [String: JSONValue]) -> Bool {
        let rawTool = firstNonEmptyString([
            itemObject["name"]?.stringValue,
            itemObject["tool_name"]?.stringValue,
            itemObject["toolName"]?.stringValue,
            itemObject["tool"]?.stringValue,
        ])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rawTool == "exec_command" || rawTool == "shell_command"
    }

    func decodeHistoryCommandToolCallText(from itemObject: [String: JSONValue]) -> String? {
        let argumentsObject = decodeHistoryToolArgumentsObject(from: itemObject)
        let status = decodeHistoryNestedStatus(from: itemObject) ?? "completed"
        let phase = normalizedHistoryCommandPhase(status)
        let command = firstNonEmptyString([
            decodeHistoryFirstString(
                forAnyKey: ["command", "cmd", "raw_command", "rawCommand", "input", "invocation"],
                in: .object(itemObject)
            ),
            decodeHistoryFirstString(
                forAnyKey: ["command", "cmd", "raw_command", "rawCommand", "input", "invocation"],
                in: .object(argumentsObject)
            ),
        ])
        guard let command else { return nil }
        return "\(phase) \(shortHistoryCommand(command))"
    }

    func decodeHistoryToolArgumentsObject(from itemObject: [String: JSONValue]) -> [String: JSONValue] {
        guard let argumentsValue = itemObject["arguments"] ?? itemObject["input"] else {
            return [:]
        }
        if let object = argumentsValue.objectValue {
            return object
        }
        guard let text = argumentsValue.stringValue,
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = decoded.objectValue else {
            return [:]
        }
        return object
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
               let content = changeObject["content"]?.stringValue,
               content.utf8.count <= Self.historyLargeTextByteLimit {
                let normalizedContent = Self.normalizedMessageText(content)
                if Self.hasMeaningfulHistoryText(normalizedContent) {
                    diff = synthesizeHistoryUnifiedDiffFromContent(normalizedContent, kind: kind, path: path)
                }
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
        return Self.normalizedMessageText(diff)
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
                "@@ -0,0 +1,\(contentLines.count) @@",
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
                "@@ -1,\(contentLines.count) +0,0 @@",
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
                    let trimmed = Self.normalizedMessageText(text)
                    if Self.hasMeaningfulHistoryText(trimmed) {
                        return trimmed
                    }
                }

                if let flattened = decodeHistoryFlattenText(from: value, maxDepth: maxDepth) {
                    let trimmed = Self.normalizedMessageText(flattened)
                    if Self.hasMeaningfulHistoryText(trimmed) {
                        return trimmed
                    }
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
            let trimmed = Self.normalizedMessageText(text)
            return Self.hasMeaningfulHistoryText(trimmed) ? trimmed : nil
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
            return !Self.hasMeaningfulHistoryText(text)
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
            let trimmed = Self.normalizedMessageText(text)
            return Self.hasMeaningfulHistoryText(trimmed) ? [trimmed] : []
        case .array(let values):
            return values.compactMap { candidate in
                if let text = candidate.stringValue {
                    let trimmed = Self.normalizedMessageText(text)
                    return Self.hasMeaningfulHistoryText(trimmed) ? trimmed : nil
                }

                if let object = candidate.objectValue,
                   let text = object["text"]?.stringValue {
                    let trimmed = Self.normalizedMessageText(text)
                    return Self.hasMeaningfulHistoryText(trimmed) ? trimmed : nil
                }

                return nil
            }
        case .object(let object):
            if let text = object["text"]?.stringValue {
                let trimmed = Self.normalizedMessageText(text)
                return Self.hasMeaningfulHistoryText(trimmed) ? [trimmed] : []
            }
            return []
        default:
            return []
        }
    }
}
