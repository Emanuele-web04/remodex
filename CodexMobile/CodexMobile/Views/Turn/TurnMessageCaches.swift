// FILE: TurnMessageCaches.swift
// Purpose: Thread-safe caches for parsed markdown, file-change state, command status, diff chunks,
//   code comment directives, and file-change grouping.
// Layer: View Support
// Exports: MarkdownRenderableTextCache, FileChangeRenderState, MessageRowRenderModel,
//   CommandExecutionStatusCache, FileChangeSystemRenderCache, FileChangeBlockPresentation,
//   FileChangeBlockPresentationBuilder, PerFileDiffChunk, PerFileDiffParser, PerFileDiffChunkCache,
//   CodeCommentDirectiveContentCache, FileChangeGroupingCache
// Depends on: Foundation, CodexMessage, TurnMessageRegexCache, TurnFileChangeSummaryParser,
//   TurnDiffLineKind, MarkdownRenderProfile, TurnMermaidRenderer, CommandExecutionViews

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

// Thread-safe bounded cache that evicts roughly half its entries when full instead of discarding everything.
final class BoundedCache<Key: Hashable, Value> {
    private let maxEntries: Int
    private let lock = NSLock()
    private var storage: [Key: Value] = [:]
    private var accessOrder: [Key] = []

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[key] else { return nil }
        markRecentlyUsed(key)
        return value
    }

    func set(_ key: Key, value: Value) {
        lock.lock()
        evictIfNeeded()
        storage[key] = value
        markRecentlyUsed(key)
        lock.unlock()
    }

    func getOrSet(_ key: Key, builder: () -> Value) -> Value {
        lock.lock()
        if let cached = storage[key] {
            markRecentlyUsed(key)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let built = builder()

        lock.lock()
        evictIfNeeded()
        storage[key] = built
        markRecentlyUsed(key)
        lock.unlock()

        return built
    }

    func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: false)
        accessOrder.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func evictIfNeeded() {
        guard storage.count >= maxEntries else { return }
        let evictCount = maxEntries / 2
        let keysToRemove = Array(accessOrder.prefix(evictCount))
        for key in keysToRemove {
            storage.removeValue(forKey: key)
        }
        accessOrder.removeFirst(min(evictCount, accessOrder.count))
    }

    private func markRecentlyUsed(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        if accessOrder.count > maxEntries * 2 {
            accessOrder = accessOrder.filter { storage[$0] != nil }
        }
    }
}

enum TurnTextCacheKey {
    private static let sampleByteCount = 24
    private static let hexDigits = Array("0123456789abcdef")

    static func fingerprint(for text: String) -> String {
        let utf8 = text.utf8
        let byteCount = utf8.count
        let middleStart = max((byteCount / 2) - (sampleByteCount / 2), 0)
        let lastStart = max(byteCount - sampleByteCount, 0)

        return [
            String(byteCount),
            hexSample(in: utf8, startOffset: 0, length: sampleByteCount),
            hexSample(in: utf8, startOffset: middleStart, length: sampleByteCount),
            hexSample(in: utf8, startOffset: lastStart, length: sampleByteCount),
        ].joined(separator: "|")
    }

    static func key(messageID: String, kind: String, text: String) -> String {
        "\(messageID)|\(kind)|\(fingerprint(for: text))"
    }

    static func key(namespace: String, text: String) -> String {
        "\(namespace)|\(fingerprint(for: text))"
    }

    static func stableFingerprint(for text: String) -> String {
        let byteCount = text.utf8.count
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(byteCount)|\(String(hash, radix: 16))"
    }

    static func stableKey(namespace: String, text: String) -> String {
        "\(namespace)|\(stableFingerprint(for: text))"
    }

    static func entriesFingerprint(_ entries: [TurnFileChangeSummaryEntry]) -> String {
        var hasher = Hasher()
        hasher.combine(entries.count)
        for entry in entries {
            hasher.combine(entry.path)
            hasher.combine(entry.action)
            hasher.combine(entry.additions)
            hasher.combine(entry.deletions)
        }
        return String(hasher.finalize())
    }

