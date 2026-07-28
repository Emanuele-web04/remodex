// FILE: SidebarThreadGrouping.swift
// Purpose: Produces sidebar thread groups by project path (`cwd`) or rootless
//          chat scope while excluding archived chats.
// Layer: View Helper
// Exports: SidebarThreadGroupKind, SidebarContentScope, SidebarThreadGroup,
//          SidebarThreadGrouping

import Foundation

enum SidebarThreadGroupKind: Equatable {
    case pinned
    case project
    case chat
}

enum SidebarContentScope: String, CaseIterable, Hashable, Identifiable {
    case projects
    case chats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects:
            return "Projects"
        case .chats:
            return "Chats"
        }
    }
}

enum SidebarThreadGroupingScope {
    case all
    case projects
    case chats
}

struct SidebarProjectChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let iconSystemName: String
    let projectPath: String
    let sortDate: Date
}

struct SidebarThreadGroup: Identifiable {
    let id: String
    let label: String
    let kind: SidebarThreadGroupKind
    let sortDate: Date
    let projectPath: String?
    let threads: [CodexThread]

    var iconSystemName: String {
        switch kind {
        case .pinned:
            return "pin"
        case .project:
            return CodexThread.projectIconSystemName(for: projectPath)
        case .chat:
            return "bubble.left.and.bubble.right"
        }
    }

    func contains(_ thread: CodexThread) -> Bool {
        threads.contains(where: { $0.id == thread.id })
    }
}

