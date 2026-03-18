// FILE: ContentViewModelReconnectTests.swift
// Purpose: Verifies reconnect URL selection across trusted-session lookup failures and saved-session fallback.
// Layer: Unit Test
// Exports: ContentViewModelReconnectTests
// Depends on: XCTest, Foundation, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class ContentViewModelReconnectTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    override func setUp() {
        super.setUp()
        clearStoredSecureRelayState()
    }

    override func tearDown() {
        clearStoredSecureRelayState()
        super.tearDown()
    }

    func testPreferredReconnectURLFallsBackToSavedSessionWhenTrustedResolveReportsOffline() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 9, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.relaySessionId = "saved-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = macDeviceID
        service.lastErrorMessage = "stale error"
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.macOffline("Your trusted Mac is offline right now.")
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertEqual(reconnectURL, "\(relayURL)/saved-session")
        XCTAssertNil(service.lastErrorMessage)
    }

    func testPreferredReconnectURLStopsWhenTrustedResolveReportsOfflineAndNoSavedSessionExists() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 10, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.macOffline("Your trusted Mac is offline right now.")
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertNil(reconnectURL)
        XCTAssertEqual(service.lastErrorMessage, "Your trusted Mac is offline right now.")
    }

    private func makeService() -> CodexService {
        let suiteName = "ContentViewModelReconnectTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    // Clears the persisted relay keys so reconnect tests do not inherit state from other suites.
    private func clearStoredSecureRelayState() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }
}
