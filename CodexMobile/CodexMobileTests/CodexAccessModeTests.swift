// FILE: CodexAccessModeTests.swift
// Purpose: Guards the runtime access-mode strings used by fork/send fallbacks.
// Layer: Unit Test
// Exports: CodexAccessModeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class CodexAccessModeTests: XCTestCase {
    func testSandboxLegacyValuesMatchRuntimeEnums() {
        XCTAssertEqual(CodexAccessMode.onRequest.sandboxLegacyValue, "workspace-write")
        XCTAssertEqual(CodexAccessMode.autoReview.sandboxLegacyValue, "workspace-write")
        XCTAssertEqual(CodexAccessMode.fullAccess.sandboxLegacyValue, "danger-full-access")
    }

    func testAutoReviewKeepsOnRequestApprovalPolicy() {
        XCTAssertEqual(CodexAccessMode.autoReview.approvalPolicyCandidates, ["on-request", "onRequest"])
    }

    func testApprovalReviewersMatchAccessModeIntent() {
        XCTAssertEqual(CodexAccessMode.onRequest.approvalsReviewerCandidates, ["user", nil])
        XCTAssertEqual(
            CodexAccessMode.autoReview.approvalsReviewerCandidates,
            ["auto_review", "guardian_subagent"]
        )
        XCTAssertEqual(CodexAccessMode.fullAccess.approvalsReviewerCandidates, ["user", nil])
    }
}
