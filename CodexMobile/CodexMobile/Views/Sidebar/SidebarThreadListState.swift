// FILE: SidebarThreadListState.swift
// Purpose: Pure state helpers for sidebar project previews, subagent hierarchy, and expansion.
// Layer: Sidebar UI state
// Exports: SidebarProjectThreadPreviewState, SidebarSubagentHierarchy, SidebarProjectExpansionState
// Depends on: Foundation, CodexThread, SidebarThreadGroup

import Foundation

enum SidebarProjectThreadPreviewState {
    static let collapsedRootThreadLimit = 6

    // Caps each project section to the latest root conversations until the user expands it.
    static func visibleRootThreads(
        for group: SidebarThreadGroup,
        selectedThread: CodexThread?,
        isFiltering: Bool,
        manuallyExpandedGroupIDs: Set<String>
    ) -> [CodexThread] {
        let rootThreads = rootThreads(in: group.threads)
        if shouldRevealAllRootThreads(
            for: group,
            rootThreads: rootThreads,
            selectedThread: selectedThread,
            isFiltering: isFiltering,
            manuallyExpandedGroupIDs: manuallyExpandedGroupIDs
        ) {
            return rootThreads
        }

        return Array(rootThreads.prefix(collapsedRootThreadLimit))
    }

    static func shouldShowMoreButton(
        for group: SidebarThreadGroup,
        selectedThread: CodexThread?,
        isFiltering: Bool,
        manuallyExpandedGroupIDs: Set<String>
    ) -> Bool {
        let rootThreads = rootThreads(in: group.threads)
        guard group.kind == .project,
              rootThreads.count > collapsedRootThreadLimit,
              !isFiltering,
              !manuallyExpandedGroupIDs.contains(group.id) else {
            return false
        }

        return !selectedThreadRequiresExpansion(
            selectedThread,
            in: group,
            rootThreads: rootThreads
        )
    }

    // Root order matches the sidebar tree order, so previewing keeps parent/subagent layout stable.
    static func rootThreads(in groupThreads: [CodexThread]) -> [CodexThread] {
        let groupThreadIDs = Set(groupThreads.map(\.id))
        return groupThreads.filter { thread in
            guard let parentThreadID = thread.parentThreadId else {
                return true
            }

            return !groupThreadIDs.contains(parentThreadID)
        }
    }

    // Keeps the active conversation visible when it would otherwise land below the preview cap.
    static func selectedThreadRequiresExpansion(
        _ selectedThread: CodexThread?,
        in group: SidebarThreadGroup,
        rootThreads: [CodexThread]? = nil
    ) -> Bool {
        guard let selectedThread, group.contains(selectedThread) else {
            return false
        }

        let groupRootThreads = rootThreads ?? self.rootThreads(in: group.threads)
        let visibleRootThreadIDs = Set(groupRootThreads.prefix(collapsedRootThreadLimit).map(\.id))
        let selectedRootThreadID = rootThreadID(containing: selectedThread, in: group.threads) ?? selectedThread.id

        return !visibleRootThreadIDs.contains(selectedRootThreadID)
    }

    private static func shouldRevealAllRootThreads(
        for group: SidebarThreadGroup,
        rootThreads: [CodexThread],
        selectedThread: CodexThread?,
        isFiltering: Bool,
        manuallyExpandedGroupIDs: Set<String>
    ) -> Bool {
        guard group.kind == .project, rootThreads.count > collapsedRootThreadLimit else {
            return true
        }

        if isFiltering || manuallyExpandedGroupIDs.contains(group.id) {
            return true
        }

        return selectedThreadRequiresExpansion(
            selectedThread,
            in: group,
            rootThreads: rootThreads
        )
    }

    private static func rootThreadID(containing thread: CodexThread, in groupThreads: [CodexThread]) -> String? {
        let threadsByID = Dictionary(uniqueKeysWithValues: groupThreads.map { ($0.id, $0) })
        var currentThread = thread
        var visitedThreadIDs: Set<String> = [thread.id]

        while let parentThreadID = currentThread.parentThreadId,
              !visitedThreadIDs.contains(parentThreadID),
              let parentThread = threadsByID[parentThreadID] {
            currentThread = parentThread
            visitedThreadIDs.insert(parentThreadID)
        }

        return currentThread.id
    }
}

struct SidebarSubagentHierarchy {
    let rootThreads: [CodexThread]
    let childrenByParentID: [String: [CodexThread]]

    init(groupThreads: [CodexThread]) {
        let threadsByID = Dictionary(uniqueKeysWithValues: groupThreads.map { ($0.id, $0) })
        var childrenByParentID: [String: [CodexThread]] = [:]
        var rootThreads: [CodexThread] = []

        for thread in groupThreads {
            if let parentThreadID = thread.parentThreadId,
               threadsByID[parentThreadID] != nil {
                childrenByParentID[parentThreadID, default: []].append(thread)
            } else {
                rootThreads.append(thread)
            }
        }

        self.rootThreads = rootThreads
        self.childrenByParentID = childrenByParentID
    }
}

struct SidebarProjectExpansionSnapshot: Equatable {
    let expandedGroupIDs: Set<String>
    let knownGroupIDs: Set<String>
}

enum SidebarProjectExpansionState {
    // Preserves user collapse choices while still auto-opening project groups that appear for the first time.
    // This also applies the persisted closed-state to groups that load late from thread/cwd data.
    static func synchronizedState(
        currentExpandedGroupIDs: Set<String>,
        knownGroupIDs: Set<String>,
        visibleGroups: [SidebarThreadGroup],
        hasInitialized: Bool,
        persistedCollapsedGroupIDs: Set<String> = []
    ) -> SidebarProjectExpansionSnapshot {
        let visibleGroupIDs = Set(
            visibleGroups
                .filter { $0.kind == .project }
                .map(\.id)
        )
        guard hasInitialized else {
            return SidebarProjectExpansionSnapshot(
                expandedGroupIDs: visibleGroupIDs.subtracting(persistedCollapsedGroupIDs),
                knownGroupIDs: visibleGroupIDs
            )
        }

        let newGroupIDs = visibleGroupIDs.subtracting(knownGroupIDs)
        return SidebarProjectExpansionSnapshot(
            expandedGroupIDs: currentExpandedGroupIDs
                .intersection(visibleGroupIDs)
                .union(newGroupIDs.subtracting(persistedCollapsedGroupIDs)),
            knownGroupIDs: visibleGroupIDs
        )
    }

    // Finds the project group that owns the current selection so the active thread is not hidden.
    static func groupIDContainingSelectedThread(_ selectedThread: CodexThread?, in groups: [SidebarThreadGroup]) -> String? {
        guard let selectedThread else {
            return nil
        }

        return groups.first(where: { $0.kind == .project && $0.contains(selectedThread) })?.id
    }

    static func shouldAutoRevealSelectedGroup(
        _ groupID: String,
        persistedCollapsedGroupIDs: Set<String>
    ) -> Bool {
        !persistedCollapsedGroupIDs.contains(groupID)
    }

    static func decodePersistedGroupIDs(_ rawValue: String) -> Set<String> {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    static func encodePersistedGroupIDs(_ groupIDs: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(groupIDs.sorted()),
              let encoded = String(data: data, encoding: .utf8) else {
            return ""
        }
        return encoded
    }
}
