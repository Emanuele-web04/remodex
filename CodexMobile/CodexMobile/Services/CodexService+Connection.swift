// FILE: CodexService+Connection.swift
// Purpose: Connection lifecycle and initialization handshake.
// Layer: Service
// Exports: CodexService connection APIs
// Depends on: Network.NWConnection, UIKit

import Foundation
import Network
import UIKit

extension CodexService {
    // Only close codes that prove the saved pairing/session can no longer be reused
    // should force a QR reset. Temporary delivery loss uses the dedicated `4004`
    // close so `4002` can stay available for "session unavailable right now" cases.
    private static let permanentRelayCloseCodeRawValues: Set<UInt16> = [4000, 4001, 4003]
    private static let explicitRelayDropCloseCodeRawValues: Set<UInt16> = [4004]
    private static let maxTrustedReconnectFailures = 3
    private static let trustedReconnectRecoveryMessage =
        "Secure reconnect could not be restored from the saved session. Try reconnecting again."

    // Models how one socket failure should affect reconnect state, pairing persistence, and UI copy.
    private struct ReceiveErrorDisposition {
        let shouldClearSavedRelaySession: Bool
        let shouldAutoReconnectOnForeground: Bool
        let connectionRecoveryState: CodexConnectionRecoveryState
        let lastErrorMessage: String?
    }

    // Opens the WebSocket and performs initialize/initialized handshake.
    func connect(
        serverURL: String,
        token: String,
        role: String? = nil,
        performInitialSync: Bool = true
    ) async throws {
        guard !isConnecting else {
            lastErrorMessage = "Connection already in progress"
            throw CodexServiceError.invalidInput("Connection already in progress")
        }

        isConnecting = true
        defer { isConnecting = false }

        await prepareForConnectionAttempt(preserveReconnectIntent: true)

        let normalizedServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try validateConnectionURL(normalizedServerURL)
        try await requestLocalNetworkAuthorizationIfNeeded(for: url)
        let serverIdentity = canonicalServerIdentity(for: url)
        if let previousIdentity = connectedServerIdentity, previousIdentity != serverIdentity {
            resetThreadRuntimeStateForServerSwitch()
        }
        connectedServerIdentity = serverIdentity

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let transport: CodexWebSocketTransport
        do {
            transport = try await establishWebSocketConnection(url: url, token: trimmedToken, role: role)
        } catch {
            let friendlyMessage = userFacingConnectError(
                error: error,
                attemptedURL: normalizedServerURL,
                host: url.host
            )
            if isRecoverableTransientConnectionError(error) || isRetryableSavedSessionConnectError(error) {
                connectionRecoveryState = .retrying(attempt: 0, message: recoveryStatusMessage(for: error))
                lastErrorMessage = retryableSessionUnavailableMessage(forConnectError: error)
                throw error
            } else {
                lastErrorMessage = friendlyMessage
            }
            throw CodexServiceError.invalidInput(friendlyMessage)
        }
        switch transport {
        case .network(let connection):
            usesManualWebSocketTransport = false
            webSocketConnection = connection
            startReceiveLoop(with: connection)
        case .manualTCP(let connection):
            usesManualWebSocketTransport = true
            manualWebSocketReadBuffer = Data()
            webSocketConnection = connection
            startManualReceiveLoop(with: connection)
        case .urlSession(let session, let task):
            usesManualWebSocketTransport = false
            webSocketSession = session
            webSocketTask = task
            startReceiveLoop(with: task)
        }
        clearHydrationCaches()
        let isTrustedReconnectAttempt = hasTrustedReconnectContext

        do {
            try await performSecureHandshake()

            isConnected = true
            shouldAutoReconnectOnForeground = false
            connectionRecoveryState = .idle
            lastErrorMessage = nil
            try await initializeSession()
            trustedReconnectFailureCount = 0
            if secureSession != nil {
                secureConnectionState = .encrypted
            }

            startSyncLoop()
            // Push registration is best-effort and talks to the bridge, so it must not
            // hold the main connect path hostage when the managed backend is slow.
            Task { @MainActor [weak self] in
                await self?.syncManagedPushRegistrationIfNeeded(force: true)
            }
            if performInitialSync {
                schedulePostConnectSyncPass()
            }
            Task { @MainActor [weak self] in
                await self?.refreshGPTAccountState()
                self?.startGPTLoginSyncIfNeeded()
            }
        } catch {
            let shouldResetSavedSession = recordTrustedReconnectFailureIfNeeded(
                isTrustedReconnectAttempt: isTrustedReconnectAttempt
            )
            presentConnectionErrorIfNeeded(error)
            await disconnect()
            if shouldResetSavedSession {
                recoverTrustedReconnectCandidate()
            }
            throw error
        }
    }

