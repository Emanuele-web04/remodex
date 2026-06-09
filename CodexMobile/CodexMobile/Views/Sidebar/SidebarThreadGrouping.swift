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
            groups.append(contentsOf: makeProjectGroups(from: projectThreads, excludingPinnedThreadIDs: pinnedThreadIDSet))
            if let chatGroup = makeRootlessChatGroup(from: chatThreads, excludingPinnedThreadIDs: pinnedThreadIDSet) {
                groups.append(chatGroup)
            }
        case .projects:
            groups.append(contentsOf: makeProjectGroups(from: scopedThreads, excludingPinnedThreadIDs: pinnedThreadIDSet))
        case .chats:
            if let chatGroup = makeRootlessChatGroup(from: scopedThreads, excludingPinnedThreadIDs: pinnedThreadIDSet) {
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
        isFallbackProjectCwd(thread)
            || thread.normalizedProjectPath == nil
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

    // Merges persisted provider-neutral project history into the picker without
    // changing sidebar groups, which should still only show projects with chats.
    static func makeProjectChoices(
        from threads: [CodexThread],
        knownProjects: [CodexKnownProject],
        projectlessRootPaths: [String] = []
    ) -> [SidebarProjectChoice] {
        var choicesByPathKey: [String: SidebarProjectChoice] = [:]
        for choice in makeProjectChoices(from: threads, projectlessRootPaths: projectlessRootPaths) {
            choicesByPathKey[projectPathIdentityKey(choice.projectPath)] = choice
        }

        for knownProject in knownProjects {
            guard let normalizedPath = CodexThread.normalizedFilesystemProjectPath(knownProject.path),
                  !isUnderProjectlessRoot(normalizedPath, roots: projectlessRootPaths),
                  !isGeneratedCodexProjectlessPath(normalizedPath) else {
                continue
            }

            let key = projectPathIdentityKey(normalizedPath)
            guard choicesByPathKey[key] == nil else {
                continue
            }

            choicesByPathKey[key] = SidebarProjectChoice(
                id: "project:\(normalizedPath)",
                label: CodexThread.projectDisplayLabel(for: normalizedPath),
                iconSystemName: CodexThread.projectIconSystemName(for: normalizedPath),
                projectPath: normalizedPath,
                sortDate: knownProject.lastSeenAt ?? .distantPast
            )
        }

        return choicesByPathKey.values.sorted(by: compareProjectChoices)
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

    private static func makeProjectGroup(projectKey: String, threads: [CodexThread]) -> SidebarThreadGroup {
        let sortedThreads = sortThreadsByRecentActivity(threads)
        let representativeThread = sortedThreads.first
        let sortDate = representativeThread?.updatedAt ?? representativeThread?.createdAt ?? .distantPast
        return SidebarThreadGroup(
            id: "project:\(projectKey)",
            label: representativeThread?.projectDisplayName ?? CodexThread.noProjectDisplayName,
            kind: .project,
            sortDate: sortDate,
            projectPath: representativeThread?.normalizedProjectPath,
            threads: sortedThreads
        )
    }

    private static func makeRootlessChatGroup(
        from threads: [CodexThread],
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String>
    ) -> SidebarThreadGroup? {
        let liveThreads = threads.filter {
            $0.syncState != .archivedLocal && !pinnedThreadIDs.contains($0.id)
        }
        let sortedThreads = sortThreadsByRecentActivity(liveThreads)
        guard let firstThread = sortedThreads.first else {
            return nil
        }

        return SidebarThreadGroup(
            id: "chats:rootless",
            label: "Chats",
            kind: .chat,
            sortDate: firstThread.updatedAt ?? firstThread.createdAt ?? .distantPast,
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

    private static func isFallbackProjectCwd(_ thread: CodexThread) -> Bool {
        thread.metadata?["projectCwdSource"]?.stringValue == "fallback"
            || thread.metadata?["project_cwd_source"]?.stringValue == "fallback"
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

    private static func projectPathIdentityKey(_ path: String) -> String {
        path.lowercased()
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
        excludingPinnedThreadIDs pinnedThreadIDs: Set<String> = []
    ) -> [SidebarThreadGroup] {
        var liveThreadsByProject: [String: [CodexThread]] = [:]

        for thread in threads where thread.syncState != .archivedLocal {
            guard !pinnedThreadIDs.contains(thread.id) else {
                continue
            }
            liveThreadsByProject[thread.projectKey, default: []].append(thread)
        }

        return liveThreadsByProject.map { projectKey, projectThreads in
            makeProjectGroup(projectKey: projectKey, threads: projectThreads)
        }
        .sorted { lhs, rhs in
            compareProjectGroups(lhs, rhs)
        }
    }

    private nonisolated static func compareProjectChoices(
        _ lhs: SidebarProjectChoice,
        _ rhs: SidebarProjectChoice
    ) -> Bool {
        if lhs.sortDate != rhs.sortDate {
            return lhs.sortDate > rhs.sortDate
        }

        if lhs.label != rhs.label {
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }

        return lhs.id < rhs.id
    }

    private nonisolated static func compareProjectGroups(
        _ lhs: SidebarThreadGroup,
        _ rhs: SidebarThreadGroup
    ) -> Bool {
        if lhs.sortDate != rhs.sortDate {
            return lhs.sortDate > rhs.sortDate
        }

        if lhs.label != rhs.label {
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }

        return lhs.id < rhs.id
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

    private static func sortThreadsByRecentActivity(_ threads: [CodexThread]) -> [CodexThread] {
        threads.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id < rhs.id
        }
    }

    private static func projectGroupID(for thread: CodexThread) -> String {
        "project:\(thread.projectKey)"
    }
}