    private static func hexSample(
        in utf8: String.UTF8View,
        startOffset: Int,
        length: Int
    ) -> String {
        guard !utf8.isEmpty else { return "" }

        let clampedLength = min(length, utf8.count)
        let clampedStart = min(max(startOffset, 0), max(utf8.count - clampedLength, 0))
        let startIndex = utf8.index(utf8.startIndex, offsetBy: clampedStart)
        let endIndex = utf8.index(startIndex, offsetBy: clampedLength)

        var result = String()
        result.reserveCapacity(clampedLength * 2)

        for byte in utf8[startIndex..<endIndex] {
            result.append(hexDigits[Int(byte >> 4)])
            result.append(hexDigits[Int(byte & 0x0F)])
        }

        return result
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

struct FileChangeBlockPresentation {
    let entries: [TurnFileChangeSummaryEntry]
    let bodyText: String
}

private struct FileChangeBlockAggregate {
    var path: String
    var additions: Int
    var deletions: Int
    var action: TurnFileChangeAction?
    var diffSections: [String]
    var lastTotalsSourceIndex: Int
}

private struct RawFileChangeDiffSection {
    let path: String
    let action: TurnFileChangeAction?
    let additions: Int
    let deletions: Int
    let diffCode: String
}

// Builds one per-file diff model from raw file-change messages so Totals stay authoritative
// while diff hunks remain purely visual context.
enum FileChangeBlockPresentationBuilder {
    static func build(from messages: [CodexMessage]) -> FileChangeBlockPresentation? {
        guard !messages.isEmpty else {
            return nil
        }

        var aggregates: [FileChangeBlockAggregate] = []
        aggregates.reserveCapacity(messages.count)

        for (messageIndex, message) in messages.enumerated() {
            let parsedEntries = TurnFileChangeSummaryParser.parse(from: message.text)?.entries ?? []
            let diffSections = RawFileChangeDiffSectionParser.parse(
                bodyText: message.text,
                fallbackPaths: parsedEntries.map(\.path)
            )

            for section in diffSections {
                mergeDiffSection(section, sourceIndex: messageIndex, into: &aggregates)
            }

            for entry in parsedEntries {
                mergeSummaryEntry(entry, sourceIndex: messageIndex, into: &aggregates)
            }
        }

        let entries = aggregates.map { aggregate in
            TurnFileChangeSummaryEntry(
                path: aggregate.path,
                additions: aggregate.additions,
                deletions: aggregate.deletions,
                action: aggregate.action
            )
        }
        guard !entries.isEmpty else {
            return nil
        }

        let bodyText = aggregates.map { aggregate in
            let action = aggregate.action?.rawValue.lowercased() ?? "edited"
            let diffBody = aggregate.diffSections.isEmpty
                ? ""
                : """

                ```diff
                \(aggregate.diffSections.joined(separator: "\n\n"))
                ```
                """

            return """
            Path: \(aggregate.path)
            Kind: \(action)
            Totals: +\(aggregate.additions) -\(aggregate.deletions)\(diffBody)
            """
        }
        .joined(separator: "\n\n---\n\n")

        return FileChangeBlockPresentation(entries: entries, bodyText: bodyText)
    }

    private static func mergeSummaryEntry(
        _ entry: TurnFileChangeSummaryEntry,
        sourceIndex: Int,
        into aggregates: inout [FileChangeBlockAggregate]
    ) {
        if let existingIndex = aggregates.firstIndex(where: {
            FileChangePathIdentity.representsSameFile($0.path, entry.path)
        }) {
            let existing = aggregates[existingIndex]
            var updated = existing
            updated.path = FileChangePathIdentity.preferredDisplayPath(existing.path, entry.path)
            updated.action = mergedFileChangeAction(existing: existing.action, incoming: entry.action)

            if sourceIndex >= existing.lastTotalsSourceIndex {
                updated.additions = entry.additions
                updated.deletions = entry.deletions
                updated.lastTotalsSourceIndex = sourceIndex
            }

            aggregates[existingIndex] = updated
            return
        }

        aggregates.append(
            FileChangeBlockAggregate(
                path: entry.path,
                additions: entry.additions,
                deletions: entry.deletions,
                action: entry.action,
                diffSections: [],
                lastTotalsSourceIndex: sourceIndex
            )
        )
    }

    private static func mergeDiffSection(
        _ section: RawFileChangeDiffSection,
        sourceIndex: Int,
        into aggregates: inout [FileChangeBlockAggregate]
    ) {
        let normalizedDiff = section.diffCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDiff.isEmpty else {
            return
        }

        if let existingIndex = aggregates.firstIndex(where: {
            FileChangePathIdentity.representsSameFile($0.path, section.path)
        }) {
            var existing = aggregates[existingIndex]
            existing.path = FileChangePathIdentity.preferredDisplayPath(existing.path, section.path)
            existing.action = mergedFileChangeAction(existing: existing.action, incoming: section.action)

            if existing.diffSections.contains(normalizedDiff) {
                aggregates[existingIndex] = existing
                return
            }

            if existing.diffSections.isEmpty {
                existing.additions = section.additions
                existing.deletions = section.deletions
            } else {
                existing.additions += section.additions
                existing.deletions += section.deletions
            }
            existing.lastTotalsSourceIndex = max(existing.lastTotalsSourceIndex, sourceIndex)
            existing.diffSections.append(normalizedDiff)
            aggregates[existingIndex] = existing
            return
        }

        aggregates.append(
            FileChangeBlockAggregate(
                path: section.path,
                additions: section.additions,
                deletions: section.deletions,
                action: section.action,
                diffSections: [normalizedDiff],
                lastTotalsSourceIndex: sourceIndex
            )
        )
    }

    private static func mergedFileChangeAction(
        existing: TurnFileChangeAction?,
        incoming: TurnFileChangeAction?
    ) -> TurnFileChangeAction? {
        switch (existing, incoming) {
        case let (lhs?, rhs?) where lhs == rhs:
            return lhs
        case (.added, _), (_, .added):
            return .added
        case (.deleted, _), (_, .deleted):
            return .deleted
        case (.renamed, _), (_, .renamed):
            return .renamed
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (.edited, _), (_, .edited):
            return .edited
        case (nil, nil):
            return nil
        }
    }
}

enum FileChangeBlockPresentationCache {
    private static let cache = BoundedCache<String, FileChangeBlockPresentation?>(maxEntries: 128)

    static func presentation(from messages: [CodexMessage]) -> FileChangeBlockPresentation? {
        guard !messages.isEmpty else { return nil }
        let key = messages.map { message in
            TurnTextCacheKey.key(messageID: message.id, kind: "block-file-change", text: message.text)
        }.joined(separator: "||")
        return cache.getOrSet(key) {
            FileChangeBlockPresentationBuilder.build(from: messages)
        }
    }

    static func reset() {
        cache.removeAll()
    }
}

private enum RawFileChangeDiffSectionParser {
    static func parse(bodyText: String, fallbackPaths: [String]) -> [RawFileChangeDiffSection] {
        let sections = bodyText.components(separatedBy: "\n\n---\n\n")
        if sections.count > 1 {
            return sections.enumerated().compactMap { index, section in
                parseSection(
                    lines: section.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                    fallbackPath: index < fallbackPaths.count ? fallbackPaths[index] : nil
                )
            }
        }

        let lines = bodyText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rawSections: [RawFileChangeDiffSection] = []
        var currentPath: String?
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsedPath = extractPath(from: [trimmed]) {
                currentPath = parsedPath
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
                    let resolvedPath = currentPath
                        ?? parsePathFromDiff(lines: codeLines)
                        ?? (rawSections.count < fallbackPaths.count ? fallbackPaths[rawSections.count] : nil)
                    if let resolvedPath, !resolvedPath.isEmpty {
                        let totals = countDiffLines(in: codeLines)
                        rawSections.append(
                            RawFileChangeDiffSection(
                                path: resolvedPath,
                                action: detectAction(from: codeLines),
                                additions: totals.additions,
                                deletions: totals.deletions,
                                diffCode: code
                            )
                        )
                    }
                    currentPath = nil
                }
                continue
            }

            i += 1
        }

        return rawSections
    }

