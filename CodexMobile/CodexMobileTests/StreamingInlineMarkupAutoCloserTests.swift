// FILE: StreamingInlineMarkupAutoCloserTests.swift
// Purpose: Guards the virtual-closer rewrites that keep streaming inline markdown flicker-free.
// Layer: Unit Test
// Exports: StreamingInlineMarkupAutoCloserTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class StreamingInlineMarkupAutoCloserTests: XCTestCase {
    // MARK: - Balanced input passes through

    func testEmptyTextUnchanged() {
        XCTAssertEqual(StreamingInlineMarkupAutoCloser.autoClosed(""), "")
    }

    func testBalancedInlineMarkupUnchanged() {
        let text = "use `getUser()` and **bold** text"
        XCTAssertEqual(StreamingInlineMarkupAutoCloser.autoClosed(text), text)
    }

    func testPlainProseUnchanged() {
        let text = "niente markdown qui, solo testo"
        XCTAssertEqual(StreamingInlineMarkupAutoCloser.autoClosed(text), text)
    }

    // MARK: - Open spans with content get virtual closers

    func testOpenCodeSpanWithContentIsClosed() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("use `getUs"),
            "use `getUs`"
        )
    }

    func testOpenBoldWithContentIsClosed() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("this is **import"),
            "this is **import**"
        )
    }

    func testNestedOpenBoldAndCodeCloseInnerFirst() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("**bold `code"),
            "**bold `code`**"
        )
    }

    func testTrailingWhitespaceTrimmedBeforeBoldCloser() {
        // "**bold **" would parse as literal asterisks, so the rendering copy
        // drops the invisible trailing space before closing.
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("**bold "),
            "**bold**"
        )
    }

    // MARK: - Bare openers are held back instead of flashing raw

    func testBareTrailingBacktickIsHeldBack() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("see `"),
            "see "
        )
    }

    func testBareTrailingBoldOpenerIsHeldBack() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("this is **"),
            "this is "
        )
    }

    func testBareCodeOpenerInsideOpenBoldClosesBold() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("**bold `"),
            "**bold**"
        )
    }

    // MARK: - Fenced code is untouched

    func testOpenFenceIsUntouched() {
        let text = "intro\n\n```swift\nlet x = `raw` ** stars"
        XCTAssertEqual(StreamingInlineMarkupAutoCloser.autoClosed(text), text)
    }

    func testMarkersInsideClosedFenceAreIgnored() {
        let text = "```\na ` b ** c\n```\nafter"
        XCTAssertEqual(StreamingInlineMarkupAutoCloser.autoClosed(text), text)
    }

    func testOpenSpanAfterClosedFenceIsClosed() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("```\ncode\n```\nthen `inline"),
            "```\ncode\n```\nthen `inline`"
        )
    }

    // MARK: - Left-flanking rule (operators stay literal)

    func testDoubleStarOperatorInProseStaysLiteral() {
        // "**" followed by whitespace is not a CommonMark opener; auto-closing it
        // would append phantom asterisks to math like "2 ** 3".
        let text = "risultato: 2 ** 3 == 8 fatto"
        XCTAssertEqual(StreamingInlineMarkupAutoCloser.autoClosed(text), text)
    }

    func testTrailingDoubleStarAfterOperatorIsHeldBack() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("2 ** 3 == 8**"),
            "2 ** 3 == 8"
        )
    }

    func testDoubleStarAtNonFinalLineEndStaysLiteral() {
        let text = "peso **\naltro testo"
        XCTAssertEqual(StreamingInlineMarkupAutoCloser.autoClosed(text), text)
    }

    // MARK: - Escapes and edge cases

    func testEscapedMarkersDoNotOpenSpans() {
        let text = "literal \\` and \\*\\* stay raw"
        XCTAssertEqual(StreamingInlineMarkupAutoCloser.autoClosed(text), text)
    }

    func testCodeSpanStateSurvivesLineBreakWithinParagraph() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("wraps `spanning\ncontent"),
            "wraps `spanning\ncontent`"
        )
    }

    func testListLineWithSingleStarIsNotBold() {
        let text = "* item one\n* item two"
        XCTAssertEqual(StreamingInlineMarkupAutoCloser.autoClosed(text), text)
    }

    func testCompletedCodeSpanCountsAsBoldContent() {
        XCTAssertEqual(
            StreamingInlineMarkupAutoCloser.autoClosed("**`code`"),
            "**`code`**"
        )
    }
}