    // Closes the socket and fails any in-flight requests.
    func disconnect(preserveReconnectIntent: Bool = false) async {
        cancelCurrentSocketConnection()

        isConnected = false
        isInitialized = false
        isLoadingThreads = false
        isLoadingModels = false
        pendingApproval = nil
        finalizeAllStreamingState()
        messagePersistenceDebounceTask?.cancel()
        messagePersistenceDebounceTask = nil
        messagePersistence.save(messagesByThread)
        assistantCompletionFingerprintByThread.removeAll()
        recentActivityLineByThread.removeAll()
        removeAllThreadTimelineState()
        assistantRevertStateCacheByThread.removeAll()
        assistantRevertStateRevision = 0
        supportsServiceTier = true
        hasPresentedServiceTierBridgeUpdatePrompt = false
        supportsThreadFork = true
        hasPresentedThreadForkBridgeUpdatePrompt = false
        hasPresentedMinimumBridgePackageUpdatePrompt = false
        clearAllRunningState()
        readyThreadIDs.removeAll()
        failedThreadIDs.removeAll()
        runningThreadWatchByID.removeAll()
        clearTransientConnectionPrompts()
        endBackgroundRunGraceTask(reason: "disconnect")
        if !preserveReconnectIntent {
            shouldAutoReconnectOnForeground = false
            connectionRecoveryState = .idle
        }
        supportsStructuredSkillInput = true
        supportsTurnCollaborationMode = false
        hasResolvedRateLimitsSnapshot = false
        bridgeInstalledVersion = nil
        latestBridgePackageVersion = nil
        clearConnectionSyncState()
        clearHydrationCaches()
        resumedThreadIDs.removeAll()
        resetSecureTransportState()
        cancelTrustedSessionResolve()

        failAllPendingRequests(with: CodexServiceError.disconnected)
    }

