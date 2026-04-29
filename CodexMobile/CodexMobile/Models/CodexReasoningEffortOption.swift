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
        case value
        case label
        case description
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer().decode(String.self) {
            reasoningEffort = singleValue.trimmingCharacters(in: .whitespacesAndNewlines)
            description = ""
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        let camelEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        let snakeEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffortSnake)
        let valueEffort = try container.decodeIfPresent(String.self, forKey: .value)
        let effort = camelEffort ?? snakeEffort ?? valueEffort ?? ""

        reasoningEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        description = (try container.decodeIfPresent(String.self, forKey: .description) ?? label ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(description, forKey: .description)
    }
}
