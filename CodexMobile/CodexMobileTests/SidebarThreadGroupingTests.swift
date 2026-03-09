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
}
