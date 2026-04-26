// FILE: CodexService+Account.swift
// Purpose: Owns ChatGPT account state, browser-login lifecycle, and sanitized bridge refreshes.
// Layer: Service
// Exports: CodexGPTAccountSnapshot, CodexGPTLoginState, CodexService GPT account helpers
// Depends on: Foundation, RPCMessage, JSONValue

import Foundation

private let minimumBridgePackageUpdateCommand = "npm install -g remodex@latest"
private let forcedBridgeUpgradeFromVersion = "1.3.7"
private let forcedBridgeUpgradeTargetVersion = "1.3.8"
private let forcedBridgeUpgradeCommand = "npm install -g remodex@1.3.8"

enum CodexGPTAccountStatus: String, Codable, Sendable {
    case unknown
    case unavailable
    case notLoggedIn
    case loginPending
    case authenticated
    case expired
}

enum CodexGPTAuthMethod: String, Codable, Sendable {
    case chatgpt
}

struct CodexGPTAccountSnapshot: Codable, Equatable, Sendable {
    var status: CodexGPTAccountStatus
    var authMethod: CodexGPTAuthMethod?
    var email: String?
    var displayName: String?
    var planType: String?
    var hostPlatform: CodexBridgeHostPlatform?
    var hostCapabilities: CodexBridgeHostCapabilities?
    var loginInFlight: Bool
    var needsReauth: Bool
    var expiresAt: Date?
    var tokenReady: Bool? = nil
    var tokenUnavailableSince: Date? = nil
    var updatedAt: Date

    var hasActiveLogin: Bool {
        loginInFlight || status == .loginPending
    }

    var isAuthenticated: Bool {
        status == .authenticated && !needsReauth
    }

    var canLogout: Bool {
        isAuthenticated || needsReauth
    }

    var isVoiceTokenReady: Bool {
        tokenReady ?? isAuthenticated
    }

    var statusLabel: String {
        switch status {
        case .unknown:
            return "Unknown"
        case .unavailable:
            return "Unavailable"
        case .notLoggedIn:
            return "Not logged in"
        case .loginPending:
            return "Login pending"
        case .authenticated:
            return needsReauth ? "Needs reauth" : "Authenticated"
        case .expired:
            return "Expired"
        }
    }

