// FILE: ContentViewModel.swift
// Purpose: Owns non-visual orchestration logic for the root screen (connection, relay pairing, sync throttling).
// Layer: ViewModel
// Exports: ContentViewModel
// Depends on: CryptoKit, Foundation, Observation, CodexService, SecureStore

import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class ContentViewModel {
    private var hasAttemptedInitialAutoConnect = false
    private var lastSidebarOpenSyncAt: Date = .distantPast
    private let autoReconnectBackoffNanoseconds: [UInt64] = [1_000_000_000, 3_000_000_000]
    private let launchReconnectAttemptLimit = 10
    private let reconnectSleepChunkNanoseconds: UInt64 = 100_000_000
    private(set) var isRunningAutoReconnect = false
    private(set) var isRunningManualReconnect = false
    private(set) var isSwitchingMac = false
    private(set) var isCancellingMacSwitch = false
    private(set) var switchingMacDeviceId: String?
    private(set) var macSwitchNotice: String?
    private var shouldCancelManualReconnect = false
    private let macSwitchInterruptTimeoutNanoseconds: UInt64 = 1_500_000_000
    // Test hooks keep reconnect verification fast without changing production retry behavior.
    @ObservationIgnored var reconnectAttemptLimitOverride: Int?
    @ObservationIgnored var launchReconnectAttemptLimitOverride: Int?
    @ObservationIgnored var connectOverride: ((CodexService, String) async throws -> Void)?
    @ObservationIgnored var reconnectSleepOverride: ((UInt64) async -> Void)?
    @ObservationIgnored var reconnectSleepChunkNanosecondsOverride: UInt64?

    private struct RelaySessionSnapshot {
        let relaySessionId: String?
        let relayUrl: String?
        let relayMacDeviceId: String?
        let relayMacIdentityPublicKey: String?
        let relayProtocolVersion: Int
        let lastAppliedBridgeOutboundSeq: Int
        let shouldForceQRBootstrapOnNextHandshake: Bool
        let trustedReconnectFailureCount: Int
        let secureConnectionState: CodexSecureConnectionState
        let secureMacFingerprint: String?
    }

    var isAttemptingAutoReconnect: Bool {
        isRunningAutoReconnect
    }

    var isAttemptingManualReconnect: Bool {
        isRunningManualReconnect
    }

    // Throttles sidebar-open sync requests to avoid redundant thread refresh churn.
    func shouldRequestSidebarFreshSync(isConnected: Bool) -> Bool {
        guard isConnected else {
            return false
        }

        let now = Date()
        guard now.timeIntervalSince(lastSidebarOpenSyncAt) >= 0.8 else {
            return false
        }

        lastSidebarOpenSyncAt = now
        return true
    }

    // Connects to the relay WebSocket using a scanned QR code payload.
    func connectToRelay(pairingPayload: CodexPairingQRPayload, codex: CodexService) async {
        await stopAutoReconnectForManualScan(codex: codex)
        // Avoid logging live pairing metadata; the relay URL path includes a bearer-like session id.
        let fullURL = "\(pairingPayload.relay)/\(pairingPayload.sessionId)"
        codex.rememberRelayPairing(pairingPayload)

        do {
            try await connectWithAutoRecovery(
                codex: codex,
                performAutoRetry: true,
                serverURLProvider: { fullURL }
            )
        } catch {
            if codex.lastErrorMessage?.isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
            }
        }
    }

    // Connects or disconnects the relay.
    func toggleConnection(codex: CodexService) async {
        if codex.isConnected {
            await codex.disconnect()
            codex.clearSavedRelaySession()
            return
        }

        guard !isRunningManualReconnect else {
            return
        }

        // Flips the UI into an immediate busy state before the reconnect handoff reaches the socket layer.
        shouldCancelManualReconnect = false
        isRunningManualReconnect = true
        defer { isRunningManualReconnect = false }

        await stopAutoReconnectForManualRetry(codex: codex)

        guard shouldContinueManualReconnect else {
            codex.connectionRecoveryState = .idle
            return
        }
        do {
            try await connectWithAutoRecovery(
                codex: codex,
                performAutoRetry: true,
                continueWhile: { self.shouldContinueManualReconnect },
                serverURLProvider: { await self.preferredReconnectURL(codex: codex) }
            )
        } catch {
            if isCancellationLikeError(error) {
                return
            }
            if codex.lastErrorMessage?.isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
            }
        }
    }

    // Lets a manual reconnect tap interrupt a stuck foreground recovery loop.
    func stopAutoReconnectForManualRetry(codex: CodexService) async {
        guard isRunningAutoReconnect || codex.isConnecting || codex.shouldAutoReconnectOnForeground else {
            return
        }

        codex.shouldAutoReconnectOnForeground = false
        codex.connectionRecoveryState = .retrying(attempt: 0, message: "Preparing reconnect...")
        codex.lastErrorMessage = nil
        codex.cancelTrustedSessionResolve()

        if codex.isConnecting || codex.isConnected {
            await codex.disconnect()
        }

        while isRunningAutoReconnect || codex.isConnecting {
            await sleepForReconnectBackoff(100_000_000)
        }
    }

    // Lets the manual QR flow take over instead of competing with the foreground reconnect loop.
    func stopAutoReconnectForManualScan(codex: CodexService) async {
        shouldCancelManualReconnect = true
        codex.shouldAutoReconnectOnForeground = false
        codex.connectionRecoveryState = .idle
        codex.lastErrorMessage = nil
        codex.cancelTrustedSessionResolve()

        // Cancel any in-flight reconnect so the scanner can appear immediately instead of waiting
        // for a stalled handshake to time out on its own.
        if codex.isConnecting || codex.isConnected {
            await codex.disconnect()
        }

        while isRunningManualReconnect || isRunningAutoReconnect || codex.isConnecting {
            await sleepForReconnectBackoff(100_000_000)
        }
    }

    // Attempts one automatic connection on app launch using saved relay session.
    func attemptAutoConnectOnLaunchIfNeeded(codex: CodexService) async {
        guard !hasAttemptedInitialAutoConnect else {
            return
        }
        hasAttemptedInitialAutoConnect = true

        guard !codex.isConnected, !codex.isConnecting else {
            return
        }

        guard codex.hasReconnectCandidate else {
            return
        }

        // Cold launches after device sleep often start before the bridge has re-registered
        // its fresh relay session, so use the foreground recovery loop instead of one short attempt.
        codex.shouldAutoReconnectOnForeground = true
        await attemptAutoReconnectOnForegroundIfNeeded(
            codex: codex,
            maxAttempts: launchReconnectAttemptLimitOverride ?? launchReconnectAttemptLimit
        )
    }

    // Reconnects after benign background disconnects.
    func attemptAutoReconnectOnForegroundIfNeeded(codex: CodexService) async {
        await attemptAutoReconnectOnForegroundIfNeeded(
            codex: codex,
            maxAttempts: reconnectAttemptLimitOverride ?? 50
        )
    }

    // Reconnects after wake/cold-launch while allowing trusted session resolve to become live.
    private func attemptAutoReconnectOnForegroundIfNeeded(
        codex: CodexService,
        maxAttempts: Int
    ) async {
        guard codex.shouldAutoReconnectOnForeground, !isRunningAutoReconnect else {
            return
        }

        isRunningAutoReconnect = true
        defer { isRunningAutoReconnect = false }

        var attempt = 0

        // Keep retryable reconnects alive until the socket recovers or the pairing becomes invalid.
        while codex.shouldAutoReconnectOnForeground, attempt < maxAttempts {

            let reconnectResolution = await autoRecoveryReconnectURLResolution(codex: codex)
            guard reconnectResolution.shouldKeepRetrying else {
                codex.shouldAutoReconnectOnForeground = false
                codex.connectionRecoveryState = .idle
                return
            }

            if codex.isConnected {
                codex.shouldAutoReconnectOnForeground = false
                codex.connectionRecoveryState = .idle
                codex.lastErrorMessage = nil
                return
            }

            if codex.isConnecting {
                if !codex.shouldAutoReconnectOnForeground {
                    codex.connectionRecoveryState = .idle
                    return
                }
                await sleepForReconnectBackoff(
                    300_000_000,
                    continueWhile: { codex.shouldAutoReconnectOnForeground }
                )
                continue
            }

            guard let fullURL = reconnectResolution.url else {
                codex.lastErrorMessage = nil
                codex.connectionRecoveryState = .retrying(
                    attempt: max(1, attempt + 1),
                    message: "Reconnecting..."
                )
                let backoffIndex = min(attempt, autoReconnectBackoffNanoseconds.count - 1)
                let backoff = autoReconnectBackoffNanoseconds[backoffIndex]
                attempt += 1
                await sleepForReconnectBackoff(
                    backoff,
                    continueWhile: { codex.shouldAutoReconnectOnForeground }
                )
                continue
            }
            do {
                codex.connectionRecoveryState = .retrying(
                    attempt: max(1, attempt + 1),
                    message: "Reconnecting..."
                )
                try await connect(codex: codex, serverURL: fullURL)
                codex.connectionRecoveryState = .idle
                codex.lastErrorMessage = nil
                codex.shouldAutoReconnectOnForeground = false
                return
            } catch {
                if codex.secureConnectionState == .rePairRequired {
                    codex.connectionRecoveryState = .idle
                    codex.shouldAutoReconnectOnForeground = false
                    if codex.lastErrorMessage?.isEmpty ?? true {
                        codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
                    }
                    return
                }

                if isCancellationLikeError(error) {
                    codex.connectionRecoveryState = .idle
                    return
                }

                if !codex.shouldAutoReconnectOnForeground {
                    codex.connectionRecoveryState = .idle
                    return
                }

                let isRetryable = codex.isRecoverableTransientConnectionError(error)
                    || codex.isBenignBackgroundDisconnect(error)
                    || codex.isRetryableSavedSessionConnectError(error)

                guard isRetryable else {
                    codex.connectionRecoveryState = .idle
                    codex.shouldAutoReconnectOnForeground = false
                    codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
                    return
                }

                codex.lastErrorMessage = nil
                codex.connectionRecoveryState = .retrying(
                    attempt: attempt + 1,
                    message: codex.recoveryStatusMessage(for: error)
                )

                let backoffIndex = min(attempt, autoReconnectBackoffNanoseconds.count - 1)
                let backoff = autoReconnectBackoffNanoseconds[backoffIndex]
                attempt += 1
                await sleepForReconnectBackoff(
                    backoff,
                    continueWhile: { codex.shouldAutoReconnectOnForeground }
                )
            }
        }

        // Exhausted all attempts — stop retrying but keep the saved pairing for next foreground cycle.
        if attempt >= maxAttempts {
            codex.shouldAutoReconnectOnForeground = false
            codex.connectionRecoveryState = .idle
            codex.lastErrorMessage = "Could not reconnect. Tap Reconnect to try again."
        }
    }
}

