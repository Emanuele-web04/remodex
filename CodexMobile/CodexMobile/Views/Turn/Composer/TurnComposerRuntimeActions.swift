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
    let selectAgent: (String?) -> Void
    let refreshModels: () -> Void
    let browseAllModels: () -> Void

    static func resolve(
        codex: CodexService,
        threadId: String? = nil,
        onBrowseAllModels: (() -> Void)? = nil
    ) -> TurnComposerRuntimeActions {
        TurnComposerRuntimeActions(
            selectModel: { selectionKey in
                if let threadId,
                   let model = codex.modelOption(forSelectionKey: selectionKey) {
                    codex.setThreadModelOverride(model, for: threadId)
                } else {
                    codex.setSelectedModelId(selectionKey)
                }
            },
            selectAutomaticReasoning: {
                if let threadId {
                    codex.clearThreadReasoningEffortOverride(for: threadId)
                } else {
                    codex.setSelectedReasoningEffort(nil)
                }
            },
            selectReasoning: { effort in
                if let threadId {
                    codex.setThreadReasoningEffortOverride(effort, for: threadId)
                } else {
                    codex.setSelectedReasoningEffort(effort)
                }
            },
            selectServiceTier: { tier in
                if let threadId {
                    codex.setThreadServiceTierOverride(tier, for: threadId)
                } else {
                    codex.setSelectedServiceTier(tier)
                }
            },
            selectAgent: { agent in
                codex.setSelectedAgentOverride(agent, for: threadId)
            },
            refreshModels: {
                Task { @MainActor in
                    codex.resetOpenCodeModelsRetry()
                    codex.setModelsErrorMessage(nil, forProvider: "opencode")
                    await codex.refreshRuntimeMetadataSequential()
                }
            },
            browseAllModels: onBrowseAllModels ?? {}
        )
    }
}
