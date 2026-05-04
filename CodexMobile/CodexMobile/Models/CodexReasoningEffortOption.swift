// FILE: CodexReasoningEffortOption.swift
// Purpose: Represents one reasoning effort option for a runtime model.
// Layer: Model
// Exports: CodexReasoningEffortOption
// Depends on: Foundation

import Foundation

struct CodexReasoningEffortOption: Identifiable, Codable, Hashable, Sendable {
    let reasoningEffort: String
    let description: String

    var id: String { reasoningEffort }

    init(reasoningEffort: String, description: String) {
        self.reasoningEffort = reasoningEffort
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case reasoningEffort
        case reasoningEffortSnake = "reasoning_effort"
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let camelEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        let snakeEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffortSnake)
        let effort = camelEffort ?? snakeEffort ?? ""

        reasoningEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        description = (try container.decodeIfPresent(String.self, forKey: .description) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(description, forKey: .description)
    }
}
