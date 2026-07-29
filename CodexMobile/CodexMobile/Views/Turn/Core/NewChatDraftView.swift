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

// Where the first send materializes the thread: the local checkout itself, or a
// managed worktree created at send time (mirrors Codex Desktop's draft mode —
// nothing is created on disk until the first message goes out).
private enum NewChatDraftRuntimeMode {
    case local
    case newWorktree
}

struct NewChatDraftView: View {
    @Environment(CodexService.self) private var codex
    @Environment(SubscriptionService.self) private var subscriptions
    @Environment(\.openURL) private var openURL
    @Environment(\.reconnectAction) private var reconnectAction
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let route: NewChatDraftRoute
    var leadingControl: NewChatDraftLeadingControl = .back
    var onOpenTerminal: ((String?) -> Void)? = nil
    let onOpenThread: @MainActor @Sendable (CodexThread) -> Void

    @State private var viewModel = TurnViewModel()
    @State private var isInputFocused = false
    @State private var hasAutoFocusedComposer = false
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
    @State private var draftRuntimeMode: NewChatDraftRuntimeMode = .local
    @State private var selectedWorktreeBaseBranch: String?
    @State private var isShowingCreateBranchPrompt = false
    @State private var newDraftBranchName = ""
    @State private var isShowingAllBranchesPicker = false
    @StateObject private var voiceInput = VoiceInputCoordinator()

    // UI-only check for layout experiments: true when opened from the general
    // sidebar Chat affordance, false when opened from a folder section button.
    private var isFromGeneralChat: Bool {
        route.isFromGeneralChat
    }

