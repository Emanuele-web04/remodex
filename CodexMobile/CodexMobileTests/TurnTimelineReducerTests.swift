// FILE: TurnTimelineReducerTests.swift
// Purpose: Verifies timeline collapse/dedupe/anchor behavior during TurnView refactor.
// Layer: Unit Test
// Exports: TurnTimelineReducerTests
// Depends on: XCTest, CodexMobile

import XCTest
import SwiftUI
@testable import CodexMobile

final class TurnTimelineReducerTests: XCTestCase {
    func testCollapseConsecutiveThinkingKeepsNewestState() {
        let threadID = "thread"
        let now = Date()

        let messages = [
            makeMessage(
                id: "thinking-1",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Thinking...",
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1",
                isStreaming: true
            ),
            makeMessage(
                id: "thinking-2",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Resolved thought",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-1",
                isStreaming: false
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)
        XCTAssertEqual(projection.messages.count, 1)
        XCTAssertEqual(projection.messages[0].text, "Resolved thought")
        XCTAssertFalse(projection.messages[0].isStreaming)
        XCTAssertEqual(projection.messages[0].itemId, "item-1")
    }

    func testCollapseConsecutiveThinkingKeepsExistingActivityWhenIncomingIsPlaceholder() {
        let threadID = "thread"
        let now = Date()

        let messages = [
            makeMessage(
                id: "thinking-activity",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Running /usr/bin/bash -lc \"echo test\"",
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1",
                isStreaming: true
            ),
            makeMessage(
                id: "thinking-placeholder",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Thinking...",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-1",
                isStreaming: true
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)
        XCTAssertEqual(projection.messages.count, 1)
        XCTAssertTrue(projection.messages[0].text.contains("Running /usr/bin/bash"))
    }

    func testCollapseConsecutiveThinkingKeepsDistinctItemsSeparated() {
        let threadID = "thread"
        let now = Date()

        let messages = [
            makeMessage(
                id: "thinking-1",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Reasoning block A",
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1",
                isStreaming: true
            ),
            makeMessage(
                id: "thinking-2",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Reasoning block B",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-2",
                isStreaming: true
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)
        XCTAssertEqual(projection.messages.count, 2)
        XCTAssertEqual(projection.messages.map(\.id), ["thinking-1", "thinking-2"])
    }

    func testCollapseThinkingReusesPlaceholderAcrossCommandRows() {
        let threadID = "thread"
        let now = Date()

        let messages = [
            makeMessage(
                id: "thinking-1",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Thinking...",
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1",
                isStreaming: true
            ),
            makeMessage(
                id: "command-1",
                threadID: threadID,
                role: .system,
                kind: .commandExecution,
                text: "Running rg -n \"needle\"",
                createdAt: now.addingTimeInterval(0.5),
                turnID: "turn-1",
                itemID: "command-1",
                isStreaming: true
            ),
            makeMessage(
                id: "thinking-2",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Resolved thought",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-2",
                isStreaming: false
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)
        XCTAssertEqual(projection.messages.map(\.id), ["thinking-1", "command-1"])
        XCTAssertEqual(projection.messages[0].text, "Resolved thought")
        XCTAssertEqual(projection.messages[0].itemId, "item-2")
    }

    func testProjectRemovesThinkingCommandEchoWhenCommandCardExists() {
        let threadID = "thread"
        let now = Date()

        let messages = [
            makeMessage(
                id: "thinking-echo",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Thinking...\nRunning rg -n \"needle\"",
                createdAt: now,
                turnID: "turn-1",
                itemID: "thinking-1",
                isStreaming: true
            ),
            makeMessage(
                id: "command-1",
                threadID: threadID,
                role: .system,
                kind: .commandExecution,
                text: "Running rg -n \"needle\"",
                createdAt: now.addingTimeInterval(0.2),
                turnID: "turn-1",
                itemID: "command-1",
                isStreaming: true
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)
        XCTAssertEqual(projection.messages.map(\.id), ["command-1"])
    }

    func testToolActivityStaysSeparateFromThinkingRows() {
        let threadID = "thread"
        let now = Date()

        let messages = [
            makeMessage(
                id: "thinking-1",
                threadID: threadID,
                role: .system,
                kind: .thinking,
                text: "Reasoning block",
                createdAt: now,
                turnID: "turn-1",
                itemID: "thinking-1",
                isStreaming: true
            ),
            makeMessage(
                id: "tool-1",
                threadID: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read Sources/App.swift",
                createdAt: now.addingTimeInterval(0.1),
                turnID: "turn-1",
                itemID: "tool-1",
                isStreaming: true
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)
        XCTAssertEqual(projection.messages.map(\.id), ["thinking-1", "tool-1"])
    }

    func testTimelineRenderProjectionGroupsLongContiguousToolRuns() {
        let now = Date()
        let toolMessages = (1...7).map { index in
            makeMessage(
                id: "tool-\(index)",
                threadID: "thread",
                role: .system,
                kind: index.isMultiple(of: 2) ? .toolActivity : .commandExecution,
                text: "Tool \(index)",
                createdAt: now.addingTimeInterval(Double(index)),
                turnID: "turn-1",
                itemID: "item-\(index)",
                isStreaming: index == 7
            )
        }

        let items = TurnTimelineRenderProjection.project(messages: toolMessages)
        XCTAssertEqual(items.count, 1)

        guard case .toolBurst(let group) = items[0] else {
            return XCTFail("Expected one grouped tool burst")
        }

        XCTAssertEqual(group.messages.map(\.id), toolMessages.map(\.id))
        XCTAssertEqual(group.hiddenCount, 2)
        XCTAssertEqual(group.pinnedMessages.map(\.id), ["tool-1", "tool-2", "tool-3", "tool-4", "tool-5"])
        XCTAssertEqual(group.overflowMessages.map(\.id), ["tool-6", "tool-7"])
    }

    func testTimelineRenderProjectionKeepsShortToolRunsExpanded() {
        let now = Date()
        let toolMessages = (1...5).map { index in
            makeMessage(
                id: "tool-\(index)",
                threadID: "thread",
                role: .system,
                kind: .commandExecution,
                text: "Tool \(index)",
                createdAt: now.addingTimeInterval(Double(index)),
                turnID: "turn-1",
                itemID: "item-\(index)"
            )
        }

        let items = TurnTimelineRenderProjection.project(messages: toolMessages)
        XCTAssertEqual(items.count, 5)

        let messageIDs = items.compactMap { item -> String? in
            if case .message(let message) = item {
                return message.id
            }
            return nil
        }

        XCTAssertEqual(messageIDs, toolMessages.map(\.id))
    }

    func testTimelineRenderProjectionSplitsToolRunsAcrossStableTurnIDs() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "tool-1",
                threadID: "thread",
                role: .system,
                kind: .commandExecution,
                text: "Tool 1",
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1"
            ),
            makeMessage(
                id: "tool-2",
                threadID: "thread",
                role: .system,
                kind: .commandExecution,
                text: "Tool 2",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-2",
                itemID: "item-2"
            ),
        ]

        let items = TurnTimelineRenderProjection.project(messages: messages)
        XCTAssertEqual(items.count, 2)

        let messageIDs = items.compactMap { item -> String? in
            if case .message(let message) = item {
                return message.id
            }
            return nil
        }

        XCTAssertEqual(messageIDs, ["tool-1", "tool-2"])
    }

    func testRemoveDuplicateAssistantMessagesByTurnAndText() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "same",
                createdAt: now,
                turnID: "turn-1"
            ),
            makeMessage(
                id: "assistant-2",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "same",
                createdAt: now.addingTimeInterval(0.2),
                turnID: "turn-1"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateAssistantMessages(in: messages)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.id, "assistant-1")
    }

    func testRemoveDuplicateAssistantMessagesWithoutTurnWithinTimeWindow() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "no turn",
                createdAt: now
            ),
            makeMessage(
                id: "assistant-2",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "no turn",
                createdAt: now.addingTimeInterval(5)
            ),
            makeMessage(
                id: "assistant-3",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "no turn",
                createdAt: now.addingTimeInterval(20)
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateAssistantMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["assistant-1", "assistant-3"])
    }

    func testRemoveDuplicateUserMessagesCollapsesPendingPhoneRowWithConfirmedEcho() {
        let now = Date()
        var pending = makeMessage(
            id: "user-pending",
            threadID: "thread",
            role: .user,
            text: "Fix this",
            createdAt: now
        )
        pending.deliveryState = .pending

        let confirmed = makeMessage(
            id: "user-confirmed",
            threadID: "thread",
            role: .user,
            text: "Fix this",
            createdAt: now.addingTimeInterval(1),
            turnID: "turn-1"
        )

        let deduped = TurnTimelineReducer.removeDuplicateUserMessages(in: [pending, confirmed])

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].id, "user-pending")
        XCTAssertEqual(deduped[0].deliveryState, .confirmed)
        XCTAssertEqual(deduped[0].turnId, "turn-1")
    }

    func testRemoveDuplicateUserMessagesKeepsRepeatedConfirmedPrompts() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "user-1",
                threadID: "thread",
                role: .user,
                text: "Fix this",
                createdAt: now,
                turnID: "turn-1"
            ),
            makeMessage(
                id: "user-2",
                threadID: "thread",
                role: .user,
                text: "Fix this",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-2"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateUserMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["user-1", "user-2"])
    }

    func testRemoveDuplicateUserMessagesKeepsPromptsWithDifferentFileMentions() {
        let now = Date()
        var first = makeMessage(
            id: "user-1",
            threadID: "thread",
            role: .user,
            text: "Fix this",
            createdAt: now
        )
        first.deliveryState = .pending
        first.fileMentions = ["Sources/App.swift"]

        var second = makeMessage(
            id: "user-2",
            threadID: "thread",
            role: .user,
            text: "Fix this",
            createdAt: now.addingTimeInterval(1),
            turnID: "turn-1"
        )
        second.deliveryState = .confirmed
        second.fileMentions = ["Sources/Other.swift"]

        let deduped = TurnTimelineReducer.removeDuplicateUserMessages(in: [first, second])
        XCTAssertEqual(deduped.map(\.id), ["user-1", "user-2"])
    }

    func testRemoveDuplicateUserMessagesDoesNotGuessBetweenTwoIdenticalPendingRows() {
        let now = Date()
        var first = makeMessage(
            id: "user-1",
            threadID: "thread",
            role: .user,
            text: "Fix this",
            createdAt: now
        )
        first.deliveryState = .pending

        var second = makeMessage(
            id: "user-2",
            threadID: "thread",
            role: .user,
            text: "Fix this",
            createdAt: now.addingTimeInterval(0.2)
        )
        second.deliveryState = .pending

        let confirmed = makeMessage(
            id: "user-3",
            threadID: "thread",
            role: .user,
            text: "Fix this",
            createdAt: now.addingTimeInterval(0.4),
            turnID: "turn-1"
        )

        let deduped = TurnTimelineReducer.removeDuplicateUserMessages(in: [first, second, confirmed])
        XCTAssertEqual(deduped.map(\.id), ["user-1", "user-2", "user-3"])
    }

    func testRemoveDuplicateAssistantMessagesKeepsDistinctItemsInSameTurn() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "same",
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1"
            ),
            makeMessage(
                id: "assistant-2",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "same",
                createdAt: now.addingTimeInterval(0.2),
                turnID: "turn-1",
                itemID: "item-2"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateAssistantMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["assistant-1", "assistant-2"])
    }

    func testRemoveDuplicateAssistantMessagesStillDedupesTurnTextWhenOneIdentityIsMissing() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "same",
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1"
            ),
            makeMessage(
                id: "assistant-2",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "same",
                createdAt: now.addingTimeInterval(0.2),
                turnID: "turn-1"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateAssistantMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["assistant-1"])
    }

    func testProjectFiltersHiddenPushResetMarker() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "visible-diff",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: "Edited Sources/App.swift +2 -1",
                createdAt: now
            ),
            makeMessage(
                id: "hidden-push-reset",
                threadID: "thread",
                role: .system,
                kind: .chat,
                text: TurnSessionDiffResetMarker.text(branch: "feature/test", remote: "origin"),
                createdAt: now.addingTimeInterval(1),
                itemID: TurnSessionDiffResetMarker.manualPushItemID
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)

        XCTAssertEqual(projection.messages.map(\.id), ["visible-diff"])
    }

    func testProjectPlacesSubagentActionBeforeAssistantReplyWithinTurn() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Here is the combined result.",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "assistant-1",
                orderIndex: 3
            ),
            makeMessage(
                id: "subagents",
                threadID: "thread",
                role: .system,
                kind: .subagentAction,
                text: "Spawning 2 agents",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "subagents-1",
                orderIndex: 2
            ),
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Investigate the repo",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)

        XCTAssertEqual(projection.messages.map(\.id), ["user", "subagents", "assistant"])
    }

    func testProjectPlacesFileChangeAfterAssistantReplyWithinTurn() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Done.",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "assistant-1",
                orderIndex: 3
            ),
            makeMessage(
                id: "diff",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +2 -1
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "diff-1",
                orderIndex: 2
            ),
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Ship it",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)

        XCTAssertEqual(projection.messages.map(\.id), ["user", "assistant", "diff"])
    }

    func testRemoveDuplicateFileChangeMessagesKeepsNewestMatchingTurnSnapshot() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +2 -1
                """,
                createdAt: now,
                turnID: "turn-1",
                itemID: "filechange-1",
                isStreaming: true
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +2 -1
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "diff-1",
                isStreaming: false
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateFileChangeMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["diff-2"])
    }

    func testRemoveDuplicateFileChangeMessagesIgnoresStatusOnlyDifferences() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: inProgress

                Path: Sources/App.swift
                Kind: update
                Totals: +2 -1
                """,
                createdAt: now,
                turnID: "turn-1",
                itemID: "filechange-1",
                isStreaming: true
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +2 -1
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "turn-diff-1",
                isStreaming: false
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateFileChangeMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["diff-2"])
    }

    func testRemoveDuplicateFileChangeMessagesDedupesSingleFileRowsAcrossPathRepresentations() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: "Edited TurnToolbarContent.swift +2 -13",
                createdAt: now,
                turnID: nil,
                itemID: nil,
                isStreaming: true
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: CodexMobile/CodexMobile/Views/Turn/TurnToolbarContent.swift
                Kind: update
                Totals: +2 -13
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "turn-diff-1",
                isStreaming: false
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateFileChangeMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["diff-2"])
    }

    func testRemoveDuplicateFileChangeMessagesKeepsDistinctDirectoryScopedSnapshots() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/FeatureA/TurnToolbarContent.swift
                Kind: update
                Totals: +2 -13
                """,
                createdAt: now,
                turnID: "turn-1",
                itemID: "diff-a",
                isStreaming: false
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/FeatureB/TurnToolbarContent.swift
                Kind: update
                Totals: +2 -13
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "diff-b",
                isStreaming: false
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateFileChangeMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["diff-1", "diff-2"])
    }

    func testRemoveDuplicateFileChangeMessagesKeepsNewestSnapshotForSamePaths() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Edited Sources/App.swift +2 -1
                Edited Sources/Composer.swift +3 -1
                """,
                createdAt: now,
                turnID: "turn-1",
                itemID: "filechange-1",
                isStreaming: true
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Edited Sources/App.swift +4 -2
                Edited Sources/Composer.swift +6 -2
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "turn-diff-1",
                isStreaming: false
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateFileChangeMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["diff-2"])
    }

    func testRemoveDuplicateFileChangeMessagesKeepsDistinctCompletedSnapshotsForSamePaths() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Edited Sources/App.swift +2 -1
                Edited Sources/Composer.swift +3 -1
                """,
                createdAt: now,
                turnID: "turn-1",
                itemID: "turn-diff-1",
                isStreaming: false
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Edited Sources/App.swift +4 -2
                Edited Sources/Composer.swift +6 -2
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "turn-diff-2",
                isStreaming: false
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateFileChangeMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["diff-1", "diff-2"])
    }

    func testRemoveDuplicateFileChangeMessagesDropsStreamingSubsetWhenLaterSnapshotAddsFiles() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: "Edited Sources/App.swift +2 -1",
                createdAt: now,
                turnID: "turn-1",
                itemID: "filechange-1",
                isStreaming: true
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Edited Sources/App.swift +4 -2
                Edited Sources/Composer.swift +6 -2
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "turn-diff-1",
                isStreaming: false
            ),
            makeMessage(
                id: "diff-3",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: "Edited Sources/Other.swift +1 -0",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "turn-diff-2",
                isStreaming: false
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateFileChangeMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["diff-2", "diff-3"])
    }

    func testRemoveDuplicateFileChangeMessagesKeepsDistinctTurnSnapshots() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +2 -1
                """,
                createdAt: now,
                turnID: "turn-1"
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/Composer.swift
                Kind: update
                Totals: +3 -1
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateFileChangeMessages(in: messages)
        XCTAssertEqual(deduped.map(\.id), ["diff-1", "diff-2"])
    }

    func testAssistantAnchorPrefersActiveTurnThenStreamingFallback() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "old",
                createdAt: now,
                turnID: "turn-old"
            ),
            makeMessage(
                id: "assistant-2",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "streaming",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-active",
                isStreaming: true
            ),
        ]

        let activeAnchor = TurnTimelineReducer.assistantResponseAnchorMessageID(
            in: messages,
            activeTurnID: "turn-active"
        )
        XCTAssertEqual(activeAnchor, "assistant-2")

        let fallbackAnchor = TurnTimelineReducer.assistantResponseAnchorMessageID(
            in: messages,
            activeTurnID: nil
        )
        XCTAssertEqual(fallbackAnchor, "assistant-2")
    }

    func testEnforceIntraTurnOrderPreservesInterleavedMultiItemFlow() {
        let now = Date()
        var order = 0
        func nextOrder() -> Int { order += 1; return order }

        // Simulates a desktop-style mirror flow: thinking1 → response1 → thinking2 → response2
        let messages = [
            makeMessage(
                id: "user-1",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Hello",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "thinking-1",
                threadID: "thread",
                role: .system,
                kind: .thinking,
                text: "Reasoning block A",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "First response",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "thinking-2",
                threadID: "thread",
                role: .system,
                kind: .thinking,
                text: "Reasoning block B",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "item-2",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-2",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Second response",
                createdAt: now.addingTimeInterval(4),
                turnID: "turn-1",
                itemID: "item-2",
                orderIndex: nextOrder()
            ),
        ]

        let reordered = TurnTimelineReducer.enforceIntraTurnOrder(in: messages)
        // User must come first, but the interleaved flow must be preserved.
        XCTAssertEqual(reordered.map(\.id), [
            "user-1",
            "thinking-1",
            "assistant-1",
            "thinking-2",
            "assistant-2",
        ])
    }

    func testEnforceIntraTurnOrderStillReordersSingleItemTurn() {
        let now = Date()
        var order = 0
        func nextOrder() -> Int { order += 1; return order }

        // Single-item turn where assistant arrives before thinking (out of order).
        let messages = [
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Response",
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "thinking-1",
                threadID: "thread",
                role: .system,
                kind: .thinking,
                text: "Thinking...",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "user-1",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Hello",
                createdAt: now.addingTimeInterval(-1),
                turnID: "turn-1",
                orderIndex: 0
            ),
        ]

        let reordered = TurnTimelineReducer.enforceIntraTurnOrder(in: messages)
        // Single-item turn: normal role-based ordering applies.
        XCTAssertEqual(reordered.map(\.id), [
            "user-1",
            "thinking-1",
            "assistant-1",
        ])
    }

    func testEnforceIntraTurnOrderKeepsSteerUserNearBottomOfInterleavedTurn() {
        let now = Date()
        var order = 0
        func nextOrder() -> Int { order += 1; return order }

        let messages = [
            makeMessage(
                id: "user-1",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Initial prompt",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "thinking-1",
                threadID: "thread",
                role: .system,
                kind: .thinking,
                text: "Reasoning block A",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "First response",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "user-steer",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Steer follow-up",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "thinking-2",
                threadID: "thread",
                role: .system,
                kind: .thinking,
                text: "Reasoning block B",
                createdAt: now.addingTimeInterval(4),
                turnID: "turn-1",
                itemID: "item-2",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-2",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Second response",
                createdAt: now.addingTimeInterval(5),
                turnID: "turn-1",
                itemID: "item-2",
                orderIndex: nextOrder()
            ),
        ]

        let reordered = TurnTimelineReducer.enforceIntraTurnOrder(in: messages)
        XCTAssertEqual(reordered.map(\.id), [
            "user-1",
            "thinking-1",
            "assistant-1",
            "user-steer",
            "thinking-2",
            "assistant-2",
        ])
    }

    func testEnforceIntraTurnOrderPreservesPartialInterleavedFlow() {
        let now = Date()
        var order = 0
        func nextOrder() -> Int { order += 1; return order }

        // Mid-stream state: thinking2 arrived after assistant1, but assistant2 not yet here.
        let messages = [
            makeMessage(
                id: "user-1",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Hello",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "thinking-1",
                threadID: "thread",
                role: .system,
                kind: .thinking,
                text: "Reasoning block A",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "First response",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "thinking-2",
                threadID: "thread",
                role: .system,
                kind: .thinking,
                text: "Reasoning block B",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "item-2",
                isStreaming: true,
                orderIndex: nextOrder()
            ),
        ]

        let reordered = TurnTimelineReducer.enforceIntraTurnOrder(in: messages)
        // Even without assistant-2 yet, thinking-2 must NOT jump before assistant-1.
        XCTAssertEqual(reordered.map(\.id), [
            "user-1",
            "thinking-1",
            "assistant-1",
            "thinking-2",
        ])
    }

    func testEnforceIntraTurnOrderPreservesToolActivityAfterAssistantInInterleavedFlow() {
        let now = Date()
        var order = 0
        func nextOrder() -> Int { order += 1; return order }

        let messages = [
            makeMessage(
                id: "user-1",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Hello",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "thinking-1",
                threadID: "thread",
                role: .system,
                kind: .thinking,
                text: "Reasoning block A",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "First response",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "tool-1",
                threadID: "thread",
                role: .system,
                kind: .toolActivity,
                text: "Read Sources/App.swift",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "tool-1",
                orderIndex: nextOrder()
            ),
        ]

        let reordered = TurnTimelineReducer.enforceIntraTurnOrder(in: messages)
        XCTAssertEqual(reordered.map(\.id), [
            "user-1",
            "thinking-1",
            "assistant-1",
            "tool-1",
        ])
    }

    func testEnforceIntraTurnOrderPreservesSteerPromptAfterAssistantWithinSameTurn() {
        let now = Date()
        var order = 0
        func nextOrder() -> Int { order += 1; return order }

        let messages = [
            makeMessage(
                id: "user-1",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Initial request",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "First pass",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "user-2",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Actually check the failing tests first",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-2",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Refocusing on failures",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "item-2",
                orderIndex: nextOrder()
            ),
        ]

        let reordered = TurnTimelineReducer.enforceIntraTurnOrder(in: messages)
        XCTAssertEqual(reordered.map(\.id), [
            "user-1",
            "assistant-1",
            "user-2",
            "assistant-2",
        ])
    }

    func testParseMarkdownSegmentsSupportsPlusLanguageTags() {
        let source = """
        Intro

        ```c++
        int main() { return 0; }
        ```

        Outro
        """

        let segments = parseMarkdownSegments(source)
        let codeLanguages = segments.compactMap { segment -> String? in
            if case .codeBlock(let language, _) = segment {
                return language
            }
            return nil
        }

        XCTAssertEqual(codeLanguages, ["c++"])
    }

    func testParseMarkdownSegmentsSupportsDashedLanguageTags() {
        let source = """
        ```objective-c
        @implementation Example
        @end
        ```
        """

        let segments = parseMarkdownSegments(source)
        let codeLanguages = segments.compactMap { segment -> String? in
            if case .codeBlock(let language, _) = segment {
                return language
            }
            return nil
        }

        XCTAssertEqual(codeLanguages, ["objective-c"])
    }

    func testMermaidMarkdownContentParsesMermaidBlocks() {
        let source = """
        Intro

        ```mermaid
        flowchart TD
            A[Start] --> B[End]
        ```

        Outro
        """

        let content = MermaidMarkdownContentCache.content(messageID: "mermaid-basic", text: source)

        XCTAssertEqual(mermaidSegmentKinds(in: content), [.markdown, .mermaid, .markdown])
    }

    func testMermaidMarkdownContentSupportsMultipleBlocks() {
        let source = """
        ```mermaid
        flowchart TD
            A --> B
        ```

        Middle

        ```mermaid
        sequenceDiagram
            Alice->>Bob: hi
        ```
        """

        let content = MermaidMarkdownContentCache.content(messageID: "mermaid-multi", text: source)

        XCTAssertEqual(mermaidSegmentKinds(in: content), [.mermaid, .markdown, .mermaid])
    }

    func testMermaidMarkdownContentIgnoresPlainCodeBlocks() {
        let source = """
        ```swift
        let text = \"```mermaid\"
        ```
        """

        let content = MermaidMarkdownContentCache.content(messageID: "mermaid-ignore", text: source)

        XCTAssertNil(content)
    }

    func testMermaidSourceNormalizerConvertsLooseArrowLabels() {
        let source = """
        W -- Yes --> X[Relay replaces old Mac socket<br/>4001 to old connection]
        """

        let normalized = MermaidSourceNormalizer.normalized(source)

        XCTAssertEqual(
            normalized,
            "W -->|Yes| X[Relay replaces old Mac socket<br/>4001 to old connection]"
        )
    }

    func testMermaidSourceNormalizerLeavesValidArrowLabelsUntouched() {
        let source = """
        W -->|Yes| X[Relay replaces old Mac socket<br/>4001 to old connection]
        """

        let normalized = MermaidSourceNormalizer.normalized(source)

        XCTAssertEqual(normalized, source)
    }

    func testMermaidSourceNormalizerQuotesSquareNodeLabels() {
        let source = """
        X[Relay replaces old Mac socket<br/>4001 to old connection]
        """

        let normalized = MermaidSourceNormalizer.normalized(source)

        XCTAssertEqual(
            normalized,
            #"X["Relay replaces old Mac socket<br/>4001 to old connection"]"#
        )
    }

    func testMermaidSourceNormalizerQuotesDecisionNodeLabels() {
        let source = """
        W{Mac reconnects?}
        """

        let normalized = MermaidSourceNormalizer.normalized(source)

        XCTAssertEqual(normalized, #"W{"Mac reconnects?"}"#)
    }

    func testAssistantRenderModelDefersMermaidUntilStreamingCompletes() {
        MessageRowRenderModelCache.reset()
        MermaidMarkdownContentCache.reset()

        let source = """
        Intro

        ```mermaid
        flowchart TD
            A[Start] --> B[End]
        ```
        """
        let displayText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = makeMessage(
            id: "assistant-mermaid-streaming",
            threadID: "thread",
            role: .assistant,
            text: source,
            isStreaming: true
        )

        let streamingModel = MessageRowRenderModelCache.model(for: message, displayText: displayText)
        XCTAssertNil(streamingModel.mermaidContent)

        message.isStreaming = false

        let finalizedModel = MessageRowRenderModelCache.model(for: message, displayText: displayText)
        XCTAssertEqual(mermaidSegmentKinds(in: finalizedModel.mermaidContent), [.markdown, .mermaid])
    }

    func testAssistantBlockInfoShowsCopyWhenLatestRunCompleted() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Completed response",
                createdAt: now,
                turnID: "turn-1"
            ),
        ]

        let blockInfo = TurnTimelineView<EmptyView, EmptyView>.assistantBlockInfo(
            for: messages,
            activeTurnID: nil,
            isThreadRunning: false,
            latestTurnTerminalState: .completed,
            stoppedTurnIDs: []
        )

        XCTAssertEqual(blockInfo, ["Completed response"])
    }

    func testAssistantBlockInfoHidesCopyWhenLatestRunStopped() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Interrupted response",
                createdAt: now,
                turnID: "turn-1"
            ),
        ]

        let blockInfo = TurnTimelineView<EmptyView, EmptyView>.assistantBlockInfo(
            for: messages,
            activeTurnID: nil,
            isThreadRunning: false,
            latestTurnTerminalState: .stopped,
            stoppedTurnIDs: ["turn-1"]
        )

        XCTAssertEqual(blockInfo, [nil])
    }

    func testScrollTrackerPausesAutomaticScrollingDuringUserDrag() {
        XCTAssertTrue(
            TurnScrollStateTracker.isAutomaticScrollingPaused(
                isUserDragging: true,
                cooldownUntil: nil,
                now: Date()
            )
        )
    }

    func testScrollTrackerPausesAutomaticScrollingDuringCooldown() {
        let now = Date()

        XCTAssertTrue(
            TurnScrollStateTracker.isAutomaticScrollingPaused(
                isUserDragging: false,
                cooldownUntil: now.addingTimeInterval(0.1),
                now: now
            )
        )
        XCTAssertFalse(
            TurnScrollStateTracker.isAutomaticScrollingPaused(
                isUserDragging: false,
                cooldownUntil: now.addingTimeInterval(-0.1),
                now: now
            )
        )
    }

    func testScrollTrackerBuildsCooldownDeadlineInFuture() {
        let now = Date()
        let deadline = TurnScrollStateTracker.cooldownDeadline(after: now)

        XCTAssertGreaterThan(deadline.timeIntervalSince(now), 0)
    }

    // Builds compact fixtures for reducer invariants.
    private func makeMessage(
        id: String,
        threadID: String,
        role: CodexMessageRole,
        kind: CodexMessageKind = .chat,
        text: String,
        createdAt: Date = Date(),
        turnID: String? = nil,
        itemID: String? = nil,
        isStreaming: Bool = false,
        orderIndex: Int? = nil
    ) -> CodexMessage {
        var message = CodexMessage(
            id: id,
            threadId: threadID,
            role: role,
            kind: kind,
            text: text,
            createdAt: createdAt,
            turnId: turnID,
            itemId: itemID,
            isStreaming: isStreaming,
            deliveryState: .confirmed,
            attachments: []
        )
        if let orderIndex {
            message.orderIndex = orderIndex
        }
        return message
    }
}

