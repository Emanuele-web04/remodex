// FILE: CodexThreadRenamePersistenceTests.swift
// Purpose: Verifies custom sidebar thread names survive app relaunches and are cleaned up on deletion.
// Layer: Unit Test
// Exports: CodexThreadRenamePersistenceTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadRenamePersistenceTests: XCTestCase {
    /// XCTest teardown of `@MainActor` + `@Observable` + task-heavy `CodexService` has triggered
    /// `malloc: pointer being freed was not allocated` on the main thread; retain like `CodexThreadForkTests`.
    private static var retainedServices: [CodexService] = []

    /// Bundle-scoped suite names get a writable plist; arbitrary top-level suite names often report
    /// `Path not accessible` in the simulator and break persistence (and can destabilize malloc).
    private func renameTestContext() -> (defaults: UserDefaults, persistenceNamespace: String) {
        let bid = Bundle.main.bundleIdentifier ?? "com.zackjackson.Remodex"
        let token = UUID().uuidString.lowercased()
        let suiteName = "\(bid).threadRename.\(token)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected bundle-scoped UserDefaults suite")
            preconditionFailure("unreachable")
        }
        let diskNamespace = UUID().uuidString.lowercased()
        return (defaults, diskNamespace)
    }

    private func makeService(defaults: UserDefaults, persistenceNamespace: String) -> CodexService {
        let service = CodexService(
            defaults: defaults,
            persistenceNamespaceOverride: persistenceNamespace,
            startsLocalRelayPathMonitor: false
        )
        service.syncRealtimeEnabled = false
        Self.retainedServices.append(service)
        return service
    }

    func testRenamePersistsAcrossServiceReload() {
        let (defaults, pns) = renameTestContext()

        let service = makeService(defaults: defaults, persistenceNamespace: pns)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Renamed Thread")

        let reloadedService = makeService(defaults: defaults, persistenceNamespace: pns)
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
        let (defaults, pns) = renameTestContext()

        let service = makeService(defaults: defaults, persistenceNamespace: pns)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Renamed Thread")
        service.deleteThread("thread-1")

        let reloadedService = makeService(defaults: defaults, persistenceNamespace: pns)
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
        let (defaults, pns) = renameTestContext()

        let service = makeService(defaults: defaults, persistenceNamespace: pns)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = makeService(defaults: defaults, persistenceNamespace: pns)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Mac Rename",
                name: "Mac Rename",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")

        let secondReloadedService = makeService(defaults: defaults, persistenceNamespace: pns)
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
        let (defaults, pns) = renameTestContext()

        let service = makeService(defaults: defaults, persistenceNamespace: pns)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = makeService(defaults: defaults, persistenceNamespace: pns)
        reloadedService.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Mac Title Rename",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "thread-1")?.displayTitle, "Phone Rename")

        let secondReloadedService = makeService(defaults: defaults, persistenceNamespace: pns)
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
        let (defaults, pns) = renameTestContext()

        let service = makeService(defaults: defaults, persistenceNamespace: pns)
        service.threads = [
            CodexThread(
                id: "thread-1",
                title: "Conversation",
                cwd: "/tmp/remodex"
            ),
        ]

        service.renameThread("thread-1", name: "Phone Rename")

        let reloadedService = makeService(defaults: defaults, persistenceNamespace: pns)
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
