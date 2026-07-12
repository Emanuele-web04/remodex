// FILE: CodexServiceCatchupRecoveryTests.swift
// Purpose: Verifies deferred-history recovery and running-thread catch-up escalation for large or active chats.
// Layer: Unit Test
// Exports: CodexServiceCatchupRecoveryTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceCatchupRecoveryTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testReplayGapDuringHandshakeLatchesCanonicalRefreshUntilInitialization() {
        let service = makeService()
        let threadID = "thread-replay-gap"
        service.activeThreadId = threadID
        service.hydratedThreadIDs.insert(threadID)
        service.lastAppliedBridgeOutboundSeq = 10
        service.isConnected = false
        service.isInitialized = false

        service.handleNotification(
            method: "remodex/bufferedReplay/gap",
            params: .object([
                "remodexBufferedReplayGap": .bool(true),
                "lastDiscardedBridgeOutboundSeq": .int(25),
            ])
        )

        XCTAssertEqual(service.lastAppliedBridgeOutboundSeq, 25)
        XCTAssertFalse(service.hydratedThreadIDs.contains(threadID))
        XCTAssertTrue(service.pendingCanonicalHistoryRefreshAfterReplayDiscontinuity)
    }

    func testReplayResetCanMoveStaleCursorBackToCurrentBridgeEpoch() {
        let service = makeService()
        service.lastAppliedBridgeOutboundSeq = 999

        service.handleNotification(
            method: "remodex/bufferedReplay/reset",
            params: .object([
                "remodexBufferedReplayReset": .bool(true),
                "resetBridgeOutboundSeqTo": .int(0),
                "bridgeReplayEpoch": .string("bridge-epoch-current"),
            ])
        )

        XCTAssertEqual(service.lastAppliedBridgeOutboundSeq, 0)
        XCTAssertEqual(service.lastAppliedBridgeReplayEpoch, "bridge-epoch-current")
        XCTAssertTrue(service.pendingCanonicalHistoryRefreshAfterReplayDiscontinuity)
    }

    func testModernHistoryOpenUsesTurnPaginationWithoutThreadRead() async throws {
        let service = makeService()
        let threadID = "thread-modern-pagination"
        let turnID = "turn-modern-pagination"

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Modern"))

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/turns/list":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                XCTAssertEqual(params?.objectValue?["limit"]?.intValue, ThreadHistoryHydrationPolicy.initialTurnPageSize)
                XCTAssertEqual(params?.objectValue?["sortDirection"]?.stringValue, "desc")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            .object([
                                "id": .string(turnID),
                                "status": .string("completed"),
                                "items": .array([
                                    .object([
                                        "id": .string("user-modern-pagination"),
                                        "type": .string("userMessage"),
                                        "content": .array([
                                            .object([
                                                "type": .string("input_text"),
                                                "text": .string("Load this chat"),
                                            ]),
                                        ]),
                                    ]),
                                    .object([
                                        "id": .string("assistant-modern-pagination"),
                                        "type": .string("agentMessage"),
                                        "text": .string("Loaded"),
                                    ]),
                                ]),
                            ]),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                XCTFail("Modern paginated history open should not call thread/read")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            default:
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .loadedPaginatedWindow)
        XCTAssertEqual(recordedMethods, ["thread/turns/list"])
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertTrue(service.hydratedThreadIDs.contains(threadID))
        XCTAssertFalse(service.messages(for: threadID).isEmpty)
    }

    func testJsonlFirstPaintStaysProvisionalUntilCanonicalPageArrives() async throws {
        let service = makeService()
        let threadID = "thread-jsonl-first-paint"
        let turnID = "turn-jsonl-first-paint"
        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.activeThreadId = threadID
        service.activeTurnIdByThread[threadID] = "turn-running-guard"
        service.upsertThread(CodexThread(id: threadID, title: "Large chat", preview: "Existing history"))

        var requireCanonicalValues: [Bool] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/turns/list")
            let requiresCanonical = params?.objectValue?["remodexRequireCanonical"]?.boolValue == true
            requireCanonicalValues.append(requiresCanonical)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([
                        .object([
                            "id": .string(turnID),
                            "status": .string("completed"),
                            "items": .array([
                                .object([
                                    "id": .string("user-jsonl-first-paint"),
                                    "type": .string("userMessage"),
                                    "content": .array([
                                        .object([
                                            "type": .string("input_text"),
                                            "text": .string("Open this large chat"),
                                        ]),
                                    ]),
                                ]),
                                .object([
                                    "id": .string("assistant-jsonl-first-paint"),
                                    "type": .string("agentMessage"),
                                    "text": .string(requiresCanonical ? "Canonical history" : "Fast local history"),
                                ]),
                            ]),
                        ]),
                    ]),
                    "nextCursor": requiresCanonical
                        ? .string("canonical-older-cursor")
                        : .string("remodex-jsonl-handoff-v1:test"),
                    "remodexJsonlFallback": .bool(!requiresCanonical),
                ]),
                includeJSONRPC: false
            )
        }

        let provisionalOutcome = try await service.loadThreadHistoryIfNeeded(
            threadId: threadID,
            forceRefresh: true
        )

        XCTAssertEqual(provisionalOutcome, .loadedProvisionalPaginatedWindow)
        XCTAssertEqual(requireCanonicalValues, [false])
        XCTAssertTrue(service.provisionalPaginatedHistoryThreadIDs.contains(threadID))
        XCTAssertTrue(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        XCTAssertFalse(service.hasRemoteOlderThreadHistoryCursor(threadId: threadID))
        XCTAssertEqual(service.messages(for: threadID).last?.text, "Fast local history")

        service.activeTurnIdByThread.removeValue(forKey: threadID)
        let canonicalOutcome = try await service.loadThreadHistoryIfNeeded(
            threadId: threadID,
            forceRefresh: true
        )

        XCTAssertEqual(canonicalOutcome, .loadedPaginatedWindow)
        XCTAssertEqual(requireCanonicalValues, [false, true])
        XCTAssertFalse(service.provisionalPaginatedHistoryThreadIDs.contains(threadID))
        XCTAssertFalse(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        XCTAssertTrue(service.hasRemoteOlderThreadHistoryCursor(threadId: threadID))
        XCTAssertEqual(service.messages(for: threadID).last?.text, "Canonical history")
        service.isConnected = false
        service.canonicalHistoryReconcileTaskByThreadID[threadID]?.cancel()
        service.canonicalHistoryReconcileRetryTaskByThreadID[threadID]?.cancel()
    }

    func testPaginatedFirstPaintKeepsTheRenderWindowBounded() {
        let service = makeService()
        let threadID = "thread-bounded-first-paint"

        service.seedThreadTimelineProjectionForPaginatedHistory(
            threadId: threadID,
            decodedMessageCount: 5_000
        )

        XCTAssertEqual(
            service.threadTimelineProjectionLimitByThreadID[threadID],
            TurnTimelineProjectionPolicy.initialMessageLimit
        )
    }

    func testEmptyCanonicalReplacementKeepsCachedRowsAndRemainsRetryable() async throws {
        let service = makeService()
        let threadID = "thread-empty-replacement"
        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Replacement"))
        service.messagesByThread[threadID] = [
            CodexMessage(id: "old", threadId: threadID, role: .assistant, text: "stale", turnId: "turn-line-1", itemId: "response-item-line-3"),
            CodexMessage(id: "pending", threadId: threadID, role: .user, text: "new", deliveryState: .pending),
        ]
        service.pendingCanonicalSourceReplacementThreadIDs.insert(threadID)
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/turns/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["data": .array([]), "nextCursor": .null]),
                includeJSONRPC: false
            )
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .deferredAfterEmptyPage)
        XCTAssertEqual(service.messages(for: threadID).map(\.id), ["old", "pending"])
        XCTAssertTrue(service.pendingCanonicalSourceReplacementThreadIDs.contains(threadID))
        XCTAssertTrue(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        service.isConnected = false
        service.canonicalHistoryReconcileTaskByThreadID[threadID]?.cancel()
        service.canonicalHistoryReconcileRetryTaskByThreadID[threadID]?.cancel()
    }

    func testEmptyLegacyReplacementDoesNotConfirmRestoredSidebarThread() async throws {
        let service = makeService()
        let threadID = "thread-empty-legacy-restored"
        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = false
        service.upsertThread(CodexThread(id: threadID, title: "Cached title", preview: "Cached history"))
        service.messagesByThread[threadID] = [
            CodexMessage(
                id: "cached-row",
                threadId: threadID,
                role: .assistant,
                text: "Cached answer",
                turnId: "cached-turn",
                itemId: "cached-item"
            ),
        ]
        service.restoredThreadSnapshotIDs.insert(threadID)
        service.pendingCanonicalSourceReplacementThreadIDs.insert(threadID)
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/read")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string(threadID),
                        "title": .string("Server title"),
                        "turns": .array([]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .deferredAfterEmptyPage)
        XCTAssertEqual(service.thread(for: threadID)?.displayTitle, "Cached title")
        XCTAssertEqual(service.messages(for: threadID).map(\.id), ["cached-row"])
        XCTAssertTrue(service.restoredThreadSnapshotIDs.contains(threadID))
        service.isConnected = false
        service.canonicalHistoryReconcileTaskByThreadID[threadID]?.cancel()
        service.canonicalHistoryReconcileRetryTaskByThreadID[threadID]?.cancel()
    }

    func testEmptyInitialPaginationForExistingThreadStaysLoadingAndRetryable() async throws {
        let service = makeService()
        let threadID = "thread-empty-existing"
        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.activeThreadId = threadID
        service.upsertThread(CodexThread(id: threadID, title: "Existing chat", preview: "Older message"))
        service.restoredThreadSnapshotIDs.insert(threadID)
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/turns/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["data": .array([]), "nextCursor": .null]),
                includeJSONRPC: false
            )
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .deferredAfterEmptyPage)
        XCTAssertFalse(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertFalse(service.hydratedThreadIDs.contains(threadID))
        XCTAssertFalse(service.hasAuthoritativeLocalHistoryStart(threadId: threadID))
        XCTAssertTrue(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        XCTAssertTrue(service.restoredThreadSnapshotIDs.contains(threadID))
        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .loading)
        service.isConnected = false
        service.canonicalHistoryReconcileTaskByThreadID[threadID]?.cancel()
        service.canonicalHistoryReconcileRetryTaskByThreadID[threadID]?.cancel()
    }

    func testEmptyInitialPaginationForRenamedBlankThreadCompletesHydration() async throws {
        let service = makeService()
        let threadID = "thread-renamed-blank"
        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.activeThreadId = threadID
        service.upsertThread(CodexThread(
            id: threadID,
            title: "My renamed blank task",
            preview: nil,
            syncState: .live
        ))
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/turns/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["data": .array([]), "nextCursor": .null]),
                includeJSONRPC: false
            )
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .loadedPaginatedWindow)
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertTrue(service.hydratedThreadIDs.contains(threadID))
        XCTAssertFalse(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .empty)
    }

    func testEmptyInitialPaginationWithCachedRowsRemainsRetryableWithoutPreview() async throws {
        let service = makeService()
        let threadID = "thread-empty-cached"
        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.activeThreadId = threadID
        service.upsertThread(CodexThread(
            id: threadID,
            title: "Cached chat",
            preview: nil,
            syncState: .live
        ))
        service.messagesByThread[threadID] = [
            CodexMessage(
                id: "cached-assistant",
                threadId: threadID,
                role: .assistant,
                text: "Previously loaded",
                turnId: "cached-turn",
                itemId: "cached-item"
            ),
        ]
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/turns/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["data": .array([]), "nextCursor": .null]),
                includeJSONRPC: false
            )
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .deferredAfterEmptyPage)
        XCTAssertEqual(service.messages(for: threadID).map(\.id), ["cached-assistant"])
        XCTAssertTrue(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        service.isConnected = false
        service.canonicalHistoryReconcileTaskByThreadID[threadID]?.cancel()
        service.canonicalHistoryReconcileRetryTaskByThreadID[threadID]?.cancel()
    }

    func testBridgePaginationFailureActuallyRetriesAfterBackoff() async throws {
        let service = makeService()
        let threadID = "thread-bridge-retry"
        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.activeThreadId = threadID
        service.upsertThread(CodexThread(id: threadID, title: "Large chat", preview: "Existing history"))

        var requestCount = 0
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/turns/list")
            requestCount += 1
            if requestCount <= 2 {
                throw CodexServiceError.rpcError(RPCError(
                    code: -32000,
                    message: "The newest chat turn is too large to relay safely.",
                    data: .object(["errorCode": .string("thread_turns_list_failed")])
                ))
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([
                        .object([
                            "id": .string("turn-after-retry"),
                            "status": .string("completed"),
                            "items": .array([
                                .object([
                                    "id": .string("assistant-after-retry"),
                                    "type": .string("agentMessage"),
                                    "text": .string("Recovered history"),
                                ]),
                            ]),
                        ]),
                    ]),
                    "nextCursor": .null,
                ]),
                includeJSONRPC: false
            )
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)
        XCTAssertEqual(outcome, .deferredAfterUnavailablePage)
        XCTAssertEqual(service.threadDisplayPhase(threadId: threadID), .loading)

        for _ in 0..<20 where requestCount < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(service.canonicalHistoryReconcileRetryAttemptByThreadID[threadID], 1)
        XCTAssertNotNil(service.canonicalHistoryReconcileRetryTaskByThreadID[threadID])

        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(requestCount, 2, "The delayed retry must respect its 1.5-second backoff")

        for _ in 0..<30 where service.messages(for: threadID).isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(service.messages(for: threadID).last?.text, "Recovered history")
        XCTAssertFalse(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        XCTAssertNil(service.canonicalHistoryReconcileRetryAttemptByThreadID[threadID])
        service.isConnected = false
        service.canonicalHistoryReconcileTaskByThreadID[threadID]?.cancel()
        service.canonicalHistoryReconcileRetryTaskByThreadID[threadID]?.cancel()
    }

    func testHistoryOpenFallsBackToLegacyThreadReadWhenTurnPaginationIsUnsupported() async throws {
        let service = makeService()
        let threadID = "thread-legacy-pagination"

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Legacy"))

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/turns/list":
                throw CodexServiceError.rpcError(
                    RPCError(code: -32601, message: "Method not found: thread/turns/list")
                )
            case "thread/read":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                XCTAssertEqual(params?.objectValue?["includeTurns"]?.boolValue, true)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Legacy"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .loadedCanonicalHistory)
        XCTAssertEqual(recordedMethods, ["thread/turns/list", "thread/read"])
        XCTAssertFalse(service.supportsTurnPagination)
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertTrue(service.hydratedThreadIDs.contains(threadID))
    }

    func testHistoryOpenFallsBackToLegacyThreadReadWhenTurnPaginationPayloadIsInvalid() async throws {
        let service = makeService()
        let threadID = "thread-invalid-pagination-payload"

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Invalid page"))

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/turns/list":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .null,
                    includeJSONRPC: false
                )
            case "thread/read":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Invalid page"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .loadedCanonicalHistory)
        XCTAssertEqual(recordedMethods, ["thread/turns/list", "thread/read"])
        XCTAssertFalse(service.supportsTurnPagination)
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains(threadID))
        XCTAssertTrue(service.hydratedThreadIDs.contains(threadID))
    }

    func testForcedHistorySkipsFreshFirstTurnWhileThreadIsStillMaterializing() async throws {
        let service = makeService()
        let threadID = "thread-first-turn-materializing"

        service.isConnected = true
        service.isInitialized = true
        service.supportsTurnPagination = true
        service.upsertThread(CodexThread(id: threadID, title: "Hi"))
        service.initialTurnsLoadedByThreadID.insert(threadID)
        service.runningThreadIDs.insert(threadID)
        service.messagesByThread[threadID] = [
            CodexMessage(
                threadId: threadID,
                role: .user,
                text: "hi",
                deliveryState: .confirmed
            ),
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                kind: .thinking,
                text: "",
                isStreaming: true
            ),
        ]

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            XCTFail("First running turn should not hydrate history before the runtime materializes it")
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        let outcome = try await service.loadThreadHistoryIfNeeded(threadId: threadID, forceRefresh: true)

        XCTAssertEqual(outcome, .skippedForRunningThread)
        XCTAssertTrue(recordedMethods.isEmpty)
    }

    func testRunningCatchupEscalatesExistingLightweightTaskIntoForcedResume() async {
        let service = makeService()
        let threadID = "thread-running"
        let turnID = "turn-running"

        service.isConnected = true
        service.isInitialized = true
        service.upsertThread(CodexThread(id: threadID, title: "Running"))

        var resumeRequestCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/read":
                try? await Task.sleep(nanoseconds: 20_000_000)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Running"),
                            "turns": .array([
                                .object([
                                    "id": .string(turnID),
                                    "status": .string("running"),
                                ]),
                            ]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                resumeRequestCount += 1
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Running"),
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

        async let lightweightOutcome = service.catchUpRunningThreadIfNeeded(
            threadId: threadID,
            shouldForceResume: false
        )
        await Task.yield()
        let forcedOutcome = await service.catchUpRunningThreadIfNeeded(
            threadId: threadID,
            shouldForceResume: true
        )
        let initialOutcome = await lightweightOutcome

        XCTAssertEqual(resumeRequestCount, 1)
        XCTAssertTrue(forcedOutcome.isRunning)
        XCTAssertTrue(forcedOutcome.didRunForcedResume)
        XCTAssertTrue(initialOutcome.isRunning)
    }

    func testServerUpdateRearmsDeferredHistoryRefreshForLargeActiveChat() {
        let service = makeService()
        let threadID = "thread-large"
        let previousUpdatedAt = Date(timeIntervalSince1970: 10)
        let nextUpdatedAt = Date(timeIntervalSince1970: 20)

        service.activeThreadId = threadID
        service.threadsWithSatisfiedDeferredHistoryHydration.insert(threadID)
        service.messagesByThread[threadID] = (0..<401).map { index in
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "message-\(index)"
            )
        }

        let shouldRefresh = service.shouldRefreshDeferredHydrationForServerUpdate(
            incomingThread: CodexThread(
                id: threadID,
                title: "Large",
                preview: "new preview",
                updatedAt: nextUpdatedAt
            ),
            existingThread: CodexThread(
                id: threadID,
                title: "Large",
                preview: "old preview",
                updatedAt: previousUpdatedAt
            ),
            treatAsServerState: true
        )

        XCTAssertTrue(shouldRefresh)
    }

    func testForegroundSyncKeepsDeferredLargeClosedChatOffForcedHistoryRead() async {
        let service = makeService()
        let threadID = "thread-large-closed"

        service.isConnected = true
        service.isInitialized = true
        service.activeThreadId = threadID
        service.upsertThread(CodexThread(id: threadID, title: "Large Closed"))
        service.messagesByThread[threadID] = (0..<401).map { index in
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "message-\(index)"
            )
        }

        var lightweightTurnRefreshCount = 0
        var canonicalHistoryReadCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/read":
                let includeTurns = params?.objectValue?["includeTurns"]?.boolValue ?? false
                if includeTurns {
                    canonicalHistoryReadCount += 1
                    try? await Task.sleep(nanoseconds: 120_000_000)
                } else {
                    lightweightTurnRefreshCount += 1
                }
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadID),
                            "title": .string("Large Closed"),
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

        let startedAt = Date()
        await service.syncActiveThreadState(threadId: threadID)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(lightweightTurnRefreshCount, 1)
        XCTAssertLessThan(elapsed, 0.1)
        XCTAssertTrue(service.threadsNeedingCanonicalHistoryReconcile.contains(threadID))
        XCTAssertLessThanOrEqual(canonicalHistoryReadCount, 1)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceCatchupRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
