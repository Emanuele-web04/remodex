// FILE: CodexRuntimeSettings.swift
// Purpose: Owner-confirmed next-turn choices, separate from device defaults and turn history.
// Layer: Model
// Exports: CodexRuntimeSettings
// Depends on: Foundation

import Foundation

struct CodexRuntimeSettings: Codable, Hashable, Sendable {
    let model: String?
    let reasoningEffort: String?
    let serviceTier: String?
    let revision: Int
    let updatedAt: Double
    let epoch: String
    let source: String
    var knownFields: Set<String>? = nil

    func contains(_ field: String) -> Bool { knownFields?.contains(field) ?? true }

    private enum CodingKeys: String, CodingKey {
        case model, reasoningEffort, serviceTier, revision, updatedAt, epoch, source, knownFields
    }
}

extension CodexRuntimeSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            model: try container.decodeIfPresent(String.self, forKey: .model),
            reasoningEffort: try container.decodeIfPresent(String.self, forKey: .reasoningEffort),
            serviceTier: try container.decodeIfPresent(String.self, forKey: .serviceTier),
            revision: try container.decode(Int.self, forKey: .revision),
            updatedAt: try container.decode(Double.self, forKey: .updatedAt),
            epoch: try container.decode(String.self, forKey: .epoch),
            source: try container.decode(String.self, forKey: .source),
            knownFields: try container.decodeIfPresent(Set<String>.self, forKey: .knownFields)
                ?? Set([CodingKeys.model, .reasoningEffort, .serviceTier].filter(container.contains).map(\.rawValue))
        )
    }
}
