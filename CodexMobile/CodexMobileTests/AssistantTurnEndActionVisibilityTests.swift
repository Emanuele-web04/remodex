// FILE: AssistantTurnEndActionVisibilityTests.swift
// Purpose: Verifies turn-end git/revert controls stay hidden until the assistant turn is complete.
// Layer: Unit Test
// Exports: AssistantTurnEndActionVisibilityTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class AssistantTurnEndActionVisibilityTests: XCTestCase {
    func testHideTurnEndActionsWhileAssistantTurnIsStillRunning() {
        let accessoryState = AssistantBlockAccessoryState(
            copyText: nil,
            showsRunningIndicator: true,
            blockDiffText: "Edited Sources/App.swift +2 -1",
            blockDiffEntries: [
                TurnFileChangeSummaryEntry(
                    path: "Sources/App.swift",
                    additions: 2,
                    deletions: 1,
                    action: .edited
                )
            ],
            blockRevertPresentation: AssistantRevertPresentation(
                title: "Undo changes",
                isEnabled: false,
                helperText: "This response is still collecting its final patch.",
                riskLevel: .blocked
            ),
            blockRevertMessage: nil
        )

        XCTAssertFalse(
            AssistantTurnEndActionVisibility.shouldShow(accessoryState: accessoryState)
        )
    }

    func testShowTurnEndActionsAfterAssistantTurnCompletes() {
        let accessoryState = AssistantBlockAccessoryState(
            copyText: nil,
            showsRunningIndicator: false,
            blockDiffText: "Edited Sources/App.swift +2 -1",
            blockDiffEntries: [
                TurnFileChangeSummaryEntry(
                    path: "Sources/App.swift",
                    additions: 2,
                    deletions: 1,
                    action: .edited
                )
            ],
            blockRevertPresentation: AssistantRevertPresentation(
                title: "Undo changes",
                isEnabled: true,
                helperText: "Only changes from this response will be reverted unless later edits overlap.",
                riskLevel: .safe
            ),
            blockRevertMessage: nil
        )

        XCTAssertTrue(
            AssistantTurnEndActionVisibility.shouldShow(accessoryState: accessoryState)
        )
    }

    func testKeepTurnEndActionsHiddenWithoutDiffOrRevertPayload() {
        let accessoryState = AssistantBlockAccessoryState(
            copyText: "Done.",
            showsRunningIndicator: false,
            blockDiffText: nil,
            blockDiffEntries: nil,
            blockRevertPresentation: nil,
            blockRevertMessage: nil
        )

        XCTAssertFalse(
            AssistantTurnEndActionVisibility.shouldShow(accessoryState: accessoryState)
        )
    }

    func testShowTurnEndActionsForStoppedTurnPayload() {
        let accessoryState = AssistantBlockAccessoryState(
            copyText: nil,
            showsRunningIndicator: false,
            blockDiffText: "Edited Sources/App.swift +2 -1",
            blockDiffEntries: [
                TurnFileChangeSummaryEntry(
                    path: "Sources/App.swift",
                    additions: 2,
                    deletions: 1,
                    action: .edited
                )
            ],
            blockRevertPresentation: nil,
            blockRevertMessage: nil
        )

        XCTAssertTrue(
            AssistantTurnEndActionVisibility.shouldShow(accessoryState: accessoryState)
        )
    }
}
