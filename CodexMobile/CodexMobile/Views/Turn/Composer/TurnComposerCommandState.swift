// FILE: TurnComposerCommandState.swift
// Purpose: Owns slash-command/review/fork state types and pure parsing helpers used by the composer.
// Layer: View Support
// Exports: BridgeSlashCommand, TurnComposerSlashCommand, TurnComposerSlashCommandItem,
//   TurnComposerSlashCommandSource, TurnComposerForkDestination, TurnComposerReviewTarget,
//   TurnComposerReviewSelection, TurnComposerSlashCommandPanelState, TurnTrailingSlashCommandToken,
//   TurnComposerCommandLogic
// Depends on: Foundation, CodexReviewTarget, CodexModelOption

import Foundation

enum SlashCommandSection: String, CaseIterable, Sendable {
    case codexBuiltin = "codex-builtin"
    case ocBuiltin = "oc-builtin"
    case agent
    case skillDerived = "skill"

    var displayTitle: String {
        switch self {
        case .codexBuiltin:
            return "Codex"
        case .ocBuiltin:
            return "OpenCode"
        case .agent:
            return "Agents"
        case .skillDerived:
            return "Skills"
        }
    }

    static let displayOrder: [SlashCommandSection] = [
        .codexBuiltin, .ocBuiltin, .agent, .skillDerived,
    ]

    init?(bridgeSectionHint: String?) {
        guard let bridgeSectionHint else { return nil }
        let normalized = bridgeSectionHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "codex", "codex-builtin":
            self = .codexBuiltin
        case "oc", "oc-builtin", "opencode", "opencode-builtin":
            self = .ocBuiltin
        case "agent", "agents":
            self = .agent
        case "skill", "skills", "skill-derived":
            self = .skillDerived
        default:
            return nil
        }
    }

    var defaultProviderID: String {
        switch self {
        case .codexBuiltin:
            return "codex"
        case .ocBuiltin, .agent, .skillDerived:
            return "opencode"
        }
    }
}

enum OpenCodeSlashBuiltins {
    static let tokens: Set<String> = [
        "/undo", "/redo", "/share", "/help", "/init", "/compact", "/login", "/logout",
        "/models", "/agents", "/skills", "/mcp", "/config", "/clear", "/exit",
    ]
}

struct BridgeSlashCommandArgumentField: Equatable, Sendable {
    let key: String
    let value: String
}

struct SlashCommandArgumentFieldSpec: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let isMultiline: Bool
}

struct BridgeSlashCommand: Codable, Equatable, Identifiable, Sendable {
    let token: String
    let title: String
    let description: String
    let requiresArguments: Bool
    let template: String?
    let hints: [String]?
    let source: String?
    let agent: String?
    let provider: String?
    let section: String?

    init(
        token: String,
        title: String,
        description: String,
        requiresArguments: Bool = false,
        template: String? = nil,
        hints: [String]? = nil,
        source: String? = nil,
        agent: String? = nil,
        provider: String? = nil,
        section: String? = nil
    ) {
        self.token = token
        self.title = title
        self.description = description
        self.requiresArguments = requiresArguments
        self.template = template
        self.hints = hints
        self.source = source
        self.agent = agent
        self.provider = provider
        self.section = section
    }

    enum CodingKeys: String, CodingKey {
        case token
        case title
        case description
        case requiresArguments
        case template
        case hints
        case source
        case agent
        case provider
        case section
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        requiresArguments = (try? container.decodeIfPresent(Bool.self, forKey: .requiresArguments)) ?? false
        template = try container.decodeIfPresent(String.self, forKey: .template)
        hints = try container.decodeIfPresent([String].self, forKey: .hints)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        section = try container.decodeIfPresent(String.self, forKey: .section)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(requiresArguments, forKey: .requiresArguments)
        try container.encodeIfPresent(template, forKey: .template)
        try container.encodeIfPresent(hints, forKey: .hints)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(section, forKey: .section)
    }

    var id: String { token }

    var argumentFieldSpecs: [SlashCommandArgumentFieldSpec] {
        let resolvedHints = resolvedArgumentHints
        if !resolvedHints.isEmpty {
            let argumentsOnly = resolvedHints.count == 1 && resolvedHints[0] == "$ARGUMENTS"
            return resolvedHints.map { hint in
                SlashCommandArgumentFieldSpec(
                    id: hint,
                    label: hint == "$ARGUMENTS" ? "Arguments" : hint,
                    isMultiline: argumentsOnly && hint == "$ARGUMENTS"
                )
            }
        }
        return extractedNumericPlaceholderKeys.map { placeholder in
            SlashCommandArgumentFieldSpec(
                id: placeholder,
                label: placeholder,
                isMultiline: false
            )
        }
    }

