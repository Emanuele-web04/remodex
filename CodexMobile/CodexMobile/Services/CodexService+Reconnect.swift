// FILE: CodexService+Reconnect.swift
// Purpose: Owns connection, relay pairing, and sync reconnect orchestration logic.
// Layer: Service
// Exports: CodexService
// Depends on: Foundation, Observation

import Foundation
import Observation

extension CodexService {
    var isAttemptingAutoReconnect: Bool {
        isRunningAutoReconnect
    }

    var isAttemptingManualReconnect: Bool {
        isRunningManualReconnect
    }

    // Connects to the relay WebSocket using a scanned QR code payload.
    func connectToRelay(pairingPayload: CodexPairingQRPayload) async {
        await stopAutoReconnectForManualScan()
        // Avoid logging live pairing metadata; the relay URL path includes a bearer-like session id.
        let fullURL = "\(pairingPayload.relay)/\(pairingPayload.sessionId)"
        rememberRelayPairing(pairingPayload)

        do {
            try await connectWithAutoRecovery(
                serverURL: fullURL,
                performAutoRetry: true
            )
        } catch {
            if lastErrorMessage?.isEmpty ?? true {
                lastErrorMessage = userFacingConnectFailureMessage(error)
            }
        }
    }

    // Connects or disconnects the relay.
    func toggleConnection() async {
        if isConnected {
            await disconnect()
            return
        }

        guard !isRunningManualReconnect else {
            return
        }

        // Flips the UI into an immediate busy state before the reconnect handoff reaches the socket layer.
        shouldCancelManualReconnect = false
        isRunningManualReconnect = true
        defer { isRunningManualReconnect = false }

        await stopAutoReconnectForManualRetry()

        guard shouldContinueManualReconnect else {
            connectionRecoveryState = .idle
            return
        }

        guard let fullURL = await preferredReconnectURL() else {
            connectionRecoveryState = .idle
            return
        }

        guard shouldContinueManualReconnect else {
            connectionRecoveryState = .idle
            return
        }
        do {
            try await connectWithAutoRecovery(
                serverURL: fullURL,
                performAutoRetry: true,
                continueWhile: { self.shouldContinueManualReconnect }
            )
        } catch {
            if isCancellationLikeError(error) {
                return
            }
            if lastErrorMessage?.isEmpty ?? true {
                lastErrorMessage = userFacingConnectFailureMessage(error)
            }
        }
    }

    // Lets a manual reconnect tap interrupt a stuck foreground recovery loop.
    func stopAutoReconnectForManualRetry() async {
        guard isRunningAutoReconnect || isConnecting || shouldAutoReconnectOnForeground else {
            return
        }

        shouldAutoReconnectOnForeground = false
        connectionRecoveryState = .retrying(attempt: 0, message: "Preparing reconnect...")
        lastErrorMessage = nil
        cancelTrustedSessionResolve()

        if isConnecting || isConnected {
            await disconnect()
        }

        while isRunningAutoReconnect || isConnecting {
            await sleepForReconnectBackoff(100_000_000)
        }
    }

    // Lets the manual QR flow take over instead of competing with the foreground reconnect loop.
    func stopAutoReconnectForManualScan() async {
        shouldCancelManualReconnect = true
        shouldAutoReconnectOnForeground = false
        connectionRecoveryState = .idle
        lastErrorMessage = nil
        cancelTrustedSessionResolve()

        // Cancel any in-flight reconnect so the scanner can appear immediately instead of waiting
        // for a stalled handshake to time out on its own.
        if isConnecting || isConnected {
            await disconnect()
        }

        while isRunningManualReconnect || isRunningAutoReconnect || isConnecting {
            await sleepForReconnectBackoff(100_000_000)
        }
    }

    /// Injected pairing JSON first (launch args, env, or simulator code path), then saved-session reconnect.
    func performLaunchConnectSequence(e2ePairing: CodexE2EPairingLaunchConfiguration) async {
        guard !hasAttemptedInitialAutoConnect else {
            return
        }
        hasAttemptedInitialAutoConnect = true

        if e2ePairing.isPairingBypassActive, let raw = e2ePairing.resolvedPairingJSON {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                switch validatePairingQRCode(trimmed) {
                case .success(let payload):
                    await connectToRelay(pairingPayload: payload)
                    return
                case .bridgeUpdateRequired(let prompt):
                    bridgeUpdatePrompt = prompt
                    return
                case .scanError:
                    break
                }
            }
        }

        guard !isConnected, !isConnecting else {
            return
        }

        guard let fullURL = await preferredReconnectURL() else {
            return
        }

