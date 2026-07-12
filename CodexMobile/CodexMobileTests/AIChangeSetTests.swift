// FILE: AIChangeSetTests.swift
// Purpose: Verifies patch parsing and turn-scoped AI change-set finalization for revertable responses.
// Layer: Unit Test
// Exports: AIChangeSetTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class AIChangeSetTests: XCTestCase {
    func testUnifiedPatchParserExtractsSingleFileUpdate() {
        let patch = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,3 @@
         struct App {}
        +let enabled = true
        -let disabled = false
        """

        let analysis = AIUnifiedPatchParser.analyze(patch)

        XCTAssertEqual(analysis.fileChanges.count, 1)
        XCTAssertEqual(analysis.fileChanges.first?.path, "Sources/App.swift")
        XCTAssertEqual(analysis.fileChanges.first?.kind, .update)
        XCTAssertEqual(analysis.fileChanges.first?.additions, 1)
        XCTAssertEqual(analysis.fileChanges.first?.deletions, 1)
        XCTAssertTrue(analysis.unsupportedReasons.isEmpty)
    }

    func testUnifiedPatchParserMarksRenameAsUnsupported() {
        let patch = """
        diff --git a/Old.swift b/New.swift
        similarity index 100%
        rename from Old.swift
        rename to New.swift
        """

        let analysis = AIUnifiedPatchParser.analyze(patch)

        XCTAssertTrue(analysis.fileChanges.isEmpty)
        XCTAssertTrue(
            analysis.unsupportedReasons.contains("Rename, mode-only, or symlink changes are not auto-revertable in v1.")
        )
    }

    func testTurnDiffFinalizesReadyChangeSetForAssistantMessage() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo")
        ]

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1111111..2222222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1 +1,2 @@
             struct App {}
            +let enabled = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.threadId, threadID)
        XCTAssertEqual(changeSet.turnId, turnID)
        XCTAssertEqual(changeSet.assistantMessageId, assistantMessage.id)
        XCTAssertEqual(changeSet.status, .ready)
        XCTAssertEqual(changeSet.repoRoot, "/tmp/repo")
    }

    func testProjectedTurnChangeSetsStaySeparateAcrossThreads() throws {
        let service = makeService()
        let firstThreadID = "thread-first"
        let secondThreadID = "thread-second"
        let projectedTurnID = "ipc-turn-0"
        service.threads = [
            CodexThread(id: firstThreadID, title: "First", cwd: "/tmp/first-repo"),
            CodexThread(id: secondThreadID, title: "Second", cwd: "/tmp/second-repo"),
        ]

        service.completeAssistantMessage(
            threadId: firstThreadID,
            turnId: projectedTurnID,
            itemId: nil,
            text: "Changed the first repository."
        )
        service.recordTurnDiffChangeSet(
            threadId: firstThreadID,
            turnId: projectedTurnID,
            diff: """
            diff --git a/Sources/First.swift b/Sources/First.swift
            index 1111111..2222222 100644
            --- a/Sources/First.swift
            +++ b/Sources/First.swift
            @@ -1 +1,2 @@
             struct First {}
            +let firstOnly = true
            """
        )

        service.completeAssistantMessage(
            threadId: secondThreadID,
            turnId: projectedTurnID,
            itemId: nil,
            text: "Changed the second repository."
        )
        service.recordTurnDiffChangeSet(
            threadId: secondThreadID,
            turnId: projectedTurnID,
            diff: """
            diff --git a/Sources/Second.swift b/Sources/Second.swift
            index 3333333..4444444 100644
            --- a/Sources/Second.swift
            +++ b/Sources/Second.swift
            @@ -1 +1,2 @@
             struct Second {}
            +let secondOnly = true
            """
        )

        service.recordTurnTerminalState(
            threadId: firstThreadID,
            turnId: projectedTurnID,
            state: .completed
        )
        service.noteTurnFinished(threadId: firstThreadID, turnId: projectedTurnID)
        service.recordTurnTerminalState(
            threadId: secondThreadID,
            turnId: projectedTurnID,
            state: .completed
        )
        service.noteTurnFinished(threadId: secondThreadID, turnId: projectedTurnID)

        let firstAssistant = try XCTUnwrap(
            service.messages(for: firstThreadID).last(where: { $0.role == .assistant })
        )
        let secondAssistant = try XCTUnwrap(
            service.messages(for: secondThreadID).last(where: { $0.role == .assistant })
        )
        // Exercise the turn-scoped assistant fallback rather than the primary
        // assistant-message index, which already has globally stable IDs.
        service.aiChangeSetIDByAssistantMessageID.removeAll()
        let firstChangeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: firstAssistant))
        let secondChangeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: secondAssistant))

        XCTAssertNotEqual(firstChangeSet.id, secondChangeSet.id)
        XCTAssertEqual(firstChangeSet.threadId, firstThreadID)
        XCTAssertEqual(secondChangeSet.threadId, secondThreadID)
        XCTAssertEqual(firstChangeSet.repoRoot, "/tmp/first-repo")
        XCTAssertEqual(secondChangeSet.repoRoot, "/tmp/second-repo")
        XCTAssertTrue(firstChangeSet.forwardUnifiedPatch.contains("firstOnly"))
        XCTAssertFalse(firstChangeSet.forwardUnifiedPatch.contains("secondOnly"))
        XCTAssertTrue(secondChangeSet.forwardUnifiedPatch.contains("secondOnly"))
        XCTAssertFalse(secondChangeSet.forwardUnifiedPatch.contains("firstOnly"))
        XCTAssertEqual(service.aiChangeSetIDByTurnKey.count, 2)
    }

    func testWorkspaceCheckpointDoesNotReplaceTurnDiffWhenFileScopeMatches() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/Runtime.swift b/Sources/Runtime.swift
            index 1111111..2222222 100644
            --- a/Sources/Runtime.swift
            +++ b/Sources/Runtime.swift
            @@ -1 +1,2 @@
             struct Runtime {}
            +let fromRuntime = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)
        service.recordWorkspaceCheckpointChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/Runtime.swift b/Sources/Runtime.swift
            index 3333333..4444444 100644
            --- a/Sources/Runtime.swift
            +++ b/Sources/Runtime.swift
            @@ -1 +1,2 @@
             struct Runtime {}
            +let fromCheckpoint = true
            """
        )

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.source, .turnDiff)
        XCTAssertEqual(changeSet.fileChanges.map(\.path), ["Sources/Runtime.swift"])
        XCTAssertTrue(changeSet.forwardUnifiedPatch.contains("fromRuntime"))
        XCTAssertFalse(changeSet.forwardUnifiedPatch.contains("fromCheckpoint"))
    }

    func testWorkspaceCheckpointDoesNotReplaceTurnDiffWhenFileScopeWidens() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             struct A {}
            +let fromRuntime = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)
        service.recordWorkspaceCheckpointChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             struct A {}
            +let fromRuntime = true
            diff --git a/Sources/B.swift b/Sources/B.swift
            index 3333333..4444444 100644
            --- a/Sources/B.swift
            +++ b/Sources/B.swift
            @@ -1 +1,2 @@
             struct B {}
            +let userOrBridgeChange = true
            """
        )

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.source, .turnDiff)
        XCTAssertEqual(changeSet.fileChanges.map(\.path), ["Sources/A.swift"])
        XCTAssertFalse(changeSet.forwardUnifiedPatch.contains("Sources/B.swift"))
    }

    func testTurnDiffReplacesWorkspaceCheckpointWhenItArrivesLater() throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordWorkspaceCheckpointChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             struct A {}
            +let checkpointChange = true
            diff --git a/Sources/B.swift b/Sources/B.swift
            index 3333333..4444444 100644
            --- a/Sources/B.swift
            +++ b/Sources/B.swift
            @@ -1 +1,2 @@
             struct B {}
            +let userOrBridgeChange = true
            """
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             struct A {}
            +let runtimeChange = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.source, .turnDiff)
        XCTAssertEqual(changeSet.fileChanges.map(\.path), ["Sources/A.swift"])
        XCTAssertTrue(changeSet.forwardUnifiedPatch.contains("runtimeChange"))
        XCTAssertFalse(changeSet.forwardUnifiedPatch.contains("Sources/B.swift"))
    }

    func testMultipleFallbackPatchesStayNotRevertable() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Made several edits."
        )
        service.recordFallbackFileChangePatch(
            threadId: threadID,
            turnId: turnID,
            patch: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             let a = 1
            +let b = 2
            """
        )
        service.recordFallbackFileChangePatch(
            threadId: threadID,
            turnId: turnID,
            patch: """
            diff --git a/Sources/B.swift b/Sources/B.swift
            index 3333333..4444444 100644
            --- a/Sources/B.swift
            +++ b/Sources/B.swift
            @@ -1 +1,2 @@
             let c = 3
            +let d = 4
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = try XCTUnwrap(service.aiChangeSet(forAssistantMessage: assistantMessage))

        XCTAssertEqual(changeSet.status, .notRevertable)
        XCTAssertTrue(
            changeSet.unsupportedReasons.contains(
                "This response emitted multiple file-change patches, so v1 cannot safely auto-revert it."
            )
        )
    }

    func testAssistantRevertPresentationIsSafeForDistinctFilesInSameRepo() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo"),
            CodexThread(id: siblingThreadID, title: "Sibling", cwd: "/tmp/repo")
        ]

        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )
        _ = recordReadyChangeSet(
            service: service,
            threadID: siblingThreadID,
            filePath: "README.md"
        )

        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: "/tmp/repo")
        )

        XCTAssertEqual(presentation.riskLevel, .safe)
        XCTAssertTrue(presentation.isEnabled)
        XCTAssertTrue(presentation.overlappingFiles.isEmpty)
    }

    func testAssistantRevertPresentationWarnsWhenSiblingTouchesSameFile() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo"),
            CodexThread(id: siblingThreadID, title: "Sibling", cwd: "/tmp/repo")
        ]

        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )
        _ = recordReadyChangeSet(
            service: service,
            threadID: siblingThreadID,
            filePath: "Sources/App.swift"
        )

        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: "/tmp/repo")
        )

        XCTAssertEqual(presentation.riskLevel, .warning)
        XCTAssertTrue(presentation.isEnabled)
        XCTAssertEqual(presentation.overlappingFiles, ["Sources/App.swift"])
    }

    func testAssistantRevertPresentationBlocksWhileSiblingRunIsStillActive() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo"),
            CodexThread(id: siblingThreadID, title: "Sibling", cwd: "/tmp/repo")
        ]

        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )

        service.markThreadAsRunning(siblingThreadID)

        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: "/tmp/repo")
        )

        XCTAssertEqual(presentation.riskLevel, .blocked)
        XCTAssertFalse(presentation.isEnabled)
        XCTAssertEqual(
            presentation.helperText,
            "Finish the active run in this repo before undoing this response."
        )
    }

    func testTimelineSnapshotInvalidatesWarningWhenSiblingChangeSetBecomesReverted() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "Revert", cwd: "/tmp/repo"),
            CodexThread(id: siblingThreadID, title: "Sibling", cwd: "/tmp/repo")
        ]

        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )
        let siblingMessage = recordReadyChangeSet(
            service: service,
            threadID: siblingThreadID,
            filePath: "Sources/App.swift"
        )

        XCTAssertEqual(
            service.timelineState(for: threadID).renderSnapshot.assistantRevertStatesByMessageID[assistantMessage.id]?.riskLevel,
            .warning
        )

        let siblingChangeSet = try XCTUnwrap(service.readyChangeSet(forAssistantMessage: siblingMessage))
        var revertedChangeSet = siblingChangeSet
        revertedChangeSet.status = .reverted
        service.aiChangeSetsByID[siblingChangeSet.id] = revertedChangeSet
        service.invalidateAssistantRevertStates()

        XCTAssertEqual(
            service.timelineState(for: threadID).renderSnapshot.assistantRevertStatesByMessageID[assistantMessage.id]?.riskLevel,
            .safe
        )
    }

    func testRememberRepoRootRefreshesOverlapAcrossSiblingSubdirectories() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let siblingThreadID = "thread-\(UUID().uuidString)"

        service.threads = [
            CodexThread(id: threadID, title: "App", cwd: "/tmp/repo/app"),
            CodexThread(id: siblingThreadID, title: "Docs", cwd: "/tmp/repo/docs")
        ]

        service.rememberRepoRoot("/tmp/repo", forWorkingDirectory: "/tmp/repo/docs")
        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "README.md"
        )
        _ = recordReadyChangeSet(
            service: service,
            threadID: siblingThreadID,
            filePath: "README.md"
        )

        XCTAssertEqual(
            service.timelineState(for: threadID).renderSnapshot.assistantRevertStatesByMessageID[assistantMessage.id]?.riskLevel,
            .safe
        )

        service.rememberRepoRoot("/tmp/repo", forWorkingDirectory: "/tmp/repo/app")

        XCTAssertEqual(
            service.timelineState(for: threadID).renderSnapshot.assistantRevertStatesByMessageID[assistantMessage.id]?.riskLevel,
            .warning
        )
    }

    func testAssistantRevertPresentationBlocksWhenWorkingDirectoryIsMissing() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let assistantMessage = recordReadyChangeSet(
            service: service,
            threadID: threadID,
            filePath: "Sources/App.swift"
        )

        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: nil)
        )

        XCTAssertEqual(presentation.riskLevel, .blocked)
        XCTAssertFalse(presentation.isEnabled)
    }

    func testAssistantRevertPresentationBlocksNotRevertableResponse() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Made several edits."
        )
        service.recordFallbackFileChangePatch(
            threadId: threadID,
            turnId: turnID,
            patch: """
            diff --git a/Sources/A.swift b/Sources/A.swift
            index 1111111..2222222 100644
            --- a/Sources/A.swift
            +++ b/Sources/A.swift
            @@ -1 +1,2 @@
             let a = 1
            +let b = 2
            """
        )
        service.recordFallbackFileChangePatch(
            threadId: threadID,
            turnId: turnID,
            patch: """
            diff --git a/Sources/B.swift b/Sources/B.swift
            index 3333333..4444444 100644
            --- a/Sources/B.swift
            +++ b/Sources/B.swift
            @@ -1 +1,2 @@
             let c = 3
            +let d = 4
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let presentation = try XCTUnwrap(
            service.assistantRevertPresentation(for: assistantMessage, workingDirectory: "/tmp/repo")
        )

        XCTAssertEqual(presentation.riskLevel, .blocked)
        XCTAssertFalse(presentation.isEnabled)
    }

    func testArchiveThreadPrunesCachedTimelineState() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        service.threads = [
            CodexThread(id: threadID, title: "Archive Me", cwd: "/tmp/repo")
        ]

        service.appendSystemMessage(
            threadId: threadID,
            text: "Status: completed\n\nPath: Sources/App.swift\nKind: update\nTotals: +1 -0",
            kind: .fileChange
        )
        _ = service.timelineState(for: threadID)

        XCTAssertNotNil(service.threadTimelineStateByThread[threadID])

        service.archiveThread(threadID)
        service.refreshAllThreadTimelineStates()

        XCTAssertNil(service.threadTimelineStateByThread[threadID])
        XCTAssertNil(service.latestRepoAffectingMessageSignalByThread[threadID])
        XCTAssertNil(service.stoppedTurnIDsByThread[threadID])
    }

    // Creates a finalized, undoable response fixture with one changed file.
    @discardableResult
    private func recordReadyChangeSet(
        service: CodexService,
        threadID: String,
        filePath: String
    ) -> CodexMessage {
        let turnID = "turn-\(UUID().uuidString)"
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Implemented the change."
        )
        service.recordTurnDiffChangeSet(
            threadId: threadID,
            turnId: turnID,
            diff: """
            diff --git a/\(filePath) b/\(filePath)
            index 1111111..2222222 100644
            --- a/\(filePath)
            +++ b/\(filePath)
            @@ -1 +1,2 @@
             struct App {}
            +let enabled = true
            """
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)
        return try! XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
    }

    private func makeService() -> CodexService {
        let service = CodexService()
        Self.retainedServices.append(service)
        return service
    }

    private static var retainedServices: [CodexService] = []
}
