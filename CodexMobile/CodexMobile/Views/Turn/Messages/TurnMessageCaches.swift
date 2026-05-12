// FILE: TurnMessageCaches.swift
// Purpose: Timeline render caches for markdown, command status and message-row render models.
// Layer: View Support
// Exports: MarkdownRenderableTextCache, FileChangeRenderState, MessageRowRenderModel,
//   CommandExecutionStatusCache, FileChangeSystemRenderCache, CodeCommentDirectiveContentCache,
//   FileChangeGroupingCache
// Depends on: Foundation, CodexMessage, TurnMessageRegexCache, TurnFileChangeSummaryParser,
//   MarkdownRenderProfile, TurnMermaidRenderer, CommandExecutionViews

import Foundation

/// Explicit cache flush hook for memory-pressure/manual recovery paths.
/// Normal thread switching should keep these hot caches warm.
enum TurnCacheManager {
    @MainActor static func resetAll() {
        MarkdownParseCacheReset.reset()
        MarkdownRenderableTextCache.reset()
        MessageRowRenderModelCache.reset()
        CommandExecutionStatusCache.reset()
        FileChangeSystemRenderCache.reset()
        FileChangeBlockPresentationCache.reset()
        PerFileDiffChunkCache.reset()
        CodeCommentDirectiveContentCache.reset()
        ThinkingDisclosureContentCache.reset()
        DiffBlockDetectionCache.reset()
        FileChangeGroupingCache.reset()
        MermaidMarkdownContentCache.reset()
        MermaidMarkdownContentCache.resetRenderedSnapshots()
    }
}


enum MarkdownRenderableTextCache {
    private static let cache = BoundedCache<String, String>(maxEntries: 512)

    static func rendered(
        raw: String,
        profile: MarkdownRenderProfile,
        builder: () -> String
    ) -> String {
        let key = TurnTextCacheKey.stableKey(namespace: profile.cacheKey, text: raw)
        return cache.getOrSet(key, builder: builder)
    }

    static func reset() {
        cache.removeAll()
    }
}

struct FileChangeRenderState {
    let summary: TurnFileChangeSummary?
    let actionEntries: [TurnFileChangeSummaryEntry]
    let bodyText: String
}

struct MessageRowRenderModel {
    let codeCommentContent: CodeCommentDirectiveContent?
    let mermaidContent: MermaidMarkdownContent?
    let assistantImageReferences: [AssistantMarkdownImageReference]
    let assistantInlineContentSegments: [AssistantMarkdownContentSegment]
    let assistantTextWithoutImageSyntax: String?
    let fileChangeState: FileChangeRenderState?
    let fileChangeGroups: [FileChangeGroup]
    let thinkingContent: ThinkingDisclosureContent?
    let thinkingText: String?
    let thinkingActivityPreview: String?
    let commandStatus: CommandExecutionStatusModel?

    static let empty = MessageRowRenderModel(
        codeCommentContent: nil,
        mermaidContent: nil,
        assistantImageReferences: [],
        assistantInlineContentSegments: [],
        assistantTextWithoutImageSyntax: nil,
        fileChangeState: nil,
        fileChangeGroups: [],
        thinkingContent: nil,
        thinkingText: nil,
        thinkingActivityPreview: nil,
        commandStatus: nil
    )
}

enum MessageRowRenderModelCache {
    private static let cache = BoundedCache<String, MessageRowRenderModel>(maxEntries: 512)

    static func model(for message: CodexMessage, displayText: String) -> MessageRowRenderModel {
        let textFingerprint = message.isStreaming
            ? TurnTextCacheKey.fingerprint(for: displayText)
            : TurnTextCacheKey.stableFingerprint(for: displayText)
        let key = "\(message.id)|\(message.kind.rawValue)|\(message.role.rawValue)|\(message.isStreaming)|\(textFingerprint)"
        return cache.getOrSet(key) { buildModel(for: message, displayText: displayText) }
    }

    static func reset() {
        cache.removeAll()
    }

