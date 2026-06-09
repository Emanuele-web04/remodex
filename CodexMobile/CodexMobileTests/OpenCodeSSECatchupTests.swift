// FILE: OpenCodeSSECatchupTests.swift
// Purpose: Verifies reconnect catch-up preserves running markers without full transcript flash.

import XCTest
@testable import CodexMobile

@MainActor
final class OpenCodeSSECatchupTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testTransportDisconnectPreservesRunningCatchupTicket() async {
        let service = makeService()
        let threadID = "thread-catchup"
        service.isConnected = true
        service.runningThreadIDs.insert(threadID)
        service.activeTurnIdByThread[threadID] = "turn-catchup"
        service.hydratedThreadIDs.insert(threadID)

        await service.disconnect(preserveReconnectIntent: true)

        XCTAssertTrue(service.runningThreadIDs.contains(threadID))
        XCTAssertEqual(service.activeTurnID(for: threadID), "turn-catchup")
    }

    func testStreamingPresentationOnlyDoesNotClearTurnMap() {
        let service = makeService()
        let threadID = "thread-stream"
        service.activeTurnIdByThread[threadID] = "turn-stream"
        service.runningThreadIDs.insert(threadID)
        service.messagesByThread[threadID] = [
            CodexMessage(id: "m1", role: .assistant, text: "Hello", isStreaming: true)
        ]

        service.finalizeStreamingPresentationOnly()

        XCTAssertEqual(service.activeTurnID(for: threadID), "turn-stream")
        XCTAssertEqual(service.messagesByThread[threadID]?.first?.isStreaming, false)
    }

    func testHydrationCachePartialClearKeepsRunningThread() {
        let service = makeService()
        service.runningThreadIDs = ["thread-running", "thread-idle"]
        service.hydratedThreadIDs = ["thread-running", "thread-idle"]
        service.loadingThreadIDs = ["thread-idle"]

        service.clearHydrationCachesPreservingRunningThreads()

        XCTAssertTrue(service.hydratedThreadIDs.contains("thread-running"))
        XCTAssertFalse(service.hydratedThreadIDs.contains("thread-idle"))
        XCTAssertFalse(service.loadingThreadIDs.contains("thread-idle"))
    }

    private func makeService() -> CodexService {
        let suiteName = "OpenCodeSSECatchupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}