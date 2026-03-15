// FILE: TurnComposerView.swift
// Purpose: Renders the turn composer input, queued-draft actions, attachments, and send/stop controls.
// Layer: View Component (orchestrator)
// Exports: TurnComposerView
// Depends on: SwiftUI, ComposerAttachmentsPreview, FileAutocompletePanel, SkillAutocompletePanel, SlashCommandAutocompletePanel, ComposerBottomBar, QueuedDraftsPanel, FileMentionChip, TurnComposerInputTextView

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

    let orderedModelOptions: [CodexModelOption]
    let selectedModelID: String?
    let selectedModelTitle: String
    let isLoadingModels: Bool

    let runtimeState: TurnComposerRuntimeState
    let runtimeActions: TurnComposerRuntimeActions

    let selectedAccessMode: CodexAccessMode
    let contextWindowUsage: ContextWindowUsage?

    let showsGitBranchSelector: Bool
    let isGitBranchSelectorEnabled: Bool
    let availableGitBranchTargets: [String]
    let gitBranchesCheckedOutElsewhere: Set<String>
    let selectedGitBaseBranch: String
    let currentGitBranch: String
    let gitDefaultBranch: String
    let isLoadingGitBranchTargets: Bool
    let isSwitchingGitBranch: Bool
    let onSelectGitBranch: (String) -> Void
    let onSelectGitBaseBranch: (String) -> Void
    let onRefreshGitBranches: () -> Void
    let onRefreshContextWindowUsage: () async -> Void

    let onSelectAccessMode: (CodexAccessMode) -> Void
    let onTapAddImage: () -> Void
    let onTapTakePhoto: () -> Void
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
    let onRemoveMentionedFile: (String) -> Void
    let onRemoveMentionedSkill: (String) -> Void
    let onRemoveComposerReviewSelection: () -> Void
    let onPasteImageData: ([Data]) -> Void
    let onResumeQueue: () -> Void
    let onSteerQueuedDraft: (String) -> Void
    let onRemoveQueuedDraft: (String) -> Void
    let onSend: () -> Void

    @State private var composerInputHeight: CGFloat = 32

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        VStack(spacing: 6) {
            TurnComposerAutocompletePanels(
                state: autocompleteState,
                onSelectFileAutocomplete: onSelectFileAutocomplete,
                onSelectSkillAutocomplete: onSelectSkillAutocomplete,
                onSelectSlashCommand: onSelectSlashCommand,
                onSelectCodeReviewTarget: onSelectCodeReviewTarget,
                onRemoveComposerReviewSelection: onRemoveComposerReviewSelection
            )

            TurnComposerQueuedDraftsSection(
                drafts: accessoryState.queuedDrafts,
                canSteerDrafts: accessoryState.canSteerQueuedDrafts,
                steeringDraftID: accessoryState.steeringDraftID,
                onSteerQueuedDraft: onSteerQueuedDraft,
                onRemoveQueuedDraft: onRemoveQueuedDraft
            )

            VStack(spacing: 0) {
                TurnComposerAccessorySection(
                    state: accessoryState,
                    onRemoveAttachment: onRemoveAttachment,
                    onRemoveMentionedFile: onRemoveMentionedFile,
                    onRemoveMentionedSkill: onRemoveMentionedSkill,
                    onRemoveComposerReviewSelection: onRemoveComposerReviewSelection
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
                    onTapAddImage: onTapAddImage,
                    onTapTakePhoto: onTapTakePhoto,
                    onSetPlanModeArmed: onSetPlanModeArmed,
                    onResumeQueue: onResumeQueue,
                    onStopTurn: onStopTurn,
                    onSend: onSend
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28))

            if !isInputFocused.wrappedValue {
                // The secondary control row is nice to have, but when the keyboard is up
                // it can become the first thing that gets clipped on shorter devices.
                HStack(spacing: 0) {
                    HStack(spacing: 14) {
                        runtimePicker
                        accessMenuLabel
                    }

                    Spacer(minLength: 0)

                    if showsGitBranchSelector {
                        HStack(spacing: 10) {
                            TurnGitBranchSelector(
                                isEnabled: isGitBranchSelectorEnabled,
                                availableGitBranchTargets: availableGitBranchTargets,
                                gitBranchesCheckedOutElsewhere: gitBranchesCheckedOutElsewhere,
                                selectedGitBaseBranch: selectedGitBaseBranch,
                                currentGitBranch: currentGitBranch,
                                defaultBranch: gitDefaultBranch,
                                isLoadingGitBranchTargets: isLoadingGitBranchTargets,
                                isSwitchingGitBranch: isSwitchingGitBranch,
                                onSelectGitBranch: onSelectGitBranch,
                                onSelectGitBaseBranch: onSelectGitBaseBranch,
                                onRefreshGitBranches: onRefreshGitBranches
                            )

                            ContextWindowProgressRing(
                                usage: contextWindowUsage,
                                onRefresh: onRefreshContextWindowUsage
                            )
                        }
                    } else {
                        ContextWindowProgressRing(
                            usage: contextWindowUsage,
                            onRefresh: onRefreshContextWindowUsage
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .adaptiveGlass(.regular, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.18), value: isInputFocused.wrappedValue)
    }

    // MARK: - Below-card controls

    private var accessMenuLabel: some View {
        Menu {
            ForEach(CodexAccessMode.allCases, id: \.rawValue) { mode in
                Button {
                    HapticFeedback.shared.triggerImpactFeedback(style: .light)
                    onSelectAccessMode(mode)
                } label: {
                    if selectedAccessMode == mode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedAccessMode == .fullAccess
                      ? "exclamationmark.shield"
                      : "checkmark.shield")
                    .font(branchTextFont)

                Text(selectedAccessMode.displayName)
                    .font(branchTextFont)
                    .fontWeight(.regular)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(branchChevronFont)
            }
            .foregroundStyle(selectedAccessMode == .fullAccess ? .orange : branchLabelColor)
            .contentShape(Rectangle())
        }
        .tint(branchLabelColor)
    }

    // MARK: - Runtime controls

    private var runtimePicker: some View {
        Menu {
            Button {
                // Already on Local — no-op.
            } label: {
                Label("Local", systemImage: "checkmark")
            }

            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                if let url = URL(string: "https://chatgpt.com/codex") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Cloud")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(branchTextFont)

                Text("Local")
                    .font(branchTextFont)
                    .fontWeight(.regular)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(branchChevronFont)
            }
            .foregroundStyle(branchLabelColor)
            .contentShape(Rectangle())
        }
        .tint(branchLabelColor)
    }

    private let branchLabelColor = Color(.secondaryLabel)
    private var branchTextFont: Font { AppFont.subheadline() }
    private var branchChevronFont: Font { AppFont.system(size: 9, weight: .regular) }
}

private struct TurnComposerAutocompletePanels: View {
    let state: TurnComposerAutocompleteState
    let onSelectFileAutocomplete: (CodexFuzzyFileMatch) -> Void
    let onSelectSkillAutocomplete: (CodexSkillMetadata) -> Void
    let onSelectSlashCommand: (TurnComposerSlashCommand) -> Void
    let onSelectCodeReviewTarget: (TurnComposerReviewTarget) -> Void
    let onRemoveComposerReviewSelection: () -> Void

    var body: some View {
        Group {
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
                    hasComposerContentConflictingWithReview: state.hasComposerContentConflictingWithReview,
                    showsGitBranchSelector: state.showsGitBranchSelector,
                    isLoadingGitBranchTargets: state.isLoadingGitBranchTargets,
                    selectedGitBaseBranch: state.selectedGitBaseBranch,
                    gitDefaultBranch: state.gitDefaultBranch,
                    onSelectCommand: onSelectSlashCommand,
                    onSelectReviewTarget: onSelectCodeReviewTarget,
                    onClose: onRemoveComposerReviewSelection
                )
            }
        }
    }
}

