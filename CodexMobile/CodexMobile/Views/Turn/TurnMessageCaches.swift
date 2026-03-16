// FILE: TurnMessageCaches.swift
// Purpose: Thread-safe caches for parsed markdown, file-change state, command status, diff chunks,
//   code comment directives, and file-change grouping.
// Layer: View Support
// Exports: MarkdownRenderableTextCache, FileChangeRenderState, MessageRowRenderModel,
//   CommandExecutionStatusCache, FileChangeSystemRenderCache, PerFileDiffChunk, PerFileDiffParser,
//   PerFileDiffChunkCache, CodeCommentDirectiveContentCache, FileChangeGroupingCache
// Depends on: Foundation, TurnMessageRegexCache, TurnFileChangeSummaryParser, TurnDiffLineKind,
//   MarkdownRenderProfile, TurnMermaidRenderer

import Foundation

// Thread-safe bounded cache that evicts roughly half its entries when full instead of discarding everything.
final class BoundedCache<Key: Hashable, Value> {
    private let maxEntries: Int
    private let lock = NSLock()
    private var storage: [Key: Value] = [:]

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: Key, value: Value) {
        lock.lock()
        evictIfNeeded()
        storage[key] = value
        lock.unlock()
    }

    func getOrSet(_ key: Key, builder: () -> Value) -> Value {
        lock.lock()
        if let cached = storage[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let built = builder()

        lock.lock()
        evictIfNeeded()
        storage[key] = built
        lock.unlock()

        return built
    }

    func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func evictIfNeeded() {
        guard storage.count >= maxEntries else { return }
        let evictCount = maxEntries / 2
        var removed = 0
        for key in storage.keys {
            guard removed < evictCount else { break }
            storage.removeValue(forKey: key)
            removed += 1
        }
    }
}

enum MarkdownRenderableTextCache {
    private static let cache = BoundedCache<String, String>(maxEntries: 512)

    static func rendered(
        raw: String,
        profile: MarkdownRenderProfile,
        builder: () -> String
    ) -> String {
        cache.getOrSet("\(profile.cacheKey)|\(raw.hashValue)", builder: builder)
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
    let fileChangeState: FileChangeRenderState?
    let fileChangeGroups: [FileChangeGroup]
    let thinkingContent: ThinkingDisclosureContent?
    let thinkingText: String?
    let commandStatus: CommandExecutionStatusModel?

    static let empty = MessageRowRenderModel(
        codeCommentContent: nil,
        mermaidContent: nil,
        fileChangeState: nil,
        fileChangeGroups: [],
        thinkingContent: nil,
        thinkingText: nil,
        commandStatus: nil
    )
}

enum MessageRowRenderModelCache {
    private static let cache = BoundedCache<String, MessageRowRenderModel>(maxEntries: 512)

    static func model(for message: CodexMessage, displayText: String) -> MessageRowRenderModel {
        let key = "\(message.id)|\(message.kind.rawValue)|\(message.role.rawValue)|\(message.isStreaming)|\(displayText.hashValue)"
        return cache.getOrSet(key) { buildModel(for: message, displayText: displayText) }
    }

    static func reset() {
        cache.removeAll()
    }

