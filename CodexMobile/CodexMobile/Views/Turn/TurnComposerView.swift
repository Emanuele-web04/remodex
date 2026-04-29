// FILE: TurnComposerView.swift
// Purpose: Renders the turn composer input, queued-draft actions, attachments, and send/stop controls.
// Layer: View Component (orchestrator)
// Exports: TurnComposerView
// Depends on: SwiftUI, ComposerAttachmentsPreview, FileAutocompletePanel, SkillAutocompletePanel, SlashCommandAutocompletePanel, ComposerBottomBar, QueuedDraftsPanel, FileMentionChip, TurnComposerInputTextView, TurnComposerSecondaryBar

import SwiftUI
import UIKit

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
    let onCancelVoiceRecording: () -> Void
    let onTapCreateWorktree: () -> Void
    let onSetPlanModeArmed: (Bool) -> Void
    let onRemoveAttachment: (String) -> Void
    let onStopTurn: (String?) -> Void
    let onInputChangedForFileAutocomplete: (String) -> Void
    let onInputChangedForSkillAutocomplete: (String) -> Void
    let onInputChangedForPluginAutocomplete: (String) -> Void
    let onInputChangedForSlashCommandAutocomplete: (String) -> Void
    let onSelectFileAutocomplete: (CodexFuzzyFileMatch) -> Void
    let onSelectSkillAutocomplete: (CodexSkillMetadata) -> Void
    let onSelectPluginAutocomplete: (CodexPluginMetadata) -> Void
    let onSelectSlashCommand: (TurnComposerSlashCommand) -> Void
    let onSelectCodeReviewTarget: (TurnComposerReviewTarget) -> Void
    let onSelectForkDestination: (TurnComposerForkDestination) -> Void
    let onCloseSlashCommandPanel: () -> Void
    let onRemoveMentionedFile: (String) -> Void
    let onRemoveMentionedSkill: (String) -> Void
    let onRemoveMentionedPlugin: (String) -> Void
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
                    onRemoveMentionedPlugin: onRemoveMentionedPlugin,
                    onRemoveComposerReviewSelection: onRemoveComposerReviewSelection,
                    onRemoveComposerSubagentsSelection: onRemoveComposerSubagentsSelection
                )

                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Ask anything... @plugins, $skills, /commands")
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
                    .frame(height: max(composerInputHeight, 34))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, accessoryState.topInputPadding + 4)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isComposerInteractionLocked else { return }
                    isInputFocused.wrappedValue = true
                }
                .onChange(of: input) { _, newValue in
                    onInputChangedForFileAutocomplete(newValue)
                    onInputChangedForSkillAutocomplete(newValue)
                    onInputChangedForPluginAutocomplete(newValue)
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
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 26))
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0, alignment: .topLeading)
                    .overlay(alignment: .bottomLeading) {
                        // Keep the floating overlay stretched to the composer width so the
                        // recording capsule can expand all the way toward the trailing controls.
                        VStack(alignment: .leading, spacing: 6) {
                            if accessoryState.showsVoiceRecordingCapsule {
                                VoiceRecordingCapsule(
                                    audioLevels: accessoryState.voiceAudioLevels,
                                    duration: accessoryState.voiceRecordingDuration,
                                    onCancel: onCancelVoiceRecording
                                )
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }

                            TurnComposerAutocompletePanels(
                                state: autocompleteState,
                                onSelectFileAutocomplete: onSelectFileAutocomplete,
                                onSelectSkillAutocomplete: onSelectSkillAutocomplete,
                                onSelectPluginAutocomplete: onSelectPluginAutocomplete,
                                onSelectSlashCommand: onSelectSlashCommand,
                                onSelectCodeReviewTarget: onSelectCodeReviewTarget,
                                onSelectForkDestination: onSelectForkDestination,
                                onCloseSlashCommandPanel: onCloseSlashCommandPanel
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.top, 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: isInputFocused.wrappedValue)
    }

}

