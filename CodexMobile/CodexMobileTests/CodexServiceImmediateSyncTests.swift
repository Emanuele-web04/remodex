// FILE: CodexServiceImmediateSyncTests.swift
// Purpose: Verifies immediate thread sync requests collapse to the latest visible thread.
// Layer: Unit Test
// Exports: CodexServiceImmediateSyncTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceImmediateSyncTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testImmediateSyncCoalescesRapidThreadSwitchesIntoLatestThread() async {
        let service = makeService()
        let threadIDs = ["thread-a", "thread-b", "thread-c"]

        service.isConnected = true
        service.isInitialized = true
        service.threads = threadIDs.map { CodexThread(id: $0, title: $0) }

        var threadListRequestCount = 0
        var readThreadIDs: [String] = []
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/list":
                threadListRequestCount += 1
                let archived = params?.objectValue?["archived"]?.boolValue ?? false
                let payload: [JSONValue] = archived ? [] : threadIDs.map { self.makeThreadJSON(id: $0, title: $0) }
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "threads": .array(payload),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                readThreadIDs.append(threadID)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        service.requestImmediateSync(threadId: "thread-a")
        service.requestImmediateSync(threadId: "thread-b")
        service.requestImmediateSync(threadId: "thread-c")

        while service.pendingImmediateSyncTask != nil {
            await Task.yield()
        }

        XCTAssertEqual(threadListRequestCount, 1)
        XCTAssertEqual(readThreadIDs, ["thread-c"])
    }

    func testImmediateSyncSkipsObsoleteThreadReadAfterEarlierListAlreadyStarted() async {
        let service = makeService()
        let threadIDs = ["thread-a", "thread-c"]

        service.isConnected = true
        service.isInitialized = true
        service.threads = threadIDs.map { CodexThread(id: $0, title: $0) }

        var activeListRequestCount = 0
        var readThreadIDs: [String] = []
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/list":
                let archived = params?.objectValue?["archived"]?.boolValue ?? false
                if !archived {
                    activeListRequestCount += 1
                    if activeListRequestCount == 1 {
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
                let payload: [JSONValue] = archived ? [] : threadIDs.map { self.makeThreadJSON(id: $0, title: $0) }
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "threads": .array(payload),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                readThreadIDs.append(threadID)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        service.requestImmediateSync(threadId: "thread-a")
        await Task.yield()
        service.requestImmediateSync(threadId: "thread-c")

        while service.pendingImmediateSyncTask != nil {
            await Task.yield()
        }

        XCTAssertEqual(activeListRequestCount, 1)
        XCTAssertEqual(readThreadIDs, ["thread-c"])
    }

    func testImmediateSyncCanSkipThreadListForThreadScopedRefreshes() async {
        let service = makeService()

        service.isConnected = true
        service.isInitialized = true
        service.threads = [CodexThread(id: "thread-a", title: "A")]

        var threadListRequestCount = 0
        var readThreadIDs: [String] = []
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/list":
                threadListRequestCount += 1
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "threads": .array([self.makeThreadJSON(id: "thread-a", title: "A")]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                readThreadIDs.append(params?.objectValue?["threadId"]?.stringValue ?? "missing")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-a"),
                            "title": .string("A"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        service.requestImmediateSync(threadId: "thread-a", includeThreadList: false)

        while service.pendingImmediateSyncTask != nil {
            await Task.yield()
        }

        XCTAssertEqual(threadListRequestCount, 0)
        XCTAssertEqual(readThreadIDs, ["thread-a"])
    }

    func testImmediateActiveThreadSyncCoalescesRapidRefreshBursts() async {
        let service = makeService()

        service.isConnected = true
        service.isInitialized = true
        service.activeThreadId = "thread-c"
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
            CodexThread(id: "thread-b", title: "B"),
            CodexThread(id: "thread-c", title: "C"),
        ]

        var threadListRequestCount = 0
        var readThreadIDs: [String] = []
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/list":
                threadListRequestCount += 1
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "threads": .array([
                            self.makeThreadJSON(id: "thread-a", title: "A"),
                            self.makeThreadJSON(id: "thread-b", title: "B"),
                            self.makeThreadJSON(id: "thread-c", title: "C"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                readThreadIDs.append(params?.objectValue?["threadId"]?.stringValue ?? "missing")
                try? await Task.sleep(nanoseconds: 20_000_000)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(readThreadIDs.last ?? "thread-c"),
                            "title": .string(readThreadIDs.last ?? "thread-c"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        service.requestImmediateActiveThreadSync(threadId: "thread-a")
        service.requestImmediateActiveThreadSync(threadId: "thread-b")
        service.requestImmediateActiveThreadSync(threadId: "thread-c")

        while service.pendingImmediateSyncTask != nil {
            await Task.yield()
        }

        XCTAssertEqual(threadListRequestCount, 0)
        XCTAssertEqual(readThreadIDs, ["thread-c"])
    }

    func testSyncThreadsListSkipsArchivedFetchWhenRecentArchivedSnapshotExists() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.lastArchivedThreadsSyncAt = Date()
        service.threads = [
            CodexThread(id: "archived-thread", title: "Archived", syncState: .archivedLocal),
        ]

        var activeListRequestCount = 0
        var archivedListRequestCount = 0
        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }

            let archived = params?.objectValue?["archived"]?.boolValue ?? false
            if archived {
                archivedListRequestCount += 1
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["threads": .array([])]),
                    includeJSONRPC: false
                )
            }

            activeListRequestCount += 1
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["threads": .array([])]),
                includeJSONRPC: false
            )
        }

        await service.syncThreadsList()

        XCTAssertEqual(activeListRequestCount, 1)
        XCTAssertEqual(archivedListRequestCount, 0)
        XCTAssertEqual(service.threads.first?.id, "archived-thread")
    }

    func testPostConnectSyncPassSkipsThreadListWhenPersistedThreadsAlreadyExist() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]
        service.activeThreadId = "thread-a"

        var methodCounts: [String: Int] = [:]
        var threadReadRequestCount = 0
        service.requestTransportOverride = { method, params in
            methodCounts[method, default: 0] += 1

            switch method {
            case "model/list":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "models": .array([]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                threadReadRequestCount += 1
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        await service.performPostConnectSyncPass()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(methodCounts["thread/list"] ?? 0, 0)
        XCTAssertEqual(methodCounts["thread/resume"] ?? 0, 1)
        XCTAssertEqual(threadReadRequestCount, 0)
        XCTAssertEqual(methodCounts["model/list"] ?? 0, 1)
    }

    func testPostConnectSyncPassCoalescesDeferredModelListRefresh() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]
        service.activeThreadId = "thread-a"

        var modelListRequestCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "model/list":
                modelListRequestCount += 1
                try? await Task.sleep(nanoseconds: 40_000_000)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "models": .array([]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        await service.performPostConnectSyncPass()
        await service.performPostConnectSyncPass()
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(modelListRequestCount, 1)
    }

    func testPostConnectSyncPassDoesNotReResumeAlreadyResumedActiveThread() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]
        service.activeThreadId = "thread-a"
        service.resumedThreadIDs.insert("thread-a")

        var resumeRequestCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "model/list":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "models": .array([]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                resumeRequestCount += 1
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-a"),
                            "title": .string("A"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        await service.performPostConnectSyncPass()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(resumeRequestCount, 0)
    }

    func testPostConnectSyncPrewarmLetsFirstSendSkipExtraResume() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]
        service.activeThreadId = "thread-a"

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)

            switch method {
            case "model/list":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "models": .array([]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume", "thread/read":
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "turn/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "turnId": .string("turn-1"),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        await service.performPostConnectSyncPass()
        try? await Task.sleep(nanoseconds: 20_000_000)

        try await service.startTurn(
            userInput: "Ship it",
            threadId: "thread-a",
            shouldAppendUserMessage: false
        )

        XCTAssertEqual(recordedMethods.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertEqual(recordedMethods.filter { $0 == "thread/read" }.count, 0)
        XCTAssertEqual(recordedMethods.filter { $0 == "turn/start" }.count, 1)
    }

    func testPrepareThreadForDisplaySkipsFollowUpThreadReadForIdleHydratedThread() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)

            switch method {
            case "thread/resume":
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                XCTFail("Idle hydrated thread should not request a follow-up thread/read during prepare.")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-a"),
                            "title": .string("A"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        let didPrepare = await service.prepareThreadForDisplay(threadId: "thread-a")

        XCTAssertTrue(didPrepare)
        XCTAssertEqual(recordedMethods.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertEqual(recordedMethods.filter { $0 == "thread/read" }.count, 0)
    }

    func testPrepareThreadForDisplaySkipsResumeForWarmIdleThread() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.resumedThreadIDs.insert("thread-a")
        service.hydratedThreadIDs.insert("thread-a")
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string(params?.objectValue?["threadId"]?.stringValue ?? "thread-a"),
                        "title": .string("A"),
                        "turns": .array([]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let didPrepare = await service.prepareThreadForDisplay(threadId: "thread-a")

        XCTAssertTrue(didPrepare)
        XCTAssertEqual(recordedMethods, [])
    }

    func testPrepareThreadForDisplayReturnsBeforeCachedIdleResumeCompletes() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]
        service.messagesByThread["thread-a"] = [
            CodexMessage(
                id: "cached-message",
                threadId: "thread-a",
                role: .assistant,
                text: "Cached reply"
            ),
        ]

        var resumeStarted = false
        var finishResume: CheckedContinuation<Void, Never>?
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/resume":
                resumeStarted = true
                await withCheckedContinuation { continuation in
                    finishResume = continuation
                }

                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        var prepareResult: Bool?
        let prepareTask = Task { @MainActor in
            prepareResult = await service.prepareThreadForDisplay(threadId: "thread-a")
        }

        while !resumeStarted {
            await Task.yield()
        }
        await Task.yield()

        XCTAssertEqual(prepareResult, true)
        XCTAssertEqual(service.activeThreadId, "thread-a")
        XCTAssertNotNil(service.inFlightThreadResumeTaskByThread["thread-a"])

        finishResume?.resume()
        _ = await prepareTask.value

        while service.inFlightThreadResumeTaskByThread["thread-a"] != nil {
            await Task.yield()
        }

        XCTAssertTrue(service.resumedThreadIDs.contains("thread-a"))
    }

    func testStartTurnReusesBackgroundPrepareResumeForCachedIdleThread() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]
        service.messagesByThread["thread-a"] = [
            CodexMessage(
                id: "cached-message",
                threadId: "thread-a",
                role: .assistant,
                text: "Cached reply"
            ),
        ]

        var recordedMethods: [String] = []
        var finishResume: CheckedContinuation<Void, Never>?
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)

            switch method {
            case "thread/resume":
                await withCheckedContinuation { continuation in
                    finishResume = continuation
                }

                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "turn/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "turnId": .string("turn-1"),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        let prepareTask = Task { @MainActor in
            await service.prepareThreadForDisplay(threadId: "thread-a")
        }

        while finishResume == nil {
            await Task.yield()
        }

        let startTurnTask = Task { @MainActor in
            try await service.startTurn(
                userInput: "Ship it",
                threadId: "thread-a",
                shouldAppendUserMessage: false
            )
        }

        await Task.yield()
        XCTAssertEqual(recordedMethods.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertEqual(recordedMethods.filter { $0 == "turn/start" }.count, 0)

        finishResume?.resume()
        _ = await prepareTask.value
        try await startTurnTask.value

        XCTAssertEqual(recordedMethods.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertEqual(recordedMethods.filter { $0 == "turn/start" }.count, 1)
    }

    func testPrepareThreadForDisplayFallsBackToThreadReadWhenResumeOmitsTurnsForRunningThread() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.runningThreadIDs.insert("thread-a")
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)

            switch method {
            case "thread/resume":
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-a"),
                            "title": .string("A"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        let didPrepare = await service.prepareThreadForDisplay(threadId: "thread-a")

        XCTAssertTrue(didPrepare)
        XCTAssertEqual(recordedMethods.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertEqual(recordedMethods.filter { $0 == "thread/read" }.count, 1)
    }

    func testPrepareThreadForDisplayFallsBackToThreadReadWhenResumeOmitsTurnsForProtectedFallbackThread() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.protectedRunningFallbackThreadIDs.insert("thread-a")
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)

            switch method {
            case "thread/resume":
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-a"),
                            "title": .string("A"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        let didPrepare = await service.prepareThreadForDisplay(threadId: "thread-a")

        XCTAssertTrue(didPrepare)
        XCTAssertEqual(recordedMethods.filter { $0 == "thread/resume" }.count, 1)
        XCTAssertEqual(recordedMethods.filter { $0 == "thread/read" }.count, 1)
    }

    func testRefreshInFlightTurnStateCoalescesConcurrentThreadReads() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var threadReadRequestCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/read":
                threadReadRequestCount += 1
                try? await Task.sleep(nanoseconds: 40_000_000)
                let threadID = params?.objectValue?["threadId"]?.stringValue
                    ?? params?.objectValue?["thread_id"]?.stringValue
                    ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        async let firstRefresh = service.refreshInFlightTurnState(threadId: "thread-a")
        async let secondRefresh = service.refreshInFlightTurnState(threadId: "thread-a")

        let firstDidRefresh = await firstRefresh
        let secondDidRefresh = await secondRefresh

        XCTAssertTrue(firstDidRefresh)
        XCTAssertTrue(secondDidRefresh)
        XCTAssertEqual(threadReadRequestCount, 1)
    }

    func testEnsureThreadResumedCoalescesConcurrentResumeRequests() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var resumeRequestCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/resume":
                resumeRequestCount += 1
                try? await Task.sleep(nanoseconds: 40_000_000)
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        async let firstResume = service.ensureThreadResumed(threadId: "thread-a")
        async let secondResume = service.ensureThreadResumed(threadId: "thread-a")

        let firstThread = try await firstResume
        let secondThread = try await secondResume

        XCTAssertEqual(firstThread?.id, "thread-a")
        XCTAssertEqual(secondThread?.id, "thread-a")
        XCTAssertEqual(resumeRequestCount, 1)
    }

    func testBootstrapAndPrepareCoalesceResumeForSameThread() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: "thread-a", title: "A"),
        ]
        service.activeThreadId = "thread-a"

        var resumeRequestCount = 0
        var threadReadRequestCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "model/list":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "models": .array([]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                resumeRequestCount += 1
                try? await Task.sleep(nanoseconds: 40_000_000)
                let threadID = params?.objectValue?["threadId"]?.stringValue ?? "missing"
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string(threadID),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                threadReadRequestCount += 1
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("thread-a"),
                            "title": .string("A"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }
        }

        async let bootstrap: Void = service.performPostConnectSyncPass()
        async let prepared = service.prepareThreadForDisplay(threadId: "thread-a")

        let didPrepare = await prepared
        await bootstrap

        XCTAssertTrue(didPrepare)
        XCTAssertEqual(resumeRequestCount, 1)
        XCTAssertEqual(threadReadRequestCount, 0)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceImmediateSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeThreadJSON(id: String, title: String) -> JSONValue {
        .object([
            "id": .string(id),
            "title": .string(title),
        ])
    }
}
