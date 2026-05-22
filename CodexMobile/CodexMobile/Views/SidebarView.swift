// FILE: SidebarView.swift
// Purpose: Orchestrates the sidebar experience with modular presentation components.
//          Top: brand toolbar hosted via `adaptiveTopBar` so the list scrolls
//          beneath it. On iOS 26 this resolves to `safeAreaBar(edge:.top)`,
//          which gives the bar the native Liquid Glass material + scroll-edge
//          handoff used by the chat's system navigation bar. On iOS 18 it
//          falls back to `safeAreaInset(edge:.top)` with an opaque header
//          fill so nothing regresses. Body: native scroll with search +
//          project / chat list, swapped for search + a status chip + a centered
//          connect/reconnect/scan-QR card when the relay is offline and no
//          cached chats exist. The
//          Projects/Chats scope picker routes rootless chats separately from
//          project groups. Bottom: SidebarBottomActionBar with the primary Chat
//          FAB (glass on iOS 26, accent pill on iOS 18).
// Layer: View
// Exports: SidebarView
// Depends on: CodexService, SidebarHeaderView, SidebarThreadListView,
//             SidebarBottomActionBar, SidebarSearchField,
//             SidebarConnectionEmptyStatePanel, SidebarConnectionStatusBadge,
//             SidebarConnectionEmptyStateFooter
//
// Trusted-device switching is now driven entirely from the Connections sheet
// (reached via the sidebar overflow menu), so this view no longer owns any
// switcher-specific state or callbacks.

import SwiftUI

struct SidebarView<ConnectionEmptyStatePanel: View, ConnectionEmptyStateFooter: View>: View {
    @Environment(CodexService.self) private var codex

    @Binding var selectedThread: CodexThread?
    @Binding var isSearchActive: Bool
    var showsInlineCloseButton: Bool = false
    var isVisible: Bool = true
    let connectionPhase: CodexConnectionPhase

    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onOpenDevicesSettings: () -> Void
    let onOpenTerminal: () -> Void
    let onOpenNewChatDraft: (NewChatDraftSource, String?) -> Void
    let onNewChatCreationStateChange: (Bool) -> Void
    let onOpenThread: (CodexThread) -> Void
    // Centered connect/reconnect card shown when the relay is offline and the
    // sidebar has no cached chats. ContentView owns the underlying connection
    // state and actions; the sidebar just slots the panel into the empty area.
    @ViewBuilder let connectionEmptyStatePanel: () -> ConnectionEmptyStatePanel
    // Status message + Forget Pair, pinned just above the bottom action bar
    // during the connect/reconnect empty state. ContentView owns the actions.
    @ViewBuilder let connectionEmptyStateFooter: () -> ConnectionEmptyStateFooter

    @State private var searchText = ""
    @State private var selectedContentScope: SidebarContentScope = .projects
    @State private var isCreatingThread = false
    @State private var pendingTopAction: SidebarTopAction? = nil
    @State private var groupedThreads: [SidebarThreadGroup] = []
    @State private var activeSidebarSheet: SidebarPresentedSheet?
    @State private var projectGroupPendingArchive: SidebarThreadGroup? = nil
    @State private var projectGroupPendingDeletion: SidebarThreadGroup? = nil
    @State private var threadPendingDeletion: CodexThread? = nil
    @State private var createThreadErrorMessage: String? = nil
    @State private var cachedRunBadges: [String: CodexThreadRunBadgeState] = [:]
    @State private var lastGroupedThreadsFingerprint: Int = 0
    @State private var lastBadgeFingerprint: Int = 0
    @State private var projectlessChatRootPaths: [String] = []
    @AppStorage(SidebarProjectExpansionState.collapsedProjectGroupIDsStorageKey)
    private var collapsedProjectGroupIDsStorage = ""

