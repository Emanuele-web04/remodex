// FILE: CodexServiceDiscoveredExternalSyncTests.swift
// Purpose: Verifies iOS background sync skips class (e) discovered external OpenCode threads until user open.
// Layer: Unit Test
// Exports: CodexServiceDiscoveredExternalSyncTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceDiscoveredExternalSyncTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testDiscoveredExternalThreadSkipsActiveSyncHistoryAndResume() async {
        let service = makeService()
        let threadID = "opencode-session-ses_mac_cli_01"

        service.isConnected = true
        service.isInitialized = true
        service.activeThreadId = threadID
        service.runningThreadIDs.insert(threadID)
        service.upsertThread(
            CodexThread(
                id: threadID,
                title: "Mac CLI session",
                modelProvider: "opencode",
                metadata: [
                    "provider": .string("opencode"),
                    "discoveredExternally": .bool(true),
                    "sessionId": .string("ses_mac_cli_01"),
                ]
            )
        )

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        await service.syncActiveThreadState(threadId: threadID)

        XCTAssertTrue(recordedMethods.isEmpty)
        XCTAssertTrue(service.shouldSkipBackgroundSyncForDiscoveredExternalThread(threadId: threadID))
    }

    func testDiscoveredExternalThreadSkipsRunningWatchCatchup() async {
        let service = makeService()
        let threadID = "opencode-session-ses_watch_01"

        service.isConnected = true
        service.isInitialized = true
        service.runningThreadIDs.insert(threadID)
        service.upsertThread(
            CodexThread(
                id: threadID,
                title: "Watch session",
                modelProvider: "opencode",
                metadata: ["discoveredExternally": .bool(true)]
            )
        )
        service.runningThreadWatchByID[threadID] = CodexRunningThreadWatch(
            threadId: threadID,
            expiresAt: Date().addingTimeInterval(60)
        )

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        await service.refreshInactiveRunningBadgeThreads()

        XCTAssertTrue(recordedMethods.isEmpty)
    }

    func testDiscoveredExternalThreadSkipsSyncThreadHistory() async {
        let service = makeService()
        let threadID = "opencode-session-ses_history_01"

        service.isConnected = true
        service.isInitialized = true
        service.upsertThread(
            CodexThread(
                id: threadID,
                title: "History session",
                modelProvider: "opencode",
                metadata: ["discoveredExternally": .bool(true)]
            )
        )

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        await service.syncThreadHistory(threadId: threadID)

        XCTAssertTrue(recordedMethods.isEmpty)
    }

    func testResumedDiscoveredExternalThreadSkipsSyncEvenWithStaleMetadata() async {
        let service = makeService()
        let threadID = "opencode-session-ses_stale_meta"

        service.isConnected = true
        service.isInitialized = true
        service.resumedThreadIDs.insert(threadID)
        service.upsertThread(
            CodexThread(
                id: threadID,
                title: "Stale metadata session",
                modelProvider: "opencode",
                metadata: ["discoveredExternally": .bool(true)]
            )
        )

        XCTAssertFalse(service.shouldSkipBackgroundSyncForDiscoveredExternalThread(threadId: threadID))
    }

    func testAdoptedDiscoveredExternalThreadAllowsBackgroundSync() async {
        let service = makeService()
        let threadID = "opencode-session-ses_adopted_01"

        service.isConnected = true
        service.isInitialized = true
        service.resumedThreadIDs.insert(threadID)
        service.upsertThread(
            CodexThread(
                id: threadID,
                title: "Adopted session",
                modelProvider: "opencode",
                metadata: [
                    "provider": .string("opencode"),
                    "sessionId": .string("ses_adopted_01"),
                ]
            )
        )

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string(threadID),
                        "title": .string("Adopted session"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        await service.syncActiveThreadState(threadId: threadID)

        XCTAssertFalse(service.shouldSkipBackgroundSyncForDiscoveredExternalThread(threadId: threadID))
        XCTAssertTrue(recordedMethods.contains("thread/resume") || recordedMethods.contains("thread/read"))
    }

    func testCatchUpRunningThreadSkipsDiscoveredExternalPrefixWithoutMetadata() async {
        let service = makeService()
        let threadID = "opencode-session-ses_prefix_only"

        service.isConnected = true
        service.isInitialized = true
        service.runningThreadIDs.insert(threadID)
        service.upsertThread(CodexThread(id: threadID, title: "Prefix only", modelProvider: "opencode"))

        var resumeRequestCount = 0
        service.requestTransportOverride = { method, _ in
            if method == "thread/resume" {
                resumeRequestCount += 1
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        let outcome = await service.catchUpRunningThreadIfNeeded(
            threadId: threadID,
            shouldForceResume: true
        )

        XCTAssertEqual(resumeRequestCount, 0)
        XCTAssertFalse(outcome.didRunForcedResume)
        XCTAssertFalse(outcome.isRunning)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceDiscoveredExternalSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}