enum SidebarThreadGrouping {
    static func makeGroups(
        from threads: [CodexThread],
        pinnedThreadIDs: [String] = [],
        scope: SidebarThreadGroupingScope = .all,
        projectlessRootPaths: [String] = [],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState] = [:],
        now _: Date = Date(),
        calendar _: Calendar = .current
    ) -> [SidebarThreadGroup] {
        var groups: [SidebarThreadGroup] = []
        let scopedThreads = threadsForScope(scope, from: threads, projectlessRootPaths: projectlessRootPaths)
        let pinnedThreads = collectPinnedThreads(from: scopedThreads, pinnedRootThreadIDs: pinnedThreadIDs)
        let pinnedThreadIDSet = Set(pinnedThreads.map(\.id))

        if let firstPinned = pinnedThreads.first {
            groups.append(
                SidebarThreadGroup(
                    id: "pinned",
                    label: "Pinned",
                    kind: .pinned,
                    sortDate: firstPinned.updatedAt ?? firstPinned.createdAt ?? .distantPast,
                    projectPath: nil,
                    threads: pinnedThreads
                )
            )
        }

        switch scope {
        case .all:
            let projectThreads = threadsForScope(.projects, from: scopedThreads, projectlessRootPaths: projectlessRootPaths)
            let chatThreads = threadsForScope(.chats, from: scopedThreads, projectlessRootPaths: projectlessRootPaths)
            groups.append(contentsOf: makeProjectGroups(
                from: projectThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ))
            if let chatGroup = makeRootlessChatGroup(
                from: chatThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ) {
                groups.append(chatGroup)
            }
        case .projects:
            groups.append(contentsOf: makeProjectGroups(
                from: scopedThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ))
        case .chats:
            if let chatGroup = makeRootlessChatGroup(
                from: scopedThreads,
                excludingPinnedThreadIDs: pinnedThreadIDSet,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            ) {
                groups.append(chatGroup)
            }
        }

        return groups
    }

    // Keeps the UI picker from leaking project chats into rootless Chats and vice versa.
    static func threadsForScope(
        _ scope: SidebarThreadGroupingScope,
        from threads: [CodexThread],
        projectlessRootPaths: [String] = []
    ) -> [CodexThread] {
        switch scope {
        case .all:
            return threads
        case .projects:
            return threads.filter { !isRootlessChatThread($0, projectlessRootPaths: projectlessRootPaths) }
        case .chats:
            return threads.filter { isRootlessChatThread($0, projectlessRootPaths: projectlessRootPaths) }
        }
    }

    // Projectless chats still receive generated host-side working directories,
    // so rootless detection cannot rely on cwd == nil alone.
    static func isRootlessChatThread(
        _ thread: CodexThread,
        projectlessRootPaths: [String] = []
    ) -> Bool {
        thread.normalizedProjectPath == nil
            || isUnderProjectlessRoot(thread.normalizedProjectPath, roots: projectlessRootPaths)
            || isGeneratedCodexProjectlessPath(thread.normalizedProjectPath)
    }

    // Reuses the sidebar project grouping rules for places like the New Chat chooser.
    static func makeProjectChoices(
        from threads: [CodexThread],
        projectlessRootPaths: [String] = []
    ) -> [SidebarProjectChoice] {
        makeProjectGroups(from: threadsForScope(
            .projects,
            from: threads,
            projectlessRootPaths: projectlessRootPaths
        )).compactMap { group in
            guard let projectPath = group.projectPath else {
                return nil
            }

            return SidebarProjectChoice(
                id: group.id,
                label: group.label,
                iconSystemName: group.iconSystemName,
                projectPath: projectPath,
                sortDate: group.sortDate
            )
        }
    }

    // Resolves all live thread ids that belong to the tapped project, even if the visible group is filtered.
    static func liveThreadIDsForProjectGroup(_ group: SidebarThreadGroup, in threads: [CodexThread]) -> [String] {
        guard group.kind == .project else {
            return []
        }

        return sortThreadsByRecentActivity(
            threads.filter { thread in
                thread.syncState != .archivedLocal && projectGroupID(for: thread) == group.id
            }
        ).map(\.id)
    }

    // Includes archived and pinned chats so local project removal fully hides the project on this device.
    static func allThreadIDsForProjectGroup(_ group: SidebarThreadGroup, in threads: [CodexThread]) -> [String] {
        guard group.kind == .project else {
            return []
        }

        return sortThreadsByRecentActivity(
            threads.filter { thread in
                projectGroupID(for: thread) == group.id
            }
        ).map(\.id)
    }

    // The group speaks for the project, not for whichever chat happens to sort first: a worktree
    // chat at the top must still show the source project's name, icon, and new-chat target.
    private static func makeProjectGroup(
        projectKey: String,
        projectPath: String?,
        threads: [CodexThread],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    ) -> SidebarThreadGroup {
        let sortedThreads = sortThreadsByRecentActivity(
            threads,
            runBadgeStateByThreadID: runBadgeStateByThreadID
        )
        // The first thread can be an old chat lifted by its run state, so the group's
        // recency comes from the newest activity anywhere in the group instead.
        let sortDate = threads
            .compactMap { $0.updatedAt ?? $0.createdAt }
            .max() ?? .distantPast
        return SidebarThreadGroup(
            id: "project:\(projectKey)",
            label: CodexThread.projectDisplayLabel(for: projectPath),
            kind: .project,
            sortDate: sortDate,
            projectPath: projectPath,
            threads: sortedThreads
        )
    }

    private static func makeRootlessChatGroup(
        from threads: [CodexThread],
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String>,
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    ) -> SidebarThreadGroup? {
        let liveThreads = threads.filter {
            $0.syncState != .archivedLocal && !pinnedThreadIDs.contains($0.id)
        }
        let sortedThreads = sortThreadsByRecentActivity(
            liveThreads,
            runBadgeStateByThreadID: runBadgeStateByThreadID
        )
        guard !sortedThreads.isEmpty else {
            return nil
        }

        return SidebarThreadGroup(
            id: "chats:rootless",
            label: "Chats",
            kind: .chat,
            sortDate: liveThreads
                .compactMap { $0.updatedAt ?? $0.createdAt }
                .max() ?? .distantPast,
            projectPath: nil,
            threads: sortedThreads
        )
    }

    private static func isUnderProjectlessRoot(_ rawPath: String?, roots: [String]) -> Bool {
        guard let normalizedPath = CodexThread.normalizedFilesystemProjectPath(rawPath) else {
            return false
        }
        let pathComponents = projectPathComponents(normalizedPath)
        guard !pathComponents.isEmpty else {
            return false
        }

        return roots.contains { root in
            guard let normalizedRoot = CodexThread.normalizedFilesystemProjectPath(root) else {
                return false
            }
            let rootComponents = projectPathComponents(normalizedRoot)
            guard !rootComponents.isEmpty, pathComponents.count >= rootComponents.count else {
                return false
            }

            return pathComponents.prefix(rootComponents.count).elementsEqual(rootComponents) {
                $0.localizedCaseInsensitiveCompare($1) == .orderedSame
            }
        }
    }

    private static func isGeneratedCodexProjectlessPath(_ rawPath: String?) -> Bool {
        guard let normalizedPath = CodexThread.normalizedFilesystemProjectPath(rawPath) else {
            return false
        }

        let pathComponents = projectPathComponents(normalizedPath)
        return isGeneratedDocumentsCodexPath(pathComponents)
            || isCodexHomeThreadsPath(pathComponents)
    }

    private static func isGeneratedDocumentsCodexPath(_ components: [String]) -> Bool {
        for index in components.indices {
            let dateIndex = index + 2
            let slugIndex = index + 3
            guard components[index] == "Documents",
                  components.indices.contains(dateIndex),
                  components.indices.contains(slugIndex),
                  components[index + 1] == "Codex",
                  isISODateFolderName(components[dateIndex]),
                  !components[slugIndex].isEmpty else {
                continue
            }
            return true
        }

        return false
    }

    private static func isCodexHomeThreadsPath(_ components: [String]) -> Bool {
        for index in components.indices {
            let childIndex = index + 2
            guard components[index] == ".codex",
                  components.indices.contains(childIndex),
                  components[index + 1] == "threads",
                  !components[childIndex].isEmpty else {
                continue
            }
            return true
        }

        return false
    }

    private static func projectPathComponents(_ path: String) -> [String] {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
    }

    private static func isISODateFolderName(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 10,
              scalars[4].value == 45,
              scalars[7].value == 45 else {
            return false
        }

        return scalars.enumerated().allSatisfy { index, scalar in
            if index == 4 || index == 7 {
                return true
            }
            return CharacterSet.decimalDigits.contains(scalar)
        }
    }

    // Keeps project-derived UI consistent by centralizing the live-thread → project bucket mapping.
    private static func makeProjectGroups(
        from threads: [CodexThread],
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String> = [],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState] = [:]
    ) -> [SidebarThreadGroup] {
        var liveThreadsByProject: [String: [CodexThread]] = [:]
        var projectPathByGroupKey: [String: String] = [:]

        for thread in threads where thread.syncState != .archivedLocal {
            guard !pinnedThreadIDs.contains(thread.id) else {
                continue
            }
            liveThreadsByProject[thread.projectGroupKey, default: []].append(thread)
            if let projectGroupPath = thread.projectGroupPath {
                projectPathByGroupKey[thread.projectGroupKey] = projectGroupPath
            }
        }

        return liveThreadsByProject.map { projectKey, projectThreads in
            makeProjectGroup(
                projectKey: projectKey,
                projectPath: projectPathByGroupKey[projectKey],
                threads: projectThreads,
                runBadgeStateByThreadID: runBadgeStateByThreadID
            )
        }
        .sorted { lhs, rhs in
            // A project whose chat is running (or waiting on the user) outranks purely
            // newer projects: threads are already tier-sorted, so each group's urgency
            // is whatever its first thread carries.
            let lhsTier = sidebarActivityTier(of: lhs.threads.first, in: runBadgeStateByThreadID)
            let rhsTier = sidebarActivityTier(of: rhs.threads.first, in: runBadgeStateByThreadID)
            if lhsTier != rhsTier {
                return lhsTier < rhsTier
            }

            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }

            if lhs.label != rhs.label {
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }

            return lhs.id < rhs.id
        }
    }

    // Keeps pinned roots and their descendants together so sidebar trees do not split across sections.
    private static func collectPinnedThreads(
        from threads: [CodexThread],
        pinnedRootThreadIDs: [String]
    ) -> [CodexThread] {
        let liveThreads = threads.filter { $0.syncState != .archivedLocal }
        let threadsByID = Dictionary(uniqueKeysWithValues: liveThreads.map { ($0.id, $0) })
        let childrenByParentID = liveThreads.reduce(into: [String: [CodexThread]]()) { partialResult, thread in
            guard let parentThreadID = thread.parentThreadId else {
                return
            }
            partialResult[parentThreadID, default: []].append(thread)
        }
        var pinnedThreads: [CodexThread] = []
        var visitedThreadIDs: Set<String> = []

        for rootThreadID in pinnedRootThreadIDs {
            guard let rootThread = threadsByID[rootThreadID] else {
                continue
            }

            appendPinnedSubtree(
                rootThread,
                childrenByParentID: childrenByParentID,
                into: &pinnedThreads,
                visitedThreadIDs: &visitedThreadIDs
            )
        }

        return pinnedThreads
    }

    private static func appendPinnedSubtree(
        _ thread: CodexThread,
        childrenByParentID: [String: [CodexThread]],
        into pinnedThreads: inout [CodexThread],
        visitedThreadIDs: inout Set<String>
    ) {
        guard visitedThreadIDs.insert(thread.id).inserted else {
            return
        }

        pinnedThreads.append(thread)

        for childThread in childrenByParentID[thread.id] ?? [] {
            appendPinnedSubtree(
                childThread,
                childrenByParentID: childrenByParentID,
                into: &pinnedThreads,
                visitedThreadIDs: &visitedThreadIDs
            )
        }
    }

    private static func sortThreadsByRecentActivity(
        _ threads: [CodexThread],
        runBadgeStateByThreadID: [String: CodexThreadRunBadgeState] = [:]
    ) -> [CodexThread] {
        threads.sorted { lhs, rhs in
            // Recency alone buries the chats the user cares about most: an orchestrating
            // run can sit idle for an hour while the worktree runs it spawned keep
            // writing, so the still-running chat would sink below its own children.
            let lhsTier = sidebarActivityTier(of: lhs, in: runBadgeStateByThreadID)
            let rhsTier = sidebarActivityTier(of: rhs, in: runBadgeStateByThreadID)
            if lhsTier != rhsTier {
                return lhsTier < rhsTier
            }
            let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id < rhs.id
        }
    }

    // Ordering tier for a sidebar row: active work first, unread outcomes next,
    // everything else (including ambient goal states) by recency alone.
    private static func sidebarActivityTier(
        of thread: CodexThread?,
        in runBadgeStateByThreadID: [String: CodexThreadRunBadgeState]
    ) -> Int {
        guard let thread, let badgeState = runBadgeStateByThreadID[thread.id] else {
            return 2
        }

        switch badgeState {
        case .running, .waitingOnUser:
            return 0
        case .ready, .failed:
            return 1
        case .goalActive, .goalAttention:
            return 2
        }
    }

    private static func projectGroupID(for thread: CodexThread) -> String {
        "project:\(thread.projectGroupKey)"
    }
}
