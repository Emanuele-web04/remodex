// FILE: TurnView.swift
// Purpose: Orchestrates turn screen composition, wiring service state to timeline + composer components.
// Layer: View
// Exports: TurnView
// Depends on: CodexService, TurnViewModel, TurnConversationContainerView, TurnComposerHostView, TurnViewAlertModifier, TurnViewLifecycleModifier

import SwiftUI
import PhotosUI
import UIKit

struct TurnView: View {
    let thread: CodexThread

    @Environment(CodexService.self) private var codex
    @Environment(\.openURL) private var openURL
    @Environment(\.reconnectAction) private var reconnectAction
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = TurnViewModel()
    @State private var isInputFocused = false
    @State private var isShowingThreadPathSheet = false
    @State private var isShowingStatusSheet = false
    @State private var isLoadingRepositoryDiff = false
    @State private var repositoryDiffPresentation: TurnDiffPresentation?
    @State private var assistantRevertSheetState: AssistantRevertSheetState?
    @State private var alertApprovalRequest: CodexApprovalRequest?
    @State private var isShowingMacHandoffConfirm = false
    @State private var isShowingWorktreeHandoff = false
    @State private var isShowingForkWorktree = false
    @State private var macHandoffErrorMessage: String?
    @State private var isHandingOffToMac = false
    @State private var isStartingSiblingChat = false
    @State private var isForkingThread = false
    @State private var checkedOutElsewhereAlert: CheckedOutElsewhereAlert?
    @State private var isVoiceRecording = false
    @State private var isVoicePreflighting = false
    @State private var voicePreflightGeneration = 0
    @State private var isVoiceTranscribing = false
    @State private var voiceRecoveryReason: CodexVoiceFailureReason?
    @State private var isShowingVoiceSetupSheet = false
    @StateObject private var voiceTranscriptionManager = GPTVoiceTranscriptionManager()

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        let resolvedThread = currentResolvedThread
        let timelineState = codex.timelineState(for: thread.id)
        let renderSnapshot = timelineState.renderSnapshot
        let activeTurnID = renderSnapshot.activeTurnID
        let gitWorkingDirectory = resolvedThread.gitWorkingDirectory
        let isThreadRunning = renderSnapshot.isThreadRunning
        let isEmptyThread = renderSnapshot.messages.isEmpty
        let showsGitControls = codex.isConnected && gitWorkingDirectory != nil
        let isWorktreeProject = resolvedThread.isManagedWorktreeProject
        let isComposerAutocompletePresented = viewModel.isFileAutocompleteVisible
            || viewModel.isSkillAutocompleteVisible
            || viewModel.slashCommandPanelState != .hidden
        let isWorktreeHandoffAvailable = isWorktreeHandoffAvailable(
            isThreadRunning: isThreadRunning,
            gitWorkingDirectory: gitWorkingDirectory
        )
        let canHandOffToWorktree = canHandOffToWorktree(
            isThreadRunning: isThreadRunning,
            gitWorkingDirectory: gitWorkingDirectory,
            isWorktreeProject: isWorktreeProject
        )

