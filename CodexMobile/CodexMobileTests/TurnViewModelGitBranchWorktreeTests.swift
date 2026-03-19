// FILE: TurnViewModelGitBranchWorktreeTests.swift
// Purpose: Verifies worktree-backed branches are exposed to the UI only when Git reports them as checked out elsewhere.
// Layer: Unit Test
// Exports: TurnViewModelGitBranchWorktreeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnViewModelGitBranchWorktreeTests: XCTestCase {
    func testWorktreePathResolvesOnlyForBranchesCheckedOutElsewhere() {
        let viewModel = TurnViewModel()
        viewModel.gitBranchesCheckedOutElsewhere = ["remodex/feature-a"]
        viewModel.gitWorktreePathsByBranch = [
            "remodex/feature-a": "/tmp/remodex-feature-a",
            "main": "/tmp/remodex-main"
        ]

        XCTAssertEqual(
            viewModel.worktreePathForCheckedOutElsewhereBranch("remodex/feature-a"),
            "/tmp/remodex-feature-a"
        )
        XCTAssertNil(viewModel.worktreePathForCheckedOutElsewhereBranch("main"))
        XCTAssertNil(viewModel.worktreePathForCheckedOutElsewhereBranch("remodex/missing"))
    }
}