    var body: some View {
        // The header is hosted via `adaptiveTopBar` — `safeAreaBar(edge:.top)`
        // on iOS 26 (system-rendered Liquid Glass bar, same look as the chat
        // navigation bar) and `safeAreaInset(edge:.top)` with an opaque
        // fallback fill on iOS 18 (no Liquid Glass available). Both branches
        // let scrolled rows extend behind the bar, and the inner ScrollView's
        // `adaptiveSoftScrollEdge(for: .top)` adds the iOS 26 soft fade so
        // content gracefully blurs out under the bar's bottom edge.
        threadListWithBottomBar
            .frame(maxHeight: .infinity)
            .background(Color(.systemBackground))
            .adaptiveTopBar {
                SidebarHeaderView(
                    showsCloseButton: showsInlineCloseButton,
                    onClose: onClose,
                    overflowActions: overflowMenuActions
                )
                .modifier(SidebarHeaderBackdropModifier())
            }
            .task {
                debugSidebarLog("task start visible=\(isVisible) threadCount=\(codex.threads.count)")
                rebuildGroupedThreads()
                rebuildCachedSidebarState()
                await refreshProjectlessChatRoots()
                if codex.isConnected, codex.threads.isEmpty {
                    await refreshThreads()
                }
            }
            .onChange(of: codex.threads) { _, _ in
                debugSidebarLog(
                    "threads changed while \(isVisible ? "visible" : "hidden-prewarmed") "
                        + "threadCount=\(codex.threads.count)"
                )
                rebuildGroupedThreads()
                rebuildCachedSidebarState()
            }
            .onChange(of: searchText) { _, _ in
                debugSidebarLog("search changed queryLength=\(searchText.count)")
                rebuildGroupedThreads()
            }
            .onChange(of: selectedContentScope) { _, scope in
                debugSidebarLog("content scope changed scope=\(scope.rawValue)")
                rebuildGroupedThreads()
            }
            .onChange(of: codex.pinnedThreadIDs) { _, _ in
                debugSidebarLog("pinned threads changed count=\(codex.pinnedThreadIDs.count)")
                rebuildGroupedThreads()
            }
            .onChange(of: codex.isConnected) { _, isConnected in
                guard isConnected else { return }
                Task { @MainActor in await refreshProjectlessChatRoots() }
            }
            // Deferred to the next runloop tick so rebuilding the cache `@State`
            // does not trigger another body re-evaluation inside the same frame
            // (which previously cascaded with iOS 26 `safeAreaBar`'s internal
            // OnScrollGeometryChange and logged "tried to update multiple times
            // per frame" warnings).
            .onChange(of: badgeFingerprint) { _, _ in
                debugSidebarLog("badge fingerprint changed visible=\(isVisible)")
                Task { @MainActor in rebuildCachedRunBadges() }
            }
            .onChange(of: isVisible) { _, visible in
                debugSidebarLog("visibility changed visible=\(visible)")
            }
            .overlay {
                if SidebarThreadsLoadingPresentation.shouldShowOverlay(
                    isLoadingThreads: codex.isLoadingThreads,
                    threadCount: codex.threads.count
                ) {
                    ProgressView()
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(item: $activeSidebarSheet) { sheet in
                sidebarSheetContent(sheet)
            }
            .modifier(sidebarPromptsModifier)
    }

    // Bundles the four destructive/confirmation dialogs into a single modifier so
    // the body's modifier chain stays short enough for the Swift type-checker.
    private var sidebarPromptsModifier: SidebarPromptsModifier {
        SidebarPromptsModifier(
            projectArchiveTitle: projectGroupPendingArchive?.label ?? "project",
            projectArchivePresented: archivePromptPresented,
            confirmArchiveProjectGroup: archivePendingProjectGroup,
            cancelArchiveProjectGroup: { projectGroupPendingArchive = nil },
            projectDeleteTitle: projectGroupPendingDeletion?.label ?? "project",
            projectDeletePresented: deleteProjectPromptPresented,
            confirmDeleteProjectGroup: deletePendingProjectGroupLocally,
            cancelDeleteProjectGroup: { projectGroupPendingDeletion = nil },
            threadDeleteTitle: threadPendingDeletion?.displayTitle ?? "conversation",
            threadDeletePresented: deleteThreadPromptPresented,
            confirmDeleteThread: confirmDeletePendingThread,
            cancelDeleteThread: { threadPendingDeletion = nil },
            errorMessage: createThreadErrorMessage ?? "Please try again.",
            errorPresented: errorAlertPresented,
            dismissError: { createThreadErrorMessage = nil }
        )
    }

    private var archivePromptPresented: Binding<Bool> {
        Binding(
            get: { projectGroupPendingArchive != nil },
            set: { if !$0 { projectGroupPendingArchive = nil } }
        )
    }

    private var deleteProjectPromptPresented: Binding<Bool> {
        Binding(
            get: { projectGroupPendingDeletion != nil },
            set: { if !$0 { projectGroupPendingDeletion = nil } }
        )
    }

    private var deleteThreadPromptPresented: Binding<Bool> {
        Binding(
            get: { threadPendingDeletion != nil },
            set: { if !$0 { threadPendingDeletion = nil } }
        )
    }

    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { createThreadErrorMessage != nil },
            set: { if !$0 { createThreadErrorMessage = nil } }
        )
    }

