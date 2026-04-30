// FILE: CommandExecutionViews.swift
// Purpose: Inline command execution row, humanizer, and detail sheet.
// Layer: View Components
// Exports: CommandExecutionCardBody, CommandExecutionDetailSheet, CommandExecutionStatusModel, CommandExecutionStatusAccent, CommandHumanizer
// Depends on: SwiftUI, CommandExecutionDetails, AppFont

import SwiftUI

// MARK: - Models

enum CommandExecutionStatusAccent: String {
    case running
    case completed
    case failed

    // Keep tool-call status colors aligned with the inline command language used elsewhere in the app.
    private static let commandColor = Color(.command)

    var color: Color {
        switch self {
        case .running:
            return Self.commandColor
        case .completed:
            return .secondary
        case .failed:
            return .red
        }
    }
}

struct CommandExecutionStatusModel {
    let command: String
    let statusLabel: String
    let accent: CommandExecutionStatusAccent
}

struct CommandOutputImageReference: Identifiable, Equatable {
    let path: String

    var id: String { path }

    var fileName: String {
        let basename = (path as NSString).lastPathComponent
        return basename.isEmpty ? path : basename
    }
}

struct AssistantMarkdownImageReference: Identifiable, Equatable {
    let id: String
    let path: String
    let altText: String

    init(path: String, altText: String, occurrenceIndex: Int) {
        self.id = "\(occurrenceIndex)|\(path)"
        self.path = path
        self.altText = altText
    }

    var fileName: String {
        let basename = (path as NSString).lastPathComponent
        return basename.isEmpty ? path : basename
    }

    var displayTitle: String {
        let trimmedAlt = altText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAlt.isEmpty ? "Image" : trimmedAlt
    }

    var isTemporaryScreenshotImage: Bool {
        AssistantMarkdownImageReferenceParser.isTemporaryScreenshotImagePath(path)
    }

    var isCodexGeneratedImage: Bool {
        AssistantMarkdownImageReferenceParser.isCodexGeneratedImagePath(path)
    }
}

enum AssistantMarkdownContentSegment: Identifiable, Equatable {
    case text(id: Int, value: String)
    case image(AssistantMarkdownImageReference)

    var id: String {
        switch self {
        case .text(let id, _):
            return "text-\(id)"
        case .image(let reference):
            return reference.id
        }
    }
}

