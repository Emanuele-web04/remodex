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

    func testMakeGroupsCreatesNoProjectBucketForThreadsWithoutCwd() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let threads = [
            makeThread(id: "thread-a", updatedAt: now, cwd: nil),
            makeThread(id: "thread-b", updatedAt: now.addingTimeInterval(-30), cwd: "   "),
        ]

        let groups = SidebarThreadGrouping.makeGroups(from: threads, now: now)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "project:__no_project__")
        XCTAssertEqual(groups[0].label, "No Project")
        XCTAssertNil(groups[0].projectPath)
        XCTAssertEqual(groups[0].threads.map(\.id), ["thread-a", "thread-b"])
    }

    func testMakeGroupsKeepsArchivedThreadsInDedicatedTrailingSection() {
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

        XCTAssertEqual(groups.map(\.id), ["project:/Users/me/work/app", "archived"])
        XCTAssertEqual(groups[1].kind, .archived)
        XCTAssertNil(groups[1].projectPath)
        XCTAssertEqual(groups[1].threads.map(\.id), ["archived-thread"])
    }

    func testMakeGroupsMarksCodexManagedWorktreesInLabelAndIcon() {
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

    func testLiveThreadIDsForProjectGroupKeepsNoProjectChatsTogether() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let allThreads = [
            makeThread(id: "no-project-1", updatedAt: now, cwd: nil),
            makeThread(id: "no-project-2", updatedAt: now.addingTimeInterval(-30), cwd: " "),
            makeThread(id: "project-thread", updatedAt: now.addingTimeInterval(-60), cwd: "/Users/me/work/app"),
        ]
        let noProjectGroup = SidebarThreadGroup(
            id: "project:__no_project__",
            label: "No Project",
            kind: .project,
            sortDate: now,
            projectPath: nil,
            threads: [allThreads[0]]
        )

        let threadIDs = SidebarThreadGrouping.liveThreadIDsForProjectGroup(noProjectGroup, in: allThreads)

        XCTAssertEqual(threadIDs, ["no-project-1", "no-project-2"])
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

    private func makeThread(
        id: String,
        updatedAt: Date,
        cwd: String?,
        syncState: CodexThreadSyncState = .live
    ) -> CodexThread {
        CodexThread(
            id: id,
            title: id,
            updatedAt: updatedAt,
            cwd: cwd,
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
}
