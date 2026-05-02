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

    func testWakeDisplayRequiresSavedPairWhenDisconnected() async {
        let service = makeService()
        let handoff = DesktopHandoffService(codex: service)

        do {
            try await handoff.wakeDisplay()
            XCTFail("Expected wakeDisplay to fail without a saved pair")
        } catch let error as DesktopHandoffError {
            XCTAssertEqual(
                error.errorDescription,
                "Reconnect to your paired computer first."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

    private func makeService() -> CodexService {
        let suiteName = "DesktopHandoffServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return CodexService(defaults: defaults)
    }
}
