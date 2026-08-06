// FILE: TurnComposerView.swift
// Purpose: Renders the turn composer input, queued-draft actions, attachments, and send/stop controls.
// Layer: View Component (orchestrator)
// Exports: TurnComposerView, TurnComposerInputChangeHandler
// Depends on: SwiftUI, AdaptiveGlassModifier, ComposerAttachmentsPreview, FileAutocompletePanel, SkillAutocompletePanel, SlashCommandAutocompletePanel, ComposerBottomBar, QueuedDraftsSheet, TurnMentionChips, TurnComposerInputTextView, TurnComposerSecondaryBar

import SwiftUI
import UIKit

// Keeps autocomplete fan-out outside the view body so input editing remains a
// single UI event from TurnComposerView's perspective.
struct TurnComposerInputChangeHandler {
    let handleFileAutocomplete: (String) -> Void
    let handleSkillAutocomplete: (String) -> Void
    let handlePluginAutocomplete: (String) -> Void
    let handleSlashCommandAutocomplete: (String) -> Void

    func callAsFunction(_ text: String) {
        handleFileAutocomplete(text)
        handleSkillAutocomplete(text)
        handlePluginAutocomplete(text)
        handleSlashCommandAutocomplete(text)
    }
}

struct TurnComposerView: View {
    @Binding var input: String
    let isInputFocused: Binding<Bool>

    let accessoryState: TurnComposerAccessoryState
    let autocompleteState: TurnComposerAutocompleteState
    let remainingAttachmentSlots: Int
    let isComposerInteractionLocked: Bool
    let isSendDisabled: Bool
    let isSending: Bool
    let isPlanModeArmed: Bool
    let queuedCount: Int
    let isQueuePaused: Bool
    let activeTurnID: String?
    let isThreadRunning: Bool
    let isEmptyThread: Bool
    let hasWorkingDirectory: Bool
    let isWorktreeProject: Bool
    var activeFileChangeStatus: FileChangeStatusSnapshot? = nil
    var threadGoal: CodexThreadGoal? = nil
    var onEditGoal: () -> Void = {}
    var onRemoveGoal: () -> Void = {}
    var onResumeGoal: () -> Void = {}
    var onPauseGoal: () -> Void = {}

    let orderedModelOptions: [CodexModelOption]
    let selectedModelID: String?
    let selectedModelTitle: String
    let isLoadingModels: Bool
    let isRuntimeSelectionLoading: Bool

    let runtimeState: TurnComposerRuntimeState
    let runtimeActions: TurnComposerRuntimeActions
    let voiceButtonPresentation: TurnComposerVoiceButtonPresentation

    let selectedAccessMode: CodexAccessMode
    let contextWindowUsage: ContextWindowUsage?
    let rateLimitBuckets: [CodexRateLimitBucket]
    let isLoadingRateLimits: Bool
    let rateLimitsErrorMessage: String?
    let shouldAutoRefreshUsageStatus: Bool

    let gitState: TurnComposerGitState
    let gitActions: TurnComposerGitActions
    let onRefreshUsageStatus: () async -> Void
    // Re-requests model/list when the runtime picker opens without options
    // (bootstrap fetch failed or still in flight). Defaulted for previews.
    var onRefreshModelsIfNeeded: () -> Void = {}

