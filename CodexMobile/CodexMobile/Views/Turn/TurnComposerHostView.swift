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
    let showsGitControls: Bool
    let isGitBranchSelectorEnabled: Bool
    let onSelectGitBranch: (String) -> Void
    let onRefreshGitBranches: () -> Void
    let onStartCodeReviewThread: (TurnComposerReviewTarget) -> Void
    let onShowStatus: () -> Void
    let onSend: () -> Void

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        let autocompleteState = TurnComposerAutocompleteState(
            fileAutocompleteItems: viewModel.fileAutocompleteItems,
            isFileAutocompleteVisible: viewModel.isFileAutocompleteVisible,
            isFileAutocompleteLoading: viewModel.isFileAutocompleteLoading,
            fileAutocompleteQuery: viewModel.fileAutocompleteQuery,
            skillAutocompleteItems: viewModel.skillAutocompleteItems,
            isSkillAutocompleteVisible: viewModel.isSkillAutocompleteVisible,
            isSkillAutocompleteLoading: viewModel.isSkillAutocompleteLoading,
            skillAutocompleteQuery: viewModel.skillAutocompleteQuery,
            slashCommandPanelState: viewModel.slashCommandPanelState,
            hasComposerContentConflictingWithReview: viewModel.hasComposerContentConflictingWithReview,
            showsGitBranchSelector: showsGitControls,
            isLoadingGitBranchTargets: viewModel.isLoadingGitBranchTargets,
            selectedGitBaseBranch: viewModel.selectedGitBaseBranch,
            gitDefaultBranch: viewModel.gitDefaultBranch
        )
        let accessoryState = TurnComposerAccessoryState(
            queuedDrafts: viewModel.queuedDraftsList(codex: codex, threadID: thread.id),
            canSteerQueuedDrafts: isThreadRunning,
            steeringDraftID: viewModel.steeringDraftID,
            composerAttachments: viewModel.composerAttachments,
            composerMentionedFiles: viewModel.composerMentionedFiles,
            composerMentionedSkills: viewModel.composerMentionedSkills,
            composerReviewSelection: viewModel.composerReviewSelection
        )
        let runtimeState = TurnComposerRuntimeState.resolve(
            codex: codex,
            reasoningDisplayOptions: reasoningDisplayOptions
        )
        let runtimeActions = TurnComposerRuntimeActions.resolve(codex: codex)

        TurnComposerView(
            input: $viewModel.input,
            isInputFocused: isInputFocused,
            accessoryState: accessoryState,
            autocompleteState: autocompleteState,
            remainingAttachmentSlots: viewModel.remainingAttachmentSlots,
            isComposerInteractionLocked: viewModel.isComposerInteractionLocked(activeTurnID: activeTurnID),
            isSendDisabled: viewModel.isSendDisabled(isConnected: codex.isConnected, activeTurnID: activeTurnID),
            isPlanModeArmed: viewModel.isPlanModeArmed,
            queuedCount: viewModel.queuedCount(codex: codex, threadID: thread.id),
            isQueuePaused: viewModel.isQueuePaused(codex: codex, threadID: thread.id),
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning,
            orderedModelOptions: orderedModelOptions,
            selectedModelID: codex.selectedModelOption()?.id,
            selectedModelTitle: selectedModelTitle,
            isLoadingModels: codex.isLoadingModels,
            runtimeState: runtimeState,
            runtimeActions: runtimeActions,
            selectedAccessMode: codex.selectedAccessMode,
            contextWindowUsage: codex.contextWindowUsageByThread[thread.id],
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
            onRefreshContextWindowUsage: {
                await codex.refreshContextWindowUsage(threadId: thread.id)
            },
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
            onInputChangedForSlashCommandAutocomplete: { text in
                viewModel.onInputChangedForSlashCommandAutocomplete(
                    text,
                    activeTurnID: activeTurnID
                )
            },
            onSelectFileAutocomplete: viewModel.onSelectFileAutocomplete,
            onSelectSkillAutocomplete: viewModel.onSelectSkillAutocomplete,
            onSelectSlashCommand: { command in
                switch command {
                case .codeReview:
                    viewModel.onSelectSlashCommand(command)
                case .status:
                    viewModel.onSelectSlashCommand(command)
                    onShowStatus()
                }
            },
            onSelectCodeReviewTarget: { target in
                viewModel.prepareForThreadRerouteFromSlashCommand()
                onStartCodeReviewThread(target)
            },
            onRemoveMentionedFile: viewModel.removeMentionedFile,
            onRemoveMentionedSkill: viewModel.removeMentionedSkill,
            onRemoveComposerReviewSelection: viewModel.clearComposerReviewSelection,
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
