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

    let onClose: () -> Void

    @State private var searchText = ""
    @State private var isCreatingThread = false
    @State private var groupedThreads: [SidebarThreadGroup] = []
    @State private var isShowingNewChatProjectPicker = false
    @State private var projectGroupPendingArchive: SidebarThreadGroup? = nil
    @State private var threadPendingDeletion: CodexThread? = nil
    @State private var createThreadErrorMessage: String? = nil
    @State private var cachedDiffTotals: [String: TurnSessionDiffTotals] = [:]
    @State private var cachedRunBadges: [String: CodexThreadRunBadgeState] = [:]
    @State private var lastDiffFingerprint: Int = 0
    @State private var lastBadgeFingerprint: Int = 0

    var body: some View {
        let diffTotalsByThreadID = cachedDiffTotals

        VStack(alignment: .leading, spacing: 0) {
            SidebarHeaderView()

            SidebarSearchField(text: $searchText, isActive: $isSearchActive)
                .padding(.horizontal, 16)
                .padding(.top, 6)
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
                onRenameThread: { thread, newName in
                    codex.renameThread(thread.id, name: newName)
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
                    SidebarMacConnectionStatusView(
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
            rebuildGroupedThreads()
            rebuildCachedSidebarState()
            if codex.isConnected, codex.threads.isEmpty {
                await refreshThreads()
            }
        }
        .onChange(of: codex.threads) { _, _ in
            rebuildGroupedThreads()
            rebuildCachedSidebarState()
        }
        .onChange(of: searchText) { _, _ in
            rebuildGroupedThreads()
        }
        .onChange(of: diffFingerprint) { _, _ in
            rebuildCachedDiffTotals()
        }
        .onChange(of: badgeFingerprint) { _, _ in
            rebuildCachedRunBadges()
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
        .sheet(isPresented: $isShowingNewChatProjectPicker) {
            SidebarNewChatProjectPickerSheet(
                choices: newChatProjectChoices,
                onSelectProject: { projectPath in
                    handleNewChatTap(preferredProjectPath: projectPath)
                },
                onSelectWithoutProject: {
                    handleNewChatTap(preferredProjectPath: nil)
                }
            )
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
        .confirmationDialog(
            "Delete \"\(threadPendingDeletion?.displayTitle ?? "conversation")\"?",
            isPresented: Binding(
                get: { threadPendingDeletion != nil },
                set: { if !$0 { threadPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let thread = threadPendingDeletion {
                    if selectedThread?.id == thread.id {
                        selectedThread = nil
                    }
                    codex.deleteThread(thread.id)
                }
                threadPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                threadPendingDeletion = nil
            }
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
        do {
            try await codex.listThreads()
        } catch {
            // Error stored in CodexService.
        }
    }

    // Shows a native sheet so folder names and full paths stay readable on small screens.
    private func handleNewChatButtonTap() {
        if newChatProjectChoices.isEmpty {
            handleNewChatTap(preferredProjectPath: nil)
            return
        }

        isShowingNewChatProjectPicker = true
    }

    private func handleNewChatTap(preferredProjectPath: String?) {
        Task { @MainActor in
            guard codex.isConnected else {
                createThreadErrorMessage = "Connect to runtime first."
                return
            }
            guard codex.isInitialized else {
                createThreadErrorMessage = "Runtime is still initializing. Wait a moment and retry."
                return
            }

            createThreadErrorMessage = nil
            isCreatingThread = true
            defer { isCreatingThread = false }

            do {
                let thread = try await codex.startThread(preferredProjectPath: preferredProjectPath)
                selectedThread = thread
                onClose()
            } catch {
                let message = error.localizedDescription
                codex.lastErrorMessage = message
                createThreadErrorMessage = message.isEmpty ? "Unable to create a chat right now." : message
            }
        }
    }

    private func selectThread(_ thread: CodexThread) {
        searchText = ""
        codex.activeThreadId = thread.id
        codex.markThreadAsViewed(thread.id)
        selectedThread = thread
        onClose()
    }

    private func openSettings() {
        searchText = ""
        showSettings = true
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

    // Rebuilds sidebar sections only when the source thread array changes.
    private func rebuildGroupedThreads() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: [CodexThread]
        if query.isEmpty {
            source = codex.threads
        } else {
            source = codex.threads.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.projectDisplayName.localizedCaseInsensitiveContains(query)
            }
        }
        groupedThreads = SidebarThreadGrouping.makeGroups(from: source)
    }

    // Cheap fingerprint: hashes thread IDs + message revisions (O(n) integer work, no message access).
    private var diffFingerprint: Int {
        var hasher = Hasher()
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
        rebuildCachedDiffTotals()
        rebuildCachedRunBadges()
    }

    private func rebuildCachedDiffTotals() {
        let fp = diffFingerprint
        guard fp != lastDiffFingerprint else { return }
        lastDiffFingerprint = fp

        var byThreadID: [String: TurnSessionDiffTotals] = [:]
        for thread in codex.threads {
            let messages = codex.messages(for: thread.id)
            if let totals = TurnSessionDiffSummaryCalculator.totals(
                from: messages,
                scope: .unpushedSession
            ) {
                byThreadID[thread.id] = totals
            }
        }
        cachedDiffTotals = byThreadID
    }

    private func rebuildCachedRunBadges() {
        let fp = badgeFingerprint
        guard fp != lastBadgeFingerprint else { return }
        lastBadgeFingerprint = fp

        var byThreadID: [String: CodexThreadRunBadgeState] = [:]
        for thread in codex.threads {
            if let state = codex.threadRunBadgeState(for: thread.id) {
                byThreadID[thread.id] = state
            }
        }
        cachedRunBadges = byThreadID
    }

    // Keeps the chooser in sync with the same project buckets shown in the sidebar.
    private var newChatProjectChoices: [SidebarProjectChoice] {
        SidebarThreadGrouping.makeProjectChoices(from: codex.threads)
    }

    private var canCreateThread: Bool {
        codex.isConnected && codex.isInitialized
    }
}

enum SidebarThreadsLoadingPresentation {
    // Keeps pull-to-refresh from stacking a second spinner over an already populated sidebar.
    static func shouldShowOverlay(isLoadingThreads: Bool, threadCount: Int) -> Bool {
        isLoadingThreads && threadCount == 0
    }
}

private struct SidebarNewChatProjectPickerSheet: View {
    let choices: [SidebarProjectChoice]
    let onSelectProject: (String) -> Void
    let onSelectWithoutProject: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose a project for this chat.")
                        .font(AppFont.body())
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("Projects") {
                    ForEach(choices) { choice in
                        Button {
                            dismiss()
                            onSelectProject(choice.projectPath)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: choice.iconSystemName)
                                    .font(AppFont.body(weight: .medium))
                                    .foregroundStyle(.secondary)

                                Text(choice.label)
                                    .font(AppFont.body(weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
                    Button {
                        dismiss()
                        onSelectWithoutProject()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "plus.bubble")
                                .font(AppFont.body(weight: .medium))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("No Project")
                                    .font(AppFont.body(weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("Start a chat without a working directory.")
                                    .font(AppFont.body())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    // Explains the existing scoping rule at the exact moment the user chooses it.
                    Text("Chats started in a project stay scoped to that working directory. If you pick No Project, the chat is global.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Start new chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents(choices.count > 4 ? [.medium, .large] : [.medium])
    }
}
