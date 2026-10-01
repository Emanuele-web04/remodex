// FILE: CodexThreadRenamePersistenceTests.swift
// Purpose: Verifies custom sidebar thread names survive app relaunches and are cleaned up on deletion.
// Layer: Unit Test
// Exports: CodexThreadRenamePersistenceTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadRenamePersistenceTests: XCTestCase {
    func testRenamePersistsAcrossServiceReload() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Renamed Thread")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Renamed Thread")
        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.name, "Renamed Thread")
    }

    func testDeletingThreadClearsPersistedRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Renamed Thread")
        service.deleteThread("thread-1")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "New Thread")
    }

    func testExplicitServerRenameDoesNotOverridePersistedLocalRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Mac Rename",
                name: "Mac Rename",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")

        let secondReloadedService = CodexService(defaults: defaults)
        secondReloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(secondReloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")
    }

    func testDesktopRenameNotificationSupersedesConfirmedPhoneRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.desktop.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [CodexThread(id: "thread-1", title: "Original")]
        service.renameThread("thread-1", name: "Phone Rename")
        service.pendingThreadRenameByThreadID.removeValue(forKey: "thread-1")

        service.handleIncomingRPCMessage(RPCMessage(
            method: "thread/name/updated",
            params: .object([
                "threadId": .string("thread-1"),
                "name": .string("Desktop Rename"),
            ])
        ))

        XCTAssertEqual(service.thread(for: "thread-1")?.displayTitle, "Desktop Rename")
        XCTAssertNil(service.persistedThreadRename(for: "thread-1"))
    }

    func testStaleRenameNotificationDoesNotOverrideNewerPendingPhoneRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.stale.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [CodexThread(id: "thread-1", title: "Original")]
        service.renameThread("thread-1", name: "Newest phone rename")

        service.handleIncomingRPCMessage(RPCMessage(
            method: "thread/name/updated",
            params: .object([
                "threadId": .string("thread-1"),
                "name": .string("Older rename"),
            ])
        ))

        XCTAssertEqual(service.thread(for: "thread-1")?.displayTitle, "Newest phone rename")
        XCTAssertEqual(service.persistedThreadRename(for: "thread-1"), "Newest phone rename")
    }

    func testPendingPhoneRenameSurvivesServiceReloadUntilServerConfirmsIt() {
        let suiteName = "CodexThreadRenamePersistenceTests.pending.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [CodexThread(id: "thread-1", title: "Original")]
        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.loadMacScopedDefaultsState(for: nil)

        XCTAssertEqual(reloadedService.pendingThreadRenameByThreadID["thread-1"], "Phone Rename")
    }

    func testThreadDeletedNotificationRemovesLocalThreadWithoutTombstone() {
        let suiteName = "CodexThreadRenamePersistenceTests.delete.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [CodexThread(id: "thread-1", title: "Delete me")]
        service.renameThread("thread-1", name: "Local rename")

        service.handleIncomingRPCMessage(RPCMessage(
            method: "thread/deleted",
            params: .object(["threadId": .string("thread-1")])
        ))

        XCTAssertNil(service.thread(for: "thread-1"))
        XCTAssertNil(service.persistedThreadRename(for: "thread-1"))
        XCTAssertFalse(service.locallyDeletedThreadIDs.contains("thread-1"))
    }

    func testFreshServerListClearsStaleRenameAfterRelaunch() {
        let suiteName = "CodexThreadRenamePersistenceTests.reconcile.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let firstService = CodexService(defaults: defaults)
        firstService.threads = [CodexThread(id: "thread-1", title: "Original")]
        firstService.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.threads = [CodexThread(id: "thread-1", title: "Phone Rename")]
        reloadedService.reconcileLocalThreadsWithServer([
            CodexThread(id: "thread-1", title: "Desktop Rename", name: "Desktop Rename"),
        ])

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Desktop Rename")
        XCTAssertNil(reloadedService.persistedThreadRename(for: "thread-1"))
    }

    func testServerTitleOnlyRenameDoesNotOverridePersistedLocalRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Mac Title Rename",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")

        let secondReloadedService = CodexService(defaults: defaults)
        secondReloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(secondReloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")
    }

    func testFallbackConversationTitleDoesNotOverridePersistedRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")
    }

    func testPinPersistsAcrossServiceReload() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Pinned Thread",
                cwd: "/tmp/remodex"
            ),
        ]
        service.pinThread("thread-1")

        let reloadedService = CodexService(defaults: defaults)

        XCTAssertEqual(reloadedService.pinnedThreadIDs, ["thread-1"])
        XCTAssertTrue(reloadedService.isThreadPinned("thread-1"))
    }

    func testDeletingThreadClearsPersistedPin() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.pinThread("thread-1")
        service.deleteThread("thread-1")

        let reloadedService = CodexService(defaults: defaults)

        XCTAssertEqual(reloadedService.pinnedThreadIDs, [])
        XCTAssertFalse(reloadedService.isThreadPinned("thread-1"))
    }

    func testPinnedSnapshotRehydratesThreadWhenFreshServiceHasNoServerThreadsYet() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Pinned Thread",
                preview: "Saved locally",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                cwd: "/tmp/remodex"
            ),
        ]
        service.pinThread("thread-1")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.reconcileLocalThreadsWithServer([])

        XCTAssertEqual(reloadedService.pinnedThreadIDs, ["thread-1"])
        XCTAssertEqual(reloadedService.threads.map(\.id), ["thread-1"])
        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Pinned Thread")
    }

    func testPinnedSnapshotRehydrateKeepsPersistedRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Original Pinned Thread",
                preview: "Saved locally",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                cwd: "/tmp/remodex"
            ),
        ]
        service.pinThread("thread-1")
        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.reconcileLocalThreadsWithServer([])

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")
        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.name, "Phone Rename")
    }

    func testArchivingPinnedChildDoesNotClearPinnedRoot() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "root-thread",
                title: "Root Thread",
                cwd: "/tmp/remodex"
            ),
            CodexThread(
                id: "child-thread",
                title: "Child Thread",
                cwd: "/tmp/remodex",
                parentThreadId: "root-thread"
            ),
        ]
        service.pinThread("root-thread")

        service.archiveThread("child-thread")

        XCTAssertEqual(service.pinnedThreadIDs, ["root-thread"])
        XCTAssertTrue(service.isThreadPinned("root-thread"))
        XCTAssertTrue(service.thread(for: "child-thread")?.syncState == .archivedLocal)
    }

    func testRemoteArchiveCascadesThroughChildThreads() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "root-thread",
                title: "Root Thread",
                cwd: "/tmp/remodex"
            ),
            CodexThread(
                id: "child-thread",
                title: "Child Thread",
                cwd: "/tmp/remodex",
                parentThreadId: "root-thread"
            ),
        ]

        service.applyRemoteThreadArchiveState(threadId: "root-thread", isArchived: true)

        XCTAssertTrue(service.thread(for: "root-thread")?.syncState == .archivedLocal)
        XCTAssertTrue(service.thread(for: "child-thread")?.syncState == .archivedLocal)

        service.applyRemoteThreadArchiveState(threadId: "root-thread", isArchived: false)

        XCTAssertTrue(service.thread(for: "root-thread")?.syncState == .live)
        XCTAssertTrue(service.thread(for: "child-thread")?.syncState == .live)
    }

    func testRemoteArchivePreservesActiveRuntimeState() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "running-thread",
                title: "Running Thread",
                cwd: "/tmp/remodex"
            ),
        ]
        service.runningThreadIDs.insert("running-thread")
        service.activeTurnIdByThread["running-thread"] = "turn-live"
        service.activeTurnId = "turn-live"
        service.threadIdByTurnID["turn-live"] = "running-thread"

        service.applyRemoteThreadArchiveState(threadId: "running-thread", isArchived: true)

        XCTAssertTrue(service.thread(for: "running-thread")?.syncState == .archivedLocal)
        XCTAssertTrue(service.runningThreadIDs.contains("running-thread"))
        XCTAssertEqual(service.activeTurnIdByThread["running-thread"], "turn-live")
        XCTAssertEqual(service.activeTurnId, "turn-live")
        XCTAssertEqual(service.threadIdByTurnID["turn-live"], "running-thread")
    }
}