private struct TurnComposerQueuedDraftsSection: View {
    let drafts: [QueuedTurnDraft]
    let canSteerDrafts: Bool
    let steeringDraftID: String?
    let onSteerQueuedDraft: (String) -> Void
    let onRemoveQueuedDraft: (String) -> Void

    var body: some View {
        Group {
            if !drafts.isEmpty {
                QueuedDraftsPanel(
                    drafts: drafts,
                    canSteerDrafts: canSteerDrafts,
                    steeringDraftID: steeringDraftID,
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

            if let reviewTarget = state.reviewTarget {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ReviewMentionChip(title: "Code Review: \(reviewTarget.title)") {
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
                    steeringDraftID: nil,
                    composerAttachments: [],
                    composerMentionedFiles: [],
                    composerMentionedSkills: [],
                    composerReviewSelection: nil
                ),
                autocompleteState: TurnComposerAutocompleteState(
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
                selectedAccessMode: .onRequest,
                contextWindowUsage: nil,
                showsGitBranchSelector: false,
                isGitBranchSelectorEnabled: false,
                availableGitBranchTargets: [],
                gitBranchesCheckedOutElsewhere: [],
                selectedGitBaseBranch: "",
                currentGitBranch: "main",
                gitDefaultBranch: "main",
                isLoadingGitBranchTargets: false,
                isSwitchingGitBranch: false,
                onSelectGitBranch: { _ in },
                onSelectGitBaseBranch: { _ in },
                onRefreshGitBranches: {},
                onRefreshContextWindowUsage: {},
                onSelectAccessMode: { _ in },
                onTapAddImage: {},
                onTapTakePhoto: {},
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
                onRemoveMentionedFile: { _ in },
                onRemoveMentionedSkill: { _ in },
                onRemoveComposerReviewSelection: {},
                onPasteImageData: { _ in },
                onResumeQueue: {},
                onSteerQueuedDraft: { _ in },
                onRemoveQueuedDraft: { _ in },
                onSend: {}
            )
        }
        .background(Color(.secondarySystemBackground))
    }
}
