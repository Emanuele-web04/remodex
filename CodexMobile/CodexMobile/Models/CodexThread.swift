// FILE: CodexThread.swift
// Purpose: Represents a Codex conversation thread returned by thread/list and related events,
//   including native subagent identity metadata used by the sidebar and parent-child navigation.
// Layer: Model
// Exports: CodexThread
// Depends on: JSONValue

import Foundation

enum CodexTimestampParser {
    private static let iso8601Formatters: [ISO8601DateFormatter] = {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        return [withFractions, standard]
    }()

    static func parseString(_ value: String?) -> Date? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        if let numeric = Double(trimmed) {
            return decodeUnixTimestamp(numeric)
        }

        for formatter in iso8601Formatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    // Accepts second, millisecond, microsecond, and nanosecond Unix timestamps.
    static func decodeUnixTimestamp(_ rawValue: Double) -> Date {
        let absoluteValue = abs(rawValue)
        let secondsValue: Double

        switch absoluteValue {
        case 1_000_000_000_000_000_000...:
            secondsValue = rawValue / 1_000_000_000
        case 1_000_000_000_000_000...:
            secondsValue = rawValue / 1_000_000
        case 10_000_000_000...:
            secondsValue = rawValue / 1_000
        default:
            secondsValue = rawValue
        }

        return Date(timeIntervalSince1970: secondsValue)
    }

    // Filters out placeholder dates so local optimistic timestamps are not replaced by epoch fallbacks.
    static func isTrustworthyServerDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970 >= 946_684_800 // 2000-01-01T00:00:00Z
    }
}

enum CodexThreadSyncState: String, Codable, Hashable, Sendable {
    case live
    case archivedLocal
}

