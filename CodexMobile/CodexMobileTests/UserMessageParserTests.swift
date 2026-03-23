// FILE: UserMessageParserTests.swift
// Purpose: Verifies leading user-message file mentions keep full filenames, including spaces.
// Layer: Unit Test
// Exports: UserMessageParserTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class UserMessageParserTests: XCTestCase {
    func testParseKeepsLeadingFileMentionWithSpaces() {
        let parsed = UserMessageParser.parse(
            "@Codex Mobile App Plan/Codex iOS Recap TLDR.md add other 2 lines"
        )

        XCTAssertEqual(parsed.mentions, ["Codex Mobile App Plan/Codex iOS Recap TLDR.md"])
        XCTAssertEqual(parsed.body, "add other 2 lines")
    }

    func testParseKeepsLegacySingleTokenMentionsWorking() {
        let parsed = UserMessageParser.parse("@Views/Turn/TurnView.swift check this")

        XCTAssertEqual(parsed.mentions, ["Views/Turn/TurnView.swift"])
        XCTAssertEqual(parsed.body, "check this")
    }

    func testParseDoesNotTreatSwiftAttributeAsFileMention() {
        let parsed = UserMessageParser.parse("@State private var count = 0")

        XCTAssertEqual(parsed.mentions, [])
        XCTAssertEqual(parsed.body, "@State private var count = 0")
    }
}
