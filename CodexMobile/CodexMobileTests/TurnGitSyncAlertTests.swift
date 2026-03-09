// FILE: TurnGitSyncAlertTests.swift
// Purpose: Verifies the guided Git sync alerts map backend repo states to the right user decisions.
// Layer: Unit Test
// Exports: TurnGitSyncAlertTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnGitSyncAlertTests: XCTestCase {
    func testBehindOnlyOffersSafeRemoteUpdate() {
        let viewModel = TurnViewModel()

        let alert = viewModel.makeGitSyncAlert(
            for: GitRepoSyncResult(
                currentBranch: "feature/sync",
                trackingBranch: "origin/feature/sync",
                isDirty: false,
                aheadCount: 0,
                behindCount: 2,
                state: "behind_only",
                actionTaken: "none",
                canPush: false,
                lastFetchAt: nil
            )
        )

        XCTAssertEqual(alert.title, "Remote Update Available")
        XCTAssertEqual(alert.confirmTitle, "Update Now")
        XCTAssertEqual(alert.action, .update(confirmStrategy: .none))
    }

    func testDivergedOffersConfirmedPullRebase() {
        let viewModel = TurnViewModel()

        let alert = viewModel.makeGitSyncAlert(
            for: GitRepoSyncResult(
                currentBranch: "feature/rebase",
                trackingBranch: "origin/feature/rebase",
                isDirty: false,
                aheadCount: 1,
                behindCount: 1,
                state: "diverged",
                actionTaken: "none",
                canPush: false,
                lastFetchAt: nil
            )
        )

        XCTAssertEqual(alert.title, "Remote History Diverged")
        XCTAssertEqual(alert.confirmTitle, "Try Update")
        XCTAssertEqual(alert.action, .update(confirmStrategy: .rebaseIfDiverged))
    }

    func testDirtyAndBehindStaysInformationalOnly() {
        let viewModel = TurnViewModel()

        let alert = viewModel.makeGitSyncAlert(
            for: GitRepoSyncResult(
                currentBranch: "feature/dirty",
                trackingBranch: "origin/feature/dirty",
                isDirty: true,
                aheadCount: 0,
                behindCount: 3,
                state: "dirty_and_behind",
                actionTaken: "blocked",
                canPush: false,
                lastFetchAt: nil
            )
        )

        XCTAssertEqual(alert.title, "Local Changes + Remote Update")
        XCTAssertNil(alert.confirmTitle)
        XCTAssertEqual(alert.action, .dismissOnly)
    }
}
