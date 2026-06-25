// FILE: SidebarThreadGroupingTests.swift
// Purpose: Guards sidebar grouping so chats stay partitioned by project path instead of time buckets.
// Layer: Unit Test
// Exports: SidebarThreadGroupingTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class SidebarThreadGroupingTests: XCTestCase {
    func testMakeGroupsPartitionsLiveThreadsByProjectPath() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "thread-a", updatedAt: now, cwd: "/Users/me/work/app"),
            makeThread(id: "thread-b", updatedAt: now.addingTimeInterval(-60), cwd: "/Users/me/work/app///"),
            makeThread(id: "thread-c", updatedAt: now.addingTimeInterval(-120), cwd: "/Users/me/work/site"),
        ]

        let groups = SidebarThreadGrouping.makeGroups(from: threads, now: now)

        XCTAssertEqual(groups.map(\.id), ["project:/Users/me/work/app", "project:/Users/me/work/site"])
        XCTAssertEqual(groups.first?.label, "app")
        XCTAssertEqual(groups.first?.projectPath, "/Users/me/work/app")
        XCTAssertEqual(groups.first?.threads.map(\.id), ["thread-a", "thread-b"])
        XCTAssertEqual(groups.last?.threads.map(\.id), ["thread-c"])
    }

    func testMakeGroupsCreatesChatBucketForThreadsWithoutCwd() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "thread-a", updatedAt: now, cwd: nil),
            makeThread(id: "thread-b", updatedAt: now.addingTimeInterval(-30), cwd: "   "),
        ]

        let groups = SidebarThreadGrouping.makeGroups(from: threads, now: now)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "chats:rootless")
        XCTAssertEqual(groups[0].kind, .chat)
        XCTAssertEqual(groups[0].label, "Chats")
        XCTAssertNil(groups[0].projectPath)
        XCTAssertEqual(groups[0].threads.map(\.id), ["thread-a", "thread-b"])
    }

    func testMakeGroupsTreatsPseudoProjectBucketsAsChats() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "thread-a", updatedAt: now, cwd: "server"),
            makeThread(id: "thread-b", updatedAt: now.addingTimeInterval(-30), cwd: "_default"),
        ]

        let groups = SidebarThreadGrouping.makeGroups(from: threads, now: now)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "chats:rootless")
        XCTAssertEqual(groups[0].kind, .chat)
        XCTAssertEqual(groups[0].label, "Chats")
        XCTAssertNil(groups[0].projectPath)
        XCTAssertEqual(groups[0].threads.map(\.id), ["thread-a", "thread-b"])
    }

    func testMakeGroupsWithProjectScopeSkipsRootlessChats() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "project-thread", updatedAt: now, cwd: "/Users/me/work/app"),
            makeThread(id: "rootless-thread", updatedAt: now.addingTimeInterval(60), cwd: nil),
        ]

        let groups = SidebarThreadGrouping.makeGroups(from: threads, scope: .projects, now: now)

        XCTAssertEqual(groups.map(\.id), ["project:/Users/me/work/app"])
        XCTAssertEqual(groups.first?.threads.map(\.id), ["project-thread"])
    }

    func testMakeGroupsWithChatScopeCreatesRootlessChatSection() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "project-thread", updatedAt: now.addingTimeInterval(60), cwd: "/Users/me/work/app"),
            makeThread(id: "rootless-new", updatedAt: now, cwd: nil),
            makeThread(id: "rootless-old", updatedAt: now.addingTimeInterval(-60), cwd: " "),
        ]

        let groups = SidebarThreadGrouping.makeGroups(from: threads, scope: .chats, now: now)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "chats:rootless")
        XCTAssertEqual(groups[0].kind, .chat)
        XCTAssertEqual(groups[0].label, "Chats")
        XCTAssertNil(groups[0].projectPath)
        XCTAssertEqual(groups[0].threads.map(\.id), ["rootless-new", "rootless-old"])
    }

    func testMakeGroupsWithChatScopeIncludesGeneratedCodexProjectlessWorkspaces() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let generatedRootlessPath = macGeneratedCodexProjectlessPath(slug: "allora-nella-schermata")
        let threads = [
            makeThread(id: "project-thread", updatedAt: now.addingTimeInterval(60), cwd: "/Users/me/work/app"),
            makeThread(id: "generated-rootless", updatedAt: now, cwd: generatedRootlessPath),
        ]

        let chatGroups = SidebarThreadGrouping.makeGroups(from: threads, scope: .chats, now: now)
        let projectGroups = SidebarThreadGrouping.makeGroups(from: threads, scope: .projects, now: now)

        XCTAssertEqual(chatGroups.map(\.id), ["chats:rootless"])
        XCTAssertEqual(chatGroups[0].threads.map(\.id), ["generated-rootless"])
        XCTAssertEqual(projectGroups.map(\.id), ["project:/Users/me/work/app"])
    }

    func testMakeGroupsWithChatScopeIncludesWindowsGeneratedCodexProjectlessWorkspaces() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "project-thread", updatedAt: now.addingTimeInterval(60), cwd: "C:\\Users\\me\\work\\app"),
            makeThread(
                id: "generated-rootless",
                updatedAt: now,
                cwd: "C:\\Users\\me\\Documents\\Codex\\2026-05-17\\rootless-chat"
            ),
        ]

        let chatGroups = SidebarThreadGrouping.makeGroups(from: threads, scope: .chats, now: now)
        let projectGroups = SidebarThreadGrouping.makeGroups(from: threads, scope: .projects, now: now)

        XCTAssertEqual(chatGroups.map(\.id), ["chats:rootless"])
        XCTAssertEqual(chatGroups[0].threads.map(\.id), ["generated-rootless"])
        XCTAssertEqual(projectGroups.map(\.id), ["project:C:\\Users\\me\\work\\app"])
    }

    func testMakeGroupsWithChatScopeIncludesDocumentedCodexHomeThreadsWorkspaces() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "project-thread", updatedAt: now.addingTimeInterval(60), cwd: "/Users/me/work/app"),
            makeThread(id: "codex-home-thread", updatedAt: now, cwd: "/Users/me/.codex/threads/rootless-chat"),
        ]

        let chatGroups = SidebarThreadGrouping.makeGroups(from: threads, scope: .chats, now: now)
        let projectGroups = SidebarThreadGrouping.makeGroups(from: threads, scope: .projects, now: now)

        XCTAssertEqual(chatGroups.map(\.id), ["chats:rootless"])
        XCTAssertEqual(chatGroups[0].threads.map(\.id), ["codex-home-thread"])
        XCTAssertEqual(projectGroups.map(\.id), ["project:/Users/me/work/app"])
    }

    func testMakeGroupsWithChatScopeIncludesProviderFallbackCwdThreads() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "project-thread", updatedAt: now.addingTimeInterval(60), cwd: "/Users/me/work/app"),
            makeThread(
                id: "opencode-rootless",
                updatedAt: now,
                cwd: "/Users/me/.codex/worktrees/dc28/Remodex",
                metadata: ["projectCwdSource": .string("fallback")]
            ),
        ]

        let chatGroups = SidebarThreadGrouping.makeGroups(from: threads, scope: .chats, now: now)
        let projectGroups = SidebarThreadGrouping.makeGroups(from: threads, scope: .projects, now: now)

        XCTAssertEqual(chatGroups.map(\.id), ["chats:rootless"])
        XCTAssertEqual(chatGroups[0].threads.map(\.id), ["opencode-rootless"])
        XCTAssertEqual(projectGroups.map(\.id), ["project:/Users/me/work/app"])
    }

    func testMakeGroupsWithChatScopeUsesDynamicProjectlessRoots() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let customRoot = "/Volumes/Fast/CodexChats"
        let threads = [
            makeThread(id: "project-thread", updatedAt: now.addingTimeInterval(60), cwd: "/Users/me/work/app"),
            makeThread(id: "custom-rootless", updatedAt: now, cwd: "\(customRoot)/2026-05-17/rootless-chat"),
        ]

        let chatGroups = SidebarThreadGrouping.makeGroups(
            from: threads,
            scope: .chats,
            projectlessRootPaths: [customRoot],
            now: now
        )
        let projectGroups = SidebarThreadGrouping.makeGroups(
            from: threads,
            scope: .projects,
            projectlessRootPaths: [customRoot],
            now: now
        )

        XCTAssertEqual(chatGroups.map(\.id), ["chats:rootless"])
        XCTAssertEqual(chatGroups[0].threads.map(\.id), ["custom-rootless"])
        XCTAssertEqual(projectGroups.map(\.id), ["project:/Users/me/work/app"])
    }

    func testMakeGroupsWithChatScopeKeepsPinnedRootlessThreadsLeading() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "pinned-rootless", updatedAt: now, cwd: nil),
            makeThread(id: "regular-rootless", updatedAt: now.addingTimeInterval(-60), cwd: nil),
            makeThread(id: "pinned-project", updatedAt: now.addingTimeInterval(60), cwd: "/Users/me/work/app"),
        ]

        let groups = SidebarThreadGrouping.makeGroups(
            from: threads,
            pinnedThreadIDs: ["pinned-project", "pinned-rootless"],
            scope: .chats,
            now: now
        )

        XCTAssertEqual(groups.map(\.id), ["pinned", "chats:rootless"])
        XCTAssertEqual(groups[0].threads.map(\.id), ["pinned-rootless"])
        XCTAssertEqual(groups[1].threads.map(\.id), ["regular-rootless"])
    }

    func testMakeGroupsExcludesArchivedThreadsFromSidebarSections() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "live-thread", updatedAt: now, cwd: "/Users/me/work/app"),
            makeThread(
                id: "archived-thread",
                updatedAt: now.addingTimeInterval(600),
                cwd: "/Users/me/work/archived",
                syncState: .archivedLocal
            ),
        ]

        let groups = SidebarThreadGrouping.makeGroups(from: threads, now: now)

        XCTAssertEqual(groups.map(\.id), ["project:/Users/me/work/app"])
        XCTAssertEqual(groups.first?.threads.map(\.id), ["live-thread"])
    }

    func testMakeGroupsLiftsPinnedThreadsIntoDedicatedLeadingSection() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "thread-a", updatedAt: now, cwd: "/Users/me/work/app"),
            makeThread(id: "thread-b", updatedAt: now.addingTimeInterval(-60), cwd: "/Users/me/work/site"),
            makeThread(id: "thread-c", updatedAt: now.addingTimeInterval(-120), cwd: "/Users/me/work/app"),
        ]

        let groups = SidebarThreadGrouping.makeGroups(
            from: threads,
            pinnedThreadIDs: ["thread-b", "thread-a"]
        )

        XCTAssertEqual(groups.map(\.id), ["pinned", "project:/Users/me/work/app"])
        XCTAssertEqual(groups.first?.kind, .pinned)
        XCTAssertEqual(groups.first?.threads.map(\.id), ["thread-b", "thread-a"])
        XCTAssertEqual(groups.last?.threads.map(\.id), ["thread-c"])
    }

    func testMakeGroupsIgnoresArchivedPinnedThreads() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "live-thread", updatedAt: now, cwd: "/Users/me/work/app"),
            makeThread(
                id: "archived-thread",
                updatedAt: now.addingTimeInterval(-60),
                cwd: "/Users/me/work/site",
                syncState: .archivedLocal
            ),
        ]

        let groups = SidebarThreadGrouping.makeGroups(
            from: threads,
            pinnedThreadIDs: ["archived-thread", "live-thread"]
        )

        XCTAssertEqual(groups.map(\.id), ["pinned", "project:/Users/me/work/app"])
        XCTAssertEqual(groups.first?.threads.map(\.id), ["live-thread"])
    }

    func testMakeGroupsKeepsPinnedRootSubtreeTogetherAndOutOfProjectSection() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let rootThread = makeThread(id: "root-thread", updatedAt: now, cwd: "/Users/me/work/app")
        let childThread = makeThread(
            id: "child-thread",
            updatedAt: now.addingTimeInterval(-30),
            cwd: "/Users/me/work/app",
            parentThreadId: "root-thread"
        )
        let siblingThread = makeThread(
            id: "sibling-thread",
            updatedAt: now.addingTimeInterval(-60),
            cwd: "/Users/me/work/app"
        )

        let groups = SidebarThreadGrouping.makeGroups(
            from: [rootThread, childThread, siblingThread],
            pinnedThreadIDs: ["root-thread"]
        )

        XCTAssertEqual(groups.map(\.id), ["pinned", "project:/Users/me/work/app"])
        XCTAssertEqual(groups.first?.threads.map(\.id), ["root-thread", "child-thread"])
        XCTAssertEqual(groups.last?.threads.map(\.id), ["sibling-thread"])
    }

    func testMakeGroupsMarksCodexManagedWorktreesInLabelAndIcon() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "main-thread", updatedAt: now, cwd: "/Users/me/work/Remodex"),
            makeThread(
                id: "worktree-thread",
                updatedAt: now.addingTimeInterval(-60),
                cwd: "/Users/me/.codex/worktrees/ce15/Remodex"
            ),
        ]

        let groups = SidebarThreadGrouping.makeGroups(from: threads, now: now)
        let mainGroup = try XCTUnwrap(groups.first(where: { $0.projectPath == "/Users/me/work/Remodex" }))
        let worktreeGroup = try XCTUnwrap(
            groups.first(where: { $0.projectPath == "/Users/me/.codex/worktrees/ce15/Remodex" })
        )

        XCTAssertEqual(mainGroup.label, "Remodex")
        XCTAssertEqual(mainGroup.iconSystemName, "folder")
        XCTAssertEqual(worktreeGroup.label, "Remodex 15")
        XCTAssertEqual(worktreeGroup.iconSystemName, "arrow.triangle.branch")
    }

    func testMakeProjectChoicesReusesLiveProjectBucketsAndSkipsNoProject() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "app-thread", updatedAt: now, cwd: "/Users/me/work/app"),
            makeThread(id: "site-thread", updatedAt: now.addingTimeInterval(-60), cwd: "/Users/me/work/site"),
            makeThread(id: "no-project-thread", updatedAt: now.addingTimeInterval(-120), cwd: nil),
            makeThread(
                id: "archived-thread",
                updatedAt: now.addingTimeInterval(60),
                cwd: "/Users/me/work/archived",
                syncState: .archivedLocal
            ),
        ]

        let choices = SidebarThreadGrouping.makeProjectChoices(from: threads)

        XCTAssertEqual(choices.map(\.label), ["app", "site"])
        XCTAssertEqual(choices.map(\.iconSystemName), ["folder", "folder"])
        XCTAssertEqual(choices.map(\.projectPath), ["/Users/me/work/app", "/Users/me/work/site"])
    }

    func testMakeProjectChoicesSkipsGeneratedCodexProjectlessWorkspaces() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "app-thread", updatedAt: now, cwd: "/Users/me/work/app"),
            makeThread(
                id: "generated-rootless-thread",
                updatedAt: now.addingTimeInterval(60),
                cwd: macGeneratedCodexProjectlessPath(slug: "rootless-chat")
            ),
        ]

        let choices = SidebarThreadGrouping.makeProjectChoices(from: threads)

        XCTAssertEqual(choices.map(\.projectPath), ["/Users/me/work/app"])
    }

    func testMakeProjectChoicesKeepWorktreeSelectionCompactWithoutShowingPathInLabel() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "main-thread", updatedAt: now, cwd: "/Users/me/work/Remodex"),
            makeThread(
                id: "worktree-thread",
                updatedAt: now.addingTimeInterval(-60),
                cwd: "/Users/me/.codex/worktrees/ce15/Remodex"
            ),
        ]

        let choices = SidebarThreadGrouping.makeProjectChoices(from: threads)
        let labelsByPath = Dictionary(uniqueKeysWithValues: choices.map { ($0.projectPath, $0) })

        XCTAssertEqual(labelsByPath["/Users/me/work/Remodex"]?.label, "Remodex")
        XCTAssertEqual(labelsByPath["/Users/me/work/Remodex"]?.iconSystemName, "folder")
        XCTAssertEqual(labelsByPath["/Users/me/.codex/worktrees/ce15/Remodex"]?.label, "Remodex 15")
        XCTAssertEqual(labelsByPath["/Users/me/.codex/worktrees/ce15/Remodex"]?.iconSystemName, "arrow.triangle.branch")
    }

    func testMakeProjectChoicesIncludesKnownProjectsWithoutThreads() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let choices = SidebarThreadGrouping.makeProjectChoices(
            from: [],
            knownProjects: [
                makeKnownProject(path: "/Users/me/work/opencode-only", lastSeenAt: now),
            ]
        )

        XCTAssertEqual(choices.map(\.label), ["opencode-only"])
        XCTAssertEqual(choices.map(\.projectPath), ["/Users/me/work/opencode-only"])
    }

    func testMakeProjectChoicesDedupesKnownProjectsAgainstLiveThreads() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let choices = SidebarThreadGrouping.makeProjectChoices(
            from: [
                makeThread(id: "thread-a", updatedAt: now, cwd: "/Users/me/work/app"),
            ],
            knownProjects: [
                makeKnownProject(path: "/Users/me/work/app", lastSeenAt: now.addingTimeInterval(600)),
                makeKnownProject(path: "/Users/me/work/site", lastSeenAt: now.addingTimeInterval(-60)),
            ]
        )

        XCTAssertEqual(choices.map(\.projectPath), ["/Users/me/work/app", "/Users/me/work/site"])
        XCTAssertEqual(choices.first?.sortDate, now)
    }

    func testMakeProjectChoicesSkipsKnownProjectlessRoots() {
        let choices = SidebarThreadGrouping.makeProjectChoices(
            from: [],
            knownProjects: [
                makeKnownProject(path: macGeneratedCodexProjectlessPath(slug: "rootless-chat")),
                makeKnownProject(path: "/Users/me/work/app"),
            ]
        )

        XCTAssertEqual(choices.map(\.projectPath), ["/Users/me/work/app"])
    }

    func testLiveThreadIDsForProjectGroupUsesAllThreadsNotJustFilteredMatches() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let allThreads = [
            makeThread(id: "app-thread-1", updatedAt: now, cwd: "/Users/me/work/app"),
            makeThread(id: "app-thread-2", updatedAt: now.addingTimeInterval(-60), cwd: "/Users/me/work/app"),
            makeThread(id: "site-thread", updatedAt: now.addingTimeInterval(-120), cwd: "/Users/me/work/site"),
        ]
        let filteredGroup = SidebarThreadGroup(
            id: "project:/Users/me/work/app",
            label: "app",
            kind: .project,
            sortDate: now,
            projectPath: "/Users/me/work/app",
            threads: [allThreads[0]]
        )

        let threadIDs = SidebarThreadGrouping.liveThreadIDsForProjectGroup(filteredGroup, in: allThreads)

        XCTAssertEqual(threadIDs, ["app-thread-1", "app-thread-2"])
    }

    func testMakeGroupsWithAllScopeKeepsRootlessThreadsInChats() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "project-thread", updatedAt: now.addingTimeInterval(-60), cwd: "/Users/me/work/app"),
            makeThread(id: "rootless-1", updatedAt: now, cwd: nil),
            makeThread(id: "rootless-2", updatedAt: now.addingTimeInterval(-30), cwd: " "),
        ]

        let groups = SidebarThreadGrouping.makeGroups(from: threads, scope: .all, now: now)

        XCTAssertEqual(groups.map(\.id), ["project:/Users/me/work/app", "chats:rootless"])
        XCTAssertEqual(groups[0].threads.map(\.id), ["project-thread"])
        XCTAssertEqual(groups[1].kind, .chat)
        XCTAssertEqual(groups[1].threads.map(\.id), ["rootless-1", "rootless-2"])
    }

    func testProjectExpansionStateInitiallyExpandsAllVisibleGroups() {
        let groups = [
            makeProjectGroup(id: "project:/Users/me/work/app"),
            makeProjectGroup(id: "project:/Users/me/work/site"),
        ]

        let snapshot = SidebarProjectExpansionState.synchronizedState(
            currentExpandedGroupIDs: [],
            knownGroupIDs: [],
            visibleGroups: groups,
            hasInitialized: false
        )

        XCTAssertEqual(snapshot.expandedGroupIDs, Set(groups.map(\.id)))
        XCTAssertEqual(snapshot.knownGroupIDs, Set(groups.map(\.id)))
    }

    func testProjectExpansionStateInitiallyKeepsPersistedCollapsedGroupsClosed() {
        let groups = [
            makeProjectGroup(id: "project:/Users/me/work/app"),
            makeProjectGroup(id: "project:/Users/me/work/site"),
        ]

        let snapshot = SidebarProjectExpansionState.synchronizedState(
            currentExpandedGroupIDs: [],
            knownGroupIDs: [],
            visibleGroups: groups,
            hasInitialized: false,
            persistedCollapsedGroupIDs: Set(["project:/Users/me/work/site"])
        )

        XCTAssertEqual(snapshot.expandedGroupIDs, Set(["project:/Users/me/work/app"]))
        XCTAssertEqual(snapshot.knownGroupIDs, Set(groups.map(\.id)))
    }

    func testProjectExpansionStatePreservesCollapsedGroupsAcrossRefreshes() {
        let groups = [
            makeProjectGroup(id: "project:/Users/me/work/app"),
            makeProjectGroup(id: "project:/Users/me/work/site"),
        ]

        let snapshot = SidebarProjectExpansionState.synchronizedState(
            currentExpandedGroupIDs: ["project:/Users/me/work/app"],
            knownGroupIDs: Set(groups.map(\.id)),
            visibleGroups: groups,
            hasInitialized: true
        )

        XCTAssertEqual(snapshot.expandedGroupIDs, ["project:/Users/me/work/app"])
    }

    func testProjectExpansionStateAutoExpandsNewProjectGroupsOnly() {
        let existingGroups = [
            makeProjectGroup(id: "project:/Users/me/work/app"),
            makeProjectGroup(id: "project:/Users/me/work/site"),
        ]
        let updatedGroups = existingGroups + [makeProjectGroup(id: "project:/Users/me/work/docs")]

        let snapshot = SidebarProjectExpansionState.synchronizedState(
            currentExpandedGroupIDs: ["project:/Users/me/work/app"],
            knownGroupIDs: Set(existingGroups.map(\.id)),
            visibleGroups: updatedGroups,
            hasInitialized: true
        )

        XCTAssertEqual(
            snapshot.expandedGroupIDs,
            ["project:/Users/me/work/app", "project:/Users/me/work/docs"]
        )
    }

    func testProjectExpansionStateKeepsPersistedCollapsedGroupsClosedWhenThreadsLoadLater() {
        let groups = [
            makeProjectGroup(id: "project:/Users/me/work/app"),
            makeProjectGroup(id: "project:/Users/me/work/site"),
        ]

        let initialSnapshot = SidebarProjectExpansionState.synchronizedState(
            currentExpandedGroupIDs: [],
            knownGroupIDs: [],
            visibleGroups: [],
            hasInitialized: false,
            persistedCollapsedGroupIDs: Set(["project:/Users/me/work/site"])
        )
        let loadedSnapshot = SidebarProjectExpansionState.synchronizedState(
            currentExpandedGroupIDs: initialSnapshot.expandedGroupIDs,
            knownGroupIDs: initialSnapshot.knownGroupIDs,
            visibleGroups: groups,
            hasInitialized: true,
            persistedCollapsedGroupIDs: Set(["project:/Users/me/work/site"])
        )

        XCTAssertEqual(loadedSnapshot.expandedGroupIDs, Set(["project:/Users/me/work/app"]))
    }

    func testProjectExpansionStateKeepsPersistedCollapsedGroupsClosedWhenTheyReappear() {
        let appGroup = makeProjectGroup(id: "project:/Users/me/work/app")
        let siteGroup = makeProjectGroup(id: "project:/Users/me/work/site")

        let hiddenSnapshot = SidebarProjectExpansionState.synchronizedState(
            currentExpandedGroupIDs: ["project:/Users/me/work/app"],
            knownGroupIDs: Set([appGroup.id, siteGroup.id]),
            visibleGroups: [appGroup],
            hasInitialized: true,
            persistedCollapsedGroupIDs: Set([siteGroup.id])
        )
        let restoredSnapshot = SidebarProjectExpansionState.synchronizedState(
            currentExpandedGroupIDs: hiddenSnapshot.expandedGroupIDs,
            knownGroupIDs: hiddenSnapshot.knownGroupIDs,
            visibleGroups: [appGroup, siteGroup],
            hasInitialized: true,
            persistedCollapsedGroupIDs: Set([siteGroup.id])
        )

        XCTAssertEqual(restoredSnapshot.expandedGroupIDs, Set([appGroup.id]))
    }

    func testGroupIDContainingSelectedThreadReturnsOwningProjectGroup() {
        let selectedThread = makeThread(
            id: "thread-a",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            cwd: "/Users/me/work/app"
        )
        let groups = [
            SidebarThreadGroup(
                id: "project:/Users/me/work/app",
                label: "app",
                kind: .project,
                sortDate: selectedThread.updatedAt ?? .distantPast,
                projectPath: "/Users/me/work/app",
                threads: [selectedThread]
            ),
            makeProjectGroup(id: "project:/Users/me/work/site"),
        ]

        let groupID = SidebarProjectExpansionState.groupIDContainingSelectedThread(selectedThread, in: groups)

        XCTAssertEqual(groupID, "project:/Users/me/work/app")
    }

    func testPersistedGroupIDsRoundTrip() {
        let encoded = SidebarProjectExpansionState.encodePersistedGroupIDs([
            "project:/Users/me/work/site",
            "project:/Users/me/work/app",
        ])

        let decoded = SidebarProjectExpansionState.decodePersistedGroupIDs(encoded)

        XCTAssertEqual(decoded, Set([
            "project:/Users/me/work/app",
            "project:/Users/me/work/site",
        ]))
    }

    func testShouldAutoRevealSelectedGroupSkipsPersistedCollapsedGroup() {
        let shouldReveal = SidebarProjectExpansionState.shouldAutoRevealSelectedGroup(
            "project:/Users/me/work/app",
            persistedCollapsedGroupIDs: Set(["project:/Users/me/work/app"])
        )

        XCTAssertFalse(shouldReveal)
    }

    func testProjectThreadPreviewStateShowsOnlyLatestSixRootThreadsByDefault() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = (0..<12).map { index in
            makeThread(
                id: "thread-\(index)",
                updatedAt: now.addingTimeInterval(TimeInterval(index * -60)),
                cwd: "/Users/me/work/app"
            )
        }
        let group = SidebarThreadGrouping.makeGroups(from: threads).first { $0.id == "project:/Users/me/work/app" }
        let projectGroup = try XCTUnwrap(group)

        let visibleRootThreads = SidebarProjectThreadPreviewState.visibleRootThreads(
            for: projectGroup,
            selectedThread: nil,
            isFiltering: false,
            manuallyExpandedGroupIDs: []
        )

        XCTAssertEqual(visibleRootThreads.count, 6)
        XCTAssertEqual(visibleRootThreads.map(\.id), (0..<6).map { "thread-\($0)" })
        XCTAssertTrue(
            SidebarProjectThreadPreviewState.shouldShowMoreButton(
                for: projectGroup,
                selectedThread: nil,
                isFiltering: false,
                manuallyExpandedGroupIDs: []
            )
        )
    }

    func testProjectThreadPreviewStateAutoRevealsSelectedOlderRootThread() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = (0..<12).map { index in
            makeThread(
                id: "thread-\(index)",
                updatedAt: now.addingTimeInterval(TimeInterval(index * -60)),
                cwd: "/Users/me/work/app"
            )
        }
        let group = try XCTUnwrap(
            SidebarThreadGrouping.makeGroups(from: threads).first { $0.id == "project:/Users/me/work/app" }
        )

        let visibleRootThreads = SidebarProjectThreadPreviewState.visibleRootThreads(
            for: group,
            selectedThread: threads[11],
            isFiltering: false,
            manuallyExpandedGroupIDs: []
        )

        XCTAssertEqual(visibleRootThreads.map(\.id), threads.map(\.id))
        XCTAssertFalse(
            SidebarProjectThreadPreviewState.shouldShowMoreButton(
                for: group,
                selectedThread: threads[11],
                isFiltering: false,
                manuallyExpandedGroupIDs: []
            )
        )
    }

    func testProjectThreadPreviewStateAutoRevealsSelectedSubagentWhenParentFallsPastCutoff() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var threads = (0..<11).map { index in
            makeThread(
                id: "thread-\(index)",
                updatedAt: now.addingTimeInterval(TimeInterval(index * -60)),
                cwd: "/Users/me/work/app"
            )
        }
        let selectedSubagent = makeThread(
            id: "thread-10-subagent",
            updatedAt: now.addingTimeInterval(-30),
            cwd: "/Users/me/work/app",
            parentThreadId: "thread-10"
        )
        threads.append(selectedSubagent)
        let group = try XCTUnwrap(
            SidebarThreadGrouping.makeGroups(from: threads).first { $0.id == "project:/Users/me/work/app" }
        )

        let visibleRootThreads = SidebarProjectThreadPreviewState.visibleRootThreads(
            for: group,
            selectedThread: selectedSubagent,
            isFiltering: false,
            manuallyExpandedGroupIDs: []
        )

        XCTAssertEqual(visibleRootThreads.map(\.id), (0..<11).map { "thread-\($0)" })
        XCTAssertFalse(
            SidebarProjectThreadPreviewState.shouldShowMoreButton(
                for: group,
                selectedThread: selectedSubagent,
                isFiltering: false,
                manuallyExpandedGroupIDs: []
            )
        )
    }

    private func makeThread(
        id: String,
        updatedAt: Date,
        cwd: String?,
        metadata: [String: JSONValue]? = nil,
        syncState: CodexThreadSyncState = .live,
        parentThreadId: String? = nil,
        forkedFromThreadId: String? = nil
    ) -> CodexThread {
        CodexThread(
            id: id,
            title: id,
            updatedAt: updatedAt,
            cwd: cwd,
            metadata: metadata,
            forkedFromThreadId: forkedFromThreadId,
            parentThreadId: parentThreadId,
            syncState: syncState
        )
    }

    private func makeProjectGroup(id: String) -> SidebarThreadGroup {
        SidebarThreadGroup(
            id: id,
            label: id,
            kind: .project,
            sortDate: .distantPast,
            projectPath: id.replacingOccurrences(of: "project:", with: ""),
            threads: []
        )
    }

    private func makeKnownProject(
        path: String,
        lastSeenAt: Date? = nil
    ) -> CodexKnownProject {
        CodexKnownProject(
            id: path,
            label: (path as NSString).lastPathComponent,
            path: path,
            source: "test",
            sources: ["test"],
            providerHints: [],
            lastSeenAt: lastSeenAt
        )
    }

    private func macGeneratedCodexProjectlessPath(slug: String) -> String {
        "/Users/me/Documents/Codex/2026-05-17/\(slug)"
    }
}