    private func confirmDeletePendingThread() {
        guard let thread = threadPendingDeletion else { return }
        if selectedThread?.id == thread.id {
            selectedThread = nil
        }
        codex.deleteThreadLocally(thread.id)
        threadPendingDeletion = nil
    }

    // MARK: - Actions

    private func refreshThreads() async {
        guard codex.isConnected else { return }
        let startedAt = Date()
        debugSidebarLog("refreshThreads start threadCount=\(codex.threads.count)")
        do {
            try await codex.listThreads()
            debugSidebarLog(
                "refreshThreads success durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                    + "threadCount=\(codex.threads.count)"
            )
        } catch {
            debugSidebarLog(
                "refreshThreads failed durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                    + "error=\(error.localizedDescription)"
            )
            // Error stored in CodexService.
        }
    }

    private func refreshProjectlessChatRoots() async {
        guard codex.isConnected else { return }

        do {
            let roots = try await codex.fetchProjectlessChatRoots().roots
            guard roots != projectlessChatRootPaths else { return }
            projectlessChatRootPaths = roots
            rebuildGroupedThreads()
        } catch {
            // Path-pattern fallbacks still classify current Desktop defaults if the bridge is older.
            debugSidebarLog("projectless roots unavailable error=\(error.localizedDescription)")
        }
    }

    // Opens a draft composer first; the real thread is created only after the first send.
    // Seeds the draft with the latest used project so the pill under the prompt has a sensible
    // default the user can still change via the inline folder menu.
    // Regression guard: project-backed New Chat relies on
    // this path to preserve "What should we work on?" + folder picker.
    private func handleNewChatButtonTap() {
        prepareSidebarForChatNavigation()
        onOpenNewChatDraft(.generalChat, defaultNewChatProjectPath)
    }

    // Opens the global Chats scope as a plain rootless draft: no folder picker,
    // no preselected project, just the prompt and composer.
    private func handleRootlessChatDraftTap() {
        prepareSidebarForChatNavigation()
        onOpenNewChatDraft(.generalChat, nil)
    }

    // Routes the shared bottom Chat button by the active sidebar scope without
    // putting a closure ternary inside the SwiftUI view builder.
    private func handleBottomChatTap() {
        switch selectedContentScope {
        case .projects:
            handleNewChatButtonTap()
        case .chats:
            handleRootlessChatDraftTap()
        }
    }

    // Starts a chat without a working directory (cwd == nil) directly from the sidebar row.
    private func handleQuickChatTap() {
        pendingTopAction = .quickChat
        handleNewChatTap(preferredProjectPath: nil)
    }

    // Opens the local folder browser so the user can register a new project root.
    private func handleNewProjectTap() {
        presentLocalFolderBrowser()
    }

    private func presentLocalFolderBrowser() {
        activeSidebarSheet = .localFolderBrowser
    }

