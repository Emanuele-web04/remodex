// FILE: TurnSlashCommandTokenTests.swift
// Purpose: Verifies trailing `/` command parsing for the composer slash menu.
// Layer: Unit Test
// Exports: TurnSlashCommandTokenTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnSlashCommandTokenTests: XCTestCase {
    func testTrailingTokenParsesBareSlash() {
        let token = TurnViewModel.trailingSlashCommandToken(in: "/")
        XCTAssertEqual(token?.query, "")
    }

    func testTrailingTokenParsesSlashQuery() {
        let token = TurnViewModel.trailingSlashCommandToken(in: "run /rev")
        XCTAssertEqual(token?.query, "rev")
    }

    func testSlashCommandPanelIgnoresNonCommandSlashSkillQueries() {
        let viewModel = TurnViewModel()

        viewModel.onInputChangedForSlashCommandAutocomplete("run /check-code", activeTurnID: nil)

        XCTAssertEqual(viewModel.slashCommandPanelState, .hidden)
    }

    func testSlashCommandPanelStillOpensForMatchingCommands() {
        let viewModel = TurnViewModel()

        viewModel.onInputChangedForSlashCommandAutocomplete("run /rev", activeTurnID: nil)

        XCTAssertEqual(viewModel.slashCommandPanelState, .commands(query: "rev"))
    }

    func testTrailingTokenDoesNotParseWhenSlashTokenIsNotFinal() {
        XCTAssertNil(TurnViewModel.trailingSlashCommandToken(in: "/review later"))
    }

    func testRemovingTrailingSlashTokenDropsOnlyFinalCommand() {
        let updated = TurnViewModel.removingTrailingSlashCommandToken(in: "compare /first and /rev")
        XCTAssertEqual(updated, "compare /first and")
    }

    func testForkCommandIsAllowedWhenSlashTokenIsTheOnlyDraftContent() {
        XCTAssertTrue(TurnComposerCommandLogic.canOfferForkSlashCommand(in: "/fo"))
        XCTAssertFalse(TurnComposerCommandLogic.canOfferForkSlashCommand(in: "   /fo"))
    }

    func testForkCommandIsHiddenWhenDraftAlreadyContainsText() {
        XCTAssertFalse(TurnComposerCommandLogic.canOfferForkSlashCommand(in: "continue /fo"))
        XCTAssertFalse(TurnComposerCommandLogic.canOfferForkSlashCommand(in: "hello\n/fo"))
    }

    func testForkCommandIsHiddenWhenComposerHasNonTextState() {
        XCTAssertFalse(
            TurnComposerCommandLogic.canOfferForkSlashCommand(
                in: "/fo",
                attachmentCount: 1
            )
        )
        XCTAssertFalse(
            TurnComposerCommandLogic.canOfferForkSlashCommand(
                in: "/fo",
                mentionedFileCount: 1
            )
        )
        XCTAssertFalse(
            TurnComposerCommandLogic.canOfferForkSlashCommand(
                in: "/fo",
                mentionedSkillCount: 1
            )
        )
        XCTAssertFalse(
            TurnComposerCommandLogic.canOfferForkSlashCommand(
                in: "/fo",
                hasReviewSelection: true
            )
        )
        XCTAssertFalse(
            TurnComposerCommandLogic.canOfferForkSlashCommand(
                in: "/fo",
                hasSubagentsSelection: true
            )
        )
        XCTAssertFalse(
            TurnComposerCommandLogic.canOfferForkSlashCommand(
                in: "/fo",
                isPlanModeArmed: true
            )
        )
    }

    func testSideCommandMatchesCanonicalNameAndBtwAlias() {
        XCTAssertEqual(TurnComposerSlashCommand.filtered(matching: "si"), [.side])
        XCTAssertEqual(TurnComposerSlashCommand.filtered(matching: "btw"), [.side])
    }

    func testSideCommandRequiresOtherwiseEmptyComposerState() {
        XCTAssertTrue(TurnComposerCommandLogic.canOfferSideSlashCommand(in: "/side"))
        XCTAssertFalse(TurnComposerCommandLogic.canOfferSideSlashCommand(in: "explain /side"))
        XCTAssertFalse(TurnComposerCommandLogic.canOfferSideSlashCommand(in: "/side", attachmentCount: 1))
        XCTAssertFalse(TurnComposerCommandLogic.canOfferSideSlashCommand(in: "/side", mentionedPluginCount: 1))
    }

    func testTypedSideCommandUsesSameNonTextEligibilityAsAutocomplete() {
        XCTAssertTrue(TurnComposerCommandLogic.canExecuteInlineSideCommand())
        XCTAssertFalse(TurnComposerCommandLogic.canExecuteInlineSideCommand(attachmentCount: 1))
        XCTAssertFalse(TurnComposerCommandLogic.canExecuteInlineSideCommand(mentionedFileCount: 1))
        XCTAssertFalse(TurnComposerCommandLogic.canExecuteInlineSideCommand(mentionedSkillCount: 1))
        XCTAssertFalse(TurnComposerCommandLogic.canExecuteInlineSideCommand(mentionedPluginCount: 1))
        XCTAssertFalse(TurnComposerCommandLogic.canExecuteInlineSideCommand(hasReviewSelection: true))
        XCTAssertFalse(TurnComposerCommandLogic.canExecuteInlineSideCommand(hasSubagentsSelection: true))
        XCTAssertFalse(TurnComposerCommandLogic.canExecuteInlineSideCommand(isPlanModeArmed: true))
    }

    func testInlineSideCommandSupportsPromptAndAlias() {
        XCTAssertEqual(TurnView.inlineSideCommandPrompt(in: "/side explain this"), "explain this")
        XCTAssertEqual(TurnView.inlineSideCommandPrompt(in: "/btw status?"), "status?")
        XCTAssertEqual(TurnView.inlineSideCommandPrompt(in: "/side"), "")
        XCTAssertNil(TurnView.inlineSideCommandPrompt(in: "/sidebar"))
    }
}
