// FILE: TurnComposerView.swift
// Purpose: Renders the turn composer input, queued-draft actions, attachments, and send/stop controls.
// Layer: View Component (orchestrator)
// Exports: TurnComposerView
// Depends on: SwiftUI, ComposerAttachmentsPreview, FileAutocompletePanel, SkillAutocompletePanel, SlashCommandAutocompletePanel, ComposerBottomBar, QueuedDraftsPanel, FileMentionChip, TurnComposerInputTextView, TurnComposerSecondaryBar

import SwiftUI

struct TurnComposerView: View {
    @Binding var input: String
    let isInputFocused: Binding<Bool>

    let accessoryState: TurnComposerAccessoryState
    let autocompleteState: TurnComposerAutocompleteState
    let remainingAttachmentSlots: Int
    let isComposerInteractionLocked: Bool
    let isSendDisabled: Bool
    let isPlanModeArmed: Bool
    let queuedCount: Int
    let isQueuePaused: Bool
    let activeTurnID: String?
    let isThreadRunning: Bool
    let isEmptyThread: Bool
    let isWorktreeProject: Bool

    let orderedModelOptions: [CodexModelOption]
    let selectedModelID: String?
    let selectedModelTitle: String
    let isLoadingModels: Bool

    let runtimeState: TurnComposerRuntimeState
    let runtimeActions: TurnComposerRuntimeActions
    let voiceButtonPresentation: TurnComposerVoiceButtonPresentation

    let selectedAccessMode: CodexAccessMode
    let contextWindowUsage: ContextWindowUsage?
    let rateLimitBuckets: [CodexRateLimitBucket]
    let isLoadingRateLimits: Bool
    let rateLimitsErrorMessage: String?
    let shouldAutoRefreshUsageStatus: Bool

    let showsGitBranchSelector: Bool
    let isGitBranchSelectorEnabled: Bool
    let availableGitBranchTargets: [String]
    let gitBranchesCheckedOutElsewhere: Set<String>
    let gitWorktreePathsByBranch: [String: String]
    let selectedGitBaseBranch: String
    let currentGitBranch: String
    let gitDefaultBranch: String
    let isLoadingGitBranchTargets: Bool
    let isSwitchingGitBranch: Bool
    let isCreatingGitWorktree: Bool
    let onSelectGitBranch: (String) -> Void
    let onCreateGitBranch: (String) -> Void
    let onSelectGitBaseBranch: (String) -> Void
    let onRefreshGitBranches: () -> Void
    let onRefreshUsageStatus: () async -> Void

    let onSelectAccessMode: (CodexAccessMode) -> Void
    let canHandOffToWorktree: Bool
    let onTapAddImage: () -> Void
    let onTapTakePhoto: () -> Void
    let onTapVoice: () -> Void
    let onTapCreateWorktree: () -> Void
    let onSetPlanModeArmed: (Bool) -> Void
    let onRemoveAttachment: (String) -> Void
    let onStopTurn: (String?) -> Void
    let onInputChangedForFileAutocomplete: (String) -> Void
    let onInputChangedForSkillAutocomplete: (String) -> Void
    let onInputChangedForSlashCommandAutocomplete: (String) -> Void
    let onSelectFileAutocomplete: (CodexFuzzyFileMatch) -> Void
    let onSelectSkillAutocomplete: (CodexSkillMetadata) -> Void
    let onSelectSlashCommand: (TurnComposerSlashCommand) -> Void
    let onSelectCodeReviewTarget: (TurnComposerReviewTarget) -> Void
    let onSelectForkDestination: (TurnComposerForkDestination) -> Void
    let onCloseSlashCommandPanel: () -> Void
    let onRemoveMentionedFile: (String) -> Void
    let onRemoveMentionedSkill: (String) -> Void
    let onRemoveComposerReviewSelection: () -> Void
    let onRemoveComposerSubagentsSelection: () -> Void
    let onPasteImageData: ([Data]) -> Void
    let onResumeQueue: () -> Void
    let onRestoreQueuedDraft: (String) -> Void
    let onSteerQueuedDraft: (String) -> Void
    let onRemoveQueuedDraft: (String) -> Void
    let onSend: () -> Void

