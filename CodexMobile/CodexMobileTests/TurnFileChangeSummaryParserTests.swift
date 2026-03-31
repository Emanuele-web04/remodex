// FILE: TurnFileChangeSummaryParserTests.swift
// Purpose: Verifies file-change parsing deduplicates repeated file entries and exposes stable dedupe keys.
// Layer: Unit Test
// Exports: TurnFileChangeSummaryParserTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class TurnFileChangeSummaryParserTests: XCTestCase {
    func testParseConsolidatesRepeatedEntriesForSamePath() {
        let source = """
        Edited orchestrator-config-v1.example.json +2 -0
        Edited orchestrator-config-v1.example.json +2 -0
        """

        let summary = TurnFileChangeSummaryParser.parse(from: source)

        XCTAssertEqual(summary?.entries.count, 1)
        XCTAssertEqual(summary?.entries.first?.path, "orchestrator-config-v1.example.json")
        XCTAssertEqual(summary?.entries.first?.additions, 4)
        XCTAssertEqual(summary?.entries.first?.deletions, 0)
    }

    func testDedupeKeyIgnoresStatusOnlyDifferences() {
        let streaming = """
        Status: inProgress

        Path: Sources/App.swift
        Kind: update
        Totals: +2 -1
        """

        let completed = """
        Status: completed

        Path: Sources/App.swift
        Kind: update
        Totals: +2 -1
        """

        XCTAssertEqual(
            TurnFileChangeSummaryParser.dedupeKey(from: streaming),
            TurnFileChangeSummaryParser.dedupeKey(from: completed)
        )
    }

    func testRepeatedParseAndDedupeKeyStayStableForSameText() {
        let source = """
        Edited Sources/App.swift +2 -1
        Edited Sources/Composer.swift +3 -0
        """

        let expectedSummary = TurnFileChangeSummaryParser.parse(from: source)
        let expectedKey = TurnFileChangeSummaryParser.dedupeKey(from: source)

        for _ in 0..<5 {
            XCTAssertEqual(
                TurnFileChangeSummaryParser.parse(from: source)?.entries,
                expectedSummary?.entries
            )
            XCTAssertEqual(TurnFileChangeSummaryParser.dedupeKey(from: source), expectedKey)
        }
    }
}
