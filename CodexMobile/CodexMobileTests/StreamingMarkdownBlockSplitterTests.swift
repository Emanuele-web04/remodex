// FILE: StreamingMarkdownBlockSplitterTests.swift
// Purpose: Guards the settled/active split invariants the streaming incremental path relies on.
// Layer: Unit Test
// Exports: StreamingMarkdownBlockSplitterTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class StreamingMarkdownBlockSplitterTests: XCTestCase {
    // MARK: - Basic splitting

    func testEmptyTextSplitsToEmptyParts() {
        let split = StreamingMarkdownBlockSplitter.split("")
        XCTAssertEqual(split.settled, "")
        XCTAssertEqual(split.active, "")
    }

    func testSingleBlockStaysActive() {
        let split = StreamingMarkdownBlockSplitter.split("just one paragraph")
        XCTAssertEqual(split.settled, "")
        XCTAssertEqual(split.active, "just one paragraph")
    }

    func testClosedBlockSettles() {
        let split = StreamingMarkdownBlockSplitter.split("para one\n\npara two")
        XCTAssertEqual(split.settled, "para one\n")
        XCTAssertEqual(split.active, "para two")
    }

    func testUnclosedFenceStaysActive() {
        // An open fence must keep streaming content in the active block, so a
        // still-typing code block never reflows the settled history above it.
        let split = StreamingMarkdownBlockSplitter.split("intro\n\n```swift\nlet x = 1\n\nstill inside")
        XCTAssertEqual(split.settled, "intro\n")
        XCTAssertTrue(split.active.hasPrefix("```swift"))
        XCTAssertTrue(split.active.hasSuffix("still inside"))
    }

    func testBlankLinesInsideFenceDoNotSplit() {
        let text = "```\nline\n\nmore\n```"
        let split = StreamingMarkdownBlockSplitter.split(text)
        XCTAssertEqual(split.settled, "")
        XCTAssertEqual(split.active, text)
    }

    // MARK: - Invariants the incremental streaming path relies on

    // fullText must always equal settled + "\n" + active (or just active when settled is
    // empty); StreamingAssistantMarkdownTextView derives the incremental tail offset from it.
    func testReconstructionInvariant() {
        let samples = [
            "a",
            "a\n\nb",
            "a\n\n\n\nb\n \n\t\nc",
            "# Head\n\npara\n\n- item1\n- item2",
            "intro\n\n```\ncode\n\ninside\n```\n\nafter",
            "ciao 👋🏼\n\nblocco 🇮🇹 due\n\n```\n🚀\n```",
            "   \n\t\nfirst\n\nsecond",
            "p1\n\np2\n\np3\n\np4\n\np5",
        ]
        for text in samples {
            let split = StreamingMarkdownBlockSplitter.split(text)
            let reconstructed = split.settled.isEmpty
                ? split.active
                : split.settled + "\n" + split.active
            XCTAssertEqual(reconstructed, text, "reconstruction failed for \(text.debugDescription)")
        }
    }

    // The incremental composition rule used by setFullText: re-splitting only the previous
    // active block plus the delta must produce the same state as re-splitting the whole text.
    func testIncrementalCompositionMatchesFullSplitAcrossFuzzedStreams() {
        let pieces = [
            "word", " tail", "…", "e ancora", "\n", "\n\n", "\n\n\n", "```", "```swift", "~~~",
            "# Heading", "> quote", "- item", "1. one", "|c1|c2|", "---", "***",
            "   ", "\t", "🚀🇮🇹", "à è ì", "`code`", "\ncontinuation", "\n   \n", "chiuso.", "```\n",
        ]
        var generator = SplitMix64(seed: 0x5EED_CAFE_F00D_2026)

        for streamIndex in 0..<300 {
            var accumulated = ""
            var settled = ""
            var active = ""

            let deltaCount = Int.random(in: 1...30, using: &generator)
            for deltaIndex in 0..<deltaCount {
                let delta = pieces[Int.random(in: 0..<pieces.count, using: &generator)]
                accumulated += delta

                // Incremental rule (mirrors StreamingAssistantMarkdownTextView.setFullText).
                let tail = active + delta
                let tailSplit = StreamingMarkdownBlockSplitter.split(tail)
                if !tailSplit.settled.isEmpty {
                    settled = settled.isEmpty ? tailSplit.settled : settled + "\n" + tailSplit.settled
                }
                active = tailSplit.active

                let full = StreamingMarkdownBlockSplitter.split(accumulated)
                XCTAssertEqual(
                    settled, full.settled,
                    "settled diverged at stream \(streamIndex) delta \(deltaIndex): \(accumulated.debugDescription)"
                )
                XCTAssertEqual(
                    active, full.active,
                    "active diverged at stream \(streamIndex) delta \(deltaIndex): \(accumulated.debugDescription)"
                )
                if settled != full.settled || active != full.active {
                    return
                }
            }
        }
    }

    // MARK: - Seam classification

    func testSeamMultipliersForEmptyTextAreZero() {
        XCTAssertEqual(StreamingMarkdownBlockSplitter.topSpacingMultiplier(forBlockStarting: ""), 0)
        XCTAssertEqual(StreamingMarkdownBlockSplitter.bottomSpacingMultiplier(forLastBlockOf: ""), 0)
    }

    func testHeadingSeamIsWiderThanParagraphSeam() {
        // Semantic guard, not exact constants: headings need more breathing room than prose,
        // mirroring RemodexTextKit's default block spacing.
        let headingTop = StreamingMarkdownBlockSplitter.topSpacingMultiplier(forBlockStarting: "# Title")
        let paragraphTop = StreamingMarkdownBlockSplitter.topSpacingMultiplier(forBlockStarting: "plain prose")
        XCTAssertGreaterThan(headingTop, paragraphTop)
        XCTAssertGreaterThan(paragraphTop, 0)
    }
}

// Deterministic RNG so the fuzzed streams are reproducible across runs and CI.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
