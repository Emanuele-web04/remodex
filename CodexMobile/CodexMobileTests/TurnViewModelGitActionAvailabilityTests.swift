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

    func testGitActionPlannedPhasesReflectBridgeWork() {
        let aheadStatus = makeRepoSync(dirty: false, ahead: 1, canPush: true)
        let cleanStatus = makeRepoSync(dirty: false, ahead: 0, canPush: false)

        XCTAssertEqual(
            TurnGitActionKind.commit.plannedPhases(repoSync: cleanStatus, hasCustomCommitMessage: false, willCreateFeatureBranch: false),
            [.generatingCommit, .commit]
        )
        XCTAssertEqual(
            TurnGitActionKind.push.plannedPhases(repoSync: aheadStatus, hasCustomCommitMessage: true, willCreateFeatureBranch: false),
            [.push]
        )
        XCTAssertEqual(
            TurnGitActionKind.commitAndPush.plannedPhases(repoSync: aheadStatus, hasCustomCommitMessage: false, willCreateFeatureBranch: false, hasWorkingTreeChanges: false),
            [.push]
        )
        XCTAssertEqual(
            TurnGitActionKind.commitPushCreatePR.plannedPhases(repoSync: aheadStatus, hasCustomCommitMessage: false, willCreateFeatureBranch: true, hasWorkingTreeChanges: false),
            [.branch, .push, .createPR]
        )
        XCTAssertEqual(
            TurnGitActionKind.createPR.plannedPhases(repoSync: aheadStatus, hasCustomCommitMessage: true, willCreateFeatureBranch: false),
            [.push, .createPR]
        )
        XCTAssertEqual(
            TurnGitActionKind.createPR.plannedPhases(repoSync: cleanStatus, hasCustomCommitMessage: true, willCreateFeatureBranch: false),
            [.createPR]
        )
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