    var body: some View {
        // Keep the draft surface static while first send creates the real thread.
        VStack(spacing: 0) {
            if let pendingDraftUserMessage {
                pendingDraftUserMessageView(pendingDraftUserMessage)
            } else {
                // Bottom-anchored like Codex Desktop's new-task rows: the
                // pickers sit just above the composer instead of mid-screen.
                Spacer(minLength: 0)
                promptStack
                    .padding(.bottom, 20)
            }
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

            // Match the real thread toolbar so the Git/menu controls stay in one visual group
            // before and after the first message creates the runtime thread.
            if hasSelectedProject {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) {
                        draftGitActionsButton
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        draftThreadActionsMenu
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        draftToolbarActionCluster
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    draftThreadActionsMenu
                }
            }
        }
        .task {
            initializeProjectSelectionIfNeeded()
            refreshDraftGitStateIfNeeded()
            // Opening a fresh chat should land the cursor in the composer so the
            // keyboard is up and the user can type right away.
            autoFocusComposerIfNeeded()
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

            voiceInput.clearReconnectRecoveryIfNeeded()
            guard !wasConnected, isConnected else { return }
            refreshDraftGitStateIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            handleVoiceScenePhaseChange(phase)
            viewModel.saveLifecycleLocalDraft(codex: codex, threadID: route.id)
        }
        .onChange(of: selectedProjectPath) { _, _ in
            // Defer the observable-model mutation out of the .onChange action
            // to avoid AttributeGraph cycles when the parent re-renders.
            DispatchQueue.main.async { [viewModel] in
                viewModel.clearComposerAutocomplete()
            }
            // Runtime mode and base branch are per-repo choices; a folder
            // switch resets them so a stale base can't leak across projects.
            draftRuntimeMode = .local
            selectedWorktreeBaseBranch = nil
            refreshDraftGitStateForSelectedProject()
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .sheet(isPresented: $isShowingAllBranchesPicker) {
            allBranchesPickerSheet
        }
        .newGitBranchPrompt(isPresented: $isShowingCreateBranchPrompt, branchName: $newDraftBranchName) { branchName in
            createDraftBranch(branchName)
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
        .onReceive(voiceInput.transcriptionManager.$recordingDuration) { duration in
            handleVoiceRecordingDuration(duration)
        }
        .onReceive(voiceInput.transcriptionManager.$captureInvalidationID) { invalidationID in
            guard invalidationID > 0 else { return }
            handleVoiceCaptureInvalidation()
        }
        .onDisappear {
            handleVoiceViewDisappear()
        }
        .sheet(isPresented: $voiceInput.isShowingSetupSheet) {
            GPTVoiceSetupSheet()
        }
        .animation(.easeInOut(duration: 0.18), value: pendingDraftUserMessage?.id)
    }

    // Shows the first user bubble while the app is still waiting for thread/start.
    private var pendingDraftUserMessage: CodexMessage? {
        codex.messages(for: route.id).last { message in
            message.role == .user && message.deliveryState == .pending
        }
    }

    private func pendingDraftUserMessageView(_ message: CodexMessage) -> some View {
        VStack(spacing: 0) {
            UserMessageBubble(
                message: message,
                text: message.text,
                actionText: message.text,
                isRetryAvailable: false,
                onRetryUserMessage: { _ in }
            )
            .padding(.horizontal, draftTimelineHorizontalPadding)
            .padding(.top, 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
    }

    private var draftTimelineHorizontalPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 16
    }

    // Unified draft context for every route (general chat and folder chats):
    // one place to pick the folder, Local vs new worktree, and the branch —
    // all through plain context menus, mirroring Codex Desktop's new-task rows.
    private var promptStack: some View {
        draftContextRows
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }

    // Near-label gray: almost white in dark mode, almost black in light —
    // dimmer than `.primary` but clearly brighter than `.secondary`.
    private var draftContextRowForeground: Color {
        Color(.label).opacity(0.88)
    }

    // The Git rows appear only once a folder with an initialized repo is bound;
    // rootless Quick Chat shows just the folder row so it can become project-backed.
    private var showsGitContextRows: Bool {
        hasSelectedProject && viewModel.isGitRepositoryInitialized
    }

    private var draftContextRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            UIKitMenuButton {
                draftContextRowLabel(title: folderPillLabel) {
                    pickerIcon
                }
            } menu: {
                folderPickerMenu()
            }
            .accessibilityLabel("Select folder")
            .accessibilityValue(folderPillLabel)

            if showsGitContextRows {
                UIKitMenuButton {
                    draftContextRowLabel(title: draftRuntimeMode == .newWorktree ? "New worktree" : "Work locally") {
                        if draftRuntimeMode == .newWorktree {
                            CodexWorktreeIcon(pointSize: 19)
                        } else {
                            RemodexIcon.image(systemName: "laptopcomputer", size: 19)
                        }
                    }
                } menu: {
                    draftRuntimeModeMenu()
                }
                .accessibilityLabel("Where to work")
                .accessibilityValue(draftRuntimeMode == .newWorktree ? "New worktree" : "Work locally")

                UIKitMenuButton {
                    draftContextRowLabel(title: draftBranchLabel) {
                        RemodexIcon.image(systemName: "remodex.git-branch", size: 19)
                    }
                } menu: {
                    draftBranchMenu()
                }
                .disabled(viewModel.isSwitchingGitBranch || viewModel.isLoadingGitBranchTargets)
                .accessibilityLabel(draftRuntimeMode == .newWorktree ? "Worktree base branch" : "Current branch")
                .accessibilityValue(draftBranchLabel)
            }
        }
    }

