// FILE: CodexServiceConnectionErrorTests.swift
// Purpose: Verifies background disconnects stay silent while real connection failures still surface.
// Layer: Unit Test
// Exports: CodexServiceConnectionErrorTests
// Depends on: XCTest, Network, UIKit, CodexMobile

import XCTest
import Network
import UIKit
@testable import CodexMobile

@MainActor
final class CodexServiceConnectionErrorTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testBenignBackgroundAbortIsSuppressedFromUserFacingErrors() {
        let service = makeService()
        let error = NWError.posix(.ECONNABORTED)
        service.isAppInForeground = false

        XCTAssertTrue(service.isBenignBackgroundDisconnect(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testSendSideNoDataDisconnectIsTreatedAsBenign() {
        let service = makeService()
        let error = NWError.posix(.ENODATA)
        service.isAppInForeground = false

        XCTAssertTrue(service.isBenignBackgroundDisconnect(error))
        XCTAssertTrue(service.shouldTreatSendFailureAsDisconnect(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testConnectionResetIsTreatedAsBenignRelayDisconnect() {
        let service = makeService()
        let error = NWError.posix(.ECONNRESET)
        service.isAppInForeground = false

        XCTAssertTrue(service.isBenignBackgroundDisconnect(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testInactiveAppStateStillSuppressesBenignDisconnectNoise() {
        let service = makeService()
        let error = NWError.posix(.ECONNRESET)
        service.isAppInForeground = true
        service.applicationStateProvider = { .inactive }

        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testTransientTimeoutStillSurfacesToUser() {
        let service = makeService()
        let error = NWError.posix(.ETIMEDOUT)

        XCTAssertTrue(service.isRecoverableTransientConnectionError(error))
        XCTAssertFalse(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testOversizedRelayPayloadGetsFriendlyFailureCopy() {
        let service = makeService()
        let error = NWError.posix(.EMSGSIZE)

        XCTAssertTrue(service.isOversizedRelayPayloadError(error))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(error),
            "A thread payload was too large for the relay connection. This can happen while reopening image-heavy chats even if you didn't press Send."
        )
    }

    func testReceiveDispositionUsesFriendlyOversizedPayloadMessage() {
        let service = makeService()
        let error = NWError.posix(.EMSGSIZE)

        service.handleReceiveError(error)

        XCTAssertEqual(
            service.lastErrorMessage,
            "A thread payload was too large for the relay connection. This can happen while reopening image-heavy chats even if you didn't press Send."
        )
    }

    func testValidateOutgoingWebSocketMessageSizeRejectsOversizedPayload() {
        let service = makeService()
        let oversizedText = String(repeating: "a", count: codexWebSocketMaximumMessageSizeBytes + 1)

        XCTAssertThrowsError(try service.validateOutgoingWebSocketMessageSize(oversizedText)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "This payload is too large for the relay connection. Try fewer or smaller images and retry."
            )
        }
    }

    func testBenignDisconnectStaysSilentWhileAutoReconnectIsRunning() {
        let service = makeService()
        let error = CodexServiceError.disconnected
        service.isAppInForeground = true
        service.shouldAutoReconnectOnForeground = true
        service.connectionRecoveryState = .retrying(attempt: 1, message: "Reconnecting...")

        XCTAssertTrue(service.shouldSuppressRecoverableConnectionError(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testConnectionRefusedStillSurfacesToUser() {
        let service = makeService()
        let error = NWError.posix(.ECONNREFUSED)

        XCTAssertFalse(service.shouldSuppressUserFacingConnectionError(error))
        XCTAssertEqual(
            service.userFacingConnectError(
                error: error,
                attemptedURL: "wss://relay.example/relay/session",
                host: "relay.example"
            ),
            "Connection refused by relay server at wss://relay.example/relay/session."
        )
    }

    func testBenignBackgroundAbortGetsFriendlyFailureCopy() {
        let service = makeService()

        XCTAssertEqual(
            service.userFacingConnectFailureMessage(NWError.posix(.ECONNABORTED)),
            "Connection was interrupted. Tap Reconnect to try again."
        )
    }

    func testBrokenPipeGetsFriendlyFailureCopy() {
        let service = makeService()

        XCTAssertEqual(
            service.userFacingConnectFailureMessage(NWError.posix(.EPIPE)),
            "Connection was interrupted. Tap Reconnect to try again."
        )
    }

    func testTurnErrorSuppressesBrokenPipeWhileAutoReconnectIsRunning() {
        let service = makeService()
        let error = NWError.posix(.EPIPE)
        service.isAppInForeground = true
        service.shouldAutoReconnectOnForeground = true
        service.connectionRecoveryState = .retrying(attempt: 1, message: "Reconnecting...")

        XCTAssertTrue(service.shouldSuppressRecoverableConnectionError(error))
        XCTAssertEqual(service.userFacingTurnErrorMessage(from: error), "")
    }

    func testConnectTimeSessionUnavailableCloseIsRetryable() {
        let service = makeService()
        let error = CodexServiceError.invalidInput("WebSocket closed during connect (4002)")

        XCTAssertTrue(service.isRetryableSavedSessionConnectError(error))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(error),
            "The saved Mac session is temporarily unavailable. Remodex will keep retrying. If you restarted the bridge on your Mac, scan the new QR code."
        )
    }

    func testLanAddressStillRequiresLocalNetworkAuthorization() {
        let service = makeService()
        let url = URL(string: "ws://192.168.1.31:9000/relay/session")!

        XCTAssertTrue(service.requiresLocalNetworkAuthorization(for: url))
        XCTAssertTrue(service.prefersDirectRelayTransport(for: url))
    }

    func testTailscaleAddressPrefersDirectRelayTransportWithoutLocalNetworkPrompt() {
        let service = makeService()
        let url = URL(string: "ws://100.122.27.82:9000/relay/session")!

        XCTAssertTrue(service.prefersDirectRelayTransport(for: url))
        XCTAssertFalse(service.requiresLocalNetworkAuthorization(for: url))
    }

    func testTailscaleMagicDNSHostPrefersDirectRelayTransportWithoutLocalNetworkPrompt() {
        let service = makeService()
        let url = URL(string: "ws://my-mac.tail-scale.ts.net:9000/relay/session")!

        XCTAssertTrue(service.prefersDirectRelayTransport(for: url))
        XCTAssertFalse(service.requiresLocalNetworkAuthorization(for: url))
    }

    func testDirectRelaySocketTimeoutRemainsRetryable() {
        let service = makeService()
        let error = CodexServiceError.invalidInput(
            "Connection timed out after 12s while opening the direct relay socket."
        )

        XCTAssertTrue(service.isRecoverableTransientConnectionError(error))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(error),
            "Connection timed out. Check server/network."
        )
    }

    func testSecureTransportTimeoutIsRetryableForAutoRecovery() {
        let service = makeService()
        let error = CodexSecureTransportError.timedOut(
            "Timed out waiting for the secure Remodex serverHello message."
        )

        XCTAssertTrue(service.isRecoverableTransientConnectionError(error))
    }

    func testCloudAsyncFallbackIsBlockedWhileLocalRelayPathIsAvailable() {
        let service = makeService()
        service.relayMacDeviceId = "mac-123"
        service.relayMacIdentityPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 2, count: 32).base64EncodedString()
        service.localRelayPathAvailabilityOverride = { true }

        XCTAssertFalse(
            service.shouldAttemptCloudAsyncFallback(
                after: NWError.posix(.ETIMEDOUT),
                serverURL: "ws://192.168.1.31:9000/relay/session"
            )
        )
    }

    func testCloudAsyncFallbackIsNotBlockedByGenericLocalRelayPathMonitorState() {
        let service = makeService()
        service.relayMacDeviceId = "mac-123"
        service.relayMacIdentityPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 2, count: 32).base64EncodedString()
        service.hasResolvedLocalRelayPathAvailability = true
        service.hasActiveLocalRelayPath = true

        XCTAssertTrue(
            service.shouldAttemptCloudAsyncFallback(
                after: NWError.posix(.ETIMEDOUT),
                serverURL: "ws://192.168.1.31:9000/relay/session"
            )
        )
    }

    func testCloudAsyncFallbackIsAllowedWhenLocalNetworkPermissionIsDenied() {
        let service = makeService()
        service.relayMacDeviceId = "mac-123"
        service.relayMacIdentityPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 2, count: 32).base64EncodedString()
        service.localNetworkAuthorizationStatus = .denied

        XCTAssertTrue(
            service.shouldAttemptCloudAsyncFallback(
                after: NWError.posix(.ETIMEDOUT),
                serverURL: "ws://192.168.1.31:9000/relay/session"
            )
        )
    }

    func testCloudAsyncFallbackIsAllowedForLocalRelayTimeoutWhenOffLAN() {
        let service = makeService()
        service.relayMacDeviceId = "mac-123"
        service.relayMacIdentityPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 2, count: 32).base64EncodedString()
        service.localRelayPathAvailabilityOverride = { false }

        XCTAssertTrue(
            service.shouldAttemptCloudAsyncFallback(
                after: NWError.posix(.ETIMEDOUT),
                serverURL: "ws://192.168.1.31:9000/relay/session"
            )
        )
    }

    func testCloudAsyncFallbackIsBlockedForSecureHandshakeFailures() {
        let service = makeService()
        service.relayMacDeviceId = "mac-123"
        service.relayMacIdentityPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 2, count: 32).base64EncodedString()

        XCTAssertFalse(
            service.shouldAttemptCloudAsyncFallback(
                after: CodexSecureTransportError.invalidHandshake("bad pairing"),
                serverURL: "ws://192.168.1.31:9000/relay/session"
            )
        )
    }

    func testCloudAsyncFallbackIsAllowedForConnectionRefusedOnLocalRelayHost() {
        let service = makeService()
        service.relayMacDeviceId = "mac-123"
        service.relayMacIdentityPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 2, count: 32).base64EncodedString()

        XCTAssertTrue(
            service.shouldAttemptCloudAsyncFallback(
                after: NWError.posix(.ECONNREFUSED),
                serverURL: "ws://192.168.1.31:9000/relay/session"
            )
        )
    }

    func testCloudAsyncFallbackIsBlockedForSavedSessionCloseCode4002() {
        let service = makeService()
        service.relayMacDeviceId = "mac-123"
        service.relayMacIdentityPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 2, count: 32).base64EncodedString()

        XCTAssertFalse(
            service.shouldAttemptCloudAsyncFallback(
                after: CodexServiceError.invalidInput("WebSocket closed during connect (4002)"),
                serverURL: "ws://192.168.1.31:9000/relay/session"
            )
        )
    }

    func testCloudAsyncFallbackIsBlockedForNonLocalRelayHosts() {
        let service = makeService()
        service.relayMacDeviceId = "mac-123"
        service.relayMacIdentityPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 2, count: 32).base64EncodedString()

        XCTAssertFalse(
            service.shouldAttemptCloudAsyncFallback(
                after: NWError.posix(.ETIMEDOUT),
                serverURL: "wss://relay.example/relay/session"
            )
        )
    }

    func testHandleReceiveErrorResetsTransportModeToDisconnected() {
        let service = makeService()
        service.transportMode = .liveRelay
        service.isConnected = true
        service.isInitialized = true

        service.handleReceiveError(NWError.posix(.ECONNRESET))

        XCTAssertEqual(service.transportMode, .disconnected)
        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isInitialized)
    }

    func testCanonicalServerIdentityIgnoresRelaySessionPathComponent() {
        let service = makeService()
        let firstURL = URL(string: "ws://192.168.1.31:9000/relay/session-a")!
        let secondURL = URL(string: "ws://192.168.1.31:9000/relay/session-b")!

        XCTAssertEqual(service.canonicalServerIdentity(for: firstURL), "ws://192.168.1.31:9000/relay")
        XCTAssertEqual(service.canonicalServerIdentity(for: secondURL), "ws://192.168.1.31:9000/relay")
    }

    func testConnectedEncryptedSessionSuppressesStaleSavedPairingTimeoutMessage() {
        let service = makeService()
        service.isConnected = true
        service.connectionRecoveryState = .idle
        service.secureConnectionState = .encrypted

        XCTAssertTrue(
            service.shouldSuppressConnectedConversationErrorMessage(
                "The saved pairing timed out while waiting for the Mac. Scan a new QR code to reconnect."
            )
        )
    }

    func testConnectedTrustedMacSessionSuppressesStaleSavedPairingTimeoutMessage() {
        let service = makeService()
        service.isConnected = true
        service.connectionRecoveryState = .idle
        service.secureConnectionState = .trustedMac

        XCTAssertTrue(
            service.shouldSuppressConnectedConversationErrorMessage(
                "The saved pairing timed out while waiting for the Mac. Scan a new QR code to reconnect."
            )
        )
    }

    func testConnectedEncryptedSessionDoesNotSuppressNonConnectionErrorMessage() {
        let service = makeService()
        service.isConnected = true
        service.connectionRecoveryState = .idle
        service.secureConnectionState = .encrypted

        XCTAssertFalse(
            service.shouldSuppressConnectedConversationErrorMessage(
                "Only 8 images are allowed per message."
            )
        )
    }

    func testPrepareForConnectionAttemptPreservesFreshQRHandshakeState() async {
        let service = makeService()
        let payload = CodexPairingQRPayload(
            v: codexPairingQRVersion,
            relay: "ws://100.122.27.82:9000/relay",
            sessionId: "session-123",
            macDeviceId: "mac-123",
            macIdentityPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
            expiresAt: 1_800_000_000_000
        )

        service.rememberRelayPairing(payload)
        XCTAssertEqual(service.secureConnectionState, .handshaking)

        await service.prepareForConnectionAttempt(preserveReconnectIntent: true)

        XCTAssertEqual(service.secureConnectionState, .handshaking)
    }

    func testPrepareForConnectionAttemptKeepsThreadStateWhenSocketAlreadyDropped() async {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.activeTurnIdByThread[threadID] = turnID
        service.runningThreadIDs.insert(threadID)
        service.bufferedSecureControlMessages["secureError"] = ["{\"kind\":\"secureError\",\"message\":\"stale\"}"]

        await service.prepareForConnectionAttempt(preserveReconnectIntent: true)

        XCTAssertEqual(service.activeTurnID(for: threadID), turnID)
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
        XCTAssertTrue(service.bufferedSecureControlMessages.isEmpty)
    }
    private func makeService() -> CodexService {
        let suiteName = "CodexServiceConnectionErrorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.localRelayPathAvailabilityOverride = nil
        Self.retainedServices.append(service)
        return service
    }
}