    let onSelectAccessMode: (CodexAccessMode) -> Void
    let onTapAddImage: () -> Void
    let onTapTakePhoto: () -> Void
    let onTapVoice: () -> Void
    let onCancelVoiceRecording: () -> Void
    let onSetPlanModeArmed: (Bool) -> Void
    let onRemoveAttachment: (String) -> Void
    let onStopTurn: (String?) -> Void
    let onInputChanged: TurnComposerInputChangeHandler
    let onSelectFileAutocomplete: (CodexFuzzyFileMatch) -> Void
    let onSelectSkillAutocomplete: (CodexSkillMetadata) -> Void
    let onSelectPluginAutocomplete: (CodexPluginMetadata) -> Void
    let onSelectSlashCommand: (TurnComposerSlashCommand) -> Void
    let onSelectCodeReviewTarget: (TurnComposerReviewTarget) -> Void
    let onSelectForkDestination: (TurnComposerForkDestination) -> Void
    let onCloseSlashCommandPanel: () -> Void
    let onRemoveMentionedFile: (String) -> Void
    let onRemoveMentionedPlugin: (String) -> Void
    let onRemoveComposerReviewSelection: () -> Void
    let onRemoveComposerSubagentsSelection: () -> Void
    let onPasteImageData: ([Data]) -> Void
    let onResumeQueue: () -> Void
    let onRestoreQueuedDraft: (String) -> Void
    let onSteerQueuedDraft: (String) -> Void
    let onRemoveQueuedDraft: (String) -> Void
    let onSend: () -> Void
    // Call sites can hide the project git/runtime row above the input for
    // constrained surfaces; access and usage always live in the bottom bar.
    var showsSecondaryBar: Bool = true
    // Every composer surface (in-thread and New Chat draft) collapses to a
    // capsule at rest; call sites may opt out for constrained hosts.
    var allowsCollapsedComposer: Bool = true

    // One text line of the composer font; keeps the resting capsule height
    // stable regardless of async UITextView measurements while still scaling
    // with Dynamic Type so large accessibility sizes don't clip the placeholder.
    @ScaledMetric(relativeTo: .body) private var collapsedInputHeight: CGFloat = 22

    // Square hit target for the resting capsule's "+", mic, and send/stop
    // controls. The extra 2pt keeps the closed capsule comfortable to tap.
    private let collapsedControlTapTarget: CGFloat = 34
    // Extra inset applied to the resting capsule (and the accessory row above
    // it, so the two stay flush) on top of the composer's own 12pt margins.
    private static let collapsedComposerInset: CGFloat = 24
    private let expandedPlainTextMaxVisibleLines: CGFloat = 6
    private let expandedAccessoryTextMaxVisibleLines: CGFloat = 4

    @State private var composerInputHeight: CGFloat = 32
    @State private var inputChangeTask: Task<Void, Never>?
    @State private var isShowingQueuedDraftsSheet = false
    // The runtime picker is presented from the always-mounted composer root (not
    // from the bottom bar) so it survives the composer collapsing mid-flow.
    @State private var showsRuntimeOverlay = false

    @Environment(\.pinnedPlanAccessory) private var pinnedPlanAccessory

    // Whether the carousel row (chevron, file changes, plan, queued) has
    // anything to show; mirrors the pills rendered by TurnComposerSecondaryBar.
    private var hasSecondaryBarContent: Bool {
        hasWorkingDirectory
            || activeFileChangeStatus != nil
            || threadGoal != nil
            || pinnedPlanAccessory != nil
            || !accessoryState.queuedDrafts.isEmpty
    }

    private var showsSendButton: Bool {
        !isThreadRunning || accessoryState.hasSendableContent(input: input)
    }

