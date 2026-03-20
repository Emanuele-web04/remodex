// FILE: TurnComposerHostView.swift
// Purpose: Adapts TurnView state and callbacks into the large TurnComposerView API, including slash-command routing.
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
    let isEmptyThread: Bool
    let isWorktreeProject: Bool
    let canForkLocally: Bool
    let isInputFocused: Binding<Bool>
    let orderedModelOptions: [CodexModelOption]
    let selectedModelTitle: String
    let reasoningDisplayOptions: [TurnComposerReasoningDisplayOption]
    let showsGitControls: Bool
    let isGitBranchSelectorEnabled: Bool
    let onSelectGitBranch: (String) -> Void
    let onCreateGitBranch: (String) -> Void
    let onRefreshGitBranches: () -> Void
    let onStartCodeReviewThread: (TurnComposerReviewTarget) -> Void
    let onStartForkThreadLocally: () -> Void
    let onOpenForkWorktree: () -> Void
    let onOpenWorktreeHandoff: () -> Void
    let onShowStatus: () -> Void
    let onSend: () -> Void

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        let availableForkDestinations = TurnComposerForkDestination.availableDestinations(
            canForkLocally: canForkLocally,
            canCreateWorktree: showsGitControls && !isWorktreeProject && isGitBranchSelectorEnabled
        )
        let autocompleteState = TurnComposerAutocompleteState(
            availableSlashCommands: TurnComposerSlashCommand.availableCommands(
                supportsThreadFork: codex.supportsThreadFork,
                allowsForkCommand: TurnComposerCommandLogic.canOfferForkSlashCommand(
                    in: viewModel.input,
                    mentionedFileCount: viewModel.composerMentionedFiles.count,
                    mentionedSkillCount: viewModel.composerMentionedSkills.count,
                    attachmentCount: viewModel.composerAttachments.count,
                    hasReviewSelection: viewModel.composerReviewSelection != nil,
                    hasSubagentsSelection: viewModel.isSubagentsSelectionArmed,
                    isPlanModeArmed: viewModel.isPlanModeArmed
                )
                    && !availableForkDestinations.isEmpty
            ),
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
            isThreadRunning: isThreadRunning,
            showsGitBranchSelector: showsGitControls,
            isLoadingGitBranchTargets: viewModel.isLoadingGitBranchTargets,
            selectedGitBaseBranch: viewModel.selectedGitBaseBranch,
            gitDefaultBranch: viewModel.gitDefaultBranch
        )
        let accessoryState = TurnComposerAccessoryState(
            queuedDrafts: viewModel.queuedDraftsList(codex: codex, threadID: thread.id),
            canSteerQueuedDrafts: isThreadRunning,
            canRestoreQueuedDrafts: viewModel.canRestoreQueuedDrafts,
            steeringDraftID: viewModel.steeringDraftID,
            composerAttachments: viewModel.composerAttachments,
            composerMentionedFiles: viewModel.composerMentionedFiles,
            composerMentionedSkills: viewModel.composerMentionedSkills,
            composerReviewSelection: viewModel.composerReviewSelection,
            isSubagentsSelectionArmed: viewModel.isSubagentsSelectionArmed
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
            isEmptyThread: isEmptyThread,
            isWorktreeProject: isWorktreeProject,
            orderedModelOptions: orderedModelOptions,
            selectedModelID: codex.selectedModelOption()?.id,
            selectedModelTitle: selectedModelTitle,
            isLoadingModels: codex.isLoadingModels,
            runtimeState: runtimeState,
            runtimeActions: runtimeActions,
            selectedAccessMode: codex.selectedAccessMode,
            contextWindowUsage: codex.contextWindowUsageByThread[thread.id],
            rateLimitBuckets: codex.rateLimitBuckets,
            isLoadingRateLimits: codex.isLoadingRateLimits,
            rateLimitsErrorMessage: codex.rateLimitsErrorMessage,
            shouldAutoRefreshUsageStatus: codex.shouldAutoRefreshUsageStatus(threadId: thread.id),
            showsGitBranchSelector: showsGitControls,
            isGitBranchSelectorEnabled: isGitBranchSelectorEnabled,
            availableGitBranchTargets: viewModel.availableGitBranchTargets,
            gitBranchesCheckedOutElsewhere: viewModel.gitBranchesCheckedOutElsewhere,
            gitWorktreePathsByBranch: viewModel.gitWorktreePathsByBranch,
            selectedGitBaseBranch: viewModel.selectedGitBaseBranch,
            currentGitBranch: viewModel.currentGitBranch,
            gitDefaultBranch: viewModel.gitDefaultBranch,
            isLoadingGitBranchTargets: viewModel.isLoadingGitBranchTargets,
            isSwitchingGitBranch: viewModel.isSwitchingGitBranch,
            isCreatingGitWorktree: viewModel.isCreatingGitWorktree,
            onSelectGitBranch: onSelectGitBranch,
            onCreateGitBranch: onCreateGitBranch,
            onSelectGitBaseBranch: { branch in
                viewModel.selectGitBaseBranch(branch)
            },
            onRefreshGitBranches: onRefreshGitBranches,
            onRefreshUsageStatus: {
                await codex.refreshUsageStatus(threadId: thread.id)
            },
            onSelectAccessMode: codex.setSelectedAccessMode,
            canHandOffToWorktree: isGitBranchSelectorEnabled
                && !isWorktreeProject
                && !viewModel.isCreatingGitWorktree,
            onTapAddImage: { viewModel.openPhotoLibraryPicker(codex: codex) },
            onTapTakePhoto: { viewModel.openCamera(codex: codex) },
            onTapCreateWorktree: onOpenWorktreeHandoff,
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
                case .fork:
                    viewModel.onSelectSlashCommand(
                        command,
                        availableForkDestinations: availableForkDestinations
                    )
                case .status:
                    viewModel.onSelectSlashCommand(command)
                    onShowStatus()
                case .subagents:
                    viewModel.onSelectSlashCommand(command)
                }
            },
            onSelectCodeReviewTarget: { target in
                viewModel.prepareForThreadRerouteFromSlashCommand()
                onStartCodeReviewThread(target)
            },
            onSelectForkDestination: { destination in
                viewModel.onSelectForkDestination(destination)
                switch destination {
                case .local:
                    onStartForkThreadLocally()
                case .newWorktree:
                    onOpenForkWorktree()
                }
            },
            onCloseSlashCommandPanel: viewModel.closeSlashCommandPanel,
            onRemoveMentionedFile: viewModel.removeMentionedFile,
            onRemoveMentionedSkill: viewModel.removeMentionedSkill,
            onRemoveComposerReviewSelection: viewModel.clearComposerReviewSelection,
            onRemoveComposerSubagentsSelection: viewModel.clearSubagentsSelection,
            onPasteImageData: { imageDataItems in
                viewModel.enqueuePastedImageData(imageDataItems, codex: codex)
            },
            onResumeQueue: {
                viewModel.resumeQueueAndFlushIfPossible(codex: codex, threadID: thread.id)
            },
            onRestoreQueuedDraft: { draftID in
                viewModel.restoreQueuedDraftToComposer(id: draftID, codex: codex, threadID: thread.id)
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