    private func handleNewChatTap(preferredProjectPath: String?) {
        createThreadErrorMessage = nil
        isCreatingThread = true
        prepareSidebarForChatNavigation()
        onNewChatCreationStateChange(true)
        Task { @MainActor in
            defer {
                isCreatingThread = false
                pendingTopAction = nil
                onNewChatCreationStateChange(false)
            }

            do {
                let thread = try await WorktreeFlowCoordinator.startNewLocalChat(
                    preferredProjectPath: preferredProjectPath,
                    codex: codex
                )
                onOpenThread(thread)
            } catch {
                guard let message = codex.userFacingTurnErrorMessageForFooter(from: error) else { return }
                codex.lastErrorMessage = message
                createThreadErrorMessage = message.isEmpty ? "Unable to create a chat right now." : message
            }
        }
    }

    private func handleNewWorktreeChatTap(preferredProjectPath: String) {
        createThreadErrorMessage = nil
        isCreatingThread = true
        prepareSidebarForChatNavigation()
        onNewChatCreationStateChange(true)
        Task { @MainActor in
            defer {
                isCreatingThread = false
                pendingTopAction = nil
                onNewChatCreationStateChange(false)
            }

            do {
                let thread = try await WorktreeFlowCoordinator.startNewWorktreeChat(
                    preferredProjectPath: preferredProjectPath,
                    codex: codex
                )
                onOpenThread(thread)
            } catch {
                guard let message = codex.userFacingTurnErrorMessageForFooter(from: error) else { return }
                codex.lastErrorMessage = message
                createThreadErrorMessage = message.isEmpty ? "Unable to create a worktree chat right now." : message
            }
        }
    }

    private func selectThread(_ thread: CodexThread) {
        debugSidebarLog("selectThread id=\(thread.id) title=\(thread.displayTitle)")
        prepareSidebarForChatNavigation()
        onOpenThread(thread)
    }

    private func openSettings() {
        searchText = ""
        isSearchActive = false
        onOpenSettings()
    }

    private func openTerminal() {
        searchText = ""
        isSearchActive = false
        onOpenTerminal()
    }

    // Clears sidebar-only input state before navigation so full-width search mode cannot hold the drawer open.
    private func prepareSidebarForChatNavigation() {
        searchText = ""
        isSearchActive = false
        onClose()
    }

    // Archives every live chat in the selected project group and clears the current selection if needed.
    private func archivePendingProjectGroup() {
        guard let group = projectGroupPendingArchive else { return }

        let threadIDs = SidebarThreadGrouping.liveThreadIDsForProjectGroup(group, in: codex.threads)
        let selectedThreadWasArchived = selectedThread.map { selected in
            threadIDs.contains(selected.id)
        } ?? false

        _ = codex.archiveThreadGroup(threadIDs: threadIDs)

        if selectedThreadWasArchived {
            selectedThread = codex.threads.first(where: { thread in
                thread.syncState == .live && !threadIDs.contains(thread.id)
            })
        }

        projectGroupPendingArchive = nil
    }

    // Removes every local chat for the selected project while leaving the desktop runtime untouched.
    private func deletePendingProjectGroupLocally() {
        guard let group = projectGroupPendingDeletion else { return }

        let threadIDs = SidebarThreadGrouping.allThreadIDsForProjectGroup(group, in: codex.threads)
        let selectedThreadWasDeleted = selectedThread.map { selected in
            threadIDs.contains(selected.id)
        } ?? false

        _ = codex.deleteLocalThreadGroup(threadIDs: threadIDs)

        if selectedThreadWasDeleted {
            selectedThread = codex.threads.first { thread in
                thread.syncState == .live && !threadIDs.contains(thread.id)
            }
        }

        projectGroupPendingDeletion = nil
    }