    private static func buildModel(for message: CodexMessage, displayText: String) -> MessageRowRenderModel {
        switch message.role {
        case .assistant:
            // Defer Mermaid parsing until the assistant row is finalized so streaming deltas
            // keep the lightweight markdown path and avoid repeated WebKit churn.
            return MessageRowRenderModel(
                codeCommentContent: CodeCommentDirectiveContentCache.content(messageID: message.id, text: displayText),
                mermaidContent: message.isStreaming
                    ? nil
                    : MermaidMarkdownContentCache.content(
                        messageID: message.id,
                        text: displayText
                    ),
                fileChangeState: nil,
                fileChangeGroups: [],
                thinkingContent: nil,
                thinkingText: nil,
                commandStatus: nil
            )
        case .user:
            return .empty
        case .system:
            switch message.kind {
            case .thinking:
                let thinkingText = ThinkingDisclosureParser.normalizedThinkingContent(from: message.text)
                return MessageRowRenderModel(
                    codeCommentContent: nil,
                    mermaidContent: nil,
                    fileChangeState: nil,
                    fileChangeGroups: [],
                    thinkingContent: thinkingText.isEmpty
                        ? ThinkingDisclosureContent(sections: [], fallbackText: "")
                        : ThinkingDisclosureContentCache.content(messageID: message.id, text: thinkingText),
                    thinkingText: thinkingText,
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
                    fileChangeState: fileChangeState,
                    fileChangeGroups: FileChangeGroupingCache.grouped(messageID: message.id, entries: allEntries),
                    thinkingContent: nil,
                    thinkingText: nil,
                    commandStatus: nil
                )
            case .commandExecution:
                return MessageRowRenderModel(
                    codeCommentContent: nil,
                    mermaidContent: nil,
                    fileChangeState: nil,
                    fileChangeGroups: [],
                    thinkingContent: nil,
                    thinkingText: nil,
                    commandStatus: CommandExecutionStatusCache.status(messageID: message.id, text: displayText)
                )
            case .plan, .userInputPrompt, .chat:
                return .empty
            }
        }
    }
}

enum CommandExecutionStatusCache {
    private static let cache = BoundedCache<String, CommandExecutionStatusModel>(maxEntries: 256)

    static func status(messageID: String, text: String) -> CommandExecutionStatusModel? {
        let key = "\(messageID)|\(text.hashValue)"
        if let cached = cache.get(key) { return cached }
        guard let parsed = parse(text) else { return nil }
        cache.set(key, value: parsed)
        return parsed
    }

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

