// FILE: CodexSlashCommand.swift
// Purpose: Models user-provided slash commands from the local bridge.
// Layer: Model
// Exports: CodexSlashCommand
// Depends on: Foundation

import Foundation

struct CodexSlashCommand: Codable, Identifiable, Equatable {
    let token: String
    let title: String
    let subtitle: String?
    let symbolName: String?
    let content: String?
    let argumentHint: String?

    var id: String {
        normalizedToken.lowercased()
    }

    var normalizedToken: String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        return "/\(trimmed)"
    }
}
