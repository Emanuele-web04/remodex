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

    func testCanRunGitActionDisablesWhileThreadIsRunningByDefault() {
        let viewModel = TurnViewModel()

        XCTAssertFalse(
            viewModel.canRunGitAction(
                isConnected: true,
                isThreadRunning: true,
                hasGitWorkingDirectory: true
            )
        )
    }

    func testCanRunGitActionCanAllowRepoScopedWritesWhileThreadIsRunning() {
        let viewModel = TurnViewModel()

        XCTAssertTrue(
            viewModel.canRunGitAction(
                isConnected: true,
                isThreadRunning: true,
                hasGitWorkingDirectory: true,
                requiresIdleThread: false
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

    func testUpdateIsDisabledWhenRepositoryHasNoRemoteWork() {
        let cleanViewModel = TurnViewModel()
        cleanViewModel.gitRepoSync = makeRepoSync(dirty: false, ahead: 0, canPush: false)

        let dirtyViewModel = TurnViewModel()
        dirtyViewModel.gitRepoSync = makeRepoSync(dirty: true, ahead: 0, canPush: false)

        XCTAssertTrue(cleanViewModel.disabledGitActions.contains(.syncNow))
        XCTAssertTrue(dirtyViewModel.disabledGitActions.contains(.syncNow))
    }

    func testUpdateIsEnabledWhenRepositoryNeedsRemoteUpdate() {
        for state in ["behind_only", "dirty_and_behind"] {
            let viewModel = TurnViewModel()
            viewModel.gitRepoSync = makeRepoSync(
                dirty: state == "dirty_and_behind",
                ahead: 0,
                behind: 1,
                state: state,
                canPush: false
            )

            XCTAssertFalse(viewModel.disabledGitActions.contains(.syncNow), state)
        }
    }

    func testUpdateIsDisabledWhenBranchDiverged() {
        let viewModel = TurnViewModel()
        // Diverged history is intentionally not treated as a normal Update:
        // it needs an explicit reconcile action instead of a fast-forward pull.
        viewModel.gitRepoSync = makeRepoSync(
            dirty: false,
            ahead: 1,
            behind: 1,
            state: "diverged",
            canPush: false
        )

        XCTAssertTrue(viewModel.disabledGitActions.contains(.syncNow))
    }

    func testRepoDiffTotalsPreserveExplicitZeroChanges() {
        let status = GitRepoSyncResult(
            from: [
                "isRepo": .bool(true),
                "branch": .string("main"),
                "tracking": .string("origin/main"),
                "dirty": .bool(false),
                "state": .string("up_to_date"),
                "diff": .object([
                    "additions": .integer(0),
                    "deletions": .integer(0),
                    "binaryFiles": .integer(0)
                ])
            ]
        )

        XCTAssertNotNil(status.repoDiffTotals)
        XCTAssertEqual(status.repoDiffTotals?.additions, 0)
        XCTAssertEqual(status.repoDiffTotals?.deletions, 0)
        XCTAssertEqual(status.repoDiffTotals?.binaryFiles, 0)
        XCTAssertFalse(status.repoDiffTotals?.hasChanges ?? true)
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

    private func makeRepoSync(
        dirty: Bool,
        ahead: Int,
        behind: Int = 0,
        state: String? = nil,
        canPush: Bool
    ) -> GitRepoSyncResult {
        GitRepoSyncResult(
            from: [
                "isRepo": .bool(true),
                "branch": .string("remodex/topic"),
                "tracking": .string("origin/remodex/topic"),
                "dirty": .bool(dirty),
                "hasPushRemote": .bool(true),
                "ahead": .integer(ahead),
                "behind": .integer(behind),
                "localOnlyCommitCount": .integer(0),
                "state": .string(state ?? (dirty ? "dirty" : "up_to_date")),
                "canPush": .bool(canPush),
                "publishedToRemote": .bool(true),
                "files": .array([])
            ]
        )
    }
}