private struct MacSwitchInterruptTimeout: Error {}

extension ContentViewModel {
    private enum ReconnectURLResolution {
        case use(String)
        case fallbackToSaved
        case retryLater
        case stop
    }

    private struct AutoRecoveryReconnectURLResolution {
        let url: String?
        let shouldKeepRetrying: Bool
    }

    func connect(codex: CodexService, serverURL: String) async throws {
        if let connectOverride {
            try await connectOverride(codex, serverURL)
            return
        }

        try await codex.connect(
            serverURL: serverURL,
            token: "",
            role: "iphone"
        )
    }

    // Re-resolves the reconnect target on every retry so bridge restarts cannot pin
    // launch/manual recovery loops to one stale saved session id.
    func connectWithAutoRecovery(
        codex: CodexService,
        performAutoRetry: Bool,
        continueWhile shouldContinue: (() -> Bool)? = nil,
        serverURLProvider: () async -> String?
    ) async throws {
        guard !isRunningAutoReconnect else {
            return
        }

        isRunningAutoReconnect = true
        defer { isRunningAutoReconnect = false }

        let maxAttemptIndex = performAutoRetry ? autoReconnectBackoffNanoseconds.count : 0
        var lastError: Error?

        for attemptIndex in 0...maxAttemptIndex {
            if Task.isCancelled {
                codex.connectionRecoveryState = .idle
                throw CancellationError()
            }

            guard shouldContinue?() ?? true else {
                codex.connectionRecoveryState = .idle
                throw CancellationError()
            }

            guard let serverURL = await serverURLProvider() else {
                codex.connectionRecoveryState = .idle
                return
            }

            guard shouldContinue?() ?? true else {
                codex.connectionRecoveryState = .idle
                throw CancellationError()
            }

            if attemptIndex > 0 {
                codex.connectionRecoveryState = .retrying(
                    attempt: attemptIndex,
                    message: "Connection timed out. Retrying..."
                )
            }

            do {
                try await connect(codex: codex, serverURL: serverURL)
                codex.connectionRecoveryState = .idle
                codex.lastErrorMessage = nil
                codex.shouldAutoReconnectOnForeground = false
                codex.clearPreviousTrustedMacDeviceId()
                macSwitchNotice = nil
                return
            } catch {
                if isCancellationLikeError(error) {
                    codex.connectionRecoveryState = .idle
                    throw error
                }

                lastError = error
                if codex.secureConnectionState == .rePairRequired {
                    codex.connectionRecoveryState = .idle
                    codex.shouldAutoReconnectOnForeground = false
                    if codex.lastErrorMessage?.isEmpty ?? true {
                        codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
                    }
                    throw error
                }

                let isRetryable = codex.isRecoverableTransientConnectionError(error)
                    || codex.isBenignBackgroundDisconnect(error)
                    || codex.isRetryableSavedSessionConnectError(error)

                guard performAutoRetry,
                      isRetryable,
                      attemptIndex < autoReconnectBackoffNanoseconds.count else {
                    codex.connectionRecoveryState = .idle
                    codex.shouldAutoReconnectOnForeground = false
                    codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
                    throw error
                }

                codex.lastErrorMessage = nil
                codex.connectionRecoveryState = .retrying(
                    attempt: attemptIndex + 1,
                    message: codex.recoveryStatusMessage(for: error)
                )
                await sleepForReconnectBackoff(
                    autoReconnectBackoffNanoseconds[attemptIndex],
                    continueWhile: shouldContinue
                )
                if Task.isCancelled {
                    codex.connectionRecoveryState = .idle
                    throw CancellationError()
                }
            }
        }

        if let lastError {
            codex.connectionRecoveryState = .idle
            codex.shouldAutoReconnectOnForeground = false
            codex.lastErrorMessage = codex.userFacingConnectFailureMessage(lastError)
            throw lastError
        }
    }

