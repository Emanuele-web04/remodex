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

    func testStableTextFingerprintChangesForUnsampledTextEdits() {
        let prefix = String(repeating: "a", count: 48)
        let suffix = String(repeating: "z", count: 48)
        let first = "\(prefix)middle-one\(suffix)"
        let second = "\(prefix)middle-two\(suffix)"

        XCTAssertNotEqual(
            TurnTextCacheKey.stableFingerprint(for: first),
            TurnTextCacheKey.stableFingerprint(for: second)
        )
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

    func testPerFileDiffParserKeepsSameNamedFilesInDifferentDirectoriesSeparate() {
        let bodyText = """
        Path: Sources/FeatureA/TurnMessageComponents.swift
        Kind: update
        Totals: +1 -0

        ```diff
        @@ -1,3 +1,4 @@
        +let featureA = true
        ```

        Path: Sources/FeatureB/TurnMessageComponents.swift
        Kind: update
        Totals: +1 -0

        ```diff
        @@ -1,3 +1,4 @@
        +let featureB = true
        ```
        """
        let entries = [
            TurnFileChangeSummaryEntry(
                path: "Sources/FeatureA/TurnMessageComponents.swift",
                additions: 1,
                deletions: 0,
                action: .edited
            ),
            TurnFileChangeSummaryEntry(
                path: "Sources/FeatureB/TurnMessageComponents.swift",
                additions: 1,
                deletions: 0,
                action: .edited
            ),
        ]

        let chunks = PerFileDiffParser.parse(bodyText: bodyText, entries: entries)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map(\.path), entries.map(\.path))
    }

    func testPerFileDiffParserDoesNotMergeBareFilenameWithDirectoryScopedPath() {
        let bodyText = """
        Path: TurnMessageComponents.swift
        Kind: update
        Totals: +1 -0

        ```diff
        @@ -1,3 +1,4 @@
        +let filenameOnly = true
        ```

        Path: Sources/FeatureA/TurnMessageComponents.swift
        Kind: update
        Totals: +1 -0

        ```diff
        @@ -1,3 +1,4 @@
        +let directoryScoped = true
        ```
        """
        let entries = [
            TurnFileChangeSummaryEntry(
                path: "TurnMessageComponents.swift",
                additions: 1,
                deletions: 0,
                action: .edited
            ),
            TurnFileChangeSummaryEntry(
                path: "Sources/FeatureA/TurnMessageComponents.swift",
                additions: 1,
                deletions: 0,
                action: .edited
            ),
        ]

        let chunks = PerFileDiffParser.parse(bodyText: bodyText, entries: entries)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map(\.path), entries.map(\.path))
    }

    func testPerFileDiffParserMergesMultipleSnapshotsForSameFile() {
        let bodyText = """
        Path: /Users/emanueledipietro/Developer/Remodex/CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift
        Kind: update
        Totals: +1 -0

        ```diff
        @@ -1,3 +1,4 @@
        +let firstChange = true
        ```

        Path: CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift
        Kind: update
        Totals: +1 -0

        ```diff
        @@ -10,3 +10,4 @@
        +let secondChange = true
        ```
        """
        let entries = [
            TurnFileChangeSummaryEntry(
                path: "/Users/emanueledipietro/Developer/Remodex/CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift",
                additions: 1,
                deletions: 0,
                action: .edited
            ),
            TurnFileChangeSummaryEntry(
                path: "CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift",
                additions: 1,
                deletions: 0,
                action: .edited
            ),
        ]

        let chunks = PerFileDiffParser.parse(bodyText: bodyText, entries: entries)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.path, "CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift")
        XCTAssertEqual(chunks.first?.additions, 2)
        XCTAssertTrue(chunks.first?.diffCode.contains("firstChange") == true)
        XCTAssertTrue(chunks.first?.diffCode.contains("secondChange") == true)
    }

    func testPerFileDiffParserDeduplicatesIdenticalSnapshotsForSameFile() {
        let bodyText = """
        Path: /Users/emanueledipietro/Developer/Remodex/CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift
        Kind: update
        Totals: +1 -0

        ```diff
        @@ -1,3 +1,4 @@
        +let duplicateChange = true
        ```

        Path: CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift
        Kind: update
        Totals: +1 -0

        ```diff
        @@ -1,3 +1,4 @@
        +let duplicateChange = true
        ```
        """
        let entries = [
            TurnFileChangeSummaryEntry(
                path: "/Users/emanueledipietro/Developer/Remodex/CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift",
                additions: 1,
                deletions: 0,
                action: .edited
            ),
            TurnFileChangeSummaryEntry(
                path: "CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift",
                additions: 1,
                deletions: 0,
                action: .edited
            ),
        ]

        let chunks = PerFileDiffParser.parse(bodyText: bodyText, entries: entries)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.additions, 1)
        XCTAssertEqual(chunks.first?.deletions, 0)
    }

    func testFileChangeSummaryParserPrefersInlineTotalsWhenTheyFollowDiffBlock() {
        let text = """
        Status: completed

        Path: Sources/App.swift
        Kind: update

        ```diff
        @@ -1,3 +1,4 @@
        +let diffBackedFile = true
        ```

        Totals: +3 -1
        """

        let summary = TurnFileChangeSummaryParser.parse(from: text)

        XCTAssertEqual(summary?.entries.count, 1)
        XCTAssertEqual(summary?.entries.first?.path, "Sources/App.swift")
        XCTAssertEqual(summary?.entries.first?.additions, 3)
        XCTAssertEqual(summary?.entries.first?.deletions, 1)
    }

    func testFileChangeSummaryParserDoesNotDuplicateRepeatedPathWithoutNewEvidence() {
        let text = """
        Status: completed

        Path: Sources/App.swift
        Kind: update

        Path: Sources/App.swift
        Totals: +10 -3
        """

        let summary = TurnFileChangeSummaryParser.parse(from: text)

        XCTAssertEqual(summary?.entries.count, 1)
        XCTAssertEqual(summary?.entries.first?.path, "Sources/App.swift")
        XCTAssertEqual(summary?.entries.first?.additions, 10)
        XCTAssertEqual(summary?.entries.first?.deletions, 3)
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
