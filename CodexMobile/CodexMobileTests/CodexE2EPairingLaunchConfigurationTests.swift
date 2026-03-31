// FILE: CodexE2EPairingLaunchConfigurationTests.swift
// Purpose: Verifies simulator-only E2E pairing launch-arg and env resolution.
// Layer: Unit Test

import XCTest
@testable import CodexMobile

final class CodexE2EPairingLaunchConfigurationTests: XCTestCase {
    func testResolveReturnsDisabledWithoutBypassFlagEvenWithEnvJSON() {
        let json = """
        {"v":\(codexPairingQRVersion),"relay":"wss://x","sessionId":"s","macDeviceId":"m","macIdentityPublicKey":"k","expiresAt":\(9_000_000_000_000)}
        """
        let result = CodexE2EPairingLaunchConfiguration.resolve(
            arguments: [],
            environment: ["CODEX_E2E_PAIRING_JSON": json]
        )
        XCTAssertFalse(result.isPairingBypassActive)
        XCTAssertNil(result.resolvedPairingJSON)
    }

    func testResolveDisablesBypassOnDevice() {
        let json = "{\"v\":3,\"relay\":\"wss://r\",\"sessionId\":\"sid\",\"macDeviceId\":\"m\",\"macIdentityPublicKey\":\"k\",\"expiresAt\":\(9_000_000_000_000)}"
        let result = CodexE2EPairingLaunchConfiguration.resolve(
            arguments: ["-CodexE2EPairingBypass"],
            environment: ["CODEX_E2E_PAIRING_JSON": json]
        )
#if !targetEnvironment(simulator)
        XCTAssertFalse(result.isPairingBypassActive)
        XCTAssertNil(result.resolvedPairingJSON)
#else
        XCTAssertTrue(result.isPairingBypassActive)
        XCTAssertEqual(result.resolvedPairingJSON, json)
#endif
    }

    func testResolvePrefersJSONOverFile() throws {
        let json = #"{"v":3,"preferred":true}"#
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-e2e-pairing-test-\(UUID().uuidString).json")
        try #"{"v":3,"preferred":false}"#.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let result = CodexE2EPairingLaunchConfiguration.resolve(
            arguments: ["-CodexE2EPairingBypass"],
            environment: [
                "CODEX_E2E_PAIRING_JSON": json,
                "CODEX_E2E_PAIRING_FILE": temp.path,
            ]
        )
#if targetEnvironment(simulator)
        XCTAssertEqual(result.resolvedPairingJSON, json)
#else
        XCTAssertNil(result.resolvedPairingJSON)
#endif
    }

    func testResolveReadsFileWhenJSONMissing() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-e2e-pairing-file-\(UUID().uuidString).json")
        let contents = #"{"v":3,"from":"file"}"#
        try contents.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        let result = CodexE2EPairingLaunchConfiguration.resolve(
            arguments: ["-CodexE2EPairingBypass"],
            environment: ["CODEX_E2E_PAIRING_FILE": temp.path]
        )
#if targetEnvironment(simulator)
        XCTAssertTrue(result.isPairingBypassActive)
        XCTAssertEqual(result.resolvedPairingJSON, contents)
#else
        XCTAssertFalse(result.isPairingBypassActive)
        XCTAssertNil(result.resolvedPairingJSON)
#endif
    }

    func testResolveActiveWithFlagButNoPayload() {
        let result = CodexE2EPairingLaunchConfiguration.resolve(
            arguments: ["-CodexE2EPairingBypass"],
            environment: [:]
        )
#if targetEnvironment(simulator)
        XCTAssertTrue(result.isPairingBypassActive)
#else
        XCTAssertFalse(result.isPairingBypassActive)
#endif
        XCTAssertNil(result.resolvedPairingJSON)
    }

    func testTestingHelperBypassesRuntimeChecks() {
        let json = #"{"x":1}"#
        let result = CodexE2EPairingLaunchConfiguration.testing(pairingBypassActive: true, pairingJSON: json)
        XCTAssertTrue(result.isPairingBypassActive)
        XCTAssertEqual(result.resolvedPairingJSON, json)
    }
}