    // Rebuilds sidebar sections only when the source thread array changes.
    private func rebuildGroupedThreads() {
        let startedAt = Date()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: [CodexThread]
        if query.isEmpty {
            source = codex.threads
        } else {
            source = codex.threads.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(query)
                || ($0.preview?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.projectDisplayName.localizedCaseInsensitiveContains(query)
                || ($0.normalizedProjectPath?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        let fingerprint = groupingFingerprint(query: query, source: source)
        guard fingerprint != lastGroupedThreadsFingerprint else { return }
        lastGroupedThreadsFingerprint = fingerprint
        groupedThreads = SidebarThreadGrouping.makeGroups(
            from: source,
            pinnedThreadIDs: codex.pinnedThreadIDs,
            scope: sidebarGroupingScope,
            projectlessRootPaths: projectlessChatRootPaths
        )
        debugSidebarLog(
            "rebuildGroupedThreads durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "queryLength=\(query.count) scope=\(selectedContentScope.rawValue) "
                + "sourceCount=\(source.count) groupCount=\(groupedThreads.count)"
        )
    }

    private func groupingFingerprint(query: String, source: [CodexThread]) -> Int {
        var hasher = Hasher()
        hasher.combine(query)
        hasher.combine(selectedContentScope)
        hasher.combine(projectlessChatRootPaths)
        hasher.combine(codex.pinnedThreadIDs)
        for thread in source {
            hasher.combine(thread)
        }
        return hasher.finalize()
    }

    // Cheap fingerprint for run badge state — changes when running/ready/failed sets change.
    private var badgeFingerprint: Int {
        var hasher = Hasher()
        for thread in codex.threads {
            hasher.combine(thread.id)
            if let badge = codex.threadRunBadgeState(for: thread.id) {
                hasher.combine(badge)
            }
        }
        return hasher.finalize()
    }

    private func rebuildCachedSidebarState() {
        let startedAt = Date()
        rebuildCachedRunBadges()
        debugSidebarLog(
            "rebuildCachedSidebarState durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "runBadges=\(cachedRunBadges.count)"
        )
    }

    private func rebuildCachedRunBadges() {
        let fp = badgeFingerprint
        guard fp != lastBadgeFingerprint else { return }
        let startedAt = Date()
        lastBadgeFingerprint = fp

        var byThreadID: [String: CodexThreadRunBadgeState] = [:]
        for thread in codex.threads {
            if let state = codex.threadRunBadgeState(for: thread.id) {
                byThreadID[thread.id] = state
            }
        }
        cachedRunBadges = byThreadID
        debugSidebarLog(
            "rebuildCachedRunBadges durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "threadCount=\(codex.threads.count) cached=\(cachedRunBadges.count)"
        )
    }

    private var defaultNewChatProjectPath: String? {
        newChatProjectChoices.first?.projectPath
    }

    // Keeps the chooser in sync with the same project buckets shown in the sidebar.
    private var newChatProjectChoices: [SidebarProjectChoice] {
        SidebarThreadGrouping.makeProjectChoices(
            from: codex.threads,
            projectlessRootPaths: projectlessChatRootPaths
        )
    }

    private var sidebarGroupingScope: SidebarThreadGroupingScope {
        switch selectedContentScope {
        case .projects:
            return .projects
        case .chats:
            return .chats
        }
    }

    private var visibleProjectGroupIDs: Set<String> {
        SidebarProjectExpansionState.projectGroupIDs(in: groupedThreads)
    }

    private func areAllProjectFoldersCollapsed(_ projectGroupIDs: Set<String>) -> Bool {
        let collapsedIDs = SidebarProjectExpansionState.decodePersistedGroupIDs(
            collapsedProjectGroupIDsStorage
        )
        return !projectGroupIDs.isEmpty && projectGroupIDs.isSubset(of: collapsedIDs)
    }

    private func toggleAllProjectFolders(_ projectGroupIDs: Set<String>) {
        guard !projectGroupIDs.isEmpty else { return }

        withAnimation(.snappy(duration: 0.22)) {
            collapsedProjectGroupIDsStorage = areAllProjectFoldersCollapsed(projectGroupIDs)
                ? ""
                : SidebarProjectExpansionState.encodePersistedGroupIDs(projectGroupIDs)
        }
    }

    private var scopedSidebarThreads: [CodexThread] {
        SidebarThreadGrouping.threadsForScope(
            sidebarGroupingScope,
            from: codex.threads,
            projectlessRootPaths: projectlessChatRootPaths
        )
    }

    private var emptySidebarTitle: String {
        switch selectedContentScope {
        case .projects:
            return "No project chats"
        case .chats:
            return "No chats"
        }
    }

    private var emptySidebarFilterTitle: String {
        switch selectedContentScope {
        case .projects:
            return "No matching projects"
        case .chats:
            return "No matching chats"
        }
    }

    private var canCreateThread: Bool {
        codex.isConnected && codex.isInitialized
    }

    // Wraps the thread list with the bottom action bar. `safeAreaInset` keeps
    // the glass controls in the hit-test tree; `safeAreaBar` could render the
    // iOS 26 bar while dropping taps from the Terminal pill inside the drawer.
    @ViewBuilder
    private var threadListWithBottomBar: some View {
        if shouldShowConnectionEmptyState {
            // Stacked safe-area insets: the inner inset hosts the footer (status
            // message + Forget Pair) and ends up directly above the bottom
            // action bar, which is added by the outer inset. SwiftUI lays insets
            // bottom-up in the order they're declared.
            connectionEmptyStateLayout
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    connectionEmptyStateFooter()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomActionBar
                }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SidebarSearchField(text: $searchText, isActive: $isSearchActive)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 12)

                    sidebarScopeRow
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)

                    threadList
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomActionBar
            }
            .adaptiveSoftScrollEdge(for: .top)
        }
    }

    // Keeps search + connection status in the same top rhythm as the normal
    // Projects/Chats chips, while centering the connect panel between the
    // header and the safe-area footer.
    private var connectionEmptyStateLayout: some View {
        VStack(spacing: 0) {
            SidebarSearchField(text: $searchText, isActive: $isSearchActive)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 12)

            SidebarConnectionStatusBadge(connectionPhase: connectionPhase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Spacer(minLength: 0)

            connectionEmptyStatePanel()
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Only swap to the centered connect card on a true cold start: no cached
    // chats, no live search, and no relay session. Users with cached chats
    // keep the regular list so they can still tap through to a thread.
    private var shouldShowConnectionEmptyState: Bool {
        guard !codex.isConnected else { return false }
        guard codex.threads.isEmpty else { return false }
        guard !isSearchActive else { return false }
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedQuery.isEmpty
    }

    private var threadList: some View {
        SidebarThreadListView(
            isFiltering: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isConnected: codex.isConnected,
            isCreatingThread: isCreatingThread,
            threads: scopedSidebarThreads,
            groups: groupedThreads,
            selectedThread: selectedThread,
            bottomContentInset: 0,
            emptyStateTitle: emptySidebarTitle,
            emptyFilterTitle: emptySidebarFilterTitle,
            projectlessRootPaths: projectlessChatRootPaths,
            timingLabelProvider: { SidebarRelativeTimeFormatter.compactLabel(for: $0) },
            showsTimestampRefreshIndicator: { codex.snapshotOnlyPinnedThreadIDs.contains($0.id) },
            runBadgeStateByThreadID: cachedRunBadges,
            onSelectThread: selectThread,
            onCreateThreadInProjectGroup: { group in
                prepareSidebarForChatNavigation()
                let source: NewChatDraftSource = group.kind == .chat ? .generalChat : .folderChat
                onOpenNewChatDraft(source, group.projectPath)
            },
            onArchiveProjectGroup: { group in
                projectGroupPendingArchive = group
            },
            onDeleteProjectGroup: { group in
                projectGroupPendingDeletion = group
            },
            onRenameThread: { thread, newName in
                codex.renameThread(thread.id, name: newName)
            },
            onPinToggleThread: { thread in
                if codex.isThreadPinned(thread.id) {
                    codex.unpinThread(thread.id)
                } else {
                    codex.pinThread(thread.id)
                }
                rebuildGroupedThreads()
            },
            onArchiveToggleThread: { thread in
                if thread.syncState == .archivedLocal {
                    codex.unarchiveThread(thread.id)
                } else {
                    codex.archiveThread(thread.id)
                    if selectedThread?.id == thread.id {
                        selectedThread = nil
                    }
                }
            },
            onDeleteThread: { thread in
                threadPendingDeletion = thread
            }
        )
        .refreshable {
            await refreshThreads()
        }
    }

    // Keeps transient sync feedback inside the scope row so list fetches do not
    // add a separate row and shift the chat list vertically.
    private var sidebarScopeRow: some View {
        let projectGroupIDs = visibleProjectGroupIDs
        let shouldShowToggle = selectedContentScope == .projects && !projectGroupIDs.isEmpty
        let areAllCollapsed = areAllProjectFoldersCollapsed(projectGroupIDs)
        let shouldShowSyncStatus = SidebarThreadsLoadingPresentation.shouldShowInlineStatus(
            isLoadingThreads: codex.isLoadingThreads,
            threadCount: codex.threads.count
        )

        return HStack(spacing: 12) {
            if shouldShowSyncStatus {
                SidebarThreadsInlineLoadingView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))

                Spacer(minLength: 0)
            } else {
                SidebarContentScopePicker(selection: $selectedContentScope)
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))

                Spacer(minLength: 0)

                if shouldShowToggle {
                    SidebarFolderExpansionToggleButton(
                        areAllFoldersCollapsed: areAllCollapsed,
                        action: { toggleAllProjectFolders(projectGroupIDs) }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
    }

    private var bottomActionBar: some View {
        SidebarBottomActionBar(
            isChatEnabled: canCreateThread,
            isCreatingThread: isCreatingThread,
            // Scope matters: Projects > Chat shows the folder picker; Chats > Chat stays rootless.
            onTapChat: handleBottomChatTap,
            onTapTerminal: openTerminal
        )
    }

    private var overflowMenuActions: SidebarOverflowMenuActions {
        SidebarOverflowMenuActions(
            isEnabled: canCreateThread,
            pendingAction: pendingTopAction,
            onNewChat: handleNewChatButtonTap,
            onQuickChat: handleQuickChatTap,
            onNewProject: handleNewProjectTap,
            onOpenTerminal: openTerminal,
            onOpenConnections: onOpenDevicesSettings,
            onOpenSettings: openSettings
        )
    }

    // Sidebar refresh and search events can fire during gestures; logs must not mutate view state.
    private func debugSidebarLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard Self.isSidebarDebugLoggingEnabled else { return }
        print("[SidebarData] \(message())")
        #endif
    }
}

