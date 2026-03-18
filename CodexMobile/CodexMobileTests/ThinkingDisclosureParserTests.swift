// FILE: ThinkingDisclosureParserTests.swift
// Purpose: Verifies compact reasoning summaries are extracted from standalone bold lines.
// Layer: Unit Test
// Exports: ThinkingDisclosureParserTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class ThinkingDisclosureParserTests: XCTestCase {
    func testParseBuildsDisclosureSectionsFromStandaloneBoldLines() {
        let parsed = ThinkingDisclosureParser.parse(
            from: """
            **Investigating scrolling issues**

            Auto-scroll looks tied to message count instead of height.

            **Examining auto-scroll triggers**

            The existing row mutates without changing the total count.
            """
        )

        XCTAssertTrue(parsed.showsDisclosure)
        XCTAssertEqual(parsed.sections.map(\.title), [
            "Investigating scrolling issues",
            "Examining auto-scroll triggers",
        ])
        XCTAssertEqual(
            parsed.sections[0].detail,
            "Auto-scroll looks tied to message count instead of height."
        )
        XCTAssertEqual(
            parsed.sections[1].detail,
            "The existing row mutates without changing the total count."
        )
    }

    func testParseKeepsFallbackWhenNoStandaloneBoldSummaryExists() {
        let parsed = ThinkingDisclosureParser.parse(
            from: "Thinking...\nI am checking the stream. **Inline emphasis** should stay in the body."
        )

        XCTAssertFalse(parsed.showsDisclosure)
        XCTAssertEqual(
            parsed.fallbackText,
            "I am checking the stream. **Inline emphasis** should stay in the body."
        )
    }

    func testParseCoalescesAdjacentDuplicateSummariesAndKeepsPreamble() {
        let parsed = ThinkingDisclosureParser.parse(
            from: """
            I am still gathering context.

            **Investigating scrolling issues**

            First snapshot.

            **Investigating scrolling issues**

            First snapshot.

            More detail from the final snapshot.
            """
        )

        XCTAssertEqual(parsed.sections.count, 1)
        XCTAssertEqual(parsed.sections[0].title, "Investigating scrolling issues")
        XCTAssertEqual(
            parsed.sections[0].detail,
            """
            I am still gathering context.

            First snapshot.

            More detail from the final snapshot.
            """
        )
    }

    func testCompactActivityPreviewReturnsLatestToolLine() {
        let preview = ThinkingDisclosureParser.compactActivityPreview(
            fromNormalizedText: """
            Running sed -n '80,140p' TurnComposerReviewModeTests.swift
            Running rg -n \"/subagents\" CodexMobile/CodexMobileTests
            """
        )

        XCTAssertEqual(
            preview,
            "Running rg -n \"/subagents\" CodexMobile/CodexMobileTests"
        )
    }

    func testCompactActivityPreviewKeepsFirstWrappedRunningLine() {
        let preview = ThinkingDisclosureParser.compactActivityPreview(
            fromNormalizedText: """
            Running sed -n '80,140p' TurnComposerReviewModeTests.swift
            .../Views/Turn/TurnMessageComponents.swift
            """
        )

        XCTAssertEqual(
            preview,
            "Running sed -n '80,140p' TurnComposerReviewModeTests.swift"
        )
    }

    func testCompactActivityPreviewKeepsReasoningBlocksExpanded() {
        let preview = ThinkingDisclosureParser.compactActivityPreview(
            fromNormalizedText: "I found the exact insertion point and I am updating the composer."
        )

        XCTAssertNil(preview)
    }
}
