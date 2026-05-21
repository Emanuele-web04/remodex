// FILE: TurnComposerMetaMapper.swift
// Purpose: Centralizes model/reasoning label mapping and ordering for TurnView composer menus.
// Layer: View Helper
// Exports: TurnComposerMetaMapper, TurnComposerReasoningDisplayOption
// Depends on: CodexModelOption

import Foundation

// Keeps TurnView lightweight by isolating menu formatting/sorting rules.
enum TurnComposerMetaMapper {
    // MARK: - Provider Mapping

    static func providerTitle(for provider: String) -> String {
        switch CodexModelOption.normalizedProvider(provider) {
        case "claude":
            return "Claude"
        case "codex":
            return "Codex"
        default:
            return provider
                .split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    static func providerIconName(for provider: String) -> String {
        switch CodexModelOption.normalizedProvider(provider) {
        case "claude":
            return "textformat"
        case "codex":
            return "sparkles"
        default:
            return "cube"
        }
    }

    // ─── Model Mapping ────────────────────────────────────────────────

    // Returns models sorted using the explicit product order expected by the UI.
    static func orderedModels(from models: [CodexModelOption]) -> [CodexModelOption] {
        let preferredOrder: [String] = [
            "codex:gpt-5.5",
            "codex:gpt-5.4",
            "codex:gpt-5.4-mini",
            "codex:gpt-5.3-codex",
            "codex:gpt-5.3-codex-spark",
            "codex:gpt-5.2",
            "codex:gpt-5.2-codex",
            "claude:claude-opus-4-7",
            "claude:claude-opus-4-6",
            "claude:claude-opus-4-5-20251101",
            "claude:claude-sonnet-4-6",
            "claude:claude-haiku-4-5-20251001",
        ]
        let rankByModel = Dictionary(uniqueKeysWithValues: preferredOrder.enumerated().map { index, value in
            (value, index)
        })

        return models.sorted { lhs, rhs in
            let lhsRank = rankByModel[lhs.selectionKey.lowercased()]
                ?? rankByModel[CodexModelOption.selectionKey(provider: lhs.modelProvider, modelId: lhs.model).lowercased()]
                ?? Int.max
            let rhsRank = rankByModel[rhs.selectionKey.lowercased()]
                ?? rankByModel[CodexModelOption.selectionKey(provider: rhs.modelProvider, modelId: rhs.model).lowercased()]
                ?? Int.max
            if lhsRank == rhsRank {
                return modelTitle(for: lhs) > modelTitle(for: rhs)
            }
            return lhsRank < rhsRank
        }
    }

    // Normalizes backend ids into consistent menu labels.
    static func modelTitle(for model: CodexModelOption) -> String {
        let normalizedModel = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelTitle(forIdentifier: normalizedModel, fallback: model.displayName)
    }

    // Formats persisted model ids before the full model list has refreshed.
    static func modelTitle(forIdentifier identifier: String?, fallback: String? = nil) -> String {
        let normalizedIdentifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch normalizedIdentifier.lowercased() {
        case "gpt-5.5":
            return "GPT-5.5"
        case "gpt-5.3-codex":
            return "GPT-5.3-Codex"
        case "gpt-5.2-codex":
            return "GPT-5.2-Codex"
        case "gpt-5.1-codex-max":
            return "GPT-5.1-Codex-Max"
        case "gpt-5.4":
            return "GPT-5.4"
        case "gpt-5.4-mini":
            return "GPT-5.4-Mini"
        case "gpt-5.2":
            return "GPT-5.2"
        case "gpt-5.1-codex-mini":
            return "GPT-5.1-Codex-Mini"
        case "claude-opus-4-7":
            return "Claude Opus 4.7"
        case "claude-opus-4-6":
            return "Claude Opus 4.6"
        case "claude-opus-4-5-20251101", "claude-opus-4-5":
            return "Claude Opus 4.5"
        case "claude-sonnet-4-6":
            return "Claude Sonnet 4.6"
        case "claude-haiku-4-5-20251001", "claude-haiku-4-5":
            return "Claude Haiku 4.5"
        default:
            let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !fallback.isEmpty {
                return fallback
            }
            if normalizedIdentifier.lowercased().hasPrefix("gpt-") {
                return "GPT-" + String(normalizedIdentifier.dropFirst("gpt-".count))
            }
            return normalizedIdentifier.isEmpty ? "GPT-5.5" : normalizedIdentifier
        }
    }

    // ─── Reasoning Mapping ───────────────────────────────────────────

    // Converts server effort values to user-facing labels and sorts them by level.
    static func reasoningDisplayOptions(from efforts: [String]) -> [TurnComposerReasoningDisplayOption] {
        efforts
            .map { effort in
                TurnComposerReasoningDisplayOption(
                    effort: effort,
                    title: reasoningTitle(for: effort)
                )
            }
            .sorted { lhs, rhs in
                if lhs.rank == rhs.rank {
                    return lhs.title > rhs.title
                }
                return lhs.rank > rhs.rank
            }
    }

    // Maps raw effort values to user-facing labels.
    static func reasoningTitle(for effort: String) -> String {
        let normalized = effort
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "minimal", "low":
            return "Low"
        case "medium":
            return "Medium"
        case "high":
            return "High"
        case "xhigh", "extra_high", "extra-high", "very_high", "very-high":
            return "Extra High"
        default:
            return normalized.split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }
}

struct TurnComposerReasoningDisplayOption: Identifiable, Equatable {
    let effort: String
    let title: String

    var id: String { effort }

    // Provides deterministic ordering for reasoning rows.
    var rank: Int {
        switch title {
        case "Low":
            return 0
        case "Medium":
            return 1
        case "High":
            return 2
        case "Exceptional":
            return 3
        default:
            return 4
        }
    }
}
