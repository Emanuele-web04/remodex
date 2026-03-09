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
}
