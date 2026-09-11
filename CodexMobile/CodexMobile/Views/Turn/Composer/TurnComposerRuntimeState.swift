// FILE: TurnComposerRuntimeState.swift
// Purpose: Bundles the composer runtime selection state shared by the bottom bar and input context menu.
// Layer: View Helper
// Exports: TurnComposerRuntimeState
// Depends on: CodexService, TurnComposerMetaMapper, CodexServiceTier

import Foundation

struct TurnComposerRuntimeState: Equatable {
    let reasoningDisplayOptions: [TurnComposerReasoningDisplayOption]
    let effectiveReasoningEffort: String?
    let selectedReasoningEffort: String?
    let reasoningMenuDisabled: Bool
    let selectedServiceTier: CodexServiceTier?
    let supportsFastMode: Bool
    var serviceTiers: [CodexServiceTier] = []
    var settingsStatus: String? = nil

    var selectedReasoningTitle: String {
        effectiveReasoningEffort.map(TurnComposerMetaMapper.reasoningTitle(for:)) ?? "Select reasoning"
    }

    var showsFastModeBadgeOnPill: Bool {
        supportsFastMode && selectedServiceTier == .fast
    }

    func isSelectedReasoning(_ effort: String) -> Bool {
        (selectedReasoningEffort ?? effectiveReasoningEffort) == effort
    }

    func isSelectedServiceTier(_ serviceTier: CodexServiceTier?) -> Bool {
        selectedServiceTier == serviceTier
    }

    static func resolve(
        codex: CodexService,
        threadId: String?,
        reasoningDisplayOptions: [TurnComposerReasoningDisplayOption]
    ) -> TurnComposerRuntimeState {
        return TurnComposerRuntimeState(
            reasoningDisplayOptions: reasoningDisplayOptions,
            effectiveReasoningEffort: codex.selectedReasoningEffortForSelectedModel(threadId: threadId),
            selectedReasoningEffort: codex.threadRuntimeOverride(for: threadId)?.overridesReasoning == true
                ? codex.threadRuntimeOverride(for: threadId)?.reasoningEffort
                : codex.selectedReasoningEffort,
            reasoningMenuDisabled: reasoningDisplayOptions.isEmpty
                || codex.selectedModelOption(threadId: threadId) == nil,
            selectedServiceTier: codex.effectiveServiceTier(for: threadId),
            supportsFastMode: codex.selectedModelSupportsServiceTier(.fast, threadId: threadId),
            serviceTiers: codex.selectedModelOption(threadId: threadId)?.serviceTiers ?? [],
            settingsStatus: threadId.flatMap { id in
                if codex.threadRuntimeOverride(for: id)?.pendingRuntimeSettings.isEmpty == false {
                    if !codex.isConnected { return "Settings saved locally" }
                    if !codex.supportsRuntimeSettingsSync { return "Applies when you send" }
                    if codex.runtimeSettingsUpdateErrors[id] != nil { return "Settings not applied" }
                    return "Updating settings…"
                }
                return codex.runningThreadIDs.contains(id) ? "Applies to the next turn" : nil
            }
        )
    }
}
