// FILE: TurnComposerMetaMapper.swift
// Purpose: Centralizes model/reasoning label mapping and ordering for TurnView composer menus.
// Layer: View Helper
// Exports: TurnComposerMetaMapper, TurnComposerReasoningDisplayOption,
//          TurnComposerRuntimeLabelParts
// Depends on: CodexModelOption, TurnComposerRuntimeState

import Foundation

// Keeps TurnView lightweight by isolating menu formatting/sorting rules.
enum TurnComposerMetaMapper {
    // ─── Model Mapping ────────────────────────────────────────────────

    // Returns models sorted using the explicit product order expected by the UI.
    static func orderedModels(from models: [CodexModelOption]) -> [CodexModelOption] {
        let preferredOrder: [String] = [
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.3-codex",
            "gpt-5.2-codex",
            "gpt-5.1-codex-max",
            "gpt-5.2",
            "gpt-5.1-codex-mini",
        ]
        let rankByModel = Dictionary(uniqueKeysWithValues: preferredOrder.enumerated().map { index, value in
            (value, index)
        })

        return models.sorted { lhs, rhs in
            let lhsRank = rankByModel[lhs.model.lowercased()] ?? Int.max
            let rhsRank = rankByModel[rhs.model.lowercased()] ?? Int.max
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

    // ─── Runtime pill label ──────────────────────────────────────────

    // Resolves the "Model Effort" label pair shown on the composer runtime
    // pill and echoed by the slider overlay, so both surfaces render the
    // exact same strings from one rule set.
    static func runtimeLabelParts(
        selectedModelID: String?,
        selectedModelTitle: String,
        isRuntimeSelectionLoading: Bool,
        runtimeState: TurnComposerRuntimeState
    ) -> TurnComposerRuntimeLabelParts {
        guard selectedModelID != nil else {
            return TurnComposerRuntimeLabelParts(
                modelPart: isRuntimeSelectionLoading ? "Loading…" : "Select model",
                effortPart: nil
            )
        }

        let effort = runtimeState.selectedReasoningTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return TurnComposerRuntimeLabelParts(
            modelPart: compactModelTitle(from: selectedModelTitle),
            effortPart: (effort.isEmpty || effort == "Select reasoning") ? nil : effort
        )
    }

    // Strips family prefixes ("GPT", "Codex") so the pill shows the short
    // product name, e.g. "GPT-5.5" -> "5.5".
    static func compactModelTitle(from title: String) -> String {
        let words = title
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(String.init)
            .filter { word in
                let lowercased = word.lowercased()
                return lowercased != "gpt" && lowercased != "codex"
            }
        return words.isEmpty ? title : words.joined(separator: " ")
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

// The two-tone label shown on the runtime pill: model name in primary,
// effort (when known) in a dimmer style alongside it.
struct TurnComposerRuntimeLabelParts: Equatable {
    let modelPart: String
    let effortPart: String?
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