    static func renderState(messageID: String, sourceText: String) -> FileChangeRenderState {
        cache.getOrSet("\(messageID)|\(sourceText.hashValue)") {
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

// ─── Per-File Diff Chunk ────────────────────────────────────────────

struct PerFileDiffChunk: Identifiable {
    let id: String
    let path: String
    let action: TurnFileChangeAction
    let additions: Int
    let deletions: Int
    let diffCode: String

    var compactPath: String {
        if let last = path.split(separator: "/").last { return String(last) }
        return path
    }

    var fullDirectoryPath: String? {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }
}

// ─── Per-File Diff Parser ───────────────────────────────────────────

enum PerFileDiffParser {
    static func parse(bodyText: String, entries: [TurnFileChangeSummaryEntry]) -> [PerFileDiffChunk] {
        let sections = bodyText.components(separatedBy: "\n\n---\n\n")

        if sections.count <= 1 {
            return singleChunkFallback(bodyText: bodyText, entries: entries)
        }

        var chunks: [PerFileDiffChunk] = []
        for (index, section) in sections.enumerated() {
            let lines = section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let path = extractPath(from: lines)
            let code = extractFencedCode(from: lines)

            let resolvedPath = path ?? (index < entries.count ? entries[index].path : "file-\(index)")
            let entry = entries.first { $0.path == resolvedPath }

            chunks.append(PerFileDiffChunk(
                id: "\(index)-\(resolvedPath)",
                path: resolvedPath,
                action: entry?.action ?? .edited,
                additions: entry?.additions ?? 0,
                deletions: entry?.deletions ?? 0,
                diffCode: code ?? ""
            ))
        }
        return chunks
    }

    private static func singleChunkFallback(bodyText: String, entries: [TurnFileChangeSummaryEntry]) -> [PerFileDiffChunk] {
        // Try to split by fenced diff blocks associated with Path: lines
        let lines = bodyText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [PerFileDiffChunk] = []
        var currentPath: String?
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("**Path:**") || trimmed.hasPrefix("Path:") {
                let raw = trimmed
                    .replacingOccurrences(of: "**Path:**", with: "")
                    .replacingOccurrences(of: "Path:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if !raw.isEmpty { currentPath = raw }
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate == "```" { break }
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }

                let code = codeLines.joined(separator: "\n")
                if TurnDiffLineKind.detectVerifiedPatch(in: code) {
                    let resolvedPath = currentPath ?? (chunks.count < entries.count ? entries[chunks.count].path : "file-\(chunks.count)")
                    let entry = entries.first { $0.path == resolvedPath }
                    chunks.append(PerFileDiffChunk(
                        id: "\(chunks.count)-\(resolvedPath)",
                        path: resolvedPath,
                        action: entry?.action ?? .edited,
                        additions: entry?.additions ?? 0,
                        deletions: entry?.deletions ?? 0,
                        diffCode: code
                    ))
                    currentPath = nil
                }
                continue
            }

            i += 1
        }

        if chunks.isEmpty, !entries.isEmpty {
            // Ultimate fallback: one chunk per entry with the whole body
            let allCode = extractFencedCode(from: lines) ?? bodyText
            let first = entries[0]
            chunks.append(PerFileDiffChunk(
                id: "0-\(first.path)",
                path: first.path,
                action: first.action ?? .edited,
                additions: first.additions,
                deletions: first.deletions,
                diffCode: allCode
            ))
        }

        return chunks
    }

    private static func extractPath(from lines: [String]) -> String? {
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("**Path:**") || t.hasPrefix("Path:") {
                let raw = t
                    .replacingOccurrences(of: "**Path:**", with: "")
                    .replacingOccurrences(of: "Path:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if !raw.isEmpty { return raw }
            }
        }
        return nil
    }

    private static func extractFencedCode(from lines: [String]) -> String? {
        var inFence = false
        var codeLines: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("```") {
                if inFence {
                    return codeLines.joined(separator: "\n")
                } else {
                    inFence = true
                    codeLines = []
                }
                continue
            }
            if inFence { codeLines.append(line) }
        }
        return inFence ? codeLines.joined(separator: "\n") : nil
    }
}

// ─── Per-File Diff Chunk Cache ──────────────────────────────────────

enum PerFileDiffChunkCache {
    private static let cache = BoundedCache<String, [PerFileDiffChunk]>(maxEntries: 128)

    static func chunks(messageID: String, bodyText: String, entries: [TurnFileChangeSummaryEntry]) -> [PerFileDiffChunk] {
        cache.getOrSet("\(messageID)|\(bodyText.hashValue)") {
            PerFileDiffParser.parse(bodyText: bodyText, entries: entries)
        }
    }
}

// ─── Code Comment Directive Content Cache ───────────────────────────

enum CodeCommentDirectiveContentCache {
    private static let cache = BoundedCache<String, CodeCommentDirectiveContent>(maxEntries: 256)

    static func content(messageID: String, text: String) -> CodeCommentDirectiveContent {
        cache.getOrSet("\(messageID)|\(text.hashValue)") {
            CodeCommentDirectiveParser.parse(from: text)
        }
    }
}

// ─── Thinking Disclosure Content Cache ──────────────────────────────

enum ThinkingDisclosureContentCache {
    private static let cache = BoundedCache<String, ThinkingDisclosureContent>(maxEntries: 256)

    static func content(messageID: String, text: String) -> ThinkingDisclosureContent {
        cache.getOrSet("\(messageID)|\(text.hashValue)") {
            ThinkingDisclosureParser.parse(from: text)
        }
    }
}

// ─── Diff Block Detection Cache ─────────────────────────────────────

enum DiffBlockDetectionCache {
    private static let cache = BoundedCache<Int, Bool>(maxEntries: 512)

    static func isDiffBlock(code: String, profile: MarkdownRenderProfile) -> Bool {
        switch profile {
        case .assistantProse, .fileChangeSystem:
            break
        }

        return cache.getOrSet(code.hashValue) {
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