final class TurnScrollStateTrackerTests: XCTestCase {
    func testUserDragImmediatelySwitchesFollowBottomToManual() {
        XCTAssertEqual(
            TurnScrollStateTracker.modeAfterUserDragBegan(currentMode: .followBottom),
            .manual
        )
    }

    func testUserDragKeepsAssistantAnchorModeUntilAnchorCompletes() {
        XCTAssertEqual(
            TurnScrollStateTracker.modeAfterUserDragBegan(currentMode: .anchorAssistantResponse),
            .anchorAssistantResponse
        )
    }

    func testUserDragEndingAtBottomRestoresFollowBottom() {
        XCTAssertEqual(
            TurnScrollStateTracker.modeAfterUserDragEnded(
                currentMode: .manual,
                isScrolledToBottom: true
            ),
            .followBottom
        )
    }

    func testUserDragEndingAwayFromBottomKeepsManualMode() {
        XCTAssertEqual(
            TurnScrollStateTracker.modeAfterUserDragEnded(
                currentMode: .manual,
                isScrolledToBottom: false
            ),
            .manual
        )
    }

    func testCorrectsBottomForMeaningfulContentGrowthWhenPinned() {
        XCTAssertTrue(
            TurnScrollStateTracker.shouldCorrectBottomAfterContentHeightChange(
                previousHeight: 320,
                newHeight: 356,
                isPinnedToBottom: true
            )
        )
    }