    @State private var composerInputHeight: CGFloat = 32

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        VStack(spacing: 6) {
            TurnComposerQueuedDraftsSection(
                drafts: accessoryState.queuedDrafts,
                canSteerDrafts: accessoryState.canSteerQueuedDrafts,
                canRestoreDrafts: accessoryState.canRestoreQueuedDrafts,
                steeringDraftID: accessoryState.steeringDraftID,
                onRestoreQueuedDraft: onRestoreQueuedDraft,
                onSteerQueuedDraft: onSteerQueuedDraft,
                onRemoveQueuedDraft: onRemoveQueuedDraft
            )

            VStack(spacing: 0) {
                TurnComposerAccessorySection(
                    state: accessoryState,
                    onRemoveAttachment: onRemoveAttachment,
                    onRemoveMentionedFile: onRemoveMentionedFile,
                    onRemoveMentionedSkill: onRemoveMentionedSkill,
                    onRemoveComposerReviewSelection: onRemoveComposerReviewSelection,
                    onRemoveComposerSubagentsSelection: onRemoveComposerSubagentsSelection
                )

                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Ask anything... @files, $skills, /commands")
                            .font(AppFont.body())
                            .foregroundStyle(Color(.placeholderText))
                            .allowsHitTesting(false)
                    }

                    TurnComposerInputTextView(
                        text: $input,
                        isFocused: isInputFocused,
                        isEditable: !isComposerInteractionLocked,
                        dynamicHeight: $composerInputHeight,
                        runtimeState: runtimeState,
                        runtimeActions: runtimeActions,
                        onPasteImageData: { imageDataItems in
                            HapticFeedback.shared.triggerImpactFeedback(style: .light)
                            onPasteImageData(imageDataItems)
                        }
                    )
                    .frame(height: composerInputHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, accessoryState.topInputPadding)
                .padding(.bottom, 12)
                .onChange(of: input) { _, newValue in
                    onInputChangedForFileAutocomplete(newValue)
                    onInputChangedForSkillAutocomplete(newValue)
                    onInputChangedForSlashCommandAutocomplete(newValue)
                }

                ComposerBottomBar(
                    orderedModelOptions: orderedModelOptions,
                    selectedModelID: selectedModelID,
                    selectedModelTitle: selectedModelTitle,
                    isLoadingModels: isLoadingModels,
                    runtimeState: runtimeState,
                    runtimeActions: runtimeActions,
                    remainingAttachmentSlots: remainingAttachmentSlots,
                    isComposerInteractionLocked: isComposerInteractionLocked,
                    isSendDisabled: isSendDisabled,
                    isPlanModeArmed: isPlanModeArmed,
                    queuedCount: queuedCount,
                    isQueuePaused: isQueuePaused,
                    activeTurnID: activeTurnID,
                    isThreadRunning: isThreadRunning,
                    voiceButtonPresentation: voiceButtonPresentation,
                    onTapAddImage: onTapAddImage,
                    onTapTakePhoto: onTapTakePhoto,
                    onTapVoice: onTapVoice,
                    onSetPlanModeArmed: onSetPlanModeArmed,
                    onResumeQueue: onResumeQueue,
                    onStopTurn: onStopTurn,
                    onSend: onSend
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28))
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0, alignment: .topLeading)
                    .overlay(alignment: .bottomLeading) {
                        TurnComposerAutocompletePanels(
                            state: autocompleteState,
                            onSelectFileAutocomplete: onSelectFileAutocomplete,
                            onSelectSkillAutocomplete: onSelectSkillAutocomplete,
                            onSelectSlashCommand: onSelectSlashCommand,
                            onSelectCodeReviewTarget: onSelectCodeReviewTarget,
                            onSelectForkDestination: onSelectForkDestination,
                            onCloseSlashCommandPanel: onCloseSlashCommandPanel
                        )
                    }
                    .offset(y: -8)
            }
            .zIndex(2)

            // Kept as a separate component so the lower meta bar can evolve without reopening this file.
            TurnComposerSecondaryBar(
                isInputFocused: isInputFocused.wrappedValue,
                isEmptyThread: isEmptyThread,
                isWorktreeProject: isWorktreeProject,
                selectedAccessMode: selectedAccessMode,
                contextWindowUsage: contextWindowUsage,
                rateLimitBuckets: rateLimitBuckets,
                isLoadingRateLimits: isLoadingRateLimits,
                rateLimitsErrorMessage: rateLimitsErrorMessage,
                shouldAutoRefreshUsageStatus: shouldAutoRefreshUsageStatus,
                showsGitBranchSelector: showsGitBranchSelector,
                isGitBranchSelectorEnabled: isGitBranchSelectorEnabled,
                availableGitBranchTargets: availableGitBranchTargets,
                gitBranchesCheckedOutElsewhere: gitBranchesCheckedOutElsewhere,
                gitWorktreePathsByBranch: gitWorktreePathsByBranch,
                selectedGitBaseBranch: selectedGitBaseBranch,
                currentGitBranch: currentGitBranch,
                gitDefaultBranch: gitDefaultBranch,
                isLoadingGitBranchTargets: isLoadingGitBranchTargets,
                isSwitchingGitBranch: isSwitchingGitBranch,
                isCreatingGitWorktree: isCreatingGitWorktree,
                onSelectGitBranch: onSelectGitBranch,
                onCreateGitBranch: onCreateGitBranch,
                onSelectGitBaseBranch: onSelectGitBaseBranch,
                onRefreshGitBranches: onRefreshGitBranches,
                onRefreshUsageStatus: onRefreshUsageStatus,
                onSelectAccessMode: onSelectAccessMode,
                canHandOffToWorktree: canHandOffToWorktree,
                onTapCreateWorktree: onTapCreateWorktree
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: isInputFocused.wrappedValue)
    }

}