    var detailText: String? {
        var parts: [String] = []
        if let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(email)
        }
        if let planType, !planType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(planType.capitalized)
        }
        if let expiresAt {
            parts.append(Self.expiryFormatter.string(from: expiresAt))
        }
        if isAuthenticated && !isVoiceTokenReady {
            parts.append("Voice syncing")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    static let voiceTokenGraceInterval: TimeInterval = 45

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

enum CodexBridgeHostPlatform: String, Codable, Sendable {
    case macOS = "macos"
    case linux
    case windows
    case unknown

    var displayName: String {
        switch self {
        case .macOS:
            return "Mac"
        case .linux:
            return "Linux computer"
        case .windows:
            return "Windows computer"
        case .unknown:
            return "computer"
        }
    }
}

struct CodexBridgeHostCapabilities: Codable, Equatable, Sendable {
    var desktopHandoff: Bool = false
    var displayWake: Bool = false
    var keepAwake: Bool = false
    var hostBrowserLogin: Bool = false

    static let legacyMacOS = CodexBridgeHostCapabilities(
        desktopHandoff: true,
        displayWake: true,
        keepAwake: true,
        hostBrowserLogin: true
    )
}

func codexGPTAccountInitialSnapshot() -> CodexGPTAccountSnapshot {
    CodexGPTAccountSnapshot(
        status: .unknown,
        authMethod: nil,
        email: nil,
        displayName: nil,
        planType: nil,
        hostPlatform: nil,
        hostCapabilities: nil,
        loginInFlight: false,
        needsReauth: false,
        expiresAt: nil,
        tokenReady: nil,
        tokenUnavailableSince: nil,
        updatedAt: .distantPast
    )
}

struct CodexGPTLoginState: Codable, Equatable, Sendable {
    let loginId: String
    let authURL: String
    let createdAt: Date
    let expiresAt: Date?
}

struct CodexGPTLoginCallbackState: Codable, Equatable, Sendable {
    let loginId: String
    let callbackURL: String
    let createdAt: Date
}

struct CodexGPTLoginStartResult: Equatable, Sendable {
    let loginId: String
    let authURL: URL
    let expiresAt: Date?
}

extension CodexService {
    static let legacyGPTLoginCallbackEnabled = true

    // Refreshes bridge-managed account + package metadata together for foreground/reconnect flows.
    func refreshBridgeManagedState(allowAvailableBridgeUpdatePrompt: Bool = false) async {
        guard isConnected else {
            applyGPTAccountConnectionFallback()
            return
        }

        do {
            let bridgeState = try await fetchBridgeManagedStatusSnapshot()
            applyBridgePackageStatus(
                from: bridgeState.payload,
                allowMissingVersionPrompt: bridgeState.allowMissingVersionPrompt,
                allowAvailableBridgeUpdatePrompt: allowAvailableBridgeUpdatePrompt
            )
            applyBridgeManagedAccountSnapshot(from: bridgeState.payload)
        } catch {
            handleBridgeManagedAccountRefreshFailure()
        }
    }

    // Refreshes the bridge-owned account snapshot without ever fetching GPT tokens on iPhone.
    func refreshGPTAccountState() async {
        guard isConnected else {
            applyGPTAccountConnectionFallback()
            return
        }

        do {
            let bridgeState = try await fetchBridgeManagedStatusSnapshot()
            applyBridgeManagedAccountSnapshot(from: bridgeState.payload)
        } catch {
            handleBridgeManagedAccountRefreshFailure()
        }
    }

    // Refreshes only the bridge package version state so Remodex updates stay independent from GPT UX.
    func refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: Bool = false) async {
        guard isConnected else {
            return
        }

        do {
            let bridgeState = try await fetchBridgeManagedStatusSnapshot()
            applyBridgePackageStatus(
                from: bridgeState.payload,
                allowMissingVersionPrompt: bridgeState.allowMissingVersionPrompt,
                allowAvailableBridgeUpdatePrompt: allowAvailableBridgeUpdatePrompt
            )
        } catch {
            // Keep the last-known bridge version info when the status read fails transiently.
        }
    }

    // Starts a ChatGPT login or reuses the last valid auth URL while login is still pending.
    func startOrResumeGPTLogin() async throws -> CodexGPTLoginStartResult {
        if let pendingLogin = currentPendingGPTLogin(),
           let authURL = URL(string: pendingLogin.authURL) {
            applyGPTAccountSnapshot(
                pendingLoginSnapshot(
                    expiresAt: pendingLogin.expiresAt,
                    retaining: gptAccountSnapshot
                )
            )
            gptAccountErrorMessage = nil
            return CodexGPTLoginStartResult(
                loginId: pendingLogin.loginId,
                authURL: authURL,
                expiresAt: pendingLogin.expiresAt
            )
        }

        guard isConnected else {
            throw CodexServiceError.disconnected
        }

        let response = try await sendRequest(
            method: "account/login/start",
            params: .object([
                "type": .string("chatgpt"),
            ])
        )
        let loginStartResult = try decodeGPTLoginStartResult(from: response)
        gptPendingLoginState = CodexGPTLoginState(
            loginId: loginStartResult.loginId,
            authURL: loginStartResult.authURL.absoluteString,
            createdAt: .now,
            expiresAt: loginStartResult.expiresAt
        )
        applyGPTAccountSnapshot(
            pendingLoginSnapshot(
                expiresAt: loginStartResult.expiresAt,
                retaining: gptAccountSnapshot
            )
        )
        gptAccountErrorMessage = nil
        return loginStartResult
    }

    // Starts or resumes ChatGPT login, then asks the bridge Mac to open the browser locally.
    func startOrResumeGPTLoginOnMac() async throws {
        guard isConnected else {
            throw CodexServiceError.disconnected
        }

        let login = try await startOrResumeGPTLogin()
        try await openGPTLoginOnMac(authURL: login.authURL)
        startGPTLoginSyncIfNeeded()
    }

    // Starts or resumes ChatGPT login and returns the auth URL so iPhone can open it directly.
    func startOrResumeGPTLoginOnPhone() async throws -> URL {
        guard isConnected else {
            throw CodexServiceError.disconnected
        }

        let login = try await startOrResumeGPTLogin()
        startGPTLoginSyncIfNeeded()
        return login.authURL
    }

    // Cancels a pending browser login locally and on the Mac runtime when reachable.
    func cancelGPTLogin() async {
        if isConnected, let pendingLogin = currentPendingGPTLogin() {
            _ = try? await sendRequest(
                method: "account/login/cancel",
                params: .object([
                    "loginId": .string(pendingLogin.loginId),
                ])
            )
        }

        clearGPTLoginState()
        clearGPTLoginCallbackState()
        stopGPTLoginSync()
        if !gptAccountSnapshot.isAuthenticated {
            applyGPTAccountSnapshot(loggedOutGPTAccountSnapshot(status: .notLoggedIn, retaining: gptAccountSnapshot))
        }
        gptAccountErrorMessage = nil
    }

    // Logs the Mac-owned ChatGPT session out without touching pairing or reconnect state.
    func logoutGPTAccount() async {
        if isConnected {
            _ = try? await sendRequest(method: "account/logout", params: nil)
        }

        clearGPTLoginState()
        clearGPTLoginCallbackState()
        stopGPTLoginSync()
        applyGPTAccountSnapshot(loggedOutGPTAccountSnapshot(status: .notLoggedIn))
        gptAccountErrorMessage = nil
    }

    // Keeps the account card honest when voice auth proves the bridge token is no longer usable.
    func markGPTVoiceReauthenticationRequired() {
        stopGPTLoginSync()
        clearGPTLoginState()
        clearGPTLoginCallbackState()
        applyGPTAccountSnapshot(
            loggedOutGPTAccountSnapshot(
                status: .expired,
                needsReauth: true,
                retaining: gptAccountSnapshot
            )
        )
        gptAccountErrorMessage = "ChatGPT voice needs a fresh sign-in on your paired computer."
    }

    // Stores an incoming deep-link callback and completes the pending login when the bridge is reachable.
    func handleGPTLoginCallbackURL(_ url: URL) async {
        guard isExpectedGPTLoginCallbackURL(url) else {
            return
        }

        guard let pendingLogin = currentPendingGPTLogin() else {
            return
        }

        let callbackState = CodexGPTLoginCallbackState(
            loginId: pendingLogin.loginId,
            callbackURL: url.absoluteString,
            createdAt: .now
        )
        gptPendingLoginCallbackState = callbackState
        await resumePendingGPTLoginIfPossible()
    }

    // Retries a stored callback after reconnects so a completed browser login is not lost.
    func resumePendingGPTLoginIfPossible() async {
        guard isConnected,
              let pendingLogin = currentPendingGPTLogin(),
              let callbackState = currentPendingGPTLoginCallback(),
              callbackState.loginId == pendingLogin.loginId else {
            return
        }

        do {
            _ = try await sendRequest(
                method: "account/login/complete",
                params: .object([
                    "loginId": .string(callbackState.loginId),
                    "callbackUrl": .string(callbackState.callbackURL),
                ])
            )
            clearGPTLoginCallbackState()
            gptAccountErrorMessage = nil
            startGPTLoginSyncIfNeeded()
        } catch {
            gptAccountErrorMessage = error.localizedDescription
        }
    }

    // Reacts to the provider login finishing on the Mac and refreshes the safe snapshot on iPhone.
    func handleGPTLoginCompletedNotification(_ paramsObject: IncomingParamsObject?) {
        let notificationLoginID = firstStringValue(in: paramsObject, keys: ["loginId", "login_id"])
        if let pendingLogin = currentPendingGPTLogin(),
           let notificationLoginID,
           notificationLoginID != pendingLogin.loginId {
            return
        }

        let wasSuccessful = firstBoolValue(in: paramsObject, keys: ["success"]) ?? false
        if wasSuccessful {
            clearGPTLoginCallbackState()
            gptAccountErrorMessage = nil
            startGPTLoginSyncIfNeeded()
            Task { await refreshGPTAccountState() }
            return
        }

        clearGPTLoginState()
        clearGPTLoginCallbackState()
        stopGPTLoginSync()
        gptAccountErrorMessage = firstStringValue(in: paramsObject, keys: ["error", "message"])
            ?? "ChatGPT sign-in did not complete."
        if !gptAccountSnapshot.isAuthenticated {
            applyGPTAccountSnapshot(
                loggedOutGPTAccountSnapshot(
                    status: .expired,
                    needsReauth: true,
                    retaining: gptAccountSnapshot
                )
            )
        }
    }

    // Keeps the cached snapshot in sync with logout and plan-change notifications from the bridge runtime.
    func handleGPTAccountUpdated(_ paramsObject: IncomingParamsObject?) {
        if let planType = firstStringValue(in: paramsObject, keys: ["planType", "plan_type"]) {
            gptAccountSnapshot.planType = planType
            gptAccountSnapshot.updatedAt = .now
        }

        Task { await refreshGPTAccountState() }
    }

    // Falls back to the last known safe snapshot so reconnects do not look like unexpected logouts.
    func applyGPTAccountConnectionFallback() {
        if let pendingLogin = currentPendingGPTLogin() {
            applyGPTAccountSnapshot(
                pendingLoginSnapshot(
                    expiresAt: pendingLogin.expiresAt,
                    retaining: gptAccountSnapshot
                )
            )
            return
        }

        if gptAccountSnapshot.status == .unknown {
            gptAccountSnapshot = disconnectedGPTAccountSnapshot()
        }
    }

    // Determines whether the mic button should nudge the user into login instead of recording.
    var gptVoiceRequiresLogin: Bool {
        !gptAccountSnapshot.isAuthenticated || gptAccountSnapshot.hasActiveLogin
    }

    // Separates signed-in state from bridge token readiness so the mic does not appear ready too early.
    var gptVoiceTemporarilyUnavailable: Bool {
        isConnected
            && gptAccountSnapshot.isAuthenticated
            && !gptAccountSnapshot.hasActiveLogin
            && !gptAccountSnapshot.isVoiceTokenReady
    }

    // Determines whether the bridge-backed voice flow can capture and transcribe audio right now.
    var canUseGPTVoiceTranscription: Bool {
        isConnected && gptAccountSnapshot.isAuthenticated && gptAccountSnapshot.isVoiceTokenReady && !gptAccountSnapshot.hasActiveLogin
    }

    // Re-polls account status while the user is finishing login in the browser.
    func startGPTLoginSyncIfNeeded() {
        guard gptAccountLoginSyncTask == nil, currentPendingGPTLogin() != nil else {
            return
        }

        gptAccountLoginSyncTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard self.currentPendingGPTLogin() != nil else {
                    self.stopGPTLoginSync()
                    return
                }

                if self.isConnected {
                    await self.refreshGPTAccountState()
                }

                if self.gptAccountSnapshot.status == .expired
                    || (self.gptAccountSnapshot.isAuthenticated && self.gptAccountSnapshot.isVoiceTokenReady)
                    || self.currentPendingGPTLogin() == nil {
                    self.stopGPTLoginSync()
                    return
                }

                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // Stops the lightweight login polling once the bridge reports a stable account state.
    func stopGPTLoginSync() {
        gptAccountLoginSyncTask?.cancel()
        gptAccountLoginSyncTask = nil
    }
}

// Split-file storage helpers stay service-internal so CodexService.swift can restore/persist GPT auth state.
extension CodexService {
    static let gptAccountSnapshotDefaultsKey = "codex.gpt.accountSnapshot"
    static let gptPendingLoginStateDefaultsKey = "codex.gpt.pendingLoginState"
    static let gptPendingLoginCallbackDefaultsKey = "codex.gpt.pendingLoginCallbackState"

    var gptPendingLoginState: CodexGPTLoginState? {
        get {
            guard let data = defaults.data(forKey: Self.gptPendingLoginStateDefaultsKey),
                  let state = try? decoder.decode(CodexGPTLoginState.self, from: data) else {
                return nil
            }

            return state.isExpired ? nil : state
        }
        set {
            if let newValue {
                guard let data = try? encoder.encode(newValue) else {
                    return
                }
                defaults.set(data, forKey: Self.gptPendingLoginStateDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.gptPendingLoginStateDefaultsKey)
            }
        }
    }

    var gptPendingLoginCallbackState: CodexGPTLoginCallbackState? {
        get {
            guard let data = defaults.data(forKey: Self.gptPendingLoginCallbackDefaultsKey),
                  let state = try? decoder.decode(CodexGPTLoginCallbackState.self, from: data) else {
                return nil
            }

            return state.isExpired ? nil : state
        }
        set {
            if let newValue {
                guard let data = try? encoder.encode(newValue) else {
                    return
                }
                defaults.set(data, forKey: Self.gptPendingLoginCallbackDefaultsKey)
            } else {
                defaults.removeObject(forKey: Self.gptPendingLoginCallbackDefaultsKey)
            }
        }
    }

    func currentPendingGPTLogin() -> CodexGPTLoginState? {
        guard let pendingLogin = gptPendingLoginState else {
            return nil
        }

        if pendingLogin.isExpired {
            clearGPTLoginState()
            return nil
        }

        return pendingLogin
    }

    func currentPendingGPTLoginCallback() -> CodexGPTLoginCallbackState? {
        guard let callbackState = gptPendingLoginCallbackState else {
            return nil
        }

        if callbackState.isExpired {
            clearGPTLoginCallbackState()
            return nil
        }

        return callbackState
    }

    func loadPersistedGPTAccountSnapshot() -> CodexGPTAccountSnapshot? {
        guard let data = defaults.data(forKey: Self.gptAccountSnapshotDefaultsKey),
              let snapshot = try? decoder.decode(CodexGPTAccountSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    func persistGPTAccountSnapshot(_ snapshot: CodexGPTAccountSnapshot) {
        guard let data = try? encoder.encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: Self.gptAccountSnapshotDefaultsKey)
    }

    func clearGPTLoginState() {
        gptPendingLoginState = nil
        stopGPTLoginSync()
    }

    func clearGPTLoginCallbackState() {
        gptPendingLoginCallbackState = nil
    }

    // Keeps stale browser URLs from surviving once the runtime reports a stable account state.
    func syncPendingGPTLoginStateIfNeeded() {
        guard let pendingLogin = gptPendingLoginState else {
            clearGPTLoginCallbackState()
            return
        }

        if pendingLogin.isExpired
            || (gptAccountSnapshot.isAuthenticated && gptAccountSnapshot.isVoiceTokenReady)
            || gptAccountSnapshot.status == .expired {
            clearGPTLoginState()
            clearGPTLoginCallbackState()
            return
        }

        if let callbackState = currentPendingGPTLoginCallback(),
           callbackState.loginId != pendingLogin.loginId {
            clearGPTLoginCallbackState()
        }
    }

    // Centralizes snapshot writes so persistence and pending-login cleanup stay aligned.
    func applyGPTAccountSnapshot(_ snapshot: CodexGPTAccountSnapshot) {
        var resolvedSnapshot = snapshot
        if resolvedSnapshot.status == .authenticated || resolvedSnapshot.status == .expired {
            resolvedSnapshot.loginInFlight = false
        }
        if (resolvedSnapshot.isAuthenticated && resolvedSnapshot.isVoiceTokenReady)
            || resolvedSnapshot.status == .expired {
            clearGPTLoginState()
            clearGPTLoginCallbackState()
        }
        resolvedSnapshot.updatedAt = .now
        gptAccountSnapshot = resolvedSnapshot
        syncPendingGPTLoginStateIfNeeded()
    }

    private func fetchBridgeManagedStatusSnapshot() async throws -> (
        payload: IncomingParamsObject,
        allowMissingVersionPrompt: Bool
    ) {
        do {
            let response = try await sendRequest(method: "account/status/read", params: nil)
            guard let payload = response.result?.objectValue else {
                throw CodexServiceError.invalidResponse("bridge account status response missing payload")
            }
            return (
                payload: payload,
                allowMissingVersionPrompt: true
            )
        } catch {
            let response = try await sendRequest(method: "getAuthStatus", params: nil)
            guard let payload = response.result?.objectValue else {
                throw CodexServiceError.invalidResponse("bridge account status response missing payload")
            }
            return (
                payload: payload,
                allowMissingVersionPrompt: shouldTreatAsUnsupportedBridgeManagedAccountStatus(error)
            )
        }
    }

    // Applies the bridge-owned ChatGPT snapshot after a shared managed-status fetch.
    private func applyBridgeManagedAccountSnapshot(from payloadObject: IncomingParamsObject) {
        applyGPTAccountSnapshot(decodeBridgeGPTAccountSnapshot(from: payloadObject))
        if currentPendingGPTLogin() != nil,
           (gptAccountSnapshot.hasActiveLogin || (gptAccountSnapshot.isAuthenticated && !gptAccountSnapshot.isVoiceTokenReady)) {
            startGPTLoginSyncIfNeeded()
        }
        if gptAccountSnapshot.isAuthenticated || gptAccountSnapshot.status == .notLoggedIn {
            gptAccountErrorMessage = nil
        }
    }

    // Applies bridge package versions and prompts independently from GPT account state.
    private func applyBridgePackageStatus(
        from payloadObject: IncomingParamsObject,
        allowMissingVersionPrompt: Bool,
        allowAvailableBridgeUpdatePrompt: Bool
    ) {
        let previousTransportMode = codexTransportMode
        codexTransportMode = decodeCodexTransportMode(
            from: firstStringValue(
                in: payloadObject,
                keys: ["codexTransportMode", "codex_transport_mode", "transportMode", "transport_mode"]
            )
        )
        reconcileNativePlanSessionSources(
            previousTransportMode: previousTransportMode,
            nextTransportMode: codexTransportMode
        )
        bridgeInstalledVersion = firstStringValue(
            in: payloadObject,
            keys: ["bridgeVersion", "bridge_version", "bridgePackageVersion", "bridge_package_version"]
        )
        latestBridgePackageVersion = firstStringValue(
            in: payloadObject,
            keys: ["bridgeLatestVersion", "bridge_latest_version", "bridgePublishedVersion", "bridge_published_version"]
        )
        applyBridgeHostMetadata(from: payloadObject)
        evaluateRequiredBridgePackageVersion(
            from: payloadObject,
            allowMissingVersionPrompt: allowMissingVersionPrompt
        )
        if allowAvailableBridgeUpdatePrompt {
            evaluateAvailableBridgePackageVersionPromptIfNeeded()
        }
    }

    private func decodeCodexTransportMode(from rawValue: String?) -> CodexRuntimeTransportMode {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else {
            return .unknown
        }

        return CodexRuntimeTransportMode(rawValue: rawValue) ?? .unknown
    }

    private func applyBridgeHostMetadata(from payloadObject: IncomingParamsObject) {
        gptAccountSnapshot.hostPlatform = decodeBridgeHostPlatform(
            from: firstStringValue(
                in: payloadObject,
                keys: ["hostPlatform", "host_platform", "bridgeHostPlatform", "bridge_host_platform"]
            )
        )
        gptAccountSnapshot.hostCapabilities = decodeBridgeHostCapabilities(from: payloadObject)
    }

    private func handleBridgeManagedAccountRefreshFailure() {
        if gptAccountSnapshot.status == .unknown {
            gptAccountSnapshot = disconnectedGPTAccountSnapshot()
        }
    }

    // Prompts for a bridge package upgrade once per session when bridge-managed status
    // reports an older npm package or omits the version entirely.
    private func evaluateRequiredBridgePackageVersion(
        from payloadObject: IncomingParamsObject,
        allowMissingVersionPrompt: Bool
    ) {
        guard !hasPresentedMinimumBridgePackageUpdatePrompt else {
            return
        }

        let bridgeVersion = firstStringValue(
            in: payloadObject,
            keys: ["bridgeVersion", "bridge_version", "bridgePackageVersion", "bridge_package_version"]
        )
        let requiresUpgrade =
            bridgePackageVersionIsOlderThanMinimum(bridgeVersion)
            || (bridgeVersion == nil && allowMissingVersionPrompt)

        guard requiresUpgrade else {
            return
        }

        hasPresentedMinimumBridgePackageUpdatePrompt = true
        bridgeUpdatePrompt = minimumBridgePackageUpdatePrompt(currentVersion: bridgeVersion)
    }

    // Only explicit versions can be compared here; missing versions are handled by the caller.
    private func bridgePackageVersionIsOlderThanMinimum(_ bridgeVersion: String?) -> Bool {
        guard let bridgeVersion = bridgeVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bridgeVersion.isEmpty else {
            return false
        }

        return bridgeVersion.compare(CodexService.minimumSupportedBridgePackageVersion, options: .numeric) == .orderedAscending
    }

    // Distinguishes "older bridge only exposes getAuthStatus" from transient read failures on a current bridge.
    private func shouldTreatAsUnsupportedBridgeManagedAccountStatus(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code == -32601 {
            return true
        }

        let message = rpcError.message.lowercased()
        let mentionsUnsupportedMethod = message.contains("method not found")
            || message.contains("unknown method")
            || message.contains("not implemented")
            || message.contains("does not support")
        let mentionsAccountStatusRoute = message.contains("account/status/read")
            || message.contains("account status read")
            || message.contains("auth status")

        guard rpcError.code == -32600 || rpcError.code == -32602 || rpcError.code == -32000 else {
            return mentionsUnsupportedMethod && mentionsAccountStatusRoute
        }

        return mentionsUnsupportedMethod && mentionsAccountStatusRoute
    }

    private func minimumBridgePackageUpdatePrompt(currentVersion: String?) -> CodexBridgeUpdatePrompt {
        let message: String
        if let currentVersion = currentVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentVersion.isEmpty {
            message =
                "This computer bridge is running Remodex \(currentVersion), but this iPhone app requires Remodex \(CodexService.minimumSupportedBridgePackageVersion) or newer. Update the npm package on your computer, then reconnect."
        } else {
            message =
                "This computer bridge is too old for this version of Remodex iPhone. Update the Remodex npm package on your computer to \(CodexService.minimumSupportedBridgePackageVersion) or newer, then reconnect."
        }

        return CodexBridgeUpdatePrompt(
            title: "Update Remodex on your computer to reconnect",
            message: message,
            command: minimumBridgePackageUpdateCommand
        )
    }

    // Surfaces a softer "npm update available" prompt without overriding stricter compatibility prompts.
    private func evaluateAvailableBridgePackageVersionPromptIfNeeded() {
        guard isAppInForeground else {
            return
        }

        guard bridgeUpdatePrompt == nil else {
            return
        }

        guard let installedVersion = normalizedBridgePackageVersion(bridgeInstalledVersion) else {
            return
        }

        if installedVersion == forcedBridgeUpgradeFromVersion {
            guard lastPresentedAvailableBridgePackageVersion != forcedBridgeUpgradeTargetVersion else {
                return
            }

            lastPresentedAvailableBridgePackageVersion = forcedBridgeUpgradeTargetVersion
            bridgeUpdatePrompt = forcedBridgePackageUpdatePrompt(currentVersion: installedVersion)
            return
        }

        guard let latestVersion = normalizedBridgePackageVersion(latestBridgePackageVersion),
              installedVersion.compare(latestVersion, options: .numeric) == .orderedAscending else {
            return
        }

        guard lastPresentedAvailableBridgePackageVersion != latestVersion else {
            return
        }

        lastPresentedAvailableBridgePackageVersion = latestVersion
        bridgeUpdatePrompt = availableBridgePackageUpdatePrompt(
            currentVersion: installedVersion,
            latestVersion: latestVersion
        )
    }

    // Keeps version comparisons and prompt copy on one normalized representation.
    private func normalizedBridgePackageVersion(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func availableBridgePackageUpdatePrompt(
        currentVersion: String,
        latestVersion: String
    ) -> CodexBridgeUpdatePrompt {
        CodexBridgeUpdatePrompt(
            title: "A newer Remodex update is available on your computer",
            message: "This computer bridge is running Remodex \(currentVersion), and npm now has Remodex \(latestVersion). Update the package on your computer when you're ready, then reconnect to start using the newer build.",
            command: minimumBridgePackageUpdateCommand
        )
    }

    private func forcedBridgePackageUpdatePrompt(currentVersion: String) -> CodexBridgeUpdatePrompt {
        CodexBridgeUpdatePrompt(
            title: "Update Remodex on your computer to reconnect",
            message: "This computer bridge is running Remodex \(currentVersion). Update the Remodex CLI on your computer to \(forcedBridgeUpgradeTargetVersion), then reconnect.",
            command: forcedBridgeUpgradeCommand
        )
    }

    // Opens the pending ChatGPT login URL on the bridge Mac instead of opening Safari on iPhone.
    func openGPTLoginOnMac(authURL: URL) async throws {
        _ = try await sendRequest(
            method: "account/login/openOnMac",
            params: .object([
                "authUrl": .string(authURL.absoluteString),
            ])
        )
    }

    func isExpectedGPTLoginCallbackURL(_ url: URL) -> Bool {
        guard let callbackScheme = Bundle.main.object(
            forInfoDictionaryKey: "PHODEX_CHATGPT_CALLBACK_SCHEME"
        ) as? String else {
            return false
        }

        guard url.scheme?.caseInsensitiveCompare(callbackScheme) == .orderedSame else {
            return false
        }

        return url.host == "auth" && url.path.lowercased().contains("/gpt/callback")
    }

    func decodeBridgeGPTAccountSnapshot(from payloadObject: IncomingParamsObject) -> CodexGPTAccountSnapshot {
        // Older bridges fall back to raw `getAuthStatus`, so derive a stable account state
        // even when the payload does not include the newer sanitized `status` field.
        let parsedStatus = decodeGPTAccountStatus(
            from: firstStringValue(in: payloadObject, keys: ["status", "state"])
        )
        let bridgeReportedPendingLogin = firstBoolValue(in: payloadObject, keys: ["loginInFlight", "login_in_flight"]) ?? false
        let needsReauth = firstBoolValue(in: payloadObject, keys: ["needsReauth", "needs_reauth"]) ?? false
        let legacyAuthMethod = decodeGPTAuthMethod(
            from: firstStringValue(in: payloadObject, keys: ["authMethod", "auth_mode"])
        )
        let hasLegacyAuthToken = firstStringValue(in: payloadObject, keys: ["authToken", "auth_token"]) != nil

        let resolvedStatus: CodexGPTAccountStatus
        if parsedStatus == .authenticated || parsedStatus == .expired {
            resolvedStatus = parsedStatus
        } else if parsedStatus == .unknown && hasLegacyAuthToken && legacyAuthMethod != nil && !needsReauth {
            resolvedStatus = .authenticated
        } else if parsedStatus == .notLoggedIn && bridgeReportedPendingLogin && !needsReauth {
            resolvedStatus = .loginPending
        } else if parsedStatus == .unknown && bridgeReportedPendingLogin {
            resolvedStatus = .loginPending
        } else if parsedStatus == .unknown {
            resolvedStatus = .notLoggedIn
        } else {
            resolvedStatus = parsedStatus
        }

        let hasPendingLogin = bridgeReportedPendingLogin
            || (currentPendingGPTLogin() != nil && resolvedStatus != .authenticated && resolvedStatus != .expired)

        let tokenReady = resolvedTokenReady(
            from: payloadObject,
            status: resolvedStatus,
            needsReauth: needsReauth,
            hasLegacyAuthToken: hasLegacyAuthToken
        )
        let tokenUnavailableSince = resolvedTokenUnavailableSince(
            status: resolvedStatus,
            needsReauth: needsReauth,
            tokenReady: tokenReady
        )
        let escalatedNeedsReauth = resolvedNeedsReauth(
            baseNeedsReauth: needsReauth,
            status: resolvedStatus,
            tokenReady: tokenReady,
            tokenUnavailableSince: tokenUnavailableSince
        )

        return CodexGPTAccountSnapshot(
            status: resolvedStatus,
            authMethod: legacyAuthMethod,
            email: firstStringValue(in: payloadObject, keys: ["email"]),
            displayName: nil,
            planType: firstStringValue(in: payloadObject, keys: ["planType", "plan_type"]),
            hostPlatform: decodeBridgeHostPlatform(
                from: firstStringValue(
                    in: payloadObject,
                    keys: ["hostPlatform", "host_platform", "bridgeHostPlatform", "bridge_host_platform"]
                )
            ),
            hostCapabilities: decodeBridgeHostCapabilities(from: payloadObject),
            loginInFlight: hasPendingLogin,
            needsReauth: escalatedNeedsReauth,
            expiresAt: firstDateValue(in: payloadObject, keys: ["expiresAt", "expires_at"]),
            tokenReady: tokenReady,
            tokenUnavailableSince: tokenUnavailableSince,
            updatedAt: .now
        )
    }

    func decodeGPTLoginStartResult(from response: RPCMessage) throws -> CodexGPTLoginStartResult {
        guard let payloadObject = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("account/login/start response missing payload")
        }

        guard firstStringValue(in: payloadObject, keys: ["type"]) == "chatgpt" else {
            throw CodexServiceError.invalidResponse("account/login/start did not return a ChatGPT login flow")
        }

        guard let loginId = firstStringValue(in: payloadObject, keys: ["loginId", "login_id"]),
              let authURLString = firstStringValue(in: payloadObject, keys: ["authUrl", "auth_url"]),
              let authURL = URL(string: authURLString) else {
            throw CodexServiceError.invalidResponse("account/login/start response missing auth URL")
        }

        return CodexGPTLoginStartResult(
            loginId: loginId,
            authURL: authURL,
            expiresAt: firstDateValue(in: payloadObject, keys: ["expiresAt", "expires_at"])
        )
    }

    func disconnectedGPTAccountSnapshot() -> CodexGPTAccountSnapshot {
        CodexGPTAccountSnapshot(
            status: .unavailable,
            authMethod: gptAccountSnapshot.authMethod,
            email: gptAccountSnapshot.email,
            displayName: gptAccountSnapshot.displayName,
            planType: gptAccountSnapshot.planType,
            hostPlatform: gptAccountSnapshot.hostPlatform,
            hostCapabilities: gptAccountSnapshot.hostCapabilities,
            loginInFlight: currentPendingGPTLogin() != nil,
            needsReauth: false,
            expiresAt: currentPendingGPTLogin()?.expiresAt,
            tokenReady: gptAccountSnapshot.tokenReady,
            tokenUnavailableSince: gptAccountSnapshot.tokenUnavailableSince,
            updatedAt: .now
        )
    }

    func pendingLoginSnapshot(
        expiresAt: Date?,
        retaining snapshot: CodexGPTAccountSnapshot
    ) -> CodexGPTAccountSnapshot {
        CodexGPTAccountSnapshot(
            status: .loginPending,
            authMethod: .chatgpt,
            email: snapshot.email,
            displayName: snapshot.displayName,
            planType: snapshot.planType,
            hostPlatform: snapshot.hostPlatform,
            hostCapabilities: snapshot.hostCapabilities,
            loginInFlight: true,
            needsReauth: false,
            expiresAt: expiresAt,
            tokenReady: false,
            tokenUnavailableSince: nil,
            updatedAt: .now
        )
    }

    func loggedOutGPTAccountSnapshot(
        status: CodexGPTAccountStatus,
        needsReauth: Bool = false,
        retaining snapshot: CodexGPTAccountSnapshot = codexGPTAccountInitialSnapshot()
    ) -> CodexGPTAccountSnapshot {
        CodexGPTAccountSnapshot(
            status: status,
            authMethod: nil,
            email: needsReauth ? snapshot.email : nil,
            displayName: needsReauth ? snapshot.displayName : nil,
            planType: needsReauth ? snapshot.planType : nil,
            hostPlatform: snapshot.hostPlatform,
            hostCapabilities: snapshot.hostCapabilities,
            loginInFlight: false,
            needsReauth: needsReauth,
            expiresAt: nil,
            tokenReady: false,
            tokenUnavailableSince: nil,
            updatedAt: .now
        )
    }

    func resolvedTokenReady(
        from payloadObject: IncomingParamsObject,
        status: CodexGPTAccountStatus,
        needsReauth: Bool,
        hasLegacyAuthToken: Bool = false
    ) -> Bool {
        if let tokenReady = firstBoolValue(in: payloadObject, keys: ["tokenReady", "token_ready"]) {
            return tokenReady
        }

        return hasLegacyAuthToken && status == .authenticated && !needsReauth
    }

    func resolvedTokenUnavailableSince(
        status: CodexGPTAccountStatus,
        needsReauth: Bool,
        tokenReady: Bool
    ) -> Date? {
        guard status == .authenticated, !needsReauth, !tokenReady else {
            return nil
        }

        if gptAccountSnapshot.status == .authenticated,
           gptAccountSnapshot.tokenReady == false,
           let existingDate = gptAccountSnapshot.tokenUnavailableSince {
            return existingDate
        }

        return .now
    }

    func resolvedNeedsReauth(
        baseNeedsReauth: Bool,
        status: CodexGPTAccountStatus,
        tokenReady: Bool,
        tokenUnavailableSince: Date?
    ) -> Bool {
        guard !baseNeedsReauth else {
            return true
        }

        if gptAccountSnapshot.needsReauth, !tokenReady {
            return true
        }

        guard status == .authenticated, !tokenReady, let tokenUnavailableSince else {
            return false
        }

        return Date().timeIntervalSince(tokenUnavailableSince) >= CodexGPTAccountSnapshot.voiceTokenGraceInterval
    }

    func decodeGPTAccountStatus(from value: String?) -> CodexGPTAccountStatus {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return .unknown
        }

        switch value {
        case "authenticated", "logged_in", "loggedin", "connected":
            return .authenticated
        case "loginpending", "login_pending", "pending", "pending_login":
            return .loginPending
        case "expired", "needs_reauth", "needsreauth", "reauth_required":
            return .expired
        case "not_logged_in", "notloggedin", "signed_out", "logged_out", "unauthenticated":
            return .notLoggedIn
        case "unavailable", "offline":
            return .unavailable
        default:
            return .unknown
        }
    }

    func decodeGPTAuthMethod(from value: String?) -> CodexGPTAuthMethod? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }

        switch value {
        case "chatgpt", "chat_gpt", "chatgptauthtokens":
            return .chatgpt
        default:
            return nil
        }
    }

    func decodeBridgeHostPlatform(from value: String?) -> CodexBridgeHostPlatform? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }

        return CodexBridgeHostPlatform(rawValue: value) ?? .unknown
    }

    func decodeBridgeHostCapabilities(from payloadObject: IncomingParamsObject) -> CodexBridgeHostCapabilities? {
        let capabilitiesObject = payloadObject["hostCapabilities"]?.objectValue
            ?? payloadObject["host_capabilities"]?.objectValue
            ?? payloadObject["bridgeHostCapabilities"]?.objectValue
            ?? payloadObject["bridge_host_capabilities"]?.objectValue

        guard let capabilitiesObject else {
            return nil
        }

        return CodexBridgeHostCapabilities(
            desktopHandoff: firstBoolValue(in: capabilitiesObject, keys: ["desktopHandoff", "desktop_handoff"]) ?? false,
            displayWake: firstBoolValue(in: capabilitiesObject, keys: ["displayWake", "display_wake"]) ?? false,
            keepAwake: firstBoolValue(in: capabilitiesObject, keys: ["keepAwake", "keep_awake"]) ?? false,
            hostBrowserLogin: firstBoolValue(in: capabilitiesObject, keys: ["hostBrowserLogin", "host_browser_login"]) ?? false
        )
    }

    func firstStringValue(in object: IncomingParamsObject?, keys: [String]) -> String? {
        guard let object else {
            return nil
        }

        for key in keys {
            if let value = object[key]?.stringValue {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    func firstBoolValue(in object: IncomingParamsObject?, keys: [String]) -> Bool? {
        guard let object else {
            return nil
        }

        for key in keys {
            if let value = object[key]?.boolValue {
                return value
            }

            if let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                switch value {
                case "true", "1", "yes", "y":
                    return true
                case "false", "0", "no", "n":
                    return false
                default:
                    continue
                }
            }

            if let value = object[key]?.intValue {
                return value != 0
            }
        }

        return nil
    }

    func firstDateValue(in object: IncomingParamsObject?, keys: [String]) -> Date? {
        guard let object else {
            return nil
        }

        for key in keys {
            if let value = object[key], let decodedDate = decodeDateValue(value) {
                return decodedDate
            }
        }
        return nil
    }

    func decodeDateValue(_ value: JSONValue) -> Date? {
        switch value {
        case .integer(let integer):
            let interval = integer > 10_000_000_000 ? TimeInterval(integer) / 1_000 : TimeInterval(integer)
            return Date(timeIntervalSince1970: interval)
        case .double(let double):
            let interval = double > 10_000_000_000 ? double / 1_000 : double
            return Date(timeIntervalSince1970: interval)
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let interval = TimeInterval(trimmed) {
                let adjusted = interval > 10_000_000_000 ? interval / 1_000 : interval
                return Date(timeIntervalSince1970: adjusted)
            }

            let formatter = ISO8601DateFormatter()
            return formatter.date(from: trimmed)
        default:
            return nil
        }
    }
}

private extension CodexGPTLoginState {
    var isExpired: Bool {
        guard let expiresAt else {
            return false
        }
        return expiresAt <= .now
    }
}

private extension CodexGPTLoginCallbackState {
    var isExpired: Bool {
        createdAt.addingTimeInterval(10 * 60) <= .now
    }
}