    // Clears the remembered relay pairing when the remote Mac session is gone for good.
    func clearSavedRelaySession() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        relaySessionId = nil
        relayUrl = nil
        relayMacDeviceId = nil
        relayMacIdentityPublicKey = nil
        relayProtocolVersion = codexSecureProtocolVersion
        lastAppliedBridgeOutboundSeq = 0
        shouldForceQRBootstrapOnNextHandshake = false
        trustedReconnectFailureCount = 0
        if let trustedMac = preferredTrustedMacRecord {
            secureConnectionState = .liveSessionUnresolved
            secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        } else {
            secureConnectionState = .notPaired
            secureMacFingerprint = nil
        }
        pendingNotificationOpenThreadID = nil
        lastPushRegistrationSignature = nil
        clearTransientConnectionPrompts()
    }

    func forgetTrustedMac(deviceId: String? = nil) {
        let targetDeviceId = deviceId ?? preferredTrustedMacDeviceId
        guard let targetDeviceId else {
            return
        }

        trustedMacRegistry.records.removeValue(forKey: targetDeviceId)
        SecureStore.writeCodable(trustedMacRegistry, for: CodexSecureKeys.trustedMacRegistry)

        if normalizedLastTrustedMacDeviceId == targetDeviceId {
            SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
            lastTrustedMacDeviceId = nil
        }

        if normalizedRelayMacDeviceId == targetDeviceId {
            clearSavedRelaySession()
        } else {
            resetSecureTransportState()
        }
    }

    // Gives the UI one stable "forget pair" action whether reconnect comes from a trusted record
    // or only from the last saved relay session.
    func forgetReconnectCandidate() {
        if let normalizedRelayMacDeviceId,
           trustedMacRegistry.records[normalizedRelayMacDeviceId] != nil {
            forgetTrustedMac(deviceId: normalizedRelayMacDeviceId)
            return
        }

        if preferredTrustedMacDeviceId != nil {
            forgetTrustedMac()
            return
        }

        clearSavedRelaySession()
    }

    func initializeSession() async throws {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let clientInfo: JSONValue = .object([
            "name": .string("codexmobile_ios"),
            "title": .string("CodexMobile iOS"),
            "version": .string(appVersion),
        ])

        // Ask for experimental APIs up front so plan mode can use `collaborationMode`
        // on runtimes that support it, while keeping a legacy handshake fallback.
        let modernParams: JSONValue = .object([
            "clientInfo": clientInfo,
            "capabilities": .object([
                "experimentalApi": .bool(true),
            ]),
        ])

        do {
            _ = try await sendRequest(method: "initialize", params: modernParams)
            supportsTurnCollaborationMode = await runtimeSupportsPlanCollaborationMode()
        } catch {
            guard shouldRetryInitializeWithoutCapabilities(error) else {
                throw error
            }

            let legacyParams: JSONValue = .object([
                "clientInfo": clientInfo,
            ])
            _ = try await sendRequest(method: "initialize", params: legacyParams)
            supportsTurnCollaborationMode = false
        }

        try await sendNotification(method: "initialized", params: nil)
        isInitialized = true
    }

    // Classifies socket failures so transient relay hiccups reconnect, while dead pairings are forgotten.
    func handleReceiveError(
        _ error: Error,
        relayCloseCode: NWProtocolWebSocket.CloseCode? = nil
    ) {
        if Task.isCancelled {
            return
        }

        cancelCurrentSocketConnection()

        let disposition = receiveErrorDisposition(for: error, relayCloseCode: relayCloseCode)
        let wasTrustedReconnectAttempt = secureConnectionState == .reconnecting
        isConnected = false
        isInitialized = false
        shouldAutoReconnectOnForeground = disposition.shouldAutoReconnectOnForeground
        if disposition.shouldClearSavedRelaySession {
            clearSavedRelaySession()
        } else {
            // Reset volatile secure state so reconnect UI does not keep showing the last encrypted session.
            resetSecureTransportState()
        }
        if wasTrustedReconnectAttempt && !disposition.shouldClearSavedRelaySession {
            if recordTrustedReconnectFailureIfNeeded(isTrustedReconnectAttempt: true) {
                shouldAutoReconnectOnForeground = false
                connectionRecoveryState = .idle
                recoverTrustedReconnectCandidate()
                failAllPendingRequests(with: error)
                return
            }
        } else if disposition.shouldClearSavedRelaySession || !shouldAutoReconnectOnForeground {
            trustedReconnectFailureCount = 0
        }
        connectionRecoveryState = disposition.connectionRecoveryState
        lastErrorMessage = disposition.lastErrorMessage
        finalizeAllStreamingState()
        endBackgroundRunGraceTask(reason: "receive-error")
        clearConnectionSyncState()
        // Thread resumes are transport-scoped; a fresh socket must be allowed to
        // issue `thread/resume` again for desktop-origin threads after recovery.
        resumedThreadIDs.removeAll()
        failAllPendingRequests(with: error)
    }
}

