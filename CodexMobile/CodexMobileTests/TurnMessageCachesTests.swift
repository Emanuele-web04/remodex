// FILE: TurnMessageCachesTests.swift
// Purpose: Guards cache keys against equal-length collisions so scrolling optimizations stay correct.
// Layer: Unit Test
// Exports: TurnMessageCachesTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnMessageCachesTests: XCTestCase {
    override func tearDown() {
        TurnCacheManager.resetAll()
        super.tearDown()
    }

    func testMarkdownRenderableTextCacheSeparatesEqualLengthTexts() {
        var buildCount = 0

        let first = MarkdownRenderableTextCache.rendered(raw: "alpha", profile: .assistantProse) {
            buildCount += 1
            return "first"
        }
        let second = MarkdownRenderableTextCache.rendered(raw: "omega", profile: .assistantProse) {
            buildCount += 1
            return "second"
        }
        let firstAgain = MarkdownRenderableTextCache.rendered(raw: "alpha", profile: .assistantProse) {
            buildCount += 1
            return "unexpected"
        }

        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "second")
        XCTAssertEqual(firstAgain, "first")
        XCTAssertEqual(buildCount, 2)
    }

    func testMessageRowRenderModelCacheSeparatesEqualLengthCommandTexts() {
        let runningMessage = CodexMessage(
            id: "message-row-cache",
            threadId: "thread-1",
            role: .system,
            kind: .commandExecution,
            text: ""
        )
        let stoppedMessage = CodexMessage(
            id: "message-row-cache",
            threadId: "thread-1",
            role: .system,
            kind: .commandExecution,
            text: ""
        )

        let running = MessageRowRenderModelCache.model(for: runningMessage, displayText: "Running npm")
        let stopped = MessageRowRenderModelCache.model(for: stoppedMessage, displayText: "Stopped npm")

        XCTAssertEqual(running.commandStatus?.statusLabel, "running")
        XCTAssertEqual(stopped.commandStatus?.statusLabel, "stopped")
    }

    func testCommandExecutionStatusCacheSeparatesEqualLengthTexts() {
        let running = CommandExecutionStatusCache.status(messageID: "command-cache", text: "Running npm")
        let stopped = CommandExecutionStatusCache.status(messageID: "command-cache", text: "Stopped npm")

        XCTAssertEqual(running?.statusLabel, "running")
        XCTAssertEqual(stopped?.statusLabel, "stopped")
    }

    func testFileChangeRenderCacheSeparatesEqualLengthTexts() {
        let first = FileChangeSystemRenderCache.renderState(
            messageID: "file-change-cache",
            sourceText: fileChangeText(path: "A.swift")
        )
        let second = FileChangeSystemRenderCache.renderState(
            messageID: "file-change-cache",
            sourceText: fileChangeText(path: "B.swift")
        )

        XCTAssertEqual(first.summary?.entries.first?.path, "A.swift")
        XCTAssertEqual(second.summary?.entries.first?.path, "B.swift")
    }

    private func fileChangeText(path: String) -> String {
        """
        Status: completed

        Path: \(path)
        Kind: update
        Totals: +1 -0
        """
    }
}
