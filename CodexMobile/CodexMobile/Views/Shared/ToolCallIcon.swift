// FILE: ToolCallIcon.swift
// Purpose: Maps a generic tool-activity line to a leading Central icon.
// Layer: View Utility
// Exports: ToolCallIcon
// Depends on: Foundation, RemodexIcon (icon name resolution)

import Foundation

/// Resolves the leading icon for a generic tool-call row, mirroring the icon
/// logic used by the synara timeline (`workEntryIcon`): one uniform stroke icon
/// per tool family, keyed off the tool rather than per-tool tinting.
///
/// Returned values are SF Symbol names that `RemodexIcon` maps to the bundled
/// `central-*` template assets, so callers render them via
/// `RemodexIcon.image(systemName:)` and tint them with a single `foregroundStyle`.
///
/// Two activity-line shapes reach this resolver (see `CodexService+Incoming` /
/// `CodexService+History`):
///   * humanized, verb-first lines — `"Read foo.swift"`, `"Wrote bar.ts"`,
///     `"Exploring src/"` — produced by `extractToolCallActivityLines`.
///   * status-first lines — `"Running mcp__server__tool"`, `"Completed Read"` —
///     produced by `toolActivitySummaryLine`.
enum ToolCallIcon {
    /// Icon for a tool-activity summary line in either of the shapes above.
    static func systemName(forToolActivitySummary summary: String) -> String {
        let firstLine = summary
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? summary
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackSystemName }

        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let firstWord = words.first?.lowercased() ?? ""

        // Status-first lines classify on the tool/command that follows the status.
        if statusWords.contains(firstWord) {
            let remainder = words.dropFirst().joined(separator: " ")
            let resolved = systemName(forDescriptor: remainder)
            // "Running <something we couldn't classify>" still reads as command execution.
            if resolved == fallbackSystemName, firstWord == "running" {
                return "terminal"
            }
            return resolved
        }

        // Humanized verb-first lines map their leading verb directly so the icon
        // does not depend on substrings of the (often path-shaped) remainder.
        if let verbIcon = verbIcons[firstWord] {
            // Terminal-interaction lines ("Writing to terminal", "Reading terminal
            // output") keep the terminal glyph over the generic write/read icons.
            if isTerminalInteractionTarget(words.dropFirst()) {
                return "terminal"
            }
            return verbIcon
        }

        // Otherwise treat the whole line as a bare tool descriptor.
        return systemName(forDescriptor: trimmed)
    }

    /// Icon for a raw tool descriptor / tool name (no status word), e.g. `"WebSearch"`,
    /// `"mcp__server__tool"`, `"spawnAgent"`.
    static func systemName(forDescriptor descriptor: String?) -> String {
        let lower = (descriptor ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return fallbackSystemName }

        let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)

        // MCP tools keep one icon regardless of the verb they wrap. Require "mcp" as
        // the leading token so file/command names containing "mcp" don't false-match.
        if tokens.first == "mcp" {
            return tokens.contains("github") ? "remodex.github" : "remodex.skill"
        }

        let squished = tokens.joined()
        guard !squished.isEmpty else { return fallbackSystemName }
        for rule in rules where squished.contains(rule.needle) {
            return rule.systemName
        }
        return fallbackSystemName
    }

    private static let fallbackSystemName = "hammer"

    // Matches only humanized phrasings whose object is the terminal itself
    // ("to terminal", "terminal output"), not paths that merely contain the word.
    private static func isTerminalInteractionTarget<Words: Sequence>(_ remainder: Words) -> Bool
    where Words.Element == String {
        let words = remainder.map { $0.lowercased() }
        guard let first = words.first else { return false }
        if first == "terminal" { return true }
        return first == "to" && words.dropFirst().first == "terminal"
    }

    // Leading humanized verbs emitted by extractToolCallActivityLines, mapped to the
    // same families synara uses (file reads/inspection → search, writes/edits → pencil).
    private static let verbIcons: [String: String] = [
        "read": "magnifyingglass", "reading": "magnifyingglass",
        "open": "magnifyingglass", "opened": "magnifyingglass", "opening": "magnifyingglass",
        "explore": "magnifyingglass", "exploring": "magnifyingglass", "explored": "magnifyingglass",
        "list": "magnifyingglass", "listing": "magnifyingglass", "listed": "magnifyingglass",
        "find": "magnifyingglass", "finding": "magnifyingglass", "found": "magnifyingglass",
        "search": "magnifyingglass", "searching": "magnifyingglass", "searched": "magnifyingglass",
        "view": "magnifyingglass", "viewing": "magnifyingglass", "viewed": "magnifyingglass",
        "edit": "pencil", "editing": "pencil", "edited": "pencil",
        "write": "pencil", "writing": "pencil", "wrote": "pencil", "written": "pencil",
        "apply": "pencil", "applying": "pencil", "applied": "pencil",
        "create": "pencil", "creating": "pencil", "created": "pencil",
    ]

    // First substring match wins; ordered most-specific first so compound names
    // (todowrite, websearch, multiedit, …) resolve before their generic parts.
    private static let rules: [(needle: String, systemName: String)] = [
        // Plans / task lists
        ("todowrite", "checklist"),
        ("updateplan", "checklist"),
        ("exitplanmode", "checklist"),
        ("planmode", "checklist"),
        ("todo", "checklist"),
        ("plan", "checklist"),
        // Web
        ("websearch", "globe"),
        ("webfetch", "link"),
        ("fetch", "link"),
        // Edits / writes
        ("multiedit", "pencil"),
        ("notebookedit", "pencil"),
        ("applypatch", "pencil"),
        ("patch", "pencil"),
        ("edit", "pencil"),
        ("write", "pencil"),
        ("create", "pencil"),
        // Reads / search
        ("read", "magnifyingglass"),
        ("grep", "magnifyingglass"),
        ("ripgrep", "magnifyingglass"),
        ("glob", "magnifyingglass"),
        ("search", "magnifyingglass"),
        ("find", "magnifyingglass"),
        ("view", "magnifyingglass"),
        ("list", "magnifyingglass"),
        // Source control. Match Synara's compact work rows by using the GitHub
        // mark for git/gh/GitHub activity instead of the generic branch glyph.
        ("github", "remodex.github"),
        ("git", "remodex.github"),
        // Agents / sub-tasks
        ("subagent", "remodex.agent"),
        ("agent", "remodex.agent"),
        ("task", "remodex.agent"),
        // Shell
        ("bash", "terminal"),
        ("shell", "terminal"),
        ("command", "terminal"),
        ("exec", "terminal"),
        ("terminal", "terminal"),
        ("console", "terminal"),
    ]

    private static let statusWords: Set<String> = [
        "running", "completed", "complete", "failed", "stopped",
        "done", "finished", "ran", "succeeded", "success",
    ]
}
