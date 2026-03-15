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
        service.threads = [
            CodexThread(id: "thread-deleted", title: "Deleted thread", syncState: .archivedLocal),
            CodexThread(id: "thread-live", title: "Live thread"),
        ]

        let routed = await service.routePendingNotificationOpenIfPossible(refreshIfNeeded: false)

        XCTAssertFalse(routed)
        XCTAssertNil(service.pendingNotificationOpenThreadID)
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

        service.reconcileLocalThreadsWithServer(
            [CodexThread(id: "thread-retry", title: "Retry thread")],
            serverArchivedThreads: []
        )
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(service.activeThreadId, "thread-retry")
        XCTAssertNil(service.pendingNotificationOpenThreadID)
        XCTAssertNil(service.missingNotificationThreadPrompt)
    }

    private func makeService(
        userNotificationCenter: CodexUserNotificationCentering,
        remoteNotificationRegistrar: CodexRemoteNotificationRegistering
    ) -> CodexService {
        let suiteName = "CodexPushNotificationRegistrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
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
