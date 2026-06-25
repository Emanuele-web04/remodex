// FILE: SidebarThreadListView.swift
// Purpose: Renders sidebar project/rootless thread groups and empty states.
// Layer: View Component
// Exports: SidebarThreadListView

import SwiftUI

struct SidebarThreadListView: View {
    var isFiltering: Bool = false
    let isConnected: Bool
    let isCreatingThread: Bool
    let threads: [CodexThread]
    let groups: [SidebarThreadGroup]
    let selectedThread: CodexThread?
    let bottomContentInset: CGFloat
    var emptyStateTitle: String = "No conversations"
    var emptyFilterTitle: String = "No matching conversations"
    var projectlessRootPaths: [String] = []
    let timingLabelProvider: (CodexThread) -> String?
    var showsTimestampRefreshIndicator: (CodexThread) -> Bool = { _ in false }
    let runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    let onSelectThread: (CodexThread) -> Void
    let onCreateThreadInProjectGroup: (SidebarThreadGroup) -> Void
    var onArchiveProjectGroup: ((SidebarThreadGroup) -> Void)? = nil
    var onDeleteProjectGroup: ((SidebarThreadGroup) -> Void)? = nil
    var onRenameThread: ((CodexThread, String) -> Void)? = nil
    var onPinToggleThread: ((CodexThread) -> Void)? = nil
    var onArchiveToggleThread: ((CodexThread) -> Void)? = nil
    var onDeleteThread: ((CodexThread) -> Void)? = nil
    @Environment(CodexService.self) private var codex
    @AppStorage(SidebarProjectExpansionState.collapsedProjectGroupIDsStorageKey) private var collapsedProjectGroupIDsStorage = ""
    @State private var expandedProjectGroupIDs: Set<String> = []
    @State private var knownProjectGroupIDs: Set<String> = []
    @State private var hasInitializedProjectGroupExpansion = false
    @State private var isPinnedExpanded = true
    @State private var isChatGroupExpanded = true
    @State private var expandedSubagentParentIDs: Set<String> = []
    // Tracks project sections whose preview cap was manually lifted with Show more.
    @State private var revealedProjectGroupIDs: Set<String> = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {

            if threads.isEmpty && !isFiltering {
                Text(isConnected ? emptyStateTitle : "Connect to view conversations")
                    .foregroundStyle(.secondary)
                    .font(AppFont.subheadline())
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
            } else if groups.flatMap(\.threads).isEmpty && isFiltering {
                Text(emptyFilterTitle)
                    .foregroundStyle(.secondary)
                    .font(AppFont.subheadline())
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
            } else {
                ForEach(groups) { group in
                    groupSection(group)
                }
            }
        }
        // Keeps the last rows reachable above the floating settings control.
        .padding(.bottom, bottomContentInset)
        .task(id: visibleSubagentThreadIDs) {
            await codex.loadSubagentThreadMetadataIfNeeded(threadIds: visibleSubagentThreadIDs)
        }
        .onAppear {
            syncExpandedProjectGroupState()
            syncRevealedProjectGroupState()
            revealSelectedThreadProjectGroup()
            revealSelectedSubagentAncestors()
        }
        .onChange(of: groups.map(\.id)) { _, _ in
            syncExpandedProjectGroupState()
            syncRevealedProjectGroupState()
            revealSelectedThreadProjectGroup()
            revealSelectedSubagentAncestors()
        }
        .onChange(of: collapsedProjectGroupIDsStorage) { _, _ in
            withAnimation(.snappy(duration: 0.22)) {
                applyPersistedProjectGroupExpansionState()
            }
        }
        .onChange(of: selectedThread?.id) { _, _ in
            revealSelectedThreadProjectGroup()
            revealSelectedSubagentAncestors()
        }
        .onChange(of: selectedSubagentAncestorIDs) { _, _ in
            revealSelectedThreadProjectGroup()
            revealSelectedSubagentAncestors()
        }
    }

    @ViewBuilder
    private func groupSection(_ group: SidebarThreadGroup) -> some View {
        switch group.kind {
        case .pinned:
            pinnedGroupSection(group)
        case .project:
            projectGroupSection(group)
        case .chat:
            chatGroupSection(group)
        }
    }

    private func pinnedGroupSection(_ group: SidebarThreadGroup) -> some View {
        let hierarchy = SidebarSubagentHierarchy(groupThreads: group.threads)

        return VStack(alignment: .leading, spacing: 0) {
            SidebarPinnedSectionHeader(
                label: group.label,
                isExpanded: isPinnedExpanded,
                onToggle: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPinnedExpanded.toggle()
                    }
                }
            )

            if isPinnedExpanded {
                SidebarThreadGroupBlock(bottomPadding: 0) {
                    VStack(spacing: 2) {
                        ForEach(hierarchy.rootThreads) { thread in
                            threadRowTree(
                                thread,
                                childrenByParentID: hierarchy.childrenByParentID,
                                pinnedRootThreadIDs: Set(hierarchy.rootThreads.map(\.id))
                            )
                        }
                    }
                }
            }
        }
    }

    private func projectGroupSection(_ group: SidebarThreadGroup) -> some View {
        let isExpanded = expandedProjectGroupIDs.contains(group.id)

        // Skip the hierarchy / preview-cap calculations entirely when the
        // group is collapsed. They were previously recomputed on every body
        // pass (selection changes, badge updates, etc.) for every project in
        // the sidebar, which dominated scroll/expand jank for users with many
        // projects.
        return VStack(alignment: .leading, spacing: 0) {
            projectHeader(group)
                .padding(.horizontal)

            if isExpanded {
                // Insertion transition is owned by `SidebarThreadGroupBlock`;
                // the surrounding `withAnimation` in
                // `toggleProjectGroupExpansion` still drives the height fold.
                expandedProjectContent(group)
            }
        }
        // `.clipped()` keeps the disappearing rows from briefly painting over
        // the next project header while SwiftUI animates the height delta.
        .clipped()
    }

    @ViewBuilder
    private func expandedProjectContent(_ group: SidebarThreadGroup) -> some View {
        let hierarchy = SidebarSubagentHierarchy(groupThreads: group.threads)
        let visibleRootThreads = SidebarProjectThreadPreviewState.visibleRootThreads(
            for: group,
            selectedThread: selectedThread,
            isFiltering: isFiltering,
            manuallyExpandedGroupIDs: revealedProjectGroupIDs
        )
        let shouldShowMoreButton = SidebarProjectThreadPreviewState.shouldShowMoreButton(
            for: group,
            selectedThread: selectedThread,
            isFiltering: isFiltering,
            manuallyExpandedGroupIDs: revealedProjectGroupIDs
        )

        // `bottomPadding: 0` keeps the gap between two adjacent project
        // sections constant regardless of whether the upper one is expanded
        // or collapsed — the next project header already provides the
        // spacing via its `.padding(.top, 18)`. Without this, an expanded
        // section added ~14pt of extra margin under its card, making the
        // sidebar visually "jump" each time a folder was toggled.
        SidebarThreadGroupBlock(bottomPadding: 0) {
            VStack(spacing: 2) {
                ForEach(visibleRootThreads) { thread in
                    threadRowTree(
                        thread,
                        childrenByParentID: hierarchy.childrenByParentID
                    )
                }

                if shouldShowMoreButton {
                    let totalRootCount = SidebarProjectThreadPreviewState.rootThreads(in: group.threads).count
                    let hiddenCount = totalRootCount - visibleRootThreads.count
                    SidebarProjectShowMoreButton(hiddenCount: hiddenCount) {
                        revealedProjectGroupIDs.insert(group.id)
                    }
                }
            }
        }
    }

    private func projectHeader(_ group: SidebarThreadGroup) -> some View {
        SidebarProjectSectionHeader(
            group: group,
            isExpanded: expandedProjectGroupIDs.contains(group.id),
            isConnected: isConnected,
            isCreatingThread: isCreatingThread,
            onToggle: { toggleProjectGroupExpansion(group.id) },
            onCreate: { onCreateThreadInProjectGroup(group) },
            onArchive: onArchiveProjectGroup.map { handler in { handler(group) } },
            onDelete: onDeleteProjectGroup.map { handler in { handler(group) } }
        )
    }

    // Rootless chats reuse the project header so the icon + label + new-chat
    // affordance reads consistently. Toggling collapses just this section; the
    // create button calls back into the parent's rootless chat creator.
    private func chatGroupSection(_ group: SidebarThreadGroup) -> some View {
        let hierarchy = SidebarSubagentHierarchy(groupThreads: group.threads)

        return VStack(alignment: .leading, spacing: 0) {
            SidebarProjectSectionHeader(
                group: group,
                isExpanded: isChatGroupExpanded,
                isConnected: isConnected,
                isCreatingThread: isCreatingThread,
                onToggle: {
                    withAnimation(.snappy(duration: 0.22)) {
                        isChatGroupExpanded.toggle()
                    }
                },
                onCreate: { onCreateThreadInProjectGroup(group) }
            )
            .padding(.horizontal)

            if isChatGroupExpanded {
                // Same `bottomPadding: 0` rationale as project sections:
                // the next sibling header owns the inter-section spacing,
                // so expanding/collapsing the rootless Chats block should
                // not shift everything below it.
                SidebarThreadGroupBlock(bottomPadding: 0) {
                    VStack(spacing: 2) {
                        ForEach(hierarchy.rootThreads) { thread in
                            threadRowTree(
                                thread,
                                childrenByParentID: hierarchy.childrenByParentID
                            )
                        }
                    }
                }
            }
        }
        .clipped()
    }

    private func threadRowTree(
        _ thread: CodexThread,
        childrenByParentID: [String: [CodexThread]],
        ancestorThreadIDs: Set<String> = [],
        pinnedRootThreadIDs: Set<String> = []
    ) -> AnyView {
        let childThreads = childrenByParentID[thread.id] ?? []
        let isExpanded = expandedSubagentParentIDs.contains(thread.id)
        let nextAncestorThreadIDs = ancestorThreadIDs.union([thread.id])

        return AnyView(VStack(alignment: .leading, spacing: thread.isSubagent ? 2 : 4) {
            threadRow(
                thread,
                isPinnedRow: pinnedRootThreadIDs.contains(thread.id),
                childSubagentCount: childThreads.count,
                isSubagentExpanded: isExpanded,
                onToggleSubagents: childThreads.isEmpty ? nil : {
                    toggleSubagentExpansion(parentThreadID: thread.id)
                }
            )

            if isExpanded, !childThreads.isEmpty {
                VStack(spacing: 2) {
                    ForEach(childThreads) { childThread in
                        if nextAncestorThreadIDs.contains(childThread.id) {
                            AnyView(threadRow(childThread))
                        } else {
                            threadRowTree(
                                childThread,
                                childrenByParentID: childrenByParentID,
                                ancestorThreadIDs: nextAncestorThreadIDs,
                                pinnedRootThreadIDs: pinnedRootThreadIDs
                            )
                        }
                    }
                }
                // Match project-group expansion: fade the inserted rows while the
                // outer stack animates height, instead of sliding through siblings.
                .transition(.opacity)
            }
        }
        .clipped())
    }

    private func threadRow(
        _ thread: CodexThread,
        isPinnedRow: Bool = false,
        childSubagentCount: Int = 0,
        isSubagentExpanded: Bool = false,
        onToggleSubagents: (() -> Void)? = nil
    ) -> some View {
        let isSelected = selectedThread?.id == thread.id

        return SidebarThreadRowView(
            thread: thread,
            isSelected: isSelected,
            runBadgeState: runBadgeStateByThreadID[thread.id],
            timingLabel: timingLabelProvider(thread),
            showsTimestampRefreshIndicator: showsTimestampRefreshIndicator(thread),
            isPinned: codex.isThreadPinned(thread.id),
            pinnedProjectLabel: isPinnedRow && !SidebarThreadGrouping.isRootlessChatThread(
                thread,
                projectlessRootPaths: projectlessRootPaths
            )
                ? thread.projectDisplayName
                : nil,
            childSubagentCount: childSubagentCount,
            isSubagentExpanded: isSubagentExpanded,
            onToggleSubagents: onToggleSubagents,
            onTap: {
                if isSelected, childSubagentCount > 0 {
                    onToggleSubagents?()
                } else {
                    onSelectThread(thread)
                }
            },
            showsBetaLabel: codex.showsBetaLabel(forProvider: thread.modelProvider ?? "codex"),
            onRename: onRenameThread.map { handler in { newName in handler(thread, newName) } },
            onPinToggle: onPinToggleThread.map { handler in { handler(thread) } },
            onArchiveToggle: onArchiveToggleThread.map { handler in { handler(thread) } },
            onDelete: onDeleteThread.map { handler in { handler(thread) } }
        )
    }

    // Preloads metadata only for subagent rows that are currently reachable in the sidebar tree.
    private var visibleSubagentThreadIDs: [String] {
        var visibleThreadIDs: [String] = []

        for group in groups {
            switch group.kind {
            case .pinned:
                guard isPinnedExpanded else { continue }
                let hierarchy = SidebarSubagentHierarchy(groupThreads: group.threads)
                for rootThread in hierarchy.rootThreads {
                    collectVisibleSubagentThreadIDs(
                        from: rootThread,
                        childrenByParentID: hierarchy.childrenByParentID,
                        ancestorThreadIDs: [],
                        into: &visibleThreadIDs
                    )
                }
            case .project:
                guard expandedProjectGroupIDs.contains(group.id) else { continue }
                let hierarchy = SidebarSubagentHierarchy(groupThreads: group.threads)
                let visibleRootThreads = SidebarProjectThreadPreviewState.visibleRootThreads(
                    for: group,
                    selectedThread: selectedThread,
                    isFiltering: isFiltering,
                    manuallyExpandedGroupIDs: revealedProjectGroupIDs
                )
                for rootThread in visibleRootThreads {
                    collectVisibleSubagentThreadIDs(
                        from: rootThread,
                        childrenByParentID: hierarchy.childrenByParentID,
                        ancestorThreadIDs: [],
                        into: &visibleThreadIDs
                    )
                }
            case .chat:
                guard isChatGroupExpanded else { continue }
                let hierarchy = SidebarSubagentHierarchy(groupThreads: group.threads)
                for rootThread in hierarchy.rootThreads {
                    collectVisibleSubagentThreadIDs(
                        from: rootThread,
                        childrenByParentID: hierarchy.childrenByParentID,
                        ancestorThreadIDs: [],
                        into: &visibleThreadIDs
                    )
                }
            }
        }

        return visibleThreadIDs
    }

    private var selectedSubagentAncestorIDs: Set<String> {
        guard let selectedThread else { return [] }
        return subagentAncestorIDs(for: selectedThread)
    }

    private func collectVisibleSubagentThreadIDs(
        from thread: CodexThread,
        childrenByParentID: [String: [CodexThread]],
        ancestorThreadIDs: Set<String>,
        into visibleThreadIDs: inout [String]
    ) {
        if thread.isSubagent {
            visibleThreadIDs.append(thread.id)
        }

        guard expandedSubagentParentIDs.contains(thread.id) else {
            return
        }

        let nextAncestorThreadIDs = ancestorThreadIDs.union([thread.id])
        for childThread in childrenByParentID[thread.id] ?? [] {
            guard !nextAncestorThreadIDs.contains(childThread.id) else { continue }
            collectVisibleSubagentThreadIDs(
                from: childThread,
                childrenByParentID: childrenByParentID,
                ancestorThreadIDs: nextAncestorThreadIDs,
                into: &visibleThreadIDs
            )
        }
    }

    private func toggleProjectGroupExpansion(_ groupID: String) {
        withAnimation(.snappy(duration: 0.22)) {
            var persistedCollapsedGroupIDs = SidebarProjectExpansionState.decodePersistedGroupIDs(
                collapsedProjectGroupIDsStorage
            )
            if expandedProjectGroupIDs.contains(groupID) {
                expandedProjectGroupIDs.remove(groupID)
                revealedProjectGroupIDs.remove(groupID)
                persistedCollapsedGroupIDs.insert(groupID)
            } else {
                expandedProjectGroupIDs.insert(groupID)
                persistedCollapsedGroupIDs.remove(groupID)
            }
            collapsedProjectGroupIDsStorage = SidebarProjectExpansionState.encodePersistedGroupIDs(
                persistedCollapsedGroupIDs
            )
        }
    }

    // Keep project sections expanded after regrouping so live updates do not collapse the sidebar.
    private func syncExpandedProjectGroupState() {
        let nextState = SidebarProjectExpansionState.synchronizedState(
            currentExpandedGroupIDs: expandedProjectGroupIDs,
            knownGroupIDs: knownProjectGroupIDs,
            visibleGroups: groups,
            hasInitialized: hasInitializedProjectGroupExpansion,
            persistedCollapsedGroupIDs: SidebarProjectExpansionState.decodePersistedGroupIDs(
                collapsedProjectGroupIDsStorage
            )
        )
        expandedProjectGroupIDs = nextState.expandedGroupIDs
        knownProjectGroupIDs = nextState.knownGroupIDs
        hasInitializedProjectGroupExpansion = true
    }

    // Applies bulk changes from the chip-row control immediately; regular sync
    // preserves in-memory folds, while this treats AppStorage as the source of truth.
    private func applyPersistedProjectGroupExpansionState() {
        let visibleProjectGroupIDs = SidebarProjectExpansionState.projectGroupIDs(in: groups)
        let persistedCollapsedGroupIDs = SidebarProjectExpansionState.decodePersistedGroupIDs(
            collapsedProjectGroupIDsStorage
        )

        expandedProjectGroupIDs = visibleProjectGroupIDs.subtracting(persistedCollapsedGroupIDs)
        knownProjectGroupIDs = visibleProjectGroupIDs
        hasInitializedProjectGroupExpansion = true
        revealedProjectGroupIDs = revealedProjectGroupIDs.intersection(expandedProjectGroupIDs)
    }

    // Keeps Show more expansion state only for project groups that still exist on screen.
    private func syncRevealedProjectGroupState() {
        let visibleProjectGroupIDs = SidebarProjectExpansionState.projectGroupIDs(in: groups)
        revealedProjectGroupIDs = revealedProjectGroupIDs.intersection(visibleProjectGroupIDs)
    }

    // Keeps an externally selected thread visible without re-opening unrelated project groups.
    private func revealSelectedThreadProjectGroup() {
        if let selectedGroupID = SidebarProjectExpansionState.groupIDContainingSelectedThread(
            selectedThread,
            in: groups
        ),
           SidebarProjectExpansionState.shouldAutoRevealSelectedGroup(
               selectedGroupID,
               persistedCollapsedGroupIDs: SidebarProjectExpansionState.decodePersistedGroupIDs(
                   collapsedProjectGroupIDsStorage
               )
        ) {
            expandedProjectGroupIDs.insert(selectedGroupID)
        }
    }

    private func toggleSubagentExpansion(parentThreadID: String) {
        withAnimation(.snappy(duration: 0.22)) {
            if expandedSubagentParentIDs.contains(parentThreadID) {
                expandedSubagentParentIDs.remove(parentThreadID)
            } else {
                expandedSubagentParentIDs.insert(parentThreadID)
            }
        }
    }

    // Expands every visible ancestor so a selected child thread is never hidden in the tree.
    private func revealSelectedSubagentAncestors() {
        guard let selectedThread else { return }
        expandedSubagentParentIDs.formUnion(subagentAncestorIDs(for: selectedThread))
    }

    private func subagentAncestorIDs(for thread: CodexThread) -> Set<String> {
        let threadsByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        var ancestorIDs: Set<String> = []
        var currentParentID = thread.parentThreadId

        while let parentID = currentParentID, !ancestorIDs.contains(parentID) {
            ancestorIDs.insert(parentID)
            currentParentID = threadsByID[parentID]?.parentThreadId
        }

        return ancestorIDs
    }
}

