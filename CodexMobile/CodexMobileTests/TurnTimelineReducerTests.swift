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

    func testDeduplicatesStalePendingImagePromptWhenConfirmedEchoUsesDifferentAttachmentIdentity() {
        let threadID = "thread"
        let now = Date()
        let pendingAttachment = CodexImageAttachment(
            id: "pending-image",
            thumbnailBase64JPEG: "local-thumb",
            payloadDataURL: "data:image/jpeg;base64,LOCAL"
        )
        let confirmedAttachment = CodexImageAttachment(
            id: "confirmed-image",
            thumbnailBase64JPEG: "server-thumb",
            sourceURL: "data:image/jpeg;base64,SERVER"
        )

        let messages = [
            makeMessage(
                id: "pending-user",
                threadID: threadID,
                role: .user,
                text: "Describe this screenshot",
                createdAt: now,
                attachments: [pendingAttachment],
                deliveryState: .pending,
                orderIndex: 1
            ),
            makeMessage(
                id: "confirmed-user",
                threadID: threadID,
                role: .user,
                text: "Describe this screenshot",
                createdAt: now.addingTimeInterval(3600),
                turnID: "turn-1",
                attachments: [confirmedAttachment],
                deliveryState: .confirmed,
                orderIndex: 2
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)
        XCTAssertEqual(projection.messages.count, 1)
        XCTAssertEqual(projection.messages[0].id, "pending-user")
        XCTAssertEqual(projection.messages[0].turnId, "turn-1")
        XCTAssertEqual(projection.messages[0].attachments.map(\.id), ["pending-image"])
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

    func testTimelineRenderProjectionCollapsesCompletedTurnBeforeFinalAnswer() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                text: "Check Gmail",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "status",
                threadID: "thread",
                role: .assistant,
                text: "I'll use the Gmail connector.",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "status-item",
                orderIndex: 2
            ),
            makeMessage(
                id: "tool",
                threadID: "thread",
                role: .system,
                kind: .toolActivity,
                text: "Read inbox",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "tool-item",
                orderIndex: 3
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                text: "Latest TestFlight version: 1.4 (124).",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "final-item",
                orderIndex: 4
            ),
        ]

        let items = TurnTimelineRenderProjection.project(
            messages: messages,
            completedTurnIDs: ["turn-1"]
        )

        XCTAssertEqual(items.count, 3)
        guard case .message(let user) = items[0],
              case .previousMessages(let previousGroup) = items[1],
              case .message(let final) = items[2] else {
            return XCTFail("Expected user, previous-messages disclosure, final answer")
        }

        XCTAssertEqual(user.id, "user")
        XCTAssertEqual(previousGroup.finalMessageID, "final")
        XCTAssertEqual(previousGroup.hiddenCount, 2)
        XCTAssertEqual(previousGroup.messages.map(\.id), ["status", "tool"])
        XCTAssertEqual(final.id, "final")
        XCTAssertEqual(
            TurnTimelineRenderProjection.collapsedFinalMessageIDs(
                in: messages,
                completedTurnIDs: ["turn-1"]
            ),
            Set(["final"])
        )
    }

    func testTimelineProjectionKeepsPreviousMessagesChronologicalForMultiAssistantTurns() {
        let now = Date()
        let rawMessages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                text: "Check Gmail",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "status",
                threadID: "thread",
                role: .assistant,
                text: "I'll use the Gmail connector.",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "status-item",
                orderIndex: 2
            ),
            makeMessage(
                id: "tool",
                threadID: "thread",
                role: .system,
                kind: .toolActivity,
                text: "Read inbox",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "tool-item",
                orderIndex: 3
            ),
            makeMessage(
                id: "final-a",
                threadID: "thread",
                role: .assistant,
                text: "The latest Remodex TestFlight inbox email says: Version 1.4, build 126.",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "final-item-a",
                orderIndex: 4
            ),
            makeMessage(
                id: "final-b",
                threadID: "thread",
                role: .assistant,
                text: "The latest Remodex TestFlight inbox email says: Version 1.4, build 126.",
                createdAt: now.addingTimeInterval(4),
                turnID: "turn-1",
                itemID: "final-item-b",
                orderIndex: 5
            ),
        ]

        let projectedMessages = TurnTimelineReducer.project(messages: rawMessages).messages
        XCTAssertEqual(projectedMessages.map(\.id), ["user", "status", "tool", "final-a"])

        let items = TurnTimelineRenderProjection.project(
            messages: projectedMessages,
            completedTurnIDs: ["turn-1"]
        )

        guard case .message(let user) = items[0],
              case .previousMessages(let previousGroup) = items[1],
              case .message(let final) = items[2] else {
            return XCTFail("Expected user, previous-messages disclosure, final answer")
        }

        XCTAssertEqual(user.id, "user")
        XCTAssertEqual(previousGroup.messages.map(\.id), ["status", "tool"])
        XCTAssertEqual(final.id, "final-a")
    }

    func testTimelineProjectionSkipsFinalReplaysAndMergedImageArtifactsInPreviousMessages() {
        let now = Date()
        let imagePath = "/Users/example/.codex/generated_images/thread/generated-icon.png"
        let finalText = """
        Created the icon with `$imagegen` using the built-in image generation mode.

        TL;DR:
        The icon shows the user as calm, focused, and in control.

        ![Generated image](\(imagePath))
        """
        let messages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                text: "Create an app user icon",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "intro",
                threadID: "thread",
                role: .assistant,
                text: "I will use the imagegen skill and inspect the app tone.",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                orderIndex: 2
            ),
            makeMessage(
                id: "context",
                threadID: "thread",
                role: .assistant,
                text: "The site is for Remodex: an iPhone bridge with a local-first power-user tone.",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                orderIndex: 3
            ),
            makeMessage(
                id: "leaked-tldr",
                threadID: "thread",
                role: .assistant,
                text: "TL;DR:\nThe icon shows the user as calm, focused, and in control.",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                orderIndex: 4
            ),
            makeMessage(
                id: "image-artifact",
                threadID: "thread",
                role: .assistant,
                text: "![Generated image](\(imagePath))",
                createdAt: now.addingTimeInterval(4),
                turnID: "turn-1",
                orderIndex: 5
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                text: finalText,
                createdAt: now.addingTimeInterval(5),
                turnID: "turn-1",
                orderIndex: 6
            ),
        ]

        let items = TurnTimelineRenderProjection.project(
            messages: messages,
            completedTurnIDs: ["turn-1"]
        )

        XCTAssertEqual(items.count, 3)
        guard case .previousMessages(let previousGroup) = items[1],
              case .message(let final) = items[2] else {
            return XCTFail("Expected previous-message disclosure followed by the final answer")
        }

        XCTAssertEqual(previousGroup.messages.map(\.id), ["intro", "context"])
        XCTAssertEqual(final.id, "final")
    }

    func testTimelineProjectionMovesGeneratedImageArtifactToFinalAnswer() {
        let now = Date()
        let imagePath = "/Users/example/.codex/generated_images/thread/generated-icon.png"
        let introText = "Using imagegen for a fresh raster icon concept. I will make it feel calm."
        let finalText = """
        TL;DR: The icon shows the user becoming calm, focused, and in control.

        The glowing path/grid represents organized direction.
        """
        let imageMarkdown = "![Generated image](\(imagePath))"
        let messages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                text: "Create an app user icon",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "intro",
                threadID: "thread",
                role: .assistant,
                text: introText,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                orderIndex: 2
            ),
            makeMessage(
                id: "image-artifact",
                threadID: "thread",
                role: .assistant,
                text: imageMarkdown,
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                orderIndex: 3
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                text: "\(introText)\n\n\(finalText)",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                orderIndex: 4
            ),
        ]

        let items = TurnTimelineRenderProjection.project(
            messages: messages,
            completedTurnIDs: ["turn-1"]
        )

        XCTAssertEqual(items.count, 3)
        guard case .previousMessages(let previousGroup) = items[1],
              case .message(let final) = items[2] else {
            return XCTFail("Expected one previous prose row followed by a normalized final answer")
        }

        XCTAssertEqual(previousGroup.messages.map(\.id), ["intro"])
        XCTAssertFalse(final.text.contains(introText))
        XCTAssertEqual(
            final.text,
            "\(finalText.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(imageMarkdown)"
        )
    }

    func testTimelineProjectionUsesAssistantPhaseForPreviousMessageCount() {
        let now = Date()
        let imagePath = "/Users/example/.codex/generated_images/thread/generated-icon.png"
        let commentary = "Using imagegen because this is a new raster icon concept. I will keep the TLDR tight."
        let finalText = "TLDR: The icon shows the user becoming calm, focused, and in control."
        let imageMarkdown = "![Generated image](\(imagePath))"
        let messages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                text: "Create an icon",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "commentary",
                threadID: "thread",
                role: .assistant,
                assistantPhase: "commentary",
                text: commentary,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "commentary-item",
                orderIndex: 2
            ),
            makeMessage(
                id: "image",
                threadID: "thread",
                role: .assistant,
                text: imageMarkdown,
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "image-item",
                orderIndex: 3
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                assistantPhase: "final_answer",
                text: finalText,
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "final-item",
                orderIndex: 4
            ),
        ]

        let items = TurnTimelineRenderProjection.project(
            messages: messages,
            completedTurnIDs: ["turn-1"]
        )

        XCTAssertEqual(items.count, 3)
        guard case .previousMessages(let previousGroup) = items[1],
              case .message(let final) = items[2] else {
            return XCTFail("Expected commentary behind one previous-message disclosure and final with generated image")
        }

        XCTAssertEqual(previousGroup.messages.map(\.id), ["commentary"])
        XCTAssertEqual(final.text, "\(finalText)\n\n\(imageMarkdown)")
    }

    func testTimelineProjectionKeepsPriorityArtifactsVisibleOutsidePreviousMessages() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                text: "Build the feature",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "thinking",
                threadID: "thread",
                role: .system,
                kind: .thinking,
                text: "Reasoning",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                orderIndex: 2
            ),
            makeMessage(
                id: "assistant-status",
                threadID: "thread",
                role: .assistant,
                text: "I am checking the repo.",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "status-item",
                orderIndex: 3
            ),
            makeMessage(
                id: "tool",
                threadID: "thread",
                role: .system,
                kind: .toolActivity,
                text: "Read Sources/App.swift",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                orderIndex: 4
            ),
            makeMessage(
                id: "file-change",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: "Path: Sources/App.swift\nKind: update\nTotals: +1 -0",
                createdAt: now.addingTimeInterval(4),
                turnID: "turn-1",
                orderIndex: 5
            ),
            makeMessage(
                id: "image",
                threadID: "thread",
                role: .assistant,
                text: "![Generated image](/Users/example/generated.png)",
                createdAt: now.addingTimeInterval(5),
                turnID: "turn-1",
                itemID: "image-item",
                orderIndex: 6
            ),
            makeMessage(
                id: "comment-card",
                threadID: "thread",
                role: .assistant,
                text: #"::code-comment{title="[P2] Keep artifact visible" body="The action card should stay visible outside previous messages." file="Sources/App.swift" start=10 end=12 priority=2 confidence=0.82}"#,
                createdAt: now.addingTimeInterval(5.5),
                turnID: "turn-1",
                itemID: "comment-item",
                orderIndex: 7
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                text: "Done. The feature is ready.",
                createdAt: now.addingTimeInterval(6),
                turnID: "turn-1",
                itemID: "final-item",
                orderIndex: 8
            ),
            makeMessage(
                id: "post-tool",
                threadID: "thread",
                role: .system,
                kind: .toolActivity,
                text: "Late metadata refresh",
                createdAt: now.addingTimeInterval(7),
                turnID: "turn-1",
                orderIndex: 9
            ),
        ]

        let items = TurnTimelineRenderProjection.project(
            messages: messages,
            completedTurnIDs: ["turn-1"]
        )

        XCTAssertEqual(items.map(\.id), [
            "user",
            "previous-messages:final",
            "file-change",
            "image",
            "comment-card",
            "final",
        ])
        guard case .previousMessages(let previousGroup) = items[1] else {
            return XCTFail("Expected previous messages disclosure before priority artifacts")
        }
        XCTAssertEqual(previousGroup.messages.map(\.id), ["thinking", "assistant-status", "tool", "post-tool"])
    }

    func testTimelineProjectionCollapsesTurnFileChangesIntoOneRenderedTable() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                text: "Build the feature",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                text: "Done.",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "final-item",
                orderIndex: 2
            ),
            makeMessage(
                id: "file-change-a",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +2 -1
                """,
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                orderIndex: 3
            ),
            makeMessage(
                id: "file-change-b",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/Composer.swift
                Kind: update
                Totals: +3 -0
                """,
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                orderIndex: 4
            ),
        ]

        let items = TurnTimelineRenderProjection.project(
            messages: messages,
            completedTurnIDs: ["turn-1"]
        )

        XCTAssertEqual(items.map(\.id), ["user", "final", "file-change-b"])
        guard case .message(let fileChange) = items[2] else {
            return XCTFail("Expected one aggregate file-change message")
        }
        let summary = TurnFileChangeSummaryParser.parse(from: fileChange.text)
        XCTAssertEqual(summary?.entries.map(\.path), ["Sources/App.swift", "Sources/Composer.swift"])
        XCTAssertEqual(summary?.entries.map(\.additions), [2, 3])
        XCTAssertEqual(summary?.entries.map(\.deletions), [1, 0])
    }

    func testTimelineProjectionMergesAdjacentSameFileChangeRows() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "file-change-add",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: CodexMobile/CodexMobile/Views/Turn/TurnTimelineView.swift
                Kind: update
                Totals: +6 -0
                """,
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "file-change-remove",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: CodexMobile/CodexMobile/Views/Turn/TurnTimelineView.swift
                Kind: update
                Totals: +0 -6
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-2",
                orderIndex: 2
            ),
        ]

        let items = TurnTimelineRenderProjection.project(messages: messages)

        XCTAssertEqual(items.map(\.id), ["file-change-remove"])
        guard case .message(let fileChange)? = items.first else {
            return XCTFail("Expected one merged file-change message")
        }
        let summary = TurnFileChangeSummaryParser.parse(from: fileChange.text)
        XCTAssertEqual(summary?.entries.count, 1)
        XCTAssertEqual(summary?.entries.first?.path, "CodexMobile/CodexMobile/Views/Turn/TurnTimelineView.swift")
        XCTAssertEqual(summary?.entries.first?.additions, 6)
        XCTAssertEqual(summary?.entries.first?.deletions, 6)
    }

    func testTimelineProjectionMergesAdjacentFinalFileChangeRowsIntoOneTable() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "file-change-a",
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
                orderIndex: 1
            ),
            makeMessage(
                id: "file-change-b",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/Composer.swift
                Kind: update
                Totals: +3 -0
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-2",
                orderIndex: 2
            ),
        ]

        let items = TurnTimelineRenderProjection.project(messages: messages)

        XCTAssertEqual(items.map(\.id), ["file-change-b"])
        guard case .message(let fileChange)? = items.first else {
            return XCTFail("Expected one final file-change table")
        }
        let summary = TurnFileChangeSummaryParser.parse(from: fileChange.text)
        XCTAssertEqual(summary?.entries.map(\.path), ["Sources/App.swift", "Sources/Composer.swift"])
        XCTAssertEqual(summary?.entries.map(\.additions), [2, 3])
        XCTAssertEqual(summary?.entries.map(\.deletions), [1, 0])
    }

    func testCollapsedFinalDoesNotDuplicateActionsWhenVisibleFileChangeOwnsThem() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                text: "Build the feature",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                text: "Done.",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "final-item",
                orderIndex: 2
            ),
            makeMessage(
                id: "file-change",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +2 -1
                """,
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                orderIndex: 3
            ),
        ]

        let blockInfo = TurnTimelineView<EmptyView, EmptyView>.assistantBlockInfo(
            for: messages,
            activeTurnID: nil,
            isThreadRunning: false,
            latestTurnTerminalState: .completed,
            stoppedTurnIDs: []
        )
        let initialStates = [String: AssistantBlockAccessoryState](
            uniqueKeysWithValues: zip(messages, blockInfo).compactMap { message, state in
                guard let state else { return nil }
                return (message.id, state)
            }
        )

        let rehousedStates = TurnTimelineView<EmptyView, EmptyView>.rehomeCollapsedFinalAccessoryStates(
            initialStates,
            messages: messages,
            completedTurnIDs: ["turn-1"]
        )

        XCTAssertNil(rehousedStates["final"]?.blockDiffEntries)
        XCTAssertEqual(rehousedStates["file-change"]?.blockDiffEntries?.first?.path, "Sources/App.swift")
    }

    func testTimelineProjectionDoesNotTreatImageOnlyArtifactAsFinalAnswer() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                text: "Create an image",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "status",
                threadID: "thread",
                role: .assistant,
                text: "Generating it now.",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "status-item",
                orderIndex: 2
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                text: "Here is the final result.",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "final-item",
                orderIndex: 3
            ),
            makeMessage(
                id: "image",
                threadID: "thread",
                role: .assistant,
                text: "![Generated image](/Users/example/generated.png)",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "image-item",
                orderIndex: 4
            ),
        ]

        let items = TurnTimelineRenderProjection.project(
            messages: messages,
            completedTurnIDs: ["turn-1"]
        )

        XCTAssertEqual(items.map(\.id), [
            "user",
            "previous-messages:final",
            "final",
            "image",
        ])
        XCTAssertEqual(
            TurnTimelineRenderProjection.collapsedFinalMessageIDs(
                in: messages,
                completedTurnIDs: ["turn-1"]
            ),
            Set(["final"])
        )
    }

    func testTimelineRenderProjectionKeepsRunningTurnExpandedBeforeFinalAnswer() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "status",
                threadID: "thread",
                role: .assistant,
                text: "Working",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                text: "Final",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                orderIndex: 2
            ),
        ]

        let items = TurnTimelineRenderProjection.project(messages: messages)
        let messageIDs = items.compactMap { item -> String? in
            if case .message(let message) = item {
                return message.id
            }
            return nil
        }

        XCTAssertEqual(messageIDs, ["status", "final"])
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

    func testRemoveDuplicateAssistantMessagesCollapsesLateReplaySubsetForSameTurn() {
        let now = Date()
        let finalText = """
        I checked the latest TestFlight email and found the current build.

        Latest TestFlight version: Remodex 1.4 (122) for iOS.
        """
        let replayText = "Latest TestFlight version: Remodex 1.4 (122) for iOS."
        let messages = [
            makeMessage(
                id: "assistant-final",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: finalText,
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1"
            ),
            makeMessage(
                id: "assistant-replay",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: replayText,
                createdAt: now.addingTimeInterval(180),
                turnID: "turn-1"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateAssistantMessages(in: messages)

        XCTAssertEqual(deduped.map(\.id), ["assistant-final"])
    }

    func testRemoveDuplicateAssistantMessagesKeepsStableOverlappingItems() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "assistant-1",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "A stable assistant response with an overlapping shared explanation.",
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-1"
            ),
            makeMessage(
                id: "assistant-2",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "stable assistant response with an overlapping shared explanation",
                createdAt: now.addingTimeInterval(180),
                turnID: "turn-1",
                itemID: "item-2"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateAssistantMessages(in: messages)

        XCTAssertEqual(deduped.map(\.id), ["assistant-1", "assistant-2"])
    }

    func testRemoveDuplicateAssistantMessagesDropsFullBlockReplayEvenWithStableItem() {
        let now = Date()
        let introText = "I'll check Gmail for the latest TestFlight message."
        let finalText = "Latest TestFlight version: 1.4 (123)."
        let messages = [
            makeMessage(
                id: "assistant-intro",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: introText,
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-intro"
            ),
            makeMessage(
                id: "tool",
                threadID: "thread",
                role: .system,
                kind: .toolActivity,
                text: "Read 6807e4de/...",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "tool-1"
            ),
            makeMessage(
                id: "assistant-final",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: finalText,
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "item-final"
            ),
            makeMessage(
                id: "assistant-replay",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "\(introText)\n\n\(finalText)",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "item-replay"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateAssistantMessages(in: messages)

        XCTAssertEqual(deduped.map(\.id), ["assistant-intro", "tool", "assistant-final"])
    }

    func testRemoveDuplicateAssistantMessagesDropsFullBlockReplayWhenPriorAssistantTurnIsMissing() {
        let now = Date()
        let introText = "I'll check Gmail for the latest TestFlight message."
        let finalText = "Latest TestFlight version: 1.4 (123)."
        let messages = [
            makeMessage(
                id: "assistant-intro",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: introText,
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-intro"
            ),
            makeMessage(
                id: "tool",
                threadID: "thread",
                role: .system,
                kind: .toolActivity,
                text: "Read 6807e4de/...",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "tool-1"
            ),
            makeMessage(
                id: "assistant-final",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: finalText,
                createdAt: now.addingTimeInterval(2),
                itemID: "item-final"
            ),
            makeMessage(
                id: "assistant-replay",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "\(introText)\n\n\(finalText)",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "item-replay"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateAssistantMessages(in: messages)

        XCTAssertEqual(deduped.map(\.id), ["assistant-intro", "tool", "assistant-final"])
    }

    func testRemoveDuplicateAssistantMessagesDropsLongExactTerminalReplayWithStableItem() {
        let now = Date()
        let finalText = """
        Latest TestFlight inbox email says:

        Remodex version 1.4, build 124

        Subject: "Remodex - Remote AI Coding 1.4 (124) for iOS is now available to test."
        """
        let statusText = "I'll use the Gmail connector to search recent inbox mentions."
        let messages = [
            makeMessage(
                id: "assistant-final",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: finalText,
                createdAt: now,
                turnID: "turn-1",
                itemID: "item-final"
            ),
            makeMessage(
                id: "assistant-status",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: statusText,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-status"
            ),
            makeMessage(
                id: "assistant-terminal-replay",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: finalText,
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "item-terminal"
            ),
        ]

        let deduped = TurnTimelineReducer.removeDuplicateAssistantMessages(in: messages)

        XCTAssertEqual(deduped.map(\.id), ["assistant-final", "assistant-status"])
    }

    func testProjectOrdersLateStatusBeforeFinalUsingCreatedAt() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "tool-row",
                threadID: "thread",
                role: .system,
                kind: .toolActivity,
                text: "Read 6807e4de/...",
                createdAt: now,
                turnID: "turn-1",
                itemID: "tool-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "assistant-final",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Latest TestFlight inbox email says: Remodex version 1.4, build 124.",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "item-final",
                orderIndex: 2
            ),
            makeMessage(
                id: "assistant-status",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "I'll use the Gmail connector to search recent inbox mentions.",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "item-status",
                orderIndex: 3
            ),
        ]

        let projection = TurnTimelineReducer.project(messages: messages)

        XCTAssertEqual(projection.messages.map(\.id), ["tool-row", "assistant-status", "assistant-final"])
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

    func testEnforceIntraTurnOrderKeepsFileChangeAfterFinalAssistantWhenStatusTextPrecedesIt() {
        let now = Date()
        var order = 0
        func nextOrder() -> Int { order += 1; return order }

        let messages = [
            makeMessage(
                id: "user-1",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Change the app",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-status",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Working on it",
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                itemID: "status-item",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "file-change",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: "Path: Sources/App.swift\nKind: update\nTotals: +1 -0",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "file-change-item",
                orderIndex: nextOrder()
            ),
            makeMessage(
                id: "assistant-final",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Done",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                itemID: "final-item",
                orderIndex: nextOrder()
            ),
        ]

        let reordered = TurnTimelineReducer.enforceIntraTurnOrder(in: messages)
        XCTAssertEqual(reordered.map(\.id), [
            "user-1",
            "assistant-status",
            "assistant-final",
            "file-change",
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

        XCTAssertEqual(blockInfo[0]?.copyText, "Completed response")
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

    func testAssistantBlockInfoDeduplicatesEquivalentSingleFileDiffSnapshots() {
        let now = Date()
        let diffCode = """
        @@ -1,3 +1,4 @@
         struct TurnMessageComponents {}
        +let assistantCopyText = true
        """
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
            makeMessage(
                id: "diff-absolute",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: /Users/emanueledipietro/Developer/Remodex/CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift
                Kind: update
                Totals: +1 -0

                ```diff
                \(diffCode)
                ```
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1"
            ),
            makeMessage(
                id: "diff-relative",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift
                Kind: update
                Totals: +1 -0

                ```diff
                \(diffCode)
                ```
                """,
                createdAt: now.addingTimeInterval(2),
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

        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.count, 1)
        XCTAssertEqual(
            blockInfo[2]?.blockDiffEntries?.first?.path,
            "CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift"
        )
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.additions, 1)
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.deletions, 0)
    }

    func testCollapsedFinalMessageKeepsBlockDiffActionsWhenLateActivityIsHidden() {
        let now = Date()
        let messages = [
            makeMessage(
                id: "user",
                threadID: "thread",
                role: .user,
                kind: .chat,
                text: "Fix the bug",
                createdAt: now,
                turnID: "turn-1",
                orderIndex: 1
            ),
            makeMessage(
                id: "file-change",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +1 -0
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1",
                orderIndex: 2
            ),
            makeMessage(
                id: "final",
                threadID: "thread",
                role: .assistant,
                kind: .chat,
                text: "Done.",
                createdAt: now.addingTimeInterval(2),
                turnID: "turn-1",
                itemID: "final-item",
                orderIndex: 3
            ),
            makeMessage(
                id: "late-tool",
                threadID: "thread",
                role: .system,
                kind: .toolActivity,
                text: "Late metadata refresh",
                createdAt: now.addingTimeInterval(3),
                turnID: "turn-1",
                orderIndex: 4
            ),
        ]

        let blockInfo = TurnTimelineView<EmptyView, EmptyView>.assistantBlockInfo(
            for: messages,
            activeTurnID: nil,
            isThreadRunning: false,
            latestTurnTerminalState: .completed,
            stoppedTurnIDs: []
        )
        let initialStates = [String: AssistantBlockAccessoryState](
            uniqueKeysWithValues: zip(messages, blockInfo).compactMap { message, state in
                guard let state else { return nil }
                return (message.id, state)
            }
        )

        let rehousedStates = TurnTimelineView<EmptyView, EmptyView>.rehomeCollapsedFinalAccessoryStates(
            initialStates,
            messages: messages,
            completedTurnIDs: ["turn-1"]
        )

        XCTAssertEqual(
            TurnTimelineRenderProjection.project(
                messages: messages,
                completedTurnIDs: ["turn-1"]
            ).map(\.id),
            ["user", "previous-messages:final", "file-change", "final"]
        )
        XCTAssertNil(initialStates["final"]?.blockDiffEntries)
        XCTAssertEqual(rehousedStates["final"]?.copyText, "Done.")
        XCTAssertEqual(rehousedStates["final"]?.blockDiffEntries?.count, 1)
        XCTAssertEqual(rehousedStates["final"]?.blockDiffEntries?.first?.path, "Sources/App.swift")
    }

    func testAssistantBlockInfoMergesDifferentSnapshotsForSameFile() {
        let now = Date()
        let firstDiff = """
        @@ -1,3 +1,4 @@
        struct TurnMessageComponents {}
        +let firstChange = true
        """
        let secondDiff = """
        @@ -10,3 +10,4 @@
         struct TurnDiffSheet {}
        +let secondChange = true
        """
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
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift
                Kind: update
                Totals: +1 -0

                ```diff
                \(firstDiff)
                ```
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1"
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: /Users/emanueledipietro/Developer/Remodex/CodexMobile/CodexMobile/Views/Turn/TurnMessageComponents.swift
                Kind: update
                Totals: +1 -0

                ```diff
                \(secondDiff)
                ```
                """,
                createdAt: now.addingTimeInterval(2),
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

        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.count, 1)
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.additions, 2)
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.deletions, 0)
    }

    func testAssistantBlockInfoPrefersLatestSummaryTotalsAfterDiffChunk() {
        let now = Date()
        let diffCode = """
        @@ -1,3 +1,4 @@
        +let diffBackedFile = true
        """
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
            makeMessage(
                id: "diff-1",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +1 -0

                ```diff
                \(diffCode)
                ```
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1"
            ),
            makeMessage(
                id: "summary-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +3 -1
                """,
                createdAt: now.addingTimeInterval(2),
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

        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.count, 1)
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.path, "Sources/App.swift")
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.additions, 3)
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.deletions, 1)
        XCTAssertEqual(blockInfo[2]?.blockDiffText?.contains("```diff"), true)
    }

    func testAssistantBlockInfoPrefersInlineTotalsOverSameMessageDiffCounts() {
        let now = Date()
        let diffCode = """
        @@ -1,3 +1,4 @@
        +let diffBackedFile = true
        """
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
            makeMessage(
                id: "diff-with-inline-totals",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update

                ```diff
                \(diffCode)
                ```

                Totals: +3 -1
                """,
                createdAt: now.addingTimeInterval(1),
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

        XCTAssertEqual(blockInfo[1]?.blockDiffEntries?.count, 1)
        XCTAssertEqual(blockInfo[1]?.blockDiffEntries?.first?.path, "Sources/App.swift")
        XCTAssertEqual(blockInfo[1]?.blockDiffEntries?.first?.additions, 3)
        XCTAssertEqual(blockInfo[1]?.blockDiffEntries?.first?.deletions, 1)
        XCTAssertEqual(blockInfo[1]?.blockDiffText?.contains("```diff"), true)
    }

    func testAssistantBlockInfoKeepsRepeatedSameFileChunksAtFinalTotals() {
        let now = Date()
        let firstDiff = """
        @@ -1,3 +1,4 @@
        +let firstChange = true
        """
        let secondDiff = """
        @@ -10,3 +10,4 @@
        +let secondChange = true
        """
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
            makeMessage(
                id: "diff-with-repeated-path",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update

                ```diff
                \(firstDiff)
                ```

                Path: Sources/App.swift

                ```diff
                \(secondDiff)
                ```

                Totals: +2 -0
                """,
                createdAt: now.addingTimeInterval(1),
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

        XCTAssertEqual(blockInfo[1]?.blockDiffEntries?.count, 1)
        XCTAssertEqual(blockInfo[1]?.blockDiffEntries?.first?.path, "Sources/App.swift")
        XCTAssertEqual(blockInfo[1]?.blockDiffEntries?.first?.additions, 2)
        XCTAssertEqual(blockInfo[1]?.blockDiffEntries?.first?.deletions, 0)
        XCTAssertEqual(blockInfo[1]?.blockDiffText?.contains("firstChange"), true)
        XCTAssertEqual(blockInfo[1]?.blockDiffText?.contains("secondChange"), true)
    }

    func testAssistantBlockInfoKeepsSummaryOnlyFileWhenSiblingHasDiffChunk() {
        let now = Date()
        let diffCode = """
        @@ -1,3 +1,4 @@
        +let diffBackedFile = true
        """
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
            makeMessage(
                id: "diff-with-code",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/App.swift
                Kind: update
                Totals: +1 -0

                ```diff
                \(diffCode)
                ```
                """,
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1"
            ),
            makeMessage(
                id: "summary-only",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: Sources/Composer.swift
                Kind: update
                Totals: +3 -1
                """,
                createdAt: now.addingTimeInterval(2),
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

        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.count, 2)
        XCTAssertEqual(
            blockInfo[2]?.blockDiffEntries?.map(\.path),
            ["Sources/App.swift", "Sources/Composer.swift"]
        )
    }

    func testAssistantBlockInfoKeepsSummaryOnlyEntriesWithoutDiffFencesSeparated() {
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
                createdAt: now.addingTimeInterval(1),
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
                createdAt: now.addingTimeInterval(2),
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

        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.count, 2)
        XCTAssertEqual(
            blockInfo[2]?.blockDiffEntries?.map(\.path),
            ["Sources/App.swift", "Sources/Composer.swift"]
        )
    }

    func testAssistantBlockInfoDoesNotDoubleCountIdenticalSummaryOnlySnapshots() {
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
                createdAt: now.addingTimeInterval(1),
                turnID: "turn-1"
            ),
            makeMessage(
                id: "diff-2",
                threadID: "thread",
                role: .system,
                kind: .fileChange,
                text: """
                Status: completed

                Path: /Users/emanueledipietro/Developer/Remodex/Sources/App.swift
                Kind: update
                Totals: +2 -1
                """,
                createdAt: now.addingTimeInterval(2),
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

        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.count, 1)
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.path, "Sources/App.swift")
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.additions, 2)
        XCTAssertEqual(blockInfo[2]?.blockDiffEntries?.first?.deletions, 1)
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
        assistantPhase: String? = nil,
        text: String,
        createdAt: Date = Date(),
        turnID: String? = nil,
        itemID: String? = nil,
        isStreaming: Bool = false,
        attachments: [CodexImageAttachment] = [],
        deliveryState: CodexMessageDeliveryState = .confirmed,
        orderIndex: Int? = nil
    ) -> CodexMessage {
        var message = CodexMessage(
            id: id,
            threadId: threadID,
            role: role,
            kind: kind,
            assistantPhase: assistantPhase,
            text: text,
            createdAt: createdAt,
            turnId: turnID,
            itemId: itemID,
            isStreaming: isStreaming,
            deliveryState: deliveryState,
            attachments: attachments
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

    func testFollowBottomKeepsPinnedAcrossTransientGeometryDrift() {
        XCTAssertTrue(
            TurnScrollStateTracker.shouldPinDuringGeometryChange(
                currentMode: .followBottom,
                isScrolledToBottom: false,
                isAutomaticScrollingPaused: false,
                assistantAnchorTargetExists: true
            )
        )
    }

    func testIgnoresTransientNotBottomOnlyWhileFollowSnapIsPending() {
        XCTAssertTrue(
            TurnScrollStateTracker.shouldIgnoreTransientNotBottomGeometry(
                currentMode: .followBottom,
                hasPendingFollowBottomScroll: true,
                isAutomaticScrollingPaused: false
            )
        )

        XCTAssertFalse(
            TurnScrollStateTracker.shouldIgnoreTransientNotBottomGeometry(
                currentMode: .followBottom,
                hasPendingFollowBottomScroll: false,
                isAutomaticScrollingPaused: false
            )
        )

        XCTAssertFalse(
            TurnScrollStateTracker.shouldIgnoreTransientNotBottomGeometry(
                currentMode: .followBottom,
                hasPendingFollowBottomScroll: true,
                isAutomaticScrollingPaused: true
            )
        )
    }

    func testAcceptedNotBottomGeometrySwitchesFollowBottomToManual() {
        XCTAssertEqual(
            TurnScrollStateTracker.modeAfterAcceptedNotBottomGeometry(currentMode: .followBottom),
            .manual
        )

        XCTAssertEqual(
            TurnScrollStateTracker.modeAfterAcceptedNotBottomGeometry(currentMode: .manual),
            .manual
        )

        XCTAssertEqual(
            TurnScrollStateTracker.modeAfterAcceptedNotBottomGeometry(currentMode: .anchorAssistantResponse),
            .anchorAssistantResponse
        )
    }

    func testManualAndPausedModesDoNotPinDuringGeometryChange() {
        XCTAssertFalse(
            TurnScrollStateTracker.shouldPinDuringGeometryChange(
                currentMode: .manual,
                isScrolledToBottom: true,
                isAutomaticScrollingPaused: false,
                assistantAnchorTargetExists: false
            )
        )

        XCTAssertFalse(
            TurnScrollStateTracker.shouldPinDuringGeometryChange(
                currentMode: .followBottom,
                isScrolledToBottom: true,
                isAutomaticScrollingPaused: true,
                assistantAnchorTargetExists: false
            )
        )
    }

    func testAssistantAnchorPinsOnlyWhileWaitingForAssistantTarget() {
        XCTAssertTrue(
            TurnScrollStateTracker.shouldPinDuringGeometryChange(
                currentMode: .anchorAssistantResponse,
                isScrolledToBottom: true,
                isAutomaticScrollingPaused: false,
                assistantAnchorTargetExists: false
            )
        )

        XCTAssertFalse(
            TurnScrollStateTracker.shouldPinDuringGeometryChange(
                currentMode: .anchorAssistantResponse,
                isScrolledToBottom: true,
                isAutomaticScrollingPaused: false,
                assistantAnchorTargetExists: true
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
