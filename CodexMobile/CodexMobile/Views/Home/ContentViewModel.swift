// FILE: ContentViewModel.swift
// Purpose: Owns non-visual orchestration logic for the root screen (connection, relay pairing, sync throttling).
// Layer: ViewModel
// Exports: ContentViewModel
// Depends on: Foundation, Observation, CodexService, SecureStore

import Foundation
import Observation

@MainActor
@Observable
final class ContentViewModel {
    private var hasAttemptedInitialAutoConnect = false
    private var lastSidebarOpenSyncAt: Date = .distantPast
    private let autoReconnectBackoffNanoseconds: [UInt64] = [1_000_000_000, 3_000_000_000]
    private let reconnectSleepChunkNanoseconds: UInt64 = 100_000_000
    private(set) var isRunningAutoReconnect = false
    private(set) var isRunningManualReconnect = false
    private var shouldCancelManualReconnect = false
    // Test hooks keep reconnect verification fast without changing production retry behavior.
    @ObservationIgnored var reconnectAttemptLimitOverride: Int?
    @ObservationIgnored var connectOverride: ((CodexService, String) async throws -> Void)?
    @ObservationIgnored var reconnectSleepOverride: ((UInt64) async -> Void)?
    @ObservationIgnored var reconnectSleepChunkNanosecondsOverride: UInt64?

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

        do {
            try await connectWithAutoRecovery(
                codex: codex,
                performAutoRetry: true,
                serverURLProvider: { await self.preferredReconnectURL(codex: codex) }
            )
        } catch {
            // Keep the saved pairing so temporary Mac/relay outages can recover on the next retry.
        }
    }

    // Reconnects after benign background disconnects.
    func attemptAutoReconnectOnForegroundIfNeeded(codex: CodexService) async {
        guard codex.shouldAutoReconnectOnForeground, !isRunningAutoReconnect else {
            return
        }

        isRunningAutoReconnect = true
        defer { isRunningAutoReconnect = false }

        var attempt = 0

        let maxAttempts = reconnectAttemptLimitOverride ?? 50

        // Keep retryable reconnects alive until the socket recovers or the pairing becomes invalid.
        while codex.shouldAutoReconnectOnForeground, attempt < maxAttempts {

            guard let fullURL = await preferredReconnectURL(codex: codex) else {
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

extension ContentViewModel {
    private enum ReconnectURLResolution {
        case use(String)
        case fallbackToSaved
        case stop
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
        switch await trustedReconnectResolution(codex: codex) {
        case .use(let resolvedURL):
            return resolvedURL
        case .fallbackToSaved:
            return savedReconnectURL(codex: codex)
        case .stop:
            return nil
        }
    }

    // Resolves a trusted-Mac session when possible and tells the caller whether to use, fall back, or stop.
    private func trustedReconnectResolution(codex: CodexService) async -> ReconnectURLResolution {
        guard codex.hasTrustedMacReconnectCandidate else {
            return .fallbackToSaved
        }

        do {
            guard let trustedReconnectURL = try await resolvedTrustedReconnectURL(codex: codex) else {
                return .fallbackToSaved
            }
            return .use(trustedReconnectURL)
        } catch let error as CodexTrustedSessionResolveError {
            return trustedReconnectResolution(for: error, codex: codex)
        } catch is CancellationError {
            return .stop
        } catch {
            if !codex.hasSavedRelaySession {
                codex.lastErrorMessage = error.localizedDescription
            }
            return .fallbackToSaved
        }
    }

    // Builds the live reconnect URL after the trusted-session lookup succeeds.
    private func resolvedTrustedReconnectURL(codex: CodexService) async throws -> String? {
        let resolved = try await codex.resolveTrustedMacSession()
        guard let relayURL = codex.normalizedRelayURL else {
            return nil
        }
        return "\(relayURL)/\(resolved.sessionId)"
    }

    // Applies trusted-resolve error policy without mixing it into the happy path URL assembly.
    private func trustedReconnectResolution(
        for error: CodexTrustedSessionResolveError,
        codex: CodexService
    ) -> ReconnectURLResolution {
        switch error {
        case .unsupportedRelay:
            if !codex.hasSavedRelaySession {
                codex.secureConnectionState = .liveSessionUnresolved
                codex.connectionRecoveryState = .idle
                codex.shouldAutoReconnectOnForeground = false
                codex.lastErrorMessage = "Trusted reconnect is unavailable from this relay endpoint. Update or check the relay/proxy, then reconnect. Scan a new QR code only if this Mac was reset."
                return .stop
            }
            return .fallbackToSaved
        case .macOffline(let message):
            if codex.hasSavedRelaySession {
                codex.lastErrorMessage = nil
                return .fallbackToSaved
            }
            codex.connectionRecoveryState = .idle
            codex.lastErrorMessage = message
            return .stop
        case .rePairRequired(let message):
            codex.connectionRecoveryState = .idle
            codex.shouldAutoReconnectOnForeground = false
            codex.lastErrorMessage = message
            return .stop
        case .noTrustedMac:
            return .fallbackToSaved
        case .invalidResponse(let message), .network(let message):
            if !codex.hasSavedRelaySession {
                codex.secureConnectionState = .liveSessionUnresolved
                codex.lastErrorMessage = message
            }
            return .fallbackToSaved
        }
    }

    // Reuses the last QR-resolved session when trusted lookup is unavailable or not yet supported end-to-end.
    private func savedReconnectURL(codex: CodexService) -> String? {
        guard let sessionId = codex.normalizedRelaySessionId,
              let relayURL = codex.normalizedRelayURL else {
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