        do {
            try await connectWithAutoRecovery(
                serverURL: fullURL,
                performAutoRetry: true
            )
        } catch {
            // Keep the saved pairing so temporary Mac/relay outages can recover on the next retry.
        }
    }

    // Attempts one automatic connection on app launch using saved relay session.
    func attemptAutoConnectOnLaunchIfNeeded() async {
        await performLaunchConnectSequence(e2ePairing: .disabled)
    }

    // Reconnects after benign background disconnects.
    func attemptAutoReconnectOnForegroundIfNeeded() async {
        guard shouldAutoReconnectOnForeground, !isRunningAutoReconnect else {
            return
        }

        isRunningAutoReconnect = true
        defer { isRunningAutoReconnect = false }

        var attempt = 0
        // The test-only attempt limit bounds the loop without mutating reconnect intent.
        while shouldAutoReconnectOnForeground {
            if let reconnectAttemptLimitOverride,
               attempt >= reconnectAttemptLimitOverride {
                return
            }

            guard let fullURL = await preferredReconnectURL() else {
                shouldAutoReconnectOnForeground = false
                connectionRecoveryState = .idle
                return
            }

            if isConnected {
                shouldAutoReconnectOnForeground = false
                connectionRecoveryState = .idle
                lastErrorMessage = nil
                return
            }

            if isConnecting {
                if !shouldAutoReconnectOnForeground {
                    connectionRecoveryState = .idle
                    return
                }
                await sleepForReconnectBackoff(
                    300_000_000,
                    continueWhile: { self.shouldAutoReconnectOnForeground }
                )
                continue
            }
            do {
                connectionRecoveryState = .retrying(
                    attempt: max(1, attempt + 1),
                    message: "Reconnecting..."
                )
                try await connectToPreferredTransport(serverURL: fullURL)
                connectionRecoveryState = .idle
                lastErrorMessage = nil
                shouldAutoReconnectOnForeground = false
                return
            } catch {
                if secureConnectionState == .rePairRequired {
                    connectionRecoveryState = .idle
                    shouldAutoReconnectOnForeground = false
                    if lastErrorMessage?.isEmpty ?? true {
                        lastErrorMessage = userFacingConnectFailureMessage(error)
                    }
                    return
                }

                if isCancellationLikeError(error) {
                    connectionRecoveryState = .idle
                    return
                }

                if !shouldAutoReconnectOnForeground {
                    connectionRecoveryState = .idle
                    return
                }

                let isRetryable = isRecoverableTransientConnectionError(error)
                    || isBenignBackgroundDisconnect(error)
                    || isRetryableSavedSessionConnectError(error)

                guard isRetryable else {
                    connectionRecoveryState = .idle
                    shouldAutoReconnectOnForeground = false
                    lastErrorMessage = userFacingConnectFailureMessage(error)
                    return
                }

                lastErrorMessage = nil
                connectionRecoveryState = .retrying(
                    attempt: attempt + 1,
                    message: recoveryStatusMessage(for: error)
                )

                let backoffIndex = min(attempt, autoReconnectBackoffNanoseconds.count - 1)
                let backoff = autoReconnectBackoffNanoseconds[backoffIndex]
                attempt += 1
                await sleepForReconnectBackoff(
                    backoff,
                    continueWhile: { self.shouldAutoReconnectOnForeground }
                )
            }
        }
    }

    private enum ReconnectURLResolution {
        case use(String)
        case fallbackToSaved
        case stop
    }

    func connectToPreferredTransport(serverURL: String) async throws {
        if let connectOverride {
            try await connectOverride(self, serverURL)
            return
        }

        guard let preferredTransportMode = preferredTransportMode(for: serverURL) else {
            throw CodexServiceError.invalidServerURL(serverURL)
        }

        switch preferredTransportMode {
        case .lanRelay:
            try await connect(
                serverURL: serverURL,
                token: "",
                role: "iphone"
            )
        case .convexRemote:
            try await activateConvexLane(serverURL: serverURL)
        case .disconnected:
            throw CodexServiceError.invalidInput("No transport lane is available.")
        }
    }

    func connectWithAutoRecovery(
        serverURL: String,
        performAutoRetry: Bool,
        continueWhile shouldContinue: (() -> Bool)? = nil
    ) async throws {
        guard !isRunningAutoReconnect else {
            return
        }

        isRunningAutoReconnect = true
        defer { isRunningAutoReconnect = false }

        let maxAttemptIndex = performAutoRetry ? autoReconnectBackoffNanoseconds.count : 0
        var lastError: Error?

        for attemptIndex in 0...maxAttemptIndex {
            guard shouldContinue?() ?? true else {
                connectionRecoveryState = .idle
                throw CancellationError()
            }

            if attemptIndex > 0 {
                connectionRecoveryState = .retrying(
                    attempt: attemptIndex,
                    message: "Connection timed out. Retrying..."
                )
            }

            do {
                try await connectToPreferredTransport(serverURL: serverURL)
                connectionRecoveryState = .idle
                lastErrorMessage = nil
                shouldAutoReconnectOnForeground = false
                return
            } catch {
                if isCancellationLikeError(error) {
                    connectionRecoveryState = .idle
                    throw error
                }

                lastError = error
                if secureConnectionState == .rePairRequired {
                    connectionRecoveryState = .idle
                    shouldAutoReconnectOnForeground = false
                    if lastErrorMessage?.isEmpty ?? true {
                        lastErrorMessage = userFacingConnectFailureMessage(error)
                    }
                    throw error
                }

                let isRetryable = isRecoverableTransientConnectionError(error)
                    || isBenignBackgroundDisconnect(error)
                    || isRetryableSavedSessionConnectError(error)

                guard performAutoRetry,
                      isRetryable,
                      attemptIndex < autoReconnectBackoffNanoseconds.count else {
                    connectionRecoveryState = .idle
                    shouldAutoReconnectOnForeground = false
                    lastErrorMessage = userFacingConnectFailureMessage(error)
                    throw error
                }

                lastErrorMessage = nil
                connectionRecoveryState = .retrying(
                    attempt: attemptIndex + 1,
                    message: recoveryStatusMessage(for: error)
                )
                await sleepForReconnectBackoff(
                    autoReconnectBackoffNanoseconds[attemptIndex],
                    continueWhile: shouldContinue
                )
            }
        }

        if let lastError {
            connectionRecoveryState = .idle
            shouldAutoReconnectOnForeground = false
            lastErrorMessage = userFacingConnectFailureMessage(lastError)
            throw lastError
        }
    }

    // Chooses the best reconnect path while treating the saved QR/local relay session
    // as the source of truth if the trusted-Mac record points at a different relay.
    func preferredReconnectURL() async -> String? {
        switch await trustedReconnectResolution() {
        case .use(let resolvedURL):
            return resolvedURL
        case .fallbackToSaved:
            return savedReconnectURL()
        case .stop:
            return nil
        }
    }

    // Resolves a trusted-Mac session when possible and tells the caller whether to use, fall back, or stop.
    private func trustedReconnectResolution() async -> ReconnectURLResolution {
        guard hasTrustedMacReconnectCandidate else {
            return .fallbackToSaved
        }
        guard !shouldPreferSavedRelayReconnect() else {
            return .fallbackToSaved
        }

        do {
            guard let trustedReconnectURL = try await resolvedTrustedReconnectURL() else {
                return .fallbackToSaved
            }
            return .use(trustedReconnectURL)
        } catch let error as CodexTrustedSessionResolveError {
            return trustedReconnectResolution(for: error)
        } catch is CancellationError {
            return .stop
        } catch {
            if !hasSavedRelaySession {
                lastErrorMessage = error.localizedDescription
            }
            return .fallbackToSaved
        }
    }

    // Prevents a stale trusted-Mac record from hijacking a fresher saved local pairing.
    private func shouldPreferSavedRelayReconnect() -> Bool {
        guard hasSavedRelaySession,
              let savedRelayURL = normalizedRelayURL,
              let trustedRelayURL = preferredTrustedMacRecord?
                .relayURL?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !trustedRelayURL.isEmpty else {
            return false
        }

        guard let savedURL = try? validateConnectionURL(savedRelayURL),
              let trustedURL = try? validateConnectionURL(trustedRelayURL) else {
            return savedRelayURL != trustedRelayURL
        }

        return canonicalServerIdentity(for: savedURL) != canonicalServerIdentity(for: trustedURL)
    }

    // Builds the live reconnect URL after the trusted-session lookup succeeds.
    private func resolvedTrustedReconnectURL() async throws -> String? {
        let resolved = try await resolveTrustedMacSession()
        guard let relayURL = normalizedRelayURL else {
            return nil
        }
        return "\(relayURL)/\(resolved.sessionId)"
    }

    // Applies trusted-resolve error policy without mixing it into the happy path URL assembly.
    private func trustedReconnectResolution(
        for error: CodexTrustedSessionResolveError
    ) -> ReconnectURLResolution {
        switch error {
        case .unsupportedRelay:
            if !hasSavedRelaySession {
                connectionRecoveryState = .idle
                lastErrorMessage = "This relay needs a fresh QR scan before trusted reconnect is available."
                return .stop
            }
            return .fallbackToSaved
        case .macOffline(let message):
            if hasSavedRelaySession {
                lastErrorMessage = nil
                return .fallbackToSaved
            }
            connectionRecoveryState = .idle
            lastErrorMessage = message
            return .stop
        case .rePairRequired(let message):
            connectionRecoveryState = .idle
            shouldAutoReconnectOnForeground = false
            lastErrorMessage = message
            return .stop
        case .noTrustedMac:
            return .fallbackToSaved
        case .invalidResponse(let message), .network(let message):
            if !hasSavedRelaySession {
                lastErrorMessage = message
            }
            return .fallbackToSaved
        }
    }

    // Reuses the last QR-resolved session when trusted lookup is unavailable or not yet supported end-to-end.
    private func savedReconnectURL() -> String? {
        guard let sessionId = normalizedRelaySessionId,
              let relayURL = normalizedRelayURL else {
            return nil
        }
        return "\(relayURL)/\(sessionId)"
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
}
