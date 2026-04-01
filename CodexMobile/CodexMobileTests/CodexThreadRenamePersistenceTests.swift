// FILE: CodexThreadRenamePersistenceTests.swift
// Purpose: Verifies custom sidebar thread names survive app relaunches and are cleaned up on deletion.
// Layer: Unit Test
// Exports: CodexThreadRenamePersistenceTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadRenamePersistenceTests: XCTestCase {
    private func makeService(defaults: UserDefaults) -> CodexService {
        let service = CodexService(defaults: defaults)
        // Isolated defaults have no transport; disable sync so parallel XCTest runs do not schedule bridge RPC.
        service.syncRealtimeEnabled = false
        return service
    }

    func testRenamePersistsAcrossServiceReload() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = makeService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Renamed Thread")

        let reloadedService = makeService(defaults: defaults)
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

        let service = makeService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Renamed Thread")
        service.deleteThread("thread-1")

        let reloadedService = makeService(defaults: defaults)
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

        let service = makeService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = makeService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Mac Rename",
                name: "Mac Rename",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")

        let secondReloadedService = makeService(defaults: defaults)
        secondReloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(secondReloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")
    }

    func testServerTitleOnlyRenameDoesNotOverridePersistedLocalRename() {
        let suiteName = "CodexThreadRenamePersistenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = makeService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = makeService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Mac Title Rename",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")

        let secondReloadedService = makeService(defaults: defaults)
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

        let service = makeService(defaults: defaults)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = makeService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")
    }
}
