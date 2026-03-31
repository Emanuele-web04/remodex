// FILE: CodexCloudAsyncFallbackTests.swift
// Purpose: Verifies the CloudKit async fallback can initialize the service without a live websocket.
// Layer: Unit Test
// Exports: CodexCloudAsyncFallbackTests
// Depends on: XCTest, Foundation, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

private final class FakeCloudAsyncTransport: CodexAsyncRequestTransporting {
    var requestedMethods: [String] = []
    var notifiedMethods: [String] = []

    func availability(for service: CodexService) async -> CodexCloudAsyncAvailability {
        .available
    }

    func performRequest(
        method: String,
        params: JSONValue?,
        requestID: JSONValue,
        service: CodexService
    ) async throws -> RPCMessage {
        requestedMethods.append(method)
        return RPCMessage(id: requestID, result: .object([:]), includeJSONRPC: false)
    }

    func performNotification(
        method: String,
        params: JSONValue?,
        service: CodexService
    ) async throws {
        notifiedMethods.append(method)
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
        let transport = FakeCloudAsyncTransport()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let sharedSecret = Data(repeating: 7, count: 32).base64EncodedString()

        service.cloudAsyncTransport = transport
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

        try await service.activateCloudAsyncFallback(serverURL: "\(relayURL)/session-123", performInitialSync: false)

        XCTAssertEqual(service.transportMode, .cloudAsyncFallback)
        XCTAssertTrue(service.isConnected)
        XCTAssertTrue(service.isInitialized)
        XCTAssertEqual(service.trustedReconnectFailureCount, 0)
        XCTAssertNil(service.bridgeUpdatePrompt)
        XCTAssertEqual(transport.requestedMethods.first, "initialize")
        XCTAssertEqual(transport.notifiedMethods.first, "initialized")
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
