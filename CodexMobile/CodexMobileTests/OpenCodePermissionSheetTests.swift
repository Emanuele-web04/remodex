// FILE: OpenCodePermissionSheetTests.swift
// Purpose: Verifies OpenCode permission request redaction and model construction.

import XCTest
@testable import CodexMobile

@MainActor
final class OpenCodePermissionSheetTests: XCTestCase {
    func testArgsSummaryRedactsEnvValues() {
        let summary = OpenCodePermissionRequest.redactedArgsSummary(from: "PATH=/bin\nAPI_KEY=secret\nnote=ok")
        XCTAssertTrue(summary.contains("API_KEY=***"))
        XCTAssertTrue(summary.contains("PATH=***"))
        XCTAssertTrue(summary.contains("note=ok"))
    }

    func testArgsSummaryRedactsSensitiveKeys() {
        let summary = OpenCodePermissionRequest.redactedArgsSummary(from: "command=rm -rf /\nscript=evil.sh\nnote=ok")
        XCTAssertTrue(summary.contains("command=***"))
        XCTAssertTrue(summary.contains("script=***"))
        XCTAssertTrue(summary.contains("note=ok"))
    }

    func testBuildUsesBridgeArgsSummaryWithoutRebuilding() {
        let request = OpenCodePermissionRequest.build(
            permissionId: "perm-1",
            threadId: "thread-1",
            turnId: "turn-1",
            sessionId: "ses-1",
            tool: "bash",
            args: ["command": .string("npm test")],
            argsSummary: "command=***\nnote=ok",
            cwd: nil
        )

        XCTAssertEqual(request?.argsSummary, "command=***\nnote=ok")
    }

    func testArgsSummaryTruncatesLongPayload() {
        let long = String(repeating: "a", count: 600)
        let summary = OpenCodePermissionRequest.redactedArgsSummary(from: long)
        XCTAssertLessThanOrEqual(summary.count, 520)
        XCTAssertTrue(summary.contains("truncated"))
    }

    func testBuildPermissionRequestFromParams() {
        let request = OpenCodePermissionRequest.build(
            permissionId: "perm-1",
            threadId: "thread-1",
            turnId: "turn-1",
            sessionId: "ses-1",
            tool: "bash",
            args: ["command": .string("npm test")],
            cwd: "/Users/me/project"
        )

        XCTAssertEqual(request?.permissionId, "perm-1")
        XCTAssertEqual(request?.tool, "bash")
        XCTAssertEqual(request?.cwd, "/Users/me/project")
    }

    func testBuildRejectsMissingPermissionId() {
        let request = OpenCodePermissionRequest.build(
            permissionId: " ",
            threadId: "thread-1",
            turnId: nil,
            sessionId: nil,
            tool: "bash",
            args: nil,
            cwd: nil
        )
        XCTAssertNil(request)
    }

    func testBuildRejectsMissingThreadId() {
        let request = OpenCodePermissionRequest.build(
            permissionId: "perm-1",
            threadId: "",
            turnId: nil,
            sessionId: nil,
            tool: "bash",
            args: nil,
            cwd: nil
        )
        XCTAssertNil(request)
    }

    func testBuildRejectsMissingTool() {
        let request = OpenCodePermissionRequest.build(
            permissionId: "perm-1",
            threadId: "thread-1",
            turnId: nil,
            sessionId: nil,
            tool: " ",
            args: nil,
            cwd: nil
        )
        XCTAssertNil(request)
    }
}