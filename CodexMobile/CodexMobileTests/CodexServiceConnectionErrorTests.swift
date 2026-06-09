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
    func testKeepMacAwakePreferenceDefaultsToDisabled() {
        let suiteName = "CodexServiceConnectionErrorTests.keepMacAwake.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)

        XCTAssertFalse(service.keepMacAwakeWhileBridgeRuns)
    }

    func testBenignBackgroundAbortIsSuppressedFromUserFacingErrors() {
        let service = CodexService()
        let error = NWError.posix(.ECONNABORTED)
        service.isAppInForeground = false

        XCTAssertTrue(service.isBenignBackgroundDisconnect(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testSendSideNoDataDisconnectIsTreatedAsBenign() {
        let service = CodexService()
        let error = NWError.posix(.ENODATA)
        service.isAppInForeground = false

        XCTAssertTrue(service.isBenignBackgroundDisconnect(error))
        XCTAssertTrue(service.shouldTreatSendFailureAsDisconnect(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testConnectionResetIsTreatedAsBenignRelayDisconnect() {
        let service = CodexService()
        let error = NWError.posix(.ECONNRESET)
        service.isAppInForeground = false

        XCTAssertTrue(service.isBenignBackgroundDisconnect(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testInactiveAppStateStillSuppressesBenignDisconnectNoise() {
        let service = CodexService()
        let error = NWError.posix(.ECONNRESET)
        service.isAppInForeground = true
        service.applicationStateProvider = { .inactive }

        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testTransientTimeoutStillSurfacesToUser() {
        let service = CodexService()
        let error = NWError.posix(.ETIMEDOUT)

        XCTAssertTrue(service.isRecoverableTransientConnectionError(error))
        XCTAssertFalse(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testOversizedRelayPayloadGetsFriendlyFailureCopy() {
        let service = CodexService()
        let error = NWError.posix(.EMSGSIZE)

        XCTAssertTrue(service.isOversizedRelayPayloadError(error))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(error),
            "A thread payload was too large for the relay connection. This can happen while reopening image-heavy chats even if you didn't press Send."
        )
    }

    func testReceiveDispositionUsesFriendlyOversizedPayloadMessage() {
        let service = CodexService()
        let error = NWError.posix(.EMSGSIZE)

        service.handleReceiveError(error)

        XCTAssertEqual(
            service.lastErrorMessage,
            "A thread payload was too large for the relay connection. This can happen while reopening image-heavy chats even if you didn't press Send."
        )
    }

    func testValidateOutgoingWebSocketMessageSizeRejectsOversizedPayload() {
        let service = CodexService()
        let oversizedText = String(repeating: "a", count: codexWebSocketMaximumMessageSizeBytes + 1)

        XCTAssertThrowsError(try service.validateOutgoingWebSocketMessageSize(oversizedText)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "This payload is too large for the relay connection. Try fewer or smaller images and retry."
            )
        }
    }

    func testWebSocketKeepAlivePingsWhileForegrounded() async {
        let service = CodexService()
        var pingCount = 0
        service.isConnected = true
        service.isInitialized = true
        service.isAppInForeground = true
        service.webSocketKeepAliveIntervalOverrideNanoseconds = 1
        service.webSocketKeepAlivePingOverride = {
            pingCount += 1
            service.stopWebSocketKeepAliveLoop()
        }

        service.startWebSocketKeepAliveLoop()

        for _ in 0..<1_000 {
            if pingCount > 0 { break }
            await Task.yield()
        }

        XCTAssertEqual(pingCount, 1)
        XCTAssertNil(service.webSocketKeepAliveTask)
    }

    func testWebSocketKeepAliveDoesNotStartWhileBackgrounded() async {
        let service = CodexService()
        var pingCount = 0
        service.isConnected = true
        service.isInitialized = true
        service.isAppInForeground = false
        service.webSocketKeepAliveIntervalOverrideNanoseconds = 1
        service.webSocketKeepAlivePingOverride = {
            pingCount += 1
        }

        service.startWebSocketKeepAliveLoop()
        await Task.yield()

        XCTAssertEqual(pingCount, 0)
        XCTAssertNil(service.webSocketKeepAliveTask)
    }

    func testForegroundStateStopsAndRestartsWebSocketKeepAlive() {
        let service = CodexService()
        service.syncRealtimeEnabled = false
        service.isConnected = true
        service.isInitialized = true
        service.isAppInForeground = true
        service.webSocketKeepAlivePingOverride = {}

        service.startWebSocketKeepAliveLoop()
        XCTAssertNotNil(service.webSocketKeepAliveTask)

        service.setForegroundState(false)
        XCTAssertNil(service.webSocketKeepAliveTask)

        service.setForegroundState(true)
        XCTAssertNotNil(service.webSocketKeepAliveTask)
        service.stopWebSocketKeepAliveLoop()
    }

    func testDisconnectStopsWebSocketKeepAlive() async {
        let service = CodexService()
        service.isConnected = true
        service.isInitialized = true
        service.isAppInForeground = true
        service.webSocketKeepAlivePingOverride = {}

        service.startWebSocketKeepAliveLoop()
        XCTAssertNotNil(service.webSocketKeepAliveTask)

        await service.disconnect()

        XCTAssertNil(service.webSocketKeepAliveTask)
        XCTAssertFalse(service.isConnected)
    }

    func testWebSocketKeepAliveFailureArmsReconnect() async {
        let service = CodexService()
        service.isConnected = true
        service.isInitialized = true
        service.isAppInForeground = true
        service.webSocketKeepAliveIntervalOverrideNanoseconds = 1
        service.webSocketKeepAlivePingOverride = {
            throw NWError.posix(.ECONNRESET)
        }

        service.startWebSocketKeepAliveLoop()

        for _ in 0..<1_000 {
            if service.webSocketKeepAliveTask == nil { break }
            await Task.yield()
        }

        XCTAssertNil(service.webSocketKeepAliveTask)
        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 0, message: "Reconnecting..."))
        XCTAssertNil(service.lastErrorMessage)
    }

    func testForegroundProbeImmediatelyArmsReconnectForZombieSocket() async {
        let service = CodexService()
        service.isConnected = true
        service.isInitialized = true
        service.isAppInForeground = true
        service.webSocketKeepAlivePingOverride = {
            throw NWError.posix(.ECONNRESET)
        }

        await service.probeForegroundConnectionIfNeeded()

        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 0, message: "Reconnecting..."))
        XCTAssertNil(service.lastErrorMessage)
    }

    func testForegroundProbeTimeoutArmsReconnectWhenPingHangs() async {
        let service = CodexService()
        service.isConnected = true
        service.isInitialized = true
        service.isAppInForeground = true
        service.webSocketForegroundProbeTimeoutOverrideNanoseconds = 1
        service.webSocketKeepAlivePingOverride = {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        await service.probeForegroundConnectionIfNeeded()

        XCTAssertFalse(service.isConnected)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 0, message: "Reconnecting..."))
        XCTAssertNil(service.lastErrorMessage)
    }

    func testBenignDisconnectStaysSilentWhileAutoReconnectIsRunning() {
        let service = CodexService()
        let error = CodexServiceError.disconnected
        service.isAppInForeground = true
        service.shouldAutoReconnectOnForeground = true
        service.connectionRecoveryState = .retrying(attempt: 1, message: "Reconnecting...")

        XCTAssertTrue(service.shouldSuppressRecoverableConnectionError(error))
        XCTAssertTrue(service.shouldSuppressUserFacingConnectionError(error))
    }

    func testConnectionRefusedStillSurfacesToUser() {
        let service = CodexService()
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
        let service = CodexService()

        XCTAssertEqual(
            service.userFacingConnectFailureMessage(NWError.posix(.ECONNABORTED)),
            "Connection was interrupted. Tap Reconnect to try again."
        )
    }

    func testBrokenPipeGetsFriendlyFailureCopy() {
        let service = CodexService()

        XCTAssertEqual(
            service.userFacingConnectFailureMessage(NWError.posix(.EPIPE)),
            "Connection was interrupted. Tap Reconnect to try again."
        )
    }

    func testTurnErrorSuppressesBrokenPipeWhileAutoReconnectIsRunning() {
        let service = CodexService()
        let error = NWError.posix(.EPIPE)
        service.isAppInForeground = true
        service.shouldAutoReconnectOnForeground = true
        service.connectionRecoveryState = .retrying(attempt: 1, message: "Reconnecting...")

        XCTAssertTrue(service.shouldSuppressRecoverableConnectionError(error))
        XCTAssertEqual(service.userFacingTurnErrorMessage(from: error), "")
    }

    func testCancellationErrorIsHiddenFromTurnFooter() {
        let service = CodexService()

        XCTAssertEqual(service.userFacingTurnErrorMessage(from: CancellationError()), "")
        XCTAssertNil(service.userFacingTurnErrorMessageForFooter(from: CancellationError()))
        XCTAssertTrue(service.shouldSuppressRuntimeErrorInChat(CancellationError()))
    }

    func testTurnStartCancellationDoesNotAppendEmptySendError() {
        let service = CodexService()
        let threadID = "thread-\(UUID().uuidString)"
        let pendingMessageID = "message-\(UUID().uuidString)"
        service.messagesByThread[threadID] = [
            CodexMessage(
                id: pendingMessageID,
                threadId: threadID,
                role: .user,
                text: "hello",
                deliveryState: .pending
            )
        ]

        XCTAssertThrowsError(
            try service.handleTurnStartFailure(
                CancellationError(),
                pendingMessageId: pendingMessageID,
                threadId: threadID
            )
        )

        XCTAssertNil(service.lastErrorMessage)
        XCTAssertFalse(service.messages(for: threadID).contains { $0.text == "Send error: " })
    }

    func testConnectTimeSessionUnavailableCloseIsRetryable() {
        let service = CodexService()
        let error = CodexServiceError.invalidInput("WebSocket closed during connect (4002)")

        XCTAssertTrue(service.isRetryableSavedSessionConnectError(error))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(error),
            "The saved Mac session is temporarily unavailable. Remodex will keep retrying. If you restarted the bridge on your Mac, scan the new QR code."
        )
    }

    func testManualWebSocketClosePayloadPreservesRetryableRelayCode() {
        let service = CodexService()
        let closeCode = service.relayCloseCode(
            fromManualWebSocketClosePayload: Data([0x0F, 0xA2])
        )

        XCTAssertEqual(service.relayCloseCodeRawValue(closeCode), 4002)
    }

    func testManualWebSocketCloseFrameUsesRetryableRelayRecovery() async throws {
        let service = CodexService()
        let connection = NWConnection(
            host: NWEndpoint.Host("localhost"),
            port: NWEndpoint.Port(rawValue: 80)!,
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "ws://mac.local/relay"
        service.isConnected = true
        service.isInitialized = true
        service.setForegroundState(true)
        service.manualWebSocketReadBuffer = Data([0x88, 0x02, 0x0F, 0xA2])

        let didHandleClose = try await service.drainManualWebSocketFrames(on: connection)

        XCTAssertTrue(didHandleClose)
        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isInitialized)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 0, message: "Reconnecting..."))
        XCTAssertEqual(
            service.lastErrorMessage,
            "The saved Mac session is temporarily unavailable. Remodex will keep retrying. If you restarted the bridge on your Mac, scan the new QR code."
        )
    }

    func testLanAddressStillRequiresLocalNetworkAuthorization() {
        let service = CodexService()
        let url = URL(string: "ws://192.168.1.31:9000/relay/session")!

        XCTAssertTrue(service.requiresLocalNetworkAuthorization(for: url))
        XCTAssertTrue(service.prefersDirectRelayTransport(for: url))
    }

    func testTailscaleAddressPrefersDirectRelayTransportWithoutLocalNetworkPrompt() {
        let service = CodexService()
        let url = URL(string: "ws://100.122.27.82:9000/relay/session")!

        XCTAssertTrue(service.prefersDirectRelayTransport(for: url))
        XCTAssertFalse(service.requiresLocalNetworkAuthorization(for: url))
    }

    func testTailscaleMagicDNSHostPrefersDirectRelayTransportWithoutLocalNetworkPrompt() {
        let service = CodexService()
        let url = URL(string: "ws://my-mac.tail-scale.ts.net:9000/relay/session")!

        XCTAssertTrue(service.prefersDirectRelayTransport(for: url))
        XCTAssertFalse(service.requiresLocalNetworkAuthorization(for: url))
    }

    func testDirectRelaySocketTimeoutRemainsRetryable() {
        let service = CodexService()
        let error = CodexServiceError.invalidInput(
            "Connection timed out after 12s while opening the direct relay socket."
        )

        XCTAssertTrue(service.isRecoverableTransientConnectionError(error))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(error),
            "Connection timed out. Check server/network."
        )
    }

    func testPrepareForConnectionAttemptPreservesFreshQRHandshakeState() async {
        let service = CodexService()
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
        let service = CodexService()
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

    func testManualWebSocketDrainAnswersPingBeforeText() async throws {
        let service = CodexService()
        let connection = NWConnection(
            host: NWEndpoint.Host("localhost"),
            port: NWEndpoint.Port(rawValue: 80)!,
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        var sequence: [String] = []
        service.manualWebSocketDrainSequenceProbe = { sequence.append($0) }

        let textPayload = Data("{\"jsonrpc\":\"2.0\",\"method\":\"relay/ping\"}".utf8)
        service.manualWebSocketReadBuffer =
            Self.unmaskedServerWebSocketFrame(opcode: 0x9, payload: Data())
            + Self.unmaskedServerWebSocketFrame(opcode: 0x1, payload: textPayload)

        let didHandleClose = try await service.drainManualWebSocketFrames(on: connection)

        XCTAssertFalse(didHandleClose)
        XCTAssertEqual(sequence, ["pong", "text"])
    }

    func testWebSocketKeepAliveIntervalShortensWhileTurnIsActive() {
        let service = CodexService()
        XCTAssertEqual(service.webSocketKeepAliveIntervalNanoseconds(), 25_000_000_000)

        service.activeTurnIdByThread["thread-active"] = "turn-active"
        XCTAssertEqual(service.webSocketKeepAliveIntervalNanoseconds(), 10_000_000_000)
    }

    func testProgressiveSidebarPaintsPinnedSnapshotsBeforeThreadListSync() {
        let suiteName = "CodexServiceConnectionErrorTests.progressiveSidebar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        let cachedThread = CodexThread(
            id: "thread-cached",
            title: "Cached chat",
            cwd: "/tmp/remodex-project"
        )
        service.pinnedThreadIDs = ["thread-cached"]
        service.pinnedThreadSnapshotsByRootID = ["thread-cached": [cachedThread]]
        XCTAssertTrue(service.threads.isEmpty)

        XCTAssertTrue(service.applyProgressiveSidebarFromStaleCacheIfNeeded())
        XCTAssertEqual(service.threads.map(\.id), ["thread-cached"])
        XCTAssertEqual(service.connectionPhase, .offline)
    }

    func testInterruptedConnectionCopyIsSoftenedDuringTrustedReconnectRetry() {
        let service = CodexService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "ws://relay.local/relay"
        service.relayMacDeviceId = macDeviceID
        service.setCurrentTrustedMacDeviceId(macDeviceID)
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
            lastPairedAt: Date()
        )
        service.shouldForceQRBootstrapOnNextHandshake = false
        service.connectionRecoveryState = .retrying(attempt: 1, message: "Reconnecting...")
        service.trustedReconnectFailureCount = 0

        XCTAssertTrue(service.hasTrustedReconnectContext)
        XCTAssertTrue(service.shouldSuppressInterruptedConnectionMessageDuringTrustedRecovery())
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(NWError.posix(.EPIPE)),
            "Reconnecting..."
        )
    }

    private static func unmaskedServerWebSocketFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            let encodedLength = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((encodedLength >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }
}
