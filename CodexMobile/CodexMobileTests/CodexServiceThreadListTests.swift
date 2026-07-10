// FILE: CodexServiceThreadListTests.swift
// Purpose: Verifies thread-list fetch shape and local ordering so sidebar results stay recent-activity ordered.
// Layer: Unit Test
// Exports: CodexServiceThreadListTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceThreadListTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testListThreadsRequestsCappedActiveThreadsAndAppServerSourceKinds() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var activeRequestParams: RPCObject?
        var requestCount = 0

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }

            requestCount += 1
            activeRequestParams = params?.objectValue

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([]),
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads()

        XCTAssertEqual(activeRequestParams?["limit"]?.intValue, 70)
        XCTAssertNil(activeRequestParams?["archived"])
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            activeRequestParams?["sourceKinds"]?.arrayValue?.compactMap(\.stringValue),
            ["cli", "vscode", "appServer", "exec", "unknown"]
        )
    }

    func testListThreadsPublishesActiveThreadsFromSingleFetch() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            XCTAssertNil(params?.objectValue?["archived"])

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("thread-active"),
                            "title": .string("Active thread"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads()
        XCTAssertEqual(service.threads.map(\.id), ["thread-active"])
        XCTAssertFalse(service.isLoadingThreads)
    }

    func testSuccessfulThreadListRestoresCachedSidebarBeforeColdServerReply() async throws {
        let suiteName = "CodexServiceThreadListTests.cache.\(UUID().uuidString)"
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        prepareThreadListCacheScope(service, macDeviceID: cacheMacDeviceID)
        defer { service.threadListPersistence.delete(macDeviceId: cacheMacDeviceID) }
        service.isConnected = true
        service.isInitialized = true
        service.requestTransportOverride = { method, _ in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("cached-thread"),
                            "title": .string("Cached sidebar title"),
                            "cwd": .string("/tmp/remodex"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }
        try await service.listThreads()
        await waitUntil {
            service.threadListPersistence
                .load(macDeviceId: cacheMacDeviceID)
                .contains(where: { $0.id == "cached-thread" })
        }

        let reloadedService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(reloadedService, macDeviceID: cacheMacDeviceID)
        Self.retainedServices.append(service)
        Self.retainedServices.append(reloadedService)

        XCTAssertEqual(reloadedService.threads.map(\.id), ["cached-thread"])
        XCTAssertEqual(reloadedService.thread(for: "cached-thread")?.displayTitle, "Cached sidebar title")
    }

    func testThreadListSnapshotRoundTripsUnixDatesWithoutChangingSortOrder() throws {
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let persistence = CodexThreadListPersistence()
        defer { persistence.delete(macDeviceId: cacheMacDeviceID) }
        let createdAt = Date(timeIntervalSince1970: 1_752_000_000.125)
        let updatedAt = Date(timeIntervalSince1970: 1_752_086_400.875)

        persistence.save(
            [
                CodexThread(
                    id: "dated-thread",
                    title: "Dated thread",
                    createdAt: createdAt,
                    updatedAt: updatedAt
                ),
            ],
            macDeviceId: cacheMacDeviceID
        )

        let restoredThread = try XCTUnwrap(
            persistence.load(macDeviceId: cacheMacDeviceID).first
        )
        XCTAssertEqual(
            try XCTUnwrap(restoredThread.createdAt).timeIntervalSince1970,
            createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(restoredThread.updatedAt).timeIntervalSince1970,
            updatedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testFreshThreadListReconcilesOverCachedSidebarMetadata() async throws {
        let suiteName = "CodexServiceThreadListTests.reconcile-cache.\(UUID().uuidString)"
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let initialService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(initialService, macDeviceID: cacheMacDeviceID)
        defer { initialService.threadListPersistence.delete(macDeviceId: cacheMacDeviceID) }
        initialService.threads = [
            CodexThread(id: "cached-thread", title: "Old title"),
            CodexThread(id: "stale-cached-thread", title: "No longer returned"),
        ]
        initialService.persistCurrentMacThreadListSnapshot()

        let reloadedService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(reloadedService, macDeviceID: cacheMacDeviceID)
        XCTAssertEqual(reloadedService.thread(for: "cached-thread")?.displayTitle, "Old title")
        XCTAssertNotNil(reloadedService.thread(for: "stale-cached-thread"))
        reloadedService.isConnected = true
        reloadedService.isInitialized = true
        reloadedService.requestTransportOverride = { method, _ in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("cached-thread"),
                            "title": .string("Fresh server title"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        try await reloadedService.listThreads()
        reloadedService.persistCurrentMacThreadListSnapshot()
        Self.retainedServices.append(initialService)
        Self.retainedServices.append(reloadedService)

        XCTAssertEqual(reloadedService.thread(for: "cached-thread")?.displayTitle, "Fresh server title")
        XCTAssertNil(reloadedService.thread(for: "stale-cached-thread"))
    }

    func testRestoredThreadStateFollowsCurrentLocalArchiveDefaults() {
        let suiteName = "CodexServiceThreadListTests.archive-cache.\(UUID().uuidString)"
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let initialService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(initialService, macDeviceID: cacheMacDeviceID)
        defer { initialService.threadListPersistence.delete(macDeviceId: cacheMacDeviceID) }
        initialService.threads = [
            CodexThread(
                id: "formerly-archived-thread",
                title: "Unarchived before relaunch",
                syncState: .archivedLocal
            ),
        ]
        initialService.persistCurrentMacThreadListSnapshot()

        let reloadedService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(reloadedService, macDeviceID: cacheMacDeviceID)
        Self.retainedServices.append(initialService)
        Self.retainedServices.append(reloadedService)

        XCTAssertEqual(reloadedService.thread(for: "formerly-archived-thread")?.syncState, .live)
    }

    func testActiveCachedOnlyThreadStaysUnconfirmedUntilItIsNoLongerOpen() {
        let suiteName = "CodexServiceThreadListTests.active-cache.\(UUID().uuidString)"
        let cacheMacDeviceID = "test-mac-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let initialService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(initialService, macDeviceID: cacheMacDeviceID)
        defer { initialService.threadListPersistence.delete(macDeviceId: cacheMacDeviceID) }
        initialService.threads = [CodexThread(id: "cached-active-thread", title: "Cached active")]
        initialService.persistCurrentMacThreadListSnapshot()

        let reloadedService = CodexService(defaults: defaults)
        prepareThreadListCacheScope(reloadedService, macDeviceID: cacheMacDeviceID)
        reloadedService.activeThreadId = "cached-active-thread"
        reloadedService.reconcileLocalThreadsWithServer([])

        XCTAssertNotNil(reloadedService.thread(for: "cached-active-thread"))
        XCTAssertTrue(reloadedService.restoredThreadSnapshotIDs.contains("cached-active-thread"))

        reloadedService.activeThreadId = nil
        reloadedService.reconcileLocalThreadsWithServer([])
        reloadedService.persistCurrentMacThreadListSnapshot()
        Self.retainedServices.append(initialService)
        Self.retainedServices.append(reloadedService)

        XCTAssertNil(reloadedService.thread(for: "cached-active-thread"))
        XCTAssertFalse(reloadedService.restoredThreadSnapshotIDs.contains("cached-active-thread"))
    }

    func testRealtimeSyncKeepsThreadListRequestsCapped() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var activeRequestParams: RPCObject?
        var requestCount = 0

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            requestCount += 1
            activeRequestParams = params?.objectValue

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["threads": .array([])]),
                includeJSONRPC: false
            )
        }

        await service.syncThreadsList()

        XCTAssertEqual(activeRequestParams?["limit"]?.intValue, 70)
        XCTAssertNil(activeRequestParams?["archived"])
        XCTAssertEqual(requestCount, 1)
    }

    func testConcurrentListThreadsShareInFlightRequest() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestCount = 0

        service.requestTransportOverride = { method, _ in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            requestCount += 1
            try await Task.sleep(nanoseconds: 50_000_000)

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("thread-active"),
                            "title": .string("Active thread"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let firstRefresh = Task { @MainActor in try await service.listThreads() }
        let secondRefresh = Task { @MainActor in try await service.listThreads() }

        try await firstRefresh.value
        try await secondRefresh.value

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(service.threads.map(\.id), ["thread-active"])
        XCTAssertFalse(service.isLoadingThreads)
    }

    func testRealtimeSyncSharesInFlightListThreadsRequest() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestCount = 0

        service.requestTransportOverride = { method, _ in
            guard method == "thread/list" else {
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }

            requestCount += 1
            try await Task.sleep(nanoseconds: 50_000_000)

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([
                        .object([
                            "id": .string("thread-active"),
                            "title": .string("Active thread"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let sidebarRefresh = Task { @MainActor in try await service.listThreads() }
        try await Task.sleep(nanoseconds: 10_000_000)

        await service.syncThreadsList()
        try await sidebarRefresh.value

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(service.threads.map(\.id), ["thread-active"])
    }

    func testListThreadsFlushesPendingRuntimeOptionRefreshAfterHydration() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.pendingRuntimeOptionRefresh = true

        var threadListRequestCount = 0
        var modelListRequestCount = 0
        var didReturnThreadListResponse = false
        var didLoadModelsBeforeThreadListReturned = false

        service.requestTransportOverride = { method, _ in
            switch method {
            case "thread/list":
                threadListRequestCount += 1
                try await Task.sleep(nanoseconds: 20_000_000)
                didReturnThreadListResponse = true
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["threads": .array([])]),
                    includeJSONRPC: false
                )
            case "model/list":
                modelListRequestCount += 1
                didLoadModelsBeforeThreadListReturned = !didReturnThreadListResponse
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["items": .array([])]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.listThreads()
        await waitUntil { modelListRequestCount > 0 }

        XCTAssertEqual(threadListRequestCount, 1)
        XCTAssertEqual(modelListRequestCount, 1)
        XCTAssertFalse(didLoadModelsBeforeThreadListReturned)
        XCTAssertFalse(service.pendingRuntimeOptionRefresh)
        XCTAssertNil(service.runtimeOptionRefreshTask)
        XCTAssertNil(service.runtimeOptionRefreshToken)
    }

    func testSortThreadsUsesUpdatedAtBeforeCreatedAtFallback() {
        let service = makeService()
        let laterByUpdatedAt = CodexThread(
            id: "later-by-updated-at",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let laterByCreatedAt = CodexThread(
            id: "later-by-created-at",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: nil
        )
        let oldestThread = CodexThread(
            id: "oldest-thread",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: nil
        )

        let sorted = service.sortThreads([oldestThread, laterByCreatedAt, laterByUpdatedAt])

        XCTAssertEqual(
            sorted.map(\.id),
            ["later-by-updated-at", "later-by-created-at", "oldest-thread"]
        )
    }

    func testUserRenameSurvivesStaleThreadListRefreshForPinnedThread() {
        let service = makeService()
        service.threads = [
            CodexThread(
                id: "pinned-thread",
                title: "Original server title",
                name: "Original server title",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                cwd: "/Users/dev/project"
            ),
        ]
        service.pinThread("pinned-thread")

        service.renameThread("pinned-thread", name: "Renamed locally")
        service.reconcileLocalThreadsWithServer([
            CodexThread(
                id: "pinned-thread",
                title: "Original server title",
                name: "Original server title",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 30),
                cwd: "/Users/dev/project"
            ),
        ])

        XCTAssertEqual(service.thread(for: "pinned-thread")?.displayTitle, "Renamed locally")
        XCTAssertEqual(service.pinnedThreadSnapshotsByRootID["pinned-thread"]?.first?.displayTitle, "Renamed locally")
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceThreadListTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func prepareThreadListCacheScope(_ service: CodexService, macDeviceID: String) {
        service.macScopedContextOverrideDeviceId = macDeviceID
        service.clearInMemoryMacScopedState()
        service.loadMacScopedDefaultsState(for: macDeviceID)
        service.loadThreadListSnapshot(for: macDeviceID)
    }

    private func waitUntil(_ condition: () -> Bool, maxPollCount: Int = 50) async {
        for _ in 0..<maxPollCount {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
