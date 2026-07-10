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

    func testProjectionWindowPreservesThePromptForAToolHeavyVisibleTurn() {
        let service = makeService()
        let threadID = "thread-prompt-window"
        let turnID = "turn-prompt-window"
        let prompt = makeMessage(
            id: "prompt",
            threadID: threadID,
            role: .user,
            text: "Fix this large task",
            turnID: turnID,
            orderIndex: 0
        )
        let filler = (1...90).map { index in
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

        let source = service.snapshotProjectionSourceMessages(
            threadId: threadID,
            from: [prompt] + filler,
            usesPaginatedHistory: true
        )

        XCTAssertTrue(source.contains { $0.id == "prompt" })
        XCTAssertEqual(source.count, 91)
        XCTAssertEqual(source.first?.id, "prompt")
    }

    func testProjectionWindowKeepsNewestTurnCoherentWhenRunningMetadataHasNotArrived() {
        let service = makeService()
        let threadID = "thread-lagging-running-metadata"
        let turnID = "turn-lagging-running-metadata"
        let older = (0..<20).map { index in
            makeMessage(
                id: "older-\(index)",
                threadID: threadID,
                role: .assistant,
                text: "Older response \(index)",
                turnID: "older-turn",
                orderIndex: index
            )
        }
        let prompt = makeMessage(
            id: "prompt",
            threadID: threadID,
            role: .user,
            text: "Keep this full turn together",
            turnID: turnID,
            orderIndex: 20
        )
        let firstSegment = (1...250).map { index in
            makeMessage(
                id: "active-\(index)",
                threadID: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Tool row \(index)",
                turnID: turnID,
                orderIndex: 20 + index
            )
        }
        let steer = makeMessage(
            id: "mid-turn-steer",
            threadID: threadID,
            role: .user,
            text: "Keep going, but do not drop the original prompt.",
            turnID: turnID,
            orderIndex: 271
        )
        let secondSegment = (251...500).map { index in
            makeMessage(
                id: "active-\(index)",
                threadID: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Tool row \(index)",
                turnID: turnID,
                orderIndex: 21 + index
            )
        }

        let source = service.snapshotProjectionSourceMessages(
            threadId: threadID,
            from: older + [prompt] + firstSegment + [steer] + secondSegment,
            usesPaginatedHistory: true
        )

        XCTAssertEqual(source.first?.id, "prompt")
        XCTAssertEqual(source.count, TurnTimelineProjectionPolicy.initialMessageLimit + 2)
        XCTAssertEqual(source[1].id, "mid-turn-steer")
        XCTAssertEqual(source.last?.id, "active-500")
    }

    func testAssistantReplayDeduperCollapsesShortMirrorToCanonicalReplay() {
        let threadID = "thread-short-replay"
        let turnID = "turn-short-replay"
        let text = "Cursor completed without new review comments."
        let mirrored = makeMessage(
            id: "rollout-assistant:thread-short-replay:turn-short-replay",
            threadID: threadID,
            role: .assistant,
            text: text,
            turnID: turnID,
            orderIndex: 0
        )
        let canonical = makeMessage(
            id: "msg-canonical",
            threadID: threadID,
            role: .assistant,
            text: text,
            turnID: turnID,
            orderIndex: 1
        )

        let result = AssistantReplayDeduper.dedupeBlockReplays(in: [mirrored, canonical])

        XCTAssertEqual(result.map(\.id), [mirrored.id])
    }

    func testAssistantCompletionSourceAliasCollapsesDifferentProviderIDs() {
        let service = makeService()
        let threadID = "thread-source-alias"
        let turnID = "turn-source-alias"
        let sourceItemKey = "turn-source-alias:9f8a7b6c"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "rollout-agent-message",
            sourceItemKey: sourceItemKey,
            text: "The bridge replayed this commentary item."
        )
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "msg-provider-canonical",
            sourceItemKey: sourceItemKey,
            text: "The bridge replayed this commentary item."
        )

        let messages = service.messagesByThread[threadID] ?? []
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.sourceItemKey, sourceItemKey)
        XCTAssertEqual(messages.first?.itemId, "msg-provider-canonical")
    }

    func testStaleAliasReplayDoesNotReplaceLongerStreamingAssistantText() {
        let service = makeService()
        let threadID = "thread-stale-source-alias"
        let turnID = "turn-stale-source-alias"
        let sourceItemKey = "turn-stale-source-alias:abcdef"
        let liveText = "This is the longer live assistant text that must remain visible while streaming."

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "rollout-agent-message",
            sourceItemKey: sourceItemKey,
            text: liveText
        )
        service.messagesByThread[threadID]?[0].isStreaming = true
        service.isApplyingReplayedBridgeEvent = true
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "msg-provider-canonical",
            sourceItemKey: sourceItemKey,
            text: "Short stale replay."
        )
        service.isApplyingReplayedBridgeEvent = false

        XCTAssertEqual(service.messagesByThread[threadID]?.first?.text, liveText)
        XCTAssertTrue(service.messagesByThread[threadID]?.first?.isStreaming == true)
        XCTAssertEqual(service.messagesByThread[threadID]?.first?.itemId, "rollout-agent-message")
    }

    func testDistinctStableAssistantItemsWithIdenticalLongTextDoNotDeduplicate() {
        let text = String(repeating: "Same stable assistant text. ", count: 4)
        let first = makeMessage(
            id: "msg-first",
            threadID: "thread-distinct-stable-items",
            role: .assistant,
            text: text,
            turnID: "turn-distinct-stable-items",
            orderIndex: 0
        )
        let second = makeMessage(
            id: "msg-second",
            threadID: "thread-distinct-stable-items",
            role: .assistant,
            text: text,
            turnID: "turn-distinct-stable-items",
            orderIndex: 1
        )

        let result = AssistantReplayDeduper.dedupeBlockReplays(in: [first, second])

        XCTAssertEqual(result.map(\.id), [first.id, second.id])
    }

    func testDistinctMirrorAssistantItemsWithIdenticalShortTextDoNotDeduplicate() {
        let text = "Repeated short mirror status."
        let first = makeMessage(
            id: "rollout-agent-message:first",
            threadID: "thread-distinct-mirror-items",
            role: .assistant,
            text: text,
            turnID: "turn-distinct-mirror-items",
            orderIndex: 0
        )
        let second = makeMessage(
            id: "rollout-agent-message:second",
            threadID: "thread-distinct-mirror-items",
            role: .assistant,
            text: text,
            turnID: "turn-distinct-mirror-items",
            orderIndex: 1
        )

        let result = AssistantReplayDeduper.dedupeBlockReplays(in: [first, second])

        XCTAssertEqual(result.map(\.id), [first.id, second.id])
    }

    func testHistoryMergePrefersSameTurnSourceAliasOverDifferentItemIDs() throws {
        var mirrored = makeMessage(
            id: "rollout-agent-message",
            threadID: "thread-history-source-alias",
            role: .assistant,
            text: "Mirrored commentary",
            turnID: "turn-history-source-alias",
            orderIndex: 0
        )
        mirrored.sourceItemKey = "turn-history-source-alias:abc123"
        var canonical = makeMessage(
            id: "msg-provider-canonical",
            threadID: "thread-history-source-alias",
            role: .assistant,
            text: "Canonical commentary",
            turnID: "turn-history-source-alias",
            orderIndex: 1
        )
        canonical.sourceItemKey = mirrored.sourceItemKey

        let merged = try CodexService.mergeHistoryMessages(
            [mirrored],
            [canonical],
            activeThreadIDs: [],
            runningThreadIDs: []
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.itemId, canonical.itemId)
        XCTAssertEqual(merged.first?.sourceItemKey, canonical.sourceItemKey)
    }

    func testHistoryMergeDoesNotCollapseTwoStableItemsSharingSourceAlias() throws {
        var first = makeMessage(
            id: "msg-first",
            threadID: "thread-stable-source-alias-collision",
            role: .assistant,
            text: "Same text is allowed twice.",
            turnID: "turn-stable-source-alias-collision",
            orderIndex: 0
        )
        var second = makeMessage(
            id: "msg-second",
            threadID: first.threadId,
            role: .assistant,
            text: first.text,
            turnID: first.turnId ?? "",
            orderIndex: 1
        )
        first.sourceItemKey = "turn-stable-source-alias-collision:shared"
        second.sourceItemKey = first.sourceItemKey

        let merged = try CodexService.mergeHistoryMessages(
            [first],
            [second],
            activeThreadIDs: [],
            runningThreadIDs: []
        )

        XCTAssertEqual(merged.map(\.itemId), [first.itemId, second.itemId])
    }

    func testSourceItemIdentityRequiresExactOrMirrorProviderTransition() {
        XCTAssertTrue(CodexService.sourceItemIdentityAllowsReconcile("msg-same", "msg-same"))
        XCTAssertTrue(CodexService.sourceItemIdentityAllowsReconcile("rollout-agent-message", "msg-provider"))
        XCTAssertTrue(CodexService.sourceItemIdentityAllowsReconcile("msg-provider", "rollout-agent-message"))
        XCTAssertFalse(CodexService.sourceItemIdentityAllowsReconcile("msg-one", "msg-two"))
        XCTAssertFalse(CodexService.sourceItemIdentityAllowsReconcile("rollout-one", "rollout-two"))
        XCTAssertFalse(CodexService.sourceItemIdentityAllowsReconcile(nil, "msg-provider"))
    }

    func testProjectionWindowKeepsTheCompleteActiveTurnForMirroring() {
        let service = makeService()
        let threadID = "thread-active-mirror-window"
        let turnID = "turn-active-mirror-window"
        let olderMessages = (0..<20).map { index in
            makeMessage(
                id: "older-\(index)",
                threadID: threadID,
                role: .assistant,
                text: "Older response \(index)",
                turnID: "older-turn",
                orderIndex: index
            )
        }
        let prompt = makeMessage(
            id: "active-prompt",
            threadID: threadID,
            role: .user,
            text: "Mirror this entire active turn",
            turnID: turnID,
            orderIndex: 20
        )
        let activeTurnRows = (1...120).map { index in
            makeMessage(
                id: "active-row-\(index)",
                threadID: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Active tool output \(index)",
                turnID: turnID,
                orderIndex: 20 + index
            )
        }
        service.runningThreadIDs.insert(threadID)
        service.activeTurnIdByThread[threadID] = turnID

        let source = service.snapshotProjectionSourceMessages(
            threadId: threadID,
            from: olderMessages + [prompt] + activeTurnRows,
            usesPaginatedHistory: true
        )

        XCTAssertEqual(source.first?.id, "active-prompt")
        XCTAssertEqual(source.count, 121)
        XCTAssertTrue(source.contains { $0.id == "active-row-1" })
        XCTAssertTrue(source.contains { $0.id == "active-row-120" })
        XCTAssertFalse(source.contains { $0.turnId == "older-turn" })
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
