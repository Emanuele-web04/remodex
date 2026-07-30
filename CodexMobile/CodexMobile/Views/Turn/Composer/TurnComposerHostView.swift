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
    let usesThreadRuntimeSettings: Bool
    let activeTurnID: String?
    let isThreadRunning: Bool
    let isEmptyThread: Bool
    let isWorktreeProject: Bool
    var activeFileChangeStatus: FileChangeStatusSnapshot? = nil
    var threadGoal: CodexThreadGoal? = nil
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
    let onOpenFeedbackMail: () -> Void
    let onShowStatus: () -> Void
    // Opens the thread goal sheet; receives any remaining composer draft as an objective prefill.
    var allowsGoalCommand: Bool = true
    var onShowGoal: (String?) -> Void = { _ in }
    var onRemoveGoal: () -> Void = {}
    var onResumeGoal: () -> Void = {}
    var onPauseGoal: () -> Void = {}
    let voiceButtonPresentation: TurnComposerVoiceButtonPresentation
    var isVoiceInputActive: Bool = false
    let isVoiceRecording: Bool
    let voiceAudioLevels: [CGFloat]
    let voiceRecordingDuration: TimeInterval
    let onTapVoice: () -> Void
    let onCancelVoiceRecording: () -> Void
    let onSend: () -> Void
    // Pass-through for the New Chat draft surface; defaults to true so every
    // existing call site keeps its meta bar.
    var showsSecondaryBar: Bool = true
    // Composer surfaces collapse to a capsule when the keyboard is closed;
    // call sites may opt out for constrained hosts.
    var allowsCollapsedComposer: Bool = true

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
                    && !availableForkDestinations.isEmpty,
                allowsGoalCommand: allowsGoalCommand && codex.supportsThreadGoals
            ),
            fileAutocompleteItems: viewModel.fileAutocompleteItems,
            isFileAutocompleteVisible: viewModel.isFileAutocompleteVisible,
            isFileAutocompleteLoading: viewModel.isFileAutocompleteLoading,
            fileAutocompleteQuery: viewModel.fileAutocompleteQuery,
            skillAutocompleteItems: viewModel.skillAutocompleteItems,
            isSkillAutocompleteVisible: viewModel.isSkillAutocompleteVisible,
            isSkillAutocompleteLoading: viewModel.isSkillAutocompleteLoading,
            skillAutocompleteQuery: viewModel.skillAutocompleteQuery,
            skillAutocompleteTrigger: viewModel.skillAutocompleteTrigger,
            pluginAutocompleteItems: viewModel.pluginAutocompleteItems,
            isPluginAutocompleteVisible: viewModel.isPluginAutocompleteVisible,
            isPluginAutocompleteLoading: viewModel.isPluginAutocompleteLoading,
            pluginAutocompleteQuery: viewModel.pluginAutocompleteQuery,
            slashCommandPanelState: viewModel.slashCommandPanelState,
            hasComposerContentConflictingWithReview: viewModel.hasComposerContentConflictingWithReview,
            isThreadRunning: isThreadRunning,
            showsGitBranchSelector: showsGitControls,
            isLoadingGitBranchTargets: viewModel.isLoadingGitBranchTargets,
            availableGitBranchTargets: viewModel.availableGitBranchTargets,
            selectedGitBaseBranch: viewModel.selectedGitBaseBranch,
            gitDefaultBranch: viewModel.gitDefaultBranch
        )
        let accessoryState = TurnComposerAccessoryState(
            queuedDrafts: viewModel.queuedDraftsList(codex: codex, threadID: thread.id),
            canSteerQueuedDrafts: isThreadRunning && activeTurnID != nil,
            canRestoreQueuedDrafts: viewModel.canRestoreQueuedDrafts,
            steeringDraftID: viewModel.steeringDraftID,
            composerAttachments: viewModel.composerAttachments,
            composerMentionedFiles: viewModel.composerMentionedFiles,
            composerMentionedSkills: viewModel.composerMentionedSkills,
            composerMentionedPlugins: viewModel.composerMentionedPlugins,
            composerReviewSelection: viewModel.composerReviewSelection,
            isSubagentsSelectionArmed: viewModel.isSubagentsSelectionArmed,
            isPlanModeArmed: viewModel.isPlanModeArmed,
            isVoiceRecording: isVoiceRecording,
            voiceAudioLevels: voiceAudioLevels,
            voiceRecordingDuration: voiceRecordingDuration
        )
        let runtimeThreadId = usesThreadRuntimeSettings ? thread.id : nil
        let runtimeState = TurnComposerRuntimeState.resolve(
            codex: codex,
            threadId: runtimeThreadId,
            reasoningDisplayOptions: reasoningDisplayOptions
        )
        let runtimeActions = TurnComposerRuntimeActions.resolve(codex: codex, threadId: runtimeThreadId)
        let selectedModelID = codex.visibleSelectedModelIDForComposer(threadId: runtimeThreadId)
        let isRuntimeSelectionLoading = codex.isRuntimeSelectionLoadingForComposer(threadId: runtimeThreadId)
        let hasComposerWorkingDirectory = thread.gitWorkingDirectory != nil
            && !SidebarThreadGrouping.isRootlessChatThread(thread)
        let gitState = TurnComposerGitState(
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
            canHandOffToWorktree: isGitBranchSelectorEnabled
                && !isWorktreeProject
                && !viewModel.isCreatingGitWorktree
        )
        let gitActions = TurnComposerGitActions(
            onSelectGitBranch: onSelectGitBranch,
            onCreateGitBranch: onCreateGitBranch,
            onSelectGitBaseBranch: { branch in
                viewModel.selectGitBaseBranch(branch)
            },
            onRefreshGitBranches: onRefreshGitBranches,
            onTapCreateWorktree: onOpenWorktreeHandoff
        )

        TurnComposerView(
            input: $viewModel.input,
            isInputFocused: isInputFocused,
            accessoryState: accessoryState,
            autocompleteState: autocompleteState,
            remainingAttachmentSlots: viewModel.remainingAttachmentSlots,
            isComposerInteractionLocked: viewModel.isComposerInteractionLocked(activeTurnID: activeTurnID),
            isSendDisabled: isVoiceInputActive
                || viewModel.isSendDisabled(isConnected: codex.isConnected, activeTurnID: activeTurnID),
            isSending: viewModel.isSending,
            isPlanModeArmed: viewModel.isPlanModeArmed,
            queuedCount: viewModel.queuedCount(codex: codex, threadID: thread.id),
            isQueuePaused: viewModel.isQueuePaused(codex: codex, threadID: thread.id),
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning,
            isEmptyThread: isEmptyThread,
            hasWorkingDirectory: hasComposerWorkingDirectory,
            isWorktreeProject: isWorktreeProject,
            activeFileChangeStatus: activeFileChangeStatus,
            threadGoal: threadGoal,
            onEditGoal: { onShowGoal(nil) },
            onRemoveGoal: onRemoveGoal,
            onResumeGoal: onResumeGoal,
            onPauseGoal: onPauseGoal,
            orderedModelOptions: orderedModelOptions,
            selectedModelID: selectedModelID,
            selectedModelTitle: selectedModelTitle,
            isLoadingModels: codex.isLoadingModels,
            isRuntimeSelectionLoading: isRuntimeSelectionLoading,
            runtimeState: runtimeState,
            runtimeActions: runtimeActions,
            voiceButtonPresentation: voiceButtonPresentation,
            selectedAccessMode: codex.selectedAccessMode,
            contextWindowUsage: codex.contextWindowUsageByThread[thread.id],
            rateLimitBuckets: codex.rateLimitBuckets,
            isLoadingRateLimits: codex.isLoadingRateLimits,
            rateLimitsErrorMessage: codex.rateLimitsErrorMessage,
            shouldAutoRefreshUsageStatus: codex.shouldAutoRefreshUsageStatus(threadId: thread.id),
            gitState: gitState,
            gitActions: gitActions,
            onRefreshUsageStatus: {
                await codex.refreshUsageStatus(threadId: thread.id)
            },
            onRefreshModelsIfNeeded: { codex.refreshModelsIfNeeded() },
            onSelectAccessMode: codex.setSelectedAccessMode,
            onTapAddImage: { viewModel.openPhotoLibraryPicker(codex: codex) },
            onTapTakePhoto: { viewModel.openCamera(codex: codex) },
            onTapVoice: onTapVoice,
            onCancelVoiceRecording: onCancelVoiceRecording,
            onSetPlanModeArmed: { isArmed in
                viewModel.setPlanModeArmed(isArmed)
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onRemoveAttachment: { attachmentID in
                viewModel.removeComposerAttachment(id: attachmentID)
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onStopTurn: { turnID in
                viewModel.interruptTurn(turnID, codex: codex, threadID: thread.id)
            },
            onInputChanged: TurnComposerInputChangeHandler(
                handleFileAutocomplete: { text in
                    viewModel.onInputChangedForFileAutocomplete(
                        text,
                        codex: codex,
                        thread: thread,
                        activeTurnID: activeTurnID
                    )
                },
                handleSkillAutocomplete: { text in
                    viewModel.onInputChangedForSkillAutocomplete(
                        text,
                        codex: codex,
                        thread: thread,
                        activeTurnID: activeTurnID
                    )
                },
                handlePluginAutocomplete: { text in
                    viewModel.onInputChangedForPluginAutocomplete(
                        text,
                        codex: codex,
                        thread: thread,
                        activeTurnID: activeTurnID
                    )
                },
                handleSlashCommandAutocomplete: { text in
                    viewModel.onInputChangedForSlashCommandAutocomplete(
                        text,
                        activeTurnID: activeTurnID
                    )
                    viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
                }
            ),
            onSelectFileAutocomplete: { item in
                viewModel.onSelectFileAutocomplete(item)
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onSelectSkillAutocomplete: { skill in
                viewModel.onSelectSkillAutocomplete(skill)
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onSelectPluginAutocomplete: { plugin in
                viewModel.onSelectPluginAutocomplete(plugin)
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onSelectSlashCommand: { command in
                switch command {
                case .codeReview:
                    viewModel.onSelectSlashCommand(command)
                case .compact:
                    viewModel.onSelectSlashCommand(command)
                    Task {
                        try? await codex.compactThread(thread.id)
                    }
                case .feedback:
                    viewModel.onSelectSlashCommand(command)
                    onOpenFeedbackMail()
                case .fork:
                    viewModel.onSelectSlashCommand(
                        command,
                        availableForkDestinations: availableForkDestinations
                    )
                case .goal:
                    viewModel.onSelectSlashCommand(command)
                    // No prefill from leftover draft here: unrelated text ending in `/goal`
                    // must not become an objective. Inline `/goal <text>` (send path) is
                    // the explicit way to prefill.
                    onShowGoal(nil)
                case .status:
                    viewModel.onSelectSlashCommand(command)
                    onShowStatus()
                case .subagents:
                    viewModel.onSelectSlashCommand(command)
                }
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
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
            onRemoveMentionedFile: { mentionID in
                viewModel.removeMentionedFile(id: mentionID)
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onRemoveMentionedPlugin: { mentionID in
                viewModel.removeMentionedPlugin(id: mentionID)
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onRemoveComposerReviewSelection: {
                viewModel.clearComposerReviewSelection()
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onRemoveComposerSubagentsSelection: {
                viewModel.clearSubagentsSelection()
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onPasteImageData: { imageDataItems in
                viewModel.enqueuePastedImageData(imageDataItems, codex: codex, threadID: thread.id)
            },
            onResumeQueue: {
                viewModel.resumeQueueAndFlushIfPossible(codex: codex, threadID: thread.id)
            },
            onRestoreQueuedDraft: { draftID in
                viewModel.restoreQueuedDraftToComposer(id: draftID, codex: codex, threadID: thread.id)
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onSteerQueuedDraft: { draftID in
                viewModel.steerQueuedDraft(id: draftID, codex: codex, threadID: thread.id)
            },
            onRemoveQueuedDraft: { draftID in
                viewModel.removeQueuedDraft(id: draftID, codex: codex, threadID: thread.id)
            },
            onSend: onSend,
            showsSecondaryBar: showsSecondaryBar,
            allowsCollapsedComposer: allowsCollapsedComposer
        )
    }
}
