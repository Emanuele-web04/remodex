// FILE: CodexPushNotificationRegistrationTests.swift
// Purpose: Verifies APNs token persistence, registration gating, and deferred push routing for managed notifications.
// Layer: Unit Test
// Exports: CodexPushNotificationRegistrationTests
// Depends on: XCTest, UserNotifications, CodexMobile

import XCTest
import UserNotifications
@testable import CodexMobile

@MainActor
final class CodexPushNotificationRegistrationTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testRequestNotificationPermissionRegistersForRemoteNotificationsWhenAuthorized() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )

        await service.requestNotificationPermission(markPrompted: false)

        XCTAssertEqual(registrar.registerCallCount, 1)
        XCTAssertEqual(service.notificationAuthorizationStatus, .authorized)
    }

    func testInactiveCompletionKeepsBannerIntentWhenDeliveryIsDelayed() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: MockRemoteNotificationRegistrar()
        )
        service.applicationStateProvider = { .inactive }
        service.threads = [CodexThread(id: "thread-inactive", title: "Finished work")]

        service.notifyRunCompletionIfNeeded(
            threadId: "thread-inactive",
            turnId: "turn-inactive",
            result: .completed
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(center.addRequests.count, 1)
        XCTAssertEqual(
            center.addRequests.first?.content.userInfo[CodexNotificationPayloadKeys.presentWhenActive] as? Bool,
            true
        )
    }

    func testOnlyFreshTrackedTerminalEventsScheduleCompletionAlerts() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: MockRemoteNotificationRegistrar()
        )
        service.applicationStateProvider = { .inactive }
        for status in ["idle", "notLoaded", "active", "stopped", "unknown"] {
            service.handleNotification(method: "thread/status/changed", params: .object([
                "threadId": .string("status-\(status)"), "status": .object(["type": .string(status)]),
            ]))
        }

        let cases: [(id: String, start: Bool, marker: String?, status: String, age: Int)] = [
            ("untracked", false, nil, "completed", 0),
            ("replayed", true, "remodexReplayedEvent", "completed", 0),
            ("bootstrap", true, "remodexRolloutBootstrapReplay", "completed", 0),
            ("catchup", true, "remodexRolloutTerminalCatchUp", "completed", 0),
            ("stale", true, nil, "completed", 86_400),
            ("wrapped-stale", true, nil, "completed", 86_400),
            ("stopped", true, nil, "interrupted", 0),
            ("running", true, nil, "inProgress", 0),
            ("unknown", true, nil, "unknown", 0),
            ("success", true, nil, "completed", 0),
            ("failure", true, nil, "failed", 0),
        ]
        for scenario in cases {
            let threadID = "thread-\(scenario.id)"
            let turnID = "turn-\(scenario.id)"
            if scenario.start {
                service.handleNotification(method: "turn/started", params: .object([
                    "threadId": .string(threadID), "turnId": .string(turnID),
                ]))
            }
            var params: [String: JSONValue] = [
                "threadId": .string(threadID), "turnId": .string(turnID),
                "turn": .object([
                    "id": .string(turnID), "status": .string(scenario.status),
                    "completedAt": .integer(Int(Date().timeIntervalSince1970) - scenario.age),
                ]),
            ]
            if let marker = scenario.marker { params[marker] = .bool(true) }
            if scenario.id == "wrapped-stale", let turn = params.removeValue(forKey: "turn") {
                params["event"] = .object(["turn": turn])
            }
            service.handleNotification(method: "turn/completed", params: .object(params))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(Set(center.addRequests.compactMap {
            $0.content.userInfo[CodexNotificationPayloadKeys.turnId] as? String
        }), ["turn-success", "turn-failure"])
        XCTAssertEqual(center.addRequests.count, 2)
    }

    func testIDLessHistoryCannotEndTheCurrentRun() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: MockRemoteNotificationRegistrar()
        )
        service.applicationStateProvider = { .inactive }
        service.handleNotification(method: "turn/started", params: .object([
            "threadId": .string("live-thread"), "turnId": .string("live-turn"),
        ]))
        for marker in ["remodexReplayedEvent", "remodexRolloutBootstrapReplay", "remodexRolloutTerminalCatchUp"] {
            for method in ["turn/completed", "error"] {
                service.handleNotification(method: method, params: .object([
                    "threadId": .string("live-thread"), marker: .bool(true),
                ]))
                XCTAssertEqual(service.activeTurnID(for: "live-thread"), "live-turn")
                XCTAssertTrue(service.threadHasActiveOrRunningTurn("live-thread"))
            }
        }
        service.handleNotification(method: "turn/completed", params: .object([
            "threadId": .string("live-thread"), "turnId": .string("live-turn"),
            "status": .string("completed"),
        ]))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(center.addRequests.count, 1)
    }

    func testCompletionReceiptsSurviveRelaunchAndKeepDistinctRuns() async {
        let suiteName = "CodexCompletionReceipts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = MockUserNotificationCenter(status: .authorized)
        let first = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: MockRemoteNotificationRegistrar(),
            defaults: defaults
        )
        first.applicationStateProvider = { .inactive }
        first.notifyRunCompletionIfNeeded(threadId: "thread", turnId: "turn-a", result: .completed)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let relaunched = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: MockRemoteNotificationRegistrar(),
            defaults: defaults
        )
        relaunched.applicationStateProvider = { .inactive }
        relaunched.notifyRunCompletionIfNeeded(threadId: "thread", turnId: "turn-a", result: .completed)
        relaunched.notifyRunCompletionIfNeeded(threadId: "thread", turnId: "turn-a", result: .failed)
        relaunched.notifyRunCompletionIfNeeded(threadId: "thread", turnId: nil, result: .completed)
        relaunched.notifyRunCompletionIfNeeded(threadId: "thread", turnId: "turn-b", result: .completed)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(center.addRequests.compactMap {
            $0.content.userInfo[CodexNotificationPayloadKeys.turnId] as? String
        }, ["turn-a", "turn-b"])
    }

    func testIDLessStartsStillNotifyWhenTheRunFinishes() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: MockRemoteNotificationRegistrar()
        )
        service.applicationStateProvider = { .inactive }
        for canonicalID in [nil, "canonical-turn"] as [String?] {
            service.handleNotification(method: "turn/started", params: .object([
                "threadId": .string("idless-thread"),
            ]))
            var params: [String: JSONValue] = [
                "threadId": .string("idless-thread"), "status": .string("completed"),
            ]
            if let canonicalID { params["turnId"] = .string(canonicalID) }
            service.handleNotification(method: "turn/completed", params: .object(params))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let turnIDs = center.addRequests.compactMap {
            $0.content.userInfo[CodexNotificationPayloadKeys.turnId] as? String
        }
        XCTAssertEqual(turnIDs.count, 2)
        XCTAssertFalse(turnIDs.contains(""))
        XCTAssertEqual(turnIDs.last, "canonical-turn")
    }

    func testRemoteCompletionOwnershipRequiresConfirmedCurrentPairing() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: MockRemoteNotificationRegistrar()
        )
        service.applicationStateProvider = { .inactive }
        service.isConnected = true
        service.isInitialized = true
        service.relaySessionId = "paired-session"
        service.remoteNotificationDeviceToken = "aabbcc"
        await service.refreshNotificationAuthorizationStatus()
        for capability in [JSONValue.null, .bool(false), .bool(true)] {
            service.requestTransportOverride = { _, _ in
                RPCMessage(id: .string("register"), result: .object([
                    "ok": .bool(true), "completionPushEnabled": capability,
                ]), includeJSONRPC: false)
            }
            await service.syncManagedPushRegistrationIfNeeded(force: true)
            service.notifyRunCompletionIfNeeded(threadId: "thread", turnId: "\(capability)", result: .completed)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(center.addRequests.count, 2)
        service.relaySessionId = "different-pairing"
        service.notifyRunCompletionIfNeeded(threadId: "thread", turnId: "new-pairing-turn", result: .completed)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(center.addRequests.count, 3)
    }

    func testPushRegistrationIgnoresOldResponsesAndReleasesOwnershipOnFailure() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: MockRemoteNotificationRegistrar()
        )
        service.applicationStateProvider = { .inactive }
        service.isConnected = true
        service.isInitialized = true
        service.relaySessionId = "paired-session"
        service.remoteNotificationDeviceToken = "aabbcc"
        await service.refreshNotificationAuthorizationStatus()
        var pendingResponse: CheckedContinuation<RPCMessage, Error>?
        let registrationStarted = expectation(description: "First registration is waiting for a response")
        service.requestTransportOverride = { _, _ in
            try await withCheckedThrowingContinuation {
                pendingResponse = $0
                registrationStarted.fulfill()
            }
        }
        let oldRegistration = Task { await service.syncManagedPushRegistrationIfNeeded(force: true) }
        await fulfillment(of: [registrationStarted], timeout: 1)
        guard let pendingResponse else {
            oldRegistration.cancel()
            return XCTFail("The first registration never reached the transport")
        }
        service.requestTransportOverride = { _, _ in
            RPCMessage(id: .string("newer"), result: .object([
                "ok": .bool(true), "completionPushEnabled": .bool(false),
            ]), includeJSONRPC: false)
        }
        await service.syncManagedPushRegistrationIfNeeded(force: true)
        pendingResponse.resume(returning: RPCMessage(id: .string("older"), result: .object([
            "ok": .bool(true), "completionPushEnabled": .bool(true),
        ]), includeJSONRPC: false))
        await oldRegistration.value
        service.notifyRunCompletionIfNeeded(threadId: "thread", turnId: "after-race", result: .completed)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(center.addRequests.count, 1)

        service.requestTransportOverride = { _, _ in
            RPCMessage(id: .string("enabled"), result: .object([
                "ok": .bool(true), "completionPushEnabled": .bool(true),
            ]), includeJSONRPC: false)
        }
        await service.syncManagedPushRegistrationIfNeeded(force: true)
        service.requestTransportOverride = { _, _ in throw NSError(domain: "offline", code: 1) }
        await service.syncManagedPushRegistrationIfNeeded(force: true)
        service.notifyRunCompletionIfNeeded(threadId: "thread", turnId: "after-error", result: .completed)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(center.addRequests.count, 2)
    }

    func testSnapshotCompletionAlertsRequireRecentTimestampForTrackedTurn() async {
        for completionAge in [0, 86_400, nil] as [Int?] {
            let center = MockUserNotificationCenter(status: .authorized)
            let service = makeService(
                userNotificationCenter: center,
                remoteNotificationRegistrar: MockRemoteNotificationRegistrar()
            )
            service.applicationStateProvider = { .inactive }
            service.isConnected = true
            service.isInitialized = true
            service.supportsTurnPagination = true
            service.threads = [CodexThread(id: "thread-recovered", title: "Recovered work")]
            service.markThreadAsRunning("thread-recovered")
            service.setActiveTurnID("turn-recovered", for: "thread-recovered")
            var turn: [String: JSONValue] = [
                "id": .string("turn-recovered"), "status": .string("completed"),
            ]
            if let completionAge {
                turn["completedAt"] = .integer(Int(Date().timeIntervalSince1970) - completionAge)
            }
            service.requestTransportOverride = { method, _ in
                XCTAssertEqual(method, "thread/turns/list")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["data": .array([.object(turn)])]),
                    includeJSONRPC: false
                )
            }

            let didRefresh = await service.refreshInFlightTurnState(threadId: "thread-recovered")
            XCTAssertTrue(didRefresh)
            _ = await service.refreshInFlightTurnState(threadId: "thread-recovered")
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(center.addRequests.count, completionAge == 0 ? 1 : 0)
            XCTAssertFalse(service.threadHasActiveOrRunningTurn("thread-recovered"))
        }
    }

    func testHandleRemoteNotificationDeviceTokenSyncsManagedPushRegistration() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.isConnected = true
        service.isInitialized = true
        service.relaySessionId = "session-push"

        var recordedMethod: String?
        var recordedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            recordedMethod = method
            recordedParams = params
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["ok": .bool(true)]), includeJSONRPC: false)
        }

        service.handleRemoteNotificationDeviceToken(Data([0xAB, 0xCD, 0xEF]))
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(recordedMethod, "notifications/push/register")
        XCTAssertEqual(
            recordedParams?.objectValue?["deviceToken"]?.stringValue,
            "abcdef"
        )
        XCTAssertEqual(recordedParams?.objectValue?["alertsEnabled"]?.boolValue, true)
        XCTAssertEqual(recordedParams?.objectValue?["authorizationStatus"]?.stringValue, "authorized")
    }

    func testDeniedNotificationsKeepBridgeRegistrationDisabled() async {
        let center = MockUserNotificationCenter(status: .denied)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.isConnected = true
        service.isInitialized = true
        service.relaySessionId = "session-push"
        service.remoteNotificationDeviceToken = "deadbeef"

        var recordedParams: JSONValue?
        service.requestTransportOverride = { _, params in
            recordedParams = params
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["ok": .bool(true)]), includeJSONRPC: false)
        }

        await service.requestNotificationPermission(markPrompted: false)

        XCTAssertEqual(registrar.registerCallCount, 0)
        XCTAssertEqual(recordedParams?.objectValue?["alertsEnabled"]?.boolValue, false)
        XCTAssertEqual(recordedParams?.objectValue?["authorizationStatus"]?.stringValue, "denied")
    }

    func testRefreshManagedNotificationRegistrationStateReRegistersAfterSettingsChange() async {
        let center = MockUserNotificationCenter(status: .denied)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.isConnected = true
        service.isInitialized = true
        service.relaySessionId = "session-push"
        service.remoteNotificationDeviceToken = "deadbeef"

        var recordedMethod: String?
        var recordedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            recordedMethod = method
            recordedParams = params
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["ok": .bool(true)]), includeJSONRPC: false)
        }

        await service.refreshManagedNotificationRegistrationState()
        XCTAssertEqual(registrar.registerCallCount, 0)
        XCTAssertEqual(recordedParams?.objectValue?["authorizationStatus"]?.stringValue, "denied")

        center.status = .authorized
        await service.refreshManagedNotificationRegistrationState()

        XCTAssertEqual(registrar.registerCallCount, 1)
        XCTAssertEqual(recordedMethod, "notifications/push/register")
        XCTAssertEqual(recordedParams?.objectValue?["authorizationStatus"]?.stringValue, "authorized")
        XCTAssertEqual(recordedParams?.objectValue?["deviceToken"]?.stringValue, "deadbeef")
    }

    func testNotificationOpenStaysPendingUntilThreadBecomesAvailable() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )

        service.handleNotificationOpen(threadId: "thread-pending", turnId: "turn-pending")
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(service.pendingNotificationOpenThreadID, "thread-pending")
        XCTAssertEqual(service.externalThreadOpenRequest?.threadId, "thread-pending")
        XCTAssertNil(service.activeThreadId)

        service.threads = [CodexThread(id: "thread-pending", title: "Pending thread")]
        let routed = await service.routePendingNotificationOpenIfPossible(refreshIfNeeded: false)

        XCTAssertTrue(routed)
        XCTAssertEqual(service.activeThreadId, "thread-pending")
        XCTAssertNil(service.pendingNotificationOpenThreadID)
    }

    func testDisconnectPreservesPendingNotificationTargetAcrossReconnectIntent() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.pendingNotificationOpenThreadID = "thread-after-reconnect"

        await service.disconnect(preserveReconnectIntent: true)

        XCTAssertEqual(service.pendingNotificationOpenThreadID, "thread-after-reconnect")
    }

    func testMissingNotificationTargetStaysPendingWhenOnlyThreadListOmitsIt() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.isConnected = true
        service.pendingNotificationOpenThreadID = "thread-missing-from-list"
        service.threads = [
            CodexThread(id: "thread-live", title: "Live thread"),
        ]
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/list":
                let isArchived = params?.objectValue?["archived"]?.boolValue ?? false
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array(isArchived ? [] : [
                            makeThreadJSON(id: "thread-live", title: "Live thread"),
                        ]),
                        "nextCursor": .null,
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

        let routed = await service.routePendingNotificationOpenIfPossible()

        XCTAssertFalse(routed)
        XCTAssertEqual(service.pendingNotificationOpenThreadID, "thread-missing-from-list")
        XCTAssertNil(service.activeThreadId)
        XCTAssertNil(service.missingNotificationThreadPrompt)
    }

    func testExplicitlyMissingNotificationTargetShowsPromptAndFallsBackToExistingThread() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.isConnected = true
        service.pendingNotificationOpenThreadID = "thread-deleted"
        service.externalThreadOpenRequest = CodexExternalThreadOpenRequest(threadId: "thread-deleted")
        service.threads = [
            CodexThread(id: "thread-deleted", title: "Deleted thread", syncState: .archivedLocal),
            CodexThread(id: "thread-live", title: "Live thread"),
        ]

        let routed = await service.routePendingNotificationOpenIfPossible(refreshIfNeeded: false)

        XCTAssertFalse(routed)
        XCTAssertNil(service.pendingNotificationOpenThreadID)
        XCTAssertNil(service.externalThreadOpenRequest)
        XCTAssertEqual(service.activeThreadId, "thread-live")
        XCTAssertEqual(service.missingNotificationThreadPrompt?.threadId, "thread-deleted")
    }

    func testExplicitlyMissingNotificationTargetClearsSelectionWhenOnlyArchivedThreadsRemain() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.isConnected = true
        service.activeThreadId = "thread-deleted"
        service.pendingNotificationOpenThreadID = "thread-deleted"
        service.threads = [
            CodexThread(id: "thread-deleted", title: "Deleted thread", syncState: .archivedLocal),
        ]

        let routed = await service.routePendingNotificationOpenIfPossible(refreshIfNeeded: false)

        XCTAssertFalse(routed)
        XCTAssertNil(service.pendingNotificationOpenThreadID)
        XCTAssertNil(service.activeThreadId)
        XCTAssertEqual(service.missingNotificationThreadPrompt?.threadId, "thread-deleted")
    }

    func testNotificationOpenStaysPendingWhenThreadRefreshFails() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.isConnected = true
        service.pendingNotificationOpenThreadID = "thread-still-exists"
        service.threads = [
            CodexThread(id: "thread-live", title: "Live thread"),
        ]
        service.requestTransportOverride = { method, _ in
            if method == "thread/list" {
                throw CodexServiceError.invalidResponse("temporary refresh failure")
            }
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        let routed = await service.routePendingNotificationOpenIfPossible()

        XCTAssertFalse(routed)
        XCTAssertEqual(service.pendingNotificationOpenThreadID, "thread-still-exists")
        XCTAssertNil(service.missingNotificationThreadPrompt)
        XCTAssertNil(service.activeThreadId)
    }

    func testNotificationOpenFallsBackToFreshThreadListWhenLocalThreadIsStale() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.isConnected = true
        service.isInitialized = true
        service.pendingNotificationOpenThreadID = "thread-stale"
        service.threads = [
            CodexThread(id: "thread-stale", title: "Stale thread"),
            CodexThread(id: "thread-other", title: "Other thread"),
        ]

        var resumeCallCount = 0
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/resume":
                resumeCallCount += 1
                if resumeCallCount == 1 {
                    throw CodexServiceError.rpcError(
                        RPCError(code: -32000, message: "thread not found")
                    )
                }

                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": makeThreadJSON(id: "thread-stale", title: "Recovered thread"),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/list":
                let isArchived = params?.objectValue?["archived"]?.boolValue ?? false
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array(isArchived ? [] : [
                            makeThreadJSON(id: "thread-stale", title: "Recovered thread"),
                            makeThreadJSON(id: "thread-other", title: "Other thread"),
                        ]),
                        "nextCursor": .null,
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

        let routed = await service.routePendingNotificationOpenIfPossible()

        XCTAssertTrue(routed)
        XCTAssertEqual(service.activeThreadId, "thread-stale")
        XCTAssertNil(service.pendingNotificationOpenThreadID)
        XCTAssertNil(service.missingNotificationThreadPrompt)
        XCTAssertEqual(resumeCallCount, 2)
    }

    func testSuccessfulThreadReconcileRetriesPendingNotificationOpen() async {
        let center = MockUserNotificationCenter(status: .authorized)
        let registrar = MockRemoteNotificationRegistrar()
        let service = makeService(
            userNotificationCenter: center,
            remoteNotificationRegistrar: registrar
        )
        service.isConnected = true
        service.isInitialized = true
        service.pendingNotificationOpenThreadID = "thread-retry"

        service.requestTransportOverride = { method, _ in
            switch method {
            case "thread/resume":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": makeThreadJSON(id: "thread-retry", title: "Retry thread"),
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

        service.reconcileLocalThreadsWithServer([CodexThread(id: "thread-retry", title: "Retry thread")])
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(service.activeThreadId, "thread-retry")
        XCTAssertNil(service.pendingNotificationOpenThreadID)
        XCTAssertNil(service.missingNotificationThreadPrompt)
    }

    private func makeService(
        userNotificationCenter: CodexUserNotificationCentering,
        remoteNotificationRegistrar: CodexRemoteNotificationRegistering,
        defaults providedDefaults: UserDefaults? = nil
    ) -> CodexService {
        let suiteName = "CodexPushNotificationRegistrationTests.\(UUID().uuidString)"
        let defaults = providedDefaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        if providedDefaults == nil { defaults.removePersistentDomain(forName: suiteName) }
        let service = CodexService(
            defaults: defaults,
            userNotificationCenter: userNotificationCenter,
            remoteNotificationRegistrar: remoteNotificationRegistrar
        )
        Self.retainedServices.append(service)
        return service
    }

    private func clearStoredRelayPairing() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
    }
}

private func makeThreadJSON(id: String, title: String) -> JSONValue {
    .object([
        "id": .string(id),
        "title": .string(title),
    ])
}

private final class MockRemoteNotificationRegistrar: CodexRemoteNotificationRegistering {
    private(set) var registerCallCount = 0

    @MainActor
    func registerForRemoteNotifications() {
        registerCallCount += 1
    }
}

private final class MockUserNotificationCenter: CodexUserNotificationCentering {
    var delegate: UNUserNotificationCenterDelegate?
    var status: UNAuthorizationStatus
    private(set) var addRequests: [UNNotificationRequest] = []

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func add(_ request: UNNotificationRequest) async throws {
        addRequests.append(request)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }
}