    // Collapse to a single glass capsule whenever the keyboard is closed. Only
    // pending composer content (typed text, attachments/mentions) or an active
    // voice recording keeps the expanded layout; a running turn stays collapsed
    // and surfaces Stop inside the capsule instead. Queued drafts live in the
    // carousel capsule above, so they never expand the composer.
    private var showsCollapsedComposer: Bool {
        allowsCollapsedComposer
            && !isInputFocused.wrappedValue
            && input.isEmpty
            && !accessoryState.hasTopAccessoryContent
            && !accessoryState.showsVoiceRecordingCapsule
    }

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        VStack(spacing: 6) {
            // The capsule stays outside the glass container: its glass lives on
            // a `Color.clear` background layer (see VoiceRecordingCapsule), so
            // inside a `GlassEffectContainer` the waveform/timer would be
            // plain sibling content that the container renders beneath the
            // promoted glass surface — i.e. blurred out. Standalone glass
            // draws behind the capsule content like a normal background and
            // never merges with the composer card's glass.
            if accessoryState.showsVoiceRecordingCapsule {
                VoiceRecordingCapsule(
                    audioLevels: accessoryState.voiceAudioLevels,
                    duration: accessoryState.voiceRecordingDuration,
                    onCancel: onCancelVoiceRecording
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            AdaptiveGlassContainer(spacing: 6) {
                composerStack
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        // Keep a little breathing room below the glass so the composer doesn't
        // sit flush against the keyboard (or the home indicator when at rest).
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Morph between the collapsed capsule and the full composer as focus
        // changes. The input text view stays mounted in both states so the
        // keyboard rises and dismisses in the same motion as the morph instead
        // of waiting for a view swap.
        .animation(.snappy(duration: 0.26), value: showsCollapsedComposer)
        .sheet(isPresented: $isShowingQueuedDraftsSheet) {
            QueuedDraftsSheet(
                drafts: accessoryState.queuedDrafts,
                canSteerDrafts: accessoryState.canSteerQueuedDrafts,
                canRestoreDrafts: accessoryState.canRestoreQueuedDrafts,
                steeringDraftID: accessoryState.steeringDraftID,
                onRestore: onRestoreQueuedDraft,
                onSteer: onSteerQueuedDraft,
                onRemove: onRemoveQueuedDraft
            )
        }
        // Containment, not presentation: presenting any view controller ends
        // editing and drops the keyboard. The overlay is installed in this same
        // hierarchy, so the composer keeps focus and the chat behind it is what
        // gets blurred. Anchored here so the picker sits right above the keyboard.
        .fullScreenOverlay(isPresented: showsRuntimeOverlay) {
            runtimeSliderOverlay
        }
        .onChange(of: accessoryState.hasQueuedDrafts) { _, hasDrafts in
            if !hasDrafts {
                isShowingQueuedDraftsSheet = false
            }
        }
    }

    private var composerStack: some View {
        VStack(spacing: 6) {
            // Gated here (not inside the bar) so the VStack never keeps an
            // empty child whose spacing could leave a stray gap above the
            // input. The row stays visible while the composer rests as a
            // collapsed capsule and hides only when the keyboard takes the
            // space or a voice recording is in progress.
            if showsSecondaryBar,
               !accessoryState.showsVoiceRecordingCapsule,
               !isInputFocused.wrappedValue,
               hasSecondaryBarContent {
                TurnComposerSecondaryBar(
                    isEmptyThread: isEmptyThread,
                    hasWorkingDirectory: hasWorkingDirectory,
                    isWorktreeProject: isWorktreeProject,
                    activeFileChangeStatus: activeFileChangeStatus,
                    threadGoal: threadGoal,
                    isThreadRunning: isThreadRunning,
                    onEditGoal: onEditGoal,
                    onRemoveGoal: onRemoveGoal,
                    onResumeGoal: onResumeGoal,
                    onPauseGoal: onPauseGoal,
                    queuedDraftCount: accessoryState.queuedDrafts.count,
                    onTapQueuedDrafts: { isShowingQueuedDraftsSheet = true },
                    gitState: gitState,
                    gitActions: gitActions
                )
                // Keep the accessory pills lined up with whichever width the
                // surface below them currently has.
                .padding(.horizontal, showsCollapsedComposer ? Self.collapsedComposerInset : 0)
            }

            VStack(spacing: 0) {
                if !showsCollapsedComposer {
                    TurnComposerAccessorySection(
                        state: accessoryState,
                        onRemoveAttachment: onRemoveAttachment,
                        onRemoveMentionedFile: onRemoveMentionedFile,
                        onRemoveMentionedPlugin: onRemoveMentionedPlugin,
                        onRemoveComposerReviewSelection: onRemoveComposerReviewSelection,
                        onRemoveComposerSubagentsSelection: onRemoveComposerSubagentsSelection,
                        onRemoveComposerPlanModeSelection: { onSetPlanModeArmed(false) }
                    )
                }

                // The text view is unconditional so UIKit keeps one first-responder
                // surface across the collapse/expand morph: tapping the resting
                // capsule begins editing immediately (keyboard and morph animate
                // together), and losing focus dismisses the keyboard in the same
                // motion as the collapse.
                HStack(alignment: .center, spacing: 8) {
                    if showsCollapsedComposer {
                        ComposerAttachmentMenu(
                            isPlanModeArmed: isPlanModeArmed,
                            runtimeState: runtimeState,
                            runtimeActions: runtimeActions,
                            remainingAttachmentSlots: remainingAttachmentSlots,
                            isInteractionLocked: isComposerInteractionLocked,
                            onSetPlanModeArmed: onSetPlanModeArmed,
                            onTapAddImage: onTapAddImage,
                            onTapTakePhoto: onTapTakePhoto,
                            tapTargetSide: collapsedControlTapTarget
                        )
                        .frame(width: collapsedControlTapTarget, height: collapsedControlTapTarget)
                        .transition(.opacity)
                    }

                    ZStack(alignment: showsCollapsedComposer ? .leading : .topLeading) {
                        if input.isEmpty {
                            Text(placeholderText)
                                .font(AppFont.body())
                                .foregroundStyle(Color(.placeholderText))
                                .lineLimit(1)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: showsCollapsedComposer ? collapsedInputHeight : 0,
                                    alignment: showsCollapsedComposer ? .leading : .topLeading
                                )
                                .padding(
                                    .top,
                                    showsCollapsedComposer ? 0 : TurnComposerInputTextView.textContainerInset.top
                                )
                                .allowsHitTesting(false)
                        }

                        TurnComposerInputTextView(
                            text: $input,
                            isFocused: isInputFocused,
                            isEditable: !isComposerInteractionLocked,
                            dynamicHeight: $composerInputHeight,
                            mentionedSkillNames: accessoryState.composerMentionedSkills.map(\.name),
                            runtimeState: runtimeState,
                            runtimeActions: runtimeActions,
                            isCollapsed: showsCollapsedComposer,
                            maxVisibleLines: expandedInputMaxVisibleLines,
                            onPasteImageData: { imageDataItems in
                                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                                onPasteImageData(imageDataItems)
                            }
                        )
                        // Collapsed: a fixed single-line box so the (empty) input
                        // centers exactly like the old capsule and never resizes
                        // from async height measurements. Expanded: measured height.
                        .frame(height: showsCollapsedComposer ? collapsedInputHeight : max(composerInputHeight, 34))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Focus only from taps on the text area itself, so the inline
                    // +/mic/Stop controls (and the gaps around them) never expand
                    // the composer instead of performing their own action.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isComposerInteractionLocked else { return }
                        isInputFocused.wrappedValue = true
                    }

                    if showsCollapsedComposer {
                        ComposerVoiceButton(
                            presentation: voiceButtonPresentation,
                            onTap: onTapVoice,
                            tapTargetSide: collapsedControlTapTarget
                        )
                        .frame(width: collapsedControlTapTarget, height: collapsedControlTapTarget)
                        .transition(.opacity)

                        // Keep Stop reachable while a turn runs even in the resting capsule.
                        if isThreadRunning {
                            ComposerStopControl(
                                activeTurnID: activeTurnID,
                                isSending: isSending,
                                onStopTurn: onStopTurn
                            )
                            .transition(.opacity)
                        }
                    }
                }
                // Collapsed capsule: 6pt on every side so the 34pt inline controls
                // sit at the same distance from the edges as the 6pt vertical rhythm.
                .padding(.leading, showsCollapsedComposer ? 6 : 14)
                .padding(.trailing, showsCollapsedComposer ? 6 : 16)
                // Resting row: 6pt above and below the row content, with
                // `composerSurfaceCornerRadius` derived as half the resulting
                // height so the surface reads as a true capsule. The expanded
                // card keeps its own rhythm.
                .padding(.top, showsCollapsedComposer ? 6 : accessoryState.topInputPadding + 4)
                .padding(.bottom, showsCollapsedComposer ? 6 : 4)
                .onChange(of: input) { _, newValue in
                    inputChangeTask?.cancel()
                    // Coalesce fast typing into one autocomplete refresh per main-actor turn.
                    inputChangeTask = Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        onInputChanged(newValue)
                    }
                }

                if !showsCollapsedComposer {
                    expandedBottomBar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: composerSurfaceCornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: composerSurfaceCornerRadius))
            // The resting capsule sits noticeably narrower than the expanded
            // composer, so the closed state reads as a floating control rather
            // than an edge-to-edge input bar.
            .padding(.horizontal, showsCollapsedComposer ? Self.collapsedComposerInset : 0)
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0, alignment: .topLeading)
                    .overlay(alignment: .bottomLeading) {
                        // Keep autocomplete stretched to the composer width so large panels
                        // align with the glass input instead of the typed token.
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .offset(y: -8)
            }
            .zIndex(2)
        }
    }

