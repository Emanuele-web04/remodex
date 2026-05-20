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

    func testMarkdownFormatterDoesNotLinkifyInlineShellCommands() {
        let command = "`node --test phodex-bridge/test/bridge.test.js phodex-bridge/test/rollout-live-mirror.test.js phodex-bridge/test/secure-transport.test.js`"

        let rendered = MarkdownTextFormatter.renderableText(
            from: "Verificato: \(command) passa 77/77.",
            profile: .assistantProse,
            usesCache: false
        )

        XCTAssertEqual(rendered, "Verificato: \(command) passa 77/77.")
    }

    func testMarkdownFormatterStillLinkifiesSingleInlineCodeFileReference() {
        let rendered = MarkdownTextFormatter.renderableText(
            from: "Verificato: `phodex-bridge/test/secure-transport.test.js` passa.",
            profile: .assistantProse,
            usesCache: false
        )

        XCTAssertEqual(
            rendered,
            "Verificato: [secure-transport.test.js](phodex-bridge/test/secure-transport.test.js) passa."
        )
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

    func testAttachmentContentFingerprintSeparatesSamePrefixSameLengthPayloads() {
        let sharedPrefix = "data:image/jpeg;base64," + String(repeating: "A", count: 64)
        let firstPayload = sharedPrefix + "B" + String(repeating: "C", count: 64)
        let secondPayload = sharedPrefix + "D" + String(repeating: "C", count: 64)
        let firstAttachment = CodexImageAttachment(
            id: "image",
            thumbnailBase64JPEG: "thumbnail",
            payloadDataURL: firstPayload
        )
        let secondAttachment = CodexImageAttachment(
            id: "image",
            thumbnailBase64JPEG: "thumbnail",
            payloadDataURL: secondPayload
        )

        XCTAssertEqual(firstPayload.utf8.count, secondPayload.utf8.count)
        XCTAssertEqual(Array(firstPayload.utf8.prefix(24)), Array(secondPayload.utf8.prefix(24)))
        XCTAssertNotEqual(firstAttachment.payloadContentFingerprint, secondAttachment.payloadContentFingerprint)
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

    func testTimelineClippingKeepsTailForCompletedLongRows() {
        let message = CodexMessage(
            id: "long-assistant",
            threadId: "thread-1",
            role: .assistant,
            kind: .chat,
            text: String(repeating: "a", count: 36_000) + "TAIL-MARKER",
            isStreaming: false
        )

        let displayText = timelineDisplayText(for: message)

        XCTAssertTrue(displayText.contains("\n\n...\n\n"))
        XCTAssertTrue(displayText.hasSuffix("TAIL-MARKER"))
        XCTAssertLessThan(displayText.count, message.text.count)
    }

    func testTimelineClippingRespectsByteLimitForUnicodeRows() {
        let message = CodexMessage(
            id: "unicode-assistant",
            threadId: "thread-1",
            role: .assistant,
            kind: .chat,
            text: String(repeating: "é", count: 20_000) + "TAIL",
            isStreaming: false
        )

        let displayText = timelineDisplayText(for: message)

        XCTAssertTrue(displayText.contains("\n\n...\n\n"))
        XCTAssertTrue(displayText.hasSuffix("TAIL"))
        XCTAssertLessThanOrEqual(displayText.utf8.count, 32_000)
    }

    func testTimelineClippingExpandsInlineWithoutMutatingSourceText() {
        let message = CodexMessage(
            id: "expandable-assistant",
            threadId: "thread-1",
            role: .assistant,
            kind: .chat,
            text: String(repeating: "a", count: 90_000) + "TAIL",
            isStreaming: false
        )

        let initialWindow = timelineDisplayWindow(for: message, expansionLevel: 0)
        let expandedWindow = timelineDisplayWindow(for: message, expansionLevel: 1)

        XCTAssertTrue(initialWindow.isPartial)
        XCTAssertTrue(expandedWindow.isPartial)
        XCTAssertGreaterThan(expandedWindow.text.utf8.count, initialWindow.text.utf8.count)
        XCTAssertLessThan(expandedWindow.hiddenByteCount, initialWindow.hiddenByteCount)
        XCTAssertEqual(message.text.suffix(4), "TAIL")
    }

    func testTimelineSelectableActionTextDoesNotTrimHugeRowsOnRender() {
        let largeText = "\n" + String(repeating: "a", count: 80_000) + "TAIL\n"

        XCTAssertEqual(timelineSelectableActionText(largeText), largeText)
    }

    func testFileChangeRenderModelParsesFullTextButKeepsDisplayFallbackBounded() {
        let fullText = """
        Preparing file summary.
        \(String(repeating: "context\n", count: 200))
        - Edited Sources/Deep/File.swift (+12 -3)
        """
        let displayText = "Preparing file summary.\n\n..."
        let message = CodexMessage(
            id: "file-change-full-source",
            threadId: "thread-1",
            role: .system,
            kind: .fileChange,
            text: fullText
        )

        let renderModel = MessageRowRenderModelCache.model(for: message, displayText: displayText)

        XCTAssertEqual(renderModel.fileChangeState?.summary?.entries.first?.path, "Sources/Deep/File.swift")
        XCTAssertEqual(renderModel.fileChangeState?.summary?.entries.first?.additions, 12)
        XCTAssertEqual(renderModel.fileChangeState?.summary?.entries.first?.deletions, 3)
        XCTAssertEqual(renderModel.fileChangeState?.bodyText, displayText)
        XCTAssertNotEqual(renderModel.fileChangeState?.detailBodyText, displayText)
    }

    func testLargeFileChangeRenderModelDoesNotReuseCachedDetailText() {
        let displayText = "- Edited Sources/Large.swift (+1 -0)"
        let firstText = displayText + "\n" + String(repeating: "A", count: 140_000) + "FIRST-DETAIL"
        let secondText = displayText + "\n" + String(repeating: "B", count: 140_000) + "SECOND-DETAIL"
        let firstMessage = CodexMessage(
            id: "large-file-change-cache",
            threadId: "thread-1",
            role: .system,
            kind: .fileChange,
            text: firstText
        )
        let secondMessage = CodexMessage(
            id: "large-file-change-cache",
            threadId: "thread-1",
            role: .system,
            kind: .fileChange,
            text: secondText
        )

        let first = MessageRowRenderModelCache.model(for: firstMessage, displayText: displayText)
        let second = MessageRowRenderModelCache.model(for: secondMessage, displayText: displayText)

        XCTAssertTrue(first.fileChangeState?.detailBodyText.contains("FIRST-DETAIL") == true)
        XCTAssertTrue(second.fileChangeState?.detailBodyText.contains("SECOND-DETAIL") == true)
        XCTAssertFalse(second.fileChangeState?.detailBodyText.contains("FIRST-DETAIL") == true)
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

    func testCommandOutputImageReferenceParserIgnoresGlobCandidates() {
        let reference = CommandOutputImageReferenceParser.firstReference(
            command: "rg --files -g '*.png'",
            outputTail: "*.png",
            cwd: "/Users/example/project"
        )

        XCTAssertNil(reference)
    }

    func testCommandOutputImageReferenceParserKeepsBracketedFileNames() {
        let reference = CommandOutputImageReferenceParser.firstReference(
            command: "echo done",
            outputTail: "/Users/example/project/Screenshot [1].png",
            cwd: "/Users/example/project"
        )

        XCTAssertEqual(reference?.path, "/Users/example/project/Screenshot [1].png")
    }

    func testCommandOutputImageReferenceParserKeepsTemporaryImagePaths() {
        let reference = CommandOutputImageReferenceParser.firstReference(
            command: "echo done",
            outputTail: "/tmp/remodex-preview.png",
            cwd: "/Users/example/project"
        )

        XCTAssertEqual(reference?.path, "/tmp/remodex-preview.png")
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

    func testAssistantMarkdownImageReferenceParserReadsEscapedAnglePathWithClosingParenthesis() {
        let path = "/Users/example/generated images/final)%20 mock.png"
        let markdownPath = CodexService.markdownImagePath(path)
        let text = "![Generated image](\(markdownPath))"

        let references = AssistantMarkdownImageReferenceParser.references(in: text)

        XCTAssertEqual(markdownPath, "</Users/example/generated images/final%29%2520 mock.png>")
        XCTAssertEqual(references.map(\.path), [path])
        XCTAssertEqual(
            CodexService.markdownImagePath("/Users/example/final%20mock.png"),
            "</Users/example/final%2520mock.png>"
        )
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
        XCTAssertTrue(renderModel.assistantInlineContentSegments.isEmpty)
    }

    func testAssistantMarkdownSegmentsKeepTemporaryImagePosition() {
        let text = "Before\n![mobile](/tmp/emanuele-mobile.png)\nAfter"
        let segments = AssistantMarkdownImageReferenceParser.contentSegmentsPreservingTemporaryImages(from: text)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .text(id: 0, value: "Before\n"))
        XCTAssertEqual(segments[1], .image(AssistantMarkdownImageReference(
            path: "/tmp/emanuele-mobile.png",
            altText: "mobile",
            occurrenceIndex: 0
        )))
        XCTAssertEqual(segments[2], .text(id: 1, value: "\nAfter"))
    }

    func testAssistantMarkdownSegmentsLeaveGeneratedImageForTrailingPreview() {
        let text = """
        Before
        ![Generated image](/Users/example/.codex/generated_images/thread/wing.png)
        After
        """
        let segments = AssistantMarkdownImageReferenceParser.contentSegmentsPreservingTemporaryImages(from: text)

        XCTAssertEqual(segments, [.text(id: 0, value: "Before\n\nAfter")])
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
        let firstText = fileChangeText(path: "A.swift")
        let secondText = fileChangeText(path: "B.swift")
        let first = FileChangeSystemRenderCache.renderState(
            messageID: "file-change-cache",
            sourceText: firstText,
            displayText: firstText
        )
        let second = FileChangeSystemRenderCache.renderState(
            messageID: "file-change-cache",
            sourceText: secondText,
            displayText: secondText
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