    // Chooses the best reconnect path: resolve the live trusted-Mac session first, then fall back to the saved QR session.
    func preferredReconnectURL(codex: CodexService) async -> String? {
        await preferredReconnectURL(
            codex: codex,
            targetMacDeviceId: codex.normalizedCurrentTrustedMacDeviceId
        )
    }

    // Resolves a reconnect URL for an explicit Mac target, instead of implicitly following the current one.
    func preferredReconnectURL(
        codex: CodexService,
        targetMacDeviceId: String?
    ) async -> String? {
        switch await trustedReconnectResolution(
            codex: codex,
            targetMacDeviceId: targetMacDeviceId
        ) {
        case .use(let resolvedURL):
            return resolvedURL
        case .fallbackToSaved:
            return savedReconnectURL(codex: codex, targetMacDeviceId: targetMacDeviceId)
        case .retryLater:
            return nil
        case .stop:
            return nil
        }
    }

    // Keeps launch/foreground recovery alive while the bridge is still re-registering after sleep.
    private func autoRecoveryReconnectURLResolution(codex: CodexService) async -> AutoRecoveryReconnectURLResolution {
        let targetMacDeviceId = codex.normalizedCurrentTrustedMacDeviceId
        switch await trustedReconnectResolution(
            codex: codex,
            targetMacDeviceId: targetMacDeviceId
        ) {
        case .use(let resolvedURL):
            return AutoRecoveryReconnectURLResolution(url: resolvedURL, shouldKeepRetrying: true)
        case .fallbackToSaved:
            if let savedURL = savedReconnectURL(codex: codex, targetMacDeviceId: targetMacDeviceId) {
                return AutoRecoveryReconnectURLResolution(url: savedURL, shouldKeepRetrying: true)
            }
            return AutoRecoveryReconnectURLResolution(
                url: nil,
                shouldKeepRetrying: codex.hasTrustedMacReconnectCandidate
            )
        case .retryLater:
            return AutoRecoveryReconnectURLResolution(url: nil, shouldKeepRetrying: true)
        case .stop:
            return AutoRecoveryReconnectURLResolution(url: nil, shouldKeepRetrying: false)
        }
    }

    // Resolves a trusted-Mac session when possible and tells the caller whether to use, fall back, or stop.
    private func trustedReconnectResolution(codex: CodexService) async -> ReconnectURLResolution {
        await trustedReconnectResolution(
            codex: codex,
            targetMacDeviceId: codex.normalizedCurrentTrustedMacDeviceId
        )
    }

