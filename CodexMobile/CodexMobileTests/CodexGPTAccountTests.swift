// FILE: CodexGPTAccountTests.swift
// Purpose: Verifies bridge-owned ChatGPT account state, login notifications, and voice transcription requests.
// Layer: Unit Test
// Exports: CodexGPTAccountTests
// Depends on: XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexGPTAccountTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testKnownWindowsBridgeDoesNotUseLegacyMacDisplayWakeFallback() {
        let service = makeService()
        let macDeviceID = "host-\(UUID().uuidString)"

        service.lastTrustedMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            lastPairedAt: Date()
        )
        service.gptAccountSnapshot.hostPlatform = .windows
        service.gptAccountSnapshot.hostCapabilities = nil

        XCTAssertEqual(service.bridgeHostPlatform, .windows)
        XCTAssertFalse(service.supportsDisplayWake)
        XCTAssertFalse(service.supportsDesktopAppHandoff)
        XCTAssertFalse(service.supportsKeepAwakeWhileBridgeRuns)
    }

    func testKnownMacBridgeKeepsLegacyDisplayWakeFallback() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.lastTrustedMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 8, count: 32).base64EncodedString(),
            lastPairedAt: Date()
        )
        service.gptAccountSnapshot.hostPlatform = .macOS
        service.gptAccountSnapshot.hostCapabilities = nil

        XCTAssertTrue(service.supportsDisplayWake)
        XCTAssertTrue(service.supportsDesktopAppHandoff)
        XCTAssertTrue(service.supportsKeepAwakeWhileBridgeRuns)
    }

    func testRefreshGPTAccountStateDecodesSanitizedBridgeStatus() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("user@example.com"),
                        "planType": .string("plus"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            }

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.authMethod, .chatgpt)
        XCTAssertEqual(service.gptAccountSnapshot.email, "user@example.com")
        XCTAssertEqual(service.gptAccountSnapshot.planType, "plus")
        XCTAssertFalse(service.gptAccountSnapshot.loginInFlight)
        XCTAssertTrue(service.gptAccountSnapshot.isVoiceTokenReady)
        XCTAssertNil(service.gptAccountErrorMessage)
    }

    func testRefreshGPTAccountStateFallsBackToLegacyGetAuthStatusPayload() async {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/status/read":
                XCTAssertNil(params)
                throw CodexServiceError.invalidInput("method not found")
            case "getAuthStatus":
                XCTAssertNil(params)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "authMethod": .string("chatgptAuthTokens"),
                        "authToken": .string("legacy-token"),
                        "requiresOpenaiAuth": .bool(false),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        await service.refreshGPTAccountState()

        XCTAssertEqual(observedMethods, ["account/status/read", "getAuthStatus"])
        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.authMethod, .chatgpt)
        XCTAssertTrue(service.gptAccountSnapshot.isVoiceTokenReady)
        XCTAssertFalse(service.gptVoiceRequiresLogin)
    }

    func testRefreshBridgeVersionStatePresentsOptionalBridgeUpdateWhenLatestIsNewer() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("2.0.0"),
                    "bridgeLatestVersion": .string("2.0.1"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: true)

        XCTAssertEqual(service.bridgeInstalledVersion, "2.0.0")
        XCTAssertEqual(service.latestBridgePackageVersion, "2.0.1")
        XCTAssertEqual(
            service.bridgeUpdatePrompt?.title,
            "A newer Remodex update is available on your Mac"
        )
        XCTAssertEqual(service.bridgeUpdatePrompt?.command, "npm install -g remodex@latest")
        XCTAssertEqual(service.gptAccountSnapshot.status, .unknown)
    }

    func testRefreshBridgeVersionStateDoesNotPresentOptionalBridgeUpdateWithoutForegroundFlag() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("2.0.0"),
                    "bridgeLatestVersion": .string("2.0.1"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState()

        XCTAssertNil(service.bridgeUpdatePrompt)
    }

    func testRefreshBridgeVersionStateDoesNotRepeatOptionalBridgeUpdateForSameLatestVersion() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("2.0.0"),
                    "bridgeLatestVersion": .string("2.0.1"),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: true)
        let firstPrompt = service.bridgeUpdatePrompt

        service.bridgeUpdatePrompt = nil
        await service.refreshBridgeVersionState(allowAvailableBridgeUpdatePrompt: true)

        XCTAssertNotNil(firstPrompt)
        XCTAssertNil(service.bridgeUpdatePrompt)
    }

    func testForegroundReturnRefreshesBridgeVersionAndPresentsOptionalUpdatePrompt() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.syncRealtimeEnabled = false
        service.isAppInForeground = false

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(true),
                    "bridgeVersion": .string("2.0.0"),
                    "bridgeLatestVersion": .string("2.0.1"),
                ]),
                includeJSONRPC: false
            )
        }

        service.setForegroundState(true)
        await yieldMainActor(times: 3)

        XCTAssertEqual(service.bridgeInstalledVersion, "2.0.0")
        XCTAssertEqual(service.latestBridgePackageVersion, "2.0.1")
        XCTAssertEqual(
            service.bridgeUpdatePrompt?.title,
            "A newer Remodex update is available on your Mac"
        )
    }

    func testStartOrResumeGPTLoginUsesChatGPTVariantAndCachesPendingURL() async throws {
        let service = makeService()
        service.isConnected = true
        var capturedParams: JSONValue?

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/login/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "type": .string("chatgpt"),
                    "loginId": .string("login-123"),
                    "authUrl": .string("https://example.com/login"),
                ]),
                includeJSONRPC: false
            )
        }

        let loginResult = try await service.startOrResumeGPTLogin()

        XCTAssertEqual(capturedParams?.objectValue?["type"]?.stringValue, "chatgpt")
        XCTAssertEqual(loginResult.loginId, "login-123")
        XCTAssertEqual(loginResult.authURL.absoluteString, "https://example.com/login")
        XCTAssertEqual(service.gptAccountSnapshot.status, .loginPending)
    }

    func testStartOrResumeGPTLoginOnMacOpensPendingBrowserOnBridge() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []
        var capturedOpenParams: IncomingParamsObject?

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/login/openOnMac":
                capturedOpenParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "success": .bool(true),
                        "openedOnMac": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        try await service.startOrResumeGPTLoginOnMac()

        XCTAssertEqual(observedMethods, ["account/login/start", "account/login/openOnMac"])
        XCTAssertEqual(capturedOpenParams?["authUrl"]?.stringValue, "https://example.com/login")
        XCTAssertEqual(service.gptAccountSnapshot.status, .loginPending)
    }

    func testStartOrResumeGPTLoginOnPhoneReturnsAuthURLWithoutMacOpenRequest() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                XCTAssertEqual(params?.objectValue?["type"]?.stringValue, "chatgpt")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        let authURL = try await service.startOrResumeGPTLoginOnPhone()

        XCTAssertEqual(observedMethods, ["account/login/start"])
        XCTAssertEqual(authURL.absoluteString, "https://example.com/login")
        XCTAssertEqual(service.gptAccountSnapshot.status, .loginPending)
    }

    func testLoginCompletedNotificationRefreshesAuthenticatedSnapshot() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/status/read":
                XCTAssertNil(params)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("signedin@example.com"),
                        "planType": .string("plus"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "account/login/completed",
                params: .object([
                    "loginId": .string("login-123"),
                    "success": .bool(true),
                    "error": .null,
                ])
            )
        )

        await yieldMainActor(times: 3)

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.email, "signedin@example.com")
        XCTAssertTrue(observedMethods.contains("account/status/read"))
    }

    func testAuthenticatedSnapshotWithoutTokenReadyKeepsVoiceDisabled() async {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "account/status/read")
            XCTAssertNil(params)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "status": .string("authenticated"),
                    "authMethod": .string("chatgpt"),
                    "email": .string("user@example.com"),
                    "loginInFlight": .bool(false),
                    "needsReauth": .bool(false),
                    "tokenReady": .bool(false),
                ]),
                includeJSONRPC: false
            )
        }

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertFalse(service.gptAccountSnapshot.isVoiceTokenReady)
        XCTAssertFalse(service.canUseGPTVoiceTranscription)
        XCTAssertTrue(service.gptVoiceTemporarilyUnavailable)
    }

    func testRefreshGPTAccountStateClearsStalePendingLoginWhenBridgeIsAuthenticated() async throws {
        let service = makeService()
        service.isConnected = true

        service.requestTransportOverride = { method, params in
            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/status/read":
                XCTAssertNil(params)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("signedin@example.com"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        XCTAssertNotNil(service.currentPendingGPTLogin())

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertFalse(service.gptAccountSnapshot.loginInFlight)
        XCTAssertNil(service.currentPendingGPTLogin())
        XCTAssertFalse(service.gptVoiceRequiresLogin)
        XCTAssertTrue(service.canUseGPTVoiceTranscription)
    }

    func testAuthenticatedSnapshotWithoutTokenReadyEventuallyNeedsReauth() {
        let service = makeService()
        service.gptAccountSnapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "user@example.com",
            displayName: nil,
            planType: nil,
            loginInFlight: false,
            needsReauth: false,
            expiresAt: nil,
            tokenReady: false,
            tokenUnavailableSince: Date().addingTimeInterval(-90),
            updatedAt: .now
        )

        let snapshot = service.decodeBridgeGPTAccountSnapshot(from: [
            "status": .string("authenticated"),
            "authMethod": .string("chatgpt"),
            "email": .string("user@example.com"),
            "loginInFlight": .bool(false),
            "needsReauth": .bool(false),
            "tokenReady": .bool(false),
        ])

        XCTAssertEqual(snapshot.status, .authenticated)
        XCTAssertTrue(snapshot.needsReauth)
        XCTAssertFalse(snapshot.isVoiceTokenReady)
        XCTAssertTrue(snapshot.canLogout)
    }

    func testHandleGPTLoginCallbackCompletesPendingLoginThroughBridge() async throws {
        let service = makeService()
        service.isConnected = true
        var observedMethods: [String] = []
        var capturedCompleteParams: IncomingParamsObject?

        service.requestTransportOverride = { method, params in
            observedMethods.append(method)

            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/login/complete":
                capturedCompleteParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "ok": .bool(true),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        await service.handleGPTLoginCallbackURL(URL(string: "phodex://auth/gpt/callback?code=abc")!)

        XCTAssertTrue(observedMethods.contains("account/login/complete"))
        XCTAssertEqual(capturedCompleteParams?["loginId"]?.stringValue, "login-123")
        XCTAssertEqual(
            capturedCompleteParams?["callbackUrl"]?.stringValue,
            "phodex://auth/gpt/callback?code=abc"
        )
    }

    func testPersistedGPTAccountSnapshotRestoresOnInit() throws {
        let defaults = makeDefaults()
        let encoder = JSONEncoder()
        let snapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "persisted@example.com",
            displayName: nil,
            planType: "plus",
            loginInFlight: false,
            needsReauth: false,
            expiresAt: Date(timeIntervalSince1970: 1_742_000_000),
            updatedAt: .now
        )
        defaults.set(try encoder.encode(snapshot), forKey: "codex.gpt.accountSnapshot")

        let service = CodexService(defaults: defaults)

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.email, "persisted@example.com")
        XCTAssertEqual(service.gptAccountSnapshot.planType, "plus")
    }

    func testVoiceTranscriptionPreflightRejectsOversizedClips() {
        let preflight = CodexVoiceTranscriptionPreflight(
            byteCount: CodexVoiceTranscriptionPreflight.maxByteCount + 1,
            durationSeconds: 30
        )

        XCTAssertThrowsError(try preflight.validate()) { error in
            XCTAssertEqual(error.localizedDescription, "Voice clips must be smaller than 10 MB.")
        }
    }

    func testVoiceTranscriptionPreflightRejectsClipsLongerThan150Seconds() {
        let preflight = CodexVoiceTranscriptionPreflight(
            byteCount: 2_048,
            durationSeconds: 150.5
        )

        XCTAssertThrowsError(try preflight.validate()) { error in
            XCTAssertEqual(error.localizedDescription, "Voice clips must be 150 seconds or less.")
        }
    }

    func testVoiceTranscriptionPreflightRejectsEmptyDuration() {
        let preflight = CodexVoiceTranscriptionPreflight(
            byteCount: 2_048,
            durationSeconds: 0
        )

        XCTAssertThrowsError(try preflight.validate()) { error in
            XCTAssertEqual(error.localizedDescription, "Voice clips must include recorded audio.")
        }
    }

    func testVoiceTranscriptionReportsDisconnectedInsteadOfLoginWhenBridgeIsOffline() async {
        let service = makeService()
        service.isConnected = false
        service.gptAccountSnapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "voice@example.com",
            displayName: nil,
            planType: "plus",
            loginInFlight: false,
            needsReauth: false,
            expiresAt: nil,
            tokenReady: true,
            updatedAt: .now
        )

        await XCTAssertThrowsErrorAsync({
            try await service.transcribeVoiceAudioFile(
                at: URL(fileURLWithPath: "/tmp/remodex-voice-test.wav"),
                durationSeconds: 1
            )
        }) { error in
            XCTAssertEqual(error.localizedDescription, "Connect to your Mac before using voice transcription.")
        }
    }

    func testVoiceTranscriptionUsesBridgeOwnedTranscribeRequest() async throws {
        let service = makeService()
        service.isConnected = true
        let clipURL = try makeTemporaryVoiceClipURL()
        defer { try? FileManager.default.removeItem(at: clipURL) }
        let expectedAudio = makeTestWavData()

        var observedMethod: String?
        var observedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            observedMethod = method
            observedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "text": .string("transcribed on bridge"),
                ]),
                includeJSONRPC: false
            )
        }

        let transcript = try await service.transcribeVoiceAudioFile(at: clipURL, durationSeconds: 1.25)

        XCTAssertEqual(transcript, "transcribed on bridge")
        XCTAssertEqual(observedMethod, "voice/transcribe")
        let params = observedParams?.objectValue
        XCTAssertEqual(params?["mimeType"]?.stringValue, "audio/wav")
        XCTAssertEqual(params?["sampleRateHz"]?.intValue, 24_000)
        XCTAssertEqual(params?["durationMs"]?.intValue, 1_250)
        XCTAssertEqual(Data(base64Encoded: params?["audioBase64"]?.stringValue ?? "") ?? Data(), expectedAudio)
    }

    func testVoiceTranscriptionFallsBackToPhoneUploadWhenBridgeProviderRejectsAuth() async throws {
        let service = makeService()
        service.isConnected = true
        let clipURL = try makeTemporaryVoiceClipURL()
        defer {
            try? FileManager.default.removeItem(at: clipURL)
            GPTVoiceTranscriptionManager.transcribeOverride = nil
        }

        var observedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            observedMethods.append(method)
            if method == "voice/transcribe" {
                throw CodexServiceError.rpcError(
                    RPCError(
                        code: -32000,
                        message: "Your ChatGPT login has expired. Sign in again.",
                        data: .object([
                            "errorCode": .string("auth_rejected"),
                        ])
                    )
                )
            }

            XCTAssertEqual(method, "voice/resolveAuth")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "token": .string("Bearer fresh-chatgpt-token"),
                ]),
                includeJSONRPC: false
            )
        }

        GPTVoiceTranscriptionManager.transcribeOverride = { data, token in
            XCTAssertFalse(data.isEmpty)
            XCTAssertEqual(token, "fresh-chatgpt-token")
            return "legacy path works"
        }

        let transcript = try await service.transcribeVoiceAudioFile(at: clipURL, durationSeconds: 1)

        XCTAssertEqual(transcript, "legacy path works")
        XCTAssertEqual(observedMethods, ["voice/transcribe", "voice/resolveAuth"])
    }

    func testVoiceTranscriptionAuthRejectionMarksAccountAsExpired() async throws {
        let service = makeService()
        service.isConnected = true
        service.gptAccountSnapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "voice@example.com",
            displayName: nil,
            planType: "plus",
            loginInFlight: false,
            needsReauth: false,
            expiresAt: nil,
            tokenReady: true,
            updatedAt: .now
        )
        let clipURL = try makeTemporaryVoiceClipURL()
        defer { try? FileManager.default.removeItem(at: clipURL) }

        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.rpcError(
                RPCError(
                    code: -32000,
                    message: "Your ChatGPT login has expired. Sign in again.",
                    data: .object([
                        "errorCode": .string("auth_rejected"),
                    ])
                )
            )
        }

        await XCTAssertThrowsErrorAsync({
            try await service.transcribeVoiceAudioFile(at: clipURL, durationSeconds: 1)
        }) { error in
            XCTAssertEqual(service.classifyVoiceFailure(error), .providerAuthenticationRejected("Your ChatGPT login has expired. Sign in again."))
        }
        XCTAssertEqual(service.gptAccountSnapshot.status, .expired)
        XCTAssertTrue(service.gptAccountSnapshot.needsReauth)
    }

    func testVoiceTranscriptionAcceptsChunkedWAVBeforeBridgeUpload() async throws {
        let service = makeService()
        service.isConnected = true
        let expectedAudio = makeTestWavData(includeJunkChunk: true)
        let clipURL = try makeTemporaryVoiceClipURL(wavData: expectedAudio)
        defer { try? FileManager.default.removeItem(at: clipURL) }

        var observedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "voice/transcribe")
            observedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "text": .string("chunked wav works"),
                ]),
                includeJSONRPC: false
            )
        }

        let transcript = try await service.transcribeVoiceAudioFile(at: clipURL, durationSeconds: 0.25)

        XCTAssertEqual(transcript, "chunked wav works")
        XCTAssertEqual(Data(base64Encoded: observedParams?.objectValue?["audioBase64"]?.stringValue ?? "") ?? Data(), expectedAudio)
    }

    func testVoiceTranscriptionRejectsInvalidWAVBeforeCallingBridge() async throws {
        let service = makeService()
        service.isConnected = true
        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data("not a wav".utf8).write(to: clipURL)
        defer { try? FileManager.default.removeItem(at: clipURL) }

        var didCallBridge = false
        service.requestTransportOverride = { _, _ in
            didCallBridge = true
            throw CodexServiceError.disconnected
        }

        await XCTAssertThrowsErrorAsync({
            try await service.transcribeVoiceAudioFile(at: clipURL, durationSeconds: 1)
        }) { error in
            XCTAssertEqual(error.localizedDescription, "The recorded audio is not a valid WAV file.")
        }
        XCTAssertFalse(didCallBridge)
    }

    func testUnsupportedVoiceBridgeTranscribeMarksBridgeSessionAsUnsupported() {
        let service = makeService()
        let error = CodexServiceError.rpcError(
            RPCError(
                code: -32600,
                message: "Invalid request: unknown variant `voice/transcribe`, expected one of `initialize`, `thread/start`"
            )
        )

        XCTAssertTrue(service.consumeUnsupportedVoiceBridgeMethod(error))
        XCTAssertFalse(service.supportsBridgeVoiceTranscription)
        XCTAssertEqual(service.classifyVoiceFailure(error), .bridgeSessionUnsupported)
    }

    func testResolvedVoiceRecoveryClearsBannerOnceVoiceAuthIsHealthy() {
        let service = makeService()
        service.gptAccountSnapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "voice@example.com",
            displayName: nil,
            planType: "plus",
            loginInFlight: false,
            needsReauth: false,
            expiresAt: nil,
            tokenReady: true,
            updatedAt: .now
        )

        XCTAssertNil(service.resolveVoiceRecoveryReason(.voiceSyncInProgress))
        XCTAssertNil(service.resolveVoiceRecoveryReason(.macLoginRequired))
        XCTAssertNil(service.resolveVoiceRecoveryReason(.macReauthenticationRequired))
        XCTAssertEqual(
            service.resolveVoiceRecoveryReason(.providerAuthenticationRejected("Your ChatGPT login has expired.")),
            .providerAuthenticationRejected("Your ChatGPT login has expired.")
        )
    }

    func testVoiceProviderAuthRejectionIsNotHiddenByHealthyCachedAccountSnapshot() {
        let service = makeService()
        service.gptAccountSnapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "voice@example.com",
            displayName: nil,
            planType: "plus",
            loginInFlight: false,
            needsReauth: false,
            expiresAt: nil,
            tokenReady: true,
            updatedAt: .now
        )

        let error = CodexServiceError.rpcError(
            RPCError(
                code: -32000,
                message: "Your ChatGPT login has expired. Sign in again.",
                data: .object([
                    "errorCode": .string("auth_rejected"),
                ])
            )
        )

        let reason = service.classifyVoiceFailure(error)
        XCTAssertEqual(reason, .providerAuthenticationRejected("Your ChatGPT login has expired. Sign in again."))
        XCTAssertEqual(service.resolveVoiceRecoveryReason(reason), reason)
    }

    func testVoiceMissingTokenWhileAuthenticatedIsClassifiedAsSyncing() {
        let service = makeService()
        service.gptAccountSnapshot = CodexGPTAccountSnapshot(
            status: .authenticated,
            authMethod: .chatgpt,
            email: "voice@example.com",
            displayName: nil,
            planType: "plus",
            loginInFlight: false,
            needsReauth: false,
            expiresAt: nil,
            tokenReady: false,
            tokenUnavailableSince: .now,
            updatedAt: .now
        )

        let error = CodexServiceError.rpcError(
            RPCError(
                code: -32000,
                message: "No ChatGPT session token available. Sign in to ChatGPT on the Mac.",
                data: .object([
                    "errorCode": .string("token_missing"),
                ])
            )
        )

        XCTAssertEqual(service.classifyVoiceFailure(error), .voiceSyncInProgress)
    }

    func testVoiceAuthUnavailableIsClassifiedAsReconnectRequired() {
        let service = makeService()
        let error = CodexServiceError.rpcError(
            RPCError(
                code: -32000,
                message: "Could not read ChatGPT session from the Mac runtime. Is the bridge running?",
                data: .object([
                    "errorCode": .string("auth_unavailable"),
                ])
            )
        )

        XCTAssertEqual(service.classifyVoiceFailure(error), .reconnectRequired)
    }

    func testSuccessfulLoginKeepsPollingUntilVoiceTokenIsReady() async throws {
        let service = makeService()
        service.isConnected = true
        var accountStatusReadCount = 0

        service.requestTransportOverride = { method, params in
            switch method {
            case "account/login/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "type": .string("chatgpt"),
                        "loginId": .string("login-123"),
                        "authUrl": .string("https://example.com/login"),
                    ]),
                    includeJSONRPC: false
                )
            case "account/status/read":
                XCTAssertNil(params)
                accountStatusReadCount += 1
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "status": .string("authenticated"),
                        "authMethod": .string("chatgpt"),
                        "email": .string("voice@example.com"),
                        "planType": .string("pro"),
                        "loginInFlight": .bool(false),
                        "needsReauth": .bool(false),
                        "tokenReady": .bool(accountStatusReadCount >= 2),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                throw CodexServiceError.disconnected
            }
        }

        _ = try await service.startOrResumeGPTLogin()
        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "account/login/completed",
                params: .object([
                    "loginId": .string("login-123"),
                    "success": .bool(true),
                    "error": .null,
                ])
            )
        )

        await yieldMainActor(times: 3)

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.tokenReady, false)
        XCTAssertFalse(service.gptAccountSnapshot.needsReauth)
        XCTAssertNotNil(service.currentPendingGPTLogin())

        await service.refreshGPTAccountState()

        XCTAssertEqual(service.gptAccountSnapshot.status, .authenticated)
        XCTAssertEqual(service.gptAccountSnapshot.tokenReady, true)
        XCTAssertFalse(service.gptAccountSnapshot.needsReauth)
        XCTAssertNil(service.currentPendingGPTLogin())
    }

    private func makeService() -> CodexService {
        let service = CodexService(defaults: makeDefaults())
        Self.retainedServices.append(service)
        return service
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CodexGPTAccountTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func yieldMainActor(times: Int) async {
        for _ in 0..<times {
            await Task.yield()
        }
    }

    private func makeTemporaryVoiceClipURL(wavData: Data? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try (wavData ?? makeTestWavData()).write(to: url)
        return url
    }

    private func makeTestWavData(includeJunkChunk: Bool = false) -> Data {
        let sampleRate = 24_000
        let sampleCount = sampleRate / 4
        let pcmData = Data(repeating: 0, count: sampleCount * 2)
        let dataSize = UInt32(pcmData.count)

        var chunks = Data()
        if includeJunkChunk {
            chunks.append(contentsOf: "JUNK".utf8)
            chunks.appendLE(UInt32(4))
            chunks.append(contentsOf: [1, 2, 3, 4])
        }
        chunks.append(contentsOf: "fmt ".utf8)
        chunks.appendLE(UInt32(16))
        chunks.appendLE(UInt16(1))
        chunks.appendLE(UInt16(1))
        chunks.appendLE(UInt32(sampleRate))
        chunks.appendLE(UInt32(sampleRate * 2))
        chunks.appendLE(UInt16(2))
        chunks.appendLE(UInt16(16))
        chunks.append(contentsOf: "data".utf8)
        chunks.appendLE(dataSize)
        chunks.append(pcmData)

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE(UInt32(4 + chunks.count))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(chunks)
        return wav
    }

    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: () async throws -> T,
        _ errorHandler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected expression to throw")
        } catch {
            errorHandler(error)
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { rawBuffer in
            append(contentsOf: rawBuffer.bindMemory(to: UInt8.self))
        }
    }
}
