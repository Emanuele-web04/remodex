// FILE: ContentViewModelReconnectTests.swift
// Purpose: Verifies reconnect URL selection across trusted-session lookup failures and saved-session fallback.
// Layer: Unit Test
// Exports: ContentViewModelReconnectTests
// Depends on: XCTest, Foundation, CodexMobile

import Foundation
import Network
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

    func testPreferredReconnectURLUsesSavedSessionWhenTrustedMacRelayDisagrees() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 13, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://api.phodex.app/relay"
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.relaySessionId = "saved-session"
        service.relayUrl = "ws://zacks-mac-studio.local:9100/relay"
        service.relayMacDeviceId = macDeviceID
        service.trustedSessionResolverOverride = {
            XCTFail("trusted session resolve should not run when the saved relay is the fresher source of truth")
            return CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: macDeviceID,
                macIdentityPublicKey: Data(repeating: 14, count: 32).base64EncodedString(),
                displayName: "My Mac",
                sessionId: "live-session"
            )
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertEqual(reconnectURL, "ws://zacks-mac-studio.local:9100/relay/saved-session")
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

    func testForegroundReconnectKeepsRetryIntentArmedAfterRetryableFailures() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        var attempts = 0

        service.relaySessionId = "saved-session"
        service.relayUrl = "wss://relay.local/relay"
        service.shouldAutoReconnectOnForeground = true
        viewModel.reconnectAttemptLimitOverride = 2
        viewModel.reconnectSleepOverride = { _ in }
        viewModel.connectOverride = { _, _ in
            attempts += 1
            throw NWError.posix(.ECONNABORTED)
        }

        await viewModel.attemptAutoReconnectOnForegroundIfNeeded(codex: service)

        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 2, message: "Reconnecting..."))
    }

    func testManualReconnectCancelsStuckTrustedSessionResolve() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        var resolveAttempts = 0
        var connectAttempts = 0

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 11, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.relaySessionId = "saved-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = macDeviceID
        service.shouldAutoReconnectOnForeground = true
        viewModel.reconnectSleepOverride = { _ in await Task.yield() }
        service.trustedSessionResolverOverride = {
            resolveAttempts += 1
            if resolveAttempts == 1 {
                while !Task.isCancelled {
                    await Task.yield()
                }
                throw CancellationError()
            }
            return CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: macDeviceID,
                macIdentityPublicKey: Data(repeating: 12, count: 32).base64EncodedString(),
                displayName: "My Mac",
                sessionId: "live-session"
            )
        }
        viewModel.connectOverride = { _, serverURL in
            connectAttempts += 1
            XCTAssertEqual(serverURL, "\(relayURL)/live-session")
        }

        let autoReconnectTask = Task {
            await viewModel.attemptAutoReconnectOnForegroundIfNeeded(codex: service)
        }

        while !viewModel.isAttemptingAutoReconnect || resolveAttempts == 0 {
            await Task.yield()
        }

        await viewModel.toggleConnection(codex: service)
        await autoReconnectTask.value

        XCTAssertEqual(resolveAttempts, 2)
        XCTAssertEqual(connectAttempts, 1)
        XCTAssertFalse(viewModel.isAttemptingAutoReconnect)
        XCTAssertFalse(service.shouldAutoReconnectOnForeground)
    }

    func testTrustedResolveCancelsWhenCallerTaskIsCancelled() async {
        let service = makeService()
        var resolverSawCancellation = false

        service.trustedSessionResolverOverride = {
            while !Task.isCancelled {
                await Task.yield()
            }
            resolverSawCancellation = true
            throw CancellationError()
        }

        let callerTask = Task {
            try await service.resolveTrustedMacSession()
        }

        while service.trustedSessionResolveTask == nil {
            await Task.yield()
        }

        callerTask.cancel()

        do {
            _ = try await callerTask.value
            XCTFail("Expected caller cancellation to abort the trusted resolve task.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        while service.trustedSessionResolveTask != nil || !resolverSawCancellation {
            await Task.yield()
        }

        XCTAssertTrue(resolverSawCancellation)
        XCTAssertNil(service.trustedSessionResolveTask)
        XCTAssertNil(service.trustedSessionResolveTaskID)
    }

    func testManualReconnectDoesNotWaitForOldAutoReconnectBackoff() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        var connectAttempts = 0

        service.relaySessionId = "saved-session"
        service.relayUrl = "wss://relay.local/relay"
        service.shouldAutoReconnectOnForeground = true
        viewModel.reconnectSleepChunkNanosecondsOverride = 10_000_000
        viewModel.connectOverride = { codex, _ in
            connectAttempts += 1
            if connectAttempts == 1 {
                throw CodexServiceError.disconnected
            }
        }

        let autoReconnectTask = Task {
            await viewModel.attemptAutoReconnectOnForegroundIfNeeded(codex: service)
        }

        while true {
            if case .retrying(let attempt, _) = service.connectionRecoveryState,
               attempt == 1 {
                break
            }
            await Task.yield()
        }

        let reconnectStartedAt = Date()
        await viewModel.toggleConnection(codex: service)
        let reconnectElapsed = Date().timeIntervalSince(reconnectStartedAt)
        await autoReconnectTask.value

        XCTAssertEqual(connectAttempts, 2)
        XCTAssertFalse(service.shouldAutoReconnectOnForeground)
        XCTAssertLessThan(reconnectElapsed, 0.75)
    }

    func testToggleConnectionDisconnectPreservesSavedRelaySession() async {
        let service = makeService()
        let viewModel = ContentViewModel()

        service.relaySessionId = "saved-session"
        service.relayUrl = "wss://relay.local/relay"
        service.relayMacDeviceId = "mac-\(UUID().uuidString)"
        service.relayMacIdentityPublicKey = Data(repeating: 21, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 22, count: 32).base64EncodedString()
        service.isConnected = true
        service.isInitialized = true
        service.transportMode = .liveRelay

        await viewModel.toggleConnection(codex: service)

        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isInitialized)
        XCTAssertEqual(service.transportMode, .disconnected)
        XCTAssertEqual(service.relaySessionId, "saved-session")
        XCTAssertEqual(service.relayUrl, "wss://relay.local/relay")
        XCTAssertNotNil(service.relayMacDeviceId)
        XCTAssertNotNil(service.relayMacIdentityPublicKey)
        XCTAssertNotNil(service.relayCloudAsyncSharedSecret)
    }

    func testManualReconnectIgnoresRapidSecondTapWhileFirstAttemptIsInFlight() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        var connectAttempts = 0
        var allowFirstAttemptToFinish = false

        service.relaySessionId = "saved-session"
        service.relayUrl = "wss://relay.local/relay"
        viewModel.connectOverride = { _, _ in
            connectAttempts += 1
            while !allowFirstAttemptToFinish {
                await Task.yield()
            }
        }

        let firstTapTask = Task {
            await viewModel.toggleConnection(codex: service)
        }

        while !viewModel.isAttemptingManualReconnect {
            await Task.yield()
        }

        let secondTapTask = Task {
            await viewModel.toggleConnection(codex: service)
        }

        await Task.yield()
        allowFirstAttemptToFinish = true

        await firstTapTask.value
        await secondTapTask.value

        XCTAssertEqual(connectAttempts, 1)
        XCTAssertFalse(viewModel.isAttemptingManualReconnect)
    }

    func testManualScannerCancelsManualReconnectBackoff() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        var connectAttempts = 0

        service.relaySessionId = "saved-session"
        service.relayUrl = "wss://relay.local/relay"
        viewModel.reconnectSleepChunkNanosecondsOverride = 10_000_000
        viewModel.connectOverride = { _, _ in
            connectAttempts += 1
            throw CodexServiceError.disconnected
        }

        let reconnectTask = Task {
            await viewModel.toggleConnection(codex: service)
        }

        while true {
            if case .retrying(let attempt, _) = service.connectionRecoveryState,
               attempt == 1 {
                break
            }
            await Task.yield()
        }

        let scannerTakeoverStartedAt = Date()
        await viewModel.stopAutoReconnectForManualScan(codex: service)
        let scannerTakeoverElapsed = Date().timeIntervalSince(scannerTakeoverStartedAt)
        await reconnectTask.value

        XCTAssertEqual(connectAttempts, 1)
        XCTAssertFalse(viewModel.isAttemptingManualReconnect)
        XCTAssertLessThan(scannerTakeoverElapsed, 0.75)
    }

    func testManualScannerCancellationDoesNotLeaveTrustedResolveError() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        var resolveAttempts = 0

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 13, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.relayUrl = relayURL
        service.relayMacDeviceId = macDeviceID
        service.lastErrorMessage = "old error"
        service.trustedSessionResolverOverride = {
            resolveAttempts += 1
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }

        let reconnectTask = Task {
            await viewModel.toggleConnection(codex: service)
        }

        while !viewModel.isAttemptingManualReconnect || resolveAttempts == 0 {
            await Task.yield()
        }

        await viewModel.stopAutoReconnectForManualScan(codex: service)
        await reconnectTask.value

        XCTAssertEqual(resolveAttempts, 1)
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertFalse(viewModel.isAttemptingManualReconnect)
    }

    func testConnectSurfacesCloudFallbackFailureInsteadOfOriginalRelayTimeout() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let expectedError = CodexCloudAsyncTransportError.unavailable(
            "Could not reach Convex for off-LAN async messaging."
        )

        service.relayMacDeviceId = "mac-123"
        service.relayMacIdentityPublicKey = Data(repeating: 1, count: 32).base64EncodedString()
        service.relayCloudAsyncSharedSecret = Data(repeating: 2, count: 32).base64EncodedString()
        service.connectAttemptOverride = { _, _, _, _ in
            throw NWError.posix(.ETIMEDOUT)
        }
        service.shouldAttemptCloudAsyncFallbackOverride = { _, _ in true }
        service.cloudAsyncFallbackActivationOverride = { _, _ in
            throw expectedError
        }

        do {
            try await viewModel.connect(codex: service, serverURL: "ws://192.168.1.31:9000/relay/session")
            XCTFail("Expected fallback failure to be surfaced.")
        } catch {
            XCTAssertEqual(error.localizedDescription, expectedError.localizedDescription)
        }
    }

    func testConnectUsesConvexOnlyPreferenceWithoutLiveRelayAttempt() async throws {
        let service = makeService()
        let viewModel = ContentViewModel()
        var connectAttempts = 0
        var fallbackAttempts = 0

        service.transportPreference = .convexOnly
        service.connectAttemptOverride = { _, _, _, _ in
            connectAttempts += 1
        }
        service.cloudAsyncFallbackActivationOverride = { _, _ in
            fallbackAttempts += 1
        }

        try await viewModel.connect(codex: service, serverURL: "ws://192.168.1.31:9000/relay/session")
        XCTAssertEqual(connectAttempts, 0)
        XCTAssertEqual(fallbackAttempts, 1)
    }

    func testConnectUsesLanOnlyPreferenceWithoutCloudFallbackAttempt() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        var fallbackAttempts = 0

        service.transportPreference = .lanOnly
        service.connectAttemptOverride = { _, _, _, _ in
            throw NWError.posix(.ETIMEDOUT)
        }
        service.cloudAsyncFallbackActivationOverride = { _, _ in
            fallbackAttempts += 1
        }

        do {
            try await viewModel.connect(codex: service, serverURL: "ws://192.168.1.31:9000/relay/session")
            XCTFail("Expected LAN-only mode to surface the relay error.")
        } catch {
            XCTAssertEqual(fallbackAttempts, 0)
        }
    }

    func testSetTransportPreferenceSwitchesLiveRelayConnectionToConvexFallback() async {
        let service = makeService()
        var fallbackAttempts = 0
        var receivedURL: String?
        var receivedPerformInitialSync: Bool?

        service.isConnected = true
        service.transportMode = .liveRelay
        service.relayUrl = "ws://192.168.1.31:9000/relay"
        service.relaySessionId = "session-1"
        service.cloudAsyncFallbackActivationOverride = { serverURL, performInitialSync in
            fallbackAttempts += 1
            receivedURL = serverURL
            receivedPerformInitialSync = performInitialSync
        }

        service.setTransportPreference(.convexOnly)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(service.transportPreference, .convexOnly)
        XCTAssertEqual(fallbackAttempts, 1)
        XCTAssertEqual(receivedURL, "ws://192.168.1.31:9000/relay/session-1")
        XCTAssertEqual(receivedPerformInitialSync, false)
    }

    func testSetTransportPreferenceReconnectsFromConvexFallbackToLan() async {
        let service = makeService()
        var connectAttempts = 0
        var receivedServerURL: String?
        var receivedPerformInitialSync: Bool?

        service.isConnected = true
        service.transportMode = .cloudAsyncFallback
        service.relayUrl = "ws://192.168.1.31:9000/relay"
        service.relaySessionId = "session-1"
        service.connectAttemptOverride = { serverURL, _, _, performInitialSync in
            connectAttempts += 1
            receivedServerURL = serverURL
            receivedPerformInitialSync = performInitialSync
        }

        service.setTransportPreference(.lanOnly)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(service.transportPreference, .lanOnly)
        XCTAssertEqual(connectAttempts, 1)
        XCTAssertEqual(receivedServerURL, "ws://192.168.1.31:9000/relay/session-1")
        XCTAssertEqual(receivedPerformInitialSync, false)
    }

    func testSetTransportPreferenceDefersSwitchUntilConnectionFinishes() async {
        let service = makeService()
        var fallbackAttempts = 0

        service.isConnected = true
        service.isConnecting = true
        service.transportMode = .liveRelay
        service.relayUrl = "ws://192.168.1.31:9000/relay"
        service.relaySessionId = "session-1"
        service.cloudAsyncFallbackActivationOverride = { _, _ in
            fallbackAttempts += 1
        }

        service.setTransportPreference(.convexOnly)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fallbackAttempts, 0)

        service.isConnecting = false
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(fallbackAttempts, 1)
    }

    func testSetTransportPreferenceRapidToggleAppliesLatestSelectionOnly() async {
        let service = makeService()
        var fallbackAttempts = 0

        service.isConnected = true
        service.transportMode = .liveRelay
        service.relayUrl = "ws://192.168.1.31:9000/relay"
        service.relaySessionId = "session-1"
        service.cloudAsyncFallbackActivationOverride = { _, _ in
            fallbackAttempts += 1
        }

        service.setTransportPreference(.convexOnly)
        service.setTransportPreference(.lanOnly)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.transportPreference, .lanOnly)
        XCTAssertEqual(fallbackAttempts, 0)
    }

    func testTransportPreferencePersistsAcrossServiceReinit() async {
        let suiteName = "ContentViewModelReconnectTests.TransportPreferencePersistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.setTransportPreference(.convexOnly)
        try? await Task.sleep(nanoseconds: 100_000_000)
        Self.retainedServices.append(service)

        let restoredService = CodexService(defaults: defaults)
        Self.retainedServices.append(restoredService)
        XCTAssertEqual(restoredService.transportPreference, .convexOnly)

        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeService() -> CodexService {
        let suiteName = "ContentViewModelReconnectTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.connectAttemptOverride = nil
        service.cloudAsyncFallbackActivationOverride = nil
        service.shouldAttemptCloudAsyncFallbackOverride = nil
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
