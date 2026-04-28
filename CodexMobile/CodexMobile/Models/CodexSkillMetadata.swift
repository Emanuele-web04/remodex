// FILE: CodexSkillMetadata.swift
// Purpose: Skill metadata and mention payload types used by composer autocomplete + turn/start.
// Layer: Model
// Exports: CodexSkillMetadata, CodexPluginMetadata, CodexTurnSkillMention, CodexTurnMention
// Depends on: Foundation

import Foundation

struct CodexSkillMetadata: Decodable, Hashable, Sendable, Identifiable {
    let name: String
    let description: String?
    let path: String?
    let scope: String?
    let enabled: Bool

    var id: String {
        normalizedName
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case path
        case scope
        case enabled
    }

    init(
        name: String,
        description: String?,
        path: String?,
        scope: String?,
        enabled: Bool
    ) {
        self.name = name
        self.description = description
        self.path = path
        self.scope = scope
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct CodexTurnSkillMention: Hashable, Sendable {
    let id: String
    let name: String?
    let path: String?
}

struct CodexPluginMetadata: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let marketplaceName: String
    let marketplacePath: String?
    let displayName: String?
    let shortDescription: String?
    let installed: Bool
    let enabled: Bool
    let installPolicy: String?

    nonisolated var isAvailableForMention: Bool {
        installed || enabled || installPolicy == "INSTALLED_BY_DEFAULT"
    }

    nonisolated var mentionPath: String {
        "plugin://\(name)@\(marketplaceName)"
    }

    nonisolated var displayTitle: String {
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedDisplayName, !trimmedDisplayName.isEmpty {
            return trimmedDisplayName
        }
        return name
    }

    nonisolated var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated var searchBlob: String {
        [
            name,
            displayName ?? "",
            shortDescription ?? "",
            marketplaceName,
        ]
            .map(Self.normalizedDiscoveryText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    nonisolated func matchesSearch(query: String) -> Bool {
        let normalizedQuery = Self.normalizedDiscoveryText(query)
        return normalizedQuery.isEmpty || searchBlob.contains(normalizedQuery)
    }

    nonisolated static func normalizedDiscoveryText(_ value: String) -> String {
        let separators = CharacterSet(charactersIn: ":/_-")
        return value
            .lowercased()
            .components(separatedBy: separators)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct CodexPluginListResponse: Decodable {
    let marketplaces: [CodexPluginMarketplace]
}

struct CodexPluginMarketplace: Decodable {
    let name: String
    let path: String?
    let plugins: [CodexPluginListItem]
}

struct CodexPluginListItem: Decodable {
    let id: String
    let name: String
    let installed: Bool
    let enabled: Bool
    let installPolicy: String?
    let interface: CodexPluginInterface?
}

struct CodexPluginInterface: Decodable, Hashable, Sendable {
    let displayName: String?
    let shortDescription: String?
    let category: String?
    let developerName: String?
}

struct CodexTurnMention: Hashable, Sendable {
    let name: String
    let path: String
}
