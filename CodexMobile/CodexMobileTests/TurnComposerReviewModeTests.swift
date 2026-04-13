// FILE: TurnComposerReviewModeTests.swift
// Purpose: Covers edge cases for inline review and slash-command composer modes.
// Layer: Unit Test
// Exports: TurnComposerReviewModeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnComposerReviewModeTests: XCTestCase {
    private static var retainedViewModels: [TurnViewModel] = []

    func testTrailingSlashCommandDoesNotCountAsReviewConflict() {
        let viewModel = makeViewModel()

        viewModel.input = "/review"
        XCTAssertFalse(viewModel.hasComposerContentConflictingWithReview)

        viewModel.input = "/"
        XCTAssertFalse(viewModel.hasComposerContentConflictingWithReview)

        viewModel.input = "follow up"
        XCTAssertTrue(viewModel.hasComposerContentConflictingWithReview)
    }

    func testArmedSubagentsSelectionCountsAsReviewConflict() {
        let viewModel = makeViewModel()

        viewModel.isSubagentsSelectionArmed = true

        XCTAssertTrue(viewModel.hasComposerContentConflictingWithReview)
    }

    func testSelectingCodeReviewRequiresEmptyDraft() {
        let viewModel = makeViewModel()
        viewModel.input = "Please review this too"

        viewModel.onSelectSlashCommand(.codeReview)

        XCTAssertNil(viewModel.composerReviewSelection)
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testTypingTextClearsConfirmedReviewSelection() {
        let viewModel = makeViewModel()
        viewModel.composerReviewSelection = TurnComposerReviewSelection(
            command: .codeReview,
            target: .uncommittedChanges
        )

        viewModel.onInputChangedForSlashCommandAutocomplete("follow up", activeTurnID: nil)

        XCTAssertNil(viewModel.composerReviewSelection)
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testSelectingFileClearsConfirmedReviewSelection() {
        let viewModel = makeViewModel()
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
        let viewModel = makeViewModel()
        viewModel.input = "/sta"
        viewModel.slashCommandPanelState = .commands(query: "sta")

        viewModel.onSelectSlashCommand(.status)

        XCTAssertEqual(viewModel.input, "")
        XCTAssertNil(viewModel.composerReviewSelection)
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testSelectingFeedbackClearsTrailingSlashTokenWithoutEnteringReviewMode() {
        let viewModel = makeViewModel()
        viewModel.input = "/feed"
        viewModel.slashCommandPanelState = .commands(query: "feed")

        viewModel.onSelectSlashCommand(.feedback)

        XCTAssertEqual(viewModel.input, "")
        XCTAssertNil(viewModel.composerReviewSelection)
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testSelectingSubagentsArmsChipAndClearsSlashToken() {
        let viewModel = makeViewModel()
        viewModel.input = "/sub"
        viewModel.slashCommandPanelState = .commands(query: "sub")

        viewModel.onSelectSlashCommand(.subagents)

        XCTAssertEqual(viewModel.input, "")
        XCTAssertTrue(viewModel.isSubagentsSelectionArmed)
        XCTAssertNil(viewModel.composerReviewSelection)
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testSelectingSubagentsKeepsSlashPickerClosedAfterInputObserverRuns() {
        let viewModel = makeViewModel()
        viewModel.input = "/sub"
        viewModel.slashCommandPanelState = .commands(query: "sub")

        viewModel.onSelectSlashCommand(.subagents)
        viewModel.onInputChangedForSlashCommandAutocomplete(viewModel.input, activeTurnID: nil)

        XCTAssertEqual(viewModel.input, "")
        XCTAssertTrue(viewModel.isSubagentsSelectionArmed)
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testEmptySlashQueryStillIncludesSubagentsCommand() {
        XCTAssertEqual(
            TurnComposerSlashCommand.filtered(
                matching: "",
                within: TurnComposerSlashCommand.availableCommands(
                    supportsThreadFork: true,
                    allowsForkCommand: true
                )
            ).map(\.commandToken),
            ["/review", "/feedback", "/fork", "/status", "/subagents"]
        )
    }

    func testForkCommandDisappearsWhenDraftAlreadyContainsText() {
        XCTAssertEqual(
            TurnComposerSlashCommand.availableCommands(
                supportsThreadFork: true,
                allowsForkCommand: false
            ).map(\.commandToken),
            ["/review", "/feedback", "/status", "/subagents"]
        )
    }

    func testSelectingForkShowsDestinationList() {
        let viewModel = makeViewModel()

        viewModel.onSelectSlashCommand(.fork, availableForkDestinations: [.newWorktree, .local])

        XCTAssertEqual(
            viewModel.slashCommandPanelState,
            .forkDestinations([.newWorktree, .local])
        )
    }

    func testSelectingForkDestinationClearsSlashTokenAndClosesPanel() {
        let viewModel = makeViewModel()
        viewModel.input = "/fo"
        viewModel.slashCommandPanelState = .forkDestinations([.local])

        viewModel.onSelectForkDestination(.local)

        XCTAssertEqual(viewModel.input, "")
        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testForkDestinationsCollapseToLocalForManagedWorktreeThreads() {
        XCTAssertEqual(
            TurnComposerForkDestination.availableDestinations(
                canForkLocally: true,
                canCreateWorktree: false
            ),
            [.local]
        )
        XCTAssertEqual(
            TurnComposerForkDestination.availableDestinations(
                canForkLocally: true,
                canCreateWorktree: true
            ),
            [.newWorktree, .local]
        )
        XCTAssertEqual(
            TurnComposerForkDestination.availableDestinations(
                canForkLocally: false,
                canCreateWorktree: true
            ),
            [.newWorktree]
        )
        XCTAssertEqual(
            TurnComposerForkDestination.availableDestinations(
                canForkLocally: false,
                canCreateWorktree: false
            ),
            []
        )
    }

    func testSelectingSubagentsPreservesExistingDraftText() {
        let viewModel = makeViewModel()
        viewModel.input = "Follow up on this\n/sub"
        viewModel.slashCommandPanelState = .commands(query: "sub")

        viewModel.onSelectSlashCommand(.subagents)

        XCTAssertEqual(viewModel.input, "Follow up on this")
        XCTAssertTrue(viewModel.isSubagentsSelectionArmed)
    }

    func testApplyingSubagentsSelectionPrefixesPromptText() {
        let expanded = TurnViewModel.applyingSubagentsSelection(
            to: "Please handle this soon.",
            isSelected: true
        )

        XCTAssertEqual(
            expanded,
            "Run subagents for different tasks. Delegate distinct work in parallel when helpful and then synthesize the results.\n\nPlease handle this soon."
        )
    }

    func testLiteralSubagentsTextStaysUnchangedWhenSelectionIsNotArmed() {
        let source = "Please explain what /subagents does."
        let expanded = TurnViewModel.applyingSubagentsSelection(
            to: source,
            isSelected: false
        )

        XCTAssertEqual(expanded, source)
    }

    func testApplyingSubagentsSelectionStillKeepsLiteralMentionInDraft() {
        let source = "Please explain what /subagents does."
        let expanded = TurnViewModel.applyingSubagentsSelection(
            to: source,
            isSelected: true
        )

        XCTAssertEqual(
            expanded,
            "Run subagents for different tasks. Delegate distinct work in parallel when helpful and then synthesize the results.\n\nPlease explain what /subagents does."
        )
    }

    private func makeViewModel() -> TurnViewModel {
        let viewModel = TurnViewModel()
        // TurnViewModel currently crashes while deallocating in the unit-test host.
        // Keep instances alive for process lifetime so this suite remains deterministic.
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }
}