    // One reference row: fixed icon column, near-label gray, small selector chevron.
    private func draftContextRowLabel(title: String, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 10) {
            icon()
                .foregroundStyle(draftContextRowForeground)
                .frame(width: 24, height: 24)
            Text(title)
                .font(AppFont.body(weight: .regular))
                .foregroundStyle(draftContextRowForeground)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private var toolbarTitleLabel: some View {
        TurnChatToolbarTitleLabel(
            title: "New thread",
            subtitle: placeholderFolderName ?? trustedHostName,
            // General chat uses the inline context menu; folder-backed drafts can still open the sheet.
            onTap: !isFromGeneralChat && hasSelectedProject ? { activeSheet = .projectPicker } : nil,
            accessibilityHint: !isFromGeneralChat && hasSelectedProject ? "Opens the project picker" : nil
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
            actions: draftThreadActions
        )
    }

    private var draftToolbarActionCluster: some View {
        TurnToolbarActionCluster(
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
            onGitAction: handleDraftGitActionSelection,
            isThreadActionLoading: false,
            threadActions: draftThreadActions
        )
    }

    private var draftThreadActions: [TurnThreadActionMenuItem] {
        [
            TurnThreadActionMenuItem(
                title: "Open Terminal Here",
                icon: .system("terminal"),
                isEnabled: !areDraftToolbarActionsDisabled && onOpenTerminal != nil
            ) {
                onOpenTerminal?(selectedProjectPath)
            },
        ]
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

    // Builds the folder-only context menu used by the draft's folder row.
    private func folderPickerMenu() -> UIMenu {
        guard !projectChoices.isEmpty else {
            return UIMenu(children: [
                UIAction(
                    title: "No folders available",
                    image: RemodexIcon.menuUIImage(systemName: "folder"),
                    attributes: [.disabled]
                ) { _ in },
            ])
        }

        let actions = projectChoices.map { choice in
            UIAction(
                title: choice.label,
                image: RemodexIcon.menuUIImage(systemName: choice.iconSystemName),
                state: selectedProjectPath == choice.projectPath ? .on : .off
            ) { _ in
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                selectedProjectPath = choice.projectPath
            }
        }

        return UIMenu(title: "", options: [.displayInline, .singleSelection], children: actions)
    }

    // Uses the custom Remodex folder glyph so the inline picker matches the rest of the sidebar.
    private var pickerIcon: some View {
        Image("central-folder-2")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 21)
    }

    // ─── Runtime + branch rows ───────────────────────────────────

    private func draftRuntimeModeMenu() -> UIMenu {
        let localAction = UIAction(
            title: "Work locally",
            image: RemodexIcon.menuUIImage(systemName: "laptopcomputer"),
            state: draftRuntimeMode == .local ? .on : .off
        ) { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            draftRuntimeMode = .local
        }
        let worktreeAction = UIAction(
            title: "New worktree",
            image: CodexWorktreeIcon.menuImage(pointSize: 16),
            state: draftRuntimeMode == .newWorktree ? .on : .off
        ) { _ in
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            draftRuntimeMode = .newWorktree
        }
        return UIMenu(options: [.displayInline, .singleSelection], children: [localAction, worktreeAction])
    }

    // Local mode reflects (and switches) the checkout; worktree mode only picks
    // the base branch that the managed worktree will be cut from at first send.
    private var draftBranchLabel: String {
        if draftRuntimeMode == .newWorktree,
           let selectedWorktreeBaseBranch,
           !selectedWorktreeBaseBranch.isEmpty {
            return selectedWorktreeBaseBranch
        }
        return remodexVisibleBranchLabel(
            currentBranch: viewModel.currentGitBranch,
            defaultBranch: viewModel.gitDefaultBranch
        )
    }

    // Keeps the context menu scannable; the full searchable picker stays one tap away.
    private static let maxRecentBranchesInMenu = 7

    private func draftBranchMenu() -> UIMenu {
        // Default branch first, then the rest in bridge order (most recent first).
        var orderedBranches = viewModel.availableGitBranchTargets
        let defaultBranch = viewModel.gitDefaultBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !defaultBranch.isEmpty, let defaultIndex = orderedBranches.firstIndex(of: defaultBranch) {
            orderedBranches.remove(at: defaultIndex)
            orderedBranches.insert(defaultBranch, at: 0)
        }
        let recentBranches = orderedBranches.prefix(Self.maxRecentBranchesInMenu)

        let branchActions = recentBranches.map { branch in
            // Any branch can seed a detached worktree, so "open elsewhere" only
            // blocks selection when it would mean switching the local checkout.
            let isDisabled = draftRuntimeMode == .local && remodexCurrentBranchSelectionIsDisabled(
                branch: branch,
                currentBranch: viewModel.currentGitBranch,
                gitBranchesCheckedOutElsewhere: viewModel.gitBranchesCheckedOutElsewhere,
                gitWorktreePathsByBranch: viewModel.gitWorktreePathsByBranch,
                allowsSelectingCurrentBranch: true
            )
            return UIAction(
                title: branch,
                image: RemodexIcon.menuUIImage(systemName: "remodex.git-branch"),
                attributes: isDisabled ? [.disabled] : [],
                state: branch == draftBranchLabel ? .on : .off
            ) { _ in
                selectDraftBranch(branch)
            }
        }
        let recentSection = UIMenu(
            title: "Recent branches",
            options: [.displayInline, .singleSelection],
            children: branchActions
        )

        var trailingActions: [UIMenuElement] = []
        if draftRuntimeMode == .local {
            // Creating a branch only makes sense when it becomes the checkout;
            // a worktree base must already exist.
            trailingActions.append(UIAction(
                title: "New branch...",
                image: RemodexIcon.menuUIImage(systemName: "plus")
            ) { _ in
                newDraftBranchName = "remodex/"
                isShowingCreateBranchPrompt = true
            })
        }
        if orderedBranches.count > recentBranches.count {
            trailingActions.append(UIAction(
                title: "All branches...",
                image: RemodexIcon.menuUIImage(systemName: "magnifyingglass")
            ) { _ in
                isShowingAllBranchesPicker = true
            })
        }

        guard !trailingActions.isEmpty else {
            return recentSection
        }
        return UIMenu(children: [
            recentSection,
            UIMenu(options: [.displayInline], children: trailingActions),
        ])
    }

    private func selectDraftBranch(_ branch: String) {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        switch draftRuntimeMode {
        case .newWorktree:
            selectedWorktreeBaseBranch = branch
        case .local:
            guard hasSelectedProject else { return }
            viewModel.requestSwitchGitBranch(
                to: branch,
                codex: codex,
                workingDirectory: selectedProjectPath,
                threadID: route.id,
                activeTurnID: nil
            )
        }
    }

    private func createDraftBranch(_ rawName: String) {
        let branchName = remodexNormalizedCreatedBranchName(rawName)
        guard !branchName.isEmpty, hasSelectedProject else { return }
        viewModel.requestCreateGitBranch(
            named: branchName,
            codex: codex,
            workingDirectory: selectedProjectPath,
            threadID: route.id,
            activeTurnID: nil
        )
    }

    // Full searchable picker for repos with more branches than the menu shows.
    private var allBranchesPickerSheet: some View {
        NavigationStack {
            TurnGitBranchPickerSheet(
                branches: viewModel.availableGitBranchTargets.filter { $0 != viewModel.gitDefaultBranch },
                gitBranchesCheckedOutElsewhere: draftRuntimeMode == .local
                    ? viewModel.gitBranchesCheckedOutElsewhere
                    : [],
                gitWorktreePathsByBranch: viewModel.gitWorktreePathsByBranch,
                selectedBranch: draftBranchLabel,
                defaultBranch: remodexSelectableDefaultBranch(
                    defaultBranch: viewModel.gitDefaultBranch,
                    availableGitBranchTargets: viewModel.availableGitBranchTargets
                ),
                currentBranch: viewModel.currentGitBranch,
                allowsSelectingCurrentBranch: true,
                sectionTitle: "Branches",
                navigationTitle: draftRuntimeMode == .newWorktree ? "Base Branch" : "Current Branch",
                isLoading: viewModel.isLoadingGitBranchTargets,
                isSwitching: viewModel.isSwitchingGitBranch,
                onSelect: { branch in
                    selectDraftBranch(branch)
                    isShowingAllBranchesPicker = false
                },
                onCreateBranch: { branchName in
                    createDraftBranch(branchName)
                    isShowingAllBranchesPicker = false
                },
                onRefresh: { refreshDraftGitStateIfNeeded() }
            )
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var trustedHostName: String? {
        let trimmed = (codex.trustedPairPresentation?.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let voiceRecoveryPresentation {
                ConnectionRecoveryCard(
                    snapshot: voiceRecoveryPresentation.snapshot,
                    onTap: {
                        handleVoiceRecoveryAction(voiceRecoveryPresentation.action)
                    },
                    onDismiss: {
                        voiceInput.clearRecovery()
                    }
                )
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            TurnComposerHostView(
                viewModel: viewModel,
                codex: codex,
                thread: draftThread,
                usesThreadRuntimeSettings: false,
                activeTurnID: nil,
                isThreadRunning: false,
                isEmptyThread: true,
                isWorktreeProject: false,
                canForkLocally: false,
                isInputFocused: $isInputFocused,
                orderedModelOptions: orderedModelOptions,
                selectedModelTitle: selectedModelTitle,
                reasoningDisplayOptions: reasoningDisplayOptions,
                // The draft's folder/runtime/branch rows own Git context now, so
                // the composer's collapsible cluster stays off to avoid two
                // competing branch pickers on one screen.
                showsGitControls: false,
                isGitBranchSelectorEnabled: false,
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
                allowsGoalCommand: false,
                voiceButtonPresentation: voiceButtonPresentation,
                isVoiceInputActive: isVoiceInputActive,
                isVoiceRecording: voiceInput.isRecording,
                voiceAudioLevels: voiceInput.audioLevels,
                voiceRecordingDuration: voiceInput.recordingDuration,
                onTapVoice: handleVoiceButtonTap,
                onCancelVoiceRecording: cancelVoiceInputIfNeeded,
                onSend: sendDraft,
                showsSecondaryBar: true
            )
        }
        .animation(.easeInOut(duration: 0.18), value: voiceRecoveryPresentation?.snapshot.summary)
        .animation(.easeInOut(duration: 0.18), value: voiceInput.isRecording)
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
        voiceInput.buttonPresentation(isConnected: codex.isConnected)
    }

    private var isVoiceInputActive: Bool {
        voiceInput.isInputActive
    }

    private var voiceRecoveryPresentation: VoiceRecoveryPresentation? {
        guard let reason = voiceInput.recoveryReason,
              let resolvedReason = codex.resolveVoiceRecoveryReason(reason) else {
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

    // Focus the composer once when the draft first opens, unless the user has
    // already started typing (e.g. returning to a draft with restored text).
    private func autoFocusComposerIfNeeded() {
        guard !hasAutoFocusedComposer, viewModel.input.isEmpty else { return }
        hasAutoFocusedComposer = true
        isInputFocused = true
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

        // Worktree mode defers everything to first send: the managed worktree
        // is cut from the chosen base branch only when a message actually goes out.
        var makeWorktreeThread: (@MainActor @Sendable () async throws -> CodexThread)?
        if draftRuntimeMode == .newWorktree,
           showsGitContextRows,
           let projectPath = selectedProjectPath {
            // Match what the branch row shows: explicit pick, else the current
            // checkout branch; only with neither does the repo default apply.
            let currentBranch = viewModel.currentGitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseBranch = selectedWorktreeBaseBranch ?? (currentBranch.isEmpty ? nil : currentBranch)
            let codex = codex
            makeWorktreeThread = {
                try await WorktreeFlowCoordinator.startNewWorktreeChat(
                    preferredProjectPath: projectPath,
                    baseBranch: baseBranch,
                    codex: codex
                )
            }
        }

        Task { @MainActor in
            await Task.yield()
            viewModel.sendNewThread(
                codex: codex,
                subscriptions: subscriptions,
                draftThreadID: route.id,
                preferredProjectPath: selectedProjectPath,
                makeThread: makeWorktreeThread,
                onThreadCreated: openThread
            )
            isDeferringSendForFocusDismissal = false
        }
    }

    // Switches the draft composer between ready, recording, and transcription states.
    private func handleVoiceButtonTap() {
        voiceInput.handleButtonTap(
            codex: codex,
            onTranscript: applyVoiceTranscript,
            onDismissInput: dismissVoiceInputFocus
        )
    }

    // User-initiated cancel clears the full voice flow, including a stop/upload race.
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

    // Losing the active scene stops draft capture; completion is best-effort while this view stays alive.
    private func handleVoiceScenePhaseChange(_ phase: ScenePhase) {
        voiceInput.handleScenePhaseChange(
            phase,
            codex: codex,
            onTranscript: applyVoiceTranscript,
            onDismissInput: dismissVoiceInputFocus
        )
    }

    // Navigation away cancels draft voice work instead of promising background completion.
    private func handleVoiceViewDisappear() {
        voiceInput.handleViewDisappear(
            scenePhase: scenePhase,
            codex: codex,
            onTranscript: applyVoiceTranscript,
            onDismissInput: dismissVoiceInputFocus
        )
    }

    // Resets the draft composer when the system invalidates the active microphone capture.
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

    private func applyVoiceTranscript(_ transcript: String) {
        viewModel.appendVoiceTranscript(transcript)
        viewModel.saveLocalDraft(codex: codex, threadID: route.id, persistToDisk: true)
    }

    private func dismissVoiceInputFocus() {
        isInputFocused = false
    }

    @ViewBuilder
    private func sheetContent(_ sheet: NewChatDraftSheet) -> some View {
        switch sheet {
        case .projectPicker:
            SidebarNewChatProjectPickerSheet(
                choices: projectChoices,
                // Fallback sheet path stays folder-only; Quick Chat is not part of the folder picker.
                showsWithoutProjectOption: false,
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
