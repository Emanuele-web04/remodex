// FILE: NewChatDraftView.swift
// Purpose: Compose-first New Chat surface that lets users pick a local folder
//          before the first send creates the real runtime thread.
// Layer: View
// Exports: NewChatDraftRoute, NewChatDraftView
// Depends on: SwiftUI, PhotosUI, CodexService, TurnComposerHostView,
//             SidebarNewChatProjectPickerSheet, SidebarLocalFolderBrowserSheet

import PhotosUI
import SwiftUI
import UIKit

struct NewChatDraftRoute: Hashable {
    let id: String
    let preferredProjectPath: String?
    let source: NewChatDraftSource

    var isFromGeneralChat: Bool {
        source == .generalChat
    }
}

// Tracks which sidebar affordance opened the draft. UI experiments can branch
// on `route.isFromGeneralChat` while keeping thread creation logic shared.
enum NewChatDraftSource: Hashable {
    case generalChat
    case folderChat
}

// Picks which leading toolbar affordance the New Chat surface should show.
// Pushed routes fall back to the system back chevron (same as the rest of the
// chats); drawer mode swaps in the hamburger so the sidebar stays one tap away.
enum NewChatDraftLeadingControl {
    case back
    case hamburger(action: () -> Void)
}

struct NewChatDraftView: View {
    @Environment(CodexService.self) private var codex
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(\.openURL) private var openURL
    @Environment(\.reconnectAction) private var reconnectAction
    @Environment(\.scenePhase) private var scenePhase

    let route: NewChatDraftRoute
    var leadingControl: NewChatDraftLeadingControl = .back
    var onOpenTerminal: ((String?) -> Void)? = nil
    let onOpenThread: @MainActor @Sendable (CodexThread) -> Void

    @State private var viewModel = TurnViewModel()
    @State private var isInputFocused = false
    @State private var selectedProjectPath: String?
    @State private var projectlessChatRootPaths: [String] = []
    @State private var activeSheet: NewChatDraftSheet?
    @State private var hasInitializedProjectSelection = false
    @State private var isLoadingRepositoryDiff = false
    @State private var repositoryDiffPresentation: TurnDiffPresentation?
    @State private var alertApprovalRequest: CodexApprovalRequest?
    @State private var isApprovalAlertPresented = false
    @State private var isShowingMacHandoffConfirm = false
    @State private var macHandoffErrorMessage: String?
    @State private var isDeferringSendForFocusDismissal = false
    @State private var isVoiceRecording = false
    @State private var isVoicePreflighting = false
    @State private var voicePreflightGeneration = 0
    @State private var voiceOperationGeneration = 0
    @State private var voiceTranscriptionTask: Task<Void, Never>?
    @State private var isVoiceTranscribing = false
    @State private var hasTriggeredVoiceAutoStop = false
    @State private var voiceRecoveryReason: CodexVoiceFailureReason?
    @State private var isShowingVoiceSetupSheet = false
    @StateObject private var voiceTranscriptionManager = GPTVoiceTranscriptionManager()

    // UI-only check for layout experiments: true when opened from the general
    // sidebar Chat affordance, false when opened from a folder section button.
    private var isFromGeneralChat: Bool {
        route.isFromGeneralChat
    }