// MARK: - Preview fixtures (UI iteration)
//
// Mirrors the screenshot layout: a Pinned section and two project sections
// (`omnara-voice` and `phodex-bridge`) with several chats each. Edit
// `SidebarThreadGroupBlock` to iterate on the block look; this preview will
// reflect changes without needing to launch the simulator.

private enum SidebarThreadListPreviewFixtures {
    static let now = Date()

    static func ago(_ minutes: Int) -> Date {
        now.addingTimeInterval(TimeInterval(-minutes * 60))
    }

    static let pinnedThread = CodexThread(
        id: "pinned-1",
        title: "Investigate flaky tests",
        createdAt: ago(720),
        updatedAt: ago(8),
        cwd: "/Users/dev/phodex-bridge"
    )

    static let omnaraThreads: [CodexThread] = [
        CodexThread(id: "om-1", title: "Create Landing Page with AI Stuff", createdAt: ago(180), updatedAt: ago(2), cwd: "/Users/dev/omnara-voice"),
        CodexThread(id: "om-2", title: "Create Landing Page with AI Stuff", createdAt: ago(170), updatedAt: ago(2), cwd: "/Users/dev/omnara-voice"),
        CodexThread(id: "om-3", title: "Landing Page", createdAt: ago(160), updatedAt: ago(2), cwd: "/Users/dev/omnara-voice"),
        CodexThread(id: "om-4", title: "App's UI", createdAt: ago(150), updatedAt: ago(2), cwd: "/Users/dev/omnara-voice"),
        CodexThread(id: "om-5", title: "Backend", createdAt: ago(140), updatedAt: ago(2), cwd: "/Users/dev/omnara-voice"),
    ]

