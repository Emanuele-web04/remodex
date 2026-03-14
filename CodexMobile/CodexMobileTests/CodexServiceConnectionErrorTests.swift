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
}
