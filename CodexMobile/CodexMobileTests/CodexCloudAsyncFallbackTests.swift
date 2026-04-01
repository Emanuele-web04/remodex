// FILE: CodexCloudAsyncFallbackTests.swift
// Purpose: Verifies the CloudKit async fallback can initialize the service without a live websocket.
// Layer: Unit Test
// Exports: CodexCloudAsyncFallbackTests
// Depends on: XCTest, Foundation, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile


final class FakeAsyncTransport: CodexAsyncRequestTransporting {
    private let lock = NSLock()
    private var requestedMethodsStorage: [String] = []
    private var notifiedMethodsStorage: [String] = []
    var requestHandler: ((String, JSONValue?, JSONValue, CodexService) throws -> RPCMessage)?
    var availabilityHandler: (() async -> CodexCloudAsyncAvailability)?

    func methodSnapshots() -> (requested: [String], notified: [String]) {
        lock.withLock {
            (requestedMethodsStorage, notifiedMethodsStorage)
        }
    }

    func availability(for service: CodexService) async -> CodexCloudAsyncAvailability {
        if let availabilityHandler {
            return await availabilityHandler()
        }
        return .available
    }

    func performRequest(
        method: String,
        params: JSONValue?,
        requestID: JSONValue,
        service: CodexService
    ) async throws -> RPCMessage {
        let handler = lock.withLock {
            requestedMethodsStorage.append(method)
            return self.requestHandler
        }

        if let handler {
            return try handler(method, params, requestID, service)
        }

        return RPCMessage(id: requestID, result: .object([:]), includeJSONRPC: false)
    }

    func performNotification(
        method: String,
        params: JSONValue?,
        service: CodexService
    ) async throws {
        lock.withLock {
            notifiedMethodsStorage.append(method)
        }
    }
}

extension XCTestCase {
    @MainActor
    func makeTestService(
        defaults: UserDefaults? = nil,
        persistenceNamespace: String? = nil,
        retain: inout [CodexService]
    ) -> CodexService {
        let suiteName = persistenceNamespace ?? "TestService.\(UUID().uuidString)"
        let resolvedDefaults = defaults ?? UserDefaults(suiteName: suiteName)!
        resolvedDefaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: resolvedDefaults)
        retain.append(service)
        return service
    }

    func makeSuccessResponse(
        id: JSONValue = .string(UUID().uuidString),
        result: [String: JSONValue]
    ) -> RPCMessage {
        RPCMessage(
            id: id,
            result: .object(result),
            includeJSONRPC: false
        )
    }

    func makeThreadJSON(id: String, title: String) -> JSONValue {
        .object([
            "id": .string(id),
            "title": .string(title),
            "turns": .array([]),
        ])
    }

    @MainActor
    func waitUntil(
        _ condition: @escaping () -> Bool,
        timeoutSeconds: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Timed out waiting for condition.", file: file, line: line)
    }
}