private extension SidebarView {
    static var isSidebarDebugLoggingEnabled: Bool { false }
}

private enum SidebarPresentedSheet: String, Identifiable {
    case newChatProjectPicker
    case localFolderBrowser

    var id: String { rawValue }
}

private extension SidebarView {
    @ViewBuilder
    func sidebarSheetContent(_ sheet: SidebarPresentedSheet) -> some View {
        switch sheet {
        case .newChatProjectPicker:
            SidebarNewChatProjectPickerSheet(
                choices: newChatProjectChoices,
                showsWithoutProjectOption: false,
                onSelectProject: { projectPath in
                    activeSidebarSheet = nil
                    handleNewChatTap(preferredProjectPath: projectPath)
                },
                onSelectWorktreeProject: { projectPath in
                    activeSidebarSheet = nil
                    handleNewWorktreeChatTap(preferredProjectPath: projectPath)
                },
                onSelectWithoutProject: {
                    activeSidebarSheet = nil
                    handleNewChatTap(preferredProjectPath: nil)
                },
                onBrowseLocalFolder: {
                    presentLocalFolderBrowser()
                }
            )
        case .localFolderBrowser:
            SidebarLocalFolderBrowserSheet { projectPath in
                activeSidebarSheet = nil
                handleNewChatTap(preferredProjectPath: projectPath)
            }
        }
    }
}

