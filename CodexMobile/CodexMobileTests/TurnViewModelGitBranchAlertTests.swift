// FILE: TurnViewModelGitBranchAlertTests.swift
// Purpose: Verifies branch-only preflight prompts stay explicit for dirty checkouts and local commits on the default branch.
// Layer: Unit Test
// Exports: TurnViewModelGitBranchAlertTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnViewModelGitBranchAlertTests: XCTestCase {
    func testCreateBranchWarnsWhenDefaultBranchHasLocalCommits() {
        let viewModel = TurnViewModel()
        viewModel.currentGitBranch = "main"
        viewModel.gitDefaultBranch = "main"
        viewModel.gitRepoSync = GitRepoSyncResult(
            from: [
                "branch": .string("main"),
                "dirty": .bool(false),
                "ahead": .integer(2),
                "behind": .integer(0),
                "localOnlyCommitCount": .integer(2),
                "state": .string("ahead_only"),
                "canPush": .bool(true)
            ]
        )

        let alert = viewModel.gitBranchAlert(for: .create("codex/topic"))

        XCTAssertEqual(alert?.title, "Local commits stay on main")
        XCTAssertTrue(alert?.message.contains("2 local commits") == true)
        if case .continueGitBranchOperation(let buttonTitle)? = alert?.action {
            XCTAssertEqual(buttonTitle, "Create Anyway")
        } else {
            XCTFail("Expected continueGitBranchOperation action")
        }
    }

    func testCleanBranchCreateNeedsNoPreflightAlert() {
        let viewModel = TurnViewModel()
        viewModel.currentGitBranch = "main"
        viewModel.gitDefaultBranch = "main"
        viewModel.gitRepoSync = GitRepoSyncResult(
            from: [
                "branch": .string("main"),
                "dirty": .bool(false),
                "ahead": .integer(0),
                "behind": .integer(0),
                "localOnlyCommitCount": .integer(0),
                "state": .string("up_to_date"),
                "canPush": .bool(false)
            ]
        )

        XCTAssertNil(viewModel.gitBranchAlert(for: .create("codex/clean-start")))
        XCTAssertNil(viewModel.gitBranchAlert(for: .switchTo("feature/existing")))
    }

    func testCreateBranchWarnsWhenDefaultBranchHasLocalOnlyCommitsWithoutTracking() {
        let viewModel = TurnViewModel()
        viewModel.currentGitBranch = "main"
        viewModel.gitDefaultBranch = "main"
        viewModel.gitRepoSync = GitRepoSyncResult(
            from: [
                "branch": .string("main"),
                "dirty": .bool(false),
                "ahead": .integer(0),
                "behind": .integer(0),
                "localOnlyCommitCount": .integer(1),
                "state": .string("no_upstream"),
                "canPush": .bool(true)
            ]
        )

        let alert = viewModel.gitBranchAlert(for: .create("remodex/topic"))

        XCTAssertEqual(alert?.title, "Local commits stay on main")
        XCTAssertTrue(alert?.message.contains("1 local commit") == true)
    }
}
