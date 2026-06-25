// FILE: CodexServiceHistoryMergeTests.swift
// Purpose: Verifies running-thread history merge guards for user and assistant dedupe.
// Layer: Unit Test
// Exports: CodexServiceHistoryMergeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceHistoryMergeTests: XCTestCase {
    func testRunningThreadConfirmedUserReconcileDoesNotAppendDuplicateBubble() throws {
        let threadID = "thread-user-\(UUID().uuidString)"
        let turnID = "turn-user-\(UUID().uuidString)"
        let prompt = "Hey"

        let existing = [
            CodexMessage(
                id: "user-confirmed",
                threadId: threadID,
                role: .user,
                text: prompt,
                turnId: turnID,
                deliveryState: .confirmed,
                orderIndex: 0
            ),
        ]
        let history = [
            CodexMessage(
                id: "user-history",
                threadId: threadID,
                role: .user,
                text: prompt,
                turnId: turnID,
                deliveryState: .confirmed,
                orderIndex: 0
            ),
        ]

        let merged = try CodexService.mergeHistoryMessages(
            existing,
            history,
            activeThreadIDs: [threadID],
            runningThreadIDs: [threadID]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "user-confirmed")
        XCTAssertEqual(merged.first?.deliveryState, .confirmed)
    }

    func testRunningThreadAssistantGuardReconcilesDuplicateFinalText() throws {
        let threadID = "thread-assistant-\(UUID().uuidString)"
        let turnID = "turn-assistant-\(UUID().uuidString)"
        let answer = "Latest TestFlight version: 1.4 (123)."

        let existing = [
            CodexMessage(
                id: "assistant-live",
                threadId: threadID,
                role: .assistant,
                text: answer,
                turnId: turnID,
                itemId: "item-live",
                isStreaming: false,
                orderIndex: 1
            ),
        ]
        let history = [
            CodexMessage(
                id: "assistant-history",
                threadId: threadID,
                role: .assistant,
                text: answer,
                turnId: turnID,
                itemId: "item-history",
                isStreaming: false,
                orderIndex: 1
            ),
        ]

        let merged = try CodexService.mergeHistoryMessages(
            existing,
            history,
            activeThreadIDs: [threadID],
            runningThreadIDs: [threadID]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "assistant-live")
        XCTAssertEqual(merged.first?.text, answer)
    }

    func testUniqueUserHistoryMergeIndexPrefersConfirmedOverPending() {
        let threadID = "thread-prefer-\(UUID().uuidString)"
        let turnID = "turn-prefer-\(UUID().uuidString)"
        let prompt = "Ship it"
        let merged = [
            CodexMessage(
                id: "user-pending",
                threadId: threadID,
                role: .user,
                text: prompt,
                turnId: turnID,
                deliveryState: .pending,
                orderIndex: 0
            ),
            CodexMessage(
                id: "user-confirmed",
                threadId: threadID,
                role: .user,
                text: prompt,
                turnId: turnID,
                deliveryState: .confirmed,
                orderIndex: 1
            ),
        ]
        let incoming = CodexMessage(
            threadId: threadID,
            role: .user,
            text: prompt,
            turnId: turnID,
            deliveryState: .confirmed,
            orderIndex: 2
        )

        let index = CodexService.uniqueUserHistoryMergeIndex(
            in: merged,
            message: incoming,
            turnId: turnID
        )

        XCTAssertEqual(index, 1)
        XCTAssertEqual(merged[index ?? -1].deliveryState, .confirmed)
    }

    func testClosedAssistantHistoryDoesNotReplaceLongAnswerWithShortPromptText() throws {
        let threadID = "thread-short-replay-\(UUID().uuidString)"
        let turnID = "opencode-turn-\(UUID().uuidString)"
        let existingAnswer = "Hey! I am Remodex, your iPad companion for controlling coding agents on your Mac."

        let existing = [
            CodexMessage(
                id: "assistant-live",
                threadId: threadID,
                role: .assistant,
                text: existingAnswer,
                turnId: turnID,
                itemId: "opencode-agent-\(turnID)",
                isStreaming: false,
                orderIndex: 0
            ),
        ]
        let history = [
            CodexMessage(
                id: "assistant-history",
                threadId: threadID,
                role: .assistant,
                text: "Hey",
                turnId: turnID,
                itemId: "opencode-agent-\(turnID)",
                isStreaming: false,
                orderIndex: 0
            ),
        ]

        let merged = try CodexService.mergeHistoryMessages(
            existing,
            history,
            activeThreadIDs: [],
            runningThreadIDs: []
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, existingAnswer)
    }

    func testClosedAssistantHistoryWithMismatchedStableItemIdDoesNotReplaceLocalAnswer() throws {
        let threadID = "thread-id-mismatch-\(UUID().uuidString)"
        let turnID = "opencode-turn-\(UUID().uuidString)"
        let existingAnswer = "I am MiniMax M3 running through OpenCode on your local Mac."

        let existing = [
            CodexMessage(
                id: "assistant-live",
                threadId: threadID,
                role: .assistant,
                text: existingAnswer,
                turnId: turnID,
                itemId: "opencode-agent-\(turnID)",
                isStreaming: false,
                orderIndex: 0
            ),
        ]
        let history = [
            CodexMessage(
                id: "assistant-history",
                threadId: threadID,
                role: .assistant,
                text: "Hey",
                turnId: turnID,
                itemId: "assistant-synthetic-other",
                isStreaming: false,
                orderIndex: 0
            ),
        ]

        let merged = try CodexService.mergeHistoryMessages(
            existing,
            history,
            activeThreadIDs: [],
            runningThreadIDs: []
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, existingAnswer)
        XCTAssertEqual(merged.first?.itemId, "opencode-agent-\(turnID)")
    }
}