enum SidebarThreadsLoadingPresentation {
    // Keeps pull-to-refresh from stacking a second spinner over an already populated sidebar.
    static func shouldShowOverlay(isLoadingThreads: Bool, threadCount: Int) -> Bool {
        isLoadingThreads && threadCount == 0
    }

    // Populated sidebars still need feedback while the complete metadata pass is running.
    static func shouldShowInlineStatus(isLoadingThreads: Bool, threadCount: Int) -> Bool {
        isLoadingThreads && threadCount > 0
    }
}

// Paints the iOS 18 fallback fill for the sidebar header. On iOS 26 the
// outer `adaptiveTopBar` uses `safeAreaBar(edge:.top)`, which renders the
// proper Liquid Glass material itself — adding another `glassEffect` here
// would stack two layers of glass and paint a visible card-like surface.
// On iOS 18 (no `safeAreaBar`, no Liquid Glass) we paint an opaque
// `systemBackground` fill so scrolled rows don't bleed under the header.
private struct SidebarHeaderBackdropModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content.background(Color(.systemBackground))
        }
    }
}

private struct SidebarThreadsInlineLoadingView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.76)
                .frame(width: 12, height: 12)
            Text("Syncing chats")
                .font(AppFont.callout(weight: .medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .adaptiveGlass(
            .regular,
            isInteractive: false,
            fallbackMaterial: .ultraThinMaterial,
            in: Capsule(style: .continuous)
        )
        .accessibilityLabel("Syncing chats")
    }
}