    private var expandedBottomBar: some View {
        ComposerBottomBar(
            runtimeLabelParts: runtimeLabelParts,
            runtimeState: runtimeState,
            runtimeActions: runtimeActions,
            remainingAttachmentSlots: remainingAttachmentSlots,
            isComposerInteractionLocked: isComposerInteractionLocked,
            isSendDisabled: isSendDisabled,
            isSending: isSending,
            isPlanModeArmed: isPlanModeArmed,
            queuedCount: queuedCount,
            isQueuePaused: isQueuePaused,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning,
            showsSendButton: showsSendButton,
            voiceButtonPresentation: voiceButtonPresentation,
            selectedAccessMode: selectedAccessMode,
            contextWindowUsage: contextWindowUsage,
            rateLimitBuckets: rateLimitBuckets,
            isLoadingRateLimits: isLoadingRateLimits,
            rateLimitsErrorMessage: rateLimitsErrorMessage,
            shouldAutoRefreshUsageStatus: shouldAutoRefreshUsageStatus,
            onRefreshUsageStatus: onRefreshUsageStatus,
            onSelectAccessMode: onSelectAccessMode,
            onTapAddImage: onTapAddImage,
            onTapTakePhoto: onTapTakePhoto,
            onTapVoice: onTapVoice,
            onSetPlanModeArmed: onSetPlanModeArmed,
            onResumeQueue: onResumeQueue,
            onStopTurn: onStopTurn,
            onTapRuntimePill: {
                // A failed bootstrap fetch would otherwise leave the picker
                // with no fast-mode toggle and no effort slider forever.
                onRefreshModelsIfNeeded()
                showsRuntimeOverlay = true
            },
            onSend: onSend
        )
    }