    private var resolvedArgumentHints: [String] {
        let trimmedHints = (hints ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return trimmedHints
    }

    private var extractedNumericPlaceholderKeys: [String] {
        guard let template else { return [] }
        let pattern = #"\$\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        var seen = Set<String>()
        var ordered: [String] = []
        for match in regex.matches(in: template, range: range) {
            guard let swiftRange = Range(match.range, in: template) else { continue }
            let token = String(template[swiftRange])
            if seen.insert(token).inserted {
                ordered.append(token)
            }
        }
        return ordered.sorted { lhs, rhs in
            let left = Int(lhs.dropFirst()) ?? 0
            let right = Int(rhs.dropFirst()) ?? 0
            return left < right
        }
    }

    private var searchBlob: String {
        "\(title) \(description) \(token)".lowercased()
    }

    func resolvedProviderID(for section: SlashCommandSection) -> String {
        let trimmedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedProvider.isEmpty {
            return trimmedProvider
        }
        return section.defaultProviderID
    }

    static func filtered(
        matching query: String,
        within commands: [BridgeSlashCommand]
    ) -> [BridgeSlashCommand] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else {
            return commands
        }
        return commands.filter { $0.searchBlob.contains(trimmedQuery) }
    }

    static func classifySection(
        for command: BridgeSlashCommand,
        openCodeBuiltins: Set<String> = OpenCodeSlashBuiltins.tokens,
        codexOverlapTokens: Set<String>,
        skillNames: Set<String> = []
    ) -> SlashCommandSection {
        if let explicit = SlashCommandSection(bridgeSectionHint: command.section) {
            return explicit
        }

        let normalizedSource = command.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalizedSource == "skill" {
            return .skillDerived
        }

        let normalizedToken = command.token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let skillToken = normalizedToken.hasPrefix("/") ? String(normalizedToken.dropFirst()) : normalizedToken
        if skillNames.contains(skillToken) {
            return .skillDerived
        }

        if normalizedSource == "mcp" {
            return .agent
        }
        let trimmedAgent = command.agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAgent.isEmpty || normalizedToken == "/agents" {
            return .agent
        }
        let classificationBlob = "\(command.title) \(command.description)".lowercased()
        if classificationBlob.contains("agent") {
            return .agent
        }

        if openCodeBuiltins.contains(normalizedToken) {
            return .ocBuiltin
        }

        if codexOverlapTokens.contains(normalizedToken) {
            return .codexBuiltin
        }

        return .ocBuiltin
    }

    static func groupedSections(
        commands: [BridgeSlashCommand],
        matching query: String = "",
        openCodeBuiltins: Set<String> = OpenCodeSlashBuiltins.tokens,
        codexOverlapTokens: Set<String>,
        skillNames: Set<String> = []
    ) -> [(section: SlashCommandSection, commands: [BridgeSlashCommand])] {
        let filtered = filtered(matching: query, within: commands)
        var buckets: [SlashCommandSection: [BridgeSlashCommand]] = [:]
        for command in filtered {
            let section = classifySection(
                for: command,
                openCodeBuiltins: openCodeBuiltins,
                codexOverlapTokens: codexOverlapTokens,
                skillNames: skillNames
            )
            buckets[section, default: []].append(command)
        }
        return SlashCommandSection.displayOrder.compactMap { section in
            guard let sectionCommands = buckets[section], !sectionCommands.isEmpty else {
                return nil
            }
            return (section: section, commands: sectionCommands)
        }
    }
}

enum TurnComposerSlashCommandSource: Equatable, Sendable {
    case disabled
    case codexEnum
    case bridgeCommands
}

enum TurnComposerSlashCommandRouting {
    static func source(
        supportsSlashCommands: Bool,
        modelProvider: String
    ) -> TurnComposerSlashCommandSource {
        guard supportsSlashCommands else {
            return .disabled
        }
        if CodexService.usesBridgeSlashCommands(modelProvider: modelProvider) {
            return .bridgeCommands
        }
        return .codexEnum
    }
}

enum TurnComposerSlashCommandItem: Identifiable, Equatable, Sendable {
    case codex(TurnComposerSlashCommand)
    case bridge(BridgeSlashCommand)

    var id: String {
        switch self {
        case .codex(let command):
            return "codex:\(command.rawValue)"
        case .bridge(let command):
            return "bridge:\(command.token)"
        }
    }

