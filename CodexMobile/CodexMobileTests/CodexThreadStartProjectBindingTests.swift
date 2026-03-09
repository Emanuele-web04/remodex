// FILE: CodexThreadStartProjectBindingTests.swift
// Purpose: Verifies thread/start project binding params and cwd fallback behavior.
// Layer: Unit Test
// Exports: CodexThreadStartProjectBindingTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class CodexThreadStartProjectBindingTests: XCTestCase {
    func testMakeThreadStartParamsIncludesModelAndCwd() {
        let params = CodexThreadStartProjectBinding.makeThreadStartParams(
            modelIdentifier: "gpt-5",
            preferredProjectPath: "/Users/me/work/project"
        )

        XCTAssertEqual(params["model"]?.stringValue, "gpt-5")
        XCTAssertEqual(params["cwd"]?.stringValue, "/Users/me/work/project")
    }

    func testMakeThreadStartParamsSkipsEmptyCwd() {
        let normalized = CodexThreadStartProjectBinding.normalizedProjectPath("   ")
        let params = CodexThreadStartProjectBinding.makeThreadStartParams(
            modelIdentifier: nil,
            preferredProjectPath: normalized
        )

        XCTAssertNil(params["cwd"])
        XCTAssertTrue(params.isEmpty)
    }

    func testApplyFallbackSetsCwdWhenMissingInResponse() {
        let responseThread = CodexThread(id: "thread-1", cwd: nil)
        let patched = CodexThreadStartProjectBinding.applyPreferredProjectFallback(
            to: responseThread,
            preferredProjectPath: "/Users/me/work/project"
        )

        XCTAssertEqual(patched.cwd, "/Users/me/work/project")
    }

    func testApplyFallbackDoesNotOverrideExistingCwd() {
        let responseThread = CodexThread(id: "thread-1", cwd: "/server/path")
        let patched = CodexThreadStartProjectBinding.applyPreferredProjectFallback(
            to: responseThread,
            preferredProjectPath: "/Users/me/work/project"
        )

        XCTAssertEqual(patched.cwd, "/server/path")
    }

    func testGitWorkingDirectoryReturnsNormalizedThreadPath() {
        let thread = CodexThread(id: "thread-1", cwd: "/Users/me/work/project///")

        XCTAssertEqual(thread.gitWorkingDirectory, "/Users/me/work/project")
    }

    func testGitWorkingDirectoryIsNilForUnboundThread() {
        let thread = CodexThread(id: "thread-1", cwd: "   ")

        XCTAssertNil(thread.gitWorkingDirectory)
    }
}