// SidebarNewChatProjectPickerSheet has moved to
// Views/Sidebar/SidebarNewChatProjectPickerSheet.swift so it can carry its own
// SwiftUI #Preview without dragging in the rest of the sidebar.

// Hosts the four sidebar destructive/error prompts as a single ViewModifier so
// SidebarView's body keeps a short modifier chain the Swift type-checker can
// resolve quickly. Pass plain values + Binding<Bool>; keep no @State here.
private struct SidebarPromptsModifier: ViewModifier {
    let projectArchiveTitle: String
    let projectArchivePresented: Binding<Bool>
    let confirmArchiveProjectGroup: () -> Void
    let cancelArchiveProjectGroup: () -> Void

    let projectDeleteTitle: String
    let projectDeletePresented: Binding<Bool>
    let confirmDeleteProjectGroup: () -> Void
    let cancelDeleteProjectGroup: () -> Void

    let threadDeleteTitle: String
    let threadDeletePresented: Binding<Bool>
    let confirmDeleteThread: () -> Void
    let cancelDeleteThread: () -> Void

    let errorMessage: String
    let errorPresented: Binding<Bool>
    let dismissError: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Archive \"\(projectArchiveTitle)\"?",
                isPresented: projectArchivePresented,
                titleVisibility: .visible
            ) {
                Button("Archive Project", action: confirmArchiveProjectGroup)
                Button("Cancel", role: .cancel, action: cancelArchiveProjectGroup)
            } message: {
                Text("All active chats in this project will be archived.")
            }
            .alert(
                "Remove \"\(projectDeleteTitle)\" from this phone?",
                isPresented: projectDeletePresented
            ) {
                Button("Remove from Phone", role: .destructive, action: confirmDeleteProjectGroup)
                Button("Cancel", role: .cancel, action: cancelDeleteProjectGroup)
            } message: {
                Text("Chats for this project will be deleted only from Remodex on this phone. Nothing is removed from your device or Codex observer.")
            }
            .alert(
                "Remove \"\(threadDeleteTitle)\" from this phone?",
                isPresented: threadDeletePresented
            ) {
                Button("Remove from Phone", role: .destructive, action: confirmDeleteThread)
                Button("Cancel", role: .cancel, action: cancelDeleteThread)
            } message: {
                Text("This only removes the chat from Remodex on this phone. Nothing is removed from your device or Codex observer.")
            }
            .alert("Action failed", isPresented: errorPresented) {
                Button("OK", role: .cancel, action: dismissError)
            } message: {
                Text(errorMessage)
            }
    }
}
