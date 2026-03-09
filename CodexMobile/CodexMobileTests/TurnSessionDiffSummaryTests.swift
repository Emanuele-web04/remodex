// FILE: TurnSessionDiffSummaryTests.swift
// Purpose: Verifies chat-level diff totals shown in the toolbar, including push resets.
// Layer: Unit Test
// Exports: TurnSessionDiffSummaryTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class TurnSessionDiffSummaryTests: XCTestCase {
    func testTotalsSumDistinctFileChangeMessages() {
        let messages = [
            makeMessage(
                id: "diff-1",
                kind: .fileChange,
                text: """
                Edited Sources/App.swift +2 -1
                Added Sources/Toolbar.swift +4 -0
                """
            ),
            makeMessage(
                id: "diff-2",
                kind: .fileChange,
                text: "Deleted Sources/Legacy.swift +0 -3"
            ),
        ]

        let totals = TurnSessionDiffSummaryCalculator.totals(from: messages)

        XCTAssertEqual(totals?.additions, 6)
        XCTAssertEqual(totals?.deletions, 4)
        XCTAssertEqual(totals?.distinctDiffCount, 2)
    }

    func testTotalsIgnoreMessagesBeforeMostRecentPush() {
        let messages = [
            makeMessage(
                id: "diff-before-push",
                kind: .fileChange,
                text: "Edited Sources/App.swift +5 -2"
            ),
            makeMessage(
                id: "push-reset",
                kind: .chat,
                text: """
                Commit & push completed.
                Branch: `main`
                Hash: `abc123`
                Remote: `origin`
                """
            ),
            makeMessage(
                id: "diff-after-push",
                kind: .fileChange,
                text: "Edited Sources/Composer.swift +3 -1"
            ),
        ]

        let totals = TurnSessionDiffSummaryCalculator.totals(from: messages)

        XCTAssertEqual(totals?.additions, 3)
        XCTAssertEqual(totals?.deletions, 1)
        XCTAssertEqual(totals?.distinctDiffCount, 1)
    }

    func testTotalsIgnoreMessagesBeforeHiddenManualPushMarker() {
        let messages = [
            makeMessage(
                id: "diff-before-push",
                kind: .fileChange,
                text: "Edited Sources/App.swift +5 -2"
            ),
            makeMessage(
                id: "hidden-push-reset",
                kind: .chat,
                text: TurnSessionDiffResetMarker.text(branch: "feature/test", remote: "origin"),
                itemID: TurnSessionDiffResetMarker.manualPushItemID
            ),
            makeMessage(
                id: "diff-after-push",
                kind: .fileChange,
                text: "Edited Sources/Composer.swift +3 -1"
            ),
        ]

        let totals = TurnSessionDiffSummaryCalculator.totals(from: messages)

        XCTAssertEqual(totals?.additions, 3)
        XCTAssertEqual(totals?.deletions, 1)
        XCTAssertEqual(totals?.distinctDiffCount, 1)
    }

    func testTotalsDeduplicateRepeatedMessageIDs() {
        let messages = [
            makeMessage(
                id: "diff-1",
                kind: .fileChange,
                text: "Edited Sources/App.swift +2 -1"
            ),
            makeMessage(
                id: "diff-1",
                kind: .fileChange,
                text: "Edited Sources/App.swift +2 -1"
            ),
        ]

        let totals = TurnSessionDiffSummaryCalculator.totals(from: messages)

        XCTAssertEqual(totals?.additions, 2)
        XCTAssertEqual(totals?.deletions, 1)
        XCTAssertEqual(totals?.distinctDiffCount, 1)
    }

    private func makeMessage(
        id: String,
        kind: CodexMessageKind,
        text: String,
        itemID: String? = nil
    ) -> CodexMessage {
        CodexMessage(
            id: id,
            threadId: "thread-1",
            role: .system,
            kind: kind,
            text: text,
            createdAt: Date(),
            itemId: itemID,
            orderIndex: 0
        )
    }
}
