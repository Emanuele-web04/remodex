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

    func testCatalogDistinguishesOmittedAndExplicitlyClearedNameAfterAcknowledgement() async throws {
        let suite = "CodexThreadRenamePersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        service.isConnected = true
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/name/set")
            XCTAssertEqual(params?.objectValue?["name"]?.stringValue, "Phone Name")
            return RPCMessage(id: .string("rename"), result: .object([:]))
        }
        service.upsertThread(CodexThread(id: "chat", name: "Original"))
        let beforeRename = service.threadNameRevision
        service.renameThread("chat", name: "Phone Name")
        await service.pendingThreadNameWrites["chat"]?.task.value
        XCTAssertNil(service.unsyncedThreadNamesByThreadID["chat"])

        let stale = CodexThread(id: "chat", name: "Original")
        service.reconcileLocalThreadsWithServer([stale], nameRevision: beforeRename)
        XCTAssertEqual(service.thread(for: "chat")?.displayTitle, "Phone Name")

        service.reconcileLocalThreadsWithServer([CodexThread(id: "chat", title: "Legacy Title")])
        XCTAssertEqual(service.thread(for: "chat")?.displayTitle, "Phone Name")

        let cleared = try JSONDecoder().decode(
            CodexThread.self,
            from: Data(#"{"id":"chat","name":null}"#.utf8)
        )
        service.reconcileLocalThreadsWithServer([cleared])
        XCTAssertNil(service.persistedThreadRename(for: "chat"))
        XCTAssertNil(service.thread(for: "chat")?.name)
        XCTAssertEqual(service.thread(for: "chat")?.displayTitle, CodexThread.defaultDisplayTitle)

        service.reconcileLocalThreadsWithServer([CodexThread(id: "chat", name: "Desktop Name")])
        XCTAssertEqual(service.thread(for: "chat")?.displayTitle, "Desktop Name")
    }

    func testOfflineRenameSurvivesRelaunchAndRetriesOnReconnect() async throws {
        let suite = "CodexThreadRenamePersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = CodexThread(id: "chat", name: "Original")
        let service = CodexService(defaults: defaults)
        service.upsertThread(original)
        service.renameThread("chat", name: "Offline Name")
        service.reconcileLocalThreadsWithServer([original])
        XCTAssertEqual(service.thread(for: "chat")?.displayTitle, "Offline Name")

        let reloaded = CodexService(defaults: defaults)
        reloaded.reconcileLocalThreadsWithServer([original])
        XCTAssertEqual(reloaded.thread(for: "chat")?.displayTitle, "Offline Name")

        reloaded.isConnected = true
        var sentNames: [String] = []
        reloaded.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/name/set")
            XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, "chat")
            sentNames.append(try XCTUnwrap(params?.objectValue?["name"]?.stringValue))
            return RPCMessage(id: .string("rename"), result: .object([:]))
        }
        reloaded.retryUnsyncedThreadRenames()
        await reloaded.pendingThreadNameWrites["chat"]?.task.value
        XCTAssertEqual(sentNames, ["Offline Name"])

        reloaded.reconcileLocalThreadsWithServer([CodexThread(id: "chat", name: "Later Desktop Name")])
        XCTAssertEqual(reloaded.thread(for: "chat")?.displayTitle, "Later Desktop Name")
    }

    func testFailedRenameSurvivesCanonicalCatalogAndNotification() async throws {
        let suite = "CodexThreadRenamePersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        service.isConnected = true
        service.upsertThread(CodexThread(id: "chat", name: "Original"))
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.rpcError(RPCError(code: -32000, message: "temporarily unavailable"))
        }
        service.renameThread("chat", name: "Failed Phone Name")
        await service.pendingThreadNameWrites["chat"]?.task.value
        let cleared = try JSONDecoder().decode(
            CodexThread.self,
            from: Data(#"{"id":"chat","name":null}"#.utf8)
        )
        service.reconcileLocalThreadsWithServer([cleared])
        service.handleIncomingRPCMessage(RPCMessage(
            method: "thread/name/updated",
            params: .object(["threadId": .string("chat"), "threadName": .null]),
            includeJSONRPC: false
        ))
        XCTAssertEqual(service.thread(for: "chat")?.displayTitle, "Failed Phone Name")

        service.reconcileLocalThreadsWithServer([CodexThread(id: "chat", name: "Failed Phone Name")])
        service.reconcileLocalThreadsWithServer([cleared])
        XCTAssertNil(service.thread(for: "chat")?.name)
        XCTAssertNil(service.persistedThreadRename(for: "chat"))
    }

    func testCatalogAbsenceRequiresMetadataConfirmationBeforeRemovingChat() async throws {
        let suite = "CodexThreadRenamePersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        service.isConnected = true
        let deleted = CodexThread(id: "deleted", preview: "Previously visible")
        let archived = CodexThread(id: "archived", preview: "Previously visible")
        let reappearing = CodexThread(id: "reappearing", preview: "Previously visible")
        let transient = CodexThread(id: "transient", preview: "Previously visible")
        let blank = CodexThread(id: "blank")
        service.reconcileLocalThreadsWithServer([deleted, archived, reappearing, transient, blank], deletionScope: "local")
        service.reconcileLocalThreadsWithServer([], deletionScope: "local")
        XCTAssertNotNil(service.thread(for: deleted.id))

        var queried: Set<String> = []
        service.requestTransportOverride = { [weak service] method, params in
            XCTAssertEqual(method, "thread/read")
            XCTAssertEqual(params?.objectValue?["includeTurns"], .bool(false))
            let id = try XCTUnwrap(params?.objectValue?["threadId"]?.stringValue)
            queried.insert(id)
            if id == archived.id {
                return RPCMessage(id: .string(id), result: .object([:]), includeJSONRPC: false)
            }
            if id == reappearing.id {
                service?.reconcileLocalThreadsWithServer([reappearing], deletionScope: "local")
            }
            let error = id == transient.id
                ? RPCError(code: -32000, message: "temporarily unavailable")
                : RPCError(code: -32600, message: "thread not loaded: \(id)")
            throw CodexServiceError.rpcError(error)
        }

        service.checkMissingCatalogThreads([])
        await service.missingThreadCatalogProbeTask?.value

        XCTAssertEqual(queried, Set([deleted.id, archived.id, reappearing.id, transient.id]))
        XCTAssertNil(service.thread(for: deleted.id))
        XCTAssertNotNil(service.thread(for: archived.id))
        XCTAssertNotNil(service.thread(for: reappearing.id))
        XCTAssertNotNil(service.thread(for: transient.id))
        XCTAssertNotNil(service.thread(for: blank.id))
    }

    func testCatalogWithoutBridgeCapabilityDoesNotProbeDeletion() async throws {
        let suite = "CodexThreadRenamePersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        service.isConnected = true
        let chat = CodexThread(id: "cold", preview: "Previously visible")
        service.reconcileLocalThreadsWithServer([chat], deletionScope: "local")
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/list")
            return RPCMessage(id: .string("catalog"), result: .object(["data": .array([])]))
        }

        try await service.listThreads(checkForDeletedThreads: true)
        XCTAssertNil(service.missingThreadCatalogProbeTask)
        XCTAssertNotNil(service.thread(for: chat.id))
    }

    func testCatalogFromAnotherBridgeProcessCannotDeleteEarlierChats() async throws {
        let suite = "CodexThreadRenamePersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        service.isConnected = true
        let earlier = CodexThread(id: "earlier", preview: "From the first store")
        service.reconcileLocalThreadsWithServer([earlier], deletionScope: "first")

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/list")
            return RPCMessage(id: .string("catalog"), result: .object([
                "data": .array([]),
                "remodexCatalogDeletionScope": .string("second"),
            ]))
        }
        try await service.listThreads(checkForDeletedThreads: true)
        XCTAssertNil(service.missingThreadCatalogProbeTask)
        XCTAssertNotNil(service.thread(for: earlier.id))
    }

    func testCatalogDeletionChecksRotatePastReadableChats() async throws {
        let suite = "CodexThreadRenamePersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        service.isConnected = true
        let chats = (0..<9).map { index in
            CodexThread(
                id: "chat-\(index)",
                preview: "Previously visible",
                updatedAt: Date(timeIntervalSince1970: Double(9 - index))
            )
        }
        service.reconcileLocalThreadsWithServer(chats, deletionScope: "local")

        var probes: [String] = []
        service.requestTransportOverride = { _, params in
            let id = try XCTUnwrap(params?.objectValue?["threadId"]?.stringValue)
            probes.append(id)
            if id == "chat-8" {
                throw CodexServiceError.rpcError(RPCError(code: -32600, message: "thread not loaded: \(id)"))
            }
            return RPCMessage(id: .string(id), result: .object([:]), includeJSONRPC: false)
        }

        service.checkMissingCatalogThreads([])
        await service.missingThreadCatalogProbeTask?.value
        XCTAssertEqual(probes, Array(chats.prefix(8)).map(\.id))
        XCTAssertNotNil(service.thread(for: "chat-8"))

        service.checkMissingCatalogThreads([])
        await service.missingThreadCatalogProbeTask?.value
        XCTAssertTrue(probes.contains("chat-8"))
        XCTAssertNil(service.thread(for: "chat-8"))
    }

    func testDeletedNotificationPreventsStaleCatalogFromRestoringChat() throws {
        let suite = "CodexThreadRenamePersistenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CodexService(defaults: defaults)
        let root = CodexThread(id: "root", preview: "Root")
        let child = CodexThread(id: "child", preview: "Child", parentThreadId: root.id)
        service.reconcileLocalThreadsWithServer([root, child])
        service.handleIncomingRPCMessage(RPCMessage(
            method: "thread/deleted",
            params: .object(["threadId": .string(root.id)]),
            includeJSONRPC: false
        ))
        service.reconcileLocalThreadsWithServer([root, child])
        XCTAssertNil(service.thread(for: root.id))
        XCTAssertNotNil(service.thread(for: child.id))
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