    // MARK: - Runtime picker hosting

    // Shared by the pill and the slider overlay so both render identical text.
    private var runtimeLabelParts: TurnComposerRuntimeLabelParts {
        TurnComposerMetaMapper.runtimeLabelParts(
            selectedModelID: selectedModelID,
            selectedModelTitle: selectedModelTitle,
            isRuntimeSelectionLoading: isRuntimeSelectionLoading,
            runtimeState: runtimeState
        )
    }

    // The overlay owns its own backdrop, model menu, and all-models sheet; this
    // view only decides when it is on screen.
    private var runtimeSliderOverlay: some View {
        ComposerRuntimeSliderOverlay(
            runtimeState: runtimeState,
            runtimeActions: runtimeActions,
            modelDisplayTitle: runtimeLabelParts.modelPart,
            effortDisplayTitle: runtimeLabelParts.effortPart,
            orderedModelOptions: orderedModelOptions,
            selectedModelID: selectedModelID,
            isLoadingModels: isLoadingModels,
            onDismiss: { showsRuntimeOverlay = false }
        )
    }

    private var placeholderText: String {
        isEmptyThread ? "Ask Remodex" : "Follow up"
    }

    // The radius animates to the expanded card's 26 inside the same morph.
    // Resting row content height: the inline control tap targets, or the scaled
    // text line when Dynamic Type grows past them.
    private var collapsedRowContentHeight: CGFloat {
        max(collapsedInputHeight, collapsedControlTapTarget)
    }

    // Attachments and mention chips already consume vertical keyboard space, so
    // switch the text field to internal scrolling sooner to keep the whole
    // composer card above the keyboard in compact draft screens.
    private var expandedInputMaxVisibleLines: CGFloat {
        accessoryState.hasTopAccessoryContent
            ? expandedAccessoryTextMaxVisibleLines
            : expandedPlainTextMaxVisibleLines
    }

