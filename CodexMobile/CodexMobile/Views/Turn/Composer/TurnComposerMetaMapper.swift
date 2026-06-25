// FILE: TurnComposerMetaMapper.swift
// Purpose: Centralizes model/reasoning label mapping and ordering for TurnView composer menus.
// Layer: View Helper
// Exports: TurnComposerMetaMapper, TurnComposerReasoningDisplayOption
// Depends on: CodexModelOption

import Foundation

// Keeps TurnView lightweight by isolating menu formatting/sorting rules.
enum TurnComposerMetaMapper {
    static func settingsModelLabel(for model: CodexModelOption) -> String {
        let provider = providerTitle(for: model.modelProvider)
        return "\(provider) · \(modelTitle(for: model))"
    }

    static func threadProviderAccessibilityLabel(for provider: String?) -> String {
        let normalized = CodexModelOption.normalizedProvider(provider ?? "codex")
        return "\(providerTitle(for: normalized)) thread"
    }

    // MARK: - Provider Mapping

    static func providerTitle(for provider: String) -> String {
        switch CodexModelOption.normalizedProvider(provider) {
        case "codex":
            return "Codex"
        case "opencode":
            return "OpenCode"
        case "claude":
            return "Claude"
        default:
            return provider
                .split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    static func upstreamProviderTitle(for upstreamId: String, displayName: String?) -> String {
        let trimmedDisplay = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDisplay.isEmpty {
            return trimmedDisplay
        }
        return providerTitle(for: upstreamId)
    }

    /// Groups OpenCode runtime models by upstream provider id (anthropic, openai, …).
    static func openCodeModelsGroupedByUpstream(
        _ models: [CodexModelOption]
    ) -> [(upstreamId: String, title: String, models: [CodexModelOption])] {
        let withUpstream = models.filter {
            let upstream = $0.upstreamProviderId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !upstream.isEmpty
        }
        guard !withUpstream.isEmpty else {
            return []
        }

        let grouped = Dictionary(grouping: withUpstream) { model in
            model.upstreamProviderId!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        return grouped.keys.sorted().compactMap { upstreamId in
            guard let models = grouped[upstreamId], !models.isEmpty else { return nil }
            let title = upstreamProviderTitle(
                for: upstreamId,
                displayName: models.first?.upstreamProviderDisplayName
            )
            return (upstreamId: upstreamId, title: title, models: models)
        }
    }

    static func providerIconName(for provider: String) -> String {
        switch CodexModelOption.normalizedProvider(provider) {
        case "codex":
            return "sparkles"
        case "opencode":
            return "terminal"
        case "claude":
            return "textformat"
        default:
            return "cube"
        }
    }

    // MARK: - Agent Mapping

    static func agentTitle(for agentId: String) -> String {
        switch agentId.lowercased() {
        case "build":
            return "Build"
        case "plan":
            return "Plan"
        case "general":
            return "General"
        case "explore":
            return "Explore"
        default:
            return agentId
                .split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    // MARK: - Model Mapping

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
            "opencode:opencode/gpt-5.5",
            "opencode:opencode/gpt-5.4",
            "opencode:openai/gpt-5.5",
            "opencode:openai/gpt-5.4",
            "opencode:ollama/llama3.1",
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
        let rawIdentifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let splitSelection = CodexModelOption.splitSelectionKey(rawIdentifier)
        let normalizedIdentifier = (splitSelection.modelId ?? rawIdentifier).trimmingCharacters(in: .whitespacesAndNewlines)
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
        default:
            let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !fallback.isEmpty {
                return fallback
            }
            if normalizedIdentifier.contains("/") {
                let modelName = normalizedIdentifier.components(separatedBy: "/").last ?? normalizedIdentifier
                return modelTitle(forIdentifier: modelName)
            }
            if normalizedIdentifier.lowercased().hasPrefix("gpt-") {
                return "GPT-" + String(normalizedIdentifier.dropFirst("gpt-".count))
            }
            return normalizedIdentifier.isEmpty ? "GPT-5.5" : normalizedIdentifier
        }
    }

    // MARK: - Reasoning Mapping

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