    private func trustedReconnectResolution(
        codex: CodexService,
        targetMacDeviceId: String?
    ) async -> ReconnectURLResolution {
        let normalizedTargetMacDeviceId = normalizedMacDeviceId(targetMacDeviceId)
        guard let targetMacDeviceId = normalizedTargetMacDeviceId,
              let trustedMac = codex.trustedMacRecord(for: targetMacDeviceId),
              trustedMac.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            logMacSwitchState("resolve-skip-no-trusted-target", targetMacDeviceId: normalizedTargetMacDeviceId, codex: codex)
            return .fallbackToSaved
        }

        do {
            logMacSwitchState("resolve-start", targetMacDeviceId: targetMacDeviceId, codex: codex)
            guard let trustedReconnectURL = try await resolvedTrustedReconnectURL(
                codex: codex,
                targetMacDeviceId: targetMacDeviceId
            ) else {
                logMacSwitchState("resolve-empty", targetMacDeviceId: targetMacDeviceId, codex: codex)
                return .fallbackToSaved
            }
            logMacSwitchState("resolve-use-live-session", targetMacDeviceId: targetMacDeviceId, codex: codex)
            return .use(trustedReconnectURL)
        } catch let error as CodexTrustedSessionResolveError {
            logMacSwitchState(
                "resolve-error \(String(describing: error))",
                targetMacDeviceId: targetMacDeviceId,
                codex: codex
            )
            if case .macOffline = error,
               let alternate = await resolvedAlternateTrustedReconnectURL(
                    codex: codex,
                    offlineTrustedMac: trustedMac
               ) {
                logMacSwitchState(
                    "resolve-use-alternate-live-record from=\(redactedMacSwitchIdentifier(targetMacDeviceId))",
                    targetMacDeviceId: alternate.macDeviceId,
                    codex: codex
                )
                return .use(alternate.url)
            }
            if case .macOffline = error {
                let prunedCount = codex.pruneOfflineTrustedMacRecords(matching: trustedMac)
                logMacSwitchState(
                    "pruned-offline-selection count=\(prunedCount)",
                    targetMacDeviceId: targetMacDeviceId,
                    codex: codex
                )
                if prunedCount > 0 {
                    macSwitchNotice = "Removed old saved entries for that device. Scan its QR code once if it is still missing."
                }
            }
            return trustedReconnectResolution(
                for: error,
                codex: codex,
                targetMacDeviceId: targetMacDeviceId
            )
        } catch is CancellationError {
            logMacSwitchState("resolve-cancelled", targetMacDeviceId: targetMacDeviceId, codex: codex)
            return .stop
        } catch {
            if savedReconnectURL(codex: codex, targetMacDeviceId: targetMacDeviceId) == nil {
                codex.lastErrorMessage = codex.userFacingTurnErrorMessageForFooter(from: error)
            }
            let message = codex.userFacingTurnErrorMessageForFooter(from: error) ?? String(describing: error)
            logMacSwitchState(
                "resolve-unexpected-error \(message)",
                targetMacDeviceId: targetMacDeviceId,
                codex: codex
            )
            return .fallbackToSaved
        }
    }

    // Builds the live reconnect URL after the trusted-session lookup succeeds.
    private func resolvedTrustedReconnectURL(
        codex: CodexService,
        targetMacDeviceId: String
    ) async throws -> String? {
        let resolved = try await codex.resolveTrustedMacSession(deviceId: targetMacDeviceId)
        guard let trustedMac = codex.trustedMacRecord(for: targetMacDeviceId),
              let relayURL = trustedMac.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayURL.isEmpty else {
            return nil
        }
        try validateResolvedTrustedReconnectTarget(resolved, trustedMac: trustedMac)
        return "\(relayURL)/\(resolved.sessionId)"
    }

    // Recovers from stale duplicate records by trying only records with the same stable Mac key.
    private func resolvedAlternateTrustedReconnectURL(
        codex: CodexService,
        offlineTrustedMac: CodexTrustedMacRecord
    ) async -> (url: String, macDeviceId: String)? {
        let candidates = alternateTrustedMacCandidates(
            for: offlineTrustedMac,
            codex: codex
        )
        for candidate in candidates {
            do {
                guard let url = try await resolvedTrustedReconnectURL(
                    codex: codex,
                    targetMacDeviceId: candidate.macDeviceId
                ) else {
                    continue
                }
                codex.setCurrentTrustedMacDeviceId(candidate.macDeviceId)
                return (url, candidate.macDeviceId)
            } catch {
                logMacSwitchState(
                    "resolve-alternate-failed \(String(describing: error))",
                    targetMacDeviceId: candidate.macDeviceId,
                    codex: codex
                )
                continue
            }
        }
        return nil
    }

    private func alternateTrustedMacCandidates(
        for trustedMac: CodexTrustedMacRecord,
        codex: CodexService
    ) -> [CodexTrustedMacRecord] {
        let trustedPublicKey = trustedMac.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trustedPublicKey.isEmpty else {
            return []
        }

        return codex.trustedMacRegistry.records.values
            .filter { candidate in
                let candidatePublicKey = candidate.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
                return candidate.macDeviceId != trustedMac.macDeviceId
                    && candidatePublicKey == trustedPublicKey
                    && candidate.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            .sorted { lhs, rhs in
                trustedMacActivityDate(lhs) > trustedMacActivityDate(rhs)
            }
    }

    private func trustedMacActivityDate(_ trustedMac: CodexTrustedMacRecord) -> Date {
        trustedMac.lastResolvedAt ?? trustedMac.lastUsedAt ?? trustedMac.lastPairedAt
    }

    // Test overrides and relay responses must not silently retarget a manual Mac switch.
    private func validateResolvedTrustedReconnectTarget(
        _ resolved: CodexTrustedSessionResolveResponse,
        trustedMac: CodexTrustedMacRecord
    ) throws {
        guard resolved.macDeviceId == trustedMac.macDeviceId else {
            throw CodexTrustedSessionResolveError.invalidResponse(
                "The trusted device relay returned a session for a different device."
            )
        }

        let resolvedPublicKey = resolved.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trustedPublicKey = trustedMac.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedPublicKey.isEmpty, resolvedPublicKey == trustedPublicKey else {
            throw CodexTrustedSessionResolveError.invalidResponse(
                "The trusted device relay returned a different device identity key."
            )
        }
    }

    // Applies trusted-resolve error policy without mixing it into the happy path URL assembly.
    private func trustedReconnectResolution(
        for error: CodexTrustedSessionResolveError,
        codex: CodexService,
        targetMacDeviceId: String?
    ) -> ReconnectURLResolution {
        let hasSavedReconnectURL = savedReconnectURL(codex: codex, targetMacDeviceId: targetMacDeviceId) != nil
        switch error {
        case .unsupportedRelay:
            if !hasSavedReconnectURL {
                codex.secureConnectionState = .liveSessionUnresolved
                codex.connectionRecoveryState = .idle
                codex.shouldAutoReconnectOnForeground = false
                codex.lastErrorMessage = "Trusted reconnect is unavailable from this relay endpoint. Update or check the relay/proxy, then reconnect. Scan a new QR code only if this device was reset."
                return .stop
            }
            return .fallbackToSaved
        case .macOffline(let message):
            if hasSavedReconnectURL {
                codex.lastErrorMessage = nil
                return .fallbackToSaved
            }
            if isConnectedToDifferentCurrentDevice(codex: codex, targetMacDeviceId: targetMacDeviceId) {
                macSwitchNotice = "That device is not reachable yet. Make sure its bridge is connected, or rescan its QR code."
                return .retryLater
            }
            codex.lastErrorMessage = message
            return .retryLater
        case .rePairRequired(let message):
            if hasSavedReconnectURL {
                // Trusted-session lookup is only a shortcut; the target-matched saved socket handshake is the authority.
                codex.restoreTrustedPairPresentationState()
                codex.lastErrorMessage = nil
                return .fallbackToSaved
            }
            codex.connectionRecoveryState = .idle
            codex.shouldAutoReconnectOnForeground = false
            codex.lastErrorMessage = message
            return .stop
        case .noTrustedMac:
            return .fallbackToSaved
        case .invalidResponse(let message), .network(let message):
            if !hasSavedReconnectURL {
                codex.secureConnectionState = .liveSessionUnresolved
                codex.lastErrorMessage = message
            }
            return .fallbackToSaved
        }
    }

    // Reuses the last QR-resolved session when trusted lookup is unavailable or not yet supported end-to-end.
    private func savedReconnectURL(codex: CodexService, targetMacDeviceId: String?) -> String? {
        guard let sessionId = codex.normalizedRelaySessionId,
              let relayURL = codex.normalizedRelayURL else {
            return nil
        }

        if let normalizedTargetMacDeviceId = normalizedMacDeviceId(targetMacDeviceId),
           codex.normalizedRelayMacDeviceId != normalizedTargetMacDeviceId {
            return nil
        }
        return "\(relayURL)/\(sessionId)"
    }

    private func isConnectedToDifferentCurrentDevice(codex: CodexService, targetMacDeviceId: String?) -> Bool {
        guard codex.isConnected,
              let currentDeviceId = codex.normalizedCurrentTrustedMacDeviceId,
              let targetDeviceId = normalizedMacDeviceId(targetMacDeviceId) else {
            return false
        }
        return currentDeviceId != targetDeviceId
    }

    func switchToTrustedMac(deviceId: String, codex: CodexService) async throws {
        let normalizedTargetMacDeviceId = try normalizedRequiredMacDeviceId(deviceId)
        logMacSwitchState("start", targetMacDeviceId: normalizedTargetMacDeviceId, codex: codex)
        guard normalizedTargetMacDeviceId != codex.normalizedCurrentTrustedMacDeviceId else {
            logMacSwitchState("ignored-already-current", targetMacDeviceId: normalizedTargetMacDeviceId, codex: codex)
            return
        }
        guard !isSwitchingMac else {
            logMacSwitchState("ignored-switch-in-flight", targetMacDeviceId: normalizedTargetMacDeviceId, codex: codex)
            return
        }

        isSwitchingMac = true
        isCancellingMacSwitch = false
        switchingMacDeviceId = normalizedTargetMacDeviceId
        macSwitchNotice = nil
        defer {
            isCancellingMacSwitch = false
            switchingMacDeviceId = nil
            isSwitchingMac = false
        }

        var effectiveTargetMacDeviceId = normalizedTargetMacDeviceId
        let previousCurrentTrustedMacDeviceId = codex.normalizedCurrentTrustedMacDeviceId
        let previousErrorMessage = codex.lastErrorMessage
        codex.lastErrorMessage = nil

        do {
            // Resolve the selected Mac before touching the live socket so an offline/stale record cannot drop the current connection.
            guard let fullURL = await preferredReconnectURL(
                codex: codex,
                targetMacDeviceId: normalizedTargetMacDeviceId
            ) else {
                let switchFailureMessage = macSwitchNotice
                    ?? codex.lastErrorMessage
                    ?? "Could not reconnect to the selected device."
                macSwitchNotice = switchFailureMessage
                codex.lastErrorMessage = isConnectedToDifferentCurrentDevice(
                    codex: codex,
                    targetMacDeviceId: normalizedTargetMacDeviceId
                ) ? previousErrorMessage : switchFailureMessage
                logMacSwitchState("missing-reconnect-url-keeping-current", targetMacDeviceId: normalizedTargetMacDeviceId, codex: codex)
                throw CodexServiceError.invalidInput("Could not reconnect to the selected device.")
            }
            if let resolvedMacDeviceId = codex.normalizedRelayMacDeviceId,
               resolvedMacDeviceId != effectiveTargetMacDeviceId {
                effectiveTargetMacDeviceId = resolvedMacDeviceId
                switchingMacDeviceId = resolvedMacDeviceId
                logMacSwitchState("retargeted-live-record", targetMacDeviceId: resolvedMacDeviceId, codex: codex)
            }

            try await interruptRunningTurnsBeforeMacSwitchIfNeeded(codex: codex)
            await stopAutoReconnectForManualRetry(codex: codex)

            codex.saveLocalState(for: previousCurrentTrustedMacDeviceId)
            beginMacSwitchContext(effectiveTargetMacDeviceId, codex: codex)
            if let previousCurrentTrustedMacDeviceId {
                codex.setPreviousTrustedMacDeviceId(previousCurrentTrustedMacDeviceId)
            } else {
                codex.clearPreviousTrustedMacDeviceId()
            }
            codex.setCurrentTrustedMacDeviceId(effectiveTargetMacDeviceId)
            await codex.disconnect(preserveReconnectIntent: false)
            prepareMacSwitchState(for: effectiveTargetMacDeviceId, codex: codex, loadCachedMessages: false)
            logMacSwitchState("prepared-target-state", targetMacDeviceId: effectiveTargetMacDeviceId, codex: codex)

            if let resolvedMacDeviceId = codex.normalizedRelayMacDeviceId,
               resolvedMacDeviceId != effectiveTargetMacDeviceId {
                effectiveTargetMacDeviceId = resolvedMacDeviceId
                switchingMacDeviceId = resolvedMacDeviceId
                codex.setCurrentTrustedMacDeviceId(resolvedMacDeviceId)
                codex.macScopedContextOverrideDeviceId = resolvedMacDeviceId
                prepareMacSwitchState(for: resolvedMacDeviceId, codex: codex, loadCachedMessages: false)
                logMacSwitchState("retargeted-live-record", targetMacDeviceId: resolvedMacDeviceId, codex: codex)
            }

            logMacSwitchState("connect-start", targetMacDeviceId: effectiveTargetMacDeviceId, codex: codex)
            try await connectWithAutoRecovery(
                codex: codex,
                performAutoRetry: true,
                continueWhile: { !self.isCancellingMacSwitch },
                serverURLProvider: { fullURL }
            )
            codex.setCurrentTrustedMacDeviceId(effectiveTargetMacDeviceId)
            macSwitchNotice = nil
            endMacSwitchContext(codex: codex)
            logMacSwitchState("success", targetMacDeviceId: effectiveTargetMacDeviceId, codex: codex)
        } catch is CancellationError {
            logMacSwitchState("cancelled", targetMacDeviceId: effectiveTargetMacDeviceId, codex: codex)
            await finalizeCancelledMacSwitch(
                previousCurrentTrustedMacDeviceId: previousCurrentTrustedMacDeviceId,
                codex: codex
            )
            throw CancellationError()
        } catch {
            if isCancellingMacSwitch {
                logMacSwitchState("cancel-requested", targetMacDeviceId: effectiveTargetMacDeviceId, codex: codex)
                await finalizeCancelledMacSwitch(
                    previousCurrentTrustedMacDeviceId: previousCurrentTrustedMacDeviceId,
                    codex: codex
                )
                throw CancellationError()
            }
            if codex.isConnected || codex.isInitialized {
                codex.setCurrentTrustedMacDeviceId(previousCurrentTrustedMacDeviceId)
                codex.clearPreviousTrustedMacDeviceId()
                macSwitchNotice = macSwitchNotice
                    ?? codex.lastErrorMessage
                    ?? previousErrorMessage
                    ?? codex.userFacingConnectFailureMessage(error)
                codex.lastErrorMessage = previousErrorMessage
                logMacSwitchState("failed-before-disconnect-kept-current \(macSwitchNotice ?? "")", targetMacDeviceId: normalizedTargetMacDeviceId, codex: codex)
                throw error
            }
            codex.setCurrentTrustedMacDeviceId(effectiveTargetMacDeviceId)
            codex.macScopedContextOverrideDeviceId = effectiveTargetMacDeviceId
            prepareMacSwitchState(for: effectiveTargetMacDeviceId, codex: codex, loadCachedMessages: true)
            restoreSelectedMacPresentationAfterFailedSwitch(codex: codex)
            if codex.lastErrorMessage?.isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
            } else if codex.lastErrorMessage == nil {
                codex.lastErrorMessage = previousErrorMessage
            }
            macSwitchNotice = codex.lastErrorMessage
            endMacSwitchContext(codex: codex)
            logMacSwitchState("failed \(codex.lastErrorMessage ?? codex.userFacingConnectFailureMessage(error))", targetMacDeviceId: effectiveTargetMacDeviceId, codex: codex)
            throw error
        }
    }

    func switchToScannedMac(pairingPayload: CodexPairingQRPayload, codex: CodexService) async throws {
        guard !isSwitchingMac else {
            return
        }

        isSwitchingMac = true
        isCancellingMacSwitch = false
        switchingMacDeviceId = pairingPayload.macDeviceId
        macSwitchNotice = nil
        defer {
            isCancellingMacSwitch = false
            switchingMacDeviceId = nil
            isSwitchingMac = false
        }

        let previousCurrentTrustedMacDeviceId = codex.normalizedCurrentTrustedMacDeviceId
        let previousErrorMessage = codex.lastErrorMessage
        let previousRelaySessionSnapshot = captureRelaySessionSnapshot(from: codex)
        codex.lastErrorMessage = nil

        try await interruptRunningTurnsBeforeMacSwitchIfNeeded(codex: codex)
        await stopAutoReconnectForManualScan(codex: codex)
        codex.saveLocalState(for: previousCurrentTrustedMacDeviceId)
        beginMacSwitchContext(pairingPayload.macDeviceId, codex: codex)
        codex.rememberRelayPairing(pairingPayload)
        prepareMacSwitchState(for: pairingPayload.macDeviceId, codex: codex, loadCachedMessages: false)

        do {
            try await connectWithAutoRecovery(
                codex: codex,
                performAutoRetry: true,
                continueWhile: { !self.isCancellingMacSwitch },
                serverURLProvider: { "\(pairingPayload.relay)/\(pairingPayload.sessionId)" }
            )
            endMacSwitchContext(codex: codex)
        } catch is CancellationError {
            await finalizeCancelledMacSwitch(
                previousCurrentTrustedMacDeviceId: previousCurrentTrustedMacDeviceId,
                codex: codex
            )
            throw CancellationError()
        } catch {
            if isCancellingMacSwitch {
                await finalizeCancelledMacSwitch(
                    previousCurrentTrustedMacDeviceId: previousCurrentTrustedMacDeviceId,
                    codex: codex
                )
                throw CancellationError()
            }
            codex.setCurrentTrustedMacDeviceId(previousCurrentTrustedMacDeviceId)
            restoreRelaySessionSnapshot(previousRelaySessionSnapshot, to: codex)
            codex.macScopedContextOverrideDeviceId = previousCurrentTrustedMacDeviceId
            prepareMacSwitchState(for: previousCurrentTrustedMacDeviceId, codex: codex, loadCachedMessages: true)
            endMacSwitchContext(codex: codex)
            if codex.lastErrorMessage?.isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
            } else if codex.lastErrorMessage == nil {
                codex.lastErrorMessage = previousErrorMessage
            }
            throw error
        }
    }

    func requestMacSwitchCancellation(codex: CodexService) async {
        guard isSwitchingMac else {
            return
        }

        isCancellingMacSwitch = true
        codex.shouldAutoReconnectOnForeground = false
        codex.connectionRecoveryState = .idle
        codex.cancelTrustedSessionResolve()
        if codex.isConnecting || codex.isConnected || codex.isInitialized {
            await codex.disconnect(preserveReconnectIntent: false)
        }
    }

    // Centralizes reconnect sleeps so manual retry can interrupt stale foreground backoff quickly.
    private func sleepForReconnectBackoff(
        _ nanoseconds: UInt64,
        continueWhile shouldContinue: (() -> Bool)? = nil
    ) async {
        if let reconnectSleepOverride {
            await reconnectSleepOverride(nanoseconds)
            return
        }

        guard let shouldContinue else {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return
        }

        var remaining = nanoseconds
        let chunkSize = max(1 as UInt64, reconnectSleepChunkNanosecondsOverride ?? reconnectSleepChunkNanoseconds)
        while remaining > 0 {
            guard shouldContinue() else {
                return
            }

            let nextChunk = min(remaining, chunkSize)
            try? await Task.sleep(nanoseconds: nextChunk)
            remaining -= nextChunk
        }
    }

    // Treats cancelled resolve/connect work as intentional handoff, not as a user-visible failure.
    private func isCancellationLikeError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private var shouldContinueManualReconnect: Bool {
        !shouldCancelManualReconnect
    }

    private func normalizedMacDeviceId(_ deviceId: String?) -> String? {
        guard let trimmed = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizedRequiredMacDeviceId(_ deviceId: String?) throws -> String {
        guard let normalizedMacDeviceId = normalizedMacDeviceId(deviceId) else {
            throw CodexServiceError.invalidInput("A valid device id is required.")
        }
        return normalizedMacDeviceId
    }

    private func beginMacSwitchContext(_ macDeviceId: String?, codex: CodexService) {
        codex.suspendAutomaticMacScopedPersistence = true
        codex.macScopedContextOverrideDeviceId = normalizedMacDeviceId(macDeviceId)
    }

    private func prepareMacSwitchState(
        for macDeviceId: String?,
        codex: CodexService,
        loadCachedMessages: Bool
    ) {
        codex.clearInMemoryMacScopedState()
        if loadCachedMessages {
            codex.loadLocalState(for: macDeviceId)
        }
        // Manual switches wait for live sync before showing messages so stale per-Mac caches do not flash.
        codex.loadMacScopedDefaultsState(for: macDeviceId)
    }

    private func endMacSwitchContext(codex: CodexService) {
        codex.macScopedContextOverrideDeviceId = nil
        codex.suspendAutomaticMacScopedPersistence = false
    }

    // Keeps an explicit manual Mac selection durable even when the socket cannot reconnect yet.
    private func restoreSelectedMacPresentationAfterFailedSwitch(codex: CodexService) {
        if codex.secureConnectionState == .rePairRequired || codex.secureConnectionState == .updateRequired {
            return
        }

        codex.restoreTrustedPairPresentationState()
    }

    // Emits redacted switch traces so manual Mac switching can be debugged from device logs.
    private func logMacSwitchState(_ event: String, targetMacDeviceId: String?, codex: CodexService) {
        let target = redactedMacSwitchIdentifier(targetMacDeviceId)
        let current = redactedMacSwitchIdentifier(codex.normalizedCurrentTrustedMacDeviceId)
        let previous = redactedMacSwitchIdentifier(codex.normalizedPreviousTrustedMacDeviceId)
        let relayMac = redactedMacSwitchIdentifier(codex.normalizedRelayMacDeviceId)
        let relaySession = redactedMacSwitchIdentifier(codex.normalizedRelaySessionId)
        print(
            "[CodexSwitch] \(event) target=\(target) current=\(current) previous=\(previous) "
            + "relayMac=\(relayMac) relaySession=\(relaySession) connected=\(codex.isConnected) "
            + "state=\(codex.secureConnectionState.statusLabel)"
        )
    }

    private func redactedMacSwitchIdentifier(_ value: String?) -> String {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return "none"
        }
        return SHA256.hash(data: Data(normalized.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
            .description
    }

    private func interruptRunningTurnsBeforeMacSwitchIfNeeded(codex: CodexService) async throws {
        guard codex.isConnected || codex.isInitialized else {
            return
        }

        let runningCount = codex.runningThreadIDs.count
        let protectedCount = codex.protectedRunningFallbackThreadIDs.count
        let activeCount = codex.activeTurnIdByThread.count
        guard runningCount > 0 || protectedCount > 0 || activeCount > 0 else {
            return
        }

        logMacSwitchState(
            "interrupt-running-start running=\(runningCount) protected=\(protectedCount) active=\(activeCount)",
            targetMacDeviceId: switchingMacDeviceId,
            codex: codex
        )

        do {
            try await runMacSwitchInterruptPreflight(codex: codex)
            logMacSwitchState("interrupt-running-finished", targetMacDeviceId: switchingMacDeviceId, codex: codex)
        } catch is MacSwitchInterruptTimeout {
            codex.lastErrorMessage = nil
            logMacSwitchState("interrupt-running-timeout-continuing", targetMacDeviceId: switchingMacDeviceId, codex: codex)
        } catch {
            codex.lastErrorMessage = nil
            logMacSwitchState(
                "interrupt-running-failed-continuing \(codex.userFacingTurnErrorMessageForFooter(from: error) ?? String(describing: error))",
                targetMacDeviceId: switchingMacDeviceId,
                codex: codex
            )
        }
    }

    // Interrupting the old Mac is best-effort; stale run state must not block an explicit Mac switch.
    private func runMacSwitchInterruptPreflight(codex: CodexService) async throws {
        let timeoutNanoseconds = macSwitchInterruptTimeoutNanoseconds
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await codex.interruptAllRunningTurnsBeforeMacSwitch()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MacSwitchInterruptTimeout()
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func finalizeCancelledMacSwitch(
        previousCurrentTrustedMacDeviceId: String?,
        codex: CodexService
    ) async {
        codex.lastErrorMessage = nil
        codex.connectionRecoveryState = .idle
        codex.shouldAutoReconnectOnForeground = false
        codex.cancelTrustedSessionResolve()
        await codex.disconnect(preserveReconnectIntent: false)
        codex.setCurrentTrustedMacDeviceId(nil)
        if let previousCurrentTrustedMacDeviceId {
            codex.setPreviousTrustedMacDeviceId(previousCurrentTrustedMacDeviceId)
        }
        codex.clearSavedRelaySession()
        codex.clearInMemoryMacScopedState()
        endMacSwitchContext(codex: codex)
        macSwitchNotice = "Switch cancelled. Choose a device to reconnect."
    }

    private func captureRelaySessionSnapshot(from codex: CodexService) -> RelaySessionSnapshot {
        RelaySessionSnapshot(
            relaySessionId: codex.relaySessionId,
            relayUrl: codex.relayUrl,
            relayMacDeviceId: codex.relayMacDeviceId,
            relayMacIdentityPublicKey: codex.relayMacIdentityPublicKey,
            relayProtocolVersion: codex.relayProtocolVersion,
            lastAppliedBridgeOutboundSeq: codex.lastAppliedBridgeOutboundSeq,
            shouldForceQRBootstrapOnNextHandshake: codex.shouldForceQRBootstrapOnNextHandshake,
            trustedReconnectFailureCount: codex.trustedReconnectFailureCount,
            secureConnectionState: codex.secureConnectionState,
            secureMacFingerprint: codex.secureMacFingerprint
        )
    }

    private func restoreRelaySessionSnapshot(_ snapshot: RelaySessionSnapshot, to codex: CodexService) {
        codex.relaySessionId = snapshot.relaySessionId
        codex.relayUrl = snapshot.relayUrl
        codex.relayMacDeviceId = snapshot.relayMacDeviceId
        codex.relayMacIdentityPublicKey = snapshot.relayMacIdentityPublicKey
        codex.relayProtocolVersion = snapshot.relayProtocolVersion
        codex.lastAppliedBridgeOutboundSeq = snapshot.lastAppliedBridgeOutboundSeq
        codex.shouldForceQRBootstrapOnNextHandshake = snapshot.shouldForceQRBootstrapOnNextHandshake
        codex.trustedReconnectFailureCount = snapshot.trustedReconnectFailureCount
        codex.secureConnectionState = snapshot.secureConnectionState
        codex.secureMacFingerprint = snapshot.secureMacFingerprint

        if let relaySessionId = snapshot.relaySessionId {
            SecureStore.writeString(relaySessionId, for: CodexSecureKeys.relaySessionId)
        } else {
            SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        }
        if let relayUrl = snapshot.relayUrl {
            SecureStore.writeString(relayUrl, for: CodexSecureKeys.relayUrl)
        } else {
            SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        }
        if let relayMacDeviceId = snapshot.relayMacDeviceId {
            SecureStore.writeString(relayMacDeviceId, for: CodexSecureKeys.relayMacDeviceId)
        } else {
            SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        }
        if let relayMacIdentityPublicKey = snapshot.relayMacIdentityPublicKey {
            SecureStore.writeString(relayMacIdentityPublicKey, for: CodexSecureKeys.relayMacIdentityPublicKey)
        } else {
            SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        }
        SecureStore.writeString(String(snapshot.relayProtocolVersion), for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.writeString(
            String(snapshot.lastAppliedBridgeOutboundSeq),
            for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq
        )
    }
}
