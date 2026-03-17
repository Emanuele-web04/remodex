// FILE: TurnComposerCommandState.swift
// Purpose: Owns slash-command/review-mode state types and pure parsing helpers used by the composer.
// Layer: View Support
// Exports: TurnComposerSlashCommand, TurnComposerReviewTarget, TurnComposerReviewSelection, TurnComposerSlashCommandPanelState, TurnTrailingSlashCommandToken, TurnComposerCommandLogic
// Depends on: Foundation, CodexReviewTarget

import Foundation

enum TurnComposerSlashCommand: String, Identifiable, Equatable {
    case codeReview
    case status
    case subagents

    static let allCommands: [TurnComposerSlashCommand] = [.codeReview, .status, .subagents]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codeReview:
            return "Code Review"
        case .status:
            return "Status"
        case .subagents:
            return "Subagents"
        }
    }

    var subtitle: String {
        switch self {
        case .codeReview:
            return "Run the reviewer on your local changes"
        case .status:
            return "Show context usage and rate limits"
        case .subagents:
            return "Insert a canned prompt that asks Codex to delegate work"
        }
    }

    var symbolName: String {
        switch self {
        case .codeReview:
            return "ladybug"
        case .status:
            return "speedometer"
        case .subagents:
            return "person.3"
        }
    }

    var commandToken: String {
        switch self {
        case .codeReview:
            return "/review"
        case .status:
            return "/status"
        case .subagents:
            return "/subagents"
        }
    }

    // Supplies canned prompt text for slash actions that expand into the visible draft.
    var cannedPrompt: String? {
        switch self {
        case .subagents:
            return "Run subagents for different tasks. Delegate distinct work in parallel when helpful and then synthesize the results."
        case .codeReview, .status:
            return nil
        }
    }

    private var searchBlob: String {
        "\(title) \(subtitle) \(commandToken)".lowercased()
    }

    static func filtered(matching query: String) -> [TurnComposerSlashCommand] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else {
            return allCommands
        }
        return allCommands.filter { $0.searchBlob.contains(trimmedQuery) }
    }
}

enum TurnComposerReviewTarget: String, Equatable {
    case uncommittedChanges
    case baseBranch

    var title: String {
        switch self {
        case .uncommittedChanges:
            return "Uncommitted changes"
        case .baseBranch:
            return "Base branch"
        }
    }

    var codexReviewTarget: CodexReviewTarget {
        switch self {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch:
            return .baseBranch
        }
    }
}

struct TurnComposerReviewSelection: Equatable {
    let command: TurnComposerSlashCommand
    let target: TurnComposerReviewTarget?
}

enum TurnComposerSlashCommandPanelState: Equatable {
    case hidden
    case commands(query: String)
    case codeReviewTargets
}

struct TurnTrailingSlashCommandToken: Equatable {
    let query: String
    let tokenRange: Range<String.Index>
}

enum TurnComposerCommandLogic {
    // Keeps review-mode conflict checks pure so they can be reused without touching observed state.
    static func hasContentConflictingWithReview(
        trimmedInput: String,
        mentionedFileCount: Int,
        mentionedSkillCount: Int,
        attachmentCount: Int,
        hasSubagentsSelection: Bool
    ) -> Bool {
        let draftText = removingTrailingSlashCommandToken(in: trimmedInput) ?? trimmedInput
        return !draftText.isEmpty
            || mentionedFileCount > 0
            || mentionedSkillCount > 0
            || attachmentCount > 0
            || hasSubagentsSelection
    }

    // Parses only a final `/query` token so ordinary prose and paths do not trigger the command menu.
    static func trailingSlashCommandToken(in text: String) -> TurnTrailingSlashCommandToken? {
        guard !text.isEmpty,
              let slashIndex = text.lastIndex(of: "/") else {
            return nil
        }

        if slashIndex > text.startIndex {
            let previousIndex = text.index(before: slashIndex)
            guard text[previousIndex].isWhitespace else {
                return nil
            }
        }

        let queryStart = text.index(after: slashIndex)
        let query = String(text[queryStart..<text.endIndex])
        guard !query.contains(where: { $0.isWhitespace }) else {
            return nil
        }

        return TurnTrailingSlashCommandToken(
            query: query,
            tokenRange: slashIndex..<text.endIndex
        )
    }

    static func removingTrailingSlashCommandToken(in text: String) -> String? {
        guard let token = trailingSlashCommandToken(in: text) else {
            return nil
        }

        var updated = text
        updated.replaceSubrange(token.tokenRange, with: "")
        return updated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replacingTrailingSlashCommandToken(
        in text: String,
        with replacement: String
    ) -> String? {
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplacement.isEmpty,
              let token = trailingSlashCommandToken(in: text) else {
            return nil
        }

        var updated = text
        updated.replaceSubrange(token.tokenRange, with: trimmedReplacement)
        return updated
    }
}