    static let bridgeThreads: [CodexThread] = [
        CodexThread(id: "br-1", title: "Investigate flaky tests", createdAt: ago(800), updatedAt: ago(8), cwd: "/Users/dev/phodex-bridge"),
        CodexThread(id: "br-2", title: "Refactor relay session store", createdAt: ago(900), updatedAt: ago(45), cwd: "/Users/dev/phodex-bridge"),
        CodexThread(id: "br-3", title: "Wire QR pairing flow", createdAt: ago(1500), updatedAt: ago(220), cwd: "/Users/dev/phodex-bridge"),
    ]

    static let allThreads: [CodexThread] =
        [pinnedThread] + omnaraThreads + bridgeThreads

    static let groups: [SidebarThreadGroup] = [
        SidebarThreadGroup(
            id: "pinned",
            label: "Pinned",
            kind: .pinned,
            sortDate: ago(8),
            projectPath: nil,
            threads: [pinnedThread]
        ),
        SidebarThreadGroup(
            id: "/Users/dev/omnara-voice",
            label: "omnara-voice",
            kind: .project,
            sortDate: ago(2),
            projectPath: "/Users/dev/omnara-voice",
            threads: omnaraThreads
        ),
        SidebarThreadGroup(
            id: "/Users/dev/phodex-bridge",
            label: "phodex-bridge",
            kind: .project,
            sortDate: ago(8),
            projectPath: "/Users/dev/phodex-bridge",
            threads: bridgeThreads
        ),
    ]

