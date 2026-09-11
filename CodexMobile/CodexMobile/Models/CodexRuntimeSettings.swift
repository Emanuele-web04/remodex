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
}