@MainActor
final class CodexCloudAsyncFallbackTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    override func setUp() {
        super.setUp()
        clearStoredSecureRelayState()
    }

    override func tearDown() {
        clearStoredSecureRelayState()
        super.tearDown()
    }

    func testActivateCloudAsyncFallbackInitializesWithoutWebSocket() async throws {
        let service = makeService()
        let transport = FakeAsyncTransport()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let sharedSecret = Data(repeating: 7, count: 32).base64EncodedString()

        service.convexTransport = transport
        service.relayUrl = relayURL
        service.relayMacDeviceId = macDeviceID
        service.relayMacIdentityPublicKey = Data(repeating: 8, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = sharedSecret
        service.trustedReconnectFailureCount = 2
        service.bridgeUpdatePrompt = CodexBridgeUpdatePrompt(
            title: "Update bridge",
            message: "Bridge update still required.",
            command: "npm install -g remodex@latest"
        )

        try await service.activateConvexLane(serverURL: "\(relayURL)/session-123", performInitialSync: false)

        XCTAssertEqual(service.transportMode, .convexRemote)
        XCTAssertTrue(service.isConnected)
        XCTAssertTrue(service.isInitialized)
        XCTAssertEqual(service.trustedReconnectFailureCount, 0)
        XCTAssertNil(service.bridgeUpdatePrompt)
        let snapshots = transport.methodSnapshots()
        XCTAssertTrue(snapshots.requested.contains("initialize"))
        XCTAssertTrue(snapshots.requested.contains("collaborationMode/list"))
        XCTAssertTrue(snapshots.notified.contains("initialized"))
    }

    @MainActor
    func testSetTransportPreferenceConvexOnlyUsesRealConvexActivationPath() async throws {
        let transport = makeConvexOnlyTransitionTransport()
        let service = makeConvexOnlyTransitionService(transport: transport)

        service.setTransportPreference(.convexOnly)

        await waitUntil {
            service.transportMode == .convexRemote
                && service.isConnected
                && service.isInitialized
        }

        XCTAssertEqual(service.transportPreference, .convexOnly)
        let snapshots = transport.methodSnapshots()
        XCTAssertTrue(snapshots.requested.contains("initialize"))
        XCTAssertTrue(snapshots.requested.contains("collaborationMode/list"))
        XCTAssertTrue(snapshots.notified.contains("initialized"))
    }

    @MainActor
    func testConvexOnlyPreferencePathCanSendRequestAfterSwitching() async throws {
        let transport = makeConvexOnlyTransitionTransport()
        let service = makeConvexOnlyTransitionService(transport: transport)

        service.setTransportPreference(.convexOnly)

        await waitUntil {
            service.transportMode == .convexRemote
                && service.isConnected
                && service.isInitialized
        }

        let requestedMethodsBeforeSend = transport.methodSnapshots().requested
        let response = try await service.sendRequest(
            method: "test/convex-only",
            params: .object(["message": .string("hello")])
        )

        let snapshots = transport.methodSnapshots()
        XCTAssertTrue(snapshots.notified.contains("initialized"))
        let appendedMethods = Array(snapshots.requested.dropFirst(requestedMethodsBeforeSend.count))
        XCTAssertTrue(appendedMethods.contains("test/convex-only"))
        XCTAssertEqual(
            response.result,
            .object(["echoMethod": .string("test/convex-only")])
        )
    }

    func testCloudAsyncFallbackCredentialsStayBoundToRelayMacWhenPreferredTrustDiffers() {
        let service = makeService()
        let relayMacDeviceID = "relay-mac-\(UUID().uuidString)"
        let preferredMacDeviceID = "preferred-mac-\(UUID().uuidString)"
        let relayPublicKey = Data(repeating: 11, count: 32).base64EncodedString()
        let preferredPublicKey = Data(repeating: 12, count: 32).base64EncodedString()
        let relaySecret = Data(repeating: 13, count: 32).base64EncodedString()
        let preferredSecret = Data(repeating: 14, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[preferredMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: preferredMacDeviceID,
            macIdentityPublicKey: preferredPublicKey,
            lastPairedAt: Date(),
            relayURL: "wss://relay-b.local/relay",
            cloudAsyncSharedSecret: preferredSecret
        )
        service.lastTrustedMacDeviceId = preferredMacDeviceID
        service.relayMacDeviceId = relayMacDeviceID
        service.relayMacIdentityPublicKey = relayPublicKey
        service.relayCloudAsyncSharedSecret = relaySecret

        let credentials = service.cloudAsyncFallbackCredentials

        XCTAssertEqual(credentials?.macDeviceId, relayMacDeviceID)
        XCTAssertEqual(credentials?.macIdentityPublicKey, relayPublicKey)
        XCTAssertEqual(credentials?.sharedSecretBase64, relaySecret)
        XCTAssertTrue(service.hasCloudAsyncFallbackCredentials)
    }

    func testCloudAsyncFallbackCredentialsDoNotSwitchToDifferentTrustedMacWhenRelaySecretIsMissing() {
        let service = makeService()
        let relayMacDeviceID = "relay-mac-\(UUID().uuidString)"
        let preferredMacDeviceID = "preferred-mac-\(UUID().uuidString)"

        service.trustedMacRegistry.records[preferredMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: preferredMacDeviceID,
            macIdentityPublicKey: Data(repeating: 15, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay-b.local/relay",
            cloudAsyncSharedSecret: Data(repeating: 16, count: 32).base64EncodedString()
        )
        service.lastTrustedMacDeviceId = preferredMacDeviceID
        service.relayMacDeviceId = relayMacDeviceID
        service.relayMacIdentityPublicKey = Data(repeating: 17, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = nil

        XCTAssertNil(service.cloudAsyncFallbackCredentials)
        XCTAssertFalse(service.hasCloudAsyncFallbackCredentials)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexCloudAsyncFallbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    @MainActor
    private func makeConvexOnlyTransitionService(
        transport: FakeAsyncTransport
    ) -> CodexService {
        let service = makeService()
        service.convexTransport = transport
        service.isConnected = true
        service.transportMode = .lanRelay
        service.relayUrl = "ws://192.168.1.31:9000/relay"
        service.relaySessionId = "session-1"
        service.relayMacDeviceId = "mac-device-1"
        service.relayMacIdentityPublicKey = Data(repeating: 8, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 7, count: 32).base64EncodedString()
        return service
    }

    @MainActor
    private func makeConvexOnlyTransitionTransport() -> FakeAsyncTransport {
        let transport = FakeAsyncTransport()
        transport.requestHandler = { method, _, requestID, _ in
            switch method {
            case "initialize":
                return RPCMessage(id: requestID, result: .object([:]), includeJSONRPC: false)
            case "collaborationMode/list":
                return RPCMessage(
                    id: requestID,
                    result: .object([
                        "modes": .array([
                            .object([
                                "mode": .string("plan"),
                            ]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                return RPCMessage(
                    id: requestID,
                    result: .object([
                        "echoMethod": .string(method),
                    ]),
                    includeJSONRPC: false
                )
            }
        }
        return transport
    }


    private func clearStoredSecureRelayState() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayCloudAsyncSharedSecret)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }
}
