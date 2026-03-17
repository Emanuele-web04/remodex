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
            preferredProjectPath: "/Users/me/work/project",
            serviceTier: "fast"
        )

        XCTAssertEqual(params["model"]?.stringValue, "gpt-5")
        XCTAssertEqual(params["cwd"]?.stringValue, "/Users/me/work/project")
        XCTAssertEqual(params["serviceTier"]?.stringValue, "fast")
    }

    func testMakeThreadStartParamsSkipsEmptyCwd() {
        let normalized = CodexThreadStartProjectBinding.normalizedProjectPath("   ")
        let params = CodexThreadStartProjectBinding.makeThreadStartParams(
            modelIdentifier: nil,
            preferredProjectPath: normalized,
            serviceTier: nil
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

    func testAgentDisplayLabelCombinesNicknameAndRole() {
        let thread = CodexThread(
            id: "thread-agent",
            agentNickname: "Locke",
            agentRole: "explorer"
        )

        XCTAssertEqual(thread.agentDisplayLabel, "Locke [explorer]")
    }

    func testDisplayTitlePrefersAgentLabelOverGenericConversation() {
        let thread = CodexThread(
            id: "thread-agent",
            title: "Conversation",
            parentThreadId: "parent-thread",
            agentNickname: "Locke",
            agentRole: "explorer"
        )

        XCTAssertEqual(thread.displayTitle, "Locke [explorer]")
    }

    func testModelDisplayLabelPrefersProviderName() {
        let thread = CodexThread(
            id: "thread-agent",
            model: "gpt-5.4",
            modelProvider: "gpt-5.4-mini"
        )

        XCTAssertEqual(thread.modelDisplayLabel, "gpt-5.4-mini")
    }

    func testAgentDisplayLabelIgnoresCollabToolItemTypeNoise() throws {
        let payload = """
        {
          "id": "thread-agent",
          "metadata": {
            "agentNickname": "Locke",
            "type": "collabAgentToolCall",
            "agentRole": "explorer"
          }
        }
        """.data(using: .utf8)!

        let thread = try JSONDecoder().decode(CodexThread.self, from: payload)

        XCTAssertEqual(thread.agentDisplayLabel, "Locke [explorer]")
    }
}
