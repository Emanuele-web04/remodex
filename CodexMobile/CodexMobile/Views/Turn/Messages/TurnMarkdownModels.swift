// FILE: TurnMarkdownModels.swift
// Purpose: Markdown render profile and assistant text formatting helpers.
// Layer: Model
// Exports: MarkdownRenderProfile, SkillReferenceReplacementStyle
// Depends on: Foundation

import Foundation

enum MarkdownRenderProfile {
    case assistantProse
    case userProse
    case fileChangeSystem
}

extension MarkdownRenderProfile {
    var cacheKey: String {
        switch self {
        case .assistantProse:
            return "assistantProse"
        case .userProse:
            return "userProse"
        case .fileChangeSystem:
            return "fileChangeSystem"
        }
    }
}

enum SkillReferenceReplacementStyle {
    case mentionToken
    case displayName
}