enum AssistantMarkdownImageReferenceParser {
    private static let markdownImageRegex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)

    static func references(in text: String) -> [AssistantMarkdownImageReference] {
        var references: [AssistantMarkdownImageReference] = []
        var isInsideFence = false
        var occurrenceIndex = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if isFenceDelimiter(line) {
                isInsideFence.toggle()
                continue
            }
            guard !isInsideFence else {
                continue
            }

            references.append(contentsOf: validImageMatches(in: line).map { match in
                defer { occurrenceIndex += 1 }
                return AssistantMarkdownImageReference(
                    path: match.path,
                    altText: match.altText,
                    occurrenceIndex: occurrenceIndex
                )
            })
        }

        return references
    }

    static func visibleTextRemovingImageSyntax(from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var isInsideFence = false
        let transformedLines = lines.compactMap { line -> String? in
            if isFenceDelimiter(line) {
                isInsideFence.toggle()
                return line
            }
            guard !isInsideFence else {
                return line
            }

            let matches = validImageMatches(in: line)
            guard !matches.isEmpty else {
                return line
            }

            let lineWithoutImageSyntax = NSMutableString(string: line)
            for match in matches.reversed() {
                lineWithoutImageSyntax.replaceCharacters(in: match.range, with: "")
            }
            if String(lineWithoutImageSyntax).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }

            let transformedLine = NSMutableString(string: line)
            for match in matches.reversed() {
                let replacement = replacementText(for: match)
                transformedLine.replaceCharacters(in: match.range, with: replacement)
            }

            let nextLine = String(transformedLine)
            return nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : nextLine
        }

        return transformedLines.joined(separator: "\n")
    }

    // Keeps temporary screenshots in their authored markdown position while generated images remain trailing previews.
    static func contentSegmentsPreservingTemporaryImages(from text: String) -> [AssistantMarkdownContentSegment] {
        var segments: [AssistantMarkdownContentSegment] = []
        var isInsideFence = false
        var occurrenceIndex = 0
        var textSegmentID = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func appendText(_ value: String) {
            guard !value.isEmpty else { return }
            if case .text(let id, let existing)? = segments.last {
                segments[segments.count - 1] = .text(id: id, value: existing + value)
            } else {
                segments.append(.text(id: textSegmentID, value: value))
                textSegmentID += 1
            }
        }

        for (lineIndex, line) in lines.enumerated() {
            let lineSuffix = lineIndex < lines.count - 1 ? "\n" : ""
            if isFenceDelimiter(line) {
                appendText(line + lineSuffix)
                isInsideFence.toggle()
                continue
            }
            guard !isInsideFence else {
                appendText(line + lineSuffix)
                continue
            }

            let matches = validImageMatches(in: line)
            guard !matches.isEmpty else {
                appendText(line + lineSuffix)
                continue
            }

            let nsLine = line as NSString
            var cursor = 0
            for match in matches {
                if match.range.location > cursor {
                    appendText(nsLine.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                }

                let reference = AssistantMarkdownImageReference(
                    path: match.path,
                    altText: match.altText,
                    occurrenceIndex: occurrenceIndex
                )
                occurrenceIndex += 1
                if reference.isTemporaryScreenshotImage {
                    segments.append(.image(reference))
                }

                cursor = match.range.location + match.range.length
            }
            if cursor < nsLine.length {
                appendText(nsLine.substring(from: cursor))
            }
            appendText(lineSuffix)
        }

        return segments.filter { segment in
            if case .text(_, let value) = segment {
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }

    static func isTemporaryScreenshotImagePath(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        return normalized.hasPrefix("/tmp/")
            || normalized.hasPrefix("/private/tmp/")
            || (normalized.hasPrefix("/private/var/folders/") && normalized.contains("/t/"))
    }

    static func isCodexGeneratedImagePath(_ path: String) -> Bool {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
            .contains("/.codex/generated_images/")
    }

    private static func markdownImageMatches(in text: String) -> [(range: NSRange, altText: String, path: String)] {
        guard let regex = markdownImageRegex else {
            return []
        }

        let nsText = text as NSString
        let protectedRanges = TurnMessageRegexCache.inlineCodeRanges(in: text)
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard !TurnMessageRegexCache.rangeOverlaps(match.range, protectedRanges: protectedRanges) else {
                return nil
            }
            guard match.numberOfRanges > 2 else { return nil }
            let alt = nsText.substring(with: match.range(at: 1))
            let path = nsText.substring(with: match.range(at: 2))
            return (match.range, alt, normalizedImagePath(path))
        }
    }

    private static func validImageMatches(in text: String) -> [(range: NSRange, altText: String, path: String)] {
        markdownImageMatches(in: text).filter { match in
            CommandOutputImageReferenceParser.isImagePath(match.path)
        }
    }

    private static func isFenceDelimiter(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
    }

    private static func normalizedImagePath(_ raw: String) -> String {
        var candidate = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>"))

        if candidate.hasPrefix("file://") {
            candidate = String(candidate.dropFirst("file://".count))
        }
        return candidate.removingPercentEncoding ?? candidate
    }

    private static func replacementText(for match: (range: NSRange, altText: String, path: String)) -> String {
        let trimmedAlt = match.altText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAlt.isEmpty {
            return trimmedAlt
        }

        let basename = (match.path as NSString).lastPathComponent
        return basename.isEmpty ? "Image" : basename
    }
}

enum CommandOutputImageReferenceParser {
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif"
    ]

    // Extracts a local image path without touching disk; the bridge validates and reads it on tap.
    static func firstReference(
        command: String,
        outputTail: String,
        cwd: String? = nil
    ) -> CommandOutputImageReference? {
        let listingDirectory = listingDirectory(from: command, cwd: cwd)
        for candidate in outputCandidates(from: outputTail) {
            if let path = normalizedImagePath(candidate, relativeTo: listingDirectory ?? cwd) {
                return CommandOutputImageReference(path: path)
            }
        }

        for candidate in commandCandidates(from: command) {
            if let path = normalizedImagePath(candidate, relativeTo: cwd) {
                return CommandOutputImageReference(path: path)
            }
        }

        return nil
    }

    private static func outputCandidates(from outputTail: String) -> [String] {
        var candidates = markdownLinkTargets(in: outputTail)
        let lines = outputTail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        candidates.append(contentsOf: lines)
        candidates.append(contentsOf: absoluteImagePathMatches(in: outputTail))
        return candidates
    }

    private static func commandCandidates(from command: String) -> [String] {
        shellTokens(from: unwrapShellCommand(command))
    }

    private static func markdownLinkTargets(in text: String) -> [String] {
        let pattern = #"!?\[[^\]]*\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsText.substring(with: match.range(at: 1))
        }
    }

    private static func absoluteImagePathMatches(in text: String) -> [String] {
        let extensionAlternation = imageExtensions.joined(separator: "|")
        let pattern = #"(?i)(file://)?(/[^\s\]\)"'`]+\.("#
            + extensionAlternation
            + #"))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            return nsText.substring(with: match.range(at: 2))
        }
    }

    private static func normalizedImagePath(_ raw: String, relativeTo baseDirectory: String?) -> String? {
        var candidate = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>"))

        while let last = candidate.last, ",.;:".contains(last) {
            candidate.removeLast()
        }

        if candidate.hasPrefix("file://") {
            candidate = String(candidate.dropFirst("file://".count))
        }
        candidate = candidate.removingPercentEncoding ?? candidate

        guard isImagePath(candidate) else {
            return nil
        }

        if candidate.hasPrefix("/") {
            return candidate
        }

        guard let baseDirectory,
              baseDirectory.hasPrefix("/") else {
            return nil
        }
        return (baseDirectory as NSString).appendingPathComponent(candidate)
    }

    static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    private static func listingDirectory(from command: String, cwd: String?) -> String? {
        let tokens = shellTokens(from: unwrapShellCommand(command))
        guard let tool = tokens.first.map({ ($0 as NSString).lastPathComponent.lowercased() }),
              tool == "ls" else {
            return nil
        }

        let pathCandidates = tokens.dropFirst().filter { token in
            !token.hasPrefix("-")
        }
        guard let listedPath = pathCandidates.last else {
            return cwd
        }
        if isImagePath(listedPath) {
            return (listedPath as NSString).deletingLastPathComponent
        }
        if listedPath.hasPrefix("/") {
            return listedPath
        }
        guard let cwd, cwd.hasPrefix("/") else {
            return nil
        }
        return (cwd as NSString).appendingPathComponent(listedPath)
    }

    private static func unwrapShellCommand(_ raw: String) -> String {
        let tokens = shellTokens(from: raw)
        guard !tokens.isEmpty else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let shellNames = ["bash", "zsh", "sh", "fish"]
        var shellIndex = 0
        if tokens.count >= 2 {
            let first = (tokens[0] as NSString).lastPathComponent.lowercased()
            let second = (tokens[1] as NSString).lastPathComponent.lowercased()
            if first == "env", shellNames.contains(second) {
                shellIndex = 1
            }
        }

        let shell = (tokens[shellIndex] as NSString).lastPathComponent.lowercased()
        guard shellNames.contains(shell) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var index = shellIndex + 1
        while index < tokens.count {
            let token = tokens[index]
            if ["-c", "-lc", "-cl", "-ic", "-ci"].contains(token) {
                let commandStart = index + 1
                guard commandStart < tokens.count else {
                    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return tokens[commandStart...].joined(separator: " ")
            }
            index += 1
        }

        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shellTokens(from value: String) -> [String] {
        var tokens: [String] = []
        var buffer = ""
        var quote: Character?
        var isEscaping = false

        for character in value {
            if isEscaping {
                buffer.append(character)
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    buffer.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !buffer.isEmpty {
                    tokens.append(buffer)
                    buffer = ""
                }
                continue
            }
            buffer.append(character)
        }

        if !buffer.isEmpty {
            tokens.append(buffer)
        }
        return tokens
    }
}

// MARK: - Card Body

struct CommandExecutionCardBody: View {
    let command: String
    let statusLabel: String
    let accent: CommandExecutionStatusAccent

    // Cached at struct level — humanize() does string parsing so we avoid
    // re-running it on every body evaluation during streaming updates.
    private static let humanizeCache = BoundedCache<String, CommandHumanizer.Info>(maxEntries: 128)

    private var display: CommandHumanizer.Info {
        let key = "\(command)|\(accent == .running)"
        if let cached = Self.humanizeCache.get(key) { return cached }
        let info = CommandHumanizer.humanize(command, isRunning: accent == .running)
        Self.humanizeCache.set(key, value: info)
        return info
    }

    var body: some View {
        HStack(spacing: 0) {
            (
                Text(display.verb)
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(.secondary)
                +
                Text(" " + display.target)
                    .font(AppFont.subheadline())
                    .foregroundStyle(.tertiary)
            )
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 6)

            Text(statusLabel)
                .font(AppFont.caption())
                .foregroundStyle(accent == .failed ? Color.red : Color.secondary.opacity(0.5))

            Image(systemName: "chevron.right")
                .font(AppFont.system(size: 8, weight: .semibold))
                .foregroundStyle(.quaternary)
                .padding(.leading, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tool rows update often while commands stream; keep the subtree static to avoid whole-row flashing.
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

// MARK: - Command Humanizer

/// Translates raw CLI commands into human-readable labels for the timeline.
/// The full command is still available in the detail sheet on tap.
enum CommandHumanizer {
    struct Info {
        let verb: String
        let target: String
    }

    static func humanize(_ raw: String, isRunning: Bool) -> Info {
        let command = unwrapShell(raw)
        let (tool, args) = splitToolAndArgs(command)

        switch tool {
        case "cat", "nl", "head", "tail", "sed", "less", "more":
            return Info(
                verb: isRunning ? "Reading" : "Read",
                target: lastPathComponents(from: args, fallback: "file")
            )
        case "rg", "grep", "ag", "ack":
            return Info(
                verb: isRunning ? "Searching" : "Searched",
                target: searchSummary(from: args)
            )
        case "ls":
            return Info(
                verb: isRunning ? "Listing" : "Listed",
                target: lastPathComponents(from: args, fallback: "directory")
            )
        case "find", "fd":
            return Info(
                verb: isRunning ? "Finding" : "Found",
                target: lastPathComponents(from: args, fallback: "files")
            )
        case "mkdir":
            return Info(
                verb: isRunning ? "Creating" : "Created",
                target: lastPathComponents(from: args, fallback: "directory")
            )
        case "rm":
            return Info(
                verb: isRunning ? "Removing" : "Removed",
                target: lastPathComponents(from: args, fallback: "file")
            )
        case "cp", "mv":
            return Info(
                verb: isRunning ? (tool == "cp" ? "Copying" : "Moving") : (tool == "cp" ? "Copied" : "Moved"),
                target: lastPathComponents(from: args, fallback: "file")
            )
        case "git":
            return gitInfo(args, isRunning: isRunning)
        default:
            return Info(
                verb: isRunning ? "Running" : "Ran",
                target: command
            )
        }
    }

    // MARK: - Shell unwrapping

    /// Strips `bash -lc "cd /path && real_command"` wrappers and pipeline
    /// suffixes to surface the primary command for humanization.
    private static func unwrapShell(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Match common shell wrapper patterns: bash/sh with -c or -lc
        let lowered = result.lowercased()
        let shellPrefixes = [
            "/usr/bin/bash -lc ", "/usr/bin/bash -c ",
            "/bin/bash -lc ", "/bin/bash -c ",
            "bash -lc ", "bash -c ",
            "/bin/sh -c ", "sh -c ",
        ]

        for prefix in shellPrefixes {
            guard lowered.hasPrefix(prefix) else { continue }
            result = String(result.dropFirst(prefix.count))
            // Strip surrounding quotes
            if (result.hasPrefix("\"") && result.hasSuffix("\""))
                || (result.hasPrefix("'") && result.hasSuffix("'")) {
                result = String(result.dropFirst().dropLast())
            }
            // Strip `cd //path &&` prefix
            if let andIndex = result.range(of: "&&") {
                result = String(result[andIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            break
        }

        // Pipeline: take the first command only.
        // `nl -ba File.tsx | sed -n '220,240p'` → `nl -ba File.tsx`
        // The downstream commands are output filters, not meaningful for the label.
        if let pipeIndex = result.range(of: " | ") {
            result = String(result[result.startIndex..<pipeIndex.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        return result
    }

    // MARK: - Parsing helpers

    private static func splitToolAndArgs(_ command: String) -> (tool: String, args: String) {
        let parts = command.split(separator: " ", maxSplits: 1)
        let rawTool = parts.first.map(String.init) ?? command
        // Resolve full paths like /usr/bin/nl → nl
        let tool = (rawTool as NSString).lastPathComponent.lowercased()
        let args = parts.count > 1 ? String(parts[1]) : ""
        return (tool, args)
    }

    /// Extracts the last meaningful file path from args, skipping flags.
    private static func lastPathComponents(from args: String, fallback: String) -> String {
        // Walk args in reverse to find the last non-flag token (typically the path).
        let tokens = args.split(separator: " ")
        for token in tokens.reversed() {
            let s = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !s.isEmpty, !s.hasPrefix("-") else { continue }
            return compactPath(s)
        }
        return fallback
    }

    /// Keeps the last two path components for readability: `a/b/c/d.swift` → `c/d.swift`.
    private static func compactPath(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 2 else { return path }
        return components.suffix(2).joined(separator: "/")
    }

    /// Builds a compact search description: `rg -n "pattern" path` → `for pattern in path`.
    /// Handles quoted patterns that contain spaces and special characters.
    private static func searchSummary(from args: String) -> String {
        let (pattern, path) = extractSearchPatternAndPath(from: args)
        let displayPattern = pattern ?? "..."
        if let path {
            return "for \(displayPattern) in \(path)"
        }
        return "for \(displayPattern)"
    }

    /// Splits search args into (pattern, path) respecting quoted strings.
    /// `rg -n "project.model \|\| FOO" src/` → ("project.model...", "src/")
    private static func extractSearchPatternAndPath(from args: String) -> (pattern: String?, path: String?) {
        let chars = Array(args)
        var tokens: [String] = []
        var i = 0

        while i < chars.count {
            // Skip whitespace
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { break }

            if chars[i] == "\"" || chars[i] == "'" {
                // Quoted token — collect until matching close quote
                let quote = chars[i]
                i += 1
                var buf = ""
                while i < chars.count, chars[i] != quote {
                    if chars[i] == "\\" && i + 1 < chars.count { buf.append(chars[i + 1]); i += 2 }
                    else { buf.append(chars[i]); i += 1 }
                }
                if i < chars.count { i += 1 } // skip closing quote
                tokens.append(buf)
            } else {
                // Unquoted token
                var buf = ""
                while i < chars.count, chars[i] != " " { buf.append(chars[i]); i += 1 }
                tokens.append(buf)
            }
        }

        // Walk tokens: skip flags, first positional = pattern, second = path
        var pattern: String?
        var path: String?
        var skipNext = false

        for token in tokens {
            if skipNext { skipNext = false; continue }
            if token.hasPrefix("-") {
                if token == "-t" || token == "-g" || token == "--type" || token == "--glob" || token == "--max-count" {
                    skipNext = true
                }
                continue
            }
            if pattern == nil {
                // Truncate very long regex patterns for readability
                pattern = token.count > 30 ? String(token.prefix(27)) + "..." : token
            } else if path == nil {
                path = compactPath(token)
            }
        }

        return (pattern, path)
    }

    // MARK: - Git

    private static func gitInfo(_ args: String, isRunning: Bool) -> Info {
        let parts = args.split(separator: " ", maxSplits: 1)
        let sub = parts.first.map(String.init) ?? ""

        switch sub {
        case "status": return Info(verb: isRunning ? "Checking" : "Checked", target: "git status")
        case "diff":   return Info(verb: isRunning ? "Comparing" : "Compared", target: "changes")
        case "log":    return Info(verb: isRunning ? "Viewing" : "Viewed", target: "git log")
        case "add":    return Info(verb: isRunning ? "Staging" : "Staged", target: "changes")
        case "commit": return Info(verb: isRunning ? "Committing" : "Committed", target: "changes")
        case "push":   return Info(verb: isRunning ? "Pushing" : "Pushed", target: "to remote")
        case "pull":   return Info(verb: isRunning ? "Pulling" : "Pulled", target: "from remote")
        case "checkout", "switch":
            let branch = parts.count > 1
                ? String(parts[1]).split(separator: " ").last.map(String.init) ?? ""
                : ""
            return Info(verb: isRunning ? "Switching to" : "Switched to", target: branch.isEmpty ? "branch" : branch)
        default:
            return Info(verb: isRunning ? "Running" : "Ran", target: "git " + args)
        }
    }
}

// MARK: - Detail Sheet

struct CommandExecutionDetailSheet: View {
    let status: CommandExecutionStatusModel
    let details: CommandExecutionDetails?
    @Environment(\.dismiss) private var dismiss
    @State private var isOutputExpanded = false
    private let commandAccent = CommandExecutionStatusAccent.running.color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                commandSection
                metadataSection
                if let details, !details.outputTail.isEmpty {
                    outputSection
                }
            }
            .padding()
        }
        .presentationDragIndicator(.visible)
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command", systemImage: "terminal.fill")
                .font(AppFont.mono(.caption))
                .foregroundStyle(commandAccent)

            Text(details?.fullCommand ?? status.command)
                .font(AppFont.mono(.callout))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cwd = details?.cwd, !cwd.isEmpty {
                metadataRow(label: "Directory", value: cwd)
            }
            if let exitCode = details?.exitCode {
                metadataRow(
                    label: "Exit code",
                    value: "\(exitCode)",
                    valueColor: exitCode == 0 ? .green : .red
                )
            }
            if let durationMs = details?.durationMs {
                metadataRow(label: "Duration", value: formattedDuration(durationMs))
            }
            metadataRow(label: "Status", value: status.statusLabel, valueColor: status.accent.color)
        }
    }

    private func metadataRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(AppFont.mono(.caption))
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOutputExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOutputExpanded ? "chevron.down" : "chevron.right")
                        .font(AppFont.system(size: 10, weight: .semibold))
                    Text("Output (last \(CommandExecutionDetails.maxOutputLines) lines)")
                        .font(AppFont.mono(.caption))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isOutputExpanded, let output = details?.outputTail {
                Text(output)
                    .font(AppFont.mono(.caption2))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
            }
        }
    }

    private func formattedDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return "\(minutes)m \(remainingSeconds)s"
    }
}

// MARK: - Previews

#Preview("Humanized Commands") {
    VStack(alignment: .leading, spacing: 12) {
        CommandExecutionCardBody(
            command: "/usr/bin/bash -lc \"cd /home/user/project && npm install\"",
            statusLabel: "running",
            accent: .running
        )
        CommandExecutionCardBody(
            command: "nl -ba apps/server/src/provider/Layers.swift",
            statusLabel: "completed",
            accent: .completed
        )
        CommandExecutionCardBody(
            command: "rg -n \"project.model\" apps/server/src",
            statusLabel: "completed",
            accent: .completed
        )
        CommandExecutionCardBody(
            command: "git status",
            statusLabel: "completed",
            accent: .completed
        )
        CommandExecutionCardBody(
            command: "python3 train.py --epochs 100 --lr 0.001",
            statusLabel: "failed",
            accent: .failed
        )
    }
    .padding(.horizontal, 16)
}
