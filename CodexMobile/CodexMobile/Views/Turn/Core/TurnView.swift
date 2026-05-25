// FILE: TurnView.swift
// Purpose: Orchestrates turn screen composition, wiring service state to timeline + composer components.
// Layer: View
// Exports: TurnView
// Depends on: CodexService, TurnViewModel, TurnConversationContainerView, TurnComposerHostView, TurnViewAlertModifier, TurnViewLifecycleModifier

import SwiftUI
import PhotosUI
import UIKit

// The handoff and fork dialogs are mutually exclusive overlays that share the
// same worktree creation surface.
private enum TurnWorktreeOverlayRoute: Equatable {
    case handoff
    case fork
}

struct TurnView: View {
    let thread: CodexThread
    let isWakingMacDisplayRecovery: Bool
    private let initialShouldAnchorToAssistantResponse: Bool
    private let onInitialAssistantAnchorConsumed: (() -> Void)?
    var onOpenTerminal: ((String?) -> Void)? = nil

    @Environment(CodexService.self) private var codex
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(\.openURL) private var openURL
    @Environment(\.reconnectAction) private var reconnectAction
    @Environment(\.wakeMacDisplayAction) private var wakeMacDisplayAction
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: TurnViewModel
    @State private var isInputFocused = false
    @State private var isShowingThreadPathSheet = false
    @State private var isShowingStatusSheet = false
    @State private var isLoadingRepositoryDiff = false
    @State private var repositoryDiffPresentation: TurnDiffPresentation?
    @State private var assistantRevertSheetState: AssistantRevertSheetState?
    @State private var alertApprovalRequest: CodexApprovalRequest?
    @State private var isApprovalAlertPresented = false
    @State private var isShowingMacHandoffConfirm = false
    @State private var worktreeOverlayRoute: TurnWorktreeOverlayRoute?
    @State private var macHandoffErrorMessage: String?
    @State private var isHandingOffToMac = false
    @State private var isStartingSiblingChat = false
    @State private var isForkingThread = false
    @State private var checkedOutElsewhereAlert: CheckedOutElsewhereAlert?
    @StateObject private var voiceInput = VoiceInputCoordinator()
    @State private var hasConsumedInitialAssistantAnchor = false
    @State private var workspaceFilePreviewRequest: WorkspaceFilePreviewRequest?

    init(
        thread: CodexThread,
        isWakingMacDisplayRecovery: Bool,
        initialShouldAnchorToAssistantResponse: Bool = false,
        onInitialAssistantAnchorConsumed: (() -> Void)? = nil,
        onOpenTerminal: ((String?) -> Void)? = nil
    ) {
        self.thread = thread
        self.isWakingMacDisplayRecovery = isWakingMacDisplayRecovery
        self.initialShouldAnchorToAssistantResponse = initialShouldAnchorToAssistantResponse
        self.onInitialAssistantAnchorConsumed = onInitialAssistantAnchorConsumed
        self.onOpenTerminal = onOpenTerminal
        _viewModel = State(initialValue: TurnViewModel(
            shouldAnchorToAssistantResponse: initialShouldAnchorToAssistantResponse
        ))
    }

