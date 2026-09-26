// FILE: CodexThreadProvenanceTests.swift
// Purpose: Verifies that thread provenance (fork origin, session source) survives decoding
//          in every shape the bridge can send it, and maps to the sidebar's source label.
// Layer: Unit Test
// Exports: CodexThreadProvenanceTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class CodexThreadProvenanceTests: XCTestCase {
    func testDecodesThreadSourceFromCamelCaseSnakeCaseAndMetadata() throws {
        let camelCase = try decodeThread(#"{"id":"t1","threadSource":"pull_request_fix_automation"}"#)
        XCTAssertEqual(camelCase.threadSource, "pull_request_fix_automation")

        let snakeCase = try decodeThread(#"{"id":"t2","thread_source":"automation"}"#)
        XCTAssertEqual(snakeCase.threadSource, "automation")

        let metadata = try decodeThread(#"{"id":"t3","metadata":{"thread_source":"user"}}"#)
        XCTAssertEqual(metadata.threadSource, "user")

        let absent = try decodeThread(#"{"id":"t4"}"#)
        XCTAssertNil(absent.threadSource)
    }

    func testThreadSourceSurvivesEncodeDecodeRoundTrip() throws {
        let thread = CodexThread(id: "t5", threadSource: "pull_request_fix_automation")
        let encoded = try JSONEncoder().encode(thread)
        let decoded = try JSONDecoder().decode(CodexThread.self, from: encoded)

        XCTAssertEqual(decoded.threadSource, "pull_request_fix_automation")
    }

    func testCanonicalProjectPresenceSurvivesNullAndAssignedRoundTrips() throws {
        for json in [
            #"{"id":"unassigned","projectId":null}"#,
            #"{"id":"assigned","projectId":"project-1"}"#,
        ] {
            let decoded = try decodeThread(json)
            XCTAssertTrue(decoded.hasCanonicalProjectId)

            let encoded = try JSONEncoder().encode(decoded)
            let roundTripped = try JSONDecoder().decode(CodexThread.self, from: encoded)
            XCTAssertEqual(roundTripped.projectId, decoded.projectId)
            XCTAssertTrue(roundTripped.hasCanonicalProjectId)
        }

        XCTAssertFalse(try decodeThread(#"{"id":"legacy"}"#).hasCanonicalProjectId)
    }

    func testAutomationSourceOnlyMarksAutomationSessions() throws {
        XCTAssertEqual(CodexThread(id: "t6", threadSource: "pull_request_fix_automation").automationSource, .pullRequestFix)
        // Scheduled runs render as the clock glyph, so only the accessible spelling is text.
        XCTAssertEqual(CodexThread(id: "t7", threadSource: "automation").automationSource, .scheduled)
        XCTAssertEqual(CodexThreadAutomationSource.scheduled.accessibilityDescription, "Started by automation")
        XCTAssertNil(CodexThread(id: "t8", threadSource: "user").automationSource)
        XCTAssertNil(CodexThread(id: "t9", threadSource: "realtime_voice").automationSource)
        XCTAssertNil(CodexThread(id: "t10").automationSource)
    }

    private func decodeThread(_ json: String) throws -> CodexThread {
        try JSONDecoder().decode(CodexThread.self, from: Data(json.utf8))
    }
}
