// FILE: TurnMessageCaches.swift
// Purpose: Thread-safe caches for parsed markdown, file-change state, command status, diff chunks,
//   code comment directives, and file-change grouping.
// Layer: View Support
// Exports: MarkdownRenderableTextCache, MessageRowMarkdownSegmentCache, FileChangeRenderState,
//   CommandExecutionStatusCache, FileChangeSystemRenderCache, PerFileDiffChunk, PerFileDiffParser,
//   PerFileDiffChunkCache, CodeCommentDirectiveContentCache, FileChangeGroupingCache
// Depends on: Foundation, TurnMessageRegexCache, TurnFileChangeSummaryParser, TurnDiffLineKind, MarkdownRenderProfile, MarkdownSegment

import Foundation

enum MarkdownRenderableTextCache {
    static let maxEntries = 512
    static let lock = NSLock()
    static var renderedByKey: [String: String] = [:]

    // Caches markdown-to-renderable transformation to reduce repeated line/regex work.
    static func rendered(
        raw: String,
        profile: MarkdownRenderProfile,
        builder: () -> String
    ) -> String {
        let cacheKey = "\(profile.cacheKey)|\(raw.hashValue)"

        lock.lock()
        if let cached = renderedByKey[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let rendered = builder()

        lock.lock()
        if renderedByKey.count >= maxEntries {
            renderedByKey.removeAll(keepingCapacity: true)
        }
        renderedByKey[cacheKey] = rendered
        lock.unlock()

        return rendered
    }
}

enum MessageRowMarkdownSegmentCache {
    static let maxEntries = 512
    static let lock = NSLock()
    static var segmentsByKey: [String: [MarkdownSegment]] = [:]

    // Reuses parsed segments during stream updates to avoid repeated regex work.
    static func segments(messageID: String, text: String) -> [MarkdownSegment] {
        let cacheKey = "\(messageID)|\(text.hashValue)"

        lock.lock()
        if let cached = segmentsByKey[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = parseMarkdownSegments(text)

        lock.lock()
        if segmentsByKey.count >= maxEntries {
            segmentsByKey.removeAll(keepingCapacity: true)
        }
        segmentsByKey[cacheKey] = parsed
        lock.unlock()

        return parsed
    }
}

struct FileChangeRenderState {
    let summary: TurnFileChangeSummary?
    let actionEntries: [TurnFileChangeSummaryEntry]
    let bodyText: String
}

enum CommandExecutionStatusCache {
    static let maxEntries = 256
    static let lock = NSLock()
    static var statusByKey: [String: CommandExecutionStatusModel] = [:]

    static func status(messageID: String, text: String) -> CommandExecutionStatusModel? {
        let cacheKey = "\(messageID)|\(text.hashValue)"

        lock.lock()
        if let cached = statusByKey[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let parsed = parse(text) else {
            return nil
        }

        lock.lock()
        if statusByKey.count >= maxEntries {
            statusByKey.removeAll(keepingCapacity: true)
        }
        statusByKey[cacheKey] = parsed
        lock.unlock()

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
    static let maxEntries = 256
    static let lock = NSLock()
    static var stateByKey: [String: FileChangeRenderState] = [:]

    // Caches file-change parse artifacts to keep scrolling smooth on long patch threads.
    static func renderState(messageID: String, sourceText: String) -> FileChangeRenderState {
        let cacheKey = "\(messageID)|\(sourceText.hashValue)"

        lock.lock()
        if let cached = stateByKey[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let summary = TurnFileChangeSummaryParser.parse(from: sourceText)
        let actionEntries = summary?.entries.filter { $0.action != nil } ?? []
        let bodyText = actionEntries.isEmpty
            ? sourceText
            : TurnFileChangeSummaryParser.removingInlineEditingRows(from: sourceText)
        let state = FileChangeRenderState(
            summary: summary,
            actionEntries: actionEntries,
            bodyText: bodyText
        )

        lock.lock()
        if stateByKey.count >= maxEntries {
            stateByKey.removeAll(keepingCapacity: true)
        }
        stateByKey[cacheKey] = state
        lock.unlock()

        return state
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
    static let maxEntries = 128
    static let lock = NSLock()
    static var cache: [String: [PerFileDiffChunk]] = [:]

    static func chunks(messageID: String, bodyText: String, entries: [TurnFileChangeSummaryEntry]) -> [PerFileDiffChunk] {
        let key = "\(messageID)|\(bodyText.hashValue)"

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = PerFileDiffParser.parse(bodyText: bodyText, entries: entries)

        lock.lock()
        if cache.count >= maxEntries {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = parsed
        lock.unlock()

        return parsed
    }
}

// ─── Code Comment Directive Content Cache ───────────────────────────

enum CodeCommentDirectiveContentCache {
    static let maxEntries = 256
    static let lock = NSLock()
    static var cache: [String: CodeCommentDirectiveContent] = [:]

    static func content(messageID: String, text: String) -> CodeCommentDirectiveContent {
        let key = "\(messageID)|\(text.hashValue)"

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = CodeCommentDirectiveParser.parse(from: text)

        lock.lock()
        if cache.count >= maxEntries {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = parsed
        lock.unlock()

        return parsed
    }
}

// ─── Thinking Disclosure Content Cache ──────────────────────────────

enum ThinkingDisclosureContentCache {
    static let maxEntries = 256
    static let lock = NSLock()
    static var cache: [String: ThinkingDisclosureContent] = [:]

    static func content(messageID: String, text: String) -> ThinkingDisclosureContent {
        let key = "\(messageID)|\(text.hashValue)"

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let parsed = ThinkingDisclosureParser.parse(from: text)

        lock.lock()
        if cache.count >= maxEntries {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = parsed
        lock.unlock()

        return parsed
    }
}

// ─── Diff Block Detection Cache ─────────────────────────────────────

enum DiffBlockDetectionCache {
    static let maxEntries = 512
    static let lock = NSLock()
    static var cache: [Int: Bool] = [:]

    static func isDiffBlock(code: String, profile: MarkdownRenderProfile) -> Bool {
        switch profile {
        case .assistantProse, .fileChangeSystem:
            break
        }

        let key = code.hashValue

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let result = TurnDiffLineKind.detectVerifiedPatch(in: code)

        lock.lock()
        if cache.count >= maxEntries {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = result
        lock.unlock()

        return result
    }
}

// ─── File Change Grouping Cache ─────────────────────────────────────

struct FileChangeGroup: Identifiable {
    let key: String
    let entries: [TurnFileChangeSummaryEntry]
    var id: String { key }
}

enum FileChangeGroupingCache {
    static let maxEntries = 256
    static let lock = NSLock()
    static var cache: [String: [FileChangeGroup]] = [:]

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

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var order: [String] = []
        var dict: [String: [TurnFileChangeSummaryEntry]] = [:]
        for entry in entries {
            let groupKey = entry.action?.rawValue ?? "Edited"
            if dict[groupKey] == nil { order.append(groupKey) }
            dict[groupKey, default: []].append(entry)
        }
        let result = order.map { FileChangeGroup(key: $0, entries: dict[$0]!) }

        lock.lock()
        if cache.count >= maxEntries {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = result
        lock.unlock()

        return result
    }
}
