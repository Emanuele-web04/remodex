// FILE: TurnComposerRuntimeActions.swift
// Purpose: Centralizes the composer runtime selection callbacks shared across nested views.
// Layer: View Helper
// Exports: TurnComposerRuntimeActions
// Depends on: CodexService, CodexServiceTier

import Foundation

struct TurnComposerRuntimeActions {
    let selectModel: (String) -> Void
    let selectAutomaticReasoning: () -> Void
    let selectReasoning: (String) -> Void
    let selectServiceTier: (CodexServiceTier?) -> Void

    static func resolve(codex: CodexService, threadId: String?) -> TurnComposerRuntimeActions {
        guard let threadId else {
            return TurnComposerRuntimeActions(
                selectModel: codex.setSelectedModelId,
                selectAutomaticReasoning: { codex.setSelectedReasoningEffort(nil) },
                selectReasoning: { effort in codex.setSelectedReasoningEffort(effort) },
                selectServiceTier: codex.setSelectedServiceTier
            )
        }
        return TurnComposerRuntimeActions(
            selectModel: { codex.setThreadModelOverride($0, for: threadId) },
            selectAutomaticReasoning: { codex.clearThreadReasoningEffortOverride(for: threadId) },
            selectReasoning: { effort in codex.setThreadReasoningEffortOverride(effort, for: threadId) },
            selectServiceTier: { codex.setThreadServiceTierOverride($0, for: threadId) }
        )
    }
}
