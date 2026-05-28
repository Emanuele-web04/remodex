// FILE: CodexThreadGitControlScopeTests.swift
// Purpose: Verifies live repo write controls stay visible for every repo-bound root chat.
// Layer: Unit Test
// Exports: CodexThreadGitControlScopeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class CodexThreadGitControlScopeTests: XCTestCase {
    func testAllRootThreadsCanShowGitControlsForSharedWorkingDirectory() {
        let older = CodexThread(
            id: "old",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            cwd: "/repo"
        )
        let newer = CodexThread(
            id: "new",
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 400),
            cwd: "/repo"
        )

        XCTAssertTrue(
            CodexThread.gitControlsVisible(
                for: older,
                workingDirectory: "/repo",
                isConnected: true
            )
        )
        XCTAssertTrue(
            CodexThread.gitControlsVisible(
                for: newer,
                workingDirectory: "/repo",
                isConnected: true
            )
        )
    }

    func testGitControlsVisibilityDoesNotDependOnThreadListHydration() {
        let thread = CodexThread(
            id: "thread",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            cwd: "/repo"
        )

        XCTAssertTrue(
            CodexThread.gitControlsVisible(
                for: thread,
                workingDirectory: "/repo",
                isConnected: true
            )
        )
    }

    func testSubagentThreadsDoNotShowRootThreadGitControls() {
        let root = CodexThread(
            id: "root",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            cwd: "/repo"
        )
        let subagent = CodexThread(
            id: "subagent",
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 400),
            cwd: "/repo",
            parentThreadId: "root"
        )

        XCTAssertTrue(
            CodexThread.gitControlsVisible(
                for: root,
                workingDirectory: "/repo",
                isConnected: true
            )
        )
        XCTAssertFalse(
            CodexThread.gitControlsVisible(
                for: subagent,
                workingDirectory: "/repo",
                isConnected: true
            )
        )
    }

    func testGitControlsVisibilityRequiresConnectedLiveRootThreadWithWorkingDirectory() {
        let thread = CodexThread(
            id: "thread",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            cwd: "/repo"
        )

        XCTAssertTrue(
            CodexThread.gitControlsVisible(
                for: thread,
                workingDirectory: "/repo",
                isConnected: true
            )
        )
        XCTAssertFalse(
            CodexThread.gitControlsVisible(
                for: thread,
                workingDirectory: "/repo",
                isConnected: false
            )
        )
        XCTAssertFalse(
            CodexThread.gitControlsVisible(
                for: thread,
                workingDirectory: nil,
                isConnected: true
            )
        )
    }
}
