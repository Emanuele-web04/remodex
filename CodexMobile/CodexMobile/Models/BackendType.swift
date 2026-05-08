// FILE: BackendType.swift
// Purpose: Describes which local AI backend the bridge is proxying.
// Layer: Model
// Exports: BackendType
// Depends on: Foundation

import Foundation

enum BackendType: String, Codable, Sendable {
    case codex
    case gemini
}
