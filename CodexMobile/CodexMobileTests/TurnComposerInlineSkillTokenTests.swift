// FILE: TurnComposerInlineSkillTokenTests.swift
// Purpose: Verifies canonical round-tripping and atomic editing for inline composer skill tokens.
// Layer: Unit Test
// Exports: TurnComposerInlineSkillTokenTests
// Depends on: XCTest, UIKit, CodexMobile

import UIKit
import XCTest
@testable import CodexMobile

final class TurnComposerInlineSkillTokenTests: XCTestCase {
    private let font = UIFont.systemFont(ofSize: 15)

    func testSelectedSkillRoundTripsThroughAttributedDisplay() {
        let canonical = "$check-code please"
        let displayed = TurnComposerInlineSkillToken.displayAttributedString(
            canonicalText: canonical,
            mentionNames: ["check-code"],
            font: font,
            textColor: .label,
            tintColor: .systemIndigo
        )

        XCTAssertEqual(TurnComposerInlineSkillToken.canonicalText(from: displayed), canonical)
        XCTAssertTrue(displayed.string.contains("Check Code"))
        XCTAssertFalse(displayed.string.contains("$check-code"))
    }

    func testUnselectedLiteralSkillReferenceStaysPlainText() {
        let canonical = "$check-code please"
        let displayed = TurnComposerInlineSkillToken.displayAttributedString(
            canonicalText: canonical,
            mentionNames: [],
            font: font,
            textColor: .label,
            tintColor: .systemIndigo
        )

        XCTAssertEqual(displayed.string, canonical)
        XCTAssertEqual(TurnComposerInlineSkillToken.canonicalText(from: displayed), canonical)
    }

    func testEditingRangeExpandsAcrossWholeToken() throws {
        let displayed = attributedToken(in: "before $check-code after")
        let tokenRange = try XCTUnwrap(tokenRange(in: displayed))
        let partialRange = NSRange(location: tokenRange.location + 1, length: 1)

        XCTAssertEqual(
            TurnComposerInlineSkillToken.expandedEditingRange(for: partialRange, in: displayed),
            tokenRange
        )
    }

    func testCaretInsideTokenSnapsToNearestBoundary() throws {
        let displayed = attributedToken(in: "$check-code after")
        let tokenRange = try XCTUnwrap(tokenRange(in: displayed))

        XCTAssertEqual(
            TurnComposerInlineSkillToken.snappedSelection(
                NSRange(location: tokenRange.location + 1, length: 0),
                in: displayed
            ),
            NSRange(location: tokenRange.location, length: 0)
        )
    }

    private func attributedToken(in canonical: String) -> NSAttributedString {
        TurnComposerInlineSkillToken.displayAttributedString(
            canonicalText: canonical,
            mentionNames: ["check-code"],
            font: font,
            textColor: .label,
            tintColor: .systemIndigo
        )
    }

    private func tokenRange(in attributed: NSAttributedString) -> NSRange? {
        var result: NSRange?
        attributed.enumerateAttribute(
            TurnComposerInlineSkillToken.attributeKey,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, stop in
            guard value != nil else { return }
            result = range
            stop.pointee = true
        }
        return result
    }
}
