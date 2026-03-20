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
}
