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
