// FILE: TurnViewModelGitActionAvailabilityTests.swift
// Purpose: Verifies git controls stay fail-closed unless the thread is idle and bound to a local repo.
// Layer: Unit Test
// Exports: TurnViewModelGitActionAvailabilityTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnViewModelGitActionAvailabilityTests: XCTestCase {
    func testCanRunGitActionRequiresBoundWorkingDirectory() {
        let viewModel = TurnViewModel()

        XCTAssertFalse(
            viewModel.canRunGitAction(
                isConnected: true,
                isThreadRunning: false,
                hasGitWorkingDirectory: false
            )
        )
    }

    func testCanRunGitActionDisablesWhileThreadIsRunning() {
        let viewModel = TurnViewModel()

        XCTAssertFalse(
            viewModel.canRunGitAction(
                isConnected: true,
                isThreadRunning: true,
                hasGitWorkingDirectory: true
            )
        )
    }

    func testCanRunGitActionAllowsIdleBoundThread() {
        let viewModel = TurnViewModel()

        XCTAssertTrue(
            viewModel.canRunGitAction(
                isConnected: true,
                isThreadRunning: false,
                hasGitWorkingDirectory: true
            )
        )
    }

    func testCommitAndPushIsDisabledWhenCleanAndNothingToPush() {
        let viewModel = TurnViewModel()
        viewModel.gitRepoSync = makeRepoSync(dirty: false, ahead: 0, canPush: false)

        XCTAssertTrue(viewModel.disabledGitActions.contains(.commitAndPush))
    }

    func testCommitAndPushIsEnabledForDirtyOrPushableBranches() {
        let dirtyViewModel = TurnViewModel()
        dirtyViewModel.gitRepoSync = makeRepoSync(dirty: true, ahead: 0, canPush: false)

        let aheadViewModel = TurnViewModel()
        aheadViewModel.gitRepoSync = makeRepoSync(dirty: false, ahead: 1, canPush: true)

        XCTAssertFalse(dirtyViewModel.disabledGitActions.contains(.commitAndPush))
        XCTAssertFalse(aheadViewModel.disabledGitActions.contains(.commitAndPush))
    }

    func testGitActionLoadingTitlesExplainBridgeWork() {
        let aheadStatus = makeRepoSync(dirty: false, ahead: 1, canPush: true)
        let cleanStatus = makeRepoSync(dirty: false, ahead: 0, canPush: false)

        XCTAssertEqual(TurnGitActionKind.commit.loadingTitle(repoSync: cleanStatus), "Committing...")
        XCTAssertEqual(TurnGitActionKind.push.loadingTitle(repoSync: aheadStatus), "Pushing...")
        XCTAssertEqual(TurnGitActionKind.commitAndPush.loadingSteps(repoSync: aheadStatus), ["Committing...", "Pushing..."])
        XCTAssertEqual(TurnGitActionKind.commitPushCreatePR.loadingSteps(repoSync: aheadStatus), ["Committing...", "Pushing...", "Creating PR..."])
        XCTAssertEqual(TurnGitActionKind.createPR.loadingSteps(repoSync: aheadStatus), ["Pushing...", "Creating PR..."])
        XCTAssertEqual(TurnGitActionKind.createPR.loadingSteps(repoSync: cleanStatus), ["Creating PR..."])
    }

    private func makeRepoSync(dirty: Bool, ahead: Int, canPush: Bool) -> GitRepoSyncResult {
        GitRepoSyncResult(
            from: [
                "isRepo": .bool(true),
                "branch": .string("remodex/topic"),
                "tracking": .string("origin/remodex/topic"),
                "dirty": .bool(dirty),
                "hasPushRemote": .bool(true),
                "ahead": .integer(ahead),
                "behind": .integer(0),
                "localOnlyCommitCount": .integer(0),
                "state": .string(dirty ? "dirty" : "up_to_date"),
                "canPush": .bool(canPush),
                "publishedToRemote": .bool(true),
                "files": .array([])
            ]
        )
    }
}
