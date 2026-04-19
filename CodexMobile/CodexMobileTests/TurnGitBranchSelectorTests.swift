// FILE: TurnGitBranchSelectorTests.swift
// Purpose: Verifies new branch creation names normalize toward the remodex/ prefix without double-prefixing.
// Layer: Unit Test
// Exports: TurnGitBranchSelectorTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class TurnGitBranchSelectorTests: XCTestCase {
    func testNormalizesCreatedBranchNamesTowardRemodexPrefix() {
        XCTAssertEqual(remodexNormalizedCreatedBranchName("foo"), "remodex/foo")
        XCTAssertEqual(remodexNormalizedCreatedBranchName("remodex/foo"), "remodex/foo")
        XCTAssertEqual(remodexNormalizedCreatedBranchName("  foo  "), "remodex/foo")
    }

    func testNormalizesEmptyBranchNamesToEmptyString() {
        XCTAssertEqual(remodexNormalizedCreatedBranchName("   "), "")
    }

    func testCurrentBranchSelectionDisablesCheckedOutElsewhereRowsWhenWorktreePathIsMissing() {
        XCTAssertTrue(
            remodexCurrentBranchSelectionIsDisabled(
                branch: "remodex/feature-a",
                currentBranch: "main",
                gitBranchesCheckedOutElsewhere: ["remodex/feature-a"],
                gitWorktreePathsByBranch: [:],
                allowsSelectingCurrentBranch: true
            )
        )
    }

    func testCurrentBranchSelectionKeepsCheckedOutElsewhereRowsEnabledWhenWorktreePathExists() {
        XCTAssertFalse(
            remodexCurrentBranchSelectionIsDisabled(
                branch: "remodex/feature-a",
                currentBranch: "main",
                gitBranchesCheckedOutElsewhere: ["remodex/feature-a"],
                gitWorktreePathsByBranch: ["remodex/feature-a": "/tmp/remodex-feature-a"],
                allowsSelectingCurrentBranch: true
            )
        )
    }

    func testSelectableDefaultBranchReturnsNilWhenDefaultIsNotLocal() {
        XCTAssertNil(
            remodexSelectableDefaultBranch(
                defaultBranch: "main",
                availableGitBranchTargets: ["remodex/feature-a"]
            )
        )
    }

    func testSelectableDefaultBranchReturnsDefaultWhenItIsLocal() {
        XCTAssertEqual(
            remodexSelectableDefaultBranch(
                defaultBranch: "main",
                availableGitBranchTargets: ["main", "remodex/feature-a"]
            ),
            "main"
        )
    }
}