struct CodexThread: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String?
    var name: String?
    var preview: String?
    var createdAt: Date?
    var updatedAt: Date?
    var cwd: String?
    var metadata: [String: JSONValue]?
    var forkedFromThreadId: String?
    var parentThreadId: String?
    var agentId: String?
    var agentNickname: String?
    var agentRole: String?
    var model: String?
    var modelProvider: String?
    var syncState: CodexThreadSyncState

    // --- Public initializer ---------------------------------------------------

    init(
        id: String,
        title: String? = nil,
        name: String? = nil,
        preview: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        cwd: String? = nil,
        metadata: [String: JSONValue]? = nil,
        forkedFromThreadId: String? = nil,
        parentThreadId: String? = nil,
        agentId: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        syncState: CodexThreadSyncState = .live
    ) {
        self.id = id
        self.title = title
        self.name = name
        self.preview = preview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cwd = Self.normalizeProjectPath(cwd)
        self.metadata = metadata
        self.forkedFromThreadId = Self.normalizeIdentifier(forkedFromThreadId)
        self.parentThreadId = Self.normalizeIdentifier(parentThreadId)
        self.agentId = Self.normalizeIdentifier(agentId)
        self.agentNickname = Self.normalizeIdentifier(agentNickname)
        self.agentRole = Self.normalizeIdentifier(agentRole)
        self.model = Self.normalizeIdentifier(model)
        self.modelProvider = Self.normalizeIdentifier(modelProvider)
        self.syncState = syncState
    }

    // --- Codable keys ---------------------------------------------------------

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case preview
        case createdAt
        case createdAtSnake = "created_at"
        case updatedAt
        case updatedAtSnake = "updated_at"
        case cwd
        case cwdSnake = "current_working_directory"
        case cwdWorkingDirectory = "working_directory"
        case metadata
        case forkedFromThreadId
        case forkedFromId = "forkedFromId"
        case forkedFromThreadIdSnake = "forked_from_thread_id"
        case forkedFromIdSnake = "forked_from_id"
        case parentThreadId
        case parentThreadIdSnake = "parent_thread_id"
        case agentId
        case agentIdSnake = "agent_id"
        case agentNickname
        case agentNicknameSnake = "agent_nickname"
        case agentRole
        case agentRoleSnake = "agent_role"
        case model
        case modelProvider
        case modelProviderSnake = "model_provider"
        case syncState
    }

    // --- Custom decoding ------------------------------------------------------

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        createdAt = try Self.decodeDateIfPresent(from: container, keys: [.createdAt, .createdAtSnake])
        updatedAt = try Self.decodeDateIfPresent(from: container, keys: [.updatedAt, .updatedAtSnake])
        cwd = Self.decodeStringIfPresent(from: container, keys: [.cwd, .cwdSnake, .cwdWorkingDirectory])
        metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        forkedFromThreadId = Self.decodeThreadIdentity(
            from: container,
            metadata: metadata,
            keys: [.forkedFromThreadId, .forkedFromId, .forkedFromThreadIdSnake, .forkedFromIdSnake],
            metadataKeys: ["forkedFromThreadId", "forked_from_thread_id", "forkedFromId", "forked_from_id"]
        )
        parentThreadId = Self.decodeThreadIdentity(
            from: container,
            metadata: metadata,
            keys: [.parentThreadId, .parentThreadIdSnake],
            metadataKeys: ["parentThreadId", "parent_thread_id"]
        )
        agentId = Self.decodeThreadIdentity(
            from: container,
            metadata: metadata,
            keys: [.agentId, .agentIdSnake],
            metadataKeys: ["agentId", "agent_id"]
        )
        agentNickname = Self.decodeThreadIdentity(
            from: container,
            metadata: metadata,
            keys: [.agentNickname, .agentNicknameSnake],
            metadataKeys: ["agentNickname", "agent_nickname", "nickname", "name"]
        )
        agentRole = Self.decodeThreadIdentity(
            from: container,
            metadata: metadata,
            keys: [.agentRole, .agentRoleSnake],
            metadataKeys: ["agentRole", "agent_role", "agentType", "agent_type"]
        )
        model = Self.decodeThreadIdentity(
            from: container,
            metadata: metadata,
            keys: [.model],
            metadataKeys: ["model", "modelName", "model_name"]
        )
        modelProvider = Self.decodeThreadIdentity(
            from: container,
            metadata: metadata,
            keys: [.modelProvider, .modelProviderSnake],
            metadataKeys: ["modelProvider", "model_provider", "modelProviderId", "model_provider_id"]
        )
        syncState = try container.decodeIfPresent(CodexThreadSyncState.self, forKey: .syncState) ?? .live
    }

    // --- Custom encoding ------------------------------------------------------

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(Self.normalizeProjectPath(cwd), forKey: .cwd)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(Self.normalizeIdentifier(forkedFromThreadId), forKey: .forkedFromThreadId)
        try container.encodeIfPresent(Self.normalizeIdentifier(parentThreadId), forKey: .parentThreadId)
        try container.encodeIfPresent(Self.normalizeIdentifier(agentId), forKey: .agentId)
        try container.encodeIfPresent(Self.normalizeIdentifier(agentNickname), forKey: .agentNickname)
        try container.encodeIfPresent(Self.normalizeIdentifier(agentRole), forKey: .agentRole)
        try container.encodeIfPresent(Self.normalizeIdentifier(model), forKey: .model)
        try container.encodeIfPresent(Self.normalizeIdentifier(modelProvider), forKey: .modelProvider)
        try container.encode(syncState, forKey: .syncState)
    }
}

extension CodexThread {
    // --- UI helpers -----------------------------------------------------------
    static let defaultDisplayTitle = "New Thread"
    private static let noProjectGroupKey = "__no_project__"

    // Old rollouts may still persist "Conversation", so treat both labels as the same placeholder.
    static func isGenericPlaceholderTitle(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }

