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

    func testCommandOutputImageReferenceParserCombinesLsDirectoryAndOutputFile() {
        let reference = CommandOutputImageReferenceParser.firstReference(
            command: "/bin/zsh -lc 'ls -1 /Users/example/.codex/generated_images/turn-123'",
            outputTail: "hero image.png\nnotes.txt",
            cwd: "/Users/example/project"
        )

        XCTAssertEqual(
            reference?.path,
            "/Users/example/.codex/generated_images/turn-123/hero image.png"
        )
        XCTAssertEqual(reference?.fileName, "hero image.png")
    }

    func testCommandOutputImageReferenceParserFindsMarkdownImagePath() {
        let reference = CommandOutputImageReferenceParser.firstReference(
            command: "echo done",
            outputTail: "Created ![preview](/Users/example/project/out/mockup.webp)",
            cwd: "/Users/example/project"
        )

        XCTAssertEqual(reference?.path, "/Users/example/project/out/mockup.webp")
    }

    func testAssistantMarkdownImageReferenceParserFindsLocalImage() {
        let references = AssistantMarkdownImageReferenceParser.references(
            in: "Here it is:\n![wing](/Users/example/.codex/generated_images/turn/wing.png)"
        )

        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?.path, "/Users/example/.codex/generated_images/turn/wing.png")
        XCTAssertEqual(references.first?.displayTitle, "wing")
    }

    func testAssistantMarkdownImageReferenceParserKeepsDuplicatePathsDistinct() {
        let references = AssistantMarkdownImageReferenceParser.references(
            in: """
            ![first](/Users/example/wing.png)
            ![second](/Users/example/wing.png)
            """
        )

        XCTAssertEqual(references.map(\.path), [
            "/Users/example/wing.png",
            "/Users/example/wing.png"
        ])
        XCTAssertEqual(Set(references.map(\.id)).count, 2)
    }

    func testAssistantMarkdownImageReferenceParserRemovesImageOnlyLines() {
        let visibleText = AssistantMarkdownImageReferenceParser.visibleTextRemovingImageSyntax(
            from: "Before\n![wing](/Users/example/wing.png)\nAfter"
        )

        XCTAssertEqual(visibleText, "Before\nAfter")
    }

    func testAssistantMarkdownImageReferenceParserIgnoresCodeExamples() {
        let text = """
        Inline `![inline](/Users/example/inline.png)` stays literal.

        ```markdown
        ![fenced](/Users/example/fenced.png)
        ```

        ![real](/Users/example/real.png)
        """

        let references = AssistantMarkdownImageReferenceParser.references(in: text)
        let visibleText = AssistantMarkdownImageReferenceParser.visibleTextRemovingImageSyntax(from: text)

        XCTAssertEqual(references.map(\.path), ["/Users/example/real.png"])
        XCTAssertTrue(visibleText.contains("`![inline](/Users/example/inline.png)`"))
        XCTAssertTrue(visibleText.contains("![fenced](/Users/example/fenced.png)"))
        XCTAssertFalse(visibleText.contains("![real](/Users/example/real.png)"))
    }

    func testMessageRowRenderModelCachesAssistantImageReferences() {
        let text = "Before\n![wing](/Users/example/wing.png)\nAfter"
        let message = CodexMessage(
            id: "assistant-image-cache",
            threadId: "thread-1",
            role: .assistant,
            text: text
        )

        let renderModel = MessageRowRenderModelCache.model(for: message, displayText: text)

        XCTAssertEqual(renderModel.assistantImageReferences.first?.path, "/Users/example/wing.png")
        XCTAssertEqual(renderModel.assistantTextWithoutImageSyntax, "Before\nAfter")
    }

    func testMessageRowRenderModelStripsImagesBeforeMermaidParsing() {
        let text = """
        Intro
        ![wing](/Users/example/wing.png)
        ```mermaid
        graph TD
          A --> B
        ```
        Outro
        """
        let message = CodexMessage(
            id: "assistant-image-mermaid-cache",
            threadId: "thread-1",
            role: .assistant,
            text: text
        )

        let renderModel = MessageRowRenderModelCache.model(for: message, displayText: text)
        let markdownSegments = renderModel.mermaidContent?.segments.compactMap { segment -> String? in
            if case .markdown(let markdown) = segment.kind {
                return markdown
            }
            return nil
        } ?? []

        XCTAssertEqual(renderModel.assistantImageReferences.first?.path, "/Users/example/wing.png")
        XCTAssertFalse(markdownSegments.joined(separator: "\n").contains("![wing]"))
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
