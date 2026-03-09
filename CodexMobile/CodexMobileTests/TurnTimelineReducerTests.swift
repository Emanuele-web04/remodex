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