    private static func buildModel(for message: CodexMessage, displayText: String) -> MessageRowRenderModel {
        switch message.role {
        case .assistant:
            let assistantImageReferences = message.isStreaming
                ? []
                : AssistantMarkdownImageReferenceParser.references(in: displayText)
            let assistantTextWithoutImageSyntax = assistantImageReferences.isEmpty
                ? nil
                : AssistantMarkdownImageReferenceParser.visibleTextRemovingImageSyntax(from: displayText)
            let assistantInlineContentSegments = assistantImageReferences.contains(where: \.isTemporaryScreenshotImage)
                ? AssistantMarkdownImageReferenceParser.contentSegmentsPreservingTemporaryImages(from: displayText)
                : []
            let assistantRenderText = assistantTextWithoutImageSyntax ?? displayText
            // Defer Mermaid parsing until the assistant row is finalized so streaming deltas
            // keep the lightweight append-only path and avoid repeated parser/WebKit churn.
            return MessageRowRenderModel(
                codeCommentContent: message.isStreaming
                    ? nil
                    : CodeCommentDirectiveContentCache.content(messageID: message.id, text: displayText),
                mermaidContent: message.isStreaming
                    ? nil
                    : MermaidMarkdownContentCache.content(
                        messageID: message.id,
                        text: assistantRenderText
                ),
                assistantImageReferences: assistantImageReferences,
                assistantInlineContentSegments: assistantInlineContentSegments,
                assistantTextWithoutImageSyntax: assistantTextWithoutImageSyntax,
                fileChangeState: nil,
                fileChangeGroups: [],
                thinkingContent: nil,
                thinkingText: nil,
                thinkingActivityPreview: nil,
                commandStatus: nil
            )
        case .user:
            return .empty
        case .system:
            switch message.kind {
            case .thinking:
                let thinkingText = ThinkingDisclosureParser.normalizedThinkingContent(from: message.text)
                let thinkingActivityPreview = thinkingText.isEmpty
                    ? nil
                    : ThinkingDisclosureParser.compactActivityPreview(fromNormalizedText: thinkingText)
                return MessageRowRenderModel(
                    codeCommentContent: nil,
                    mermaidContent: nil,
                    assistantImageReferences: [],
                    assistantInlineContentSegments: [],
                    assistantTextWithoutImageSyntax: nil,
                    fileChangeState: nil,
                    fileChangeGroups: [],
                    thinkingContent: thinkingText.isEmpty
                        ? ThinkingDisclosureContent(sections: [], fallbackText: "")
                        : ThinkingDisclosureContentCache.content(messageID: message.id, text: thinkingText),
                    thinkingText: thinkingText,
                    thinkingActivityPreview: thinkingActivityPreview,
                    commandStatus: nil
                )
            case .fileChange:
                let fileChangeState = FileChangeSystemRenderCache.renderState(
                    messageID: message.id,
                    sourceText: displayText
                )
                let actionEntries = fileChangeState.actionEntries
                let allEntries = actionEntries.isEmpty ? (fileChangeState.summary?.entries ?? []) : actionEntries
                return MessageRowRenderModel(
                    codeCommentContent: nil,
                    mermaidContent: nil,
                    assistantImageReferences: [],
                    assistantInlineContentSegments: [],
                    assistantTextWithoutImageSyntax: nil,
                    fileChangeState: fileChangeState,
                    fileChangeGroups: FileChangeGroupingCache.grouped(messageID: message.id, entries: allEntries),
                    thinkingContent: nil,
                    thinkingText: nil,
                    thinkingActivityPreview: nil,
                    commandStatus: nil
                )
            case .toolActivity:
                return .empty
            case .commandExecution:
                return MessageRowRenderModel(
                    codeCommentContent: nil,
                    mermaidContent: nil,
                    assistantImageReferences: [],
                    assistantInlineContentSegments: [],
                    assistantTextWithoutImageSyntax: nil,
                    fileChangeState: nil,
                    fileChangeGroups: [],
                    thinkingContent: nil,
                    thinkingText: nil,
                    thinkingActivityPreview: nil,
                    commandStatus: CommandExecutionStatusCache.status(messageID: message.id, text: displayText)
                )
            case .subagentAction, .plan, .userInputPrompt, .chat:
                return .empty
            }
        }
    }
}

enum CommandExecutionStatusCache {
    private static let cache = BoundedCache<String, CommandExecutionStatusModel>(maxEntries: 256)

    static func status(messageID: String, text: String) -> CommandExecutionStatusModel? {
        let key = TurnTextCacheKey.key(messageID: messageID, kind: "command-status", text: text)
        if let cached = cache.get(key) { return cached }
        guard let parsed = parse(text) else { return nil }
        cache.set(key, value: parsed)
        return parsed
    }

    static func reset() { cache.removeAll() }

