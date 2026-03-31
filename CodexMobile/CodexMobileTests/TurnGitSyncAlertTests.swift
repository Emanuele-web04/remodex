// FILE: TurnGitSyncAlertTests.swift
// Purpose: Verifies sync-state alerts reflect the current Git reconciliation flow.
// Layer: Unit Test
// Exports: TurnGitSyncAlertTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnGitSyncAlertTests: XCTestCase {
    func testBehindOnlyDoesNotShowAlertBecauseSyncNowAutoPulls() {
        let viewModel = TurnViewModel()

        XCTAssertNil(
            viewModel.gitSyncAlert(
                for: makeRepoSyncResult(
                    branch: "feature/sync",
                    tracking: "origin/feature/sync",
                    state: "behind_only",
                    behind: 2
                )
            )
        )
    }

    func testDivergedShowsPullRebaseConfirmation() throws {
        let viewModel = TurnViewModel()

        let alert = try XCTUnwrap(
            viewModel.gitSyncAlert(
                for: makeRepoSyncResult(
                    branch: "feature/rebase",
                    tracking: "origin/feature/rebase",
                    state: "diverged",
                    ahead: 1,
                    behind: 1
                )
            )
        )

        XCTAssertEqual(alert.title, "Branch diverged from remote")
        XCTAssertEqual(alert.message, "Local and remote history both moved. Pull with rebase to reconcile them?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Pull & Rebase"])
        XCTAssertEqual(alert.buttons.map(\.action), [.dismissOnly, .pullRebase])
    }

    func testDirtyAndBehindShowsCautiousPullRebasePrompt() throws {
        let viewModel = TurnViewModel()

        let alert = try XCTUnwrap(
            viewModel.gitSyncAlert(
                for: makeRepoSyncResult(
                    branch: "feature/dirty",
                    tracking: "origin/feature/dirty",
                    state: "dirty_and_behind",
                    isDirty: true,
                    behind: 3
                )
            )
        )

        XCTAssertEqual(alert.title, "Local changes need attention")
        XCTAssertEqual(
            alert.message,
            "You have local changes and the remote branch moved ahead. Pull with rebase only if you're ready to reconcile those changes."
        )
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Pull & Rebase"])
        XCTAssertEqual(alert.buttons.map(\.action), [.dismissOnly, .pullRebase])
    }

    private func makeRepoSyncResult(
        branch: String,
        tracking: String,
        state: String,
        isDirty: Bool = false,
        ahead: Int = 0,
        behind: Int = 0
    ) -> GitRepoSyncResult {
        GitRepoSyncResult(
            from: [
                "branch": .string(branch),
                "tracking": .string(tracking),
                "dirty": .bool(isDirty),
                "ahead": .integer(ahead),
                "behind": .integer(behind),
                "state": .string(state),
                "canPush": .bool(false),
                "publishedToRemote": .bool(true)
            ]
        )
    }
}