private struct TurnComposerAutocompletePanels: View {
    let state: TurnComposerAutocompleteState
    let onSelectFileAutocomplete: (CodexFuzzyFileMatch) -> Void
    let onSelectSkillAutocomplete: (CodexSkillMetadata) -> Void
    let onSelectSlashCommand: (TurnComposerSlashCommand) -> Void
    let onSelectCodeReviewTarget: (TurnComposerReviewTarget) -> Void
    let onSelectForkDestination: (TurnComposerForkDestination) -> Void
    let onCloseSlashCommandPanel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isFileAutocompleteVisible {
                FileAutocompletePanel(
                    items: state.fileAutocompleteItems,
                    isLoading: state.isFileAutocompleteLoading,
                    query: state.fileAutocompleteQuery,
                    onSelect: onSelectFileAutocomplete
                )
            }

            if state.isSkillAutocompleteVisible {
                SkillAutocompletePanel(
                    items: state.skillAutocompleteItems,
                    isLoading: state.isSkillAutocompleteLoading,
                    query: state.skillAutocompleteQuery,
                    onSelect: onSelectSkillAutocomplete
                )
            }

            if state.slashCommandPanelState != .hidden {
                SlashCommandAutocompletePanel(
                    state: state.slashCommandPanelState,
                    availableCommands: state.availableSlashCommands,
                    hasComposerContentConflictingWithReview: state.hasComposerContentConflictingWithReview,
                    isThreadRunning: state.isThreadRunning,
                    showsGitBranchSelector: state.showsGitBranchSelector,
                    isLoadingGitBranchTargets: state.isLoadingGitBranchTargets,
                    selectedGitBaseBranch: state.selectedGitBaseBranch,
                    gitDefaultBranch: state.gitDefaultBranch,
                    onSelectCommand: onSelectSlashCommand,
                    onSelectReviewTarget: onSelectCodeReviewTarget,
                    onSelectForkDestination: onSelectForkDestination,
                    onClose: onCloseSlashCommandPanel
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .zIndex(1)
    }
}

private struct TurnComposerQueuedDraftsSection: View {
    let drafts: [QueuedTurnDraft]
    let canSteerDrafts: Bool
    let canRestoreDrafts: Bool
    let steeringDraftID: String?
    let onRestoreQueuedDraft: (String) -> Void
    let onSteerQueuedDraft: (String) -> Void
    let onRemoveQueuedDraft: (String) -> Void

