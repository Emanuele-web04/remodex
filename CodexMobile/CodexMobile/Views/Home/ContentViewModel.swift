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
    private(set) var isRunningAutoReconnect = false

    var isAttemptingAutoReconnect: Bool {
        isRunningAutoReconnect
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
        let fullURL = "\(pairingPayload.relay)/\(pairingPayload.sessionId)"
        print("[PAIRING] QR scanned — relay=\(pairingPayload.relay) session=\(pairingPayload.sessionId)")
        print("[PAIRING] full URL=\(fullURL)")
        codex.rememberRelayPairing(pairingPayload)

        do {
            print("[PAIRING] starting connectWithAutoRecovery")
            try await connectWithAutoRecovery(
                codex: codex,
                serverURL: fullURL,
                performAutoRetry: true
            )
            print("[PAIRING] connected OK")
        } catch {
            print("[PAIRING] connect failed: \(error)")
            if codex.lastErrorMessage?.isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
            }
        }
    }

    // Connects or disconnects the relay.
    func toggleConnection(codex: CodexService) async {
        guard !codex.isConnecting, !isRunningAutoReconnect else {
            return
        }

        if codex.isConnected {
            await codex.disconnect()
            codex.clearSavedRelaySession()
            return
        }

        guard let fullURL = await preferredReconnectURL(codex: codex) else {
            return
        }
        do {
            try await connectWithAutoRecovery(
                codex: codex,
                serverURL: fullURL,
                performAutoRetry: true
            )
        } catch {
            if codex.lastErrorMessage?.isEmpty ?? true {
                codex.lastErrorMessage = codex.userFacingConnectFailureMessage(error)
            }
        }
    }

    // Lets the manual QR flow take over instead of competing with the foreground reconnect loop.
    func stopAutoReconnectForManualScan(codex: CodexService) async {
        codex.shouldAutoReconnectOnForeground = false
        codex.connectionRecoveryState = .idle
        codex.lastErrorMessage = nil

        // Cancel any in-flight reconnect so the scanner can appear immediately instead of waiting
        // for a stalled handshake to time out on its own.
        if codex.isConnecting || codex.isConnected {
            await codex.disconnect()
        }

        while isRunningAutoReconnect || codex.isConnecting {
            try? await Task.sleep(nanoseconds: 100_000_000)
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

        guard let fullURL = await preferredReconnectURL(codex: codex) else {
            return
        }

        do {
            try await connectWithAutoRecovery(
                codex: codex,
                serverURL: fullURL,
                performAutoRetry: true
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
        let maxAttempts = 20

        // Keep trying while the relay pairing is still valid.
        // This lets network changes recover on their own instead of dropping back to a manual reconnect button.
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
                try? await Task.sleep(nanoseconds: 300_000_000)
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
                try? await Task.sleep(nanoseconds: backoff)
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
        try await codex.connect(
            serverURL: serverURL,
            token: "",
            role: "iphone"
        )
    }

    func connectWithAutoRecovery(
        codex: CodexService,
        serverURL: String,
        performAutoRetry: Bool
    ) async throws {
        guard !isRunningAutoReconnect else {
            return
        }

        isRunningAutoReconnect = true
        defer { isRunningAutoReconnect = false }

        let maxAttemptIndex = performAutoRetry ? autoReconnectBackoffNanoseconds.count : 0
        var lastError: Error?

        for attemptIndex in 0...maxAttemptIndex {
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
                try? await Task.sleep(nanoseconds: autoReconnectBackoffNanoseconds[attemptIndex])
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
                codex.connectionRecoveryState = .idle
                codex.lastErrorMessage = "This relay needs a fresh QR scan before trusted reconnect is available."
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
}