extension CodexService {
    func schedulePostConnectSyncPass(preferredThreadId: String? = nil) {
        postConnectSyncTask?.cancel()
        isBootstrappingConnectionSync = true

        let syncToken = UUID()
        postConnectSyncToken = syncToken
        let preferredThreadId = preferredThreadId
        postConnectSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.postConnectSyncToken == syncToken {
                    self.isBootstrappingConnectionSync = false
                    self.postConnectSyncTask = nil
                    self.postConnectSyncToken = nil
                }
            }
            await self.performPostConnectSyncPass(preferredThreadId: preferredThreadId)
        }
    }

    // Runs the post-connect sync work that is useful but not required to mark the socket usable.
    func performPostConnectSyncPass(preferredThreadId: String? = nil) async {
        try? await listModels()
        try? await listThreads()
        if await routePendingNotificationOpenIfPossible(refreshIfNeeded: false) {
            return
        }
        let resolvedPreferredThreadId = normalizedInterruptIdentifier(preferredThreadId)
        if let resolvedPreferredThreadId {
            activeThreadId = resolvedPreferredThreadId
        }
        if let threadId = activeThreadId
            ?? resolvedPreferredThreadId
            ?? firstLiveThreadID() {
            await refreshInFlightTurnState(threadId: threadId)
            if threadHasActiveOrRunningTurn(threadId) {
                _ = try? await ensureThreadResumed(threadId: threadId, force: true)
                if activeThreadId == threadId {
                    currentOutput = messages(for: threadId)
                        .reversed()
                        .first(where: { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                        .text ?? ""
                }
            }
        }
    }

    // Clears volatile runtime state on server switch.
    func resetThreadRuntimeStateForServerSwitch() {
        activeThreadId = nil
        activeTurnId = nil
        activeTurnIdByThread.removeAll()
        refreshAllThreadTimelineStates()
        threadIdByTurnID.removeAll()
        pendingApproval = nil
        currentOutput = ""
        lastErrorMessage = nil
        isLoadingModels = false
        modelsErrorMessage = nil
        assistantCompletionFingerprintByThread.removeAll()
        recentActivityLineByThread.removeAll()
        removeAllThreadTimelineState()
        assistantRevertStateCacheByThread.removeAll()
        assistantRevertStateRevision = 0
        supportsServiceTier = true
        hasPresentedServiceTierBridgeUpdatePrompt = false
        supportsThreadFork = true
        hasPresentedThreadForkBridgeUpdatePrompt = false
        hasPresentedMinimumBridgePackageUpdatePrompt = false
        clearAllRunningState()
        readyThreadIDs.removeAll()
        failedThreadIDs.removeAll()
        runningThreadWatchByID.removeAll()
        pendingNotificationOpenThreadID = nil
        clearTransientConnectionPrompts()
        endBackgroundRunGraceTask(reason: "server-switch")
        shouldAutoReconnectOnForeground = false
        connectionRecoveryState = .idle
        supportsStructuredSkillInput = true
        supportsTurnCollaborationMode = false
        bridgeInstalledVersion = nil
        latestBridgePackageVersion = nil
        resumedThreadIDs.removeAll()
        clearHydrationCaches()
        resetSecureTransportState()
    }

    // Clears UI-only recovery prompts that should not survive a relay/context teardown.
    func clearTransientConnectionPrompts() {
        bridgeUpdatePrompt = nil
        threadCompletionBanner = nil
        missingNotificationThreadPrompt = nil
    }

    // Removes the current socket reference before reconnect/teardown logic mutates shared state.
    private func cancelCurrentSocketConnection() {
        if let connection = webSocketConnection {
            connection.stateUpdateHandler = nil
            webSocketConnection = nil
            connection.cancel()
        }

        if let task = webSocketTask {
            webSocketTask = nil
            task.cancel(with: .goingAway, reason: nil)
        }

        if let session = webSocketSession {
            webSocketSession = nil
            session.invalidateAndCancel()
        }

        webSocketSessionDelegate = nil
        manualWebSocketReadBuffer = Data()
        usesManualWebSocketTransport = false
    }

    // Drops sync work tied to the old transport so reconnect starts from a clean baseline.
    private func clearConnectionSyncState() {
        isBootstrappingConnectionSync = false
        stopSyncLoop()
        postConnectSyncTask?.cancel()
        postConnectSyncTask = nil
        postConnectSyncToken = nil
    }

    // Avoids wiping thread/runtime state when reconnecting after a socket that already died.
    func prepareForConnectionAttempt(preserveReconnectIntent: Bool = true) async {
        let needsTransportReset = webSocketConnection != nil
            || webSocketTask != nil
            || isConnected
            || isInitialized
            || !pendingRequests.isEmpty

        guard needsTransportReset else {
            // A dead socket can still leave secure-handshake buffers behind; clear only transport-volatiles here.
            resetSecureTransportState(preservePendingQRBootstrapState: shouldForceQRBootstrapOnNextHandshake)
            return
        }

        await disconnect(preserveReconnectIntent: preserveReconnectIntent)
    }

    // Identifies reconnects that should reuse a previously trusted Mac instead of going through QR bootstrap.
    var hasTrustedReconnectContext: Bool {
        guard hasSavedRelaySession,
              !shouldForceQRBootstrapOnNextHandshake,
              let relayMacDeviceId = normalizedRelayMacDeviceId else {
            return false
        }

        return trustedMacRegistry.records[relayMacDeviceId] != nil
    }

    // Counts reconnect handshake failures so repeated stale-session wakeups can fall back to
    // trusted-session resolution instead of forcing an unnecessary fresh QR scan.
    @discardableResult
    func recordTrustedReconnectFailureIfNeeded(isTrustedReconnectAttempt: Bool) -> Bool {
        guard isTrustedReconnectAttempt else {
            trustedReconnectFailureCount = 0
            return false
        }

        trustedReconnectFailureCount += 1
        guard trustedReconnectFailureCount >= Self.maxTrustedReconnectFailures else {
            return false
        }

        shouldAutoReconnectOnForeground = false
        connectionRecoveryState = .idle
        return true
    }

    // Drops only the stale saved relay session after repeated secure reconnect failures.
    // This preserves the trusted Mac record, but stops looping on a dead session id forever.
    func recoverTrustedReconnectCandidate() {
        if hasSavedRelaySession {
            clearSavedRelaySession()
        } else {
            secureConnectionState = .liveSessionUnresolved
        }
        lastErrorMessage = Self.trustedReconnectRecoveryMessage
    }

    // Centralizes the "should we retry, stay silent, or force a re-pair?" rules for socket failures.
    private func receiveErrorDisposition(
        for error: Error,
        relayCloseCode: NWProtocolWebSocket.CloseCode?
    ) -> ReceiveErrorDisposition {
        let shouldClearSavedRelaySession = shouldClearSavedRelaySession(for: relayCloseCode)
        let retryableSessionUnavailableMessage = retryableSessionUnavailableMessage(for: relayCloseCode)
        // Only relay closes that preserve the saved session should stay on the
        // auto-reconnect path; dead sessions must fall back to QR recovery.
        let permanentRelayMessage = shouldClearSavedRelaySession
            ? (permanentRelayDisconnectMessage(for: relayCloseCode)
                ?? "This relay pairing is no longer valid. Scan a new QR code to reconnect.")
            : nil
        let explicitRelayDropMessage = explicitRelayDropMessage(for: relayCloseCode)
        let isBenignDisconnect = isBenignBackgroundDisconnect(error)
        let shouldSuppressMessage = isBenignDisconnect && !isActivelyForegroundedForConnectionUI()
        // Foreground relay drops should reconnect too, otherwise Stop disappears mid-run.
        let shouldAttemptAutoRecovery = !shouldClearSavedRelaySession
            && explicitRelayDropMessage == nil
            && (retryableSessionUnavailableMessage != nil
                || isRecoverableTransientConnectionError(error)
                || isBenignDisconnect)

        let connectionRecoveryState: CodexConnectionRecoveryState = shouldAttemptAutoRecovery
            ? .retrying(attempt: 0, message: recoveryStatusMessage(for: error))
            : .idle

        let lastErrorMessage: String?
        if let permanentRelayMessage {
            lastErrorMessage = permanentRelayMessage
        } else if let retryableSessionUnavailableMessage, !shouldSuppressMessage {
            lastErrorMessage = retryableSessionUnavailableMessage
        } else if let explicitRelayDropMessage {
            lastErrorMessage = explicitRelayDropMessage
        } else if !shouldSuppressMessage && !shouldAttemptAutoRecovery {
            lastErrorMessage = userFacingConnectFailureMessage(error)
        } else {
            lastErrorMessage = nil
        }

        return ReceiveErrorDisposition(
            shouldClearSavedRelaySession: shouldClearSavedRelaySession,
            shouldAutoReconnectOnForeground: !shouldClearSavedRelaySession
                && (shouldSuppressMessage || shouldAttemptAutoRecovery || explicitRelayDropMessage != nil),
            connectionRecoveryState: connectionRecoveryState,
            lastErrorMessage: lastErrorMessage
        )
    }

    // Detects runtimes that still reject `initialize.capabilities`.
    func shouldRetryInitializeWithoutCapabilities(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code != -32600 && rpcError.code != -32602 {
            return false
        }

        let message = rpcError.message.lowercased()
        guard message.contains("capabilities") || message.contains("experimentalapi") else {
            return false
        }

        return message.contains("unknown")
            || message.contains("unexpected")
            || message.contains("unrecognized")
            || message.contains("invalid")
            || message.contains("unsupported")
            || message.contains("field")
    }

    // Uses the documented experimental listing endpoint instead of assuming initialize implies plan support.
    func runtimeSupportsPlanCollaborationMode() async -> Bool {
        do {
            let response = try await sendRequest(method: "collaborationMode/list", params: nil)
            return responseContainsPlanCollaborationMode(response)
        } catch {
            return false
        }
    }

    // Accepts the current app-server result shapes without depending on one exact field name.
    func responseContainsPlanCollaborationMode(_ response: RPCMessage) -> Bool {
        let candidateArrays: [[JSONValue]?] = [
            response.result?.arrayValue,
            response.result?.objectValue?["modes"]?.arrayValue,
            response.result?.objectValue?["collaborationModes"]?.arrayValue,
            response.result?.objectValue?["items"]?.arrayValue,
        ]

        for candidateArray in candidateArrays {
            guard let candidateArray else { continue }
            for entry in candidateArray {
                let modeName = entry.objectValue?["mode"]?.stringValue
                    ?? entry.objectValue?["name"]?.stringValue
                    ?? entry.objectValue?["id"]?.stringValue
                    ?? entry.stringValue
                if modeName == CodexCollaborationModeKind.plan.rawValue {
                    return true
                }
            }
        }

        return false
    }

    func canonicalServerIdentity(for url: URL) -> String {
        let scheme = (url.scheme ?? "ws").lowercased()
        let host = (url.host ?? "unknown-host").lowercased()
        let defaultPort = (scheme == "wss") ? 443 : 80
        let port = url.port ?? defaultPort
        let path = url.path.isEmpty ? "/" : url.path
        return "\(scheme)://\(host):\(port)\(path)"
    }

    func validateConnectionURL(_ serverURL: String) throws -> URL {
        guard let url = URL(string: serverURL) else {
            let message = CodexServiceError.invalidServerURL(serverURL).localizedDescription
            lastErrorMessage = message
            throw CodexServiceError.invalidServerURL(serverURL)
        }

        return url
    }

    func userFacingConnectError(error: Error, attemptedURL: String, host: String?) -> String {
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code) where code == .ECONNREFUSED:
                return "Connection refused by relay server at \(attemptedURL)."
            case .posix(let code) where code == .EMSGSIZE:
                return oversizedRelayPayloadMessage
            case .posix(let code) where code == .ENETDOWN || code == .ENETUNREACH || code == .EHOSTUNREACH:
                return "Cannot reach relay server at \(attemptedURL). Check that the iPhone can access the Mac on the local network."
            case .posix(let code) where code == .ETIMEDOUT:
                return "Connection timed out. Check server/network."
            case .dns(let code):
                return "Cannot resolve server host (\(code)). Check the relay URL."
            default:
                break
            }
        }

        if isRecoverableTransientConnectionError(error) {
            return "Connection timed out. Check server/network."
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorNotConnectedToInternet,
           requiresLocalNetworkAuthorization(for: URL(string: attemptedURL) ?? URL(fileURLWithPath: "/")) {
            return "Remodex cannot open the local relay connection on this iPhone. Check Local Network and the app's Wi-Fi/Cellular access in Settings, then retry."
        }

        return error.localizedDescription
    }

    // Treats common local relay socket teardowns as transient so foreground return can recover quietly.
    func isBenignBackgroundDisconnect(_ error: Error) -> Bool {
        if let serviceError = error as? CodexServiceError {
            if case .disconnected = serviceError {
                return true
            }
        }

        guard let nwError = error as? NWError else {
            return false
        }

        if case .posix(let code) = nwError,
           code == .ECONNABORTED
            || code == .ECANCELED
            || code == .ENOTCONN
            || code == .ENODATA
            || code == .ECONNRESET {
            return true
        }

        return false
    }

    // Treats write-side socket loss the same as receive-side disconnects so UI can recover instead of hanging.
    func shouldTreatSendFailureAsDisconnect(_ error: Error) -> Bool {
        if isBenignBackgroundDisconnect(error) || isRecoverableTransientConnectionError(error) {
            return true
        }

        guard let nwError = error as? NWError,
              case .posix(let code) = nwError else {
            return false
        }

        return code == .EPIPE || code == .ECONNRESET
    }

    func isRecoverableTransientConnectionError(_ error: Error) -> Bool {
        if let serviceError = error as? CodexServiceError {
            if case .invalidInput(let message) = serviceError {
                return message.localizedCaseInsensitiveContains("timed out")
            }
        }

        if let nwError = error as? NWError {
            if case .posix(let code) = nwError,
               code == .ETIMEDOUT {
                return true
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(POSIXErrorCode.ETIMEDOUT.rawValue)
    }

    // Detects connect-time relay closes that still leave the saved session reusable moments later.
    func isRetryableSavedSessionConnectError(_ error: Error) -> Bool {
        relayCloseCodeRawValue(fromConnectError: error) == 4002
    }

    // Keeps auto-recovery reconnects visually quiet, even if stale in-flight sync calls fail after the socket drops.
    func shouldSuppressRecoverableConnectionError(_ error: Error) -> Bool {
        let isRecovering: Bool
        switch connectionRecoveryState {
        case .retrying:
            isRecovering = true
        case .idle:
            isRecovering = false
        }

        guard shouldAutoReconnectOnForeground || isRecovering else {
            return false
        }

        return isBenignBackgroundDisconnect(error) || isRecoverableTransientConnectionError(error)
    }

    // Suppresses only background disconnect noise; foreground timeouts should still tell the user why sync stopped.
    func shouldSuppressUserFacingConnectionError(_ error: Error) -> Bool {
        shouldSuppressRecoverableConnectionError(error)
            || (isBenignBackgroundDisconnect(error) && !isActivelyForegroundedForConnectionUI())
    }

    // Surfaces only meaningful connection failures to the UI and keeps reconnect noise silent.
    func presentConnectionErrorIfNeeded(_ error: Error, fallbackMessage: String? = nil) {
        guard !shouldSuppressUserFacingConnectionError(error) else {
            return
        }

        let message = (fallbackMessage ?? userFacingConnectFailureMessage(error))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return
        }

        // Preserve a more specific relay-session message instead of replacing it with a generic disconnect.
        if message == CodexServiceError.disconnected.localizedDescription,
           let lastErrorMessage,
           !lastErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        lastErrorMessage = message
    }

    func recoveryStatusMessage(for error: Error) -> String {
        if isRetryableSavedSessionConnectError(error) {
            return "Reconnecting..."
        }
        if isRecoverableTransientConnectionError(error) {
            return "Connection timed out. Retrying..."
        }
        return "Reconnecting..."
    }

    func userFacingConnectFailureMessage(_ error: Error) -> String {
        if let retryableSessionUnavailableMessage = retryableSessionUnavailableMessage(forConnectError: error) {
            return retryableSessionUnavailableMessage
        }
        if isOversizedRelayPayloadError(error) {
            return oversizedRelayPayloadMessage
        }
        if isBenignBackgroundDisconnect(error) {
            return "Connection was interrupted. Tap Reconnect to try again."
        }
        if isRecoverableTransientConnectionError(error) {
            return "Connection timed out. Check server/network."
        }
        return error.localizedDescription
    }

    // Distinguishes relay frame-size failures from generic disconnects so reconnect UI can explain them.
    func isOversizedRelayPayloadError(_ error: Error) -> Bool {
        if let nwError = error as? NWError,
           case .posix(let code) = nwError,
           code == .EMSGSIZE {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(POSIXErrorCode.EMSGSIZE.rawValue)
    }

    var oversizedRelayPayloadMessage: String {
        "A thread payload was too large for the relay connection. This can happen while reopening image-heavy chats even if you didn't press Send."
    }

    // Treats `.inactive` app switches like background for user-facing reconnect noise.
    private func isActivelyForegroundedForConnectionUI() -> Bool {
        isAppInForeground && applicationStateProvider() == .active
    }

    // Pulls a stable raw close code out of NWProtocolWebSocket so we can classify relay shutdowns.
    func relayCloseCodeRawValue(_ closeCode: NWProtocolWebSocket.CloseCode?) -> UInt16? {
        switch closeCode {
        case .protocolCode(let definedCode):
            return definedCode.rawValue
        case .applicationCode(let rawValue), .privateCode(let rawValue):
            return rawValue
        case nil:
            return nil
        @unknown default:
            return nil
        }
    }

    // Extracts relay close codes from connect-time URLSession delegate errors.
    func relayCloseCodeRawValue(fromConnectError error: Error) -> UInt16? {
        guard let serviceError = error as? CodexServiceError,
              case .invalidInput(let message) = serviceError else {
            return nil
        }

        let prefix = "WebSocket closed during connect ("
        guard let prefixRange = message.range(of: prefix) else {
            return nil
        }

        let suffix = message[prefixRange.upperBound...]
        guard let closingParenIndex = suffix.firstIndex(of: ")") else {
            return nil
        }

        return UInt16(suffix[..<closingParenIndex])
    }

    // Distinguishes "temporary socket blip" from "that QR pairing is no longer valid".
    func permanentRelayDisconnectMessage(for closeCode: NWProtocolWebSocket.CloseCode?) -> String? {
        guard let rawValue = relayCloseCodeRawValue(closeCode),
              Self.permanentRelayCloseCodeRawValues.contains(rawValue) else {
            return nil
        }

        switch rawValue {
        case 4001:
            return "This relay session was replaced by another Mac connection. Scan a new QR code to reconnect."
        case 4003:
            return "This device was replaced by a newer connection. Scan a new QR code to reconnect."
        default:
            return "This relay pairing is no longer valid. Scan a new QR code to reconnect."
        }
    }

    // Treats `4002` as ambiguous while the Mac bridge may still be recreating the same relay session.
    func retryableSessionUnavailableMessage(for closeCode: NWProtocolWebSocket.CloseCode?) -> String? {
        guard relayCloseCodeRawValue(closeCode) == 4002 else {
            return nil
        }

        return "The saved Mac session is temporarily unavailable. Remodex will keep retrying. If you restarted the bridge on your Mac, scan the new QR code."
    }

    func retryableSessionUnavailableMessage(forConnectError error: Error) -> String? {
        guard isRetryableSavedSessionConnectError(error) else {
            return nil
        }

        return "The saved Mac session is temporarily unavailable. Remodex will keep retrying. If you restarted the bridge on your Mac, scan the new QR code."
    }

    // Surfaces relay-enforced drops that keep the pairing valid but lost the current send.
    func explicitRelayDropMessage(for closeCode: NWProtocolWebSocket.CloseCode?) -> String? {
        guard let rawValue = relayCloseCodeRawValue(closeCode),
              Self.explicitRelayDropCloseCodeRawValues.contains(rawValue) else {
            return nil
        }

        return "The Mac was temporarily unavailable and this message could not be delivered. Wait a moment, then try again."
    }

    func shouldClearSavedRelaySession(for closeCode: NWProtocolWebSocket.CloseCode?) -> Bool {
        guard let rawValue = relayCloseCodeRawValue(closeCode) else {
            return false
        }

        return Self.permanentRelayCloseCodeRawValues.contains(rawValue)
    }

    var isRunningOnSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        if host == "localhost" || host == "::1" {
            return true
        }
        return host == "127.0.0.1" || host.hasPrefix("127.")
    }

    // Triggers iOS local-network privacy before dialing LAN relay hosts so pairing
    // does not fail with an opaque socket wait when the permission prompt was never shown.
    func requestLocalNetworkAuthorizationIfNeeded(for url: URL) async throws {
        guard requiresLocalNetworkAuthorization(for: url),
              localNetworkAuthorizationStatus != .granted else {
            return
        }

        let requester = LocalNetworkAuthorizationRequester()
        let status = await requester.request()
        localNetworkAuthorizationStatus = status

        guard status != .denied else {
            let message =
                "Remodex is not allowed to access your local network. Enable Local Network for Remodex in iPhone Settings and try again."
            lastErrorMessage = message
            throw CodexServiceError.invalidInput(message)
        }
    }

    func requiresLocalNetworkAuthorization(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }

        return host.hasSuffix(".local")
            || isPrivateIPv4Host(host)
            || isLocalIPv6Host(host)
    }

    // Chooses the most direct relay transport for LAN-style hosts plus private overlays like Tailscale.
    // Tailscale's 100.64.0.0/10 range should bypass the WebSocket URL path that iOS may proxy.
    func prefersDirectRelayTransport(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }

        return host.hasSuffix(".local")
            || isPrivateIPv4Host(host)
            || isCarrierGradePrivateIPv4Host(host)
            || isTailscaleMagicDNSHost(host)
            || isLocalIPv6Host(host)
    }

    private func isPrivateIPv4Host(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }

        switch (octets[0], octets[1]) {
        case (10, _):
            return true
        case (172, 16...31):
            return true
        case (192, 168):
            return true
        case (169, 254):
            return true
        default:
            return false
        }
    }

    // Covers CGNAT/private-overlay ranges like Tailscale's default 100.x addresses.
    private func isCarrierGradePrivateIPv4Host(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }

        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    // Covers Tailscale hostnames that still resolve to the local/private overlay even without a raw 100.x QR URL.
    private func isTailscaleMagicDNSHost(_ host: String) -> Bool {
        host.hasSuffix(".ts.net") || host.hasSuffix(".beta.tailscale.net")
    }

    private func isLocalIPv6Host(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized.hasPrefix("fe80:")
            || normalized.hasPrefix("fc")
            || normalized.hasPrefix("fd")
    }
}
