// FILE: TurnComposerCommandState.swift
// Purpose: Owns slash-command/review/fork state types and pure parsing helpers used by the composer.
// Layer: View Support
// Exports: TurnComposerSlashCommand, TurnComposerForkDestination, TurnComposerReviewTarget, TurnComposerReviewSelection, TurnComposerSlashCommandPanelState, TurnTrailingSlashCommandToken, TurnComposerCommandLogic
// Depends on: Foundation, CodexReviewTarget

import Foundation

enum TurnComposerSlashCommand: String, Identifiable, Equatable {
    case codeReview
    case fork
    case status
    case subagents

    static let allCommands: [TurnComposerSlashCommand] = [.codeReview, .fork, .status, .subagents]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codeReview:
            return "Code Review"
        case .fork:
            return "Fork"
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
        case .fork:
            return "Fork this thread into local or a new worktree"
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
        case .fork:
            return "arrow.triangle.branch"
        case .status:
            return "speedometer"
        case .subagents:
            return "person.crop.circle"
        }
    }

    var commandToken: String {
        switch self {
        case .codeReview:
            return "/review"
        case .fork:
            return "/fork"
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
        case .codeReview, .fork, .status:
            return nil
        }
    }

    private var searchBlob: String {
        "\(title) \(subtitle) \(commandToken)".lowercased()
    }

    static func filtered(
        matching query: String,
        within commands: [TurnComposerSlashCommand] = allCommands
    ) -> [TurnComposerSlashCommand] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else {
            return commands
        }
        return commands.filter { $0.searchBlob.contains(trimmedQuery) }
    }

    // Hides slash commands that the connected runtime cannot fulfill for this session.
    static func availableCommands(
        supportsThreadFork: Bool,
        allowsForkCommand: Bool
    ) -> [TurnComposerSlashCommand] {
        allCommands.filter { command in
            switch command {
            case .fork:
                return supportsThreadFork && allowsForkCommand
            case .codeReview, .status, .subagents:
                return true
            }
        }
    }
}

enum TurnComposerForkDestination: String, Identifiable, Equatable {
    case local
    case newWorktree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local:
            return "Fork into local"
        case .newWorktree:
            return "Fork into new worktree"
        }
    }

    var subtitle: String {
        switch self {
        case .local:
            return "Continue in a new local thread"
        case .newWorktree:
            return "Continue in a new worktree"
        }
    }

    var symbolName: String {
        switch self {
        case .local:
            return "laptopcomputer"
        case .newWorktree:
            return "arrow.up.right.square"
        }
    }

    // V1 keeps worktree-to-worktree branching out of scope so fork stays predictable.
    static func availableDestinations(
        canForkLocally: Bool,
        canCreateWorktree: Bool
    ) -> [TurnComposerForkDestination] {
        var destinations: [TurnComposerForkDestination] = []
        if canCreateWorktree {
            destinations.append(.newWorktree)
        }
        if canForkLocally {
            destinations.append(.local)
        }
        return destinations
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
    case forkDestinations([TurnComposerForkDestination])
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

    // Fork is only valid as the first slash action in an otherwise empty draft.
    static func canOfferForkSlashCommand(
        in text: String,
        mentionedFileCount: Int = 0,
        mentionedSkillCount: Int = 0,
        attachmentCount: Int = 0,
        hasReviewSelection: Bool = false,
        hasSubagentsSelection: Bool = false,
        isPlanModeArmed: Bool = false
    ) -> Bool {
        guard let token = trailingSlashCommandToken(in: text) else {
            return false
        }

        var remainingDraft = text
        remainingDraft.replaceSubrange(token.tokenRange, with: "")
        let trimmedRemainingDraft = remainingDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmedRemainingDraft.isEmpty
            && mentionedFileCount == 0
            && mentionedSkillCount == 0
            && attachmentCount == 0
            && !hasReviewSelection
            && !hasSubagentsSelection
            && !isPlanModeArmed
    }
}
