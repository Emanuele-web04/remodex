// FILE: CodexServiceTier.swift
// Purpose: Catalog-driven speed choices, with legacy Fast identifiers normalized at decoding.
// Layer: Model
// Exports: CodexServiceTier
// Depends on: Foundation

import Foundation

struct CodexServiceTier: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    let displayName: String
    let description: String

    static let fast = CodexServiceTier(rawValue: "priority")!

    init?(rawValue: String) {
        self.init(id: rawValue, name: nil, description: nil)
    }

    init?(id: String, name: String?, description: String?) {
        let value = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "default" else { return nil }
        rawValue = value == "fast" ? "priority" : value
        displayName = name ?? (rawValue == "priority" ? "Fast" : value)
        self.description = description ?? (rawValue == "priority" ? "Lower latency using Codex Fast Mode." : "")
    }

    var iconName: String { rawValue == "priority" ? "bolt.fill" : "speedometer" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    private enum CodingKeys: String, CodingKey { case id, name, description }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self),
           let tier = Self(rawValue: value) {
            self = tier
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard let tier = Self(
            id: id,
            name: try container.decodeIfPresent(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description)
        ) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Empty service tier")
        }
        self = tier
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .id)
        try container.encode(displayName, forKey: .name)
        try container.encode(description, forKey: .description)
    }
}
