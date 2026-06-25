// FILE: DesktopHandoffServiceTests.swift
// Purpose: Verifies desktop handoff and display-wake requests use the bridge RPC contract.
// Layer: Unit Test
// Exports: DesktopHandoffServiceTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class DesktopHandoffServiceTests: XCTestCase {
    func testContinueOnDesktopUsesPlatformNeutralBridgeMethod() async throws {
        let service = makeService()
        var capturedMethod: String?
        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            capturedMethod = method
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["success": .bool(true)]),
                includeJSONRPC: false
            )
        }

        let handoff = DesktopHandoffService(codex: service)
        try await handoff.continueOnDesktopApp(threadId: " thread-123 ")

        XCTAssertEqual(capturedMethod, "desktop/continueOnDesktop")
        XCTAssertEqual(capturedParams?.objectValue?["threadId"]?.stringValue, "thread-123")
    }

    func testWakeDisplayUsesCurrentBridgeConnectionWhenAvailable() async throws {
        let service = makeService()
        service.isConnected = true

        var capturedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            capturedMethods.append(method)
            XCTAssertEqual(params?.objectValue?.isEmpty, true)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["success": .bool(true)]),
                includeJSONRPC: false
            )
        }

        let handoff = DesktopHandoffService(codex: service)
        try await handoff.wakeDisplay()

        XCTAssertEqual(capturedMethods, ["desktop/wakeDisplay"])
    }

    func testWakeDisplayUsesSavedSessionWhenDisconnected() async throws {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "ws://macbook-pro-di-emanuele.local:8080/ws"
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: Data(repeating: 19, count: 32).base64EncodedString(),
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.relayUrl = relayURL
        service.relaySessionId = "session-123"
        service.relayMacDeviceId = macDeviceID

        var capturedURL: String?
        var capturedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            capturedMethods.append(method)
            XCTAssertEqual(params?.objectValue?.isEmpty, true)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["success": .bool(true)]),
                includeJSONRPC: false
            )
        }
        let handoff = DesktopHandoffService(
            codex: service,
            savedPairConnector: { reconnectURL in
                capturedURL = reconnectURL
            }
        )

        try await handoff.wakeDisplay()

        XCTAssertEqual(
            capturedURL,
            "ws://macbook-pro-di-emanuele.local:8080/ws/session-123"
        )
        XCTAssertEqual(capturedMethods, ["desktop/wakeDisplay"])
    }

    func testWakeDisplayFallsBackToSavedSessionWhenTrustedResolveReportsRePairRequired() async throws {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "ws://macbook-pro-di-emanuele.local:8080/ws"
        let macPublicKey = Data(repeating: 21, count: 32).base64EncodedString()
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.lastTrustedMacDeviceId = macDeviceID
        service.relayUrl = relayURL
        service.relaySessionId = "session-123"
        service.relayMacDeviceId = macDeviceID
        service.relayMacIdentityPublicKey = macPublicKey
        service.secureConnectionState = .rePairRequired
        service.lastErrorMessage = "This iPhone is no longer trusted by the paired computer."
        service.trustedSessionResolverOverride = {
            throw CodexTrustedSessionResolveError.rePairRequired("Resolve says this phone is not trusted.")
        }

        var capturedURL: String?
        service.requestTransportOverride = { _, _ in
            RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["success": .bool(true)]),
                includeJSONRPC: false
            )
        }
        let handoff = DesktopHandoffService(
            codex: service,
            savedPairConnector: { reconnectURL in
                capturedURL = reconnectURL
            }
        )

        try await handoff.wakeDisplay()

        XCTAssertEqual(
            capturedURL,
            "ws://macbook-pro-di-emanuele.local:8080/ws/session-123"
        )
        XCTAssertEqual(service.secureConnectionState, .trustedMac)
        XCTAssertNil(service.lastErrorMessage)
    }

    func testWakeDisplayCanResolveTrustedSessionWithoutSavedLiveSession() async throws {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let relayURL = "ws://macbook-pro-di-emanuele.local:8080/ws"
        let macPublicKey = Data(repeating: 22, count: 32).base64EncodedString()
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date(),
            relayURL: relayURL
        )
        service.setCurrentTrustedMacDeviceId(macDeviceID)
        service.trustedSessionResolverOverride = {
            CodexTrustedSessionResolveResponse(
                ok: true,
                macDeviceId: macDeviceID,
                macIdentityPublicKey: macPublicKey,
                displayName: "MacBook",
                sessionId: "fresh-session"
            )
        }

        var capturedURL: String?
        var capturedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            capturedMethods.append(method)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["success": .bool(true)]),
                includeJSONRPC: false
            )
        }
        let handoff = DesktopHandoffService(
            codex: service,
            savedPairConnector: { reconnectURL in
                capturedURL = reconnectURL
            }
        )

        try await handoff.wakeDisplay()

        XCTAssertEqual(capturedURL, "\(relayURL)/fresh-session")
        XCTAssertEqual(capturedMethods, ["desktop/wakeDisplay"])
    }

    func testWakeDisplayRequiresSavedPairWhenDisconnected() async {
        let service = makeService()
        let handoff = DesktopHandoffService(codex: service)

        do {
            try await handoff.wakeDisplay()
            XCTFail("Expected wakeDisplay to fail without a saved pair")
        } catch let error as DesktopHandoffError {
            XCTAssertEqual(
                error.errorDescription,
                "Reconnect to your paired device first."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOpenCodeHandoffParamsEncodeOptionalFields() {
        let params = OpenCodeDesktopHandoffParams.normalized(
            threadId: " thread-abc ",
            sessionId: " ses_123 ",
            directory: " /tmp/proj "
        )
        XCTAssertNotNil(params)
        let object = params?.makeJSONValue().objectValue
        XCTAssertEqual(object?["threadId"]?.stringValue, "thread-abc")
        XCTAssertEqual(object?["sessionId"]?.stringValue, "ses_123")
        XCTAssertEqual(object?["directory"]?.stringValue, "/tmp/proj")
    }

    func testOpenCodeHandoffParamsOmitEmptyOptionals() {
        let params = OpenCodeDesktopHandoffParams.normalized(threadId: "thread-abc")
        let object = params?.makeJSONValue().objectValue
        XCTAssertEqual(object?["threadId"]?.stringValue, "thread-abc")
        XCTAssertNil(object?["sessionId"])
        XCTAssertNil(object?["directory"])
    }

    func testOpenCodeHandoffResultDecodesBridgePayload() {
        let result = OpenCodeDesktopHandoffResult(
            from: [
                "success": .bool(true),
                "threadId": .string("thread-1"),
                "sessionId": .string("ses_abc"),
                "cwd": .string("/tmp"),
                "model": .string("openai/gpt-5"),
                "agent": .string("build"),
                "title": .string("Fix"),
                "handoffMode": .string("tui"),
                "sessionSelected": .bool(true),
                "desktopAppInstalled": .bool(true),
                "instructions": .string("Session selected in OpenCode TUI."),
            ]
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.handoffMode, "tui")
        XCTAssertEqual(result.userFacingSummary, "Session selected in OpenCode TUI.")
    }

    func testContinueOnDesktopOpenCodeUsesBridgeMethod() async throws {
        let service = makeService()
        var capturedMethod: String?
        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            capturedMethod = method
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "success": .bool(true),
                    "threadId": .string("thread-1"),
                    "sessionId": .string("ses_abc"),
                    "handoffMode": .string("tui"),
                    "sessionSelected": .bool(true),
                    "instructions": .string("Done"),
                ]),
                includeJSONRPC: false
            )
        }

        let handoff = DesktopHandoffService(codex: service)
        let result = try await handoff.continueOnDesktopOpenCode(
            threadId: "thread-1",
            sessionId: "ses_abc",
            directory: "/tmp/proj"
        )

        XCTAssertEqual(capturedMethod, "desktop/continueOpenCode")
        XCTAssertEqual(capturedParams?.objectValue?["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(capturedParams?.objectValue?["sessionId"]?.stringValue, "ses_abc")
        XCTAssertEqual(capturedParams?.objectValue?["directory"]?.stringValue, "/tmp/proj")
        XCTAssertEqual(result.handoffMode, "tui")
    }

    func testContinueOnDesktopRoutesOpenCodeProviderToOpenCodeRPC() async throws {
        let service = makeService()
        var capturedMethod: String?
        service.requestTransportOverride = { method, _ in
            capturedMethod = method
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "success": .bool(true),
                    "handoffMode": .string("desktop_app"),
                    "instructions": .string("Opened"),
                ]),
                includeJSONRPC: false
            )
        }

        let handoff = DesktopHandoffService(codex: service)
        let result = try await handoff.continueOnDesktop(
            threadId: "thread-1",
            modelProvider: "opencode",
            directory: "/tmp"
        )

        XCTAssertEqual(capturedMethod, "desktop/continueOpenCode")
        XCTAssertEqual(result?.handoffMode, "desktop_app")
    }

    func testContinueOnDesktopRoutesCodexProviderToCodexRPC() async throws {
        let service = makeService()
        var capturedMethod: String?
        service.requestTransportOverride = { method, _ in
            capturedMethod = method
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["success": .bool(true)]),
                includeJSONRPC: false
            )
        }

        let handoff = DesktopHandoffService(codex: service)
        let result = try await handoff.continueOnDesktop(
            threadId: "thread-1",
            modelProvider: "codex"
        )

        XCTAssertEqual(capturedMethod, "desktop/continueOnDesktop")
        XCTAssertNil(result)
    }

    func testUnsupportedPlatformMessageIsPlatformNeutral() {
        let error = DesktopHandoffError.bridgeError(
            code: "unsupported_platform",
            message: "Unsupported platform"
        )

        XCTAssertEqual(
            error.errorDescription,
            "Desktop app handoff works only when the bridge is running on a supported desktop platform."
        )
    }

    func testDesktopHandoffVisibilityUsesCapabilityNotProviderIdentity() {
        let service = makeService()
        service.availableRuntimes = [
            RuntimeInfo(
                id: "codex",
                label: "Codex",
                enabled: true,
                unavailableReason: nil,
                reasonCode: nil,
                showsBetaLabel: false,
                capabilities: .defaultCodex,
                agents: []
            ),
        ]
        service.availableModels = [
            CodexModelOption(
                id: "gpt-5",
                model: "gpt-5",
                modelProvider: "codex",
                displayName: "GPT-5",
                description: "",
                capabilities: .defaultCodex
            ),
        ]
        service.upsertThread(
            CodexThread(id: "thread-codex-handoff", title: "Codex", modelProvider: "codex")
        )

        XCTAssertTrue(service.supportsDesktopHandoffForTurn(threadId: "thread-codex-handoff"))
    }

    func testDesktopHandoffActionUnavailableWhenHandoffEnvDisabled() {
        let service = makeService()
        service.availableRuntimes = [
            RuntimeInfo(
                id: "opencode",
                label: "OpenCode",
                enabled: true,
                unavailableReason: nil,
                reasonCode: nil,
                showsBetaLabel: true,
                capabilities: handoffCapabilities(),
                agents: [],
                opencode: OpenCodeRuntimeDetails(
                    enabled: true,
                    serveUrl: nil,
                    version: "1.0.0",
                    minVersion: nil,
                    versionBelowMinimum: false,
                    sessionCount: 1,
                    lastError: nil,
                    command: nil,
                    handoffEnvEnabled: false,
                    authConfigured: true,
                    connectedProviders: nil,
                    providerInventory: nil,
                    providerDiscoveryReasonCode: nil
                )
            ),
        ]
        service.availableModels = [
            CodexModelOption(
                id: "openai/gpt-5.5",
                model: "openai/gpt-5.5",
                modelProvider: "opencode",
                displayName: "GPT-5.5",
                description: "",
                capabilities: handoffCapabilities()
            ),
        ]
        service.upsertThread(
            CodexThread(
                id: "thread-opencode-handoff-env-off",
                title: "OpenCode",
                modelProvider: "opencode"
            )
        )

        XCTAssertTrue(service.supportsDesktopHandoffForTurn(threadId: "thread-opencode-handoff-env-off"))
        XCTAssertFalse(service.isDesktopHandoffActionAvailable(forThreadId: "thread-opencode-handoff-env-off"))
    }

    func testDesktopHandoffActionAvailableWhenHandoffEnvEnabled() {
        let service = makeService()
        service.availableRuntimes = [
            RuntimeInfo(
                id: "opencode",
                label: "OpenCode",
                enabled: true,
                unavailableReason: nil,
                reasonCode: nil,
                showsBetaLabel: true,
                capabilities: handoffCapabilities(),
                agents: [],
                opencode: OpenCodeRuntimeDetails(
                    enabled: true,
                    serveUrl: nil,
                    version: "1.0.0",
                    minVersion: nil,
                    versionBelowMinimum: false,
                    sessionCount: 1,
                    lastError: nil,
                    command: nil,
                    handoffEnvEnabled: true,
                    authConfigured: true,
                    connectedProviders: nil,
                    providerInventory: nil,
                    providerDiscoveryReasonCode: nil
                )
            ),
        ]
        service.availableModels = [
            CodexModelOption(
                id: "openai/gpt-5.5",
                model: "openai/gpt-5.5",
                modelProvider: "opencode",
                displayName: "GPT-5.5",
                description: "",
                capabilities: handoffCapabilities()
            ),
        ]
        service.upsertThread(
            CodexThread(
                id: "thread-opencode-handoff-env-on",
                title: "OpenCode",
                modelProvider: "opencode"
            )
        )

        XCTAssertTrue(service.isDesktopHandoffActionAvailable(forThreadId: "thread-opencode-handoff-env-on"))
    }

    private func handoffCapabilities() -> ProviderCapabilities {
        ProviderCapabilities(
            supportsAgentSelection: true,
            supportsReasoningEffort: false,
            supportsFastMode: false,
            supportsPlanMode: false,
            supportsStreamingTools: true,
            supportsApprovals: true,
            supportsFork: true,
            supportsVoice: false,
            supportsDesktopHandoff: true,
            supportsSlashCommands: true,
            supportsSlashCommandExecute: true,
            supportsMCP: false,
            supportsWorktree: false,
            supportsSkillAutocomplete: true,
            supportsStructuredSkillInput: false,
            supportsSkillFileInjection: true,
            supportsImageAttachments: true,
            supportsSteer: false,
            supportsQueue: true
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "DesktopHandoffServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return CodexService(defaults: defaults)
    }
}