    private static func parse(_ text: String) -> CommandExecutionStatusModel? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.lowercased() else { return nil }
        let command = words.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let commandLabel = command.isEmpty ? "command" : command

        switch first {
        case "running":
            return CommandExecutionStatusModel(command: commandLabel, statusLabel: "running", accent: .running)
        case "completed":
            return CommandExecutionStatusModel(command: commandLabel, statusLabel: "completed", accent: .completed)
        case "failed", "stopped":
            return CommandExecutionStatusModel(command: commandLabel, statusLabel: first, accent: .failed)
        default:
            return nil
        }
    }
}

enum FileChangeSystemRenderCache {
    private static let cache = BoundedCache<String, FileChangeRenderState>(maxEntries: 256)

    static func reset() { cache.removeAll() }

    static func renderState(messageID: String, sourceText: String) -> FileChangeRenderState {
        cache.getOrSet(TurnTextCacheKey.key(messageID: messageID, kind: "file-change-render", text: sourceText)) {
            let summary = TurnFileChangeSummaryParser.parse(from: sourceText)
            let actionEntries = summary?.entries.filter { $0.action != nil } ?? []
            let bodyText = actionEntries.isEmpty
                ? sourceText
                : TurnFileChangeSummaryParser.removingInlineEditingRows(from: sourceText)
            return FileChangeRenderState(
                summary: summary,
                actionEntries: actionEntries,
                bodyText: bodyText
            )
        }
    }
}

// ─── Code Comment Directive Content Cache ───────────────────────────

enum CodeCommentDirectiveContentCache {
    private static let cache = BoundedCache<String, CodeCommentDirectiveContent>(maxEntries: 256)

    static func reset() { cache.removeAll() }

    static func content(messageID: String, text: String) -> CodeCommentDirectiveContent {
        cache.getOrSet(TurnTextCacheKey.key(messageID: messageID, kind: "code-comment", text: text)) {
            CodeCommentDirectiveParser.parse(from: text)
        }
    }
}

// ─── Thinking Disclosure Content Cache ──────────────────────────────

enum ThinkingDisclosureContentCache {
    private static let cache = BoundedCache<String, ThinkingDisclosureContent>(maxEntries: 256)

    static func reset() { cache.removeAll() }

    static func content(messageID: String, text: String) -> ThinkingDisclosureContent {
        cache.getOrSet(TurnTextCacheKey.key(messageID: messageID, kind: "thinking", text: text)) {
            ThinkingDisclosureParser.parse(from: text)
        }
    }
}

// ─── Diff Block Detection Cache ─────────────────────────────────────

enum DiffBlockDetectionCache {
    private static let cache = BoundedCache<String, Bool>(maxEntries: 512)

    static func reset() { cache.removeAll() }

    static func isDiffBlock(code: String, profile: MarkdownRenderProfile) -> Bool {
        switch profile {
        case .assistantProse, .fileChangeSystem:
            break
        }

        let key = TurnTextCacheKey.key(namespace: "\(profile.cacheKey)|diff-block", text: code)
        return cache.getOrSet(key) {
            TurnDiffLineKind.detectVerifiedPatch(in: code)
        }
    }
}

// ─── File Change Grouping Cache ─────────────────────────────────────

struct FileChangeGroup: Identifiable {
    let key: String
    let entries: [TurnFileChangeSummaryEntry]
    var id: String { key }
}

enum FileChangeGroupingCache {
    private static let cache = BoundedCache<String, [FileChangeGroup]>(maxEntries: 256)

    static func reset() { cache.removeAll() }

    static func grouped(messageID: String, entries: [TurnFileChangeSummaryEntry]) -> [FileChangeGroup] {
        var hasher = Hasher()
        hasher.combine(messageID)
        for entry in entries {
            hasher.combine(entry.path)
            hasher.combine(entry.action)
            hasher.combine(entry.additions)
            hasher.combine(entry.deletions)
        }
        let key = "\(hasher.finalize())"

        return cache.getOrSet(key) {
            var order: [String] = []
            var dict: [String: [TurnFileChangeSummaryEntry]] = [:]
            for entry in entries {
                let groupKey = entry.action?.rawValue ?? "Edited"
                if dict[groupKey] == nil { order.append(groupKey) }
                dict[groupKey, default: []].append(entry)
            }
            return order.map { FileChangeGroup(key: $0, entries: dict[$0]!) }
        }
    }
}