        return TurnConversationContainerView(
                threadID: thread.id,
                messages: renderSnapshot.messages,
                timelineChangeToken: renderSnapshot.timelineChangeToken,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                latestTurnTerminalState: renderSnapshot.latestTurnTerminalState,
                stoppedTurnIDs: renderSnapshot.stoppedTurnIDs,
                assistantRevertStatesByMessageID: renderSnapshot.assistantRevertStatesByMessageID,
                errorMessage: codex.lastErrorMessage,
                composerRecoveryAccessory: composerRecoveryAccessory,
                shouldAnchorToAssistantResponse: shouldAnchorToAssistantResponseBinding,
                isScrolledToBottom: isScrolledToBottomBinding,
                isComposerFocused: isInputFocused,
                isComposerAutocompletePresented: isComposerAutocompletePresented,
                emptyState: AnyView(emptyState),
                composer: AnyView(composerWithSubagentAccessory(
                    currentThread: resolvedThread,
                    activeTurnID: activeTurnID,
                    isThreadRunning: isThreadRunning,
                    isEmptyThread: isEmptyThread,
                    isWorktreeProject: isWorktreeProject,
                    showsGitControls: showsGitControls,
                    gitWorkingDirectory: gitWorkingDirectory
                )),
                repositoryLoadingToastOverlay: AnyView(EmptyView()),
                usageToastOverlay: AnyView(EmptyView()),
                isRepositoryLoadingToastVisible: false,
                onRetryUserMessage: { messageText in
                    viewModel.input = messageText
                    isInputFocused = true
                },
                onTapAssistantRevert: { message in
                    startAssistantRevertPreview(message: message, gitWorkingDirectory: gitWorkingDirectory)
                },
                onTapSubagent: { subagent in
                    openThread(subagent.threadId)
                },
                onTapOutsideComposer: {
                    guard isInputFocused else { return }
                    isInputFocused = false
                    viewModel.clearComposerAutocomplete()
                }
            )
        .environment(\.inlineCommitAndPushAction, showsGitControls ? {
            viewModel.inlineCommitAndPush(
                codex: codex,
                workingDirectory: gitWorkingDirectory,
                threadID: thread.id
            )
        } as (() -> Void)? : nil)
        .navigationTitle(resolvedThread.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            TurnToolbarContent(
                displayTitle: resolvedThread.displayTitle,
                navigationContext: threadNavigationContext(for: resolvedThread),
                showsThreadActions: codex.isConnected,
                isHandingOffToMac: isHandingOffToMac,
                isStartingNewChat: isStartingSiblingChat,
                canHandOffToWorktree: canHandOffToWorktree,
                isCreatingGitWorktree: viewModel.isCreatingGitWorktree,
                repoDiffTotals: viewModel.gitRepoSync?.repoDiffTotals,
                isLoadingRepoDiff: isLoadingRepositoryDiff,
                showsGitActions: showsGitControls,
                isGitActionEnabled: canRunGitAction(
                    isThreadRunning: isThreadRunning,
                    gitWorkingDirectory: gitWorkingDirectory
                ),
                disabledGitActions: viewModel.canCreatePullRequest ? [] : [.createPR],
                isRunningGitAction: viewModel.isRunningGitAction,
                showsDiscardRuntimeChangesAndSync: viewModel.shouldShowDiscardRuntimeChangesAndSync,
                gitSyncState: viewModel.gitSyncState,
                onTapMacHandoff: codex.isConnected ? {
                    isShowingMacHandoffConfirm = true
                } : nil,
                onTapWorktreeHandoff: showsGitControls ? {
                    isShowingWorktreeHandoff = true
                } : nil,
                onTapNewChat: codex.isConnected && !isWorktreeProject ? {
                    startSiblingChat()
                } : nil,
                onTapRepoDiff: showsGitControls ? {
                    presentRepositoryDiff(workingDirectory: gitWorkingDirectory)
                } : nil,
                onGitAction: { action in
                    handleGitActionSelection(
                        action,
                        isThreadRunning: isThreadRunning,
                        gitWorkingDirectory: gitWorkingDirectory
                    )
                },
                isShowingPathSheet: $isShowingThreadPathSheet
            )
        }
        .overlay {
            if isShowingWorktreeHandoff {
                TurnWorktreeHandoffOverlay(
                    mode: .handoff,
                    preferredBaseBranch: preferredWorktreeBaseBranch,
                    isHandoffAvailable: isWorktreeHandoffAvailable,
                    isSubmitting: viewModel.isCreatingGitWorktree,
                    onClose: { isShowingWorktreeHandoff = false },
                    onSubmit: { branchName, baseBranch in
                        submitWorktreeHandoff(
                            branchName: branchName,
                            baseBranch: baseBranch,
                            gitWorkingDirectory: gitWorkingDirectory,
                            activeTurnID: activeTurnID
                        )
                    }
                )
                .transition(.opacity)
            }

            if isShowingForkWorktree {
                TurnWorktreeHandoffOverlay(
                    mode: .fork,
                    preferredBaseBranch: preferredWorktreeBaseBranch,
                    isHandoffAvailable: isWorktreeHandoffAvailable,
                    isSubmitting: viewModel.isCreatingGitWorktree || isForkingThread,
                    onClose: { isShowingForkWorktree = false },
                    onSubmit: { branchName, baseBranch in
                        submitForkIntoNewWorktree(
                            branchName: branchName,
                            baseBranch: baseBranch,
                            gitWorkingDirectory: gitWorkingDirectory,
                            activeTurnID: activeTurnID
                        )
                    }
                )
                .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: isCameraPresentedBinding) {
            CameraImagePicker { data in
                viewModel.enqueueCapturedImageData(data, codex: codex)
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
        .turnViewLifecycle(
            taskID: thread.id,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning,
            isConnected: codex.isConnected,
            scenePhase: scenePhase,
            approvalRequestID: approvalForThread?.id,
            photoPickerItems: viewModel.photoPickerItems,
            onTask: {
                await prepareThreadIfReady(gitWorkingDirectory: gitWorkingDirectory)
            },
            onInitialAppear: {
                handleInitialAppear(activeTurnID: activeTurnID)
            },
            onPhotoPickerItemsChanged: { newItems in
                handlePhotoPickerItemsChanged(newItems)
            },
            onActiveTurnChanged: { newValue in
                if newValue != nil {
                    viewModel.clearComposerAutocomplete()
                }
            },
            onThreadRunningChanged: { wasRunning, isRunning in
                guard wasRunning, !isRunning else { return }
                viewModel.flushQueueIfPossible(codex: codex, threadID: thread.id)
                guard showsGitControls else { return }
                viewModel.refreshGitBranchTargets(
                    codex: codex,
                    workingDirectory: gitWorkingDirectory,
                    threadID: thread.id
                )
            },
            onConnectionChanged: { wasConnected, isConnected in
                if !isConnected {
                    cancelVoiceRecordingIfNeeded()
                    invalidatePendingVoicePreflight()
                    clearVoiceRecovery()
                    return
                }

                clearVoiceRecovery()
                guard !wasConnected, isConnected else { return }
                viewModel.flushQueueIfPossible(codex: codex, threadID: thread.id)
                guard showsGitControls else { return }
                viewModel.refreshGitBranchTargets(
                    codex: codex,
                    workingDirectory: gitWorkingDirectory,
                    threadID: thread.id
                )
            },
            onScenePhaseChanged: { phase in
                guard phase != .active else { return }
                cancelVoiceRecordingIfNeeded()
                invalidatePendingVoicePreflight()
            },
            onApprovalRequestIDChanged: {
                alertApprovalRequest = approvalForThread
            }
        )
        .onDisappear {
            cancelVoiceRecordingIfNeeded()
            invalidatePendingVoicePreflight()
            clearVoiceRecovery()
            viewModel.cancelTransientTasks()
            viewModel.clearComposerAutocomplete()
        }
        .onChange(of: isInputFocused) { _, isFocused in
            guard !isFocused else { return }
            viewModel.clearComposerAutocomplete()
        }
        .onChange(of: renderSnapshot.repoRefreshSignal) { _, newValue in
            guard showsGitControls, newValue != nil else { return }
            viewModel.scheduleGitStatusRefresh(
                codex: codex,
                workingDirectory: gitWorkingDirectory,
                threadID: thread.id
            )
        }
        .sheet(isPresented: $isShowingThreadPathSheet) {
            if let context = threadNavigationContext(for: resolvedThread) {
                TurnThreadPathSheet(
                    context: context,
                    threadTitle: resolvedThread.displayTitle,
                    onRenameThread: { newName in
                        codex.renameThread(thread.id, name: newName)
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingStatusSheet) {
            TurnStatusSheet(
                contextWindowUsage: codex.contextWindowUsageByThread[thread.id],
                rateLimitBuckets: codex.rateLimitBuckets,
                isLoadingRateLimits: codex.isLoadingRateLimits,
                rateLimitsErrorMessage: codex.rateLimitsErrorMessage
            )
        }
        .sheet(isPresented: $isShowingVoiceSetupSheet) {
            GPTVoiceSetupSheet()
        }
        .sheet(item: $repositoryDiffPresentation) { presentation in
            TurnDiffSheet(
                title: presentation.title,
                entries: presentation.entries,
                bodyText: presentation.bodyText,
                messageID: presentation.messageID
            )
        }
        .sheet(isPresented: assistantRevertSheetPresentedBinding) {
            if let assistantRevertSheetState {
                AssistantRevertSheet(
                    state: assistantRevertSheetState,
                    onClose: { self.assistantRevertSheetState = nil },
                    onConfirm: {
                        confirmAssistantRevert(gitWorkingDirectory: gitWorkingDirectory)
                    }
                )
            }
        }
        .turnViewAlerts(
            alertApprovalRequest: $alertApprovalRequest,
            isShowingNothingToCommitAlert: isShowingNothingToCommitAlertBinding,
            gitSyncAlert: gitSyncAlertBinding,
            isShowingMacHandoffConfirm: $isShowingMacHandoffConfirm,
            macHandoffErrorMessage: $macHandoffErrorMessage,
            onDeclineApproval: {
                viewModel.decline(codex: codex)
            },
            onApproveApproval: {
                viewModel.approve(codex: codex)
            },
            onConfirmGitSyncAction: { alertAction in
                viewModel.confirmGitSyncAlertAction(
                    alertAction,
                    codex: codex,
                    workingDirectory: gitWorkingDirectory,
                    threadID: thread.id,
                    activeTurnID: codex.activeTurnID(for: thread.id)
                )
            },
            onDismissGitSyncAlert: {
                viewModel.dismissGitSyncAlert()
            },
            onConfirmMacHandoff: {
                continueOnMac()
            }
        )
        .alert(
            checkedOutElsewhereAlert?.title ?? "Branch already open elsewhere",
            isPresented: checkedOutElsewhereAlertIsPresented,
            presenting: checkedOutElsewhereAlert
        ) { alert in
            Button("Close", role: .cancel) {
                checkedOutElsewhereAlert = nil
            }

            if let threadID = alert.threadID {
                Button("Open Chat") {
                    checkedOutElsewhereAlert = nil
                    openThread(threadID)
                }
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    // Reuses the shared recovery-card slot for both transport reconnects and voice-specific guidance.
    private var composerRecoveryAccessory: AnyView? {
        if let voiceRecoveryPresentation {
            return AnyView(
                ConnectionRecoveryCard(snapshot: voiceRecoveryPresentation.snapshot) {
                    handleVoiceRecoveryAction(voiceRecoveryPresentation.action)
                }
            )
        }

        guard let snapshot = connectionRecoverySnapshot else {
            return nil
        }

        return AnyView(
            ConnectionRecoveryCard(snapshot: snapshot) {
                reconnectAction?()
            }
        )
    }

    private var voiceRecoveryPresentation: VoiceRecoveryPresentation? {
        guard let voiceRecoveryReason else {
            return nil
        }

        guard let resolvedReason = codex.resolveVoiceRecoveryReason(voiceRecoveryReason) else {
            return nil
        }

        return buildVoiceRecoveryPresentation(for: resolvedReason)
    }

    private var connectionRecoverySnapshot: ConnectionRecoverySnapshot? {
        guard codex.hasReconnectCandidate,
              !codex.isConnected,
              codex.secureConnectionState != .rePairRequired else {
            return nil
        }

        if codex.isConnecting || codex.shouldAutoReconnectOnForeground || isRetryingConnectionRecovery {
            return ConnectionRecoverySnapshot(
                summary: "Trying to reconnect to your Mac.",
                status: .reconnecting,
                trailingStyle: .progress
            )
        }

        let trimmedError = codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = {
            guard let trimmedError, !trimmedError.isEmpty else {
                return "Reconnect to your Mac to keep this chat in sync."
            }
            return trimmedError
        }()
        return ConnectionRecoverySnapshot(
            summary: summary,
            status: .interrupted,
            trailingStyle: .action("Reconnect")
        )
    }

    private var isRetryingConnectionRecovery: Bool {
        if case .retrying = codex.connectionRecoveryState {
            return true
        }
        return false
    }

    // MARK: - Bindings

    private var shouldAnchorToAssistantResponseBinding: Binding<Bool> {
        Binding(
            get: { viewModel.shouldAnchorToAssistantResponse },
            set: { viewModel.shouldAnchorToAssistantResponse = $0 }
        )
    }

    private var isScrolledToBottomBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isScrolledToBottom },
            set: { viewModel.isScrolledToBottom = $0 }
        )
    }

    // Fetches the repo-wide local patch on demand so the toolbar pill opens the same diff UI as turn changes.
    private func presentRepositoryDiff(workingDirectory: String?) {
        guard !isLoadingRepositoryDiff else { return }
        isLoadingRepositoryDiff = true

        Task { @MainActor in
            defer { isLoadingRepositoryDiff = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)

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

    // Opens the local session summary and refreshes both thread context usage and rate limits.
    private func presentStatusSheet() {
        isShowingStatusSheet = true

        Task {
            await codex.refreshUsageStatus(threadId: thread.id)
        }
    }

    private func continueOnMac() {
        guard !isHandingOffToMac else { return }
        isHandingOffToMac = true

        Task { @MainActor in
            defer { isHandingOffToMac = false }

            do {
                let handoffService = DesktopHandoffService(codex: codex)
                try await handoffService.continueOnMac(threadId: thread.id)
            } catch {
                macHandoffErrorMessage = error.localizedDescription
            }
        }
    }

    // Starts a sibling chat scoped to the same cwd as the current thread.
    private func startSiblingChat() {
        Task { @MainActor in
            guard !isStartingSiblingChat else { return }
            guard !currentResolvedThread.isManagedWorktreeProject else { return }
            isStartingSiblingChat = true
            defer { isStartingSiblingChat = false }

            do {
                _ = try await codex.startThreadIfReady(preferredProjectPath: resolvedProjectPathForFollowUpThread())
            } catch {
                if codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    codex.lastErrorMessage = error.localizedDescription
                }
            }
        }
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

    private var checkedOutElsewhereAlertIsPresented: Binding<Bool> {
        Binding(
            get: { checkedOutElsewhereAlert != nil },
            set: { isPresented in
                if !isPresented {
                    checkedOutElsewhereAlert = nil
                }
            }
        )
    }

    private var assistantRevertSheetPresentedBinding: Binding<Bool> {
        Binding(
            get: { assistantRevertSheetState != nil },
            set: { isPresented in
                if !isPresented {
                    assistantRevertSheetState = nil
                }
            }
        )
    }

    private func handleSend() {
        isInputFocused = false
        viewModel.clearComposerAutocomplete()
        viewModel.sendTurn(codex: codex, threadID: thread.id)
    }

    private func handleGitActionSelection(
        _ action: TurnGitActionKind,
        isThreadRunning: Bool,
        gitWorkingDirectory: String?
    ) {
        guard canRunGitAction(isThreadRunning: isThreadRunning, gitWorkingDirectory: gitWorkingDirectory) else { return }
        viewModel.triggerGitAction(
            action,
            codex: codex,
            workingDirectory: gitWorkingDirectory,
            threadID: thread.id,
            activeTurnID: codex.activeTurnID(for: thread.id)
        )
    }

    private func canRunGitAction(isThreadRunning: Bool, gitWorkingDirectory: String?) -> Bool {
        viewModel.canRunGitAction(
            isConnected: codex.isConnected,
            isThreadRunning: isThreadRunning,
            hasGitWorkingDirectory: gitWorkingDirectory != nil
        )
    }

    // Re-resolves the active thread so handoff/reconnect UI always uses the freshest cwd + title.
    private var currentResolvedThread: CodexThread {
        codex.thread(for: thread.id) ?? thread
    }

    // Reuses the same running-thread gate as Stop/Git actions so worktree handoff never races a live run.
    private func isWorktreeHandoffAvailable(
        isThreadRunning: Bool,
        gitWorkingDirectory: String?
    ) -> Bool {
        canRunGitAction(
            isThreadRunning: isThreadRunning,
            gitWorkingDirectory: gitWorkingDirectory
        )
    }

    // Centralizes the toolbar/composer availability rule so both entry points stay aligned.
    private func canHandOffToWorktree(
        isThreadRunning: Bool,
        gitWorkingDirectory: String?,
        isWorktreeProject: Bool
    ) -> Bool {
        isWorktreeHandoffAvailable(
            isThreadRunning: isThreadRunning,
            gitWorkingDirectory: gitWorkingDirectory
        ) && !isWorktreeProject && !viewModel.isCreatingGitWorktree
    }

    private func handleInitialAppear(activeTurnID: String?) {
        alertApprovalRequest = approvalForThread
        if let pendingComposerAction = codex.consumePendingComposerAction(for: thread.id) {
            viewModel.applyPendingComposerAction(pendingComposerAction)
            isInputFocused = true
        }
    }

    private func handlePhotoPickerItemsChanged(_ newItems: [PhotosPickerItem]) {
        viewModel.enqueuePhotoPickerItems(newItems, codex: codex)
        viewModel.photoPickerItems = []
    }

    private func startAssistantRevertPreview(message: CodexMessage, gitWorkingDirectory: String?) {
        guard let gitWorkingDirectory,
              let changeSet = codex.readyChangeSet(forAssistantMessage: message),
              let presentation = codex.assistantRevertPresentation(
                for: message,
                workingDirectory: gitWorkingDirectory
              ),
              presentation.isEnabled else {
            return
        }

        assistantRevertSheetState = AssistantRevertSheetState(
            changeSet: changeSet,
            presentation: presentation,
            preview: nil,
            isLoadingPreview: true,
            isApplying: false,
            errorMessage: nil
        )

        Task { @MainActor in
            do {
                let preview = try await codex.previewRevert(
                    changeSet: changeSet,
                    workingDirectory: gitWorkingDirectory
                )
                guard assistantRevertSheetState?.id == changeSet.id else { return }
                assistantRevertSheetState?.preview = preview
                assistantRevertSheetState?.isLoadingPreview = false
            } catch {
                guard assistantRevertSheetState?.id == changeSet.id else { return }
                assistantRevertSheetState?.isLoadingPreview = false
                assistantRevertSheetState?.errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmAssistantRevert(gitWorkingDirectory: String?) {
        guard let gitWorkingDirectory,
              var assistantRevertSheetState,
              let preview = assistantRevertSheetState.preview,
              preview.canRevert else {
            return
        }

        assistantRevertSheetState.isApplying = true
        assistantRevertSheetState.errorMessage = nil
        self.assistantRevertSheetState = assistantRevertSheetState

        let changeSet = assistantRevertSheetState.changeSet
        Task { @MainActor in
            do {
                let applyResult = try await codex.applyRevert(
                    changeSet: changeSet,
                    workingDirectory: gitWorkingDirectory
                )

                guard self.assistantRevertSheetState?.id == changeSet.id else { return }
                if applyResult.success {
                    if let status = applyResult.status {
                        viewModel.gitRepoSync = status
                    } else {
                        viewModel.scheduleGitStatusRefresh(
                            codex: codex,
                            workingDirectory: gitWorkingDirectory,
                            threadID: thread.id
                        )
                    }
                    self.assistantRevertSheetState = nil
                    return
                }

                self.assistantRevertSheetState?.isApplying = false
                let affectedFiles = self.assistantRevertSheetState?.preview?.affectedFiles
                    ?? changeSet.fileChanges.map(\.path)
                self.assistantRevertSheetState?.preview = RevertPreviewResult(
                    canRevert: false,
                    affectedFiles: affectedFiles,
                    conflicts: applyResult.conflicts,
                    unsupportedReasons: applyResult.unsupportedReasons,
                    stagedFiles: applyResult.stagedFiles
                )
                self.assistantRevertSheetState?.errorMessage = applyResult.conflicts.first?.message
                    ?? applyResult.unsupportedReasons.first
            } catch {
                guard self.assistantRevertSheetState?.id == changeSet.id else { return }
                self.assistantRevertSheetState?.isApplying = false
                self.assistantRevertSheetState?.errorMessage = error.localizedDescription
            }
        }
    }

    private func prepareThreadIfReady(gitWorkingDirectory: String?) async {
        let didPrepare = await codex.prepareThreadForDisplay(threadId: thread.id)
        guard didPrepare, !Task.isCancelled, codex.activeThreadId == thread.id else { return }
        await codex.refreshContextWindowUsage(threadId: thread.id)
        guard !Task.isCancelled, codex.activeThreadId == thread.id else { return }
        viewModel.flushQueueIfPossible(codex: codex, threadID: thread.id)
        guard !Task.isCancelled, codex.activeThreadId == thread.id else { return }
        guard gitWorkingDirectory != nil else { return }
        viewModel.refreshGitBranchTargets(
            codex: codex,
            workingDirectory: gitWorkingDirectory,
            threadID: thread.id
        )
    }

    // Shares the same default base branch between the toolbar overlay and the empty-thread Local menu.
    private var preferredWorktreeBaseBranch: String {
        let currentBranch = viewModel.currentGitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentBranch.isEmpty {
            return currentBranch
        }

        let selectedBaseBranch = viewModel.selectedGitBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedBaseBranch.isEmpty {
            return selectedBaseBranch
        }
        return viewModel.gitDefaultBranch
    }

    // Creates the worktree first, then rebinds this same chat to the returned project path.
    private func submitWorktreeHandoff(
        branchName: String,
        baseBranch: String,
        gitWorkingDirectory: String?,
        activeTurnID: String?
    ) {
        viewModel.requestCreateGitWorktree(
            named: branchName,
            fromBaseBranch: baseBranch,
            changeTransfer: .move,
            codex: codex,
            workingDirectory: gitWorkingDirectory,
            threadID: thread.id,
            activeTurnID: activeTurnID,
            onOpenWorktree: { result in
                isShowingWorktreeHandoff = false
                TurnViewWorktreeActions.handoffCurrentThreadToWorktree(
                    projectPath: result.worktreePath,
                    branch: result.branch,
                    codex: codex,
                    viewModel: viewModel,
                    threadID: thread.id
                )
            }
        )
    }

    // Forks the current conversation into the Local checkout when possible, or keeps it on the current cwd.
    private func startLocalFork() {
        Task { @MainActor in
            guard !isForkingThread else { return }
            let sourceThread = currentResolvedThread
            guard let targetProjectPath = TurnThreadForkCoordinator.localForkProjectPath(
                for: sourceThread,
                localCheckoutPath: viewModel.gitLocalCheckoutPath
            ) else {
                viewModel.gitSyncAlert = TurnThreadForkCoordinator.localForkUnavailableAlert(for: sourceThread)
                return
            }
            isForkingThread = true
            defer { isForkingThread = false }

            do {
                let forkedThread = try await codex.forkThreadIfReady(
                    from: thread.id,
                    target: .projectPath(targetProjectPath)
                )
                openThread(forkedThread.id)
            } catch {
                if codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    codex.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    // Creates a fresh worktree first, then forks the conversation into that checkout as a new thread.
    private func submitForkIntoNewWorktree(
        branchName: String,
        baseBranch: String,
        gitWorkingDirectory: String?,
        activeTurnID: String?
    ) {
        viewModel.requestCreateGitWorktree(
            named: branchName,
            fromBaseBranch: baseBranch,
            changeTransfer: .copy,
            codex: codex,
            workingDirectory: gitWorkingDirectory,
            threadID: thread.id,
            activeTurnID: activeTurnID,
            onOpenWorktree: { result in
                guard !result.alreadyExisted else {
                    viewModel.gitSyncAlert = TurnGitSyncAlert(
                        title: "Pick a Different Branch Name",
                        message: "A managed worktree for '\(result.branch)' already exists. Choose a different branch name to create a fresh forked workspace.",
                        action: .dismissOnly
                    )
                    return
                }

                guard let normalizedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(result.worktreePath) else {
                    viewModel.gitSyncAlert = TurnGitSyncAlert(
                        title: "Worktree Fork Failed",
                        message: "Could not resolve the new worktree path for '\(result.branch)'.",
                        action: .dismissOnly
                    )
                    return
                }

                isForkingThread = true
                Task { @MainActor in
                    defer { isForkingThread = false }

                    do {
                        let forkedThread = try await TurnThreadForkCoordinator.forkThreadIntoPreparedWorktree(
                            codex: codex,
                            sourceThreadId: thread.id,
                            projectPath: normalizedProjectPath
                        )
                        isShowingForkWorktree = false
                        openThread(forkedThread.id)
                    } catch {
                        let cleanupResult = await TurnThreadForkCoordinator.cleanupResultForFailedWorktreeFork(
                            result,
                            sourceWorkingDirectory: gitWorkingDirectory,
                            error: error,
                            codex: codex,
                            viewModel: viewModel,
                            threadID: thread.id
                        )
                        viewModel.gitSyncAlert = TurnGitSyncAlert(
                            title: "Worktree Fork Failed",
                            message: TurnThreadForkCoordinator.failedWorktreeForkMessage(
                                for: error,
                                branch: result.branch,
                                cleanupResult: cleanupResult
                            ),
                            action: .dismissOnly
                        )
                    }
                }
            }
        )
    }

    // Re-resolves the thread at action time so follow-up chats inherit the freshest cwd after sync/reconnect.
    private func resolvedProjectPathForFollowUpThread() -> String? {
        let currentThread = codex.thread(for: thread.id) ?? thread
        return currentThread.normalizedProjectPath
    }

    // Creates a fresh thread in the same project and opens it straight into the review flow.
    private func startCodeReviewThread(target: TurnComposerReviewTarget) {
        Task { @MainActor in
            do {
                _ = try await codex.startThreadIfReady(
                    preferredProjectPath: resolvedProjectPathForFollowUpThread(),
                    pendingComposerAction: .codeReview(target: pendingCodeReviewTarget(for: target))
                )
                viewModel.clearComposerReviewSelection()
            } catch {
                if codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    codex.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func pendingCodeReviewTarget(
        for target: TurnComposerReviewTarget
    ) -> CodexPendingCodeReviewTarget {
        switch target {
        case .uncommittedChanges:
            return .uncommittedChanges
        case .baseBranch:
            return .baseBranch
        }
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

    // MARK: - Derived UI state

    private var orderedModelOptions: [CodexModelOption] {
        TurnComposerMetaMapper.orderedModels(from: codex.availableModels)
    }

    private var reasoningDisplayOptions: [TurnComposerReasoningDisplayOption] {
        TurnComposerMetaMapper.reasoningDisplayOptions(
            from: codex.supportedReasoningEffortsForSelectedModel().map(\.reasoningEffort)
        )
    }

    private var selectedModelTitle: String {
        guard let selectedModel = codex.selectedModelOption() else {
            return "Select model"
        }

        return TurnComposerMetaMapper.modelTitle(for: selectedModel)
    }

    private var approvalForThread: CodexApprovalRequest? {
        guard let request = codex.pendingApproval else {
            return nil
        }

        guard let requestThreadID = request.threadId else {
            return request
        }

        return requestThreadID == thread.id ? request : nil
    }

    private var parentThread: CodexThread? {
        guard let parentThreadId = thread.parentThreadId else {
            return nil
        }

        return codex.thread(for: parentThreadId)
    }

    private func threadNavigationContext(for thread: CodexThread) -> TurnThreadNavigationContext? {
        guard let path = thread.normalizedProjectPath ?? thread.cwd,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let fullPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = (fullPath as NSString).lastPathComponent
        return TurnThreadNavigationContext(
            folderName: folderName.isEmpty ? fullPath : folderName,
            subtitle: fullPath,
            fullPath: fullPath
        )
    }

    @ViewBuilder
    private func composerWithSubagentAccessory(
        currentThread: CodexThread,
        activeTurnID: String?,
        isThreadRunning: Bool,
        isEmptyThread: Bool,
        isWorktreeProject: Bool,
        showsGitControls: Bool,
        gitWorkingDirectory: String?
    ) -> some View {
        VStack(spacing: 8) {
            if let parentThread = parentThread {
                SubagentParentAccessoryCard(
                    parentTitle: parentThread.displayTitle,
                    agentLabel: codex.resolvedSubagentDisplayLabel(threadId: thread.id, agentId: thread.agentId)
                        ?? "Subagent",
                    onTap: { openThread(parentThread.id) }
                )
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isForkingThread {
                forkLoadingNotice
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            TurnComposerHostView(
                viewModel: viewModel,
                codex: codex,
                thread: currentThread,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                isEmptyThread: isEmptyThread,
                isWorktreeProject: isWorktreeProject,
                canForkLocally: TurnThreadForkCoordinator.localForkProjectPath(
                    for: currentThread,
                    localCheckoutPath: viewModel.gitLocalCheckoutPath
                ) != nil,
                isInputFocused: $isInputFocused,
                orderedModelOptions: orderedModelOptions,
                selectedModelTitle: selectedModelTitle,
                reasoningDisplayOptions: reasoningDisplayOptions,
                showsGitControls: showsGitControls,
                isGitBranchSelectorEnabled: canRunGitAction(
                    isThreadRunning: isThreadRunning,
                    gitWorkingDirectory: gitWorkingDirectory
                ),
                onSelectGitBranch: { branch in
                    guard canRunGitAction(
                        isThreadRunning: isThreadRunning,
                        gitWorkingDirectory: gitWorkingDirectory
                    ) else { return }

                    if let worktreePath = viewModel.worktreePathForCheckedOutElsewhereBranch(branch) {
                        if let normalizedWorktreePath = CodexThreadStartProjectBinding.normalizedProjectPath(worktreePath) {
                            let resolvedWorktreePath = TurnWorktreeRouting.canonicalProjectPath(normalizedWorktreePath)
                                ?? normalizedWorktreePath
                            if TurnWorktreeRouting.comparableProjectPath(currentThread.normalizedProjectPath) == resolvedWorktreePath {
                                return
                            }
                        }

                        let existingThread = TurnViewWorktreeActions.liveThreadForCheckedOutElsewhereBranch(
                            projectPath: worktreePath,
                            codex: codex,
                            currentThread: currentThread
                        )
                        checkedOutElsewhereAlert = CheckedOutElsewhereAlert(
                            branch: branch,
                            threadID: existingThread?.id
                        )
                        return
                    }

                    viewModel.requestSwitchGitBranch(
                        to: branch,
                        codex: codex,
                        workingDirectory: gitWorkingDirectory,
                        threadID: thread.id,
                        activeTurnID: activeTurnID
                    )
                },
                onCreateGitBranch: { branchName in
                    guard canRunGitAction(
                        isThreadRunning: isThreadRunning,
                        gitWorkingDirectory: gitWorkingDirectory
                    ) else { return }

                    viewModel.requestCreateGitBranch(
                        named: branchName,
                        codex: codex,
                        workingDirectory: gitWorkingDirectory,
                        threadID: thread.id,
                        activeTurnID: activeTurnID
                    )
                },
                onRefreshGitBranches: {
                    guard showsGitControls else { return }
                    viewModel.refreshGitBranchTargets(
                        codex: codex,
                        workingDirectory: gitWorkingDirectory,
                        threadID: thread.id
                    )
                },
                onStartCodeReviewThread: startCodeReviewThread,
                onStartForkThreadLocally: startLocalFork,
                onOpenForkWorktree: {
                    isShowingForkWorktree = true
                },
                onOpenWorktreeHandoff: {
                    isShowingWorktreeHandoff = true
                },
                onShowStatus: presentStatusSheet,
                voiceButtonPresentation: voiceButtonPresentation,
                isVoiceRecording: isVoiceRecording,
                voiceAudioLevels: voiceTranscriptionManager.audioLevels,
                voiceRecordingDuration: voiceTranscriptionManager.recordingDuration,
                onTapVoice: handleVoiceButtonTap,
                onCancelVoiceRecording: cancelVoiceRecordingIfNeeded,
                onSend: handleSend
            )
        }
    }

    // Mirrors the mic CTA state so the composer can swap between ready, record, and stop.
    private var voiceButtonPresentation: TurnComposerVoiceButtonPresentation {
        if isVoiceTranscribing {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "waveform",
                foregroundColor: Color(.secondaryLabel),
                backgroundColor: Color(.systemGray5),
                accessibilityLabel: "Transcribing voice note",
                isDisabled: true,
                showsProgress: true,
                hasCircleBackground: true
            )
        }

        if isVoicePreflighting {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "hourglass",
                foregroundColor: Color(.secondaryLabel),
                backgroundColor: Color(.systemGray5),
                accessibilityLabel: "Preparing microphone",
                isDisabled: true,
                showsProgress: true,
                hasCircleBackground: true
            )
        }

        if isVoiceRecording {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "stop.fill",
                foregroundColor: Color(.systemBackground),
                backgroundColor: Color(.systemRed),
                accessibilityLabel: "Stop voice recording",
                isDisabled: false,
                showsProgress: false,
                hasCircleBackground: true
            )
        }

        return TurnComposerVoiceButtonPresentation(
            systemImageName: "mic",
            foregroundColor: Color(.secondaryLabel),
            backgroundColor: .clear,
            accessibilityLabel: "Start voice transcription",
            isDisabled: !codex.isConnected,
            showsProgress: false,
            hasCircleBackground: false
        )
    }

    // Switches the mic button between login, recording, and transcription states.
    private func handleVoiceButtonTap() {
        if isVoiceTranscribing {
            return
        }

        if isVoiceRecording {
            Task { @MainActor in
                await stopVoiceTranscription()
            }
            return
        }

        Task { @MainActor in
            await startVoiceRecordingIfReady()
        }
    }

    // Stops the recorder, transcribes through the bridge, and appends the final text into the draft.
    private func stopVoiceTranscription() async {
        isVoiceTranscribing = true
        defer { isVoiceTranscribing = false }

        do {
            guard let clip = try voiceTranscriptionManager.stopRecording() else {
                isVoiceRecording = false
                voiceTranscriptionManager.resetMeteringState()
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
            clearVoiceRecovery()
            viewModel.appendVoiceTranscript(transcript)
            // Keep voice flows keyboard-free; users can tap into the draft afterward if they want to edit.
            isInputFocused = false
        } catch {
            isVoiceRecording = false
            voiceTranscriptionManager.resetMeteringState()
            presentVoiceRecovery(for: error)
        }
    }

    // Starts microphone capture directly; auth is resolved when the user stops recording, matching Litter's flow.
    @MainActor
    private func startVoiceRecordingIfReady() async {
        guard !isVoicePreflighting else {
            return
        }

        guard codex.supportsBridgeVoiceAuth else {
            presentVoiceRecovery(for: .bridgeSessionUnsupported)
            return
        }

        guard codex.isConnected else {
            presentVoiceRecovery(for: .reconnectRequired)
            return
        }

        clearVoiceRecovery()
        codex.lastErrorMessage = nil
        // Dismiss any active text focus before recording so the keyboard does not
        // compete with the waveform UI or waste vertical space during capture.
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
            guard isVoicePreflightCurrent(preflightGeneration), codex.isConnected else {
                return
            }
            try await voiceTranscriptionManager.startRecording()
            guard isVoicePreflightCurrent(preflightGeneration), codex.isConnected else {
                voiceTranscriptionManager.cancelRecording()
                return
            }
            isVoiceRecording = true
            isInputFocused = false
        } catch {
            presentVoiceRecovery(for: error)
        }
    }

    // Clears any partial microphone capture when the screen leaves the active voice flow.
    private func cancelVoiceRecordingIfNeeded() {
        guard isVoiceRecording else {
            return
        }

        voiceTranscriptionManager.cancelRecording()
        isVoiceRecording = false
    }

    private func clearVoiceRecovery() {
        voiceRecoveryReason = nil
    }

    // Keeps voice failures out of the transcript by routing them into a dedicated recovery accessory.
    private func presentVoiceRecovery(for error: Error) {
        presentVoiceRecovery(for: codex.classifyVoiceFailure(error))
    }

    private func presentVoiceRecovery(for reason: CodexVoiceFailureReason) {
        voiceRecoveryReason = reason
        codex.lastErrorMessage = nil
    }

    private func buildVoiceRecoveryPresentation(for reason: CodexVoiceFailureReason) -> VoiceRecoveryPresentation {
        switch reason {
        case .reconnectRequired:
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: "Reconnect to your Mac to use voice mode.",
                    detail: "Keep the Remodex bridge running on your Mac, then try the microphone again.",
                    status: .interrupted,
                    trailingStyle: .action("Reconnect")
                ),
                action: .reconnect
            )
        case .bridgeSessionUnsupported:
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: "This bridge session does not support voice mode yet.",
                    detail: "Restart Remodex on your Mac, then reconnect this iPhone. If it still happens, update Remodex on your Mac and pair again.",
                    status: .actionRequired,
                    trailingStyle: .action("Reconnect")
                ),
                action: .reconnect
            )
        case .macLoginRequired:
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: "Sign in to ChatGPT on your Mac to use voice mode.",
                    detail: "Open ChatGPT on the paired Mac, sign in there, then come back here and try again.",
                    status: .actionRequired,
                    trailingStyle: .action("How To Fix")
                ),
                action: .showSetupHelp
            )
        case .macReauthenticationRequired:
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: "ChatGPT voice needs a fresh sign-in on your Mac.",
                    detail: "Open ChatGPT on the paired Mac, sign in again there, then retry voice mode here.",
                    status: .actionRequired,
                    trailingStyle: .action("How To Fix")
                ),
                action: .showSetupHelp
            )
        case .voiceSyncInProgress:
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: "Voice mode is still syncing from your Mac.",
                    detail: "Keep the bridge connected for a moment, then try again.",
                    status: .syncing,
                    trailingStyle: .progress
                ),
                action: .none
            )
        case .chatGPTRequired:
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: "Voice mode needs a ChatGPT session on your Mac.",
                    detail: "API-key-only auth is not enough here. Sign in to ChatGPT on the paired Mac, then try again.",
                    status: .actionRequired,
                    trailingStyle: .action("How To Fix")
                ),
                action: .showSetupHelp
            )
        case .microphonePermissionRequired:
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: "Microphone access is off for Remodex.",
                    detail: "Open iPhone Settings, allow Microphone for Remodex, then try recording again.",
                    status: .actionRequired,
                    trailingStyle: .action("Open Settings")
                ),
                action: .openSystemSettings
            )
        case .microphoneUnavailable:
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: "No microphone input is available right now.",
                    detail: "Check that another app is not holding the microphone, then try again.",
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        case .recorderUnavailable:
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: "Remodex could not start the recorder.",
                    detail: "Close other audio-heavy apps, then try voice mode again.",
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        case .generic(let message):
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: message,
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        }
    }

    private func handleVoiceRecoveryAction(_ action: VoiceRecoveryAction) {
        switch action {
        case .reconnect:
            reconnectAction?()
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

    // Invalidates any in-flight async mic startup so it cannot reopen the recorder after leaving the screen.
    private func invalidatePendingVoicePreflight() {
        voicePreflightGeneration += 1
        isVoicePreflighting = false
    }

    private func isVoicePreflightCurrent(_ generation: Int) -> Bool {
        generation == voicePreflightGeneration
    }

    private var forkLoadingNotice: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("Creating fork...")
                    .font(AppFont.subheadline(weight: .semibold))
                Text("Opening the new chat")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func openThread(_ threadId: String) {
        codex.activeThreadId = threadId
        codex.markThreadAsViewed(threadId)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .adaptiveGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Hi! How can I help you?")
                .font(AppFont.title2(weight: .semibold))
            // Reinforces the secure transport upgrade right where a new chat starts.
            Text("Chats are End-to-end encrypted")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private enum VoiceRecoveryAction: Equatable {
    case reconnect
    case showSetupHelp
    case openSystemSettings
    case none
}

private struct VoiceRecoveryPresentation: Equatable {
    let snapshot: ConnectionRecoverySnapshot
    let action: VoiceRecoveryAction
}

private struct SubagentParentAccessoryCard: View {
    let parentTitle: String
    let agentLabel: String
    let onTap: () -> Void

    var body: some View {
        GlassAccessoryCard(onTap: onTap) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 22, height: 22)

                Image(systemName: "arrow.turn.up.left")
                    .font(AppFont.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        } header: {
            HStack(alignment: .center, spacing: 6) {
                Text("Subagent")
                    .font(AppFont.mono(.caption2))
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(Color(.separator).opacity(0.6))
                    .frame(width: 3, height: 3)

                SubagentLabelParser.styledText(for: agentLabel)
                    .font(AppFont.caption(weight: .regular))
                    .lineLimit(1)
            }
        } summary: {
            Text("Back to \(parentTitle)")
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        } trailing: {
            Image(systemName: "chevron.right")
                .font(AppFont.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct CheckedOutElsewhereAlert: Identifiable {
    let id = UUID()
    let branch: String
    let threadID: String?

    var title: String {
        "Branch already open elsewhere"
    }

    var message: String {
        if threadID != nil {
            return "'\(branch)' is already checked out in another worktree. Open that chat to continue there."
        }

        return "'\(branch)' is already checked out in another worktree. Open that chat from the sidebar to continue there."
    }
}

#Preview {
    NavigationStack {
        TurnView(thread: CodexThread(id: "thread_preview", title: "Preview"))
            .environment(CodexService())
    }
}
