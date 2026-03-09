// FILE: TurnComposerHostView.swift
// Purpose: Adapts TurnView state and callbacks into the large TurnComposerView API, including queued-draft actions.
// Layer: View Component
// Exports: TurnComposerHostView
// Depends on: SwiftUI, TurnComposerView, TurnViewModel, CodexService

import SwiftUI

struct TurnComposerHostView: View {
    @Bindable var viewModel: TurnViewModel

    let codex: CodexService
    let thread: CodexThread
    let activeTurnID: String?
    let isThreadRunning: Bool
    let isInputFocused: Binding<Bool>
    let orderedModelOptions: [CodexModelOption]
    let selectedModelTitle: String
    let reasoningDisplayOptions: [TurnComposerReasoningDisplayOption]
    let selectedReasoningTitle: String
    let showsGitControls: Bool
    let isGitBranchSelectorEnabled: Bool
    let onSelectGitBranch: (String) -> Void
    let onRefreshGitBranches: () -> Void
    let onSend: () -> Void

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        TurnComposerView(
            input: $viewModel.input,
            isInputFocused: isInputFocused,
            composerAttachments: viewModel.composerAttachments,
            remainingAttachmentSlots: viewModel.remainingAttachmentSlots,
            isComposerInteractionLocked: viewModel.isComposerInteractionLocked(activeTurnID: activeTurnID),
            isSendDisabled: viewModel.isSendDisabled(isConnected: codex.isConnected, activeTurnID: activeTurnID),
            isPlanModeArmed: viewModel.isPlanModeArmed,
            queuedDrafts: viewModel.queuedDraftsList(codex: codex, threadID: thread.id),
            queuedCount: viewModel.queuedCount(codex: codex, threadID: thread.id),
            isQueuePaused: viewModel.isQueuePaused(codex: codex, threadID: thread.id),
            canSteerQueuedDrafts: isThreadRunning,
            steeringDraftID: viewModel.steeringDraftID,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning,
            composerMentionedFiles: viewModel.composerMentionedFiles,
            composerMentionedSkills: viewModel.composerMentionedSkills,
            fileAutocompleteItems: viewModel.fileAutocompleteItems,
            isFileAutocompleteVisible: viewModel.isFileAutocompleteVisible,
            isFileAutocompleteLoading: viewModel.isFileAutocompleteLoading,
            fileAutocompleteQuery: viewModel.fileAutocompleteQuery,
            skillAutocompleteItems: viewModel.skillAutocompleteItems,
            isSkillAutocompleteVisible: viewModel.isSkillAutocompleteVisible,
            isSkillAutocompleteLoading: viewModel.isSkillAutocompleteLoading,
            skillAutocompleteQuery: viewModel.skillAutocompleteQuery,
            orderedModelOptions: orderedModelOptions,
            selectedModelID: codex.selectedModelOption()?.id,
            selectedModelTitle: selectedModelTitle,
            isLoadingModels: codex.isLoadingModels,
            reasoningDisplayOptions: reasoningDisplayOptions,
            selectedReasoningEffort: codex.selectedReasoningEffortForSelectedModel(),
            selectedReasoningTitle: selectedReasoningTitle,
            reasoningMenuDisabled: reasoningDisplayOptions.isEmpty || codex.selectedModelOption() == nil,
            selectedAccessMode: codex.selectedAccessMode,
            showsGitBranchSelector: showsGitControls,
            isGitBranchSelectorEnabled: isGitBranchSelectorEnabled,
            availableGitBranchTargets: viewModel.availableGitBranchTargets,
            selectedGitBaseBranch: viewModel.selectedGitBaseBranch,
            currentGitBranch: viewModel.currentGitBranch,
            gitDefaultBranch: viewModel.gitDefaultBranch,
            isLoadingGitBranchTargets: viewModel.isLoadingGitBranchTargets,
            isSwitchingGitBranch: viewModel.isSwitchingGitBranch,
            onSelectGitBranch: onSelectGitBranch,
            onSelectGitBaseBranch: viewModel.selectGitBaseBranch,
            onRefreshGitBranches: onRefreshGitBranches,
            onSelectModel: codex.setSelectedModelId,
            onSelectReasoning: codex.setSelectedReasoningEffort,
            onSelectAccessMode: codex.setSelectedAccessMode,
            onTapAddImage: { viewModel.openPhotoLibraryPicker(codex: codex) },
            onTapTakePhoto: { viewModel.openCamera(codex: codex) },
            onSetPlanModeArmed: viewModel.setPlanModeArmed,
            onRemoveAttachment: viewModel.removeComposerAttachment,
            onStopTurn: { turnID in
                viewModel.interruptTurn(turnID, codex: codex, threadID: thread.id)
            },
            onInputChangedForFileAutocomplete: { text in
                viewModel.onInputChangedForFileAutocomplete(
                    text,
                    codex: codex,
                    thread: thread,
                    activeTurnID: activeTurnID
                )
            },
            onInputChangedForSkillAutocomplete: { text in
                viewModel.onInputChangedForSkillAutocomplete(
                    text,
                    codex: codex,
                    thread: thread,
                    activeTurnID: activeTurnID
                )
            },
            onSelectFileAutocomplete: viewModel.onSelectFileAutocomplete,
            onSelectSkillAutocomplete: viewModel.onSelectSkillAutocomplete,
            onRemoveMentionedFile: viewModel.removeMentionedFile,
            onRemoveMentionedSkill: viewModel.removeMentionedSkill,
            onPasteImageData: { imageDataItems in
                viewModel.enqueuePastedImageData(imageDataItems, codex: codex)
            },
            onResumeQueue: {
                viewModel.resumeQueueAndFlushIfPossible(codex: codex, threadID: thread.id)
            },
            onSteerQueuedDraft: { draftID in
                viewModel.steerQueuedDraft(id: draftID, codex: codex, threadID: thread.id)
            },
            onRemoveQueuedDraft: { draftID in
                viewModel.removeQueuedDraft(id: draftID, codex: codex, threadID: thread.id)
            },
            onSend: onSend
        )
    }
}
