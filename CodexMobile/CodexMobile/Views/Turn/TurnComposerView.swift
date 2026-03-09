// FILE: TurnComposerView.swift
// Purpose: Renders the turn composer input, queued-draft actions, attachments, and send/stop controls.
// Layer: View Component (orchestrator)
// Exports: TurnComposerView
// Depends on: SwiftUI, ComposerAttachmentsPreview, FileAutocompletePanel, SkillAutocompletePanel, ComposerBottomBar, QueuedDraftsPanel, FileMentionChip, TurnComposerInputTextView

import SwiftUI
import UIKit

struct TurnComposerView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var input: String
    let isInputFocused: Binding<Bool>

    let composerAttachments: [TurnComposerImageAttachment]
    let remainingAttachmentSlots: Int
    let isComposerInteractionLocked: Bool
    let isSendDisabled: Bool
    let isPlanModeArmed: Bool
    let queuedDrafts: [QueuedTurnDraft]
    let queuedCount: Int
    let isQueuePaused: Bool
    let canSteerQueuedDrafts: Bool
    let steeringDraftID: String?
    let activeTurnID: String?
    let isThreadRunning: Bool
    let composerMentionedFiles: [TurnComposerMentionedFile]
    let composerMentionedSkills: [TurnComposerMentionedSkill]
    let fileAutocompleteItems: [CodexFuzzyFileMatch]
    let isFileAutocompleteVisible: Bool
    let isFileAutocompleteLoading: Bool
    let fileAutocompleteQuery: String
    let skillAutocompleteItems: [CodexSkillMetadata]
    let isSkillAutocompleteVisible: Bool
    let isSkillAutocompleteLoading: Bool
    let skillAutocompleteQuery: String

    let orderedModelOptions: [CodexModelOption]
    let selectedModelID: String?
    let selectedModelTitle: String
    let isLoadingModels: Bool

    let reasoningDisplayOptions: [TurnComposerReasoningDisplayOption]
    let selectedReasoningEffort: String?
    let selectedReasoningTitle: String
    let reasoningMenuDisabled: Bool

    let selectedAccessMode: CodexAccessMode

    let showsGitBranchSelector: Bool
    let isGitBranchSelectorEnabled: Bool
    let availableGitBranchTargets: [String]
    let selectedGitBaseBranch: String
    let currentGitBranch: String
    let gitDefaultBranch: String
    let isLoadingGitBranchTargets: Bool
    let isSwitchingGitBranch: Bool
    let onSelectGitBranch: (String) -> Void
    let onSelectGitBaseBranch: (String) -> Void
    let onRefreshGitBranches: () -> Void

    let onSelectModel: (String) -> Void
    let onSelectReasoning: (String) -> Void
    let onSelectAccessMode: (CodexAccessMode) -> Void
    let onTapAddImage: () -> Void
    let onTapTakePhoto: () -> Void
    let onSetPlanModeArmed: (Bool) -> Void
    let onRemoveAttachment: (String) -> Void
    let onStopTurn: (String?) -> Void
    let onInputChangedForFileAutocomplete: (String) -> Void
    let onInputChangedForSkillAutocomplete: (String) -> Void
    let onSelectFileAutocomplete: (CodexFuzzyFileMatch) -> Void
    let onSelectSkillAutocomplete: (CodexSkillMetadata) -> Void
    let onRemoveMentionedFile: (String) -> Void
    let onRemoveMentionedSkill: (String) -> Void
    let onPasteImageData: ([Data]) -> Void
    let onResumeQueue: () -> Void
    let onSteerQueuedDraft: (String) -> Void
    let onRemoveQueuedDraft: (String) -> Void
    let onSend: () -> Void

    @State private var composerInputHeight: CGFloat = 32

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        VStack(spacing: 6) {
            if isFileAutocompleteVisible {
                FileAutocompletePanel(
                    items: fileAutocompleteItems,
                    isLoading: isFileAutocompleteLoading,
                    query: fileAutocompleteQuery,
                    onSelect: onSelectFileAutocomplete
                )
            }

            if isSkillAutocompleteVisible {
                SkillAutocompletePanel(
                    items: skillAutocompleteItems,
                    isLoading: isSkillAutocompleteLoading,
                    query: skillAutocompleteQuery,
                    onSelect: onSelectSkillAutocomplete
                )
            }

            if !queuedDrafts.isEmpty {
                QueuedDraftsPanel(
                    drafts: queuedDrafts,
                    canSteerDrafts: canSteerQueuedDrafts,
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

            VStack(spacing: 0) {
                if !composerAttachments.isEmpty {
                    ComposerAttachmentsPreview(
                        attachments: composerAttachments,
                        onRemove: onRemoveAttachment
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }

                if !composerMentionedFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(composerMentionedFiles) { file in
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

                if !composerMentionedSkills.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(composerMentionedSkills) { skill in
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

                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text("Ask for follow-up changes")
                            .font(AppFont.body())
                            .foregroundStyle(Color(.placeholderText))
                            .allowsHitTesting(false)
                    }

                    TurnComposerInputTextView(
                        text: $input,
                        isFocused: isInputFocused,
                        isEditable: !isComposerInteractionLocked,
                        dynamicHeight: $composerInputHeight,
                        onPasteImageData: { imageDataItems in
                            HapticFeedback.shared.triggerImpactFeedback(style: .light)
                            onPasteImageData(imageDataItems)
                        }
                    )
                    .frame(height: composerInputHeight)
                }
                .padding(.horizontal, 16)
                .padding(
                    .top,
                    composerAttachments.isEmpty && composerMentionedFiles.isEmpty && composerMentionedSkills.isEmpty
                        ? 14 : 8
                )
                .padding(.bottom, 12)
                .onChange(of: input) { _, newValue in
                    onInputChangedForFileAutocomplete(newValue)
                    onInputChangedForSkillAutocomplete(newValue)
                }

                ComposerBottomBar(
                    orderedModelOptions: orderedModelOptions,
                    selectedModelID: selectedModelID,
                    selectedModelTitle: selectedModelTitle,
                    isLoadingModels: isLoadingModels,
                    reasoningDisplayOptions: reasoningDisplayOptions,
                    selectedReasoningEffort: selectedReasoningEffort,
                    selectedReasoningTitle: selectedReasoningTitle,
                    reasoningMenuDisabled: reasoningMenuDisabled,
                    remainingAttachmentSlots: remainingAttachmentSlots,
                    isComposerInteractionLocked: isComposerInteractionLocked,
                    isSendDisabled: isSendDisabled,
                    isPlanModeArmed: isPlanModeArmed,
                    queuedCount: queuedCount,
                    isQueuePaused: isQueuePaused,
                    activeTurnID: activeTurnID,
                    isThreadRunning: isThreadRunning,
                    onSelectModel: onSelectModel,
                    onSelectReasoning: onSelectReasoning,
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
                        TurnGitBranchSelector(
                            isEnabled: isGitBranchSelectorEnabled,
                            availableGitBranchTargets: availableGitBranchTargets,
                            selectedGitBaseBranch: selectedGitBaseBranch,
                            currentGitBranch: currentGitBranch,
                            defaultBranch: gitDefaultBranch,
                            isLoadingGitBranchTargets: isLoadingGitBranchTargets,
                            isSwitchingGitBranch: isSwitchingGitBranch,
                            onSelectGitBranch: onSelectGitBranch,
                            onSelectGitBaseBranch: onSelectGitBaseBranch,
                            onRefreshGitBranches: onRefreshGitBranches
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

#Preview("Queued Drafts + Composer") {
    QueuedDraftsPanelPreviewWrapper()
}

private struct QueuedDraftsPanelPreviewWrapper: View {
    @State private var input = ""
    @State private var isInputFocused = false

    private let fakeDrafts: [QueuedTurnDraft] = [
        QueuedTurnDraft(id: "1", text: "Fix the login bug on the settings page", attachments: [], skillMentions: [], createdAt: .now),
        QueuedTurnDraft(id: "2", text: "Add dark mode support to the onboarding flow", attachments: [], skillMentions: [], createdAt: .now),
        QueuedTurnDraft(id: "3", text: "Refactor the networking layer to use async/await", attachments: [], skillMentions: [], createdAt: .now),
    ]

    var body: some View {
        VStack {
            Spacer()

            TurnComposerView(
                input: $input,
                isInputFocused: $isInputFocused,
                composerAttachments: [],
                remainingAttachmentSlots: 4,
                isComposerInteractionLocked: false,
                isSendDisabled: false,
                isPlanModeArmed: true,
                queuedDrafts: fakeDrafts,
                queuedCount: 3,
                isQueuePaused: false,
                canSteerQueuedDrafts: true,
                steeringDraftID: nil,
                activeTurnID: nil,
                isThreadRunning: true,
                composerMentionedFiles: [],
                composerMentionedSkills: [],
                fileAutocompleteItems: [],
                isFileAutocompleteVisible: false,
                isFileAutocompleteLoading: false,
                fileAutocompleteQuery: "",
                skillAutocompleteItems: [],
                isSkillAutocompleteVisible: false,
                isSkillAutocompleteLoading: false,
                skillAutocompleteQuery: "",
                orderedModelOptions: [],
                selectedModelID: nil,
                selectedModelTitle: "GPT-5.3-Codex",
                isLoadingModels: false,
                reasoningDisplayOptions: [],
                selectedReasoningEffort: nil,
                selectedReasoningTitle: "High",
                reasoningMenuDisabled: true,
                selectedAccessMode: .onRequest,
                showsGitBranchSelector: false,
                isGitBranchSelectorEnabled: false,
                availableGitBranchTargets: [],
                selectedGitBaseBranch: "",
                currentGitBranch: "main",
                gitDefaultBranch: "main",
                isLoadingGitBranchTargets: false,
                isSwitchingGitBranch: false,
                onSelectGitBranch: { _ in },
                onSelectGitBaseBranch: { _ in },
                onRefreshGitBranches: {},
                onSelectModel: { _ in },
                onSelectReasoning: { _ in },
                onSelectAccessMode: { _ in },
                onTapAddImage: {},
                onTapTakePhoto: {},
                onSetPlanModeArmed: { _ in },
                onRemoveAttachment: { _ in },
                onStopTurn: { _ in },
                onInputChangedForFileAutocomplete: { _ in },
                onInputChangedForSkillAutocomplete: { _ in },
                onSelectFileAutocomplete: { _ in },
                onSelectSkillAutocomplete: { _ in },
                onRemoveMentionedFile: { _ in },
                onRemoveMentionedSkill: { _ in },
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