    static let runBadges: [String: CodexThreadRunBadgeState] = [
        "om-1": .running,
        "om-3": .ready,
        "br-1": .running,
        "br-2": .ready,
    ]

    static func timingLabel(for thread: CodexThread) -> String? {
        guard let updated = thread.updatedAt else { return nil }
        let seconds = Int(now.timeIntervalSince(updated))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

@MainActor
@ViewBuilder
private func sidebarThreadBlockPreviewBody() -> some View {
    ScrollView {
        SidebarThreadListView(
            isConnected: true,
            isCreatingThread: false,
            threads: SidebarThreadListPreviewFixtures.allThreads,
            groups: SidebarThreadListPreviewFixtures.groups,
            selectedThread: SidebarThreadListPreviewFixtures.omnaraThreads[2],
            bottomContentInset: 80,
            timingLabelProvider: SidebarThreadListPreviewFixtures.timingLabel,
            runBadgeStateByThreadID: SidebarThreadListPreviewFixtures.runBadges,
            onSelectThread: { _ in },
            onCreateThreadInProjectGroup: { _ in },
            onRenameThread: { _, _ in },
            onPinToggleThread: { _ in },
            onArchiveToggleThread: { _ in },
            onDeleteThread: { _ in }
        )
    }
    .background(Color(.systemBackground))
    .environment(CodexService())
}

#Preview("Sidebar Thread Block — Dark") {
    sidebarThreadBlockPreviewBody()
        .preferredColorScheme(.dark)
}

#Preview("Sidebar Thread Block — Light") {
    sidebarThreadBlockPreviewBody()
        .preferredColorScheme(.light)
}
