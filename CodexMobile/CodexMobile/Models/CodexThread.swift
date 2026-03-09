// FILE: CodexThread.swift
// Purpose: Represents a Codex conversation thread returned by thread/list and related events.
// Layer: Model
// Exports: CodexThread
// Depends on: JSONValue

import Foundation

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
        try container.encode(syncState, forKey: .syncState)
    }
}

extension CodexThread {
    // --- UI helpers -----------------------------------------------------------
    private static let noProjectGroupKey = "__no_project__"
    var displayTitle: String {
        let cleanedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPreview = preview?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer explicit thread name (AI/user rename) over server title fallback.
        if let cleanedName, !cleanedName.isEmpty {
            return cleanedName
        }

        guard let cleanedTitle, !cleanedTitle.isEmpty else {
            if let cleanedPreview, !cleanedPreview.isEmpty {
                let firstCharacter = cleanedPreview.prefix(1).uppercased()
                let remainingCharacters = cleanedPreview.dropFirst()
                return firstCharacter + remainingCharacters
            }

            return "Conversation"
        }

        return cleanedTitle
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

        guard let cwd else {
            return nil
        }

        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Stable key for grouping threads by project.
    var projectKey: String {
        normalizedProjectPath ?? Self.noProjectGroupKey
    }

    // User-facing project label shown in the sidebar section header.
    var projectDisplayName: String {
        guard let normalizedProjectPath else {
            return "No Project"
        }

        let lastComponent = (normalizedProjectPath as NSString).lastPathComponent
        if !lastComponent.isEmpty, lastComponent != "/" {
            return lastComponent
        }

        return normalizedProjectPath
    }

    // --- Date parsing ---------------------------------------------------------

    private static let iso8601Formatters: [ISO8601DateFormatter] = {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        return [withFractions, standard]
    }()

    private static func decodeDateIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> Date? {
        for key in keys {
            if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
                if let parsedDate = parseISO8601(stringValue) {
                    return parsedDate
                }
            }

            if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
                return decodeUnixTimestamp(doubleValue)
            }

            if let intValue = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return decodeUnixTimestamp(Double(intValue))
            }

            // Keep native Date decoding as a final fallback for unexpected formats.
            if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
                return date
            }
        }

        return nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        for formatter in iso8601Formatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    // Supports both seconds and milliseconds timestamps.
    private static func decodeUnixTimestamp(_ rawValue: Double) -> Date {
        let secondsValue = rawValue > 10_000_000_000 ? rawValue / 1000 : rawValue
        return Date(timeIntervalSince1970: secondsValue)
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

    private static func normalizeProjectPath(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed == "/" {
            return trimmed
        }

        var normalized = trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        return normalized.isEmpty ? "/" : normalized
    }
}
