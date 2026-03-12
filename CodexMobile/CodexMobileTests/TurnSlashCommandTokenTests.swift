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
}