    // Collapsed: half the resting height (6pt padding + content + 6pt padding)
    // so the surface reads as a true capsule at every Dynamic Type size.
    // Expanded: the standard 26pt card radius.
    private var composerSurfaceCornerRadius: CGFloat {
        showsCollapsedComposer ? (collapsedRowContentHeight + 12) / 2 : 26
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
                    trigger: state.skillAutocompleteTrigger,
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

private struct TurnComposerAccessorySection: View {
    let state: TurnComposerAccessoryState
    let onRemoveAttachment: (String) -> Void
    let onRemoveMentionedFile: (String) -> Void
    let onRemoveMentionedPlugin: (String) -> Void
    let onRemoveComposerReviewSelection: () -> Void
    let onRemoveComposerSubagentsSelection: () -> Void
    let onRemoveComposerPlanModeSelection: () -> Void

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

            TurnComposerMentionChipSections(
                state: state,
                onRemoveMentionedFile: onRemoveMentionedFile,
                onRemoveMentionedPlugin: onRemoveMentionedPlugin,
                onRemoveComposerReviewSelection: onRemoveComposerReviewSelection,
                onRemoveComposerSubagentsSelection: onRemoveComposerSubagentsSelection,
                onRemoveComposerPlanModeSelection: onRemoveComposerPlanModeSelection
            )
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
        from: ["low", "medium", "high", "xhigh", "max"]
    )

    private let modelOptions: [CodexModelOption] = [
        CodexModelOption(
            id: "gpt-5.6-sol",
            model: "gpt-5.6-sol",
            displayName: "GPT-5.6-Sol",
            description: "Preview model",
            isDefault: true,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "high", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "xhigh", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "max", description: ""),
            ],
            defaultReasoningEffort: "high"
        ),
        CodexModelOption(
            id: "gpt-5.6-terra",
            model: "gpt-5.6-terra",
            displayName: "GPT-5.6-Terra",
            description: "Preview model",
            isDefault: false,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "high", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "xhigh", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "max", description: ""),
            ],
            defaultReasoningEffort: "medium"
        ),
        CodexModelOption(
            id: "gpt-5.6-luna",
            model: "gpt-5.6-luna",
            displayName: "GPT-5.6-Luna",
            description: "Preview model",
            isDefault: false,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "high", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "xhigh", description: ""),
                CodexReasoningEffortOption(reasoningEffort: "max", description: ""),
            ],
            defaultReasoningEffort: "medium"
        ),
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
            supportsFastMode: false,
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
                isPlanModeArmed: isPlanModeArmed,
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
                skillAutocompleteTrigger: "$",
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
            isSending: false,
            isPlanModeArmed: isPlanModeArmed,
            queuedCount: queuedCount,
            isQueuePaused: false,
            activeTurnID: nil,
            isThreadRunning: isThreadRunning,
            isEmptyThread: true,
            hasWorkingDirectory: true,
            isWorktreeProject: false,
            orderedModelOptions: modelOptions,
            selectedModelID: "gpt-5.6-sol",
            selectedModelTitle: "GPT-5.6-Sol",
            isLoadingModels: false,
            isRuntimeSelectionLoading: false,
            runtimeState: TurnComposerRuntimeState(
                reasoningDisplayOptions: reasoningOptions,
                effectiveReasoningEffort: "max",
                selectedReasoningEffort: "max",
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
                foregroundColor: Color.primary,
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
            gitState: TurnComposerGitState(
                currentGitBranch: "main",
                gitDefaultBranch: "main"
            ),
            gitActions: TurnComposerGitActions(),
            onRefreshUsageStatus: {},
            onSelectAccessMode: { _ in },
            onTapAddImage: {},
            onTapTakePhoto: {},
            onTapVoice: {},
            onCancelVoiceRecording: {},
            onSetPlanModeArmed: { _ in },
            onRemoveAttachment: { _ in },
            onStopTurn: { _ in },
            onInputChanged: TurnComposerInputChangeHandler(
                handleFileAutocomplete: { _ in },
                handleSkillAutocomplete: { _ in },
                handlePluginAutocomplete: { _ in },
                handleSlashCommandAutocomplete: { _ in }
            ),
            onSelectFileAutocomplete: { _ in },
            onSelectSkillAutocomplete: { _ in },
            onSelectPluginAutocomplete: { _ in },
            onSelectSlashCommand: { _ in },
            onSelectCodeReviewTarget: { _ in },
            onSelectForkDestination: { _ in },
            onCloseSlashCommandPanel: {},
            onRemoveMentionedFile: { _ in },
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
