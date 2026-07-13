// FILE: CodexSideConversationTests.swift
// Purpose: Verifies native `/side` fork, boundary injection, and cleanup payloads.
// Layer: Unit Test
// Exports: CodexSideConversationTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexSideConversationTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testStartSideConversationCreatesEphemeralForkAndInjectsBoundaryWithoutActivatingIt() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]
        service.activeThreadId = "source-thread"

        var forkParams: RPCObject = [:]
        var injectedItems: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/fork":
                forkParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("side-thread"),
                            "ephemeral": .bool(true),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/inject_items":
                injectedItems = params?.objectValue?["items"]?.arrayValue ?? []
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let sideThread = try await service.startSideConversation(from: "source-thread")

        XCTAssertEqual(forkParams["threadId"]?.stringValue, "source-thread")
        XCTAssertEqual(forkParams["ephemeral"]?.boolValue, true)
        XCTAssertNotNil(forkParams["developerInstructions"]?.stringValue)
        XCTAssertEqual(injectedItems.first?.objectValue?["type"]?.stringValue, "message")
        XCTAssertEqual(injectedItems.first?.objectValue?["role"]?.stringValue, "user")
        XCTAssertEqual(sideThread.id, "side-thread")
        XCTAssertTrue(sideThread.ephemeral)
        XCTAssertEqual(service.activeThreadId, "source-thread")
        XCTAssertTrue(service.messages(for: "side-thread").isEmpty)
        XCTAssertTrue(service.sideConversationThreadIDs.contains("side-thread"))
        XCTAssertEqual(service.sideConversationRuntimeState(for: "side-thread"), .active)

        _ = await service.prepareThreadForDisplay(threadId: "side-thread")

        XCTAssertEqual(service.activeThreadId, "source-thread")
    }

    func testCloseSideConversationInterruptsBeforeUnsubscribeAndDropsLocalState() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            makeSourceThread(),
            CodexThread(id: "side-thread", ephemeral: true),
        ]
        service.sideConversationThreadIDs.insert("side-thread")
        service.setActiveTurnID("turn-side", for: "side-thread")
        service.markThreadAsRunning("side-thread")

        var methods: [String] = []
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            if method == "thread/turns/list" {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["data": .array([
                        .object([
                            "id": .string("turn-side"),
                            "status": .string("in_progress"),
                        ]),
                    ])]),
                    includeJSONRPC: false
                )
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(method == "thread/unsubscribe"
                    ? ["status": .string("unsubscribed")]
                    : [:]),
                includeJSONRPC: false
            )
        }

        try await service.closeSideConversation(threadID: "side-thread")

        XCTAssertEqual(methods, ["thread/turns/list", "turn/interrupt", "thread/unsubscribe"])
        XCTAssertNil(service.thread(for: "side-thread"))
        XCTAssertFalse(service.sideConversationThreadIDs.contains("side-thread"))
        XCTAssertEqual(service.sideConversationRuntimeState(for: "side-thread"), .closing)
    }

    func testReconnectResumesSideWithoutHydratingTurnsOrChangingPrimarySelection() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            makeSourceThread(),
            CodexThread(id: "side-thread", ephemeral: true),
        ]
        service.activeThreadId = "source-thread"
        service.sideConversationThreadIDs.insert("side-thread")
        service.sideConversationRuntimeStateByThreadID["side-thread"] = .recovering
        service.messagesByThread["side-thread"] = [
            CodexMessage(threadId: "side-thread", role: .user, text: "local-only question"),
        ]

        var resumeParams: RPCObject = [:]
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/resume":
                resumeParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("side-thread"),
                            "ephemeral": .bool(true),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/turns/list":
                XCTAssertEqual(
                    service.sideConversationRuntimeState(for: "side-thread"),
                    .recovering
                )
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["data": .array([])]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        await service.recoverSideConversationsAfterReconnect()

        XCTAssertEqual(resumeParams["threadId"]?.stringValue, "side-thread")
        XCTAssertEqual(resumeParams["excludeTurns"]?.boolValue, true)
        XCTAssertEqual(service.sideConversationRuntimeState(for: "side-thread"), .active)
        XCTAssertEqual(service.activeThreadId, "source-thread")
        XCTAssertEqual(service.messages(for: "side-thread").map(\.text), ["local-only question"])
    }

    func testCloseFailureOnLiveConnectionRestoresActiveState() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread(), CodexThread(id: "side-thread", ephemeral: true)]
        service.sideConversationThreadIDs.insert("side-thread")
        service.sideConversationRuntimeStateByThreadID["side-thread"] = .active
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/turns/list")
            throw CodexServiceError.disconnected
        }

        do {
            try await service.closeSideConversation(threadID: "side-thread")
            XCTFail("Expected close to fail while turn state is ambiguous")
        } catch {}

        XCTAssertTrue(service.sideConversationThreadIDs.contains("side-thread"))
        XCTAssertFalse(service.pendingSideConversationCleanupThreadIDs.contains("side-thread"))
        XCTAssertEqual(service.sideConversationRuntimeState(for: "side-thread"), .active)
        XCTAssertNotNil(service.thread(for: "side-thread"))
    }

    func testCloseFailureAfterDisconnectRetainsCleanupIntentInRecovery() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread(), CodexThread(id: "side-thread", ephemeral: true)]
        service.sideConversationThreadIDs.insert("side-thread")
        service.sideConversationRuntimeStateByThreadID["side-thread"] = .active
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/turns/list")
            service.isConnected = false
            service.isInitialized = false
            throw CodexServiceError.disconnected
        }

        do {
            try await service.closeSideConversation(threadID: "side-thread")
            XCTFail("Expected close to fail after disconnect")
        } catch {}

        XCTAssertTrue(service.pendingSideConversationCleanupThreadIDs.contains("side-thread"))
        XCTAssertEqual(service.sideConversationRuntimeState(for: "side-thread"), .recovering)
        guard let pauseState = service.queuePauseStateByThread["side-thread"],
              case .paused = pauseState else {
            return XCTFail("Expected the side queue to stay paused during recovery cleanup")
        }
    }

    func testReconnectCleanupPublishesUnavailableStateForPresentedSide() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread(), CodexThread(id: "side-thread", ephemeral: true)]
        service.sideConversationThreadIDs.insert("side-thread")
        service.pendingSideConversationCleanupThreadIDs.insert("side-thread")
        service.sideConversationRuntimeStateByThreadID["side-thread"] = .recovering
        service.requestTransportOverride = { method, _ in
            if method == "thread/turns/list" {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["data": .array([])]),
                    includeJSONRPC: false
                )
            }
            XCTAssertEqual(method, "thread/unsubscribe")
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        await service.recoverSideConversationsAfterReconnect()

        guard case .unavailable = service.sideConversationRuntimeState(for: "side-thread") else {
            return XCTFail("Expected reconnect cleanup to dismiss the presented side")
        }
        XCTAssertFalse(service.hasOpenSideConversation)
        XCTAssertTrue(service.closedSideConversationThreadIDs.contains("side-thread"))
    }

    func testClosingSideRejectsQueuedTurnStartBeforeTransport() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.sideConversationThreadIDs.insert("side-thread")
        service.sideConversationRuntimeStateByThreadID["side-thread"] = .closing
        var requestedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            requestedMethods.append(method)
            throw CodexServiceError.invalidInput("Unexpected transport request")
        }

        do {
            try await service.sendTurnStart("queued question", to: "side-thread")
            XCTFail("Expected a closing side to reject a queued turn")
        } catch {}

        XCTAssertTrue(requestedMethods.isEmpty)
    }

    func testAbandonedSideRetriesInterruptSafeCleanupAfterReconnect() async {
        let service = makeService()
        service.threads = [makeSourceThread(), CodexThread(id: "side-thread", ephemeral: true)]
        service.sideConversationThreadIDs.insert("side-thread")
        service.abandonSideConversationLocally(threadID: "side-thread")

        XCTAssertTrue(service.pendingSideConversationCleanupThreadIDs.contains("side-thread"))

        service.isConnected = true
        service.isInitialized = true
        var methods: [String] = []
        service.requestTransportOverride = { method, _ in
            methods.append(method)
            if method == "thread/turns/list" {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["data": .array([])]),
                    includeJSONRPC: false
                )
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        await service.recoverSideConversationsAfterReconnect()

        XCTAssertEqual(methods, ["thread/turns/list", "thread/unsubscribe"])
        XCTAssertFalse(service.pendingSideConversationCleanupThreadIDs.contains("side-thread"))
    }

    func testReconnectDropsExpiredSideButPreservesParent() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            makeSourceThread(),
            CodexThread(id: "side-thread", ephemeral: true),
        ]
        service.activeThreadId = "source-thread"
        service.sideConversationThreadIDs.insert("side-thread")
        service.sideConversationRuntimeStateByThreadID["side-thread"] = .recovering
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/resume")
            throw CodexServiceError.rpcError(RPCError(code: -32000, message: "thread not found"))
        }

        await service.recoverSideConversationsAfterReconnect()

        guard case .unavailable(let message) = service.sideConversationRuntimeState(for: "side-thread") else {
            return XCTFail("Expected unavailable side state")
        }
        XCTAssertTrue(message.contains("main conversation is unchanged"))
        XCTAssertEqual(service.activeThreadId, "source-thread")
        XCTAssertNotNil(service.thread(for: "source-thread"))
        XCTAssertNil(service.thread(for: "side-thread"))
        XCTAssertFalse(service.sideConversationThreadIDs.contains("side-thread"))
    }

    func testSideMessagesAreExcludedFromLocalPersistencePayload() {
        let service = makeService()
        service.threads = [
            makeSourceThread(),
            CodexThread(id: "side-thread", ephemeral: true),
        ]
        service.sideConversationThreadIDs.insert("side-thread")
        service.messagesByThread = [
            "source-thread": [CodexMessage(threadId: "source-thread", role: .user, text: "keep")],
            "side-thread": [CodexMessage(threadId: "side-thread", role: .user, text: "discard")],
        ]

        XCTAssertEqual(Set(service.messagesEligibleForPersistence.keys), ["source-thread"])
    }

    func testAbandonedCleanupTombstoneKeepsLateEventsOutOfPersistence() {
        let service = makeService()
        service.threads = [makeSourceThread(), CodexThread(id: "side-thread", ephemeral: true)]
        service.sideConversationThreadIDs.insert("side-thread")

        service.abandonSideConversationLocally(threadID: "side-thread")
        service.messagesByThread["side-thread"] = [
            CodexMessage(threadId: "side-thread", role: .assistant, text: "late side event"),
        ]

        XCTAssertTrue(service.hasOpenSideConversation)
        XCTAssertTrue(service.isSideConversationIsolated("side-thread"))
        XCTAssertNil(service.messagesEligibleForPersistence["side-thread"])
    }

    func testSuccessfulCloseKeepsLateNotificationsIsolatedWithoutBlockingNewSide() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread(), CodexThread(id: "side-thread", ephemeral: true)]
        service.sideConversationThreadIDs.insert("side-thread")
        service.sideConversationRuntimeStateByThreadID["side-thread"] = .active
        service.requestTransportOverride = { method, _ in
            if method == "thread/turns/list" {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["data": .array([])]),
                    includeJSONRPC: false
                )
            }
            XCTAssertEqual(method, "thread/unsubscribe")
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        try await service.closeSideConversation(threadID: "side-thread")
        service.handleNotification(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string("side-thread"),
                "turnId": .string("late-turn"),
                "itemId": .string("late-item"),
                "delta": .string("late response"),
            ])
        )

        XCTAssertFalse(service.hasOpenSideConversation)
        XCTAssertTrue(service.isSideConversationIsolated("side-thread"))
        XCTAssertTrue(service.messages(for: "side-thread").isEmpty)
        XCTAssertNil(service.messagesEligibleForPersistence["side-thread"])
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexSideConversationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeSourceThread() -> CodexThread {
        CodexThread(
            id: "source-thread",
            title: "Source",
            cwd: "/tmp/remodex",
            model: "gpt-5.4",
            modelProvider: "openai"
        )
    }
}
