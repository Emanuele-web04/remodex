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

    func testTrustedResolveURLCandidatesTryProxyRelativeThenRootRoute() {
        let candidates = CodexTrustedSessionResolveURLBuilder.candidates(
            from: "wss://relay.example.com/remodex/relay?stale=1#old"
        )

        XCTAssertEqual(
            candidates.map(\.absoluteString),
            [
                "https://relay.example.com/remodex/v1/trusted/session/resolve",
                "https://relay.example.com/v1/trusted/session/resolve",
            ]
        )
    }

    func testTrustedResolveURLCandidatesDoNotDuplicateRootRoute() {
        let candidates = CodexTrustedSessionResolveURLBuilder.candidates(
            from: "ws://relay.example.com/relay?stale=1"
        )

        XCTAssertEqual(
            candidates.map(\.absoluteString),
            [
                "http://relay.example.com/v1/trusted/session/resolve",
            ]
        )
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
        service.setCurrentTrustedMacDeviceId(macDeviceID)
        service.relaySessionId = "saved-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = macDeviceID
        service.lastErrorMessage = "stale error"
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.macOffline("Your trusted device is offline right now.")
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertEqual(reconnectURL, "\(relayURL)/saved-session")
        XCTAssertNil(service.lastErrorMessage)
    }

    func testPreferredReconnectURLFallsBackToSavedSessionWhenTrustedResolveReportsRePairRequired() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let macPublicKey = Data(repeating: 19, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.relaySessionId = "saved-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = macDeviceID
        service.relayMacIdentityPublicKey = macPublicKey
        service.secureConnectionState = .rePairRequired
        service.lastErrorMessage = "This iPhone is no longer trusted by the paired computer."
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.rePairRequired("Resolve says this phone is not trusted.")
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertEqual(reconnectURL, "\(relayURL)/saved-session")
        XCTAssertEqual(service.secureConnectionState, .trustedMac)
        XCTAssertNil(service.lastErrorMessage)
    }

    func testPreferredReconnectURLStopsWhenTrustedResolveReportsRePairRequiredWithoutSavedSession() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 20, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.shouldAutoReconnectOnForeground = true
        service.secureConnectionState = .rePairRequired
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.rePairRequired("Resolve says this phone is not trusted.")
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertNil(reconnectURL)
        XCTAssertEqual(service.secureConnectionState, .rePairRequired)
        XCTAssertFalse(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.lastErrorMessage, "Resolve says this phone is not trusted.")
    }

    func testExplicitTargetDoesNotFallbackToSavedSessionForDifferentMacWhenRePairRequired() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let currentMacDeviceID = "mac-current-\(UUID().uuidString)"
        let targetMacDeviceID = "mac-target-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"

        service.trustedMacRegistry.records[currentMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: currentMacDeviceID,
            macIdentityPublicKey: Data(repeating: 45, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.trustedMacRegistry.records[targetMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: targetMacDeviceID,
            macIdentityPublicKey: Data(repeating: 46, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.setCurrentTrustedMacDeviceId(currentMacDeviceID)
        service.relaySessionId = "saved-current-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = currentMacDeviceID
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.rePairRequired("Resolve says the target phone is not trusted.")
        }

        let reconnectURL = await viewModel.preferredReconnectURL(
            codex: service,
            targetMacDeviceId: targetMacDeviceID
        )

        XCTAssertNil(reconnectURL)
        XCTAssertEqual(service.secureConnectionState, .rePairRequired)
        XCTAssertEqual(service.lastErrorMessage, "Resolve says the target phone is not trusted.")
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
        service.setCurrentTrustedMacDeviceId(macDeviceID)
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.macOffline("Your trusted device is offline right now.")
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertNil(reconnectURL)
        XCTAssertEqual(service.lastErrorMessage, "Your trusted device is offline right now.")
    }

    func testPreferredReconnectURLIgnoresSavedSessionForDifferentCurrentMac() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let currentMacDeviceID = "mac-current-\(UUID().uuidString)"
        let staleMacDeviceID = "mac-stale-\(UUID().uuidString)"

        service.trustedMacRegistry.records[currentMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: currentMacDeviceID,
            macIdentityPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: "wss://relay.current/relay"
        )
        service.setCurrentTrustedMacDeviceId(currentMacDeviceID)
        service.relaySessionId = "saved-session"
        service.relayUrl = "wss://relay.stale/relay"
        service.relayMacDeviceId = staleMacDeviceID
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.noTrustedMac
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertNil(reconnectURL)
    }

    func testPreferredReconnectURLStopsWithUnsupportedRelayWithoutForcingRePair() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 16, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.setCurrentTrustedMacDeviceId(macDeviceID)
        service.shouldAutoReconnectOnForeground = true
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.unsupportedRelay
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertNil(reconnectURL)
        XCTAssertEqual(service.secureConnectionState, .liveSessionUnresolved)
        XCTAssertFalse(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(
            service.lastErrorMessage,
            "Trusted reconnect is unavailable from this relay endpoint. Update or check the relay/proxy, then reconnect. Scan a new QR code only if this device was reset."
        )
    }

    func testWakeDisplayCanUseTrustedRecordWithoutSavedLiveSessionURL() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 17, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.setCurrentTrustedMacDeviceId(macDeviceID)

        XCTAssertTrue(service.hasReconnectCandidate)
        XCTAssertTrue(service.canWakePreferredMacDisplay)
        XCTAssertEqual(service.preferredWakeRelayURL, relayURL)

        service.relaySessionId = "saved-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = macDeviceID
        service.relayMacIdentityPublicKey = Data(repeating: 17, count: 32).base64EncodedString()

        XCTAssertTrue(service.canWakePreferredMacDisplay)
    }

    func testLaunchAutoConnectKeepsResolvingTrustedSessionUntilBridgeRegisters() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let macPublicKey = Data(repeating: 24, count: 32).base64EncodedString()
        var resolveAttempts = 0
        var attemptedURLs: [String] = []

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.setCurrentTrustedMacDeviceId(macDeviceID)
        service.trustedSessionResolverOverride = {
            resolveAttempts += 1
            if resolveAttempts < 3 {
                throw CodexTrustedSessionResolveError.macOffline("Your trusted device is offline right now.")
            }
            return CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: macDeviceID,
                macIdentityPublicKey: macPublicKey,
                displayName: "MacBook",
                sessionId: "fresh-session"
            )
        }
        viewModel.launchReconnectAttemptLimitOverride = 4
        viewModel.reconnectSleepOverride = { _ in }
        viewModel.connectOverride = { codex, serverURL in
            attemptedURLs.append(serverURL)
            codex.isConnected = true
            codex.isInitialized = true
        }

        await viewModel.attemptAutoConnectOnLaunchIfNeeded(codex: service)

        XCTAssertEqual(resolveAttempts, 3)
        XCTAssertEqual(attemptedURLs, ["\(relayURL)/fresh-session"])
        XCTAssertFalse(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.connectionRecoveryState, .idle)
    }

    func testRecoverTrustedReconnectCandidatePreservesTrustedMacAndRelayBaseURL() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let macPublicKey = Data(repeating: 18, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.setCurrentTrustedMacDeviceId(macDeviceID)
        service.relaySessionId = "stale-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = macDeviceID
        service.relayMacIdentityPublicKey = macPublicKey

        service.recoverTrustedReconnectCandidate()

        XCTAssertNil(service.normalizedRelaySessionId)
        XCTAssertEqual(service.normalizedRelayURL, relayURL)
        XCTAssertEqual(service.normalizedRelayMacDeviceId, macDeviceID)
        XCTAssertEqual(service.normalizedRelayMacIdentityPublicKey, macPublicKey)
        XCTAssertFalse(service.hasSavedRelaySession)
        XCTAssertTrue(service.hasTrustedMacReconnectCandidate)
        XCTAssertEqual(service.secureConnectionState, .liveSessionUnresolved)
        XCTAssertTrue(service.canWakePreferredMacDisplay)
        XCTAssertEqual(
            service.lastErrorMessage,
            "Secure reconnect could not be restored from the saved session. Try reconnecting again."
        )
    }

    func testPreferredReconnectURLUsesCurrentMacInsteadOfLastTrustedMac() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let lastTrustedMacDeviceID = "mac-last-\(UUID().uuidString)"
        let currentMacDeviceID = "mac-current-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let currentMacPublicKey = Data(repeating: 22, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[lastTrustedMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: lastTrustedMacDeviceID,
            macIdentityPublicKey: Data(repeating: 21, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.trustedMacRegistry.records[currentMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: currentMacDeviceID,
            macIdentityPublicKey: currentMacPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = lastTrustedMacDeviceID
        service.setCurrentTrustedMacDeviceId(currentMacDeviceID)
        service.trustedSessionResolverOverride = {
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: currentMacDeviceID,
                macIdentityPublicKey: currentMacPublicKey,
                displayName: "Current Mac",
                sessionId: "resolved-current-session"
            )
        }

        let reconnectURL = await viewModel.preferredReconnectURL(codex: service)

        XCTAssertEqual(reconnectURL, "\(relayURL)/resolved-current-session")
        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, currentMacDeviceID)
        XCTAssertNil(service.normalizedRelayMacDeviceId)
    }

    func testPreferredReconnectURLUsesExplicitTargetMacInsteadOfCurrentMacDuringSwitch() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let currentMacDeviceID = "mac-current-\(UUID().uuidString)"
        let targetMacDeviceID = "mac-target-\(UUID().uuidString)"
        let currentRelayURL = "wss://relay.current/relay"
        let targetRelayURL = "wss://relay.target/relay"
        let targetMacPublicKey = Data(repeating: 42, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[currentMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: currentMacDeviceID,
            macIdentityPublicKey: Data(repeating: 41, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: currentRelayURL
        )
        service.trustedMacRegistry.records[targetMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: targetMacDeviceID,
            macIdentityPublicKey: targetMacPublicKey,
            lastPairedAt: Date(),
            relayURL: targetRelayURL
        )
        service.setCurrentTrustedMacDeviceId(currentMacDeviceID)
        service.trustedSessionResolverOverride = {
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: targetMacDeviceID,
                macIdentityPublicKey: targetMacPublicKey,
                displayName: "Target Mac",
                sessionId: "target-session"
            )
        }

        let reconnectURL = await viewModel.preferredReconnectURL(
            codex: service,
            targetMacDeviceId: targetMacDeviceID
        )

        XCTAssertEqual(reconnectURL, "\(targetRelayURL)/target-session")
    }

    func testPreferredReconnectURLRejectsResolvedSessionForDifferentMac() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let targetMacDeviceID = "mac-target-\(UUID().uuidString)"
        let wrongMacDeviceID = "mac-wrong-\(UUID().uuidString)"
        let targetMacPublicKey = Data(repeating: 44, count: 32).base64EncodedString()
        let relayURL = "wss://relay.target/relay"

        service.trustedMacRegistry.records[targetMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: targetMacDeviceID,
            macIdentityPublicKey: targetMacPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.setCurrentTrustedMacDeviceId(targetMacDeviceID)
        service.trustedSessionResolverOverride = {
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: wrongMacDeviceID,
                macIdentityPublicKey: targetMacPublicKey,
                displayName: "Wrong Mac",
                sessionId: "wrong-session"
            )
        }

        let reconnectURL = await viewModel.preferredReconnectURL(
            codex: service,
            targetMacDeviceId: targetMacDeviceID
        )

        XCTAssertNil(reconnectURL)
        XCTAssertEqual(
            service.lastErrorMessage,
            "The trusted device relay returned a session for a different device."
        )
    }

    func testForegroundReconnectStopsAfterRetryLimitWithRetryableFailures() async {
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
        XCTAssertFalse(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.lastErrorMessage, "Could not reconnect. Tap Reconnect to try again.")
        XCTAssertEqual(service.connectionRecoveryState, .idle)
    }

    func testManualReconnectReResolvesReconnectURLBetweenRetryAttempts() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let macPublicKey = Data(repeating: 14, count: 32).base64EncodedString()
        var resolveAttempts = 0
        var attemptedURLs: [String] = []

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.setCurrentTrustedMacDeviceId(macDeviceID)
        service.relaySessionId = "saved-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = macDeviceID
        viewModel.reconnectSleepOverride = { _ in }
        service.trustedSessionResolverOverride = {
            resolveAttempts += 1
            if resolveAttempts == 1 {
                throw CodexTrustedSessionResolveError.macOffline("Your trusted device is offline right now.")
            }
            return CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: macDeviceID,
                macIdentityPublicKey: macPublicKey,
                displayName: "My Mac",
                sessionId: "live-session"
            )
        }
        viewModel.connectOverride = { _, serverURL in
            attemptedURLs.append(serverURL)
            if attemptedURLs.count == 1 {
                throw CodexServiceError.invalidInput("WebSocket closed during connect (4002)")
            }
        }

        await viewModel.toggleConnection(codex: service)

        XCTAssertEqual(resolveAttempts, 2)
        XCTAssertEqual(
            attemptedURLs,
            ["\(relayURL)/saved-session", "\(relayURL)/live-session"]
        )
        XCTAssertFalse(viewModel.isAttemptingManualReconnect)
    }

    func testManualReconnectCancelsStuckTrustedSessionResolve() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let macPublicKey = Data(repeating: 11, count: 32).base64EncodedString()
        var resolveAttempts = 0
        var connectAttempts = 0

        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.setCurrentTrustedMacDeviceId(macDeviceID)
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
                macIdentityPublicKey: macPublicKey,
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
        service.setCurrentTrustedMacDeviceId(macDeviceID)
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

    func testDisconnectPersistsMacScopedOverrideNamespace() async {
        let service = makeService()
        let currentMacDeviceID = "mac-current-\(UUID().uuidString)"
        let targetMacDeviceID = "mac-target-\(UUID().uuidString)"

        service.setCurrentTrustedMacDeviceId(currentMacDeviceID)
        service.messagesByThread = [
            "thread-current": [makeMessage(threadID: "thread-current", text: "current")]
        ]
        service.saveLocalState(for: currentMacDeviceID)

        service.messagesByThread = [
            "thread-target": [makeMessage(threadID: "thread-target", text: "target")]
        ]
        service.macScopedContextOverrideDeviceId = targetMacDeviceID

        await service.disconnect()

        XCTAssertEqual(
            service.messagePersistence.load(macDeviceId: currentMacDeviceID)["thread-current"]?.first?.text,
            "current"
        )
        XCTAssertEqual(
            service.messagePersistence.load(macDeviceId: targetMacDeviceID)["thread-target"]?.first?.text,
            "target"
        )
    }

    func testSwitchToTrustedMacDoesNotPreloadStaleTargetMessagesBeforeLiveConnect() async throws {
        let service = makeService()
        let viewModel = ContentViewModel()
        let currentMacDeviceID = "mac-current-\(UUID().uuidString)"
        let targetMacDeviceID = "mac-target-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let targetMacPublicKey = Data(repeating: 43, count: 32).base64EncodedString()
        var messagesSeenAtConnect: [String: [CodexMessage]] = [:]

        service.trustedMacRegistry.records[currentMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: currentMacDeviceID,
            macIdentityPublicKey: Data(repeating: 42, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.trustedMacRegistry.records[targetMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: targetMacDeviceID,
            macIdentityPublicKey: targetMacPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.setCurrentTrustedMacDeviceId(currentMacDeviceID)
        service.messagesByThread = [
            "thread-current": [makeMessage(threadID: "thread-current", text: "current")]
        ]
        service.saveLocalState(for: currentMacDeviceID)
        service.messagesByThread = [
            "thread-target-old": [makeMessage(threadID: "thread-target-old", text: "target-old")]
        ]
        service.saveLocalState(for: targetMacDeviceID)
        service.loadLocalState(for: currentMacDeviceID)
        service.trustedSessionResolverOverride = {
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: targetMacDeviceID,
                macIdentityPublicKey: targetMacPublicKey,
                displayName: "Target Mac",
                sessionId: "target-session"
            )
        }
        viewModel.connectOverride = { codex, _ in
            messagesSeenAtConnect = codex.messagesByThread
            codex.isConnected = true
            codex.isInitialized = true
        }

        try await viewModel.switchToTrustedMac(deviceId: targetMacDeviceID, codex: service)

        XCTAssertTrue(messagesSeenAtConnect.isEmpty)
        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, targetMacDeviceID)
    }

    func testSwitchToTrustedMacFailureKeepsSelectedMacWithoutPersistingTargetDrafts() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let currentMacDeviceID = "mac-current-\(UUID().uuidString)"
        let targetMacDeviceID = "mac-target-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        let targetMacPublicKey = Data(repeating: 32, count: 32).base64EncodedString()

        service.trustedMacRegistry.records[currentMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: currentMacDeviceID,
            macIdentityPublicKey: Data(repeating: 31, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.trustedMacRegistry.records[targetMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: targetMacDeviceID,
            macIdentityPublicKey: targetMacPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.setCurrentTrustedMacDeviceId(currentMacDeviceID)
        service.messagesByThread = [
            "thread-current": [makeMessage(threadID: "thread-current", text: "current")]
        ]
        service.saveLocalState(for: currentMacDeviceID)
        service.messagesByThread = [
            "thread-target-old": [makeMessage(threadID: "thread-target-old", text: "target-old")]
        ]
        service.saveLocalState(for: targetMacDeviceID)
        service.loadLocalState(for: currentMacDeviceID)
        service.trustedSessionResolverOverride = {
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: targetMacDeviceID,
                macIdentityPublicKey: targetMacPublicKey,
                displayName: "Target Mac",
                sessionId: "target-session"
            )
        }
        viewModel.connectOverride = { codex, _ in
            codex.messagesByThread = [
                "thread-target-new": [self.makeMessage(threadID: "thread-target-new", text: "target-new")]
            ]
            await codex.disconnect()
            throw CodexServiceError.disconnected
        }

        do {
            try await viewModel.switchToTrustedMac(deviceId: targetMacDeviceID, codex: service)
            XCTFail("Expected switch failure to keep the selected device pending reconnect.")
        } catch {
            // Expected.
        }

        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, targetMacDeviceID)
        XCTAssertEqual(service.normalizedPreviousTrustedMacDeviceId, currentMacDeviceID)
        XCTAssertEqual(viewModel.macSwitchNotice, "Connection was interrupted. Tap Reconnect to try again.")

        let currentMessages = service.messagePersistence.load(macDeviceId: currentMacDeviceID)
        let targetMessages = service.messagePersistence.load(macDeviceId: targetMacDeviceID)
        XCTAssertEqual(currentMessages["thread-current"]?.first?.text, "current")
        XCTAssertEqual(targetMessages["thread-target-old"]?.first?.text, "target-old")
        XCTAssertNil(targetMessages["thread-target-new"])
    }

    func testSwitchToTrustedMacOfflineTargetKeepsCurrentRelaySession() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let currentMacDeviceID = "mac-current-\(UUID().uuidString)"
        let targetMacDeviceID = "mac-target-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"
        defer {
            MyDeviceMenuVisibilityStore.removePreference(for: targetMacDeviceID)
        }

        service.trustedMacRegistry.records[currentMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: currentMacDeviceID,
            macIdentityPublicKey: Data(repeating: 51, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.trustedMacRegistry.records[targetMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: targetMacDeviceID,
            macIdentityPublicKey: Data(repeating: 52, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.setCurrentTrustedMacDeviceId(currentMacDeviceID)
        service.relaySessionId = "old-current-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = currentMacDeviceID
        service.relayMacIdentityPublicKey = service.trustedMacRegistry.records[currentMacDeviceID]?.macIdentityPublicKey
        service.isConnected = true
        service.isInitialized = true
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.macOffline("The selected device is offline.")
        }

        do {
            try await viewModel.switchToTrustedMac(deviceId: targetMacDeviceID, codex: service)
            XCTFail("Expected switch failure to leave the current device connected.")
        } catch {
            // Expected.
        }

        XCTAssertEqual(service.normalizedCurrentTrustedMacDeviceId, currentMacDeviceID)
        XCTAssertNil(service.normalizedPreviousTrustedMacDeviceId)
        XCTAssertEqual(service.normalizedRelaySessionId, "old-current-session")
        XCTAssertEqual(service.normalizedRelayMacDeviceId, currentMacDeviceID)
        XCTAssertTrue(service.isConnected)
        XCTAssertTrue(MyDeviceMenuVisibilityStore.isVisible(targetMacDeviceID))
        XCTAssertEqual(
            viewModel.macSwitchNotice,
            "That device is not reachable yet. Make sure its bridge is connected, or rescan its QR code."
        )
        XCTAssertNil(service.lastErrorMessage)
    }

    func testSwitchToScannedMacInterruptsRunningTurnsBeforeConnecting() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        var events: [String] = []

        service.isConnected = true
        service.runningThreadIDs = ["thread-1"]
        service.activeTurnIdByThread["thread-1"] = "turn-1"
        service.requestTransportOverride = { method, _ in
            events.append(method)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }
        viewModel.connectOverride = { _, _ in
            events.append("connect")
            throw CancellationError()
        }

        do {
            try await viewModel.switchToScannedMac(
                pairingPayload: CodexPairingQRPayload(
                    v: codexPairingQRVersion,
                    relay: "wss://relay.local/relay",
                    sessionId: "session-\(UUID().uuidString)",
                    macDeviceId: "mac-\(UUID().uuidString)",
                    macIdentityPublicKey: Data(repeating: 34, count: 32).base64EncodedString(),
                    expiresAt: Int64(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000)
                ),
                codex: service
            )
            XCTFail("Expected connect override to abort the switch.")
        } catch {
            // Expected.
        }

        XCTAssertEqual(events.prefix(2), ["turn/interrupt", "connect"])
    }

    func testCancelledSwitchClearsCurrentSelectionMarksPreviousAndRemovesRelaySession() async {
        let service = makeService()
        let viewModel = ContentViewModel()
        let currentMacDeviceID = "mac-current-\(UUID().uuidString)"
        let targetMacDeviceID = "mac-target-\(UUID().uuidString)"
        let relayURL = "wss://relay.local/relay"

        service.trustedMacRegistry.records[currentMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: currentMacDeviceID,
            macIdentityPublicKey: Data(repeating: 35, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.trustedMacRegistry.records[targetMacDeviceID] = CodexTrustedMacRecord(
            macDeviceId: targetMacDeviceID,
            macIdentityPublicKey: Data(repeating: 36, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.setCurrentTrustedMacDeviceId(currentMacDeviceID)
        service.relaySessionId = "saved-session"
        service.relayUrl = relayURL
        service.relayMacDeviceId = currentMacDeviceID
        viewModel.connectOverride = { _, _ in
            while !Task.isCancelled {
                await Task.yield()
            }
            throw CancellationError()
        }

        let switchTask = Task {
            try await viewModel.switchToTrustedMac(deviceId: targetMacDeviceID, codex: service)
        }

        while !viewModel.isSwitchingMac {
            await Task.yield()
        }

        switchTask.cancel()
        await viewModel.requestMacSwitchCancellation(codex: service)

        do {
            try await switchTask.value
            XCTFail("Expected cancelled switch to terminate with cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertNil(service.normalizedCurrentTrustedMacDeviceId)
        XCTAssertEqual(service.normalizedPreviousTrustedMacDeviceId, currentMacDeviceID)
        XCTAssertNil(service.normalizedRelaySessionId)
        XCTAssertNil(service.normalizedRelayMacDeviceId)
        XCTAssertEqual(viewModel.macSwitchNotice, "Switch cancelled. Choose a device to reconnect.")
        XCTAssertFalse(viewModel.isSwitchingMac)
    }

    func testSuccessfulReconnectClearsPreviousMarkerAndSwitchNotice() async {
        let service = makeService()
        let viewModel = ContentViewModel()

        service.setPreviousTrustedMacDeviceId("mac-previous")
        viewModel.connectOverride = { _, _ in }

        try? await viewModel.connectWithAutoRecovery(
            codex: service,
            performAutoRetry: false,
            serverURLProvider: { "wss://relay.local/relay/session" }
        )

        XCTAssertNil(service.normalizedPreviousTrustedMacDeviceId)
        XCTAssertNil(viewModel.macSwitchNotice)
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
        SecureStore.deleteValue(for: CodexSecureKeys.currentTrustedMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }

    private func makeMessage(threadID: String, text: String) -> CodexMessage {
        CodexMessage(
            threadId: threadID,
            role: .assistant,
            text: text
        )
    }
}