    var body: some View {
        Group {
            if !drafts.isEmpty {
                QueuedDraftsPanel(
                    drafts: drafts,
                    canSteerDrafts: canSteerDrafts,
                    canRestoreDrafts: canRestoreDrafts,
                    steeringDraftID: steeringDraftID,
                    onRestore: onRestoreQueuedDraft,
                    onSteer: onSteerQueuedDraft,
                    onRemove: onRemoveQueuedDraft
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom], 4)
                .adaptiveGlass(.regular, in: UnevenRoundedRectangle(
                    topLeadingRadius: 28,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 28,
                    style: .continuous
                ))
                .padding(.bottom, -10)
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct TurnComposerAccessorySection: View {
    let state: TurnComposerAccessoryState
    let onRemoveAttachment: (String) -> Void
    let onRemoveMentionedFile: (String) -> Void
    let onRemoveMentionedSkill: (String) -> Void
    let onRemoveComposerReviewSelection: () -> Void
    let onRemoveComposerSubagentsSelection: () -> Void

    var body: some View {
        Group {
            if state.showsComposerAttachments {
                ComposerAttachmentsPreview(
                    attachments: state.composerAttachments,
                    onRemove: onRemoveAttachment
                )
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            if state.showsMentionedFiles {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.composerMentionedFiles) { file in
                            FileMentionChip(fileName: file.fileName) {
                                onRemoveMentionedFile(file.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            if state.showsMentionedSkills {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.composerMentionedSkills) { skill in
                            SkillMentionChip(skillName: skill.name) {
                                onRemoveMentionedSkill(skill.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if state.showsSubagentsSelection {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ComposerActionChip(
                            title: "Subagents",
                            symbolName: "person.crop.circle",
                            tintColor: .teal,
                            removeAccessibilityLabel: "Remove subagents"
                        ) {
                            onRemoveComposerSubagentsSelection()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            if let reviewTarget = state.reviewTarget {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ComposerActionChip(
                            title: "Code Review: \(reviewTarget.title)",
                            symbolName: "checklist",
                            tintColor: .teal,
                            removeAccessibilityLabel: "Remove code review"
                        ) {
                            onRemoveComposerReviewSelection()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

        }
    }
}

#Preview("Queued Drafts + Composer") {
    QueuedDraftsPanelPreviewWrapper()
}

private struct QueuedDraftsPanelPreviewWrapper: View {
    @State private var input = ""
    @State private var isInputFocused = false

    private let fakeDrafts: [QueuedTurnDraft] = [
        QueuedTurnDraft(id: "1", text: "Fix the login bug on the settings page", attachments: [], skillMentions: [], collaborationMode: nil, createdAt: .now),
        QueuedTurnDraft(id: "2", text: "Add dark mode support to the onboarding flow", attachments: [], skillMentions: [], collaborationMode: nil, createdAt: .now),
        QueuedTurnDraft(id: "3", text: "Refactor the networking layer to use async/await", attachments: [], skillMentions: [], collaborationMode: nil, createdAt: .now),
    ]

    var body: some View {
        VStack {
            Spacer()

            TurnComposerView(
                input: $input,
                isInputFocused: $isInputFocused,
                accessoryState: TurnComposerAccessoryState(
                    queuedDrafts: fakeDrafts,
                    canSteerQueuedDrafts: true,
                    canRestoreQueuedDrafts: true,
                    steeringDraftID: nil,
                    composerAttachments: [],
                    composerMentionedFiles: [],
                    composerMentionedSkills: [],
                    composerReviewSelection: nil,
                    isSubagentsSelectionArmed: true
                ),
                autocompleteState: TurnComposerAutocompleteState(
                    availableSlashCommands: TurnComposerSlashCommand.allCommands,
                    fileAutocompleteItems: [],
                    isFileAutocompleteVisible: false,
                    isFileAutocompleteLoading: false,
                    fileAutocompleteQuery: "",
                    skillAutocompleteItems: [],
                    isSkillAutocompleteVisible: false,
                    isSkillAutocompleteLoading: false,
                    skillAutocompleteQuery: "",
                    slashCommandPanelState: .hidden,
                    hasComposerContentConflictingWithReview: false,
                    isThreadRunning: true,
                    showsGitBranchSelector: false,
                    isLoadingGitBranchTargets: false,
                    selectedGitBaseBranch: "",
                    gitDefaultBranch: "main"
                ),
                remainingAttachmentSlots: 4,
                isComposerInteractionLocked: false,
                isSendDisabled: false,
                isPlanModeArmed: true,
                queuedCount: 3,
                isQueuePaused: false,
                activeTurnID: nil,
                isThreadRunning: true,
                isEmptyThread: true,
                isWorktreeProject: false,
                orderedModelOptions: [],
                selectedModelID: nil,
                selectedModelTitle: "GPT-5.3-Codex",
                isLoadingModels: false,
                runtimeState: TurnComposerRuntimeState(
                    reasoningDisplayOptions: [],
                    effectiveReasoningEffort: nil,
                    selectedReasoningEffort: nil,
                    reasoningMenuDisabled: true,
                    selectedServiceTier: .fast
                ),
                runtimeActions: TurnComposerRuntimeActions(
                    selectModel: { _ in },
                    selectAutomaticReasoning: {},
                    selectReasoning: { _ in },
                    selectServiceTier: { _ in }
                ),
                voiceButtonPresentation: TurnComposerVoiceButtonPresentation(
                    systemImageName: "mic.fill",
                    foregroundColor: .white,
                    backgroundColor: .black,
                    accessibilityLabel: "Start voice transcription",
                    isDisabled: false,
                    showsProgress: false
                ),
                selectedAccessMode: .onRequest,
                contextWindowUsage: nil,
                rateLimitBuckets: [],
                isLoadingRateLimits: false,
                rateLimitsErrorMessage: nil,
                shouldAutoRefreshUsageStatus: false,
                showsGitBranchSelector: false,
                isGitBranchSelectorEnabled: false,
                availableGitBranchTargets: [],
                gitBranchesCheckedOutElsewhere: [],
                gitWorktreePathsByBranch: [:],
                selectedGitBaseBranch: "",
                currentGitBranch: "main",
                gitDefaultBranch: "main",
                isLoadingGitBranchTargets: false,
                isSwitchingGitBranch: false,
                isCreatingGitWorktree: false,
                onSelectGitBranch: { _ in },
                onCreateGitBranch: { _ in },
                onSelectGitBaseBranch: { _ in },
                onRefreshGitBranches: {},
                onRefreshUsageStatus: {},
                onSelectAccessMode: { _ in },
                canHandOffToWorktree: false,
                onTapAddImage: {},
                onTapTakePhoto: {},
                onTapVoice: {},
                onTapCreateWorktree: {},
                onSetPlanModeArmed: { _ in },
                onRemoveAttachment: { _ in },
                onStopTurn: { _ in },
                onInputChangedForFileAutocomplete: { _ in },
                onInputChangedForSkillAutocomplete: { _ in },
                onInputChangedForSlashCommandAutocomplete: { _ in },
                onSelectFileAutocomplete: { _ in },
                onSelectSkillAutocomplete: { _ in },
                onSelectSlashCommand: { _ in },
                onSelectCodeReviewTarget: { _ in },
                onSelectForkDestination: { _ in },
                onCloseSlashCommandPanel: {},
                onRemoveMentionedFile: { _ in },
                onRemoveMentionedSkill: { _ in },
                onRemoveComposerReviewSelection: {},
                onRemoveComposerSubagentsSelection: {},
                onPasteImageData: { _ in },
                onResumeQueue: {},
                onRestoreQueuedDraft: { _ in },
                onSteerQueuedDraft: { _ in },
                onRemoveQueuedDraft: { _ in },
                onSend: {}
            )
        }
        .background(Color(.secondarySystemBackground))
    }
}
