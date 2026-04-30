// FILE: TurnConnectionRecoverySnapshotBuilderTests.swift
// Purpose: Verifies the turn recovery card only exposes the wake fallback after the silent wake attempt is spent.
// Layer: Unit Test
// Exports: TurnConnectionRecoverySnapshotBuilderTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class TurnConnectionRecoverySnapshotBuilderTests: XCTestCase {
    func testReconnectProgressWinsWhileManualWakeFallbackIsAvailable() {
        let snapshot = TurnConnectionRecoverySnapshotBuilder.makeSnapshot(
            hasReconnectCandidate: true,
            isConnected: false,
            secureConnectionState: .trustedMac,
            showsWakeSavedMacDisplayAction: true,
            isWakingMacDisplayRecovery: false,
            isConnecting: false,
            shouldAutoReconnectOnForeground: true,
            isRetryingConnectionRecovery: true,
            lastErrorMessage: "Trying to reach your saved Mac. Remodex will keep retrying."
        )

        XCTAssertEqual(snapshot?.status, .reconnecting)
        XCTAssertEqual(snapshot?.trailingStyle, .progress)
        XCTAssertEqual(snapshot?.summary, "Trying to reconnect to your computer.")
    }

    func testReconnectProgressStillShowsBeforeManualWakeFallbackIsUnlocked() {
        let snapshot = TurnConnectionRecoverySnapshotBuilder.makeSnapshot(
            hasReconnectCandidate: true,
            isConnected: false,
            secureConnectionState: .trustedMac,
            showsWakeSavedMacDisplayAction: false,
            isWakingMacDisplayRecovery: false,
            isConnecting: false,
            shouldAutoReconnectOnForeground: true,
            isRetryingConnectionRecovery: true,
            lastErrorMessage: "Trying to reach your saved Mac. Remodex will keep retrying."
        )

        XCTAssertEqual(snapshot?.status, .reconnecting)
        XCTAssertEqual(snapshot?.trailingStyle, .progress)
        XCTAssertEqual(snapshot?.summary, "Trying to reconnect to your computer.")
    }

    func testWakeInFlightShowsProgressInsteadOfReconnectAction() {
        let snapshot = TurnConnectionRecoverySnapshotBuilder.makeSnapshot(
            hasReconnectCandidate: true,
            isConnected: false,
            secureConnectionState: .trustedMac,
            showsWakeSavedMacDisplayAction: false,
            isWakingMacDisplayRecovery: true,
            isConnecting: false,
            shouldAutoReconnectOnForeground: false,
            isRetryingConnectionRecovery: false,
            lastErrorMessage: "Trying to wake your Mac display..."
        )

        XCTAssertEqual(snapshot?.status, .reconnecting)
        XCTAssertEqual(snapshot?.trailingStyle, .progress)
        XCTAssertEqual(snapshot?.summary, "Trying to wake your Mac display...")
    }

    func testWakeActionShowsAfterReconnectProgressStops() {
        let snapshot = TurnConnectionRecoverySnapshotBuilder.makeSnapshot(
            hasReconnectCandidate: true,
            isConnected: false,
            secureConnectionState: .trustedMac,
            showsWakeSavedMacDisplayAction: true,
            isWakingMacDisplayRecovery: false,
            isConnecting: false,
            shouldAutoReconnectOnForeground: false,
            isRetryingConnectionRecovery: false,
            lastErrorMessage: "Connection was interrupted. Tap Reconnect to try again."
        )

        XCTAssertEqual(snapshot?.status, .interrupted)
        XCTAssertEqual(snapshot?.trailingStyle, .action("Wake Screen"))
        XCTAssertEqual(snapshot?.summary, "Connection was interrupted. Tap Reconnect to try again.")
    }
}
