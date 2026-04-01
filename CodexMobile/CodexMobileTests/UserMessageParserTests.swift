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

    func testParseDoesNotTreatTerminalScopedTaskLabelAsFileMention() {
        let parsed = UserMessageParser.parse("@t3tools/contracts:build cache hit, replaying logs")

        XCTAssertEqual(parsed.mentions, [])
        XCTAssertEqual(parsed.body, "@t3tools/contracts:build cache hit, replaying logs")
    }

    func testParseDoesNotTreatBareTerminalHandleAsFileMention() {
        let parsed = UserMessageParser.parse("@remodex cache hit")

        XCTAssertEqual(parsed.mentions, [])
        XCTAssertEqual(parsed.body, "@remodex cache hit")
    }

    func testParseKeepsFileMentionWithLineNumber() {
        let parsed = UserMessageParser.parse("@Views/Turn/TurnView.swift:42 check this")

        XCTAssertEqual(parsed.mentions, ["Views/Turn/TurnView.swift:42"])
        XCTAssertEqual(parsed.body, "check this")
    }

    func testParseKeepsCommonExtensionlessFileMention() {
        let parsed = UserMessageParser.parse("@Makefile fix this target")

        XCTAssertEqual(parsed.mentions, ["Makefile"])
        XCTAssertEqual(parsed.body, "fix this target")
    }
}