    private static func parseSection(lines: [String], fallbackPath: String?) -> RawFileChangeDiffSection? {
        guard let code = extractFencedCode(from: lines),
              TurnDiffLineKind.detectVerifiedPatch(in: code) else {
            return nil
        }
        let resolvedPath = extractPath(from: lines) ?? fallbackPath
        guard let resolvedPath, !resolvedPath.isEmpty else {
            return nil
        }

        let totals = countDiffLines(in: code.components(separatedBy: "\n"))
        return RawFileChangeDiffSection(
            path: resolvedPath,
            action: extractKind(from: lines) ?? detectAction(from: code.components(separatedBy: "\n")),
            additions: totals.additions,
            deletions: totals.deletions,
            diffCode: code
        )
    }

    private static func extractPath(from lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("**Path:**") || trimmed.hasPrefix("Path:") {
                let raw = trimmed
                    .replacingOccurrences(of: "**Path:**", with: "")
                    .replacingOccurrences(of: "Path:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if !raw.isEmpty {
                    return raw
                }
            }
        }
        return nil
    }

    private static func extractKind(from lines: [String]) -> TurnFileChangeAction? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("kind:") else { continue }
            let value = trimmed.dropFirst("Kind:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return TurnFileChangeAction.fromKind(value)
        }
        return nil
    }

    private static func extractFencedCode(from lines: [String]) -> String? {
        var inFence = false
        var codeLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                if inFence {
                    return codeLines.joined(separator: "\n")
                }
                inFence = true
                codeLines = []
                continue
            }
            if inFence {
                codeLines.append(line)
            }
        }
        return inFence ? codeLines.joined(separator: "\n") : nil
    }

    private static func parsePathFromDiff(lines: [String]) -> String? {
        for line in lines where line.hasPrefix("+++ ") {
            let candidate = normalizeDiffPath(String(line.dropFirst(4)))
            if !candidate.isEmpty {
                return candidate
            }
        }

        for line in lines where line.hasPrefix("diff --git ") {
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            if components.count >= 4 {
                let candidate = normalizeDiffPath(String(components[3]))
                if !candidate.isEmpty {
                    return candidate
                }
            }
        }

        return nil
    }

    private static func normalizeDiffPath(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/dev/null" else { return "" }
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    private static func countDiffLines(in lines: [String]) -> TurnDiffLineTotals {
        var totals = TurnDiffLineTotals()
        for line in lines {
            if line.isEmpty || isDiffMetadataLine(line) {
                continue
            }
            if line.hasPrefix("+") {
                totals.additions += 1
            } else if line.hasPrefix("-") {
                totals.deletions += 1
            }
        }
        return totals
    }

    private static func detectAction(from lines: [String]) -> TurnFileChangeAction? {
        if lines.contains(where: { $0.hasPrefix("rename from ") || $0.hasPrefix("rename to ") }) {
            return .renamed
        }
        if lines.contains(where: { $0.hasPrefix("new file mode ") || $0 == "--- /dev/null" }) {
            return .added
        }
        if lines.contains(where: { $0.hasPrefix("deleted file mode ") || $0 == "+++ /dev/null" }) {
            return .deleted
        }
        return .edited
    }

    private static func isDiffMetadataLine(_ line: String) -> Bool {
        let metadataPrefixes = [
            "+++",
            "---",
            "diff --git",
            "@@",
            "index ",
            "\\ No newline",
            "new file mode",
            "deleted file mode",
            "similarity index",
            "rename from",
            "rename to",
        ]

        return metadataPrefixes.contains { line.hasPrefix($0) }
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

// ─── File Change Path Identity ────────────────────────────────

enum FileChangePathIdentity {
    // Treats absolute-vs-relative references to the same repo file as one identity,
    // while keeping same-named files in different directories separate.
    static func representsSameFile(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLHS = normalizedPath(lhs)
        let normalizedRHS = normalizedPath(rhs)

        guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else {
            return false
        }
        if normalizedLHS == normalizedRHS {
            return true
        }

        let lhsIsAbsolute = isAbsolutePath(lhs)
        let rhsIsAbsolute = isAbsolutePath(rhs)
        guard lhsIsAbsolute != rhsIsAbsolute else {
            return false
        }

        let absolutePath = lhsIsAbsolute ? normalizedLHS : normalizedRHS
        let relativePath = lhsIsAbsolute ? normalizedRHS : normalizedLHS
        guard relativePath.contains("/") else {
            return false
        }

        return absolutePath.hasSuffix("/" + relativePath)
    }

    static func preferredDisplayPath(_ lhs: String, _ rhs: String) -> String {
        let trimmedLHS = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRHS = rhs.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedLHS.isEmpty { return trimmedRHS }
        if trimmedRHS.isEmpty { return trimmedLHS }
        if trimmedLHS == trimmedRHS { return trimmedLHS }
        if representsSameFile(trimmedLHS, trimmedRHS) {
            return trimmedLHS.count <= trimmedRHS.count ? trimmedLHS : trimmedRHS
        }
        return trimmedLHS
    }

    static func normalizedPath(_ rawPath: String) -> String {
        var normalized = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("a/") || normalized.hasPrefix("b/") {
            normalized = String(normalized.dropFirst(2))
        }
        if normalized.hasPrefix("./") {
            normalized = String(normalized.dropFirst(2))
        }
        if let range = normalized.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            normalized.removeSubrange(range)
        }
        return normalized.lowercased()
    }

    private static func isAbsolutePath(_ rawPath: String) -> Bool {
        rawPath.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
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
        return consolidate(chunks: chunks)
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

        return consolidate(chunks: chunks)
    }

    // Collapses repeated snapshots for the same file into one card and appends
    // distinct hunks in-order so users can inspect the full file history in one place.
    private static func consolidate(chunks: [PerFileDiffChunk]) -> [PerFileDiffChunk] {
        guard chunks.count > 1 else {
            return chunks
        }

        var consolidated: [PerFileDiffChunk] = []
        consolidated.reserveCapacity(chunks.count)

        for chunk in chunks {
            if let existingIndex = consolidated.firstIndex(where: {
                FileChangePathIdentity.representsSameFile($0.path, chunk.path)
            }) {
                let existing = consolidated[existingIndex]
                let isExactDuplicate = existing.diffCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    == chunk.diffCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    && existing.additions == chunk.additions
                    && existing.deletions == chunk.deletions
                    && existing.action == chunk.action
                let mergedDiff = mergedDiffCode(existing.diffCode, chunk.diffCode)
                consolidated[existingIndex] = PerFileDiffChunk(
                    id: existing.id,
                    path: FileChangePathIdentity.preferredDisplayPath(existing.path, chunk.path),
                    action: mergedAction(existing.action, chunk.action),
                    additions: isExactDuplicate ? existing.additions : (existing.additions + chunk.additions),
                    deletions: isExactDuplicate ? existing.deletions : (existing.deletions + chunk.deletions),
                    diffCode: mergedDiff
                )
            } else {
                consolidated.append(chunk)
            }
        }

        return consolidated
    }

    private static func mergedDiffCode(_ lhs: String, _ rhs: String) -> String {
        let trimmedLHS = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRHS = rhs.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedLHS.isEmpty { return trimmedRHS }
        if trimmedRHS.isEmpty { return trimmedLHS }
        if trimmedLHS == trimmedRHS { return trimmedLHS }
        return "\(trimmedLHS)\n\n\(trimmedRHS)"
    }

    private static func mergedAction(
        _ lhs: TurnFileChangeAction,
        _ rhs: TurnFileChangeAction
    ) -> TurnFileChangeAction {
        if lhs == rhs {
            return lhs
        }
        let precedence: [TurnFileChangeAction] = [.added, .deleted, .renamed, .edited]
        let lhsRank = precedence.firstIndex(of: lhs) ?? precedence.count
        let rhsRank = precedence.firstIndex(of: rhs) ?? precedence.count
        return lhsRank <= rhsRank ? lhs : rhs
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

    static func reset() { cache.removeAll() }

    static func chunks(messageID: String, bodyText: String, entries: [TurnFileChangeSummaryEntry]) -> [PerFileDiffChunk] {
        let key = "\(TurnTextCacheKey.key(messageID: messageID, kind: "per-file-diff", text: bodyText))|\(TurnTextCacheKey.entriesFingerprint(entries))"
        return cache.getOrSet(key) {
            PerFileDiffParser.parse(bodyText: bodyText, entries: entries)
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
