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
    var activeFileChangeStatus: FileChangeStatusSnapshot? = nil
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
    var showsComposerDesktopHandoff: Bool = false
    var isDesktopHandoffLoading: Bool = false
    var onContinueOnDesktop: (() -> Void)?

    @State private var isShowingAllBridgeSlashCommands = false
    @State private var isShowingAllSkills = false
    @State private var isShowingAllModels = false

    private var slashHostContext: TurnSlashHostContext {
        TurnSlashHostContext(
            codex: codex,
            thread: thread,
            availableForkDestinations: TurnComposerForkDestination.availableDestinations(
                canForkLocally: canForkLocally,
                canCreateWorktree: showsGitControls && !isWorktreeProject && isGitBranchSelectorEnabled
            ),
            onShowStatus: onShowStatus,
            onOpenFeedbackMail: onOpenFeedbackMail
        )
    }

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        let runtimeState = TurnComposerRuntimeState.resolve(
            codex: codex,
            threadId: thread.id,
            reasoningDisplayOptions: reasoningDisplayOptions
        )
        let availableForkDestinations = TurnComposerForkDestination.availableDestinations(
            canForkLocally: canForkLocally,
            canCreateWorktree: showsGitControls && !isWorktreeProject && isGitBranchSelectorEnabled
        )
        let allowsForkCommand = TurnComposerCommandLogic.canOfferForkSlashCommand(
            in: viewModel.input,
            mentionedFileCount: viewModel.composerMentionedFiles.count,
            mentionedSkillCount: viewModel.composerMentionedSkills.count,
            attachmentCount: viewModel.composerAttachments.count,
            hasReviewSelection: viewModel.composerReviewSelection != nil,
            hasSubagentsSelection: viewModel.isSubagentsSelectionArmed,
            isPlanModeArmed: viewModel.isPlanModeArmed
        ) && !availableForkDestinations.isEmpty
        let modelProvider = codex.runtimeModelProviderForTurn(threadId: thread.id)
        let slashSource = TurnComposerSlashCommandRouting.source(
            supportsSlashCommands: runtimeState.capabilities.supportsSlashCommands,
            modelProvider: modelProvider
        )
        let slashQuery: String = {
            if case .commands(let query) = viewModel.slashCommandPanelState {
                return query
            }
            return ""
        }()
        let groupedBridgeSlashSections: [(section: SlashCommandSection, commands: [BridgeSlashCommand])] = {
            guard slashSource == .bridgeCommands else { return [] }
            return viewModel.groupedBridgeSlashCommandSections(
                matching: slashQuery,
                allowsForkCommand: allowsForkCommand,
                modelProvider: modelProvider,
                thread: thread
            )
        }()
        let autocompleteState = TurnComposerAutocompleteState(
            availableSlashCommands: viewModel.availableSlashCommandItems(
                allowsForkCommand: allowsForkCommand,
                slashSource: slashSource
            ),
            groupedBridgeSlashSections: groupedBridgeSlashSections,
            supportsSlashCommands: runtimeState.capabilities.supportsSlashCommands,
            supportsSlashCommandExecute: runtimeState.capabilities.supportsSlashCommandExecute,
            usesBridgeSlashCommands: slashSource == .bridgeCommands,
            isLoadingBridgeSlashCommands: viewModel.isLoadingBridgeSlashCommands,
            showsBridgeSlashCommandsEmptyHint: viewModel.showsBridgeSlashCommandsEmptyHint,
            bridgeSlashCommandsLoadError: viewModel.bridgeSlashCommandsLoadError,
            supportsThreadFork: runtimeState.capabilities.supportsFork,
            supportsSkillAutocomplete: runtimeState.capabilities.supportsSkillAutocomplete,
            fileAutocompleteItems: viewModel.fileAutocompleteItems,
            isFileAutocompleteVisible: viewModel.isFileAutocompleteVisible,
            isFileAutocompleteLoading: viewModel.isFileAutocompleteLoading,
            fileAutocompleteQuery: viewModel.fileAutocompleteQuery,
            skillAutocompleteItems: viewModel.skillAutocompleteItems,
            skillFullListItems: viewModel.skillFullListItems,
            skillTotalCount: viewModel.skillTotalCount,
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
        let steerEligible = isThreadRunning && activeTurnID != nil
        let accessoryState = TurnComposerAccessoryState(
            queuedDrafts: viewModel.queuedDraftsList(codex: codex, threadID: thread.id),
            canSteerQueuedDrafts: steerEligible && runtimeState.capabilities.supportsSteer,
            showsSteerQueuedDraftControl: steerEligible,
            steerUnavailableReason: runtimeState.capabilities.supportsSteer
                ? nil
                : ComposerCapabilityCopy.capabilityReason(for: .steer),
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
        let runtimeActions = TurnComposerRuntimeActions.resolve(
            codex: codex,
            threadId: thread.id,
            onBrowseAllModels: { isShowingAllModels = true }
        )
        let selectedModelID = codex.visibleSelectedModelIDForComposer(threadId: thread.id)
        let isRuntimeSelectionLoading = codex.isRuntimeSelectionLoadingForComposer(threadId: thread.id)
        let isRuntimeCapabilitiesLoading = codex.isRuntimeCapabilitiesLoadingForComposer(threadId: thread.id)
        let hasComposerWorkingDirectory = thread.gitWorkingDirectory != nil
            && !SidebarThreadGrouping.isRootlessChatThread(thread)

        // When the runtime provider is explicitly disabled, replace the entire composer
        // with an unavailable notice so users see why the controls are missing.
        if !runtimeState.isRuntimeEnabled {
            let unavailable = ComposerCapabilityCopy.runtimeUnavailableMessage(runtimeState.runtimeUnavailableReason, reasonCode: runtimeState.runtimeUnavailableReasonCode)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(unavailable.title)
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(.primary)
                        if let hint = unavailable.hint {
                            Text(hint)
                                .font(AppFont.caption())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 26))
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
        } else {
        TurnComposerView(
            input: $viewModel.input,
            isInputFocused: isInputFocused,
            accessoryState: accessoryState,
            autocompleteState: autocompleteState,
            remainingAttachmentSlots: viewModel.remainingAttachmentSlots,
            isComposerInteractionLocked: viewModel.isComposerInteractionLocked(activeTurnID: activeTurnID),
            isSendDisabled: isVoiceInputActive
                || viewModel.isSendDisabled(
                    isConnected: codex.isConnected,
                    activeTurnID: activeTurnID,
                    isRuntimeCapabilitiesLoading: isRuntimeCapabilitiesLoading
                ),
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
            orderedModelOptions: orderedModelOptions,
            selectedModelID: selectedModelID,
            selectedModelTitle: selectedModelTitle,
            isLoadingModels: codex.isLoadingModels,
            isLoadingOpenCodeProvider: codex.isLoadingOpenCodeProvider,
            isRuntimeSelectionLoading: isRuntimeSelectionLoading,
            modelsErrorMessage: codex.modelsErrorMessage(forThreadId: thread.id),
            openCodeProviderDiscoveryReasonCode: codex.openCodeProviderDiscoveryReasonCode,
            threadId: thread.id,
            runtimeState: runtimeState,
            runtimeActions: runtimeActions,
            voiceButtonPresentation: voiceButtonPresentation,
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
            onTapAddImage: { viewModel.openPhotoLibraryPicker(codex: codex, threadID: thread.id) },
            onTapTakePhoto: { viewModel.openCamera(codex: codex, threadID: thread.id) },
            onTapVoice: onTapVoice,
            onCancelVoiceRecording: onCancelVoiceRecording,
            onTapCreateWorktree: onOpenWorktreeHandoff,
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
                        codex: codex,
                        thread: thread,
                        supportsSlashCommands: runtimeState.capabilities.supportsSlashCommands,
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
            onSelectSlashCommand: { item in
                viewModel.onSelectSlashCommandItem(item, hostContext: slashHostContext)
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
            onRetryBridgeSlashCommands: {
                viewModel.retryBridgeSlashCommandsLoad(codex: codex, thread: thread)
            },
            onSeeAllBridgeSlashCommands: {
                guard slashSource == .bridgeCommands else { return }
                isShowingAllBridgeSlashCommands = true
            },
            onSeeAllSkills: {
                isShowingAllSkills = true
            },
            onRemoveMentionedFile: { mentionID in
                viewModel.removeMentionedFile(id: mentionID)
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            },
            onRemoveMentionedSkill: { mentionID in
                viewModel.removeMentionedSkill(id: mentionID)
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
            showsComposerDesktopHandoff: showsComposerDesktopHandoff,
            isDesktopHandoffLoading: isDesktopHandoffLoading,
            onContinueOnDesktop: onContinueOnDesktop
        )
        .sheet(isPresented: $isShowingAllModels) {
            OpenCodeAllModelsSheet(
                threadId: thread.id,
                onSelect: { model in
                    isShowingAllModels = false
                    runtimeActions.selectModel(model.selectionKey)
                }
            )
        }
        .sheet(isPresented: $isShowingAllSkills) {
            BridgeSkillsFullListSheet(
                items: viewModel.skillFullListItems,
                onSelect: { skill in
                    isShowingAllSkills = false
                    viewModel.onSelectSkillAutocomplete(skill)
                    viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
                },
                onDismiss: {
                    isShowingAllSkills = false
                }
            )
        }
        .sheet(isPresented: $isShowingAllBridgeSlashCommands) {
            if slashSource == .bridgeCommands {
                BridgeSlashCommandsFullListSheet(
                    sections: viewModel.groupedBridgeSlashCommandSections(
                        matching: "",
                        allowsForkCommand: allowsForkCommand,
                        modelProvider: modelProvider,
                        thread: thread
                    ),
                    supportsSlashCommands: runtimeState.capabilities.supportsSlashCommands,
                    supportsSlashCommandExecute: runtimeState.capabilities.supportsSlashCommandExecute,
                    onSelect: { command in
                        isShowingAllBridgeSlashCommands = false
                        viewModel.onSelectSlashCommandItem(
                            .bridge(command),
                            hostContext: slashHostContext
                        )
                        viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
                    },
                    onDismiss: {
                        isShowingAllBridgeSlashCommands = false
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingSlashCommandArgumentsSheet) {
            if let command = viewModel.pendingSlashCommandArguments {
                SlashCommandArgumentsSheet(
                    command: command,
                    supportsExecute: codex.runtimeCapabilitiesForTurn(threadId: thread.id)
                        .supportsSlashCommandExecute,
                    onSubmit: { fields in
                        viewModel.submitSlashCommandArguments(
                            command: command,
                            argumentFields: fields,
                            hostContext: slashHostContext
                        )
                    },
                    onDismiss: {
                        viewModel.dismissSlashCommandArgumentsSheet()
                    }
                )
            }
        }
        }
    }
}

private struct BridgeSlashCommandsFullListSheet: View {
    let sections: [(section: SlashCommandSection, commands: [BridgeSlashCommand])]
    let supportsSlashCommands: Bool
    let supportsSlashCommandExecute: Bool
    let onSelect: (BridgeSlashCommand) -> Void
    let onDismiss: () -> Void

    private var commandCount: Int {
        sections.reduce(0) { $0 + $1.commands.count }
    }

    var body: some View {
        NavigationStack {
            Group {
                if commandCount == 0 {
                    ContentUnavailableView(
                        "No commands",
                        systemImage: "slash.circle",
                        description: Text("No slash commands are available for this project.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections, id: \.section) { group in
                                Text(group.section.displayTitle)
                                    .font(AppFont.caption(weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)

                                ForEach(group.commands) { command in
                                    Button {
                                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                                        onSelect(command)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 8) {
                                                RuntimeProviderLogoView(
                                                    provider: command.resolvedProviderID(for: group.section),
                                                    size: 14
                                                )
                                                Text(command.token)
                                                    .font(AppFont.subheadline(weight: .semibold))
                                                    .foregroundStyle(Color.indigo)
                                                Spacer(minLength: 8)
                                                Text(command.title)
                                                    .font(AppFont.footnote())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            if let description = SlashCommandAutocompletePanel.descriptionLabel(from: command.description) {
                                                Text(description)
                                                    .font(AppFont.caption2())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .capabilityGreyOut(
                                        isEnabled: bridgeSlashRowIsEnabled(command: command),
                                        reason: bridgeSlashRowDisabledReason(command: command)
                                    )
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func bridgeSlashRowIsEnabled(command: BridgeSlashCommand) -> Bool {
        guard supportsSlashCommands else { return false }
        if command.requiresArguments {
            return true
        }
        return supportsSlashCommandExecute
    }

    private func bridgeSlashRowDisabledReason(command: BridgeSlashCommand) -> String? {
        if !supportsSlashCommands {
            return ComposerCapabilityCopy.capabilityReason(for: .slashCommands)
        }
        if !command.requiresArguments, !supportsSlashCommandExecute {
            return ComposerCapabilityCopy.capabilityReason(for: .slashCommandExecute)
        }
        return nil
    }
}
