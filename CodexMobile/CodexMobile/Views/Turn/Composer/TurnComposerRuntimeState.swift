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
    let selectedAgentRuntimeID: String
    let agentRuntimeOptions: [AgentRuntimeDescriptor]
    let agentRuntimeCapabilities: AgentRuntimeCapabilities
    let isAgentRuntimeLocked: Bool
    let openCodeAgentOptions: [OpenCodeAgentOption]
    let selectedOpenCodeBuildAgentID: String
    let selectedOpenCodePlanAgentID: String
    let selectedCursorModeID: String

    var selectedReasoningTitle: String {
        effectiveReasoningEffort.map(TurnComposerMetaMapper.reasoningTitle(for:)) ?? "Select reasoning"
    }

    var selectedAgentRuntimeTitle: String {
        agentRuntimeOptions.first(where: { $0.id == selectedAgentRuntimeID })?.displayName ?? "Codex"
    }

    var selectedOpenCodeBuildAgentTitle: String {
        openCodeAgentOptions.first(where: { $0.id == selectedOpenCodeBuildAgentID })?.displayName
            ?? selectedOpenCodeBuildAgentID.capitalized
    }

    var selectedOpenCodePlanAgentTitle: String {
        selectedOpenCodePlanAgentID.capitalized
    }

    var selectedCursorModeTitle: String {
        CursorComposerModeOption.all.first(where: { $0.id == selectedCursorModeID })?.displayName ?? "None"
    }

    var selectedAgentRuntimeStatusMessage: String? {
        agentRuntimeOptions.first(where: { $0.id == selectedAgentRuntimeID })?.statusMessage
    }

    var showsSpeedBadgeInModelMenu: Bool {
        supportsFastMode && selectedServiceTier != nil
    }

    func isSelectedReasoning(_ effort: String) -> Bool {
        (selectedReasoningEffort ?? effectiveReasoningEffort) == effort
    }

    func isSelectedServiceTier(_ serviceTier: CodexServiceTier?) -> Bool {
        selectedServiceTier == serviceTier
    }

    static func resolve(
        codex: CodexService,
        reasoningDisplayOptions: [TurnComposerReasoningDisplayOption],
        thread: CodexThread?,
        isAgentRuntimeLocked: Bool
    ) -> TurnComposerRuntimeState {
        let lockedThread = isAgentRuntimeLocked ? thread : nil
        let runtimeID = codex.effectiveAgentRuntimeID(for: lockedThread)
        let selectedModel = codex.selectedModelOption(for: lockedThread)
        return TurnComposerRuntimeState(
            reasoningDisplayOptions: reasoningDisplayOptions,
            effectiveReasoningEffort: runtimeID == "codex" ? codex.selectedReasoningEffortForSelectedModel() : nil,
            selectedReasoningEffort: codex.selectedReasoningEffort,
            reasoningMenuDisabled: runtimeID != "codex" || reasoningDisplayOptions.isEmpty || selectedModel == nil,
            selectedServiceTier: runtimeID == "codex" ? codex.effectiveServiceTier() : nil,
            supportsFastMode: runtimeID == "codex" && codex.selectedModelSupportsServiceTier(.fast),
            selectedAgentRuntimeID: runtimeID,
            agentRuntimeOptions: codex.agentRuntimeOptionsForComposer(),
            agentRuntimeCapabilities: codex.effectiveAgentRuntimeCapabilities(for: lockedThread),
            isAgentRuntimeLocked: isAgentRuntimeLocked,
            openCodeAgentOptions: codex.openCodeAgentOptions(for: lockedThread),
            selectedOpenCodeBuildAgentID: codex.effectiveOpenCodeBuildAgentName(for: lockedThread),
            selectedOpenCodePlanAgentID: codex.effectiveOpenCodePlanAgentName(for: lockedThread),
            selectedCursorModeID: codex.effectiveCursorMode(for: lockedThread)
        )
    }
}
