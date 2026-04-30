// FILE: SidebarView.swift
// Purpose: Orchestrates the sidebar experience with modular presentation components.
// Layer: View
// Exports: SidebarView
// Depends on: CodexService, Sidebar* components/helpers

import SwiftUI

struct SidebarView: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.colorScheme) private var colorScheme

    @Binding var selectedThread: CodexThread?
    @Binding var showSettings: Bool
    @Binding var isSearchActive: Bool
    var showsInlineCloseButton: Bool = false
    var isVisible: Bool = true

    let onClose: () -> Void
    let onOpenThread: (CodexThread) -> Void

    @State private var searchText = ""
    @State private var isCreatingThread = false
    @State private var groupedThreads: [SidebarThreadGroup] = []
    @State private var activeSidebarSheet: SidebarPresentedSheet?
    @State private var projectGroupPendingArchive: SidebarThreadGroup? = nil
    @State private var projectGroupPendingDeletion: SidebarThreadGroup? = nil
    @State private var threadPendingDeletion: CodexThread? = nil
    @State private var createThreadErrorMessage: String? = nil
    @State private var cachedDiffTotals: [String: TurnSessionDiffTotals] = [:]
    @State private var cachedDiffRevisionByThreadID: [String: Int] = [:]
    @State private var cachedRunBadges: [String: CodexThreadRunBadgeState] = [:]
    @State private var lastGroupedThreadsFingerprint: Int = 0
    @State private var lastDiffFingerprint: Int = 0
    @State private var lastBadgeFingerprint: Int = 0

    var body: some View {
        let diffTotalsByThreadID = cachedDiffTotals

        VStack(alignment: .leading, spacing: 0) {
            SidebarHeaderView(
                showsCloseButton: showsInlineCloseButton,
                onClose: onClose
            )

            SidebarSearchField(text: $searchText, isActive: $isSearchActive)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

            SidebarNewChatButton(
                isCreatingThread: isCreatingThread,
                isEnabled: canCreateThread,
                statusMessage: nil,
                action: handleNewChatButtonTap
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            SidebarThreadListView(
                isFiltering: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isConnected: codex.isConnected,
                isCreatingThread: isCreatingThread,
                threads: codex.threads,
                groups: groupedThreads,
                selectedThread: selectedThread,
                bottomContentInset: 0,
                timingLabelProvider: { SidebarRelativeTimeFormatter.compactLabel(for: $0) },
                diffTotalsByThreadID: diffTotalsByThreadID,
                runBadgeStateByThreadID: cachedRunBadges,
                onSelectThread: selectThread,
                onCreateThreadInProjectGroup: { group in
                    handleNewChatTap(preferredProjectPath: group.projectPath)
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

            HStack(spacing: 10) {
                SidebarFloatingSettingsButton(colorScheme: colorScheme, action: openSettings)
                Spacer(minLength: 0)
                if let trustedPairPresentation = codex.trustedPairPresentation {
                    SidebarComputerConnectionStatusView(
                        name: trustedPairPresentation.name,
                        systemName: trustedPairPresentation.systemName,
                        isConnected: codex.isConnected
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task {
            debugSidebarLog("task start visible=\(isVisible) threadCount=\(codex.threads.count)")
            rebuildGroupedThreads()
            rebuildCachedSidebarState()
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
        .onChange(of: codex.pinnedThreadIDs) { _, _ in
            debugSidebarLog("pinned threads changed count=\(codex.pinnedThreadIDs.count)")
            rebuildGroupedThreads()
        }
        .onChange(of: diffFingerprint) { _, _ in
            debugSidebarLog("diff fingerprint changed visible=\(isVisible)")
            rebuildCachedDiffTotals()
        }
        .onChange(of: badgeFingerprint) { _, _ in
            debugSidebarLog("badge fingerprint changed visible=\(isVisible)")
            rebuildCachedRunBadges()
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
        .confirmationDialog(
            "Archive \"\(projectGroupPendingArchive?.label ?? "project")\"?",
            isPresented: Binding(
                get: { projectGroupPendingArchive != nil },
                set: { if !$0 { projectGroupPendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Archive Project") {
                archivePendingProjectGroup()
            }
            Button("Cancel", role: .cancel) {
                projectGroupPendingArchive = nil
            }
        } message: {
            Text("All active chats in this project will be archived.")
        }
        .alert(
            "Remove \"\(projectGroupPendingDeletion?.label ?? "project")\" from this phone?",
            isPresented: Binding(
                get: { projectGroupPendingDeletion != nil },
                set: { if !$0 { projectGroupPendingDeletion = nil } }
            )
        ) {
            Button("Remove from Phone", role: .destructive) {
                deletePendingProjectGroupLocally()
            }
            Button("Cancel", role: .cancel) {
                projectGroupPendingDeletion = nil
            }
        } message: {
            Text("Chats for this project will be deleted only from Remodex on this phone. Nothing is removed from your computer or Codex observer.")
        }
        .alert(
            "Remove \"\(threadPendingDeletion?.displayTitle ?? "conversation")\" from this phone?",
            isPresented: Binding(
                get: { threadPendingDeletion != nil },
                set: { if !$0 { threadPendingDeletion = nil } }
            )
        ) {
            Button("Remove from Phone", role: .destructive) {
                if let thread = threadPendingDeletion {
                    if selectedThread?.id == thread.id {
                        selectedThread = nil
                    }
                    codex.deleteThreadLocally(thread.id)
                }
                threadPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                threadPendingDeletion = nil
            }
        } message: {
            Text("This only removes the chat from Remodex on this phone. Nothing is removed from your computer or Codex observer.")
        }
        .alert(
            "Action failed",
            isPresented: Binding(
                get: { createThreadErrorMessage != nil },
                set: { if !$0 { createThreadErrorMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    createThreadErrorMessage = nil
                }
            },
            message: {
                Text(createThreadErrorMessage ?? "Please try again.")
            }
        )
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

    // Shows a native sheet so folder names and full paths stay readable on small screens.
    private func handleNewChatButtonTap() {
        activeSidebarSheet = .newChatProjectPicker
    }

    private func presentLocalFolderBrowser() {
        activeSidebarSheet = .localFolderBrowser
    }

    private func handleNewChatTap(preferredProjectPath: String?) {
        prepareSidebarForChatNavigation()
        Task { @MainActor in
            createThreadErrorMessage = nil
            isCreatingThread = true
            defer { isCreatingThread = false }

            do {
                let thread = try await WorktreeFlowCoordinator.startNewLocalChat(
                    preferredProjectPath: preferredProjectPath,
                    codex: codex
                )
                onOpenThread(thread)
            } catch {
                let message = error.localizedDescription
                codex.lastErrorMessage = message
                createThreadErrorMessage = message.isEmpty ? "Unable to create a chat right now." : message
            }
        }
    }

    private func handleNewWorktreeChatTap(preferredProjectPath: String) {
        prepareSidebarForChatNavigation()
        Task { @MainActor in
            createThreadErrorMessage = nil
            isCreatingThread = true
            defer { isCreatingThread = false }

            do {
                let thread = try await WorktreeFlowCoordinator.startNewWorktreeChat(
                    preferredProjectPath: preferredProjectPath,
                    codex: codex
                )
                onOpenThread(thread)
            } catch {
                let message = error.localizedDescription
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
        showSettings = true
        onClose()
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
        groupedThreads = SidebarThreadGrouping.makeGroups(from: source, pinnedThreadIDs: codex.pinnedThreadIDs)
        debugSidebarLog(
            "rebuildGroupedThreads durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "queryLength=\(query.count) sourceCount=\(source.count) groupCount=\(groupedThreads.count)"
        )
    }

    private func groupingFingerprint(query: String, source: [CodexThread]) -> Int {
        var hasher = Hasher()
        hasher.combine(query)
        hasher.combine(codex.pinnedThreadIDs)
        for thread in source {
            hasher.combine(thread)
        }
        return hasher.finalize()
    }

    // Cheap fingerprint: hashes thread IDs + message revisions (O(n) integer work, no message access).
    private var diffFingerprint: Int {
        var hasher = Hasher()
        let hasRunningTurn = codex.hasAnyRunningTurn
        hasher.combine(hasRunningTurn)
        guard !hasRunningTurn else {
            return hasher.finalize()
        }
        for thread in codex.threads {
            hasher.combine(thread.id)
            hasher.combine(codex.messageRevision(for: thread.id))
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
        rebuildCachedDiffTotals()
        rebuildCachedRunBadges()
        debugSidebarLog(
            "rebuildCachedSidebarState durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "diffTotals=\(cachedDiffTotals.count) runBadges=\(cachedRunBadges.count)"
        )
    }

    private func rebuildCachedDiffTotals() {
        let fp = diffFingerprint
        guard fp != lastDiffFingerprint else { return }
        // Keep streaming smooth: diff totals are sidebar-only and can wait until active runs settle.
        guard !codex.hasAnyRunningTurn else {
            debugSidebarLog("rebuildCachedDiffTotals skipped runningTurn=true")
            return
        }
        let startedAt = Date()
        lastDiffFingerprint = fp

        let currentThreadIDs = Set(codex.threads.map(\.id))
        cachedDiffTotals = cachedDiffTotals.filter { currentThreadIDs.contains($0.key) }
        cachedDiffRevisionByThreadID = cachedDiffRevisionByThreadID.filter { currentThreadIDs.contains($0.key) }

        for thread in codex.threads {
            let revision = codex.messageRevision(for: thread.id)
            guard cachedDiffRevisionByThreadID[thread.id] != revision else { continue }

            let messages = codex.messages(for: thread.id)
            cachedDiffTotals[thread.id] = TurnSessionDiffSummaryCalculator.totals(
                from: messages,
                scope: .unpushedSession
            )
            cachedDiffRevisionByThreadID[thread.id] = revision
        }
        debugSidebarLog(
            "rebuildCachedDiffTotals durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) "
                + "threadCount=\(codex.threads.count) cached=\(cachedDiffTotals.count)"
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

    // Keeps the chooser in sync with the same project buckets shown in the sidebar.
    private var newChatProjectChoices: [SidebarProjectChoice] {
        SidebarThreadGrouping.makeProjectChoices(from: codex.threads)
    }

    private var canCreateThread: Bool {
        codex.isConnected && codex.isInitialized
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
}

// SidebarNewChatProjectPickerSheet has moved to
// Views/Sidebar/SidebarNewChatProjectPickerSheet.swift so it can carry its own
// SwiftUI #Preview without dragging in the rest of the sidebar.
