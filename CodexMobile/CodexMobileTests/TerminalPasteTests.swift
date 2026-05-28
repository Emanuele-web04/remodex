// FILE: TerminalPasteTests.swift
// Purpose: Verifies terminal paste payloads respect bracketed-paste mode and chunking.
// Layer: Unit Test
// Exports: TerminalPasteTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class TerminalPasteTests: XCTestCase {
    func testSnapshotTracksBracketedPasteModeFromOutput() {
        var snapshot = RemodexTerminalSnapshot.idleSnapshot(terminalId: "term-1")

        snapshot.appendOutput(Data("prompt \u{1B}[?2004h".utf8))
        XCTAssertTrue(snapshot.bracketedPasteEnabled)

        snapshot.appendOutput(Data("prompt \u{1B}[?2004l".utf8))
        XCTAssertFalse(snapshot.bracketedPasteEnabled)
    }

    func testSnapshotTracksSplitBracketedPasteModeSequence() {
        var snapshot = RemodexTerminalSnapshot.idleSnapshot(terminalId: "term-1")

        snapshot.appendOutput(Data("prompt \u{1B}[?20".utf8))
        snapshot.appendOutput(Data("04h".utf8))

        XCTAssertTrue(snapshot.bracketedPasteEnabled)
    }

    func testPastePayloadWrapsOnlyWhenBracketedPasteIsEnabled() {
        let plainPaste = String(decoding: TerminalScreen.terminalPasteInputChunks(
            for: "echo hi",
            bracketedPasteEnabled: false
        ).joinedData(), as: UTF8.self)

        let bracketedPaste = String(decoding: TerminalScreen.terminalPasteInputChunks(
            for: "echo hi",
            bracketedPasteEnabled: true
        ).joinedData(), as: UTF8.self)

        XCTAssertEqual(plainPaste, "echo hi")
        XCTAssertEqual(bracketedPaste, "\u{1B}[200~echo hi\u{1B}[201~")
    }

    func testPastePayloadNormalizesNewlinesAndStripsUnsafeDelimiters() {
        let chunks = TerminalScreen.terminalPasteInputChunks(
            for: "one\r\ntwo\n\u{0}\u{1B}[201~three",
            bracketedPasteEnabled: true
        )
        let payload = String(decoding: chunks.joinedData(), as: UTF8.self)

        XCTAssertEqual(payload, "\u{1B}[200~one\rtwo\rthree\u{1B}[201~")
    }

    func testPastePayloadChunksLargeInput() {
        let chunks = TerminalScreen.terminalPasteInputChunks(
            for: String(repeating: "x", count: 20),
            bracketedPasteEnabled: false,
            maxChunkBytes: 8
        )

        XCTAssertEqual(chunks.map(\.count), [8, 8, 4])
    }
}

private extension Array where Element == Data {
    func joinedData() -> Data {
        reduce(into: Data()) { result, chunk in
            result.append(chunk)
        }
    }
}