        return ["Conversation", defaultDisplayTitle].contains {
            trimmed.localizedCaseInsensitiveCompare($0) == .orderedSame
        }
    }

    var displayTitle: String {
        let cleanedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAgentLabel = agentDisplayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPreview = preview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = Self.isGenericPlaceholderTitle(cleanedTitle) ? nil : cleanedTitle

        // Prefer explicit thread name (AI/user rename) over server title fallback.
        if let cleanedName, !cleanedName.isEmpty {
            return cleanedName
        }

        if let cleanedAgentLabel, !cleanedAgentLabel.isEmpty {
            if cleanedTitle == nil || Self.isGenericPlaceholderTitle(cleanedTitle) {
                return cleanedAgentLabel
            }
        }

        guard let effectiveTitle, !effectiveTitle.isEmpty else {
            if let cleanedPreview, !cleanedPreview.isEmpty {
                let firstCharacter = cleanedPreview.prefix(1).uppercased()
                let remainingCharacters = cleanedPreview.dropFirst()
                return firstCharacter + remainingCharacters
            }

            return Self.defaultDisplayTitle
        }

        return effectiveTitle
    }

    var isSubagent: Bool {
        parentThreadId != nil
    }

    // Fork badges use ancestry rather than cwd heuristics so local/worktree routing stays independent.
    var isForkedThread: Bool {
        forkedFromThreadId != nil
    }

    var preferredSubagentLabel: String? {
        guard isSubagent else { return nil }

        if let agentDisplayLabel {
            return agentDisplayLabel
        }

        for candidate in [name, title] {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  !Self.isGenericPlaceholderTitle(trimmed) else {
                continue
            }
            return trimmed
        }

        return nil
    }

    var derivedSubagentIdentity: (nickname: String?, role: String?)? {
        guard let label = preferredSubagentLabel else {
            return nil
        }

        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard trimmed.hasSuffix("]"),
              let openBracket = trimmed.lastIndex(of: "[") else {
            return (nickname: trimmed, role: nil)
        }

        let nickname = String(trimmed[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        let roleStart = trimmed.index(after: openBracket)
        let roleEnd = trimmed.index(before: trimmed.endIndex)
        let role = String(trimmed[roleStart..<roleEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            nickname: nickname.isEmpty ? nil : nickname,
            role: role.isEmpty ? nil : role
        )
    }

    var agentDisplayLabel: String? {
        let nickname = Self.sanitizedAgentIdentity(agentNickname) ?? ""
        let role = Self.sanitizedAgentIdentity(agentRole) ?? ""

        if !nickname.isEmpty && !role.isEmpty {
            return "\(nickname) [\(role)]"
        }
        if !nickname.isEmpty {
            return nickname
        }
        if !role.isEmpty {
            return role.capitalized
        }
        return nil
    }

    var modelDisplayLabel: String? {
        if let provider = modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            return provider
        }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            return model
        }
        return nil
    }

    // Normalized absolute project path used for stable grouping.
    var normalizedProjectPath: String? {
        Self.normalizeProjectPath(cwd)
    }

    // Best-effort repo root for project-scoped bridge features like git actions.
    var gitWorkingDirectory: String? {
        if let normalizedProjectPath {
            return normalizedProjectPath
        }
        return nil
    }

    // Stable key for grouping threads by project.
    var projectKey: String {
        normalizedProjectPath ?? Self.noProjectGroupKey
    }

    // User-facing project label shown in the sidebar section header.
    var projectDisplayName: String {
        Self.projectDisplayLabel(for: normalizedProjectPath)
    }

    // Reuses the same worktree detection across the sidebar, toolbar, and composer affordances.
    var isManagedWorktreeProject: Bool {
        Self.projectIconSystemName(for: normalizedProjectPath) == "arrow.triangle.branch"
    }

    // Distinguishes Codex-managed worktrees from the main repo in compact sidebar UIs.
    static func projectDisplayLabel(for normalizedProjectPath: String?) -> String {
        guard let normalizedProjectPath else {
            return "Cloud"
        }

        let baseLabel = projectBaseDisplayName(for: normalizedProjectPath)
        guard let worktreeToken = codexManagedWorktreeDisplayToken(for: normalizedProjectPath) else {
            return baseLabel
        }

        return "\(baseLabel) \(worktreeToken)"
    }

    static func projectIconSystemName(for normalizedProjectPath: String?) -> String {
        guard let normalizedProjectPath else {
            return "cloud"
        }

        return codexManagedWorktreeToken(for: normalizedProjectPath) == nil ? "laptopcomputer" : "arrow.triangle.branch"
    }

    // Shared path gate for every flow that needs to decide whether a cwd represents a real local project.
    static func normalizedFilesystemProjectPath(_ value: String?) -> String? {
        normalizeProjectPath(value)
    }

    // --- Date parsing ---------------------------------------------------------

    private static func decodeDateIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> Date? {
        for key in keys {
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                if let parsedDate = CodexTimestampParser.parseString(stringValue) {
                    return parsedDate
                }
            }

            if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
                return CodexTimestampParser.decodeUnixTimestamp(doubleValue)
            }

            if let intValue = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return CodexTimestampParser.decodeUnixTimestamp(Double(intValue))
            }

            // Keep native Date decoding as a final fallback for unexpected formats.
            if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
                return date
            }
        }

        return nil
    }
    private static func decodeStringIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let normalized = normalizeProjectPath(value) {
                return normalized
            }
        }

        return nil
    }

    private static func decodeThreadIdentity(
        from container: KeyedDecodingContainer<CodingKeys>,
        metadata: [String: JSONValue]?,
        keys: [CodingKeys],
        metadataKeys: [String]
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let normalized = normalizeIdentifier(value) {
                return normalized
            }
        }

        for metadataKey in metadataKeys {
            if let normalized = normalizeIdentifier(metadata?[metadataKey]?.stringValue) {
                return normalized
            }
        }

        return nil
    }

    private static func sanitizedAgentIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered == "collabagenttoolcall" || lowered == "collabtoolcall" {
            return nil
        }

        return trimmed
    }

    private static func normalizeIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeProjectPath(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let normalizedRootPath = normalizedFilesystemRootPath(trimmed) {
            return normalizedRootPath
        }

        var normalized = trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        if normalized.isEmpty {
            return "/"
        }

        guard isLikelyFilesystemPath(normalized) else {
            return nil
        }

        return normalized
    }

    // Preserves valid filesystem roots that would otherwise be mangled by generic trailing-slash trimming.
    private static func normalizedFilesystemRootPath(_ value: String) -> String? {
        if value == "/" {
            return "/"
        }

        if value.first == "~", value.dropFirst().allSatisfy({ $0 == "/" }) {
            return "~/"
        }

        let utf16View = value.utf16
        guard utf16View.count >= 3 else {
            return nil
        }

        let startIndex = utf16View.startIndex
        let first = utf16View[startIndex]
        let second = utf16View[utf16View.index(after: startIndex)]
        let thirdIndex = utf16View.index(startIndex, offsetBy: 2)
        let third = utf16View[thirdIndex]
        let isDriveLetter = (65...90).contains(first) || (97...122).contains(first)
        guard isDriveLetter, second == 58, third == 92 || third == 47 else {
            return nil
        }

        let remainder = value.dropFirst(3)
        guard remainder.allSatisfy({ $0 == "/" || $0 == "\\" }) else {
            return nil
        }

        let drive = UnicodeScalar(first).map(String.init) ?? "C"
        return "\(drive):/"
    }

    // Rejects pseudo-buckets like `server` or `_default` so only real local paths create project groups.
    private static func isLikelyFilesystemPath(_ value: String) -> Bool {
        if value == "/" {
            return true
        }

        if value.hasPrefix("/") || value.hasPrefix("~/") {
            return true
        }

        let utf16View = value.utf16
        guard utf16View.count >= 3 else {
            return false
        }

        let first = utf16View[utf16View.startIndex]
        let second = utf16View[utf16View.index(after: utf16View.startIndex)]
        let third = utf16View[utf16View.index(utf16View.startIndex, offsetBy: 2)]
        let isDriveLetter = (65...90).contains(first) || (97...122).contains(first)
        if isDriveLetter, second == 58, third == 92 || third == 47 {
            return true
        }

        return value.hasPrefix("\\\\")
    }

    private static func projectBaseDisplayName(for normalizedProjectPath: String) -> String {
        let lastComponent = (normalizedProjectPath as NSString).lastPathComponent
        if !lastComponent.isEmpty, lastComponent != "/" {
            return lastComponent
        }

        return normalizedProjectPath
    }

    private static func codexManagedWorktreeToken(for normalizedProjectPath: String) -> String? {
        let components = URL(fileURLWithPath: normalizedProjectPath).standardized.pathComponents
        guard let worktreesIndex = components.firstIndex(of: "worktrees"),
              worktreesIndex > 0,
              components[worktreesIndex - 1] == ".codex" else {
            return nil
        }

        let tokenIndex = components.index(after: worktreesIndex)
        guard components.indices.contains(tokenIndex) else {
            return nil
        }

        let token = components[tokenIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func codexManagedWorktreeDisplayToken(for normalizedProjectPath: String) -> String? {
        guard let token = codexManagedWorktreeToken(for: normalizedProjectPath) else {
            return nil
        }

        return "[\(token)]"
    }
}
