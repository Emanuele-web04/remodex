// FILE: CodexSecurePairingStateTests.swift
// Purpose: Verifies fresh QR scans force bootstrap mode and secure pairing failures stay actionable in UI state.
// Layer: Unit Test
// Exports: CodexSecurePairingStateTests
// Depends on: Foundation, XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexSecurePairingStateTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    override func setUp() {
        super.setUp()
        clearStoredSecureRelayState()
    }

    override func tearDown() {
        clearStoredSecureRelayState()
        super.tearDown()
    }

    func testRememberRelayPairingForcesFreshQRBootstrapEvenForTrustedMac() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let originalPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        let freshQRPublicKey = Data(repeating: 2, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: originalPublicKey,
            lastPairedAt: Date()
        )

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://relay.local/relay",
                sessionId: "session-\(UUID().uuidString)",
                macDeviceId: macDeviceID,
                macIdentityPublicKey: freshQRPublicKey,
                expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
            )
        )

        XCTAssertTrue(service.shouldForceQRBootstrapOnNextHandshake)
        XCTAssertFalse(service.hasTrustedReconnectContext)
        XCTAssertEqual(service.secureConnectionState, .trustedMac)
        XCTAssertEqual(service.normalizedRelayMacIdentityPublicKey, freshQRPublicKey)
    }

    func testRememberRelayPairingShowsHandshakeStateForBrandNewMac() {
        let service = makeService()
        let freshQRPublicKey = Data(repeating: 4, count: 32).base64EncodedString()

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://relay.local/relay",
                sessionId: "session-\(UUID().uuidString)",
                macDeviceId: "mac-\(UUID().uuidString)",
                macIdentityPublicKey: freshQRPublicKey,
                expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
            )
        )

        XCTAssertTrue(service.shouldForceQRBootstrapOnNextHandshake)
        XCTAssertEqual(service.secureConnectionState, .handshaking)
        XCTAssertEqual(service.secureMacFingerprint, codexSecureFingerprint(for: freshQRPublicKey))
    }

    func testRememberRelayPairingPersistsCloudAsyncSharedSecret() {
        let service = makeService()
        let sharedSecret = Data(repeating: 5, count: 32).base64EncodedString()

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "ws://relay.local/relay",
                sessionId: "session-\(UUID().uuidString)",
                macDeviceId: "mac-\(UUID().uuidString)",
                macIdentityPublicKey: Data(repeating: 6, count: 32).base64EncodedString(),
                cloudAsyncSharedSecret: sharedSecret,
                expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
            )
        )

        XCTAssertEqual(service.normalizedRelayCloudAsyncSharedSecret, sharedSecret)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.relayCloudAsyncSharedSecret),
            sharedSecret
        )
        XCTAssertTrue(service.hasCloudAsyncFallbackCredentials)
    }

    func testSecureServerHelloTimeoutStaysRecoverableForTrustedReconnectContext() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "wss://relay.local/relay"
        service.relayMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay"
        )
        service.secureConnectionState = .reconnecting
        service.connectionRecoveryState = .retrying(attempt: 2, message: "Reconnecting...")
        service.shouldAutoReconnectOnForeground = true

        let error = service.secureControlTimeoutError(for: "serverHello")

        XCTAssertEqual(
            error.localizedDescription,
            "Timed out waiting for the secure Remodex serverHello message."
        )
        XCTAssertEqual(service.secureConnectionState, .reconnecting)
        XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 2, message: "Reconnecting..."))
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertNil(service.lastErrorMessage)
    }

    func testSecureServerHelloTimeoutKeepsFreshQRBootstrapRecoverable() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "wss://relay.local/relay",
                sessionId: "session-\(UUID().uuidString)",
                macDeviceId: macDeviceID,
                macIdentityPublicKey: Data(repeating: 9, count: 32).base64EncodedString(),
                expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
            )
        )
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 10, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay"
        )
        service.connectionRecoveryState = .retrying(attempt: 2, message: "Reconnecting...")
        service.shouldAutoReconnectOnForeground = true

        let error = service.secureControlTimeoutError(for: "serverHello")

        XCTAssertEqual(
            error.localizedDescription,
            "Timed out waiting for the secure Remodex serverHello message."
        )
        XCTAssertNotEqual(service.secureConnectionState, .rePairRequired)
        XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 2, message: "Reconnecting..."))
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertNil(service.lastErrorMessage)
    }

    func testNonServerHelloTimeoutKeepsGenericSecureTimeoutState() {
        let service = makeService()

        let error = service.secureControlTimeoutError(for: "secureReady")

        XCTAssertEqual(
            error.localizedDescription,
            "Timed out waiting for the secure Remodex secureReady message."
        )
        XCTAssertNotEqual(service.secureConnectionState, .rePairRequired)
        XCTAssertEqual(service.connectionRecoveryState, .idle)
        XCTAssertFalse(service.shouldAutoReconnectOnForeground)
        XCTAssertNil(service.lastErrorMessage)
    }

    func testResetSecureTransportStateFallsBackToTrustedMacAfterRePairRequiredState() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "ws://relay.local/relay"
        service.relayMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 11, count: 32).base64EncodedString(),
            lastPairedAt: Date()
        )
        service.secureConnectionState = .rePairRequired
        service.secureMacFingerprint = "ABC123"

        service.resetSecureTransportState()

        XCTAssertEqual(service.secureConnectionState, .trustedMac)
        XCTAssertEqual(
            service.secureMacFingerprint,
            codexSecureFingerprint(for: service.trustedMacRegistry.records[macDeviceID]?.macIdentityPublicKey ?? "")
        )
    }

    func testApplyingResolvedTrustedSessionResetsReplayCursorWhenLiveSessionChanges() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.relaySessionId = "stale-session"
        service.relayUrl = "wss://relay.local/relay"
        service.relayMacDeviceId = macDeviceID
        service.lastAppliedBridgeOutboundSeq = 17
        SecureStore.writeString("17", for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)

        service.applyResolvedTrustedSession(
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: macDeviceID,
                macIdentityPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
                displayName: "Desk Mac",
                sessionId: "fresh-session"
            ),
            relayURL: "wss://relay.local/relay"
        )

        XCTAssertEqual(service.lastAppliedBridgeOutboundSeq, 0)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq),
            "0"
        )
    }

    func testApplyingResolvedTrustedSessionKeepsReplayCursorWhenLiveSessionIsUnchanged() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.relaySessionId = "same-session"
        service.relayUrl = "wss://relay.local/relay"
        service.relayMacDeviceId = macDeviceID
        service.lastAppliedBridgeOutboundSeq = 17
        SecureStore.writeString("17", for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)

        service.applyResolvedTrustedSession(
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: macDeviceID,
                macIdentityPublicKey: Data(repeating: 8, count: 32).base64EncodedString(),
                displayName: "Desk Mac",
                sessionId: "same-session"
            ),
            relayURL: "wss://relay.local/relay"
        )

        XCTAssertEqual(service.lastAppliedBridgeOutboundSeq, 17)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq),
            "17"
        )
    }

    // Clears the persisted relay session keys touched by secure reconnect tests.
    private func makeService() -> CodexService {
        let suiteName = "CodexSecurePairingStateTests.\(UUID().uuidString)"
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
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }
}