    var body: some View {
        // Keep the draft surface static while first send creates the real thread.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            promptStack
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .navigationTitle("New thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .hamburger(let action) = leadingControl {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: action) {
                        TwoLineHamburgerIcon()
                    }
                    .accessibilityLabel("Open menu")
                }
            }
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .title) {
                    toolbarTitleLabel
                }
            } else {
                ToolbarItem(placement: .principal) {
                    toolbarTitleLabel
                }
            }

            if hasSelectedProject {
                ToolbarItem(placement: .topBarTrailing) {
                    draftGitActionsButton
                }

                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                draftThreadActionsMenu
            }
        }
        .task {
            initializeProjectSelectionIfNeeded()
            refreshDraftGitStateIfNeeded()
            await refreshProjectlessChatRoots()
            refreshDraftGitStateIfNeeded()
        }
        .onChange(of: projectChoices) { _, _ in
            initializeProjectSelectionIfNeeded()
        }
        .onChange(of: codex.isConnected) { wasConnected, isConnected in
            if !isConnected {
                return
            }

            if voiceRecoveryReason == .reconnectRequired {
                clearVoiceRecovery()
            }
            guard !wasConnected, isConnected else { return }
            refreshDraftGitStateIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            cancelVoiceTranscriptionIfNeeded()
            cancelVoiceRecordingIfNeeded()
            invalidatePendingVoicePreflight()
            viewModel.saveLocalDraft(codex: codex, threadID: route.id, persistToDisk: true)
        }
        .onChange(of: selectedProjectPath) { _, _ in
            // Defer the observable-model mutation out of the .onChange action
            // to avoid AttributeGraph cycles when the parent re-renders.
            DispatchQueue.main.async { [viewModel] in
                viewModel.clearComposerAutocomplete()
            }
            refreshDraftGitStateForSelectedProject()
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .sheet(item: $repositoryDiffPresentation) { presentation in
            TurnDiffSheet(
                title: presentation.title,
                entries: presentation.entries,
                bodyText: presentation.bodyText,
                messageID: presentation.messageID
            )
        }
        .turnViewAlerts(
            alertApprovalRequest: $alertApprovalRequest,
            isApprovalAlertPresented: $isApprovalAlertPresented,
            isShowingNothingToCommitAlert: isShowingNothingToCommitAlertBinding,
            gitSyncAlert: gitSyncAlertBinding,
            isShowingMacHandoffConfirm: $isShowingMacHandoffConfirm,
            macHandoffErrorMessage: $macHandoffErrorMessage,
            onDeclineApproval: { _ in },
            onApproveApproval: { _ in },
            onConfirmGitSyncAction: { action in
                viewModel.confirmGitSyncAlertAction(
                    action,
                    codex: codex,
                    workingDirectory: selectedProjectPath,
                    threadID: route.id,
                    activeTurnID: nil
                )
            },
            onDismissGitSyncAlert: {
                viewModel.dismissGitSyncAlert()
            },
            onConfirmMacHandoff: {}
        )
        .fullScreenCover(isPresented: isCameraPresentedBinding) {
            CameraImagePicker { data in
                viewModel.enqueueCapturedImageData(data, codex: codex, threadID: route.id)
            }
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: isPhotoPickerPresentedBinding,
            selection: photoPickerItemsBinding,
            maxSelectionCount: max(1, viewModel.remainingAttachmentSlots),
            matching: .images,
            preferredItemEncoding: .automatic
        )
        .onChange(of: viewModel.photoPickerItems) { _, newItems in
            // Defer the observable-model mutation out of the .onChange action
            // to avoid AttributeGraph cycles when the parent re-renders.
            DispatchQueue.main.async { [viewModel] in
                viewModel.enqueuePhotoPickerItems(newItems, codex: codex, threadID: route.id)
                viewModel.photoPickerItems = []
            }
        }
        .onReceive(voiceTranscriptionManager.$recordingDuration) { duration in
            guard isVoiceRecording,
                  !isVoiceTranscribing,
                  !hasTriggeredVoiceAutoStop,
                  duration >= voiceAutoStopThreshold else {
                return
            }

            hasTriggeredVoiceAutoStop = true
            beginVoiceStopTranscription()
        }
        .onReceive(voiceTranscriptionManager.$captureInvalidationID) { invalidationID in
            guard invalidationID > 0 else { return }
            handleVoiceCaptureInvalidation()
        }
        .onDisappear {
            cancelVoiceTranscriptionIfNeeded()
            cancelVoiceRecordingIfNeeded()
            invalidatePendingVoicePreflight()
            clearVoiceRecovery()
        }
        .sheet(isPresented: $isShowingVoiceSetupSheet) {
            GPTVoiceSetupSheet()
        }
    }

    // Source-specific prompt UI:
    // - General Chat exposes the picker only while it is project-backed; rootless Quick Chat stays bare.
    // - Folder/project button keeps the normal title because that folder is already implied.
    private var promptStack: some View {
        Group {
            if isFromGeneralChat {
                generalChatPrompt
            } else {
                folderButtonPrompt
            }
        }
        .padding()
    }

    private var generalChatPrompt: some View {
        VStack(spacing: 8) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .adaptiveGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.bottom, 4)
            Text("What should we work on?")
                .font(AppFont.title2(weight: .regular))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            if hasSelectedProject {
                folderPickerPill
                Text("Chats are End-to-end encrypted")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
    }

    private var folderButtonPrompt: some View {
        VStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .adaptiveGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            ChatEmptyStateTitleBuilder.makeTitle(for: placeholderFolderName)
                .font(AppFont.title2(weight: .regular))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text("Chats are End-to-end encrypted")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }

    private var toolbarTitleLabel: some View {
        TurnChatToolbarTitleLabel(
            title: "New thread",
            subtitle: placeholderFolderName ?? trustedHostName,
            onTap: hasSelectedProject ? { activeSheet = .projectPicker } : nil,
            accessibilityHint: hasSelectedProject ? "Opens the project picker" : nil
        )
    }

    // Drafts expose Git state/actions whenever a folder is selected (including the
    // general-chat default seeded from the latest used project).
    private var draftGitActionsButton: some View {
        TurnGitActionsToolbarButton(
            isEnabled: isDraftGitActionEnabled,
            disabledActions: areDraftToolbarActionsDisabled ? Set(TurnGitActionKind.allCases) : viewModel.disabledGitActions,
            isRunningAction: viewModel.isRunningGitAction,
            loadingTitle: nil,
            showsDiscardRuntimeChangesAndSync: viewModel.shouldShowDiscardRuntimeChangesAndSync,
            gitSyncState: viewModel.gitSyncState,
            repoDiffTotals: viewModel.gitRepoSync?.repoDiffTotals,
            isLoadingRepoDiff: isLoadingRepositoryDiff,
            onTapRepoDiff: areDraftToolbarActionsDisabled ? nil : {
                presentRepositoryDiff()
            },
            onSelect: handleDraftGitActionSelection
        )
        .opacity(areDraftToolbarActionsDisabled ? 0.45 : 1)
        .disabled(areDraftToolbarActionsDisabled)
    }

    // Mirrors the regular chat ellipsis chrome only when a folder-backed draft can act on a cwd.
    private var draftThreadActionsMenu: some View {
        TurnThreadActionsMenuButton(
            isLoading: false,
            isEnabled: !areDraftToolbarActionsDisabled,
            actions: [
                TurnThreadActionMenuItem(
                    title: "Open Terminal Here",
                    icon: .system("terminal"),
                    isEnabled: !areDraftToolbarActionsDisabled && onOpenTerminal != nil
                ) {
                    onOpenTerminal?(selectedProjectPath)
                },
            ]
        )
    }

    private var areDraftToolbarActionsDisabled: Bool {
        !hasSelectedProject
    }

    private var isDraftGitActionEnabled: Bool {
        !areDraftToolbarActionsDisabled
            && viewModel.gitRepoSync != nil
            && viewModel.canRunGitAction(
                isConnected: codex.isConnected,
                isThreadRunning: false,
                hasGitWorkingDirectory: selectedProjectPath != nil
            )
    }

    // Drafts refresh only the selected project's Git state so the secondary
    // composer bar can show Local/branch controls before the first send.
    private func refreshDraftGitStateIfNeeded() {
        guard hasSelectedProject, codex.isConnected else {
            return
        }
        viewModel.refreshGitBranchTargets(
            codex: codex,
            workingDirectory: selectedProjectPath,
            threadID: route.id
        )
    }

    private func refreshDraftGitStateForSelectedProject() {
        resetDraftGitState()
        refreshDraftGitStateIfNeeded()
    }

    private func resetDraftGitState() {
        viewModel.gitRepoSync = nil
        viewModel.currentGitBranch = ""
        viewModel.availableGitBranchTargets = []
        viewModel.gitBranchesCheckedOutElsewhere = []
        viewModel.gitWorktreePathsByBranch = [:]
        viewModel.gitLocalCheckoutPath = nil
        viewModel.gitDefaultBranch = ""
        viewModel.selectedGitBaseBranch = ""
    }

    private var hasSelectedProject: Bool {
        selectedProjectPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func handleDraftGitActionSelection(_ action: TurnGitActionKind) {
        guard isDraftGitActionEnabled else { return }
        viewModel.triggerGitAction(
            action,
            codex: codex,
            workingDirectory: selectedProjectPath,
            threadID: route.id,
            activeTurnID: nil
        )
    }

    // Fetches the repo patch for folder-backed drafts so the Git menu's
    // "Changes" row matches the regular TurnView toolbar behavior.
    private func presentRepositoryDiff() {
        guard !isLoadingRepositoryDiff,
              !areDraftToolbarActionsDisabled else {
            return
        }
        isLoadingRepositoryDiff = true

        Task { @MainActor in
            defer { isLoadingRepositoryDiff = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: selectedProjectPath)
            do {
                let result = try await gitService.diff()
                guard let presentation = TurnDiffPresentationBuilder.repositoryPresentation(from: result.patch) else {
                    viewModel.gitSyncAlert = TurnGitSyncAlert(
                        title: "Git Error",
                        message: "There are no repository changes to show.",
                        action: .dismissOnly
                    )
                    return
                }
                repositoryDiffPresentation = presentation
            } catch let error as GitActionsError {
                viewModel.gitSyncAlert = TurnGitSyncAlert(
                    title: "Git Error",
                    message: error.errorDescription ?? "Could not load repository changes.",
                    action: .dismissOnly
                )
            } catch {
                viewModel.gitSyncAlert = TurnGitSyncAlert(
                    title: "Git Error",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    private var isShowingNothingToCommitAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isShowingNothingToCommitAlert },
            set: { viewModel.isShowingNothingToCommitAlert = $0 }
        )
    }

    private var gitSyncAlertBinding: Binding<TurnGitSyncAlert?> {
        Binding(
            get: { viewModel.gitSyncAlert },
            set: { newValue in
                if let newValue {
                    viewModel.gitSyncAlert = newValue
                } else {
                    viewModel.dismissGitSyncAlert()
                }
            }
        )
    }

    private var placeholderFolderName: String? {
        guard let selectedProjectPath,
              !selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return selectedProjectPath.pathDisplayName
    }

    // Always reads the same way as the toolbar subtitle so the inline pill and
    // the navigation block never disagree on the currently bound folder.
    private var folderPillLabel: String {
        placeholderFolderName ?? "Quick Chat"
    }

    // Compact inline picker shown below the "What should we work on?" prompt.
    // Mirrors the toolbar subtitle target so tapping either entry point opens
    // the same project picker sheet.
    private var folderPickerPill: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            activeSheet = .projectPicker
        } label: {
            HStack(spacing: 6) {
                pickerIcon
                Text(folderPillLabel)
                    .font(AppFont.title2(weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(AppFont.title2(weight: .regular))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select folder")
        .accessibilityHint("Opens the project picker")
        .accessibilityValue(folderPillLabel)
    }

    // Uses the custom Remodex folder glyph so the inline picker matches the rest of the sidebar.
    private var pickerIcon: some View {
        Image("central-folder-2")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
    }

    private var trustedHostName: String? {
        let trimmed = (codex.trustedPairPresentation?.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let voiceRecoveryPresentation {
                ConnectionRecoveryCard(snapshot: voiceRecoveryPresentation.snapshot) {
                    handleVoiceRecoveryAction(voiceRecoveryPresentation.action)
                }
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            TurnComposerHostView(
                viewModel: viewModel,
                codex: codex,
                thread: draftThread,
                activeTurnID: nil,
                isThreadRunning: false,
                isEmptyThread: true,
                isWorktreeProject: false,
                canForkLocally: false,
                isInputFocused: $isInputFocused,
                orderedModelOptions: orderedModelOptions,
                selectedModelTitle: selectedModelTitle,
                reasoningDisplayOptions: reasoningDisplayOptions,
                showsGitControls: hasSelectedProject && viewModel.isGitRepositoryInitialized,
                isGitBranchSelectorEnabled: isDraftGitActionEnabled && viewModel.isGitRepositoryInitialized,
                onSelectGitBranch: { branch in
                    guard hasSelectedProject else { return }
                    viewModel.requestSwitchGitBranch(
                        to: branch,
                        codex: codex,
                        workingDirectory: selectedProjectPath,
                        threadID: route.id,
                        activeTurnID: nil
                    )
                },
                onCreateGitBranch: { branchName in
                    guard hasSelectedProject else { return }
                    viewModel.requestCreateGitBranch(
                        named: branchName,
                        codex: codex,
                        workingDirectory: selectedProjectPath,
                        threadID: route.id,
                        activeTurnID: nil
                    )
                },
                onRefreshGitBranches: {
                    guard hasSelectedProject, viewModel.isGitRepositoryInitialized else { return }
                    viewModel.refreshGitBranchTargets(
                        codex: codex,
                        workingDirectory: selectedProjectPath,
                        threadID: route.id
                    )
                },
                onStartCodeReviewThread: { target in
                    viewModel.applyPendingComposerAction(.codeReview(target: target.codexPendingTarget))
                },
                onStartForkThreadLocally: {},
                onOpenForkWorktree: {},
                onOpenWorktreeHandoff: {},
                onOpenFeedbackMail: {},
                onShowStatus: {},
                voiceButtonPresentation: voiceButtonPresentation,
                isVoiceInputActive: isVoiceInputActive,
                isVoiceRecording: isVoiceRecording,
                voiceAudioLevels: voiceTranscriptionManager.audioLevels,
                voiceRecordingDuration: voiceTranscriptionManager.recordingDuration,
                onTapVoice: handleVoiceButtonTap,
                onCancelVoiceRecording: cancelVoiceRecordingIfNeeded,
                onSend: sendDraft,
                showsSecondaryBar: true
            )
        }
        .animation(.easeInOut(duration: 0.18), value: voiceRecoveryPresentation?.snapshot.summary)
        .animation(.easeInOut(duration: 0.18), value: isVoiceRecording)
    }

    private var draftThread: CodexThread {
        CodexThread(
            id: route.id,
            title: "New thread",
            cwd: selectedProjectPath
        )
    }

    private var projectChoices: [SidebarProjectChoice] {
        SidebarThreadGrouping.makeProjectChoices(
            from: codex.threads,
            projectlessRootPaths: projectlessChatRootPaths
        )
    }

    private var orderedModelOptions: [CodexModelOption] {
        TurnComposerMetaMapper.orderedModels(from: codex.availableModels)
    }

    private var reasoningDisplayOptions: [TurnComposerReasoningDisplayOption] {
        TurnComposerMetaMapper.reasoningDisplayOptions(
            from: codex.supportedReasoningEffortsForSelectedModel().map(\.reasoningEffort)
        )
    }

    private var selectedModelTitle: String {
        if let selectedModel = codex.selectedModelOption() {
            return TurnComposerMetaMapper.modelTitle(for: selectedModel)
        }

        return TurnComposerMetaMapper.modelTitle(forIdentifier: codex.selectedModelId)
    }

    // Mirrors the regular TurnView mic state so empty drafts can record before a runtime thread exists.
    private var voiceButtonPresentation: TurnComposerVoiceButtonPresentation {
        TurnVoiceButtonPresentationBuilder.presentation(
            isTranscribing: isVoiceTranscribing,
            isPreflighting: isVoicePreflighting,
            isRecording: isVoiceRecording,
            isConnected: codex.isConnected
        )
    }

    private var isVoiceInputActive: Bool {
        isVoiceRecording || isVoicePreflighting || isVoiceTranscribing
    }

    private var voiceRecoveryPresentation: VoiceRecoveryPresentation? {
        guard let voiceRecoveryReason,
              let resolvedReason = codex.resolveVoiceRecoveryReason(voiceRecoveryReason) else {
            return nil
        }

        return TurnVoiceRecoveryPresentationBuilder.presentation(for: resolvedReason)
    }

    private var isPhotoPickerPresentedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isPhotoPickerPresented },
            set: { viewModel.isPhotoPickerPresented = $0 }
        )
    }

    private var isCameraPresentedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isCameraPresented },
            set: { viewModel.isCameraPresented = $0 }
        )
    }

    private var photoPickerItemsBinding: Binding<[PhotosPickerItem]> {
        Binding(
            get: { viewModel.photoPickerItems },
            set: { viewModel.photoPickerItems = $0 }
        )
    }

    private func initializeProjectSelectionIfNeeded() {
        guard !hasInitializedProjectSelection else { return }

        // A general-chat route without a preferred path is an explicit rootless Quick Chat.
        // Keep it unbound instead of falling back to the first recent project.
        guard !(isFromGeneralChat && route.preferredProjectPath == nil) else {
            selectedProjectPath = nil
            hasInitializedProjectSelection = true
            return
        }

        selectedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(route.preferredProjectPath)
            ?? projectChoices.first?.projectPath
        hasInitializedProjectSelection = selectedProjectPath != nil || !projectChoices.isEmpty
    }

    private func refreshProjectlessChatRoots() async {
        guard codex.isConnected else { return }

        do {
            let roots = try await codex.fetchProjectlessChatRoots().roots
            guard roots != projectlessChatRootPaths else { return }
            projectlessChatRootPaths = roots
            initializeProjectSelectionIfNeeded()
        } catch {
            // Project grouping still has built-in fallbacks for older local bridges.
        }
    }

    private func sendDraft() {
        guard !isVoiceInputActive else { return }
        guard !isDeferringSendForFocusDismissal else { return }
        isDeferringSendForFocusDismissal = true
        isInputFocused = false

        let openThread: @MainActor @Sendable (CodexThread) -> Void = { thread in
            onOpenThread(thread)
        }
        Task { @MainActor in
            await Task.yield()
            viewModel.sendNewThread(
                codex: codex,
                subscriptions: subscriptions,
                draftThreadID: route.id,
                preferredProjectPath: selectedProjectPath,
                onThreadCreated: openThread
            )
            isDeferringSendForFocusDismissal = false
        }
    }

    // Switches the draft composer between ready, recording, and transcription states.
    private func handleVoiceButtonTap() {
        if isVoiceTranscribing {
            return
        }

        if isVoiceRecording {
            beginVoiceStopTranscription()
            return
        }

        Task { @MainActor in
            await startVoiceRecordingIfReady()
        }
    }

    // Starts a single draft stop/upload operation so double taps and auto-stop cannot race each other.
    private func beginVoiceStopTranscription() {
        guard isVoiceRecording, !isVoiceTranscribing else {
            return
        }

        hasTriggeredVoiceAutoStop = false
        isVoiceTranscribing = true
        voiceOperationGeneration += 1
        let operationGeneration = voiceOperationGeneration
        voiceTranscriptionTask?.cancel()
        voiceTranscriptionTask = Task { @MainActor in
            await stopVoiceTranscription(operationGeneration: operationGeneration)
        }
    }

    // Stops the draft recorder, transcribes through the bridge, and inserts text into the unsent draft.
    private func stopVoiceTranscription(operationGeneration: Int) async {
        defer {
            if isVoiceOperationCurrent(operationGeneration) {
                isVoiceTranscribing = false
                voiceTranscriptionTask = nil
            }
        }

        do {
            guard let clip = try voiceTranscriptionManager.stopRecording() else {
                if isVoiceOperationCurrent(operationGeneration) {
                    isVoiceRecording = false
                    voiceTranscriptionManager.resetMeteringState()
                    presentVoiceRecovery(for: .recorderUnavailable)
                }
                return
            }

            defer {
                try? FileManager.default.removeItem(at: clip.url)
            }

            isVoiceRecording = false
            voiceTranscriptionManager.resetMeteringState()
            let transcript = try await codex.transcribeVoiceAudioFile(
                at: clip.url,
                durationSeconds: clip.durationSeconds
            )
            guard isVoiceOperationCurrent(operationGeneration), !Task.isCancelled else {
                return
            }
            clearVoiceRecovery()
            viewModel.appendVoiceTranscript(transcript)
            viewModel.saveLocalDraft(codex: codex, threadID: route.id, persistToDisk: true)
            isInputFocused = false
        } catch {
            guard isVoiceOperationCurrent(operationGeneration), !Task.isCancelled else {
                return
            }
            isVoiceRecording = false
            voiceTranscriptionManager.resetMeteringState()
            presentVoiceRecovery(for: error)
        }
    }

    // Starts microphone capture before the first thread is created; auth resolves only after stop.
    @MainActor
    private func startVoiceRecordingIfReady() async {
        guard !isVoicePreflighting else {
            return
        }

        guard codex.supportsBridgeVoiceTranscription else {
            presentVoiceRecovery(for: .bridgeSessionUnsupported)
            return
        }

        guard codex.isConnected else {
            presentVoiceRecovery(for: .reconnectRequired)
            return
        }

        clearVoiceRecovery()
        codex.lastErrorMessage = nil
        hasTriggeredVoiceAutoStop = false
        isInputFocused = false
        let preflightGeneration = voicePreflightGeneration + 1
        voicePreflightGeneration = preflightGeneration
        isVoicePreflighting = true
        defer {
            if isVoicePreflightCurrent(preflightGeneration) {
                isVoicePreflighting = false
            }
        }

        do {
            guard isVoicePreflightCurrent(preflightGeneration) else {
                return
            }
            try await voiceTranscriptionManager.startRecording()
            guard isVoicePreflightCurrent(preflightGeneration) else {
                voiceTranscriptionManager.cancelRecording()
                return
            }
            isVoiceRecording = true
            isInputFocused = false
        } catch {
            guard isVoicePreflightCurrent(preflightGeneration) else {
                return
            }
            presentVoiceRecovery(for: error)
        }
    }

    private func cancelVoiceRecordingIfNeeded() {
        guard isVoiceRecording || isVoicePreflighting else {
            return
        }

        voiceTranscriptionManager.cancelRecording()
        isVoiceRecording = false
        isVoicePreflighting = false
        hasTriggeredVoiceAutoStop = false
    }

    // Resets the draft composer when the system invalidates the active microphone capture.
    private func handleVoiceCaptureInvalidation() {
        guard isVoiceRecording || isVoicePreflighting else {
            return
        }

        cancelVoiceTranscriptionIfNeeded()
        invalidatePendingVoicePreflight()
        isVoiceRecording = false
        isVoicePreflighting = false
        hasTriggeredVoiceAutoStop = false
        presentVoiceRecovery(for: .recorderUnavailable)
    }

    private var voiceAutoStopThreshold: TimeInterval {
        max(0, CodexVoiceTranscriptionPreflight.maxDurationSeconds - 0.25)
    }

    private func clearVoiceRecovery() {
        voiceRecoveryReason = nil
    }

    private func presentVoiceRecovery(for error: Error) {
        presentVoiceRecovery(for: codex.classifyVoiceFailure(error))
    }

    private func presentVoiceRecovery(for reason: CodexVoiceFailureReason) {
        voiceRecoveryReason = reason
        codex.lastErrorMessage = nil
    }

    private func handleVoiceRecoveryAction(_ action: VoiceRecoveryAction) {
        switch action {
        case .reconnect:
            reconnectAction?()
        case .openMacLogin:
            startVoiceLoginOnMac()
        case .showSetupHelp:
            isShowingVoiceSetupSheet = true
        case .openSystemSettings:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            openURL(settingsURL)
        case .none:
            break
        }
    }

    // Opens the Codex ChatGPT login flow on the paired Mac while the draft composer stays in place.
    private func startVoiceLoginOnMac() {
        Task { @MainActor in
            do {
                try await codex.startOrResumeGPTLoginOnMac()
                presentVoiceRecovery(for: .voiceSyncInProgress)
            } catch {
                presentVoiceRecovery(for: error)
            }
        }
    }

    private func cancelVoiceTranscriptionIfNeeded() {
        guard isVoiceTranscribing || voiceTranscriptionTask != nil else {
            return
        }

        voiceOperationGeneration += 1
        voiceTranscriptionTask?.cancel()
        voiceTranscriptionTask = nil
        isVoiceTranscribing = false
    }

    private func invalidatePendingVoicePreflight() {
        voicePreflightGeneration += 1
        isVoicePreflighting = false
        voiceTranscriptionManager.cancelRecording()
    }

    private func isVoicePreflightCurrent(_ generation: Int) -> Bool {
        generation == voicePreflightGeneration
    }

    private func isVoiceOperationCurrent(_ generation: Int) -> Bool {
        generation == voiceOperationGeneration
    }

    @ViewBuilder
    private func sheetContent(_ sheet: NewChatDraftSheet) -> some View {
        switch sheet {
        case .projectPicker:
            SidebarNewChatProjectPickerSheet(
                choices: projectChoices,
                showsWithoutProjectOption: isFromGeneralChat,
                showsWorktreeOptions: false,
                onSelectProject: { projectPath in
                    selectedProjectPath = projectPath
                    activeSheet = nil
                },
                onSelectWorktreeProject: { projectPath in
                    selectedProjectPath = projectPath
                    activeSheet = nil
                },
                onSelectWithoutProject: {
                    selectedProjectPath = nil
                    activeSheet = nil
                },
                onBrowseLocalFolder: {
                    activeSheet = .localFolderBrowser
                }
            )
        case .localFolderBrowser:
            SidebarLocalFolderBrowserSheet { projectPath in
                selectedProjectPath = projectPath
                activeSheet = nil
            }
        }
    }
}