    func testCorrectsBottomForMeaningfulContentShrinkWhenPinned() {
        XCTAssertTrue(
            TurnScrollStateTracker.shouldCorrectBottomAfterContentHeightChange(
                previousHeight: 356,
                newHeight: 320,
                isPinnedToBottom: true
            )
        )
    }

    func testIgnoresTinyHeightDriftAndManualMode() {
        XCTAssertFalse(
            TurnScrollStateTracker.shouldCorrectBottomAfterContentHeightChange(
                previousHeight: 320,
                newHeight: 320.5,
                isPinnedToBottom: true
            )
        )

        XCTAssertFalse(
            TurnScrollStateTracker.shouldCorrectBottomAfterContentHeightChange(
                previousHeight: 356,
                newHeight: 320,
                isPinnedToBottom: false
            )
        )
    }
}

private enum MarkdownSegment {
    case text(String)
    case codeBlock(language: String?, code: String)
}

private enum MermaidSegmentKind: Equatable {
    case markdown
    case mermaid
}

private func parseMarkdownSegments(_ source: String) -> [MarkdownSegment] {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var segments: [MarkdownSegment] = []
    var currentText: [String] = []
    var currentCode: [String] = []
    var currentLanguage: String?
    var isInsideCodeBlock = false

    func flushText() {
        guard !currentText.isEmpty else { return }
        segments.append(.text(currentText.joined(separator: "\n")))
        currentText.removeAll(keepingCapacity: true)
    }

    func flushCode() {
        segments.append(.codeBlock(language: currentLanguage, code: currentCode.joined(separator: "\n")))
        currentCode.removeAll(keepingCapacity: true)
        currentLanguage = nil
    }

    for line in lines {
        if line.hasPrefix("```") {
            if isInsideCodeBlock {
                flushCode()
                isInsideCodeBlock = false
            } else {
                flushText()
                let languageTag = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentLanguage = languageTag.isEmpty ? nil : languageTag
                isInsideCodeBlock = true
            }
            continue
        }

        if isInsideCodeBlock {
            currentCode.append(line)
        } else {
            currentText.append(line)
        }
    }

    if isInsideCodeBlock {
        flushCode()
    } else {
        flushText()
    }

    return segments
}

private func mermaidSegmentKinds(in content: MermaidMarkdownContent?) -> [MermaidSegmentKind] {
    guard let content else {
        return []
    }

    return content.segments.map { segment in
        switch segment.kind {
        case .markdown:
            return .markdown
        case .mermaid:
            return .mermaid
        }
    }
}