private struct TurnComposerAutocompletePanels: View {
    let state: TurnComposerAutocompleteState
    let onSelectFileAutocomplete: (CodexFuzzyFileMatch) -> Void
    let onSelectSkillAutocomplete: (CodexSkillMetadata) -> Void
    let onSelectPluginAutocomplete: (CodexPluginMetadata) -> Void
    let onSelectSlashCommand: (TurnComposerSlashCommand) -> Void
    let onSelectCodeReviewTarget: (TurnComposerReviewTarget) -> Void
    let onSelectForkDestination: (TurnComposerForkDestination) -> Void
    let onCloseSlashCommandPanel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isFileAutocompleteVisible {
                FileAutocompletePanel(
                    items: state.fileAutocompleteItems,
                    pluginItems: state.pluginAutocompleteItems,
                    isLoading: state.isFileAutocompleteLoading,
                    isLoadingPlugins: state.isPluginAutocompleteLoading,
                    query: state.fileAutocompleteQuery,
                    pluginQuery: state.pluginAutocompleteQuery,
                    onSelect: onSelectFileAutocomplete,
                    onSelectPlugin: onSelectPluginAutocomplete
                )
            }

            if !state.isFileAutocompleteVisible && state.isPluginAutocompleteVisible {
                FileAutocompletePanel(
                    items: [],
                    pluginItems: state.pluginAutocompleteItems,
                    isLoading: false,
                    isLoadingPlugins: state.isPluginAutocompleteLoading,
                    query: state.pluginAutocompleteQuery,
                    pluginQuery: state.pluginAutocompleteQuery,
                    onSelect: onSelectFileAutocomplete,
                    onSelectPlugin: onSelectPluginAutocomplete
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
                    availableGitBranchTargets: state.availableGitBranchTargets,
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
    let onRemoveMentionedPlugin: (String) -> Void
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

            if state.showsMentionedPlugins {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.composerMentionedPlugins) { plugin in
                            PluginMentionChip(pluginName: plugin.displayName ?? plugin.name) {
                                onRemoveMentionedPlugin(plugin.id)
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
                            symbolName: "point.3.connected.trianglepath.dotted",
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

#Preview("Composer Input - Runtime Controls") {
    ComposerInputRuntimePreviewWrapper()
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

            ComposerPreviewContent(
                input: $input,
                isInputFocused: $isInputFocused,
                queuedDrafts: fakeDrafts,
                canSteerQueuedDrafts: true,
                isSubagentsSelectionArmed: true,
                isPlanModeArmed: true,
                queuedCount: 3,
                isThreadRunning: true
            )
        }
        .safeAreaPadding(.bottom, 20)
        .background(Color(.secondarySystemBackground))
    }
}

private struct ComposerInputRuntimePreviewWrapper: View {
    @State private var input = ""
    @State private var isInputFocused = false

    var body: some View {
        VStack {
            Spacer()

            ComposerPreviewContent(
                input: $input,
                isInputFocused: $isInputFocused,
                queuedDrafts: [],
                canSteerQueuedDrafts: false,
                isSubagentsSelectionArmed: false,
                isPlanModeArmed: false,
                queuedCount: 0,
                isThreadRunning: false
            )
        }
        .safeAreaPadding(.bottom, 20)
        .background(Color(.secondarySystemBackground))
    }
}

// Shared preview fixture keeps the sample runtime controls aligned across composer previews.
private struct ComposerPreviewContent: View {
    @Binding var input: String
    @Binding var isInputFocused: Bool

    let queuedDrafts: [QueuedTurnDraft]
    let canSteerQueuedDrafts: Bool
    let isSubagentsSelectionArmed: Bool
    let isPlanModeArmed: Bool
    let queuedCount: Int
    let isThreadRunning: Bool

    private let reasoningOptions = TurnComposerMetaMapper.reasoningDisplayOptions(
        from: ["low", "medium", "high", "xhigh"]
    )

    private let modelOptions: [CodexModelOption] = [
        CodexModelOption(
            id: "gpt-5.5",
            model: "gpt-5.5",
            displayName: "GPT-5.5",
            description: "Preview model",
            isDefault: true,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "high", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "xhigh", description: ""),
            ],
            defaultReasoningEffort: "high"
        ),
        CodexModelOption(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            description: "Preview model",
            isDefault: false,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "high", description: ""),
            ],
            defaultReasoningEffort: "medium"
        ),
        CodexModelOption(
            id: "gpt-5.3-codex",
            model: "gpt-5.3-codex",
            displayName: "GPT-5.3-Codex",
            description: "Preview model",
            isDefault: false,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "high", description: ""),
            ],
            defaultReasoningEffort: "high"
        ),
        CodexModelOption(
            id: "gpt-5.2-codex",
            model: "gpt-5.2-codex",
            displayName: "GPT-5.2-Codex",
            description: "Preview model",
            isDefault: false,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "high", description: ""),
            ],
            defaultReasoningEffort: "medium"
        ),
        CodexModelOption(
            id: "gpt-5.2",
            model: "gpt-5.2",
            displayName: "GPT-5.2",
            description: "Preview model",
            isDefault: false,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
            ],
            defaultReasoningEffort: "medium"
        ),
        CodexModelOption(
            id: "gpt-5.1-codex-max",
            model: "gpt-5.1-codex-max",
            displayName: "GPT-5.1-Codex-Max",
            description: "Preview model",
            isDefault: false,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "high", description: ""),
            ],
            defaultReasoningEffort: "high"
        ),
        CodexModelOption(
            id: "gpt-5.1-codex-mini",
            model: "gpt-5.1-codex-mini",
            displayName: "GPT-5.1-Codex-Mini",
            description: "Preview model",
            isDefault: false,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
            ],
            defaultReasoningEffort: "low"
        ),
    ]

    var body: some View {
        TurnComposerView(
            input: $input,
            isInputFocused: $isInputFocused,
            accessoryState: TurnComposerAccessoryState(
                queuedDrafts: queuedDrafts,
                canSteerQueuedDrafts: canSteerQueuedDrafts,
                canRestoreQueuedDrafts: canSteerQueuedDrafts,
                steeringDraftID: nil,
                composerAttachments: [],
                composerMentionedFiles: [],
                composerMentionedSkills: [],
                composerMentionedPlugins: [],
                composerReviewSelection: nil,
                isSubagentsSelectionArmed: isSubagentsSelectionArmed,
                isVoiceRecording: false,
                voiceAudioLevels: [],
                voiceRecordingDuration: 0
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
                pluginAutocompleteItems: [],
                isPluginAutocompleteVisible: false,
                isPluginAutocompleteLoading: false,
                pluginAutocompleteQuery: "",
                slashCommandPanelState: .hidden,
                hasComposerContentConflictingWithReview: false,
                isThreadRunning: isThreadRunning,
                showsGitBranchSelector: false,
                isLoadingGitBranchTargets: false,
                availableGitBranchTargets: [],
                selectedGitBaseBranch: "",
                gitDefaultBranch: "main"
            ),
            remainingAttachmentSlots: 4,
            isComposerInteractionLocked: false,
            isSendDisabled: false,
            isPlanModeArmed: isPlanModeArmed,
            queuedCount: queuedCount,
            isQueuePaused: false,
            activeTurnID: nil,
            isThreadRunning: isThreadRunning,
            isEmptyThread: true,
            isWorktreeProject: false,
            orderedModelOptions: modelOptions,
            selectedModelID: "gpt-5.5",
            selectedModelTitle: "GPT-5.5",
            isLoadingModels: false,
            runtimeState: TurnComposerRuntimeState(
                reasoningDisplayOptions: reasoningOptions,
                effectiveReasoningEffort: "high",
                selectedReasoningEffort: "high",
                reasoningMenuDisabled: false,
                selectedServiceTier: .fast,
                supportsFastMode: true
            ),
            runtimeActions: TurnComposerRuntimeActions(
                selectModel: { _ in },
                selectAutomaticReasoning: {},
                selectReasoning: { _ in },
                selectServiceTier: { _ in }
            ),
            voiceButtonPresentation: TurnComposerVoiceButtonPresentation(
                systemImageName: "mic",
                foregroundColor: Color(.secondaryLabel),
                backgroundColor: .clear,
                accessibilityLabel: "Start voice transcription",
                isDisabled: false,
                showsProgress: false,
                hasCircleBackground: false
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
            onCancelVoiceRecording: {},
            onTapCreateWorktree: {},
            onSetPlanModeArmed: { _ in },
            onRemoveAttachment: { _ in },
            onStopTurn: { _ in },
            onInputChangedForFileAutocomplete: { _ in },
            onInputChangedForSkillAutocomplete: { _ in },
            onInputChangedForPluginAutocomplete: { _ in },
            onInputChangedForSlashCommandAutocomplete: { _ in },
            onSelectFileAutocomplete: { _ in },
            onSelectSkillAutocomplete: { _ in },
            onSelectPluginAutocomplete: { _ in },
            onSelectSlashCommand: { _ in },
            onSelectCodeReviewTarget: { _ in },
            onSelectForkDestination: { _ in },
            onCloseSlashCommandPanel: {},
            onRemoveMentionedFile: { _ in },
            onRemoveMentionedSkill: { _ in },
            onRemoveMentionedPlugin: { _ in },
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
}