    // ─── ENTRY POINT ─────────────────────────────────────────────
    var body: some View {
        let resolvedThread = currentResolvedThread
        let timelineState = codex.timelineState(for: thread.id)
        let renderSnapshot = timelineState.renderSnapshot
        let activeTurnID = renderSnapshot.activeTurnID
        let planSessionSource = codex.currentPlanSessionSource(for: thread.id)
        // Rootless Quick Chat paths are host-side storage only; the UI should stay branch/git-less.
        let isRootlessChat = SidebarThreadGrouping.isRootlessChatThread(resolvedThread)
        let gitWorkingDirectory = isRootlessChat ? nil : resolvedThread.gitWorkingDirectory
        let isThreadRunning = renderSnapshot.isThreadRunning
        let isEmptyThread = renderSnapshot.messages.isEmpty
        let threadDisplayPhase = codex.threadDisplayPhase(
            threadId: thread.id,
            hasVisibleMessages: !renderSnapshot.messages.isEmpty,
            isThreadRunning: isThreadRunning
        )
        // Keep the service-owned loading vs empty-state decision intact while
        // history hydration catches up for previously active conversations.
        let resolvedEmptyConversationState = resolvedEmptyState(for: threadDisplayPhase)
        let showsGitControls = codex.isConnected && gitWorkingDirectory != nil
        let isWorktreeProject = resolvedThread.isManagedWorktreeProject
        let isComposerAutocompletePresented = viewModel.isFileAutocompleteVisible
            || viewModel.isSkillAutocompleteVisible
            || viewModel.isPluginAutocompleteVisible
            || viewModel.slashCommandPanelState != .hidden
        let activeFileChangeStatus = FileChangeStatusSnapshot.activeTurnSnapshot(
            from: renderSnapshot.messages,
            activeTurnID: activeTurnID,
            isThreadRunning: isThreadRunning
        )
        let isWorktreeHandoffAvailable = isWorktreeHandoffAvailable(
            isThreadRunning: isThreadRunning,
            gitWorkingDirectory: gitWorkingDirectory
        )
        let canHandOffToWorktree = canHandOffToWorktree(
            isThreadRunning: isThreadRunning,
            gitWorkingDirectory: gitWorkingDirectory
        )
        let toolbarNavigationContext = isRootlessChat ? nil : threadNavigationContext(for: resolvedThread)
        let toolbarWorktreeHandoffTitle = isWorktreeProject ? "Hand off to Local" : "Hand off to Worktree"
        let isGitActionEnabled = viewModel.gitRepoSync != nil && canRunGitAction(
            isThreadRunning: isThreadRunning,
            gitWorkingDirectory: gitWorkingDirectory
        )
        let disabledGitActions: Set<TurnGitActionKind> = viewModel.disabledGitActions
        let onTapMacHandoff: (() -> Void)? = codex.isConnected && codex.supportsDesktopAppHandoff ? {
            isShowingMacHandoffConfirm = true
        } : nil
        let onTapWorktreeHandoff: (() -> Void)? = showsGitControls ? {
            handleWorktreeHandoffTap(currentThread: resolvedThread)
        } : nil
        let onTapNewChat: (() -> Void)? = codex.isConnected && !isWorktreeProject ? {
            startSiblingChat()
        } : nil
        let onTapRepoDiff: (() -> Void)? = showsGitControls ? {
            presentRepositoryDiff(workingDirectory: gitWorkingDirectory)
        } : nil

        return TurnConversationContainerView(
                threadID: thread.id,
                messages: renderSnapshot.messages,
                timelineChangeToken: renderSnapshot.timelineChangeToken,
                activeTurnID: activeTurnID,
                isThreadRunning: isThreadRunning,
                isSendInFlight: viewModel.isSending,
                latestTurnTerminalState: renderSnapshot.latestTurnTerminalState,
                completedTurnIDs: renderSnapshot.completedTurnIDs,
                stoppedTurnIDs: renderSnapshot.stoppedTurnIDs,
                assistantRevertStatesByMessageID: renderSnapshot.assistantRevertStatesByMessageID,
                planSessionSource: planSessionSource,
                allowsAssistantPlanFallbackRecovery: planSessionSource == .compatibilityFallback,
                threadMessagesForPlanMatching: renderSnapshot.planMatchingMessages,
                currentWorkingDirectory: gitWorkingDirectory,
                errorMessage: timelineFooterErrorMessage,
                composerRecoveryAccessory: composerRecoveryAccessory,
                onReportError: { errorMessage in
                    openURL(AppEnvironment.feedbackMailtoURL(
                        errorMessage: errorMessage,
                        threadId: thread.id,
                        isConnected: codex.isConnected,
                        cliVersion: codex.bridgeInstalledVersion
                    ))
                },
                onDismissError: {
                    codex.lastErrorMessage = nil
                },
                hasRemoteEarlierMessages: renderSnapshot.hasRemoteOlderHistory,
                hasLocallyProjectedEarlierMessages: renderSnapshot.hasLocallyProjectedOlderHistory,
                usesPaginatedHistory: renderSnapshot.usesPaginatedHistory,
                initialTurnsLoaded: renderSnapshot.initialTurnsLoaded,
                isLoadingRemoteEarlierMessages: renderSnapshot.isLoadingOlderHistory,
                olderHistoryLoadErrorMessage: renderSnapshot.olderHistoryLoadErrorMessage,
                shouldAnchorToAssistantResponse: shouldAnchorToAssistantResponseBinding,
                isComposerFocused: isInputFocused,
                isComposerAutocompletePresented: isComposerAutocompletePresented,
                emptyState: resolvedEmptyConversationState,
                composer: AnyView(composerWithSubagentAccessory(
                    currentThread: resolvedThread,
                    activeTurnID: activeTurnID,
                    isThreadRunning: isThreadRunning,
                    isEmptyThread: isEmptyThread,
                    isWorktreeProject: isWorktreeProject,
                    activeFileChangeStatus: activeFileChangeStatus,
                    showsGitControls: showsGitControls,
                    gitWorkingDirectory: gitWorkingDirectory
                )),
                structuredPromptReplacementComposer: { message in
                    AnyView(composerStructuredPromptReplacement(message: message))
                },
                repositoryLoadingToastOverlay: AnyView(EmptyView()),
                usageToastOverlay: AnyView(EmptyView()),
                isRepositoryLoadingToastVisible: false,
                onRetryUserMessage: { messageText in
                    viewModel.input = messageText
                    viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
                    isInputFocused = true
                },
                onTapAssistantRevert: { message in
                    startAssistantRevertPreview(message: message, gitWorkingDirectory: gitWorkingDirectory)
                },
                onTapSubagent: { subagent in
                    openThread(subagent.threadId)
                },
                onRevealEarlierMessages: { pageSize in
                    codex.noteThreadHistoryRevealRequested(threadId: thread.id, pageSize: pageSize)
                },
                onLoadRemoteEarlierMessages: {
                    Task { @MainActor in
                        await codex.loadOlderThreadHistoryPage(threadId: thread.id)
                    }
                },
                onRetryEarlierMessages: { completion in
                    Task { @MainActor in
                        defer { completion() }
                        _ = try? await codex.loadThreadHistoryIfNeeded(threadId: thread.id, forceRefresh: true)
                    }
                },
                onTapOutsideComposer: {
                    guard isInputFocused else { return }
                    isInputFocused = false
                    viewModel.clearComposerAutocomplete()
                }
            )
        .environment(\.openURL, OpenURLAction { url in
            guard let path = WorkspaceFileLinkResolver.localPath(from: url) else {
                return .systemAction
            }
            workspaceFilePreviewRequest = WorkspaceFilePreviewRequest(
                path: path,
                currentWorkingDirectory: gitWorkingDirectory
            )
            return .handled
        })
        .environment(\.inlineCommitAndPushAction, showsGitControls ? {
            viewModel.inlineCommitAndPush(
                codex: codex,
                workingDirectory: gitWorkingDirectory,
                threadID: thread.id
            )
        } as (() -> Void)? : nil)
        .environment(\.inlineCommitAndPushPhase, viewModel.inlineCommitAndPushPhase)
        .navigationTitle(resolvedThread.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            TurnToolbarContent(
                displayTitle: resolvedThread.displayTitle,
                navigationContext: toolbarNavigationContext,
                showsThreadActions: codex.isConnected,
                isHandingOffToMac: isHandingOffToMac,
                isStartingNewChat: isStartingSiblingChat,
                canHandOffToWorktree: canHandOffToWorktree,
                worktreeHandoffTitle: toolbarWorktreeHandoffTitle,
                isCreatingGitWorktree: viewModel.isCreatingGitWorktree,
                repoDiffTotals: viewModel.gitRepoSync?.repoDiffTotals,
                isLoadingRepoDiff: isLoadingRepositoryDiff,
                showsGitActions: showsGitControls,
                isGitActionEnabled: isGitActionEnabled,
                disabledGitActions: disabledGitActions,
                isRunningGitAction: viewModel.isRunningGitAction,
                gitActionLoadingTitle: viewModel.gitActionLoadingTitle,
                showsDiscardRuntimeChangesAndSync: viewModel.shouldShowDiscardRuntimeChangesAndSync,
                gitSyncState: viewModel.gitSyncState,
                onTapMacHandoff: onTapMacHandoff,
                onTapWorktreeHandoff: onTapWorktreeHandoff,
                onTapNewChat: onTapNewChat,
                onTapTerminal: onOpenTerminal == nil ? nil : {
                    onOpenTerminal?(gitWorkingDirectory)
                },
                onTapRepoDiff: onTapRepoDiff,
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
            if isStartingSiblingChat {
                NewChatOpeningOverlay()
                    .transition(.opacity)
            }

            if worktreeOverlayRoute == .handoff {
                TurnWorktreeHandoffOverlay(
                    mode: .handoff,
                    preferredBaseBranch: preferredWorktreeBaseBranch,
                    isHandoffAvailable: isWorktreeHandoffAvailable,
                    isSubmitting: viewModel.isCreatingGitWorktree,
                    onClose: { worktreeOverlayRoute = nil },
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

            if worktreeOverlayRoute == .fork {
                TurnWorktreeHandoffOverlay(
                    mode: .fork,
                    preferredBaseBranch: preferredWorktreeBaseBranch,
                    isHandoffAvailable: isWorktreeHandoffAvailable,
                    isSubmitting: viewModel.isCreatingGitWorktree || isForkingThread,
                    onClose: { worktreeOverlayRoute = nil },
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
        .overlay(alignment: .top) {
            TurnGitActionToastOverlay(
                success: viewModel.gitActionSuccess,
                progress: viewModel.gitActionProgress,
                onDismissSuccess: {
                    viewModel.dismissGitActionSuccess()
                }
            )
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: viewModel.gitActionLoadingTitle)
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: viewModel.gitActionSuccess?.id)
        .fullScreenCover(isPresented: isCameraPresentedBinding) {
            CameraImagePicker { data in
                viewModel.enqueueCapturedImageData(data, codex: codex, threadID: thread.id)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $workspaceFilePreviewRequest) { request in
            WorkspaceLinkedFilePreviewScreen(
                request: request,
                onDismiss: { workspaceFilePreviewRequest = nil }
            )
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
            approvalRequestChangeToken: approvalRequestChangeToken,
            photoPickerItems: viewModel.photoPickerItems,
            onTask: {
                await prepareThreadIfReady(gitWorkingDirectory: gitWorkingDirectory)
            },
            onInitialAppear: {
                handleInitialAppear(activeTurnID: activeTurnID)
            },
            onPhotoPickerItemsChanged: { newItems in
                // Defer the observable-model mutation out of the .onChange action
                // to avoid AttributeGraph cycles when the parent re-renders.
                DispatchQueue.main.async { [viewModel] in
                    viewModel.enqueuePhotoPickerItems(newItems, codex: codex, threadID: thread.id)
                    viewModel.photoPickerItems = []
                }
            },
            onActiveTurnChanged: { newValue in
                if newValue != nil {
                    // Defer the observable-model mutation out of the .onChange action
                    // to avoid AttributeGraph cycles when the parent re-renders.
                    DispatchQueue.main.async { [viewModel] in
                        viewModel.clearComposerAutocomplete()
                    }
                }
            },
            onThreadRunningChanged: { wasRunning, isRunning in
                guard wasRunning, !isRunning else { return }
                // Defer the observable-model mutation out of the .onChange action
                // to avoid AttributeGraph cycles when the parent re-renders.
                DispatchQueue.main.async { [viewModel] in
                    viewModel.flushQueueIfPossible(codex: codex, threadID: thread.id)
                    guard showsGitControls else { return }
                    viewModel.refreshGitBranchTargets(
                        codex: codex,
                        workingDirectory: gitWorkingDirectory,
                        threadID: thread.id
                    )
                }
            },
            onConnectionChanged: { wasConnected, isConnected in
                if !isConnected {
                    return
                }

                voiceInput.clearReconnectRecoveryIfNeeded()
                guard !wasConnected, isConnected else { return }
                // Defer the observable-model mutation out of the .onChange action
                // to avoid AttributeGraph cycles when the parent re-renders.
                DispatchQueue.main.async { [viewModel] in
                    viewModel.flushQueueIfPossible(codex: codex, threadID: thread.id)
                    guard showsGitControls else { return }
                    viewModel.refreshGitBranchTargets(
                        codex: codex,
                        workingDirectory: gitWorkingDirectory,
                        threadID: thread.id
                    )
                }
            },
            onScenePhaseChanged: { phase in
                guard phase != .active else { return }
                // Defer the observable-model mutation out of the .onChange action
                // to avoid AttributeGraph cycles when the parent re-renders.
                DispatchQueue.main.async { [viewModel] in
                    viewModel.saveLocalDraft(codex: codex, threadID: thread.id, persistToDisk: true)
                }
                handleVoiceScenePhaseChange(phase)
            },
            onApprovalRequestChanged: {
                syncApprovalAlertPresentation()
            }
        )
        .onDisappear {
            viewModel.saveLocalDraft(codex: codex, threadID: thread.id, persistToDisk: true)
            handleVoiceViewDisappear()
            viewModel.cancelTransientTasks()
            viewModel.clearComposerAutocomplete()
        }
        .onChange(of: isInputFocused) { _, isFocused in
            guard !isFocused else { return }
            // Defer the observable-model mutation out of the .onChange action
            // to avoid AttributeGraph cycles during send.
            DispatchQueue.main.async {
                viewModel.clearComposerAutocomplete()
            }
        }
        .onChange(of: renderSnapshot.repoRefreshSignal) { _, newValue in
            guard showsGitControls, newValue != nil else { return }
            // Defer the observable-model mutation out of the .onChange action
            // to avoid AttributeGraph cycles when the parent re-renders.
            DispatchQueue.main.async { [viewModel] in
                viewModel.scheduleGitStatusRefresh(
                    codex: codex,
                    workingDirectory: gitWorkingDirectory,
                    threadID: thread.id
                )
            }
        }
        .onChange(of: renderSnapshot.timelineChangeToken) { _, _ in
            // Defer the observable-model mutation out of the .onChange action
            // to avoid AttributeGraph cycles when the parent re-renders.
            let messages = renderSnapshot.messages
            DispatchQueue.main.async { [viewModel] in
                viewModel.reconcileDismissedStructuredPlanPrompts(messages: messages, codex: codex)
            }
        }
        .onReceive(voiceInput.transcriptionManager.$recordingDuration) { duration in
            handleVoiceRecordingDuration(duration)
        }
        .onReceive(voiceInput.transcriptionManager.$captureInvalidationID) { invalidationID in
            guard invalidationID > 0 else { return }
            handleVoiceCaptureInvalidation()
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
        .sheet(isPresented: $voiceInput.isShowingSetupSheet) {
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
            isApprovalAlertPresented: $isApprovalAlertPresented,
            isShowingNothingToCommitAlert: isShowingNothingToCommitAlertBinding,
            gitSyncAlert: gitSyncAlertBinding,
            isShowingMacHandoffConfirm: $isShowingMacHandoffConfirm,
            macHandoffErrorMessage: $macHandoffErrorMessage,
            onDeclineApproval: { request in
                viewModel.decline(request, codex: codex) { didSucceed in
                    if didSucceed {
                        syncApprovalAlertPresentation()
                    } else {
                        restoreApprovalAlert(afterFailureOf: request)
                    }
                }
            },
            onApproveApproval: { request in
                viewModel.approve(request, codex: codex) { didSucceed in
                    if didSucceed {
                        syncApprovalAlertPresentation()
                    } else {
                        restoreApprovalAlert(afterFailureOf: request)
                    }
                }
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
                continueOnDesktopApp()
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
                handleConnectionRecoveryAction()
            }
        )
    }

    // Keeps reconnect prompts out of the red footer error slot; recovery UI owns that state.
    private var timelineFooterErrorMessage: String? {
        TurnFooterErrorFilter.visibleFooterMessage(from: codex.lastErrorMessage)
    }

    private var voiceRecoveryPresentation: VoiceRecoveryPresentation? {
        guard let reason = voiceInput.recoveryReason else {
            return nil
        }

        guard let resolvedReason = codex.resolveVoiceRecoveryReason(reason) else {
            return nil
        }

        return TurnVoiceRecoveryPresentationBuilder.presentation(for: resolvedReason)
    }

    private var connectionRecoverySnapshot: ConnectionRecoverySnapshot? {
        TurnConnectionRecoverySnapshotBuilder.makeSnapshot(
            hasReconnectCandidate: codex.hasReconnectCandidate,
            isConnected: codex.isConnected,
            secureConnectionState: codex.secureConnectionState,
            showsWakeSavedMacDisplayAction: shouldOfferWakeSavedMacDisplayAction,
            isWakingMacDisplayRecovery: isWakingMacDisplayRecovery,
            isConnecting: codex.isConnecting,
            shouldAutoReconnectOnForeground: codex.shouldAutoReconnectOnForeground,
            isRetryingConnectionRecovery: isRetryingConnectionRecovery,
            lastErrorMessage: codex.lastErrorMessage
        )
    }

    private var canWakeSavedMacDisplay: Bool {
        codex.canWakePreferredMacDisplay
    }

    // Matches the root fallback gate so the turn card only offers wake after the silent attempt already ran.
    private var shouldOfferWakeSavedMacDisplayAction: Bool {
        canWakeSavedMacDisplay && wakeMacDisplayAction != nil
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

    private func continueOnDesktopApp() {
        guard !isHandingOffToMac else { return }
        isHandingOffToMac = true

        Task { @MainActor in
            defer { isHandingOffToMac = false }

            do {
                let handoffService = DesktopHandoffService(codex: codex)
                try await handoffService.continueOnDesktopApp(threadId: thread.id)
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
                if let message = codex.userFacingTurnErrorMessageForFooter(from: error),
                   codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    codex.lastErrorMessage = message
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
        guard !isVoiceInputActive else { return }
        viewModel.clearComposerAutocomplete()
        viewModel.sendTurn(codex: codex, subscriptions: subscriptions, threadID: thread.id)
        isInputFocused = false
    }

    @ViewBuilder
    private func composerStructuredPromptReplacement(message: CodexMessage) -> some View {
        let activeTurnID = codex.activeTurnID(for: thread.id)
        let renderSnapshot = codex.timelineState(for: thread.id).renderSnapshot
        let activeFileChangeStatus = FileChangeStatusSnapshot.activeTurnSnapshot(
            from: renderSnapshot.messages,
            activeTurnID: activeTurnID,
            isThreadRunning: renderSnapshot.isThreadRunning
        )

        if let request = message.structuredUserInputRequest {
            let isDismissed = viewModel.isStructuredPlanPromptDismissed(request.requestID, codex: codex)
            let isDismissing = viewModel.isStructuredPlanPromptDismissing(request.requestID, codex: codex)

            if !isDismissed {
                StructuredUserInputCard(
                    request: request,
                    isInteractionLocked: isDismissing,
                    secondaryActionTitle: isDismissing ? "Closing..." : "ESC",
                    onSecondaryAction: isDismissing ? nil : {
                        isInputFocused = true
                        viewModel.dismissStructuredPlanPrompt(message, codex: codex, threadID: thread.id)
                    }
                )
                .id(request.requestID)
                .padding(.horizontal, 12)
                .padding(.top, 4)
            } else {
                composerWithSubagentAccessory(
                    currentThread: currentResolvedThread,
                    activeTurnID: activeTurnID,
                    isThreadRunning: renderSnapshot.isThreadRunning,
                    isEmptyThread: renderSnapshot.messages.isEmpty,
                    isWorktreeProject: currentResolvedThread.isManagedWorktreeProject,
                    activeFileChangeStatus: activeFileChangeStatus,
                    showsGitControls: codex.isConnected && currentResolvedThread.gitWorkingDirectory != nil,
                    gitWorkingDirectory: currentResolvedThread.gitWorkingDirectory
                )
            }
        } else {
            composerWithSubagentAccessory(
                currentThread: currentResolvedThread,
                activeTurnID: activeTurnID,
                isThreadRunning: renderSnapshot.isThreadRunning,
                isEmptyThread: renderSnapshot.messages.isEmpty,
                isWorktreeProject: currentResolvedThread.isManagedWorktreeProject,
                activeFileChangeStatus: activeFileChangeStatus,
                showsGitControls: codex.isConnected && currentResolvedThread.gitWorkingDirectory != nil,
                gitWorkingDirectory: currentResolvedThread.gitWorkingDirectory
            )
        }
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
        viewModel.isGitRepositoryInitialized && canRunGitAction(
            isThreadRunning: isThreadRunning,
            gitWorkingDirectory: gitWorkingDirectory
        )
    }

    // Centralizes the toolbar/composer availability rule so both entry points stay aligned.
    private func canHandOffToWorktree(
        isThreadRunning: Bool,
        gitWorkingDirectory: String?
    ) -> Bool {
        isWorktreeHandoffAvailable(
            isThreadRunning: isThreadRunning,
            gitWorkingDirectory: gitWorkingDirectory
        ) && !viewModel.isCreatingGitWorktree
    }

    private func handleWorktreeHandoffTap(currentThread: CodexThread) {
        if currentThread.isManagedWorktreeProject {
            Task { @MainActor in
                do {
                    let move = try await WorktreeFlowCoordinator.handoffThreadToLocal(
                        thread: currentThread,
                        codex: codex
                    )
                    viewModel.refreshGitBranchTargets(
                        codex: codex,
                        workingDirectory: move.projectPath,
                        threadID: thread.id
                    )
                } catch {
                    viewModel.gitSyncAlert = TurnGitSyncAlert(
                        title: "Local Handoff Failed",
                        message: error.localizedDescription.isEmpty
                            ? "Could not hand off the thread back to Local."
                            : error.localizedDescription,
                        action: .dismissOnly
                    )
                }
            }
            return
        }

        guard let associatedWorktreePath = codex.associatedManagedWorktreePath(for: thread.id) else {
            worktreeOverlayRoute = .handoff
            return
        }

        Task { @MainActor in
            viewModel.isCreatingGitWorktree = true
            defer { viewModel.isCreatingGitWorktree = false }

            do {
                let outcome = try await WorktreeFlowCoordinator.handoffThreadToWorktree(
                    threadID: thread.id,
                    sourceProjectPath: currentThread.gitWorkingDirectory,
                    associatedWorktreePath: associatedWorktreePath,
                    codex: codex
                )

                switch outcome {
                case .moved(let move):
                    viewModel.refreshGitBranchTargets(
                        codex: codex,
                        workingDirectory: move.projectPath,
                        threadID: thread.id
                    )
                case .missingAssociatedWorktree:
                    worktreeOverlayRoute = .handoff
                }
            } catch {
                viewModel.gitSyncAlert = TurnGitSyncAlert(
                    title: "Worktree Handoff Failed",
                    message: error.localizedDescription.isEmpty
                        ? "Could not hand off the thread to the new worktree."
                        : error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    private func handleInitialAppear(activeTurnID: String?) {
        syncApprovalAlertPresentation()
        if initialShouldAnchorToAssistantResponse && !hasConsumedInitialAssistantAnchor {
            hasConsumedInitialAssistantAnchor = true
            viewModel.shouldAnchorToAssistantResponse = true
            onInitialAssistantAnchorConsumed?()
        }
        if let pendingComposerAction = codex.consumePendingComposerAction(for: thread.id) {
            viewModel.applyPendingComposerAction(pendingComposerAction)
            viewModel.saveLocalDraft(codex: codex, threadID: thread.id)
            isInputFocused = true
        } else {
            viewModel.restoreSavedLocalDraftIfNeeded(codex: codex, threadID: thread.id)
        }
    }

    private func handlePhotoPickerItemsChanged(_ newItems: [PhotosPickerItem]) {
        viewModel.enqueuePhotoPickerItems(newItems, codex: codex, threadID: thread.id)
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

    // Creates a named worktree, then rebinds this same chat to that checkout.
    private func submitWorktreeHandoff(
        branchName: String,
        baseBranch: String,
        gitWorkingDirectory: String?,
        activeTurnID: String?
    ) {
        viewModel.requestCreateGitWorktree(
            named: branchName,
            fromBaseBranch: baseBranch,
            changeTransfer: .none,
            codex: codex,
            workingDirectory: gitWorkingDirectory,
            threadID: thread.id,
            activeTurnID: activeTurnID,
            onOpenWorktree: { result in
                guard !result.alreadyExisted else {
                    viewModel.gitSyncAlert = TurnGitSyncAlert(
                        title: "Branch Already Exists",
                        message: "A worktree for '\(result.branch)' already exists. Choose a different name.",
                        action: .dismissOnly
                    )
                    return
                }

                Task { @MainActor in
                    do {
                        let outcome = try await WorktreeFlowCoordinator.handoffThreadToWorktree(
                            threadID: thread.id,
                            sourceProjectPath: gitWorkingDirectory,
                            associatedWorktreePath: result.worktreePath,
                            codex: codex
                        )

                        if case .moved(let move) = outcome {
                            worktreeOverlayRoute = nil
                            viewModel.refreshGitBranchTargets(
                                codex: codex,
                                workingDirectory: move.projectPath,
                                threadID: thread.id
                            )
                        }
                    } catch {
                        viewModel.gitSyncAlert = TurnGitSyncAlert(
                            title: "Worktree Handoff Failed",
                            message: error.localizedDescription.isEmpty
                                ? "Could not hand off the thread to the new worktree."
                                : error.localizedDescription,
                            action: .dismissOnly
                        )
                    }
                }
            }
        )
    }

    // Forks the current conversation into the Local checkout when possible.
    private func startLocalFork() {
        Task { @MainActor in
            guard !isForkingThread else { return }
            let sourceThread = currentResolvedThread
            guard WorktreeFlowCoordinator.localForkProjectPath(
                for: sourceThread,
                localCheckoutPath: viewModel.gitLocalCheckoutPath
            ) != nil else {
                viewModel.gitSyncAlert = TurnGitSyncAlert(
                    title: "Local Fork Unavailable",
                    message: sourceThread.isManagedWorktreeProject
                        ? "Could not resolve the Local checkout for this worktree thread."
                        : "Could not resolve the local project path for this thread.",
                    action: .dismissOnly
                )
                return
            }
            isForkingThread = true
            defer { isForkingThread = false }

            do {
                let forkedThread = try await WorktreeFlowCoordinator.forkThreadToLocal(
                    sourceThread: sourceThread,
                    localCheckoutPath: viewModel.gitLocalCheckoutPath,
                    codex: codex
                )
                openThread(forkedThread.id)
            } catch {
                if let message = codex.userFacingTurnErrorMessageForFooter(from: error),
                   codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    codex.lastErrorMessage = message
                }
            }
        }
    }

    // Creates a named worktree, then forks the conversation into that checkout.
    private func submitForkIntoNewWorktree(
        branchName: String,
        baseBranch: String,
        gitWorkingDirectory: String?,
        activeTurnID: String?
    ) {
        viewModel.requestCreateGitWorktree(
            named: branchName,
            fromBaseBranch: baseBranch,
            changeTransfer: .none,
            codex: codex,
            workingDirectory: gitWorkingDirectory,
            threadID: thread.id,
            activeTurnID: activeTurnID,
            onOpenWorktree: { result in
                guard !result.alreadyExisted else {
                    viewModel.gitSyncAlert = TurnGitSyncAlert(
                        title: "Branch Already Exists",
                        message: "A worktree for '\(result.branch)' already exists. Choose a different name.",
                        action: .dismissOnly
                    )
                    return
                }

                isForkingThread = true
                Task { @MainActor in
                    defer { isForkingThread = false }

                    do {
                        let forkedThread = try await codex.forkThreadIfReady(
                            from: thread.id,
                            target: .projectPath(result.worktreePath)
                        )
                        worktreeOverlayRoute = nil
                        openThread(forkedThread.id)
                    } catch {
                        viewModel.gitSyncAlert = TurnGitSyncAlert(
                            title: "Worktree Fork Failed",
                            message: error.localizedDescription.isEmpty
                                ? "Could not fork the thread into the new worktree."
                                : error.localizedDescription,
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
        guard !SidebarThreadGrouping.isRootlessChatThread(currentThread) else {
            return nil
        }
        return currentThread.normalizedProjectPath
    }

    // Creates a fresh thread in the same project and opens it straight into the review flow.
    private func startCodeReviewThread(target: TurnComposerReviewTarget) {
        Task { @MainActor in
            do {
                _ = try await codex.startThreadIfReady(
                    preferredProjectPath: resolvedProjectPathForFollowUpThread(),
                    pendingComposerAction: .codeReview(target: target.codexPendingTarget)
                )
                viewModel.clearComposerReviewSelection()
                viewModel.saveLocalDraft(codex: codex, threadID: thread.id, persistToDisk: true)
            } catch {
                if let message = codex.userFacingTurnErrorMessageForFooter(from: error),
                   codex.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    codex.lastErrorMessage = message
                }
            }
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
        if let selectedModel = codex.selectedModelOption() {
            return TurnComposerMetaMapper.modelTitle(for: selectedModel)
        }

        return TurnComposerMetaMapper.modelTitle(forIdentifier: codex.selectedModelId)
    }

    private var approvalForThread: CodexApprovalRequest? {
        codex.pendingApproval(for: thread.id)
    }

    private var approvalRequestChangeToken: String? {
        guard let request = approvalForThread else {
            return nil
        }

        let reason = request.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = request.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [request.id, reason, command].joined(separator: "|")
    }

    private func syncApprovalAlertPresentation() {
        alertApprovalRequest = approvalForThread
        isApprovalAlertPresented = alertApprovalRequest != nil
    }

    private func restoreApprovalAlert(afterFailureOf request: CodexApprovalRequest) {
        alertApprovalRequest = approvalForThread ?? request
        isApprovalAlertPresented = alertApprovalRequest != nil
    }

    private var parentThread: CodexThread? {
        guard let parentThreadId = thread.parentThreadId else {
            return nil
        }

        return codex.thread(for: parentThreadId)
    }

    private func threadNavigationContext(for thread: CodexThread) -> TurnThreadNavigationContext? {
        guard let path = thread.gitWorkingDirectory,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let fullPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = fullPath.pathDisplayName
        return TurnThreadNavigationContext(
            folderName: folderName,
            subtitle: folderName,
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
        activeFileChangeStatus: FileChangeStatusSnapshot?,
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
                activeFileChangeStatus: activeFileChangeStatus,
                canForkLocally: gitWorkingDirectory != nil && WorktreeFlowCoordinator.localForkProjectPath(
                    for: currentThread,
                    localCheckoutPath: viewModel.gitLocalCheckoutPath
                ) != nil,
                isInputFocused: $isInputFocused,
                orderedModelOptions: orderedModelOptions,
                selectedModelTitle: selectedModelTitle,
                reasoningDisplayOptions: reasoningDisplayOptions,
                showsGitControls: showsGitControls && viewModel.isGitRepositoryInitialized,
                isGitBranchSelectorEnabled: viewModel.isGitRepositoryInitialized && canRunGitAction(
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

                        let existingThread = WorktreeFlowCoordinator.liveThreadForCheckedOutElsewhereBranch(
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
                    guard showsGitControls, viewModel.isGitRepositoryInitialized else { return }
                    viewModel.refreshGitBranchTargets(
                        codex: codex,
                        workingDirectory: gitWorkingDirectory,
                        threadID: thread.id
                    )
                },
                onStartCodeReviewThread: startCodeReviewThread,
                onStartForkThreadLocally: startLocalFork,
                onOpenForkWorktree: {
                    worktreeOverlayRoute = .fork
                },
                onOpenWorktreeHandoff: {
                    handleWorktreeHandoffTap(currentThread: currentThread)
                },
                onOpenFeedbackMail: {
                    openURL(AppEnvironment.feedbackMailtoURL(
                        errorMessage: codex.lastErrorMessage,
                        threadId: thread.id,
                        isConnected: codex.isConnected,
                        cliVersion: codex.bridgeInstalledVersion
                    ))
                },
                onShowStatus: presentStatusSheet,
                voiceButtonPresentation: voiceButtonPresentation,
                isVoiceInputActive: isVoiceInputActive,
                isVoiceRecording: voiceInput.isRecording,
                voiceAudioLevels: voiceInput.audioLevels,
                voiceRecordingDuration: voiceInput.recordingDuration,
                onTapVoice: handleVoiceButtonTap,
                onCancelVoiceRecording: cancelVoiceInputIfNeeded,
                onSend: handleSend
            )
        }
    }

    private var isVoiceInputActive: Bool {
        voiceInput.isInputActive
    }

    // Mirrors the mic CTA state so the composer can swap between ready, record, and stop.
    private var voiceButtonPresentation: TurnComposerVoiceButtonPresentation {
        voiceInput.buttonPresentation(isConnected: codex.isConnected)
    }

    // Switches the mic button between login, recording, and transcription states.
    private func handleVoiceButtonTap() {
        voiceInput.handleButtonTap(
            codex: codex,
            onTranscript: applyVoiceTranscript,
            onDismissInput: dismissVoiceInputFocus
        )
    }

    // User-initiated cancel should abort both capture and any just-started transcription race.
    private func cancelVoiceInputIfNeeded() {
        voiceInput.cancelInputIfNeeded()
    }

    private func handleVoiceRecordingDuration(_ duration: TimeInterval) {
        voiceInput.handleRecordingDuration(
            duration,
            codex: codex,
            onTranscript: applyVoiceTranscript,
            onDismissInput: dismissVoiceInputFocus
        )
    }

    // Losing the active scene stops capture; completion is best-effort while this view stays alive.
    private func handleVoiceScenePhaseChange(_ phase: ScenePhase) {
        voiceInput.handleScenePhaseChange(
            phase,
            codex: codex,
            onTranscript: applyVoiceTranscript,
            onDismissInput: dismissVoiceInputFocus
        )
    }

    // Navigation away cancels voice work instead of promising background completion.
    private func handleVoiceViewDisappear() {
        voiceInput.handleViewDisappear(
            scenePhase: scenePhase,
            codex: codex,
            onTranscript: applyVoiceTranscript,
            onDismissInput: dismissVoiceInputFocus
        )
    }

    // Resets UI state when iOS invalidates the mic route underneath an active recording.
    private func handleVoiceCaptureInvalidation() {
        voiceInput.handleCaptureInvalidation(codex: codex)
    }

    private func handleVoiceRecoveryAction(_ action: VoiceRecoveryAction) {
        switch action {
        case .reconnect:
            reconnectAction?()
        case .openMacLogin:
            voiceInput.startVoiceLoginOnMac(codex: codex)
        case .showSetupHelp:
            voiceInput.isShowingSetupSheet = true
        case .openSystemSettings:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            openURL(settingsURL)
        case .none:
            break
        }
    }

    private func handleConnectionRecoveryAction() {
        if shouldOfferWakeSavedMacDisplayAction {
            wakeMacDisplayAction?()
            return
        }

        reconnectAction?()
    }

    private func applyVoiceTranscript(_ transcript: String) {
        viewModel.appendVoiceTranscript(transcript)
        viewModel.saveLocalDraft(codex: codex, threadID: thread.id, persistToDisk: true)
    }

    private func dismissVoiceInputFocus() {
        // Keep voice flows keyboard-free; users can tap into the draft afterward if they want to edit.
        isInputFocused = false
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
        codex.requestImmediateActiveThreadSync(threadId: threadId, forceHistoryRefresh: true)
    }

    // MARK: - Empty State

    private var loadingState: some View {
        ChatEmptyStatePlaceholder(
            title: Text("Loading chat..."),
            subtitle: "Fetching the latest messages for this conversation."
        )
    }

    private func resolvedEmptyState(for phase: CodexService.ThreadDisplayPhase) -> AnyView {
        switch phase {
        case .loading:
            return AnyView(loadingState)
        case .empty, .ready:
            return AnyView(emptyState)
        }
    }

    private var emptyState: some View {
        ChatEmptyStatePlaceholder(
            title: ChatEmptyStateTitleBuilder.makeTitle(for: emptyStateFolderName),
            subtitle: "Chats are End-to-end encrypted"
        )
    }

    private var emptyStateFolderName: String? {
        let resolvedThread = currentResolvedThread
        guard !SidebarThreadGrouping.isRootlessChatThread(resolvedThread),
              let cwd = resolvedThread.gitWorkingDirectory else { return nil }
        let display = cwd.pathDisplayName
        // Defensive: pathDisplayName falls back to the input, so only nil out
        // when there's no usable folder portion at all (empty cwd after split).
        return display.isEmpty ? nil : display
    }
}


#Preview {
    NavigationStack {
        TurnView(
            thread: CodexThread(id: "thread_preview", title: "Preview"),
            isWakingMacDisplayRecovery: false
        )
            .environment(CodexService())
    }
}
