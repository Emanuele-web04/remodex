// FILE: CodexSkillMetadata.swift
// Purpose: Skill metadata and mention payload types used by composer autocomplete + turn/start.
// Layer: Model
// Exports: CodexSkillMetadata, CodexTurnSkillMention
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
