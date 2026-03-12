// FILE: TurnComposerReviewModeTests.swift
// Purpose: Covers edge cases for the inline review composer mode.
// Layer: Unit Test
// Exports: TurnComposerReviewModeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnComposerReviewModeTests: XCTestCase {
    func testTrailingSlashCommandDoesNotCountAsReviewConflict() {
        let viewModel = TurnViewModel()

        viewModel.input = "/review"
        XCTAssertFalse(viewModel.hasComposerContentConflictingWithReview)

        viewModel.input = "/"
        XCTAssertFalse(viewModel.hasComposerContentConflictingWithReview)

        viewModel.input = "follow up"
        XCTAssertTrue(viewModel.hasComposerContentConflictingWithReview)
    }

    func testSelectingCodeReviewRequiresEmptyDraft() {
        let viewModel = TurnViewModel()
        viewModel.input = "Please review this too"

        viewModel.onSelectSlashCommand(.codeReview)

        XCTAssertNil(viewModel.composerReviewSelection)
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testTypingTextClearsConfirmedReviewSelection() {
        let viewModel = TurnViewModel()
        viewModel.composerReviewSelection = TurnComposerReviewSelection(
            command: .codeReview,
            target: .uncommittedChanges
        )

        viewModel.onInputChangedForSlashCommandAutocomplete("follow up", activeTurnID: nil)

        XCTAssertNil(viewModel.composerReviewSelection)
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testSelectingFileClearsConfirmedReviewSelection() {
        let viewModel = TurnViewModel()
        viewModel.input = "@turn"
        viewModel.composerReviewSelection = TurnComposerReviewSelection(
            command: .codeReview,
            target: .uncommittedChanges
        )

        viewModel.onSelectFileAutocomplete(
            CodexFuzzyFileMatch(
                root: "/tmp/project",
                path: "Views/Turn/TurnView.swift",
                fileName: "TurnView.swift",
                score: 0.91
            )
        )

        XCTAssertNil(viewModel.composerReviewSelection)
        XCTAssertEqual(viewModel.composerMentionedFiles.map(\.fileName), ["TurnView.swift"])
    }

    func testSelectingStatusClearsTrailingSlashTokenWithoutEnteringReviewMode() {
        let viewModel = TurnViewModel()
        viewModel.input = "/sta"
        viewModel.slashCommandPanelState = .commands(query: "sta")

        viewModel.onSelectSlashCommand(.status)

        XCTAssertEqual(viewModel.input, "")
        XCTAssertNil(viewModel.composerReviewSelection)
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }
}