private enum NewChatDraftSheet: String, Identifiable {
    case projectPicker
    case localFolderBrowser

    var id: String { rawValue }
}

#Preview("New Chat Draft") {
    NavigationStack {
        NewChatDraftView(
            route: NewChatDraftRoute(
                id: "draft_preview",
                preferredProjectPath: "/Users/emanueledipietro/Developer/Remodex",
                source: .generalChat
            ),
            onOpenThread: { _ in }
        )
    }
    .environment(CodexService())
    .environment(SubscriptionService())
}

#Preview("New Chat Draft – No Folder") {
    NavigationStack {
        NewChatDraftView(
            route: NewChatDraftRoute(
                id: "draft_preview_no_folder",
                preferredProjectPath: nil,
                source: .generalChat
            ),
            onOpenThread: { _ in }
        )
    }
    .environment(CodexService())
    .environment(SubscriptionService())
}

#Preview("New Chat Draft – Folder Button") {
    NavigationStack {
        NewChatDraftView(
            route: NewChatDraftRoute(
                id: "draft_preview_folder_button",
                preferredProjectPath: "/Users/emanueledipietro/Developer/Remodex",
                source: .folderChat
            ),
            onOpenThread: { _ in }
        )
    }
    .environment(CodexService())
    .environment(SubscriptionService())
}
