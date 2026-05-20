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
                let payload: [JSONValue] = archived ? [] : threadIDs.map { makeThreadJSON(id: $0, title: $0) }
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

        XCTAssertEqual(threadListRequestCount, 2)
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
                let payload: [JSONValue] = archived ? [] : threadIDs.map { makeThreadJSON(id: $0, title: $0) }
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

        XCTAssertEqual(readThreadIDs, ["thread-c"])
    }

    func testProjectionWindowPreservesFileChangesFromVisibleTurnPrefix() {
        let service = makeService()
        let threadID = "thread-file-window"
        let turnID = "turn-file-window"
        let fileChange = makeMessage(
            id: "file-change",
            threadID: threadID,
            role: .system,
            kind: .fileChange,
            text: "Status: completed\n\nPath: Sources/App.swift\nKind: update",
            turnID: turnID,
            orderIndex: 0
        )
        let filler = (1...81).map { index in
            makeMessage(
                id: "tool-\(index)",
                threadID: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Ran command \(index)",
                turnID: turnID,
                orderIndex: index
            )
        }
        let assistant = makeMessage(
            id: "assistant",
            threadID: threadID,
            role: .assistant,
            text: "Done.",
            turnID: turnID,
            orderIndex: 82
        )

        let source = service.snapshotProjectionSourceMessages(
            threadId: threadID,
            from: [fileChange] + filler + [assistant],
            usesPaginatedHistory: true
        )
        let projected = TurnTimelineReducer.project(messages: source).messages

        XCTAssertTrue(source.contains { $0.id == "file-change" })
        XCTAssertEqual(projected.last?.id, "file-change")
    }

    func testProjectionWindowPreservesPlanFromVisibleTurnPrefix() {
        let service = makeService()
        let threadID = "thread-plan-window"
        let turnID = "turn-plan-window"
        var plan = makeMessage(
            id: "plan",
            threadID: threadID,
            role: .system,
            kind: .plan,
            text: "1. Inspect plan rendering\n2. Keep it visible",
            turnID: turnID,
            orderIndex: 0
        )
        plan.planState = CodexPlanState(steps: [
            CodexPlanStep(step: "Inspect plan rendering", status: .completed),
            CodexPlanStep(step: "Keep it visible", status: .inProgress),
        ])
        let filler = (1...81).map { index in
            makeMessage(
                id: "tool-\(index)",
                threadID: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Ran command \(index)",
                turnID: turnID,
                orderIndex: index
            )
        }
        let assistant = makeMessage(
            id: "assistant",
            threadID: threadID,
            role: .assistant,
            text: "Ready to implement.",
            turnID: turnID,
            orderIndex: 82
        )

        let source = service.snapshotProjectionSourceMessages(
            threadId: threadID,
            from: [plan] + filler + [assistant],
            usesPaginatedHistory: true
        )
        let projected = TurnTimelineReducer.project(messages: source).messages

        XCTAssertTrue(source.contains { $0.id == "plan" })
        XCTAssertTrue(projected.contains { $0.id == "plan" })
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

    private func makeMessage(
        id: String,
        threadID: String,
        role: CodexMessageRole,
        kind: CodexMessageKind = .chat,
        text: String,
        turnID: String,
        orderIndex: Int
    ) -> CodexMessage {
        CodexMessage(
            id: id,
            threadId: threadID,
            role: role,
            kind: kind,
            text: text,
            turnId: turnID,
            itemId: id,
            orderIndex: orderIndex
        )
    }
}