    var commandToken: String {
        switch self {
        case .codex(let command):
            return command.commandToken
        case .bridge(let command):
            return command.token
        }
    }

    var title: String {
        switch self {
        case .codex(let command):
            return command.title
        case .bridge(let command):
            return command.title
        }
    }

    var subtitle: String {
        switch self {
        case .codex(let command):
            return command.subtitle
        case .bridge(let command):
            return command.description
        }
    }

    var codexCommand: TurnComposerSlashCommand? {
        if case .codex(let command) = self {
            return command
        }
        return nil
    }

    static func filtered(
        matching query: String,
        within commands: [TurnComposerSlashCommandItem]
    ) -> [TurnComposerSlashCommandItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else {
            return commands
        }
        return commands.filter { item in
            let blob = "\(item.title) \(item.subtitle) \(item.commandToken)".lowercased()
            return blob.contains(trimmedQuery)
        }
    }
}

enum TurnComposerSlashCommand: String, Identifiable, Codable, Equatable, Sendable {
    case codeReview
    case compact
    case feedback
    case fork
    case status
    case subagents

    static let allCommands: [TurnComposerSlashCommand] = [.codeReview, .compact, .feedback, .fork, .status, .subagents]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codeReview:
            return "Code Review"
        case .compact:
            return "Compact"
        case .feedback:
            return "Feedback"
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
        case .compact:
            return "Summarize older context to keep this thread lean"
        case .feedback:
            return "Share feedback on Remodex with the developer"
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
        case .compact:
            return "arrow.down.right.and.arrow.up.left"
        case .feedback:
            return "envelope"
        case .fork:
            return "remodex.fork"
        case .status:
            return "speedometer"
        case .subagents:
            return "point.3.connected.trianglepath.dotted"
        }
    }

    var commandToken: String {
        switch self {
        case .codeReview:
            return "/review"
        case .compact:
            return "/compact"
        case .feedback:
            return "/feedback"
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
        case .codeReview, .compact, .feedback, .fork, .status:
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

    static func availableCommands(
        allowsForkCommand: Bool,
        includeCodexOnlyCommands: Bool = true
    ) -> [TurnComposerSlashCommand] {
        return allCommands.filter { command in
            switch command {
            case .fork:
                return allowsForkCommand
            case .codeReview, .subagents:
                return includeCodexOnlyCommands
            case .compact, .feedback, .status:
                return true
            }
        }
    }

    static func availableCommandsForProvider(
        allowsForkCommand: Bool,
        modelProvider: String
    ) -> [TurnComposerSlashCommand] {
        let includeCodexOnly = CodexModelOption.normalizedProvider(modelProvider) != "opencode"
        return availableCommands(
            allowsForkCommand: allowsForkCommand,
            includeCodexOnlyCommands: includeCodexOnly
        )
    }

    // openCodeExcludedTokens removed (RP-CMD-3): no longer filters bridge data for OC (dynamic primary).
    // Codex enum assumptions updated; availableCommandsForProvider and allCommands kept for codex paths only.

    // Strengthened minimal hardcoded cross-provider tokens (per Issue 3 + PR desc) for degraded/bridge-down
    // + codex parity when dynamic bridge unavailable for OC/usesBridge. Dynamic bridge list is primary.
    // These become .bridge(...) items (synthetic) so that selection for OC always goes to insert-token path.
    static let minimalFallbackSlashCommandTokens: [String] = ["/compact", "/review", "/help"]

    static func minimalFallbackSlashCommands() -> [BridgeSlashCommand] {
        minimalFallbackSlashCommandTokens.map { token in
            switch token {
            case "/compact":
                return BridgeSlashCommand(token: "/compact", title: "Compact", description: "Summarize older context to keep this thread lean")
            case "/review":
                return BridgeSlashCommand(token: "/review", title: "Code Review", description: "Run the reviewer on your local changes")
            case "/help":
                return BridgeSlashCommand(token: "/help", title: "Help", description: "Show available commands and usage")
            default:
                return BridgeSlashCommand(token: token, title: token, description: "")
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

enum TurnComposerReviewTarget: String, Codable, Equatable, Sendable {
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

    // Mirror used by thread-start callers (NewChatDraftView, TurnView) when they
    // need to seed `CodexPendingThreadComposerAction.codeReview` for a brand-new
    // thread without duplicating the case mapping.
    var codexPendingTarget: CodexPendingCodeReviewTarget {
        switch self {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch:
            return .baseBranch
        }
    }
}

struct TurnComposerReviewSelection: Codable, Equatable, Sendable {
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
