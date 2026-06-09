// FILE: ProviderCapabilitiesDecodeTests.swift
// Purpose: Verifies conservative decode defaults for optional capability flags.
// Layer: Unit Test
// Exports: ProviderCapabilitiesDecodeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class ProviderCapabilitiesDecodeTests: XCTestCase {
    func testMissingDesktopHandoffAndMCPEvaluateToFalse() throws {
        let json = """
        {
          "supportsAgentSelection": true,
          "supportsReasoningEffort": false,
          "supportsFastMode": false,
          "supportsPlanMode": false,
          "supportsStreamingTools": true,
          "supportsApprovals": true,
          "supportsFork": true,
          "supportsVoice": false,
          "supportsSlashCommands": true,
          "supportsWorktree": false,
          "supportsSkillAutocomplete": true,
          "supportsSteer": false,
          "supportsQueue": true
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let capabilities = try JSONDecoder().decode(ProviderCapabilities.self, from: data)

        XCTAssertFalse(capabilities.supportsDesktopHandoff)
        XCTAssertFalse(capabilities.supportsMCP)
        XCTAssertFalse(capabilities.supportsSlashCommandExecute)
    }

    func testMissingSupportsSlashCommandExecuteDefaultsToFalse() throws {
        let json = """
        {
          "supportsAgentSelection": true,
          "supportsReasoningEffort": false,
          "supportsFastMode": false,
          "supportsPlanMode": false,
          "supportsStreamingTools": true,
          "supportsApprovals": true,
          "supportsFork": true,
          "supportsVoice": false,
          "supportsSlashCommands": true,
          "supportsWorktree": false,
          "supportsSkillAutocomplete": true,
          "supportsSteer": false,
          "supportsQueue": true
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let capabilities = try JSONDecoder().decode(ProviderCapabilities.self, from: data)

        XCTAssertFalse(capabilities.supportsSlashCommandExecute)
    }

    func testMissingCapabilityFlagsDefaultToFalse() throws {
        let json = """
        {
          "supportsAgentSelection": true,
          "supportsReasoningEffort": false,
          "supportsPlanMode": false,
          "supportsVoice": false,
          "supportsDesktopHandoff": false,
          "supportsMCP": false,
          "supportsWorktree": false,
          "supportsSkillAutocomplete": true,
          "supportsSteer": false
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let capabilities = try JSONDecoder().decode(ProviderCapabilities.self, from: data)

        XCTAssertFalse(capabilities.supportsFastMode)
        XCTAssertFalse(capabilities.supportsStreamingTools)
        XCTAssertFalse(capabilities.supportsApprovals)
        XCTAssertFalse(capabilities.supportsFork)
        XCTAssertFalse(capabilities.supportsSlashCommands)
        XCTAssertFalse(capabilities.supportsQueue)
        XCTAssertFalse(capabilities.supportsAccessMode)
    }
}
