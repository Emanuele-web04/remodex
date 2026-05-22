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

    func testResetSecureTransportStatePreservesRePairRequiredState() {
        let service = makeService()
        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "ws://relay.local/relay"
        service.secureConnectionState = .rePairRequired
        service.secureMacFingerprint = "ABC123"

        service.resetSecureTransportState()

        XCTAssertEqual(service.secureConnectionState, .rePairRequired)
        XCTAssertEqual(service.secureMacFingerprint, "ABC123")
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

    func testTrustMacPromotesCurrentTrustedMacDeviceId() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.trustMac(
            deviceId: macDeviceID,
            publicKey: Data(repeating: 6, count: 32).base64EncodedString(),
            relayURL: "wss://relay.local/relay",
            displayName: "Desk Mac"
        )

        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, macDeviceID)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.currentTrustedMacDeviceId),
            macDeviceID
        )
    }

    func testInitializationMigratesCurrentTrustedMacDeviceIdFromRelayMacDeviceId() {
        let macDeviceID = "mac-\(UUID().uuidString)"
        let publicKey = Data(repeating: 12, count: 32).base64EncodedString()

        SecureStore.writeCodable(
            CodexTrustedMacRegistry(
                records: [
                    macDeviceID: CodexTrustedMacRecord(
                        macDeviceId: macDeviceID,
                        macIdentityPublicKey: publicKey,
                        lastPairedAt: Date()
                    )
                ]
            ),
            for: CodexSecureKeys.trustedMacRegistry
        )
        SecureStore.writeString(macDeviceID, for: CodexSecureKeys.relayMacDeviceId)

        let service = makeService()

        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, macDeviceID)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.currentTrustedMacDeviceId),
            macDeviceID
        )
    }

    func testInitializationDoesNotInventCurrentTrustedMacWhenLegacyPointersAreUnknown() {
        let knownMacDeviceID = "mac-\(UUID().uuidString)"

        SecureStore.writeCodable(
            CodexTrustedMacRegistry(
                records: [
                    knownMacDeviceID: CodexTrustedMacRecord(
                        macDeviceId: knownMacDeviceID,
                        macIdentityPublicKey: Data(repeating: 13, count: 32).base64EncodedString(),
                        lastPairedAt: Date()
                    )
                ]
            ),
            for: CodexSecureKeys.trustedMacRegistry
        )
        SecureStore.writeString("mac-missing", for: CodexSecureKeys.lastTrustedMacDeviceId)

        let service = makeService()

        XCTAssertNil(service.normalizedCurrentTrustedMacDeviceId)
        XCTAssertNil(SecureStore.readString(for: CodexSecureKeys.currentTrustedMacDeviceId))
    }

    func testInitializationMigratesCurrentTrustedMacDeviceIdFromLastTrustedMacDeviceId() {
        let macDeviceID = "mac-\(UUID().uuidString)"
        let publicKey = Data(repeating: 14, count: 32).base64EncodedString()

        SecureStore.writeCodable(
            CodexTrustedMacRegistry(
                records: [
                    macDeviceID: CodexTrustedMacRecord(
                        macDeviceId: macDeviceID,
                        macIdentityPublicKey: publicKey,
                        lastPairedAt: Date()
                    )
                ]
            ),
            for: CodexSecureKeys.trustedMacRegistry
        )
        SecureStore.writeString(macDeviceID, for: CodexSecureKeys.lastTrustedMacDeviceId)

        let service = makeService()

        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, macDeviceID)
        XCTAssertEqual(
            SecureStore.readString(for: CodexSecureKeys.currentTrustedMacDeviceId),
            macDeviceID
        )
    }

    func testClearSavedRelaySessionFallsBackToCurrentTrustedMacState() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let publicKey = Data(repeating: 15, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: publicKey,
            lastPairedAt: Date(),
            relayURL: "wss://relay.local/relay"
        )
        service.setCurrentTrustedMacDeviceId(macDeviceID)
        service.relaySessionId = "saved-session"
        service.relayUrl = "wss://relay.local/relay"
        service.relayMacDeviceId = macDeviceID
        service.relayMacIdentityPublicKey = publicKey

        service.clearSavedRelaySession()

        XCTAssertEqual(service.secureConnectionState, .liveSessionUnresolved)
        XCTAssertEqual(service.secureMacFingerprint, codexSecureFingerprint(for: publicKey))
        XCTAssertNil(service.normalizedRelaySessionId)
    }

    func testInitializationMigratesLegacyMacScopedDefaultsIntoCurrentMacScope() throws {
        let macDeviceID = "mac-\(UUID().uuidString)"
        let suiteName = "CodexSecurePairingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let legacyPlanSources = try JSONEncoder().encode(["thread-1": CodexPlanSessionSource.requested])
        let legacyWorktreePaths = try JSONEncoder().encode(["thread-1": "/tmp/worktree"])
        let legacyTurnTerminalStates = try JSONEncoder().encode(["turn-1": CodexTurnTerminalState.completed])
        defaults.set(legacyPlanSources, forKey: CodexService.planSessionSourcesDefaultsKey)
        defaults.set(legacyWorktreePaths, forKey: CodexService.associatedManagedWorktreePathsDefaultsKey)
        defaults.set(["deleted-thread"], forKey: CodexService.locallyDeletedThreadIDsKey)
        defaults.set(legacyTurnTerminalStates, forKey: CodexService.turnTerminalStatesDefaultsKey)

        SecureStore.writeCodable(
            CodexTrustedMacRegistry(
                records: [
                    macDeviceID: CodexTrustedMacRecord(
                        macDeviceId: macDeviceID,
                        macIdentityPublicKey: Data(repeating: 16, count: 32).base64EncodedString(),
                        lastPairedAt: Date()
                    )
                ]
            ),
            for: CodexSecureKeys.trustedMacRegistry
        )
        SecureStore.writeString(macDeviceID, for: CodexSecureKeys.currentTrustedMacDeviceId)

        let service = makeService(defaults: defaults)

        XCTAssertEqual(service.planSessionSourceByThread["thread-1"], .requested)
        XCTAssertEqual(service.associatedManagedWorktreePath(for: "thread-1"), "/tmp/worktree")
        XCTAssertEqual(service.locallyDeletedThreadIDs, Set(["deleted-thread"]))
        XCTAssertEqual(service.turnTerminalState(for: "turn-1"), .completed)
        XCTAssertNil(defaults.object(forKey: CodexService.planSessionSourcesDefaultsKey))
        XCTAssertNil(defaults.object(forKey: CodexService.associatedManagedWorktreePathsDefaultsKey))
        XCTAssertNil(defaults.object(forKey: CodexService.locallyDeletedThreadIDsKey))
        XCTAssertNil(defaults.object(forKey: CodexService.turnTerminalStatesDefaultsKey))
        XCTAssertNotNil(
            defaults.data(forKey: service.macScopedDefaultsKey(CodexService.planSessionSourcesDefaultsKey, macDeviceId: macDeviceID))
        )
        XCTAssertNotNil(
            defaults.data(forKey: service.macScopedDefaultsKey(CodexService.associatedManagedWorktreePathsDefaultsKey, macDeviceId: macDeviceID))
        )
        XCTAssertNotNil(
            defaults.array(forKey: service.macScopedDefaultsKey(CodexService.locallyDeletedThreadIDsKey, macDeviceId: macDeviceID))
        )
        XCTAssertNotNil(
            defaults.data(forKey: service.macScopedDefaultsKey(CodexService.turnTerminalStatesDefaultsKey, macDeviceId: macDeviceID))
        )
    }

    // Clears the persisted relay session keys touched by secure reconnect tests.
    private func clearStoredSecureRelayState() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.currentTrustedMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }

    private func makeService(defaults: UserDefaults? = nil) -> CodexService {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else {
            let suiteName = "CodexSecurePairingStateTests.\(UUID().uuidString)"
            let isolatedDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            isolatedDefaults.removePersistentDomain(forName: suiteName)
            resolvedDefaults = isolatedDefaults
        }

        let service = CodexService(defaults: resolvedDefaults)
        Self.retainedServices.append(service)
        return service
    }
}
