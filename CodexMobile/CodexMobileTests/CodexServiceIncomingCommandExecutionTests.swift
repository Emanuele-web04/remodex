// FILE: CodexServiceIncomingCommandExecutionTests.swift
// Purpose: Verifies legacy+modern command execution event handling and dedup behavior.
// Layer: Unit Test
// Exports: CodexServiceIncomingCommandExecutionTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceIncomingCommandExecutionTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testLegacyBeginAndModernItemStartedMergeIntoSingleRunRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let callID = "call-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/exec_command_begin",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("exec_command_begin"),
                    "call_id": .string(callID),
                    "turn_id": .string(turnID),
                    "cwd": .string("/tmp"),
                    "command": .array([
                        .string("/bin/zsh"),
                        .string("-lc"),
                        .string("echo one"),
                    ]),
                ]),
            ])
        )

        service.handleNotification(
            method: "item/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(callID),
                    "type": .string("commandExecution"),
                    "status": .string("inProgress"),
                    "cwd": .string("/tmp"),
                    "command": .string("/bin/zsh -lc \"echo one\""),
                    "commandActions": .array([]),
                ]),
            ])
        )

        let runRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .commandExecution
        }
        XCTAssertEqual(runRows.count, 1)
        XCTAssertTrue(runRows[0].text.lowercased().hasPrefix("running "))
    }

    func testOutputDeltaDoesNotReplaceExistingCommandPreview() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let callID = "call-\(UUID().uuidString)"

        service.handleNotification(
            method: "item/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(callID),
                    "type": .string("commandExecution"),
                    "status": .string("inProgress"),
                    "cwd": .string("/tmp"),
                    "command": .string("/bin/zsh -lc \"echo one\""),
                    "commandActions": .array([]),
                ]),
            ])
        )

        let before = service.messages(for: threadID).first { $0.itemId == callID }?.text
        service.handleNotification(
            method: "item/commandExecution/outputDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(callID),
                "delta": .string("ONE\n"),
            ])
        )
        let after = service.messages(for: threadID).first { $0.itemId == callID }?.text

        XCTAssertEqual(after, before)
        XCTAssertFalse((after ?? "").lowercased().contains("running command"))
    }

    func testLegacyEndCompletesExistingRunRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let callID = "call-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/exec_command_begin",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("exec_command_begin"),
                    "call_id": .string(callID),
                    "turn_id": .string(turnID),
                    "cwd": .string("/tmp"),
                    "command": .array([.string("echo"), .string("ok")]),
                ]),
            ])
        )

        service.handleNotification(
            method: "codex/event/exec_command_end",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("exec_command_end"),
                    "call_id": .string(callID),
                    "turn_id": .string(turnID),
                    "cwd": .string("/tmp"),
                    "status": .string("completed"),
                    "exit_code": .integer(0),
                    "command": .array([.string("echo"), .string("ok")]),
                ]),
            ])
        )

        let runRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .commandExecution
        }
        XCTAssertEqual(runRows.count, 1)
        XCTAssertTrue(runRows[0].text.lowercased().hasPrefix("completed "))
        XCTAssertFalse(runRows[0].isStreaming)
    }

    func testToolCallDeltaAddsDedicatedToolActivityRows() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "item/toolCall/outputDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "delta": .string("Read CodexProtocol.swift\nSearch extractSystemTitleAndBody\n{\"ignore\":\"json\"}"),
            ])
        )

        let toolRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .toolActivity
        }
        XCTAssertEqual(toolRows.count, 1)
        let body = toolRows[0].text
        XCTAssertTrue(body.contains("Read CodexProtocol.swift"))
        XCTAssertTrue(body.contains("Search extractSystemTitleAndBody"))
        XCTAssertFalse(body.contains("ignore"))
    }

    func testHistoryToolCallRestoresDedicatedToolActivityRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        let history = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .string("2026-03-12T10:00:00Z"),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("tool-item"),
                                "type": .string("toolCall"),
                                "name": .string("search"),
                                "status": .string("completed"),
                                "message": .string("Search extractSystemTitleAndBody"),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].kind, .toolActivity)
        XCTAssertEqual(history[0].text, "Search extractSystemTitleAndBody")
        XCTAssertEqual(history[0].turnId, turnID)
    }

    func testHistoryCompletedAtAliasAndTimezoneRestoreMessageTimestamp() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let expectedDate = ISO8601DateFormatter().date(from: "2026-05-19T00:14:00Z")

        let history = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .string("2026-03-12T10:00:00Z"),
                "timezone": .string("America/New_York"),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "completedAt": .string("2026-05-19T00:14:00Z"),
                        "items": .array([
                            .object([
                                "id": .string("assistant-item"),
                                "type": .string("message"),
                                "role": .string("assistant"),
                                "content": .array([
                                    .object([
                                        "type": .string("output_text"),
                                        "text": .string("Done."),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertNotNil(expectedDate)
        XCTAssertEqual(
            history[0].createdAt.timeIntervalSince1970,
            expectedDate!.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(history[0].timeZoneIdentifier, "America/New_York")
    }

    func testHistoryRawExecCommandToolCallRestoresCommandRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        let history = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .string("2026-03-12T10:00:00Z"),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("call-command"),
                                "type": .string("toolCall"),
                                "name": .string("exec_command"),
                                "arguments": .string(#"{"cmd":"git status --short --branch","workdir":"/repo"}"#),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].kind, .commandExecution)
        XCTAssertEqual(history[0].text, "completed git status --short --branch")
        XCTAssertEqual(history[0].turnId, turnID)
    }

    func testHistoryToolCallAcceptsExpandedReadableActivityVerbs() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        let history = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .string("2026-03-12T10:00:00Z"),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("tool-item"),
                                "type": .string("toolCall"),
                                "name": .string("view_image"),
                                "message": .string("Capture screenshot\nCheck weather Rome"),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].kind, .toolActivity)
        XCTAssertEqual(history[0].text, "Capture screenshot\nCheck weather Rome")
    }

    func testHistoryRestoresGeneratedImageEndAndImageViewItems() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let history = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .string("2026-03-12T10:00:00Z"),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("image-end"),
                                "type": .string("image_generation_end"),
                                "saved_path": .string("/Users/example/generated end.png"),
                            ]),
                            .object([
                                "id": .string("image-view"),
                                "type": .string("imageView"),
                                "path": .string("/Users/example/viewed image.png"),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.itemId), ["image-end", "image-view"])
        XCTAssertEqual(history.map(\.text), [
            "![Generated image](</Users/example/generated end.png>)",
            "![Generated image](</Users/example/viewed image.png>)",
        ])
    }

    func testHistoryDecodesInputImageContentAsAttachment() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let history = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .string("2026-03-12T10:00:00Z"),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("user-image"),
                                "type": .string("user_message"),
                                "content": .array([
                                    .object([
                                        "type": .string("input_text"),
                                        "text": .string("Look at this"),
                                    ]),
                                    .object([
                                        "type": .string("input_image"),
                                        "image_url": .object([
                                            "url": .string("remodex://history-image-elided"),
                                        ]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].role, .user)
        XCTAssertEqual(history[0].text, "Look at this")
        XCTAssertEqual(history[0].attachments.count, 1)
        XCTAssertEqual(history[0].attachments[0].sourceURL, "remodex://history-image-elided")
    }

    func testHistoryDecodesNumericStringMicrosecondTimestamps() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let expectedDate = Date(timeIntervalSince1970: 1_710_000_000)
        let microseconds = "1710000000000000"

        let history = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .string(microseconds),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("assistant-item"),
                                "type": .string("assistantMessage"),
                                "createdAt": .string(microseconds),
                                "message": .string("Hello"),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].createdAt.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMergeHistoryMessagesReplacesOptimisticCreatedAtWithTrustworthyServerTimestamp() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let localDate = Date(timeIntervalSince1970: 1_720_000_000)
        let serverDate = Date(timeIntervalSince1970: 1_710_000_000)

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Hello",
                createdAt: localDate,
                turnId: turnID,
                itemId: "assistant-item",
                isStreaming: false
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Hello",
                createdAt: serverDate,
                turnId: turnID,
                itemId: "assistant-item",
                isStreaming: false
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].createdAt.timeIntervalSince1970, serverDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testLateActivityLineAfterTurnCompletionDoesNotReopenToolActivityStream() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        service.handleNotification(
            method: "item/toolCall/outputDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "delta": .string("Read file A.swift"),
            ])
        )
        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        service.handleNotification(
            method: "codex/event/read",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "path": .string("B.swift"),
            ])
        )

        let toolRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .toolActivity
        }
        XCTAssertEqual(toolRows.count, 1)
        XCTAssertTrue(toolRows[0].text.contains("Read file A.swift"))
        XCTAssertTrue(toolRows[0].text.contains("Read B.swift"))
        XCTAssertFalse(toolRows[0].isStreaming)
    }

    func testLateActivityLineWithoutTurnIdAfterCompletionDoesNotCreateTrailingToolActivityRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )

        service.handleNotification(
            method: "codex/event/background_event",
            params: .object([
                "threadId": .string(threadID),
                "message": .string("Controllo subito il repository"),
            ])
        )

        let toolRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .toolActivity
        }
        XCTAssertTrue(toolRows.isEmpty)
    }

    func testEssentialReadEventUsesToolActivityInsteadOfThinking() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        service.handleNotification(
            method: "codex/event/read",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "path": .string("A.swift"),
            ])
        )

        let toolRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .toolActivity
        }
        let thinkingRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .thinking
        }

        XCTAssertEqual(toolRows.count, 1)
        XCTAssertEqual(toolRows[0].text, "Read A.swift")
        XCTAssertTrue(thinkingRows.isEmpty)
    }

    func testLiveToolActivityReusesSingleMatchingTurnRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let existing = CodexMessage(
            threadId: threadID,
            role: .system,
            kind: .toolActivity,
            text: "Read A.swift",
            turnId: turnID,
            itemId: nil,
            isStreaming: true,
            deliveryState: .confirmed
        )
        service.messagesByThread[threadID] = [existing]

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "tool-real",
            kind: .toolActivity,
            text: "Read A.swift",
            isStreaming: true
        )

        let toolRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .toolActivity
        }
        XCTAssertEqual(toolRows.count, 1)
        XCTAssertEqual(toolRows[0].id, existing.id)
        XCTAssertEqual(toolRows[0].itemId, "tool-real")
    }

    func testLiveToolActivityKeepsDistinctStableItemsWithIdenticalTextSeparated() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "tool-1",
            kind: .toolActivity,
            text: "Read foo.swift",
            isStreaming: true
        )
        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "tool-2",
            kind: .toolActivity,
            text: "Read foo.swift",
            isStreaming: true
        )

        let toolRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .toolActivity
        }
        XCTAssertEqual(toolRows.count, 2)
        XCTAssertEqual(toolRows.map(\.itemId), ["tool-1", "tool-2"])
    }

    func testCompletedToolActivityPlaceholderIsRemovedWhenNoContentArrives() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "tool-\(UUID().uuidString)"

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: itemID,
            kind: .toolActivity,
            text: "",
            isStreaming: true
        )
        service.completeStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: itemID,
            kind: .toolActivity,
            text: nil
        )

        let toolRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .toolActivity
        }
        XCTAssertTrue(toolRows.isEmpty)
    }

    func testLiveFileChangeReusesTurnlessRowWhenTurnIDArrives() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let fileChangeText = """
        Status: inProgress

        Path: Sources/App.swift
        Kind: update
        Totals: +2 -1
        """

        service.appendSystemMessage(
            threadId: threadID,
            text: fileChangeText,
            kind: .fileChange,
            isStreaming: true
        )
        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "file-1",
            kind: .fileChange,
            text: fileChangeText,
            isStreaming: true
        )

        let fileRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .fileChange
        }
        XCTAssertEqual(fileRows.count, 1)
        XCTAssertEqual(fileRows[0].turnId, turnID)
        XCTAssertEqual(fileRows[0].itemId, "file-1")
    }

    // The bootstrap fallback must not reach back across a user prompt: the
    // previous turn's post-completion table is not claimable by a new turn
    // whose first file-change event lands before any of its rows are tagged.
    func testLiveFileChangeBootstrapFallbackDoesNotCrossUserBoundary() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let previousTurnID = "turn-\(UUID().uuidString)"
        let newTurnID = "turn-\(UUID().uuidString)"
        let fileChangeText = """
        Status: completed

        Path: Sources/App.swift
        Kind: update
        Totals: +2 -1
        """

        // Previous turn: anchored user row, then its turnless end-of-turn table.
        service.appendUserMessage(threadId: threadID, text: "first prompt", turnId: previousTurnID)
        service.appendSystemMessage(
            threadId: threadID,
            text: fileChangeText,
            kind: .fileChange,
            isStreaming: false
        )

        // Next turn starts: pending user row, turn/started, and the turn's
        // first event is a file-change touching the same working-tree paths.
        service.appendUserMessage(threadId: threadID, text: "nice")
        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(newTurnID),
            ])
        )
        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: newTurnID,
            itemId: "file-new-turn",
            kind: .fileChange,
            text: fileChangeText,
            isStreaming: false
        )

        let fileRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .fileChange
        }
        XCTAssertEqual(fileRows.count, 2)
        XCTAssertNil(fileRows[0].turnId)
        XCTAssertEqual(fileRows[1].turnId, newTurnID)
        XCTAssertEqual(fileRows[1].itemId, "file-new-turn")
    }

    func testLiveFileChangeSnapshotFallbackReusesTurnlessRowWithoutPathKeys() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let fileChangeText = """
        Status: completed

        Diff available in the changes sheet.
        """

        service.appendSystemMessage(
            threadId: threadID,
            text: fileChangeText,
            kind: .fileChange,
            isStreaming: true
        )
        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "file-snapshot",
            kind: .fileChange,
            text: fileChangeText,
            isStreaming: false
        )

        let fileRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .fileChange
        }
        XCTAssertEqual(fileRows.count, 1)
        XCTAssertEqual(fileRows[0].turnId, turnID)
        XCTAssertEqual(fileRows[0].itemId, "file-snapshot")
    }

    func testLiveFileChangeAppendDoesNotStealNextTurnsTurnlessTable() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let oldTurnID = "turn-\(UUID().uuidString)"
        let newTurnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)
        let fileChangeText = """
        Status: completed

        Path: package.json
        Kind: update
        Totals: +1 -1
        """

        service.messagesByThread[threadID] = [
            CodexMessage(
                id: "user-old-turn",
                threadId: threadID,
                role: .user,
                text: "first change",
                createdAt: now,
                turnId: oldTurnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "user-new-turn",
                threadId: threadID,
                role: .user,
                text: "second change",
                createdAt: now.addingTimeInterval(10),
                turnId: newTurnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "new-turn-table",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: fileChangeText,
                createdAt: now.addingTimeInterval(12),
                turnId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        service.appendSystemMessage(
            threadId: threadID,
            text: fileChangeText,
            turnId: oldTurnID,
            itemId: "file-old",
            kind: .fileChange,
            isStreaming: false
        )

        let fileRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .fileChange
        }
        XCTAssertEqual(fileRows.count, 2)
        XCTAssertNil(service.messages(for: threadID).first(where: { $0.id == "new-turn-table" })?.turnId)
        XCTAssertTrue(fileRows.contains { $0.turnId == oldTurnID && $0.itemId == "file-old" })
    }

    func testTurnDiffUpdatedDoesNotCreateVisibleFileChangeRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let diff = """
        diff --git a/README.md b/README.md
        index 1111111..2222222 100644
        --- a/README.md
        +++ b/README.md
        @@ -1,1 +1,1 @@
        -old
        +new
        """

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Checked the repo."
        )
        service.handleNotification(
            method: "turn/diff/updated",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "diff": .string(diff),
            ])
        )

        let visibleFileRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .fileChange
        }
        XCTAssertTrue(visibleFileRows.isEmpty)

        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)
        let assistantMessage = try? XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        XCTAssertNil(assistantMessage.flatMap { service.readyChangeSet(forAssistantMessage: $0) })
    }

    func testTurnDiffUpdatedCanRecordUndoAfterRealFileChangeEvidence() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let diff = """
        diff --git a/README.md b/README.md
        index 1111111..2222222 100644
        --- a/README.md
        +++ b/README.md
        @@ -1,1 +1,1 @@
        -old
        +new
        """

        service.appendSystemMessage(
            threadId: threadID,
            text: """
            Status: completed

            Path: README.md
            Kind: update
            Totals: +1 -1
            """,
            turnId: turnID,
            kind: .fileChange
        )
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Updated README."
        )
        service.handleNotification(
            method: "turn/diff/updated",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "diff": .string(diff),
            ])
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try? XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        let changeSet = assistantMessage.flatMap { service.readyChangeSet(forAssistantMessage: $0) }
        XCTAssertEqual(changeSet?.fileChanges.map(\.path), ["README.md"])
    }

    func testTurnDiffUpdatedIgnoresTurnlessFileChangeEvidence() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let diff = """
        diff --git a/README.md b/README.md
        index 1111111..2222222 100644
        --- a/README.md
        +++ b/README.md
        @@ -1,1 +1,1 @@
        -old
        +new
        """

        service.appendSystemMessage(
            threadId: threadID,
            text: """
            Status: completed

            Path: README.md
            Kind: update
            Totals: +1 -1
            """,
            kind: .fileChange
        )
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Checked README."
        )
        service.handleNotification(
            method: "turn/diff/updated",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "diff": .string(diff),
            ])
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.noteTurnFinished(threadId: threadID, turnId: turnID)

        let assistantMessage = try? XCTUnwrap(service.messages(for: threadID).last(where: { $0.role == .assistant }))
        XCTAssertNil(assistantMessage.flatMap { service.readyChangeSet(forAssistantMessage: $0) })
    }

    func testLegacyToolActivityAfterAssistantCreatesNewLaterRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        service.messagesByThread[threadID] = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read A.swift",
                createdAt: now,
                turnId: turnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                kind: .chat,
                text: "Prima risposta",
                createdAt: now.addingTimeInterval(0.1),
                turnId: turnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        service.appendToolActivityLine(
            threadId: threadID,
            turnId: turnID,
            line: "Read B.swift"
        )

        let messages = service.messages(for: threadID)
        let toolRows = messages.filter { $0.role == .system && $0.kind == .toolActivity }

        XCTAssertEqual(toolRows.count, 2)
        XCTAssertEqual(toolRows[0].text, "Read A.swift")
        XCTAssertEqual(toolRows[1].text, "Read B.swift")
        XCTAssertEqual(messages.map(\.role), [.system, .assistant, .system])
    }

    func testHistoryMergeDoesNotCollapseRepeatedToolActivityRowsWhenTurnHasMultipleCandidates() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read foo.swift",
                createdAt: now,
                turnId: turnID,
                itemId: "tool-1",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read foo.swift",
                createdAt: now.addingTimeInterval(0.1),
                turnId: turnID,
                itemId: "tool-2",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read foo.swift",
                createdAt: now.addingTimeInterval(0.2),
                turnId: turnID,
                itemId: "tool-3",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let toolRows = merged.filter { $0.role == .system && $0.kind == .toolActivity }

        XCTAssertEqual(toolRows.map(\.itemId), ["tool-1", "tool-2", "tool-3"])
    }

    func testHistoryMergeUpgradesSyntheticToolActivityIdentityToRealItemID() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read foo.swift",
                createdAt: now,
                turnId: turnID,
                itemId: "turn:\(turnID)|kind:toolActivity",
                isStreaming: true,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read foo.swift",
                createdAt: now.addingTimeInterval(0.2),
                turnId: turnID,
                itemId: "tool-1",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let toolRows = merged.filter { $0.role == .system && $0.kind == .toolActivity }

        XCTAssertEqual(toolRows.count, 1)
        XCTAssertEqual(toolRows[0].itemId, "tool-1")
    }

    func testHistoryMergeKeepsSingleCompletedSyntheticToolActivitySeparateFromRepeatedHistoryRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read foo.swift",
                createdAt: now,
                turnId: turnID,
                itemId: "turn:\(turnID)|kind:toolActivity",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read foo.swift",
                createdAt: now.addingTimeInterval(0.2),
                turnId: turnID,
                itemId: "tool-1",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let toolRows = merged.filter { $0.role == .system && $0.kind == .toolActivity }

        XCTAssertEqual(toolRows.count, 2)
        XCTAssertEqual(toolRows.map(\.itemId), ["turn:\(turnID)|kind:toolActivity", "tool-1"])
    }

    func testHistoryFileChangeReconcilesTurnlessLocalRowWhenTurnIDArrives() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()
        let fileChangeText = """
        Status: completed

        Path: Sources/App.swift
        Kind: update
        Totals: +2 -1
        """

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: fileChangeText,
                createdAt: now,
                turnId: nil,
                itemId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: fileChangeText,
                createdAt: now.addingTimeInterval(0.2),
                turnId: turnID,
                itemId: "file-1",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let fileRows = merged.filter { $0.role == .system && $0.kind == .fileChange }

        XCTAssertEqual(fileRows.count, 1)
        XCTAssertEqual(fileRows[0].turnId, turnID)
        XCTAssertEqual(fileRows[0].itemId, "file-1")
    }

    func testHistoryUserMessageReconcilesPendingPhoneRowWhenHistoryOmitsLocalMetadata() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .user,
                text: "Fix this",
                fileMentions: ["Sources/App.swift"],
                createdAt: now,
                turnId: nil,
                itemId: nil,
                isStreaming: false,
                deliveryState: .pending,
                attachments: [
                    CodexImageAttachment(
                        thumbnailBase64JPEG: "thumb-1",
                        payloadDataURL: "data:image/jpeg;base64,abc"
                    ),
                ]
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .user,
                text: "Fix this",
                fileMentions: [],
                createdAt: now.addingTimeInterval(0.2),
                turnId: turnID,
                itemId: "user-1",
                isStreaming: false,
                deliveryState: .confirmed,
                attachments: []
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let userRows = merged.filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].turnId, turnID)
        XCTAssertEqual(userRows[0].deliveryState, .confirmed)
        XCTAssertEqual(userRows[0].fileMentions, ["Sources/App.swift"])
        XCTAssertEqual(userRows[0].attachments.count, 1)
    }

    func testHistoryUserMessageDoesNotGuessBetweenTwoIdenticalPendingRows() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .user,
                text: "Fix this",
                createdAt: now,
                turnId: nil,
                itemId: nil,
                isStreaming: false,
                deliveryState: .pending
            ),
            CodexMessage(
                threadId: threadID,
                role: .user,
                text: "Fix this",
                createdAt: now.addingTimeInterval(0.2),
                turnId: nil,
                itemId: nil,
                isStreaming: false,
                deliveryState: .pending
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .user,
                text: "Fix this",
                createdAt: now.addingTimeInterval(0.4),
                turnId: turnID,
                itemId: "user-1",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let userRows = merged.filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 3)
        XCTAssertEqual(userRows.filter { $0.deliveryState == .pending }.count, 2)
        XCTAssertEqual(userRows.filter { $0.deliveryState == .confirmed }.count, 1)
        XCTAssertEqual(userRows.last?.turnId, turnID)
    }

    func testHistoryUserMessageRebindsConfirmedIdentitylessDesktopMirror() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                id: "desktop-live-mirror",
                threadId: threadID,
                role: .user,
                text: "okok",
                createdAt: now,
                turnId: nil,
                itemId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "user-history",
                threadId: threadID,
                role: .user,
                text: "okok",
                createdAt: now.addingTimeInterval(0.4),
                turnId: turnID,
                itemId: "user-history-item",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let userRows = merged.filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].id, "desktop-live-mirror")
        XCTAssertEqual(userRows[0].turnId, turnID)
        XCTAssertEqual(userRows[0].itemId, "user-history-item")
        XCTAssertEqual(userRows[0].text, "okok")
    }

    func testDesktopMirroredUserMessageEventAndItemStartedDoNotDuplicate() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "user-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/user_message",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "message": .string("okok"),
                "remodexDesktopMirror": .bool(true),
            ])
        )
        service.handleNotification(
            method: "item/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "remodexDesktopMirror": .bool(true),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("userMessage"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("okok"),
                        ]),
                    ]),
                ]),
            ])
        )

        let userRows = service.messages(for: threadID).filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].text, "okok")
        XCTAssertEqual(userRows[0].turnId, turnID)
        XCTAssertEqual(userRows[0].deliveryState, .confirmed)
    }

    // Desktop snapshots without raw turn ids project the same prompt under
    // synthetic identity ("ipc-turn-N" / "<turnId>:input"); that replay must
    // merge into the turn-bound row instead of duplicating the bubble.
    func testDesktopMirroredSyntheticIdentityReplayDoesNotDuplicateUserRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/user_message",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "id": .string("\(turnID):input"),
                "message": .string("jamm bell"),
                "remodexDesktopMirror": .bool(true),
            ])
        )
        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string("ipc-turn-3"),
                "remodexDesktopMirror": .bool(true),
                "item": .object([
                    "id": .string("ipc-turn-3:input"),
                    "type": .string("userMessage"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("jamm bell"),
                        ]),
                    ]),
                ]),
            ])
        )

        let userRows = service.messages(for: threadID).filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].text, "jamm bell")
        XCTAssertEqual(userRows[0].turnId, turnID)
        XCTAssertEqual(userRows[0].itemId, "\(turnID):input")
    }

    // Rollout mirrors can flush the prompt without a resolved turn id; that
    // event must merge into the already turn-bound row of the same prompt.
    func testDesktopMirroredTurnlessUserMessageMergesIntoTurnBoundRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/user_message",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "message": .string("okok"),
                "remodexDesktopMirror": .bool(true),
            ])
        )
        service.handleNotification(
            method: "codex/event/user_message",
            params: .object([
                "threadId": .string(threadID),
                "message": .string("okok"),
                "remodexDesktopMirror": .bool(true),
                "remodexRolloutLiveMirror": .bool(true),
            ])
        )

        let userRows = service.messages(for: threadID).filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].turnId, turnID)
    }

    // Follower-served thread/read projects prompts with synthetic identity and
    // thread-level fallback dates; history merge must bind them to the live row
    // and keep its real identity instead of appending a second bubble.
    func testHistoryUserMessageWithSyntheticDesktopIdentityMergesIntoRealRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)

        let existing = [
            CodexMessage(
                id: "user-live-mirror",
                threadId: threadID,
                role: .user,
                text: "jamm bell",
                createdAt: now,
                turnId: turnID,
                itemId: "\(turnID):input",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "user-projected-history",
                threadId: threadID,
                role: .user,
                text: "jamm bell",
                createdAt: now.addingTimeInterval(-1_380),
                turnId: "ipc-turn-0",
                itemId: "ipc-turn-0:input",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let userRows = merged.filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].id, "user-live-mirror")
        XCTAssertEqual(userRows[0].turnId, turnID)
    }

    // The reverse direction: a provisional synthetic row created from a projected
    // mirror must rebind to the real app-server history identity.
    func testHistoryUserMessageUpgradesSyntheticDesktopIdentityToRealIdentity() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)

        let existing = [
            CodexMessage(
                id: "user-projected-mirror",
                threadId: threadID,
                role: .user,
                text: "jamm bell",
                createdAt: now,
                turnId: "ipc-turn-0",
                itemId: "ipc-turn-0:input",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "user-history",
                threadId: threadID,
                role: .user,
                text: "jamm bell",
                createdAt: now.addingTimeInterval(0.4),
                turnId: turnID,
                itemId: "user-history-item",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let userRows = merged.filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].id, "user-projected-mirror")
        XCTAssertEqual(userRows[0].turnId, turnID)
        XCTAssertEqual(userRows[0].itemId, "user-history-item")
    }

    // Intentional repeats stay separate: two prompts with distinct real turn ids
    // must not collapse even though the text matches.
    func testDesktopMirroredRepeatedSendsWithDistinctRealTurnIdsStaySeparate() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let firstTurnID = "turn-\(UUID().uuidString)"
        let secondTurnID = "turn-\(UUID().uuidString)"

        for turnID in [firstTurnID, secondTurnID] {
            service.handleNotification(
                method: "codex/event/user_message",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "message": .string("okok"),
                    "remodexDesktopMirror": .bool(true),
                ])
            )
        }

        let userRows = service.messages(for: threadID).filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 2)
        XCTAssertEqual(Set(userRows.compactMap(\.turnId)), [firstTurnID, secondTurnID])
    }

    func testHistoryUserMessageRebindsFallbackTimestampEchoToRealDatedRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)

        let existing = [
            CodexMessage(
                id: "user-real",
                threadId: threadID,
                role: .user,
                text: "Can you review this flow?",
                createdAt: now,
                turnId: turnID,
                itemId: "user-real-item",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "user-epoch-echo",
                threadId: threadID,
                role: .user,
                text: "Can you review this flow?",
                createdAt: Date(timeIntervalSince1970: 0),
                turnId: turnID,
                itemId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "user-history",
                threadId: threadID,
                role: .user,
                text: "Can you review this flow?",
                createdAt: now.addingTimeInterval(2),
                turnId: turnID,
                itemId: "user-history-item",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let userRows = merged.filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 2)
        XCTAssertEqual(userRows[0].id, "user-real")
        XCTAssertEqual(userRows[0].itemId, "user-real-item")
    }

    func testHistoryUserMessageWithoutTurnIdDoesNotAppendFallbackTimestampEcho() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)

        let existing = [
            CodexMessage(
                id: "user-local",
                threadId: threadID,
                role: .user,
                text: "/check-code one last time",
                createdAt: now,
                turnId: turnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "user-history-epoch",
                threadId: threadID,
                role: .user,
                text: "/check-code one last time",
                createdAt: Date(timeIntervalSince1970: 0),
                turnId: nil,
                itemId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let userRows = merged.filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].id, "user-local")
        XCTAssertEqual(userRows[0].turnId, turnID)
        XCTAssertEqual(userRows[0].createdAt, now)
    }

    func testHistoryUserMessageWithoutTurnIdReusesCloseLocalRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)

        let existing = [
            CodexMessage(
                id: "user-local",
                threadId: threadID,
                role: .user,
                text: "run this again",
                createdAt: now,
                turnId: turnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "user-history-no-id",
                threadId: threadID,
                role: .user,
                text: "run this again",
                createdAt: now.addingTimeInterval(0.25),
                turnId: nil,
                itemId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let userRows = merged.filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].id, "user-local")
        XCTAssertEqual(userRows[0].turnId, turnID)
    }

    func testThreadReadFallbackTimestampUsesExistingLocalAnchor() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let existingDate = Date(timeIntervalSince1970: 1_779_654_720)
        service.messagesByThread[threadID] = [
            CodexMessage(
                id: "local-anchor",
                threadId: threadID,
                role: .user,
                text: "local anchor",
                createdAt: existingDate,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let messages = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "id": .string(threadID),
                "turns": .array([
                    .object([
                        "items": .array([
                            .object([
                                "id": .string("user-history"),
                                "type": .string("user_message"),
                                "message": .string("history without server time"),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].createdAt, existingDate)
    }

    func testHistoryUserMessageMergesRawSkillCommandIntoRichLocalBubble() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)

        let existing = [
            CodexMessage(
                id: "user-rich",
                threadId: threadID,
                role: .user,
                text: "one last time",
                skillMentions: ["check-code"],
                createdAt: now,
                turnId: turnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "user-raw-history",
                threadId: threadID,
                role: .user,
                text: "$check-code one last time",
                createdAt: now.addingTimeInterval(0.1),
                turnId: turnID,
                itemId: "raw-user-item",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let userRows = merged.filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].id, "user-rich")
        XCTAssertEqual(userRows[0].text, "one last time")
        XCTAssertEqual(userRows[0].skillMentions, ["check-code"])
        XCTAssertEqual(userRows[0].itemId, "raw-user-item")
    }

    func testMirroredRawSkillUserMessageReusesRichLocalBubble() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.messagesByThread[threadID] = [
            CodexMessage(
                id: "user-rich",
                threadId: threadID,
                role: .user,
                text: "one last time",
                skillMentions: ["check-code"],
                turnId: turnID,
                isStreaming: false,
                deliveryState: .pending
            ),
        ]

        service.handleNotification(
            method: "codex/event/user_message",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "message": .string("$check-code one last time"),
                "timestamp": .string("2026-05-24T21:52:51.133Z"),
            ])
        )

        let userRows = service.messages(for: threadID).filter { $0.role == .user }

        XCTAssertEqual(userRows.count, 1)
        XCTAssertEqual(userRows[0].id, "user-rich")
        XCTAssertEqual(userRows[0].deliveryState, .confirmed)
        XCTAssertEqual(userRows[0].text, "one last time")
        XCTAssertEqual(userRows[0].skillMentions, ["check-code"])
    }

    func testMirroredOpeningUserMessageAnchorsBeforeExistingTurnOutput() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.appendMessage(
            CodexMessage(
                id: "assistant-first",
                threadId: threadID,
                role: .assistant,
                text: "Already streaming from desktop",
                turnId: turnID,
                itemId: "assistant-item",
                isStreaming: true,
                orderIndex: 10
            )
        )

        service.appendConfirmedMirroredUserMessage(
            threadId: threadID,
            turnId: turnID,
            text: "let's hope now it will"
        )

        let messages = service.messages(for: threadID)

        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertLessThan(messages[0].orderIndex, messages[1].orderIndex)
        XCTAssertEqual(messages[0].text, "let's hope now it will")
    }

    func testThreadReadDecodesTurnIdAliasAndRejectsEpochHistoryTimestamp() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        let messages = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "id": .string(threadID),
                "turns": .array([
                    .object([
                        "turnId": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("user-history"),
                                "type": .string("user_message"),
                                "message": .string("/check-code one last time"),
                                "timestamp": .integer(0),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].turnId, turnID)
        XCTAssertTrue(CodexTimestampParser.isTrustworthyServerDate(messages[0].createdAt))
    }

    func testThreadReadDecodesStructuredAtMentionOnlyUserMessage() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        let messages = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "id": .string(threadID),
                "createdAt": .string("2026-05-24T21:52:51.000Z"),
                "turns": .array([
                    .object([
                        "turnId": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("user-history"),
                                "type": .string("message"),
                                "role": .string("user"),
                                "content": .array([
                                    .object([
                                        "type": .string("mention"),
                                        "name": .string("linear"),
                                        "path": .string("mcp://linear"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "@linear")
        XCTAssertEqual(messages[0].pluginMentions, ["linear"])
    }

    func testThreadReadDecodesStructuredAtMentionMetadataWithText() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        let messages = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "id": .string(threadID),
                "createdAt": .string("2026-05-24T21:52:51.000Z"),
                "turns": .array([
                    .object([
                        "id": .string("turn-history"),
                        "items": .array([
                            .object([
                                "id": .string("user-history"),
                                "type": .string("message"),
                                "role": .string("user"),
                                "content": .array([
                                    .object([
                                        "type": .string("input_text"),
                                        "text": .string("summarize this"),
                                    ]),
                                    .object([
                                        "type": .string("mention"),
                                        "name": .string("linear"),
                                        "path": .string("mcp://linear"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "summarize this\n@linear")
        XCTAssertEqual(messages[0].pluginMentions, ["linear"])
    }

    func testLateTerminalInteractionDoesNotRegressCompletedCommandRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let callID = "call-\(UUID().uuidString)"

        service.handleNotification(
            method: "item/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(callID),
                    "type": .string("commandExecution"),
                    "status": .string("inProgress"),
                    "command": .string("/bin/zsh -lc \"echo one\""),
                ]),
            ])
        )
        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(callID),
                    "type": .string("commandExecution"),
                    "status": .string("completed"),
                    "command": .string("/bin/zsh -lc \"echo one\""),
                ]),
            ])
        )
        service.handleNotification(
            method: "item/commandExecution/terminalInteraction",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(callID),
                "command": .string("/bin/zsh -lc \"echo one\""),
            ])
        )

        let runRow = service.messages(for: threadID).first(where: {
            $0.role == .system && $0.kind == .commandExecution && $0.itemId == callID
        })
        XCTAssertNotNil(runRow)
        XCTAssertTrue(runRow?.text.lowercased().hasPrefix("completed ") ?? false)
        XCTAssertFalse(runRow?.isStreaming ?? true)
    }

    func testReasoningDeltasPreserveWhitespaceAndCompletionReplacesSnapshot() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "reasoning-\(UUID().uuidString)"

        service.handleNotification(
            method: "item/reasoning/textDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "delta": .string("**Providing"),
            ])
        )
        service.handleNotification(
            method: "item/reasoning/textDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "delta": .string(" exact 200-word paragraph**"),
            ])
        )
        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("reasoning"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("**Providing exact 200-word paragraph**"),
                        ]),
                    ]),
                ]),
            ])
        )

        let thinkingRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .thinking
        }
        XCTAssertEqual(thinkingRows.count, 1)
        XCTAssertEqual(thinkingRows[0].text, "**Providing exact 200-word paragraph**")
    }

    func testReasoningSummaryPartBoundariesStayPlainDuringStreaming() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "reasoning-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        service.handleNotification(
            method: "item/reasoning/summaryPartAdded",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "summaryIndex": .integer(0),
            ])
        )
        service.handleNotification(
            method: "item/reasoning/summaryTextDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "summaryIndex": .integer(0),
                "delta": .string("**Testing notify command behavior**\n\n<!-- -->"),
            ])
        )
        service.handleNotification(
            method: "item/reasoning/summaryPartAdded",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "summary_index": .integer(1),
                "delta": .string("**Analyzing notify hook JSON output format**\n\n<!-- -->"),
            ])
        )
        service.flushPendingSystemDeltas(threadId: threadID, itemId: itemID)

        let thinkingRow = service.messages(for: threadID).first(where: {
            $0.role == .system && $0.kind == .thinking && $0.itemId == itemID
        })
        let text = try? XCTUnwrap(thinkingRow?.text)
        XCTAssertEqual(
            text,
            "**Testing notify command behavior**\n\n<!-- -->\n\n**Analyzing notify hook JSON output format**\n\n<!-- -->"
        )
        XCTAssertTrue(text.map { ThinkingDisclosureParser.parse(from: $0).isSummaryOnly } ?? false)
    }

    func testSummaryOnlyReasoningSurvivesTurnCompletion() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "reasoning-\(UUID().uuidString)"
        let rawText = "**Planning targeted test execution**\n\n<!-- -->"

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: itemID,
            kind: .thinking,
            text: rawText,
            isStreaming: true
        )
        service.recordTurnTerminalState(
            threadId: threadID,
            turnId: turnID,
            state: .completed
        )
        service.markTurnCompleted(threadId: threadID, turnId: turnID)

        let thinkingRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .thinking
        }
        XCTAssertEqual(thinkingRows.count, 1)
        XCTAssertEqual(thinkingRows[0].text, rawText)
        XCTAssertFalse(thinkingRows[0].isStreaming)
    }

    func testLateReasoningDeltaAfterTurnCompletionDoesNotCreateNewThinkingRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "reasoning-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )

        service.handleNotification(
            method: "item/reasoning/textDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "delta": .string("Late reasoning chunk"),
            ])
        )

        let thinkingRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .thinking
        }
        XCTAssertTrue(thinkingRows.isEmpty)
    }

    func testLateReasoningDeltaAfterTurnCompletionUpdatesExistingThinkingWithoutStreaming() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "reasoning-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        service.handleNotification(
            method: "item/reasoning/textDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "delta": .string("First"),
            ])
        )
        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        service.handleNotification(
            method: "item/reasoning/textDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "delta": .string(" second"),
            ])
        )

        let thinkingRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .thinking
        }
        XCTAssertEqual(thinkingRows.count, 1)
        XCTAssertEqual(thinkingRows[0].text, "First second")
        XCTAssertFalse(thinkingRows[0].isStreaming)
    }

    // The IPC follower streams reasoning under real per-item ids while the
    // rollout mirror aggregates the same turn under one synthetic
    // "rollout-thinking:" id. Alternating sources mid-turn must rebind to the
    // existing row instead of stacking a second "Thinking..." row.
    func testRolloutMirrorReasoningRebindsToIpcThinkingRowInsteadOfDuplicating() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let realItemID = "reasoning-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
        service.handleNotification(
            method: "item/reasoning/textDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(realItemID),
                "delta": .string("Weighing options"),
            ])
        )
        service.handleNotification(
            method: "item/reasoning/textDelta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string("rollout-thinking:\(threadID):\(turnID)"),
                "delta": .string(" and deciding"),
                "remodexDesktopMirror": .bool(true),
                "remodexRolloutLiveMirror": .bool(true),
            ])
        )

        let thinkingRows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .thinking
        }
        XCTAssertEqual(thinkingRows.count, 1)
        XCTAssertEqual(thinkingRows[0].itemId, realItemID)
    }

    // A previous turn's post-completion file-change table has no turnId; the
    // next turn repeating the same working-tree paths must not re-anchor it
    // into its own block (the table visually "moved" into the new turn).
    func testHistoryFileChangeDoesNotStealPreviousTurnsTurnlessTable() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let newTurnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)

        let existing = [
            CodexMessage(
                id: "old-table",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: "package.json +1 -1",
                createdAt: now,
                turnId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "user-new-turn",
                threadId: threadID,
                role: .user,
                text: "nice",
                createdAt: now.addingTimeInterval(10),
                turnId: newTurnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "new-turn-snapshot",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: "package.json +1 -1",
                createdAt: now.addingTimeInterval(12),
                turnId: newTurnID,
                itemId: "fc-new",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let fileChangeRows = merged.filter { $0.kind == .fileChange }

        XCTAssertEqual(fileChangeRows.count, 2)
        XCTAssertNil(merged.first(where: { $0.id == "old-table" })?.turnId)
    }

    // The ownership window is bounded by the next turn as well as the previous
    // one; otherwise late history for an older turn can steal a newer table.
    func testHistoryFileChangeDoesNotStealNextTurnsTurnlessTable() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let oldTurnID = "turn-\(UUID().uuidString)"
        let newTurnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)

        let existing = [
            CodexMessage(
                id: "user-old-turn",
                threadId: threadID,
                role: .user,
                text: "first change",
                createdAt: now,
                turnId: oldTurnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "user-new-turn",
                threadId: threadID,
                role: .user,
                text: "second change",
                createdAt: now.addingTimeInterval(10),
                turnId: newTurnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "new-turn-table",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: "package.json +1 -1",
                createdAt: now.addingTimeInterval(12),
                turnId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "old-turn-snapshot",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: "package.json +1 -1",
                createdAt: now.addingTimeInterval(2),
                turnId: oldTurnID,
                itemId: "fc-old",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let fileChangeRows = merged.filter { $0.kind == .fileChange }

        XCTAssertEqual(fileChangeRows.count, 2)
        XCTAssertNil(merged.first(where: { $0.id == "new-turn-table" })?.turnId)
        XCTAssertNotNil(merged.first(where: { $0.id == "old-turn-snapshot" }))
    }

    // The same turn's own post-completion snapshot (turnless, positioned after
    // the turn's rows) must keep reconciling instead of appending a duplicate.
    func testHistoryFileChangeStillBindsSameTurnTurnlessSnapshot() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)

        let existing = [
            CodexMessage(
                id: "user-turn",
                threadId: threadID,
                role: .user,
                text: "bump the version",
                createdAt: now,
                turnId: turnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "turnless-snapshot",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: "package.json +1 -1",
                createdAt: now.addingTimeInterval(5),
                turnId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "turn-snapshot",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: "package.json +1 -1",
                createdAt: now.addingTimeInterval(6),
                turnId: turnID,
                itemId: "fc-turn",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let fileChangeRows = merged.filter { $0.kind == .fileChange }

        XCTAssertEqual(fileChangeRows.count, 1)
        XCTAssertEqual(fileChangeRows[0].id, "turnless-snapshot")
        XCTAssertEqual(fileChangeRows[0].turnId, turnID)
    }

    // A pending user prompt (no turnId yet) closes the previous turn's block:
    // that turn's history reconcile must bind its anchored row and leave the
    // next turn's turnless table alone instead of re-anchoring it backwards.
    func testHistoryFileChangeBlockStopsAtPendingUserBoundary() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_779_654_720)
        let fileChangeText = """
        Path: Sources/App.swift
        Kind: update
        Totals: +2 -1
        """

        let existing = [
            CodexMessage(
                id: "user-t1",
                threadId: threadID,
                role: .user,
                text: "first prompt",
                createdAt: now,
                turnId: turnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "fc-t1",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: fileChangeText,
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: "fc-live",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "user-pending",
                threadId: threadID,
                role: .user,
                text: "next prompt",
                createdAt: now.addingTimeInterval(10),
                turnId: nil,
                isStreaming: false,
                deliveryState: .pending
            ),
            CodexMessage(
                id: "fc-next-turnless",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: fileChangeText,
                createdAt: now.addingTimeInterval(12),
                turnId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "fc-t1-history",
                threadId: threadID,
                role: .system,
                kind: .fileChange,
                text: fileChangeText,
                createdAt: now.addingTimeInterval(2),
                turnId: turnID,
                itemId: "fc-history-item",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let fileChangeRows = merged.filter { $0.kind == .fileChange }

        XCTAssertEqual(fileChangeRows.count, 2)
        XCTAssertNil(merged.first(where: { $0.id == "fc-next-turnless" })?.turnId)
    }

    func testHistoryMergeReconcilesThinkingByTurnWhenTextDiffers() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .thinking,
                text: "**Providingexact200-wordparagraph**",
                createdAt: now,
                turnId: turnID,
                itemId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .thinking,
                text: "**Providing exact 200-word paragraph**",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "**Providing exact 200-word paragraph**")
    }

    func testReasoningDeltaWithoutIDsIsIgnoredWhenMultipleThreadsExist() {
        let service = makeService()
        let firstThreadID = "thread-\(UUID().uuidString)"
        let secondThreadID = "thread-\(UUID().uuidString)"
        service.threads = [
            CodexThread(id: firstThreadID, title: "First"),
            CodexThread(id: secondThreadID, title: "Second"),
        ]
        service.activeThreadId = firstThreadID

        service.handleNotification(
            method: "item/reasoning/textDelta",
            params: .object([
                "delta": .string("Should not route"),
            ])
        )

        XCTAssertTrue(service.messages(for: firstThreadID).isEmpty)
        XCTAssertTrue(service.messages(for: secondThreadID).isEmpty)
    }

    func testHistoryMergeDedupesQuotedCommandExecutionPreviews() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .commandExecution,
                text: "completed /bin/zsh -lc rg --files",
                createdAt: now,
                turnId: turnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .system,
                kind: .commandExecution,
                text: "completed /bin/zsh -lc \"rg --files\"",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let commandRows = merged.filter { $0.role == .system && $0.kind == .commandExecution }

        XCTAssertEqual(commandRows.count, 1)
        XCTAssertEqual(commandRows[0].turnId, turnID)
    }

    func testHistoryMergeReconcilesClosedSingleAssistantTurnWhenCanonicalSnapshotDiffers() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Testo parziale",
                createdAt: now,
                turnId: turnID,
                itemId: "local-message",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Testo finale",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: "server-message",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let assistantRows = merged.filter { $0.role == .assistant }

        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(assistantRows[0].turnId, turnID)
        XCTAssertEqual(assistantRows[0].itemId, "server-message")
        XCTAssertEqual(assistantRows[0].text, "Testo finale")
    }

    func testHistoryMergeDoesNotCollapseSingleAssistantTurnWhileStillRunning() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        service.runningThreadIDs.insert(threadID)

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Testo parziale",
                createdAt: now,
                turnId: turnID,
                itemId: "local-message",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Testo finale",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: "server-message",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let assistantRows = merged.filter { $0.role == .assistant }

        XCTAssertEqual(assistantRows.count, 2)
        XCTAssertEqual(assistantRows.map(\.itemId), ["local-message", "server-message"])
    }

    func testHistoryMergeSkipsFlattenedAssistantBlockReplay() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()
        let introText = "I'll check Gmail for the latest TestFlight message."
        let finalText = "Latest TestFlight version: 1.4 (123)."

        let existing = [
            CodexMessage(
                id: "assistant-intro",
                threadId: threadID,
                role: .assistant,
                text: introText,
                createdAt: now,
                turnId: turnID,
                itemId: "item-intro",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "tool-row",
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read 6807e4de/...",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: "tool-1",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "assistant-final",
                threadId: threadID,
                role: .assistant,
                text: finalText,
                createdAt: now.addingTimeInterval(2),
                turnId: nil,
                itemId: "item-final",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "assistant-replay",
                threadId: threadID,
                role: .assistant,
                text: "\(introText)\n\n\(finalText)",
                createdAt: now.addingTimeInterval(3),
                turnId: turnID,
                itemId: "item-replay",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let assistantRows = merged.filter { $0.role == .assistant }

        XCTAssertEqual(assistantRows.map(\.id), ["assistant-intro", "assistant-final"])
        XCTAssertEqual(assistantRows.map(\.text), [introText, finalText])
    }

    func testHistoryMergeSkipsLongExactTerminalReplayAfterTurnlessFinal() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()
        let finalText = """
        Latest TestFlight inbox email says:

        Remodex version 1.4, build 124

        Subject: "Remodex - Remote AI Coding 1.4 (124) for iOS is now available to test."
        """

        let existing = [
            CodexMessage(
                id: "assistant-final",
                threadId: threadID,
                role: .assistant,
                text: finalText,
                createdAt: now,
                turnId: nil,
                itemId: "item-final",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "assistant-status",
                threadId: threadID,
                role: .assistant,
                text: "I'll use the Gmail connector to search recent inbox mentions.",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: "item-status",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                id: "assistant-terminal-replay",
                threadId: threadID,
                role: .assistant,
                text: finalText,
                createdAt: now.addingTimeInterval(2),
                turnId: turnID,
                itemId: "item-terminal",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let assistantRows = merged.filter { $0.role == .assistant }

        XCTAssertEqual(assistantRows.map(\.id), ["assistant-final", "assistant-status"])
        XCTAssertEqual(assistantRows.map(\.text), [
            finalText,
            "I'll use the Gmail connector to search recent inbox mentions.",
        ])
    }

    func testInitialHistorySkipsFlattenedAssistantBlockReplay() throws {
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()
        let introText = "I'll check Gmail for the latest TestFlight message."
        let finalText = "Latest TestFlight version: 1.4 (123)."
        let history = [
            CodexMessage(
                id: "assistant-intro",
                threadId: threadID,
                role: .assistant,
                text: introText,
                createdAt: now,
                turnId: turnID,
                itemId: "item-intro",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "tool-row",
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Read 6807e4de/...",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: "tool-1",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "assistant-final",
                threadId: threadID,
                role: .assistant,
                text: finalText,
                createdAt: now.addingTimeInterval(2),
                turnId: nil,
                itemId: "item-final",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                id: "assistant-replay",
                threadId: threadID,
                role: .assistant,
                text: "\(introText)\n\n\(finalText)",
                createdAt: now.addingTimeInterval(3),
                turnId: turnID,
                itemId: "item-replay",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = try CodexService.mergeHistoryMessages(
            [],
            history,
            activeThreadIDs: [],
            runningThreadIDs: []
        )
        let assistantRows = merged.filter { $0.role == .assistant }

        XCTAssertEqual(assistantRows.map(\.id), ["assistant-intro", "assistant-final"])
        XCTAssertEqual(assistantRows.map(\.text), [introText, finalText])
    }

    func testHistoryMergeDoesNotRegressClosedSingleAssistantTurnToShorterSnapshot() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Testo finale completo",
                createdAt: now,
                turnId: turnID,
                itemId: "local-message",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Testo finale",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: "server-message",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let assistantRows = merged.filter { $0.role == .assistant }

        XCTAssertEqual(assistantRows.count, 1)
        XCTAssertEqual(assistantRows[0].text, "Testo finale completo")
        XCTAssertEqual(assistantRows[0].itemId, "local-message")
    }

    func testHistoryMergeKeepsDistinctAssistantItemsInSameTurnWhenHistoryIDsArriveLater() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Prima risposta",
                createdAt: now,
                turnId: turnID,
                itemId: nil,
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Seconda risposta",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: "message-2",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Terza risposta",
                createdAt: now.addingTimeInterval(2),
                turnId: turnID,
                itemId: "message-3",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let assistantRows = merged.filter { $0.role == .assistant }

        XCTAssertEqual(assistantRows.count, 3)
        XCTAssertEqual(assistantRows.map(\.text), ["Prima risposta", "Seconda risposta", "Terza risposta"])
        XCTAssertEqual(assistantRows.map(\.itemId), [nil, "message-2", "message-3"])
    }

    func testHistoryMergeDoesNotCollapseRepeatedAssistantTextAcrossDistinctItemsInSameTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date()

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Ok",
                createdAt: now,
                turnId: turnID,
                itemId: "message-1",
                isStreaming: false,
                deliveryState: .confirmed
            ),
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Ok",
                createdAt: now.addingTimeInterval(1),
                turnId: turnID,
                itemId: "message-2",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "Ok",
                createdAt: now.addingTimeInterval(2),
                turnId: turnID,
                itemId: "message-3",
                isStreaming: false,
                deliveryState: .confirmed
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let assistantRows = merged.filter { $0.role == .assistant }

        XCTAssertEqual(assistantRows.count, 3)
        XCTAssertEqual(assistantRows.map(\.itemId), ["message-1", "message-2", "message-3"])
    }

    func testThreadReadRestoresNestedReviewModeMessages() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let history = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .string("2026-03-12T10:00:00Z"),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("review-enter"),
                                "type": .string("enteredReviewMode"),
                                "review": .object([
                                    "summary": .string("base branch"),
                                ]),
                            ]),
                            .object([
                                "id": .string("review-exit"),
                                "type": .string("exitedReviewMode"),
                                "review": .object([
                                    "content": .array([
                                        .string("Line one"),
                                        .string("Line two"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].text, "Reviewing base branch...")
        XCTAssertEqual(history[0].kind, .commandExecution)
        XCTAssertEqual(history[1].text, "Line one\nLine two")
        XCTAssertEqual(history[1].kind, .chat)
    }

    func testContextCompactionLifecycleTracksProgressAndCompletesSingleRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "compact-\(UUID().uuidString)"

        service.handleNotification(
            method: "item/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("contextCompaction"),
                ]),
            ])
        )

        let startedRow = service.messages(for: threadID).first(where: {
            $0.role == .system && $0.kind == .commandExecution && $0.itemId == itemID
        })
        XCTAssertEqual(startedRow?.text, "Compacting context…")
        XCTAssertEqual(startedRow?.isStreaming, true)

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("contextCompaction"),
                ]),
            ])
        )

        let rows = service.messages(for: threadID).filter {
            $0.role == .system && $0.kind == .commandExecution && $0.itemId == itemID
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].text, "Context compacted")
        XCTAssertFalse(rows[0].isStreaming)
    }

    func testThreadReadRestoresContextCompactionAsCompletedCommandRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let history = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .string("2026-03-12T10:00:00Z"),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("compact-item"),
                                "type": .string("contextCompaction"),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].kind, .commandExecution)
        XCTAssertEqual(history[0].text, "Context compacted")
        XCTAssertEqual(history[0].turnId, turnID)
    }

    func testLegacyNamedImageGenerationEndAppendsGeneratedImagePreview() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "image-\(UUID().uuidString)"
        let imagePath = "/Users/example/generated image.png"

        service.handleNotification(
            method: "codex/event/image_generation_end",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("image_generation_end"),
                    "call_id": .string(itemID),
                    "turn_id": .string(turnID),
                    "saved_path": .string(imagePath),
                ]),
            ])
        )

        let imageRows = service.messages(for: threadID).filter {
            $0.role == .assistant && $0.itemId == itemID
        }
        XCTAssertEqual(imageRows.count, 1)
        XCTAssertEqual(imageRows[0].turnId, turnID)
        XCTAssertEqual(imageRows[0].text, "![Generated image](</Users/example/generated image.png>)")
    }

    func testCompletedImageGenerationItemAppendsGeneratedImagePreview() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "image-\(UUID().uuidString)"
        let imagePath = "/Users/example/generated image.png"

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("image_generation_call"),
                    "saved_path": .string(imagePath),
                ]),
            ])
        )

        let imageRows = service.messages(for: threadID).filter {
            $0.role == .assistant && $0.itemId == itemID
        }
        XCTAssertEqual(imageRows.count, 1)
        XCTAssertEqual(imageRows[0].turnId, turnID)
        XCTAssertEqual(imageRows[0].text, "![Generated image](</Users/example/generated image.png>)")
    }

    func testLateGeneratedImageMergesIntoAssistantAnswerForSameTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "image-\(UUID().uuidString)"
        let imagePath = "/Users/example/generated image.png"

        service.appendMessage(
            CodexMessage(
                id: "assistant-final",
                threadId: threadID,
                role: .assistant,
                text: "Done: generated the image.",
                turnId: turnID,
                isStreaming: false
            )
        )

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("image_generation_call"),
                    "saved_path": .string(imagePath),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages[0].id, "assistant-final")
        XCTAssertEqual(
            assistantMessages[0].text,
            "Done: generated the image.\n\n![Generated image](</Users/example/generated image.png>)"
        )
        XCTAssertNil(assistantMessages[0].itemId)
    }

    func testLateGeneratedImageDoesNotFinishStreamingAssistantAnswer() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "image-\(UUID().uuidString)"
        let imagePath = "/Users/example/generated image.png"

        service.appendMessage(
            CodexMessage(
                id: "assistant-streaming",
                threadId: threadID,
                role: .assistant,
                text: "Generating",
                turnId: turnID,
                isStreaming: true
            )
        )

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("image_generation_call"),
                    "saved_path": .string(imagePath),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages[0].id, "assistant-streaming")
        XCTAssertTrue(assistantMessages[0].isStreaming)
        XCTAssertEqual(assistantMessages[0].text, "Generating")
        XCTAssertEqual(assistantMessages[1].itemId, itemID)
        XCTAssertEqual(assistantMessages[1].text, "![Generated image](</Users/example/generated image.png>)")
    }

    func testLateGeneratedImageDoesNotReplaceAssistantAnswerItemIdentity() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let answerItemID = "answer-\(UUID().uuidString)"
        let imageItemID = "image-\(UUID().uuidString)"
        let imagePath = "/Users/example/generated image.png"

        service.appendMessage(
            CodexMessage(
                id: "assistant-final",
                threadId: threadID,
                role: .assistant,
                text: "Done: generated the image.",
                turnId: turnID,
                itemId: answerItemID,
                isStreaming: false
            )
        )

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(imageItemID),
                    "type": .string("image_generation_call"),
                    "saved_path": .string(imagePath),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages[0].id, "assistant-final")
        XCTAssertEqual(assistantMessages[0].itemId, answerItemID)
        XCTAssertEqual(
            assistantMessages[0].text,
            "Done: generated the image.\n\n![Generated image](</Users/example/generated image.png>)"
        )
    }

    func testDuplicateLateGeneratedImageDoesNotAdoptImageItemIdentity() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let imageItemID = "image-\(UUID().uuidString)"
        let imagePath = "/Users/example/generated image.png"

        service.appendMessage(
            CodexMessage(
                id: "assistant-final",
                threadId: threadID,
                role: .assistant,
                text: "Done: generated the image.",
                turnId: turnID,
                isStreaming: false
            )
        )

        let params: JSONValue = .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
            "item": .object([
                "id": .string(imageItemID),
                "type": .string("image_generation_call"),
                "saved_path": .string(imagePath),
            ]),
        ])

        service.handleNotification(method: "item/completed", params: params)
        service.handleNotification(method: "item/completed", params: params)

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages[0].id, "assistant-final")
        XCTAssertNil(assistantMessages[0].itemId)
        XCTAssertEqual(
            assistantMessages[0].text,
            "Done: generated the image.\n\n![Generated image](</Users/example/generated image.png>)"
        )
    }

    func testCompletedImageViewItemAppendsGeneratedImagePreview() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "image-\(UUID().uuidString)"
        let imagePath = "/Users/example/generated image.png"

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("imageView"),
                    "path": .string(imagePath),
                ]),
            ])
        )

        let imageRows = service.messages(for: threadID).filter {
            $0.role == .assistant && $0.itemId == itemID
        }
        XCTAssertEqual(imageRows.count, 1)
        XCTAssertEqual(imageRows[0].turnId, turnID)
        XCTAssertEqual(imageRows[0].text, "![Generated image](</Users/example/generated image.png>)")
    }

    func testDirectCompletedImageViewItemAppendsGeneratedImagePreview() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "image-\(UUID().uuidString)"
        let imagePath = "/Users/example/generated image.png"

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "id": .string(itemID),
                "type": .string("imageView"),
                "path": .string(imagePath),
            ])
        )

        let imageRows = service.messages(for: threadID).filter {
            $0.role == .assistant && $0.itemId == itemID
        }
        XCTAssertEqual(imageRows.count, 1)
        XCTAssertEqual(imageRows[0].turnId, turnID)
        XCTAssertEqual(imageRows[0].text, "![Generated image](</Users/example/generated image.png>)")
    }

    func testCompletedImageGenerationItemTypeAppendsGeneratedImagePreview() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "image-\(UUID().uuidString)"
        let imagePath = "/Users/example/generated image.png"

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("image_generation"),
                    "path": .string(imagePath),
                    "result": .string("iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"),
                ]),
            ])
        )

        let imageRows = service.messages(for: threadID).filter {
            $0.role == .assistant && $0.itemId == itemID
        }
        XCTAssertEqual(imageRows.count, 1)
        XCTAssertEqual(imageRows[0].turnId, turnID)
        XCTAssertEqual(imageRows[0].text, "![Generated image](</Users/example/generated image.png>)")
    }

    func testClosedHistoryMergePlacesMissingOlderTurnRowsAtCanonicalPosition() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        func message(
            id: String,
            role: CodexMessageRole,
            kind: CodexMessageKind = .chat,
            text: String,
            turnID: String,
            itemID: String,
            order: Int
        ) -> CodexMessage {
            var value = CodexMessage(
                id: id,
                threadId: threadID,
                role: role,
                kind: kind,
                text: text,
                createdAt: now,
                turnId: turnID,
                itemId: itemID,
                isStreaming: false,
                deliveryState: .confirmed
            )
            value.orderIndex = order
            return value
        }

        let existing = [
            message(id: "user-1", role: .user, text: "one", turnID: "turn-1", itemID: "user-item-1", order: 1),
            message(id: "assistant-1", role: .assistant, text: "answer one", turnID: "turn-1", itemID: "assistant-item-1", order: 2),
            message(id: "user-2", role: .user, text: "two", turnID: "turn-2", itemID: "user-item-2", order: 3),
            message(id: "assistant-2", role: .assistant, text: "answer two", turnID: "turn-2", itemID: "assistant-item-2", order: 4),
        ]
        let history = [
            message(id: "history-user-1", role: .user, text: "one", turnID: "turn-1", itemID: "user-item-1", order: 101),
            message(id: "reasoning-1", role: .system, kind: .thinking, text: "reasoning one", turnID: "turn-1", itemID: "reasoning-item-1", order: 102),
            message(id: "history-assistant-1", role: .assistant, text: "answer one", turnID: "turn-1", itemID: "assistant-item-1", order: 103),
            message(id: "history-user-2", role: .user, text: "two", turnID: "turn-2", itemID: "user-item-2", order: 104),
            message(id: "history-assistant-2", role: .assistant, text: "answer two", turnID: "turn-2", itemID: "assistant-item-2", order: 105),
        ]

        let merged = service.mergeHistoryMessages(existing, history)

        XCTAssertEqual(merged.map(\.id), [
            "user-1",
            "reasoning-1",
            "assistant-1",
            "user-2",
            "assistant-2",
        ])
    }

    func testColdHistoryMergePreservesPayloadOrderWhenTimestampsDisagree() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let history = [
            CodexMessage(id: "user", threadId: threadID, role: .user, text: "fix it", createdAt: now, turnId: turnID, itemId: "user"),
            CodexMessage(id: "command", threadId: threadID, role: .system, kind: .commandExecution, text: "git status", createdAt: now.addingTimeInterval(60), turnId: turnID, itemId: "command"),
            CodexMessage(id: "final", threadId: threadID, role: .assistant, text: "done", createdAt: now.addingTimeInterval(0.002), turnId: turnID, itemId: "final"),
        ]

        let merged = service.mergeHistoryMessages([], history)

        XCTAssertEqual(merged.map(\.id), ["user", "command", "final"])
    }

    func testHistoryMergeRepairsAssistantSourceIdentityRotationAcrossToolRows() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let text = "The provider-isolation branch is committed and all focused verification passes."
        let sourceKey = try! XCTUnwrap(
            CodexService.remodexAssistantSourceItemKey(turnId: turnID, text: text)
        )

        var localAssistant = CodexMessage(
            id: "local-assistant",
            threadId: threadID,
            role: .assistant,
            text: text,
            turnId: turnID,
            itemId: "desktop-provider-item",
            sourceItemKey: sourceKey
        )
        var tool = CodexMessage(
            id: "tool",
            threadId: threadID,
            role: .system,
            kind: .commandExecution,
            text: "git show --stat",
            turnId: turnID,
            itemId: "tool-item"
        )
        localAssistant.orderIndex = 1
        tool.orderIndex = 2

        for canonicalSourceKey in [nil, sourceKey] as [String?] {
            var duplicateCanonicalAssistant = CodexMessage(
                id: "duplicate-canonical-assistant",
                threadId: threadID,
                role: .assistant,
                text: text,
                turnId: turnID,
                itemId: "canonical-provider-item",
                sourceItemKey: canonicalSourceKey
            )
            duplicateCanonicalAssistant.orderIndex = 3
            let history = [
                CodexMessage(
                    id: "history-assistant",
                    threadId: threadID,
                    role: .assistant,
                    text: text,
                    turnId: turnID,
                    itemId: "canonical-provider-item",
                    sourceItemKey: canonicalSourceKey
                ),
                CodexMessage(
                    id: "history-tool",
                    threadId: threadID,
                    role: .system,
                    kind: .commandExecution,
                    text: "git show --stat",
                    turnId: turnID,
                    itemId: "tool-item"
                ),
            ]

            for includesPersistedCanonicalDuplicate in [false, true] {
                let existing = includesPersistedCanonicalDuplicate
                    ? [localAssistant, tool, duplicateCanonicalAssistant]
                    : [localAssistant, tool]
                let merged = service.mergeHistoryMessages(existing, history)
                let assistantRows = merged.filter { $0.role == .assistant }

                XCTAssertEqual(assistantRows.count, 1)
                XCTAssertEqual(assistantRows.first?.id, "local-assistant")
                XCTAssertEqual(assistantRows.first?.itemId, "canonical-provider-item")
                XCTAssertEqual(assistantRows.first?.sourceItemKey, sourceKey)
                XCTAssertEqual(merged.map(\.id), ["local-assistant", "tool"])
            }
        }
    }

    func testRemodexAssistantSourceItemKeyMatchesBridgeFormat() {
        XCTAssertEqual(
            CodexService.remodexAssistantSourceItemKey(
                turnId: "turn-test",
                text: "  hello\n"
            ),
            "turn-test:2cf24dba5fb0a30e"
        )
    }

    func testHistoryMergePreservesRepeatedAssistantTextWhenBothProviderItemsAreCanonical() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let text = "This deliberately repeated assistant update must remain visible twice."
        let sourceKey = try! XCTUnwrap(
            CodexService.remodexAssistantSourceItemKey(turnId: turnID, text: text)
        )
        for firstSourceKey in [nil, sourceKey] as [String?] {
            let existing = [
                CodexMessage(
                    id: "local-first",
                    threadId: threadID,
                    role: .assistant,
                    text: text,
                    turnId: turnID,
                    itemId: "provider-a",
                    sourceItemKey: firstSourceKey
                ),
            ]
            let history = [
                CodexMessage(
                    id: "history-first",
                    threadId: threadID,
                    role: .assistant,
                    text: text,
                    turnId: turnID,
                    itemId: "provider-a",
                    sourceItemKey: firstSourceKey
                ),
                CodexMessage(
                    id: "history-tool",
                    threadId: threadID,
                    role: .system,
                    kind: .toolActivity,
                    text: "Reviewed provider isolation",
                    turnId: turnID,
                    itemId: "tool-between"
                ),
                CodexMessage(
                    id: "history-second",
                    threadId: threadID,
                    role: .assistant,
                    text: text,
                    turnId: turnID,
                    itemId: "provider-b"
                ),
            ]

            let merged = service.mergeHistoryMessages(existing, history)
            let assistantRows = merged.filter { $0.role == .assistant }

            XCTAssertEqual(assistantRows.map(\.itemId), ["provider-a", "provider-b"])
            XCTAssertEqual(merged.map(\.id), ["local-first", "history-tool", "history-second"])
        }
    }

    func testHistoryMergePreservesAliaslessRepeatedAssistantOutsidePartialCanonicalPage() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let text = "This intentional update has the same text as a later canonical item."
        var first = CodexMessage(
            id: "local-first",
            threadId: threadID,
            role: .assistant,
            text: text,
            turnId: turnID,
            itemId: "provider-a"
        )
        var tool = CodexMessage(
            id: "tool-between",
            threadId: threadID,
            role: .system,
            kind: .toolActivity,
            text: "Checked the implementation",
            turnId: turnID,
            itemId: "tool-between"
        )
        var second = CodexMessage(
            id: "local-second",
            threadId: threadID,
            role: .assistant,
            text: text,
            turnId: turnID,
            itemId: "provider-b"
        )
        first.orderIndex = 1
        tool.orderIndex = 2
        second.orderIndex = 3
        let partialHistory = [
            CodexMessage(
                id: "history-second",
                threadId: threadID,
                role: .assistant,
                text: text,
                turnId: turnID,
                itemId: "provider-b"
            ),
        ]

        let merged = service.mergeHistoryMessages([first, tool, second], partialHistory)

        XCTAssertEqual(
            merged.filter { $0.role == .assistant }.map(\.itemId),
            ["provider-a", "provider-b"]
        )
    }

    func testActiveHistoryMergePreservesNewerSameTextProviderItemNotYetCanonical() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let text = "This intentional live update repeats an earlier canonical status exactly."
        let sourceKey = try! XCTUnwrap(
            CodexService.remodexAssistantSourceItemKey(turnId: turnID, text: text)
        )
        service.setActiveTurnID(turnID, for: threadID)
        service.runningThreadIDs.insert(threadID)

        var tool = CodexMessage(
            id: "tool-between",
            threadId: threadID,
            role: .system,
            kind: .toolActivity,
            text: "Reviewed provider isolation",
            turnId: turnID,
            itemId: "tool-between"
        )
        var newerLiveAssistant = CodexMessage(
            id: "newer-live-assistant",
            threadId: threadID,
            role: .assistant,
            text: text,
            turnId: turnID,
            itemId: "provider-b",
            isStreaming: false
        )
        tool.orderIndex = 2
        newerLiveAssistant.orderIndex = 3
        for canonicalSourceKey in [nil, sourceKey] as [String?] {
            var canonicalAssistant = CodexMessage(
                id: "canonical-existing",
                threadId: threadID,
                role: .assistant,
                text: text,
                turnId: turnID,
                itemId: "provider-a",
                sourceItemKey: canonicalSourceKey
            )
            canonicalAssistant.orderIndex = 1
            let history = [
                CodexMessage(
                    id: "history-canonical",
                    threadId: threadID,
                    role: .assistant,
                    text: text,
                    turnId: turnID,
                    itemId: "provider-a",
                    sourceItemKey: canonicalSourceKey
                ),
                CodexMessage(
                    id: "history-tool",
                    threadId: threadID,
                    role: .system,
                    kind: .toolActivity,
                    text: "Reviewed provider isolation",
                    turnId: turnID,
                    itemId: "tool-between"
                ),
            ]

            let merged = service.mergeHistoryMessages(
                [canonicalAssistant, tool, newerLiveAssistant],
                history
            )

            XCTAssertEqual(
                merged.filter { $0.role == .assistant }.map(\.itemId),
                ["provider-a", "provider-b"]
            )
        }
    }

    func testOlderCanonicalPageRepairsAssistantIdentityPastNewerUserFence() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let olderTurnID = "turn-older"
        let newerTurnID = "turn-newer"
        let sourceKey = "\(olderTurnID):assistant-source"
        let text = "Older assistant commentary mirrored through two provider identities."
        var olderAssistant = CodexMessage(
            id: "older-local-assistant",
            threadId: threadID,
            role: .assistant,
            text: text,
            turnId: olderTurnID,
            itemId: "older-desktop-item"
        )
        var newerPrompt = CodexMessage(
            id: "newer-prompt",
            threadId: threadID,
            role: .user,
            text: "Continue",
            turnId: newerTurnID,
            itemId: "newer-user-item"
        )
        olderAssistant.orderIndex = 1
        newerPrompt.orderIndex = 2
        let history = [
            CodexMessage(
                id: "older-history-assistant",
                threadId: threadID,
                role: .assistant,
                text: text,
                turnId: olderTurnID,
                itemId: "older-canonical-item",
                sourceItemKey: sourceKey
            ),
        ]

        let merged = service.mergeHistoryMessages([olderAssistant, newerPrompt], history)

        XCTAssertEqual(merged.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(merged.first?.itemId, "older-canonical-item")
        XCTAssertEqual(merged.last?.id, "newer-prompt")
    }

    func testCanonicalRepairDoesNotLeavePendingNextUserInsideOlderTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        var userOne = CodexMessage(id: "user-1", threadId: threadID, role: .user, text: "one", turnId: "turn-1", itemId: "user-item-1")
        var assistantOne = CodexMessage(id: "assistant-1", threadId: threadID, role: .assistant, text: "answer one", turnId: "turn-1", itemId: "assistant-item-1")
        var pendingUser = CodexMessage(id: "pending-user-2", threadId: threadID, role: .user, text: "two", deliveryState: .pending)
        userOne.orderIndex = 1
        assistantOne.orderIndex = 2
        pendingUser.orderIndex = 3
        let history = [
            CodexMessage(id: "history-user-1", threadId: threadID, role: .user, text: "one", turnId: "turn-1", itemId: "user-item-1"),
            CodexMessage(id: "reasoning-1", threadId: threadID, role: .system, kind: .thinking, text: "reasoning", turnId: "turn-1", itemId: "reasoning-item-1"),
            CodexMessage(id: "history-assistant-1", threadId: threadID, role: .assistant, text: "answer one", turnId: "turn-1", itemId: "assistant-item-1"),
        ]

        let merged = service.mergeHistoryMessages([userOne, assistantOne, pendingUser], history)

        XCTAssertEqual(merged.map(\.id), ["user-1", "reasoning-1", "assistant-1", "pending-user-2"])
    }

    func testCanonicalRepairPlacesSingletonRecoveredHistoryBeforePendingPrompt() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        var pendingUser = CodexMessage(
            id: "pending-user-2",
            threadId: threadID,
            role: .user,
            text: "two",
            deliveryState: .pending
        )
        pendingUser.orderIndex = 1
        let history = [
            CodexMessage(
                id: "assistant-1",
                threadId: threadID,
                role: .assistant,
                text: "answer one",
                turnId: "turn-1",
                itemId: "assistant-item-1"
            ),
        ]

        let merged = service.mergeHistoryMessages([pendingUser], history)

        XCTAssertEqual(merged.map(\.id), ["assistant-1", "pending-user-2"])
    }

    func testCanonicalRepairKeepsUncoveredMiddleTurnBetweenCoveredTurns() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        func row(_ id: String, _ role: CodexMessageRole, _ turn: String, _ order: Int) -> CodexMessage {
            var message = CodexMessage(
                id: id,
                threadId: threadID,
                role: role,
                text: id,
                turnId: turn,
                itemId: "item-\(id)"
            )
            message.orderIndex = order
            return message
        }
        let existing = [
            row("user-1", .user, "turn-1", 1),
            row("assistant-1", .assistant, "turn-1", 2),
            row("user-2", .user, "turn-2", 3),
            row("assistant-2", .assistant, "turn-2", 4),
            row("user-3", .user, "turn-3", 5),
            row("assistant-3", .assistant, "turn-3", 6),
        ]
        let history = [
            row("history-user-1", .user, "turn-1", 101),
            row("history-assistant-1", .assistant, "turn-1", 102),
            row("history-user-3", .user, "turn-3", 103),
            row("history-assistant-3", .assistant, "turn-3", 104),
        ].enumerated().map { index, message in
            var value = message
            value.itemId = ["item-user-1", "item-assistant-1", "item-user-3", "item-assistant-3"][index]
            return value
        }

        let merged = service.mergeHistoryMessages(existing, history)

        XCTAssertEqual(merged.map(\.id), [
            "user-1", "assistant-1",
            "user-2", "assistant-2",
            "user-3", "assistant-3",
        ])
    }

    func testCanonicalRepairKeepsLocalSameTurnRowBetweenCanonicalAnchors() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        var opener = CodexMessage(id: "opener", threadId: threadID, role: .user, text: "fix", turnId: turnID, itemId: "user-item")
        var command = CodexMessage(id: "local-command", threadId: threadID, role: .system, kind: .commandExecution, text: "git status", turnId: turnID, itemId: "local-command-item")
        var final = CodexMessage(id: "final", threadId: threadID, role: .assistant, text: "done", turnId: turnID, itemId: "assistant-item")
        opener.orderIndex = 1
        command.orderIndex = 2
        final.orderIndex = 3
        let history = [
            CodexMessage(id: "history-opener", threadId: threadID, role: .user, text: "fix", turnId: turnID, itemId: "user-item"),
            CodexMessage(id: "history-final", threadId: threadID, role: .assistant, text: "done", turnId: turnID, itemId: "assistant-item"),
        ]

        let merged = service.mergeHistoryMessages([opener, command, final], history)

        XCTAssertEqual(merged.map(\.id), ["opener", "local-command", "final"])
    }

    func testHistoryReconcileUpgradesSyntheticTurnsForAssistantAndSystemRows() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let realTurnID = "turn-\(UUID().uuidString)"
        let existing = [
            CodexMessage(id: "assistant", threadId: threadID, role: .assistant, text: "done", turnId: "turn-line-4", itemId: "assistant-item"),
            CodexMessage(id: "command", threadId: threadID, role: .system, kind: .commandExecution, text: "git status", turnId: "ipc-turn-0", itemId: "command-item"),
        ]
        let history = [
            CodexMessage(id: "history-assistant", threadId: threadID, role: .assistant, text: "done", turnId: realTurnID, itemId: "assistant-item"),
            CodexMessage(id: "history-command", threadId: threadID, role: .system, kind: .commandExecution, text: "git status", turnId: realTurnID, itemId: "command-item"),
        ]

        let merged = service.mergeHistoryMessages(existing, history)

        XCTAssertEqual(merged.map(\.turnId), [realTurnID, realTurnID])
    }

    func testHistoryReconcileUpgradesJsonlFallbackItemIdentities() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let realTurnID = "turn-\(UUID().uuidString)"
        let existing = [
            CodexMessage(id: "user", threadId: threadID, role: .user, text: "fix", turnId: "turn-line-1", itemId: "user-message-line-3"),
            CodexMessage(id: "assistant", threadId: threadID, role: .assistant, text: "done", turnId: "turn-line-1", itemId: "response-item-line-5"),
            CodexMessage(id: "patch", threadId: threadID, role: .system, kind: .fileChange, text: "Path: App.swift", turnId: "turn-line-1", itemId: "apply-patch-line-4"),
        ]
        let history = [
            CodexMessage(id: "history-user", threadId: threadID, role: .user, text: "fix", turnId: realTurnID, itemId: "user-real"),
            CodexMessage(id: "history-assistant", threadId: threadID, role: .assistant, text: "done", turnId: realTurnID, itemId: "assistant-real"),
            CodexMessage(id: "history-patch", threadId: threadID, role: .system, kind: .fileChange, text: "Path: App.swift", turnId: realTurnID, itemId: "patch-real"),
        ]

        let merged = service.mergeHistoryMessages(existing, history)

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.compactMap(\.itemId), ["user-real", "assistant-real", "patch-real"])
        XCTAssertEqual(merged.compactMap(\.turnId), [realTurnID, realTurnID, realTurnID])
    }

    func testProjectedIndexIdentityDoesNotMergeDifferentPromptText() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let reusedTurnID = "ipc-turn-1"
        let reusedItemID = "ipc-turn-1:input"
        let existing = [
            CodexMessage(id: "cached-b", threadId: threadID, role: .user, text: "Prompt B", turnId: reusedTurnID, itemId: reusedItemID),
        ]
        let history = [
            CodexMessage(id: "history-a", threadId: threadID, role: .user, text: "Prompt A", turnId: reusedTurnID, itemId: reusedItemID),
        ]

        let replacementBase = CodexService.existingMessagesForCanonicalSourceReplacement(
            existing,
            history: history
        )

        let merged = service.mergeHistoryMessages(existing, history)

        XCTAssertEqual(replacementBase.map(\.id), ["cached-b"])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.text)), ["Prompt A", "Prompt B"])
    }

    func testRepeatedProvisionalPromptsDoNotCollapseOntoOneCanonicalTurn() {
        let threadID = "thread-\(UUID().uuidString)"
        let firstProvisionalTurnID = "ipc-turn-0"
        let secondProvisionalTurnID = "ipc-turn-1"
        let canonicalTurnID = "turn-\(UUID().uuidString)"
        var messages = [
            CodexMessage(
                id: "first-user",
                threadId: threadID,
                role: .user,
                text: "Run it again",
                turnId: firstProvisionalTurnID,
                itemId: "ipc-turn-0:input"
            ),
            CodexMessage(
                id: "first-finding",
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "First finding",
                turnId: firstProvisionalTurnID,
                itemId: "rollout-tool-first"
            ),
            CodexMessage(
                id: "second-user",
                threadId: threadID,
                role: .user,
                text: "Run it again",
                turnId: secondProvisionalTurnID,
                itemId: "ipc-turn-1:input"
            ),
            CodexMessage(
                id: "second-finding",
                threadId: threadID,
                role: .system,
                kind: .toolActivity,
                text: "Second finding",
                turnId: secondProvisionalTurnID,
                itemId: "rollout-tool-second"
            ),
        ]
        let history = [
            CodexMessage(
                id: "canonical-user",
                threadId: threadID,
                role: .user,
                text: "Run it again",
                turnId: canonicalTurnID,
                itemId: "canonical-user-item"
            ),
        ]

        CodexService.canonicalizeUniqueProvisionalTurnMappings(
            in: &messages,
            history: history
        )

        XCTAssertEqual(messages[0].turnId, firstProvisionalTurnID)
        XCTAssertEqual(messages[1].turnId, firstProvisionalTurnID)
        XCTAssertEqual(messages[2].turnId, secondProvisionalTurnID)
        XCTAssertEqual(messages[3].turnId, secondProvisionalTurnID)
    }

    func testSourceReplacementPrunesOnlyAbsentMirroredRowsInsideCanonicalTail() {
        let threadID = "thread-\(UUID().uuidString)"
        var olderStable = CodexMessage(id: "older", threadId: threadID, role: .assistant, text: "older", turnId: "turn-old", itemId: "older-real")
        var mirroredAnchor = CodexMessage(id: "anchor", threadId: threadID, role: .user, text: "fix", turnId: "turn-line-9", itemId: "user-message-line-20")
        var staleMirroredFinding = CodexMessage(id: "stale", threadId: threadID, role: .system, kind: .toolActivity, text: "stale finding", turnId: "turn-line-9", itemId: "remodex-jsonl-tool-turn-line-9")
        var pendingUser = CodexMessage(id: "pending", threadId: threadID, role: .user, text: "next", deliveryState: .pending)
        var stableLocalFinding = CodexMessage(id: "stable-local", threadId: threadID, role: .system, kind: .toolActivity, text: "local-only", turnId: "turn-real", itemId: "stable-local-item")
        olderStable.orderIndex = 1
        mirroredAnchor.orderIndex = 10
        staleMirroredFinding.orderIndex = 9
        pendingUser.orderIndex = 12
        stableLocalFinding.orderIndex = 13
        let canonical = [
            CodexMessage(id: "canonical-user", threadId: threadID, role: .user, text: "fix", turnId: "turn-real", itemId: "user-real"),
            CodexMessage(id: "canonical-assistant", threadId: threadID, role: .assistant, text: "done", turnId: "turn-real", itemId: "assistant-real"),
        ]

        let pruned = CodexService.existingMessagesForCanonicalSourceReplacement(
            [olderStable, mirroredAnchor, staleMirroredFinding, pendingUser, stableLocalFinding],
            history: canonical
        )

        XCTAssertEqual(pruned.map(\.id), ["older", "anchor", "pending", "stable-local"])
    }

    func testSourceReplacementDoesNotUseRepeatedAssistantTextAsTailAnchor() {
        let threadID = "thread-\(UUID().uuidString)"
        var oldDone = CodexMessage(id: "old-done", threadId: threadID, role: .assistant, text: "Done", turnId: "turn-line-1", itemId: "response-item-line-5")
        var laterMirror = CodexMessage(id: "later", threadId: threadID, role: .system, kind: .toolActivity, text: "keep until anchored", turnId: "turn-line-2", itemId: "remodex-jsonl-tool-2")
        oldDone.orderIndex = 1
        laterMirror.orderIndex = 2
        let history = [
            CodexMessage(id: "new-done", threadId: threadID, role: .assistant, text: "Done", turnId: "turn-real-new", itemId: "assistant-real-new"),
        ]

        let pruned = CodexService.existingMessagesForCanonicalSourceReplacement(
            [oldDone, laterMirror],
            history: history
        )

        XCTAssertEqual(pruned.map(\.id), ["old-done", "later"])
    }

    func testThreadReplacedLatchesCanonicalSourceReplacement() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.handleNotification(
            method: "thread/replaced",
            params: .object(["threadId": .string(threadID)])
        )

        XCTAssertTrue(service.pendingCanonicalSourceReplacementThreadIDs.contains(threadID))
    }

    func testRunningThreadHistoryDoesNotReviveOlderTurnsAsStreaming() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let oldTurnID = "turn-old"
        let activeTurnID = "turn-active"
        service.activeTurnIdByThread[threadID] = activeTurnID
        service.runningThreadIDs.insert(threadID)
        let existing = [
            CodexMessage(id: "old-assistant", threadId: threadID, role: .assistant, text: "old", turnId: oldTurnID, itemId: "old-assistant-item", isStreaming: false),
            CodexMessage(id: "old-command", threadId: threadID, role: .system, kind: .commandExecution, text: "old command", turnId: oldTurnID, itemId: "old-command-item", isStreaming: false),
            CodexMessage(id: "active-assistant", threadId: threadID, role: .assistant, text: "working", turnId: activeTurnID, itemId: "active-assistant-item", isStreaming: true),
        ]
        let history = [
            CodexMessage(id: "history-old-assistant", threadId: threadID, role: .assistant, text: "old", turnId: oldTurnID, itemId: "old-assistant-item", isStreaming: false),
            CodexMessage(id: "history-old-command", threadId: threadID, role: .system, kind: .commandExecution, text: "old command", turnId: oldTurnID, itemId: "old-command-item", isStreaming: false),
            CodexMessage(id: "history-active-assistant", threadId: threadID, role: .assistant, text: "working", turnId: activeTurnID, itemId: "active-assistant-item", isStreaming: false),
        ]

        let merged = service.mergeHistoryMessages(existing, history)

        XCTAssertFalse(merged.first(where: { $0.id == "old-assistant" })?.isStreaming ?? true)
        XCTAssertFalse(merged.first(where: { $0.id == "old-command" })?.isStreaming ?? true)
        XCTAssertTrue(merged.first(where: { $0.id == "active-assistant" })?.isStreaming ?? false)
    }

    func testRunningThreadWithoutActiveTurnIDPreservesStreamingHistoryRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        service.runningThreadIDs.insert(threadID)
        let existing = [
            CodexMessage(
                id: "live-assistant",
                threadId: threadID,
                role: .assistant,
                text: "Working live",
                turnId: turnID,
                itemId: "assistant-item",
                isStreaming: true
            ),
        ]
        let history = [
            CodexMessage(
                id: "history-assistant",
                threadId: threadID,
                role: .assistant,
                text: "Working",
                turnId: turnID,
                itemId: "assistant-item",
                isStreaming: false
            ),
        ]

        let merged = service.mergeHistoryMessages(existing, history)
        let assistant = merged.first(where: { $0.id == "live-assistant" })

        XCTAssertEqual(assistant?.text, "Working live")
        XCTAssertTrue(assistant?.isStreaming ?? false)
    }

    func testHistoryMergeKeepsDistinctStableCommandsInOneTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let existing = [
            CodexMessage(threadId: threadID, role: .system, kind: .commandExecution, text: "git status", turnId: turnID, itemId: "command-1"),
            CodexMessage(threadId: threadID, role: .system, kind: .commandExecution, text: "git diff", turnId: turnID, itemId: "command-2"),
        ]
        let history = [
            CodexMessage(threadId: threadID, role: .system, kind: .commandExecution, text: "git log -1", turnId: turnID, itemId: "command-3"),
        ]

        let merged = service.mergeHistoryMessages(existing, history)

        XCTAssertEqual(
            merged.filter { $0.kind == .commandExecution }.compactMap(\.itemId),
            ["command-1", "command-2", "command-3"]
        )
    }

    func testReplayedSystemItemRehydratesPersistedExactIdentity() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "reasoning-\(UUID().uuidString)"
        let persisted = CodexMessage(
            id: "persisted-reasoning",
            threadId: threadID,
            role: .system,
            kind: .thinking,
            text: "This is a much longer stale reasoning snapshot that must not win.",
            turnId: turnID,
            itemId: itemID,
            isStreaming: false,
            deliveryState: .confirmed
        )
        let staleDuplicate = CodexMessage(
            id: "stale-duplicate-reasoning",
            threadId: threadID,
            role: .system,
            kind: .thinking,
            text: "An even longer stale duplicate reasoning snapshot that must not replace the incoming completion.",
            turnId: turnID,
            itemId: itemID,
            isStreaming: false,
            deliveryState: .confirmed
        )
        service.messagesByThread[threadID] = [persisted, staleDuplicate]
        service.streamingSystemMessageByItemID.removeAll()

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: itemID,
            kind: .thinking,
            text: "canonical reasoning",
            isStreaming: false
        )

        let rows = service.messages(for: threadID).filter { $0.itemId == itemID }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "persisted-reasoning")
        XCTAssertEqual(rows[0].text, "canonical reasoning")
    }

    func testActiveReplayPrunesPersistedExactPlanDuplicatesBeforeUpdatingState() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "plan-\(UUID().uuidString)"
        var first = CodexMessage(id: "first-plan", threadId: threadID, role: .system, kind: .plan, text: "partial", turnId: turnID, itemId: itemID)
        var duplicate = CodexMessage(id: "duplicate-plan", threadId: threadID, role: .system, kind: .plan, text: "Complete canonical plan body", turnId: turnID, itemId: itemID)
        first.orderIndex = 1
        duplicate.orderIndex = 2
        service.messagesByThread[threadID] = [first, duplicate]
        service.runningThreadIDs.insert(threadID)
        service.streamingSystemMessageByItemID.removeAll()

        service.upsertPlanMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: itemID,
            explanation: "Current",
            steps: [CodexPlanStep(step: "Repair replay", status: .completed)],
            isStreaming: false,
            planPresentation: .progress
        )

        let rows = service.messages(for: threadID).filter { $0.itemId == itemID }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "first-plan")
        XCTAssertEqual(rows[0].text, "Complete canonical plan body")
        XCTAssertEqual(rows[0].planState?.explanation, "Current")
        XCTAssertEqual(rows[0].planState?.steps.first?.status, .completed)
    }

    func testClosedHistoryMergeHealsPersistedExactSystemDuplicates() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        var first = CodexMessage(id: "first", threadId: threadID, role: .system, kind: .thinking, text: "old", turnId: turnID, itemId: "reasoning-1")
        var duplicate = CodexMessage(id: "duplicate", threadId: threadID, role: .system, kind: .thinking, text: "duplicate", turnId: turnID, itemId: "reasoning-1")
        first.orderIndex = 1
        duplicate.orderIndex = 2
        let history = [
            CodexMessage(id: "canonical", threadId: threadID, role: .system, kind: .thinking, text: "canonical", turnId: turnID, itemId: "reasoning-1"),
        ]

        let merged = service.mergeHistoryMessages([first, duplicate], history)
        let rows = merged.filter { $0.itemId == "reasoning-1" }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "first")
        XCTAssertEqual(rows[0].text, "canonical")

        service.messagesByThread[threadID] = merged
        service.runningThreadIDs.insert(threadID)
        service.streamingSystemMessageByItemID[
            service.streamingItemMessageKey(threadId: threadID, itemId: "reasoning-1")
        ] = "duplicate"
        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "reasoning-1",
            kind: .thinking,
            text: "next live delta",
            isStreaming: true
        )

        let afterReplay = service.messages(for: threadID).filter { $0.itemId == "reasoning-1" }
        XCTAssertEqual(afterReplay.count, 1)
        XCTAssertEqual(afterReplay[0].id, "first")
        XCTAssertTrue(afterReplay[0].text.contains("next live delta"))
    }

    func testColdHistoryMergeHealsShortExactAssistantDuplicates() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let history = [
            CodexMessage(id: "assistant-first", threadId: threadID, role: .assistant, text: "ok", turnId: turnID, itemId: "assistant-item"),
            CodexMessage(id: "assistant-duplicate", threadId: threadID, role: .assistant, text: "okay", turnId: turnID, itemId: "assistant-item"),
        ]

        let merged = service.mergeHistoryMessages([], history)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "assistant-first")
        XCTAssertEqual(merged[0].text, "okay")
    }

    func testHistoryMergeHealsGenericAndConcreteSystemKindsWithExactIdentity() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let existing = [
            CodexMessage(id: "plan", threadId: threadID, role: .system, kind: .plan, text: "Plan", turnId: turnID, itemId: "shared-item"),
            CodexMessage(id: "generic", threadId: threadID, role: .system, kind: .chat, text: "Plan", turnId: turnID, itemId: "shared-item"),
        ]
        let history = [
            CodexMessage(id: "history-plan", threadId: threadID, role: .system, kind: .plan, text: "Current plan", turnId: turnID, itemId: "shared-item"),
        ]

        let merged = service.mergeHistoryMessages(existing, history)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "plan")
        XCTAssertEqual(merged[0].kind, .plan)
        XCTAssertEqual(merged[0].text, "Current plan")
    }

    func testHistoryReconcileRefreshesStructuredPlanState() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let local = CodexMessage(
            id: "persisted-plan",
            threadId: threadID,
            role: .system,
            kind: .plan,
            text: "Old plan",
            turnId: turnID,
            itemId: "turn:\(turnID)|kind:plan",
            planState: CodexPlanState(
                explanation: "Old",
                steps: [CodexPlanStep(step: "Fix history", status: .pending)]
            ),
            planPresentation: .progress,
            proposedPlan: CodexProposedPlan(body: "Planning...")
        )
        let duplicate = CodexMessage(
            id: "duplicate-plan",
            threadId: threadID,
            role: .system,
            kind: .plan,
            text: "Duplicate old plan",
            turnId: turnID,
            itemId: "remodex-jsonl-progress-plan-\(turnID)",
            planState: CodexPlanState(
                explanation: "Duplicate",
                steps: [CodexPlanStep(step: "Fix history", status: .inProgress)]
            ),
            planPresentation: .progress
        )
        let canonical = CodexMessage(
            id: "canonical-plan",
            threadId: threadID,
            role: .system,
            kind: .plan,
            text: "Current plan",
            turnId: turnID,
            itemId: "todo-list-\(turnID)",
            planState: CodexPlanState(
                explanation: "Current",
                steps: [CodexPlanStep(step: "Fix history", status: .completed)]
            ),
            planPresentation: .progress
        )

        let merged = service.mergeHistoryMessages([local, duplicate], [canonical])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "persisted-plan")
        XCTAssertEqual(merged[0].itemId, "todo-list-\(turnID)")
        XCTAssertEqual(merged[0].planState?.explanation, "Current")
        XCTAssertEqual(merged[0].planState?.steps.first?.status, .completed)
        XCTAssertNil(merged[0].proposedPlan)
    }

    func testProgressPlanReplayReusesCanonicalTodoListForOldAliases() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let todoListID = "todo-list-\(turnID)"
        let persisted = CodexMessage(
            id: "canonical-progress-plan",
            threadId: threadID,
            role: .system,
            kind: .plan,
            text: "Canonical progress",
            turnId: turnID,
            itemId: todoListID,
            planState: CodexPlanState(
                explanation: "Canonical",
                steps: [CodexPlanStep(step: "Keep one row", status: .inProgress)]
            ),
            planPresentation: .progress
        )
        service.messagesByThread[threadID] = [persisted]
        service.streamingSystemMessageByItemID.removeAll()

        service.upsertPlanMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: service.syntheticStreamingItemId(turnId: turnID, kind: .plan),
            text: "Placeholder replay",
            explanation: "Placeholder",
            steps: [CodexPlanStep(step: "Keep one row", status: .inProgress)],
            isStreaming: true,
            planPresentation: .progress
        )
        service.upsertPlanMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "old-stable-plan-call",
            text: "Latest progress",
            explanation: "Latest",
            steps: [CodexPlanStep(step: "Keep one row", status: .completed)],
            isStreaming: false,
            planPresentation: .progress
        )

        let plans = service.messages(for: threadID).filter { $0.kind == .plan }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].id, "canonical-progress-plan")
        XCTAssertEqual(plans[0].itemId, todoListID)
        XCTAssertEqual(plans[0].text, "Latest progress")
        XCTAssertEqual(plans[0].planState?.explanation, "Latest")
        XCTAssertEqual(plans[0].planState?.steps.first?.status, .completed)
    }

    func testProgressPlanPromotesStableOldCallIDToTodoListIdentity() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let todoListID = "todo-list-\(turnID)"
        service.messagesByThread[threadID] = [
            CodexMessage(
                id: "old-progress-plan",
                threadId: threadID,
                role: .system,
                kind: .plan,
                text: "Old progress",
                turnId: turnID,
                itemId: "old-stable-plan-call",
                planState: CodexPlanState(
                    explanation: "Old",
                    steps: [CodexPlanStep(step: "Promote identity", status: .inProgress)]
                ),
                planPresentation: .progress
            ),
        ]
        service.streamingSystemMessageByItemID.removeAll()

        service.upsertPlanMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: todoListID,
            text: "Current progress",
            explanation: "Current",
            steps: [CodexPlanStep(step: "Promote identity", status: .completed)],
            isStreaming: false,
            planPresentation: .progress
        )

        let plans = service.messages(for: threadID).filter { $0.kind == .plan }
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].id, "old-progress-plan")
        XCTAssertEqual(plans[0].itemId, todoListID)
        XCTAssertEqual(plans[0].text, "Current progress")
    }

    func testLiveCommandFallbackKeepsDistinctStableItemsButRebindsUniqueProvisionalRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let stable = CodexMessage(
            id: "stable-command-one",
            threadId: threadID,
            role: .system,
            kind: .commandExecution,
            text: "Running git status",
            turnId: turnID,
            itemId: "command-one"
        )
        service.messagesByThread[threadID] = [stable]
        service.streamingSystemMessageByItemID.removeAll()

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "command-two",
            kind: .commandExecution,
            text: "Completed git status",
            isStreaming: false
        )

        var commands = service.messages(for: threadID).filter { $0.kind == .commandExecution }
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.first(where: { $0.id == "stable-command-one" })?.text, "Running git status")

        let provisionalThreadID = "thread-\(UUID().uuidString)"
        let provisionalID = service.syntheticStreamingItemId(turnId: turnID, kind: .commandExecution)
        service.messagesByThread[provisionalThreadID] = [
            CodexMessage(
                id: "provisional-command",
                threadId: provisionalThreadID,
                role: .system,
                kind: .commandExecution,
                text: "Running git diff",
                turnId: turnID,
                itemId: provisionalID
            ),
        ]
        service.streamingSystemMessageByItemID.removeAll()

        service.upsertStreamingSystemItemMessage(
            threadId: provisionalThreadID,
            turnId: turnID,
            itemId: "real-command",
            kind: .commandExecution,
            text: "Completed git diff",
            isStreaming: false
        )

        commands = service.messages(for: provisionalThreadID).filter { $0.kind == .commandExecution }
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].id, "provisional-command")
        XCTAssertEqual(commands[0].itemId, "real-command")
        XCTAssertEqual(commands[0].text, "Completed git diff")
    }

    func testLiveCommandFallbackDoesNotChooseBetweenAmbiguousProvisionalRows() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        service.messagesByThread[threadID] = [
            CodexMessage(
                id: "provisional-command-one",
                threadId: threadID,
                role: .system,
                kind: .commandExecution,
                text: "Running git status",
                turnId: turnID,
                itemId: service.syntheticStreamingItemId(turnId: turnID, kind: .commandExecution)
            ),
            CodexMessage(
                id: "provisional-command-two",
                threadId: threadID,
                role: .system,
                kind: .commandExecution,
                text: "Running git status",
                turnId: turnID,
                itemId: "rollout-command:\(turnID)"
            ),
        ]
        service.streamingSystemMessageByItemID.removeAll()

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "real-command",
            kind: .commandExecution,
            text: "Completed git status",
            isStreaming: false
        )

        let commands = service.messages(for: threadID).filter { $0.kind == .commandExecution }
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands.first(where: { $0.id == "provisional-command-one" })?.itemId, service.syntheticStreamingItemId(turnId: turnID, kind: .commandExecution))
        XCTAssertEqual(commands.first(where: { $0.id == "provisional-command-two" })?.itemId, "rollout-command:\(turnID)")
        XCTAssertNotNil(commands.first(where: { $0.itemId == "real-command" }))
    }

    func testLateStableReasoningMissDoesNotReuseStableSyntheticAlias() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let existing = CodexMessage(
            id: "stable-reasoning-one",
            threadId: threadID,
            role: .system,
            kind: .thinking,
            text: "First stable reasoning section",
            turnId: turnID,
            itemId: "reasoning-one"
        )
        service.messagesByThread[threadID] = [existing]
        service.streamingSystemMessageByItemID.removeAll()
        service.streamingSystemMessageByItemID[
            service.streamingItemMessageKey(
                threadId: threadID,
                itemId: service.syntheticStreamingItemId(turnId: turnID, kind: .thinking)
            )
        ] = existing.id

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "reasoning-two",
            kind: .thinking,
            text: "Second stable reasoning section",
            isStreaming: false
        )

        let reasoning = service.messages(for: threadID).filter { $0.kind == .thinking }
        XCTAssertEqual(reasoning.count, 2)
        XCTAssertEqual(reasoning.first(where: { $0.id == existing.id })?.text, "First stable reasoning section")
        XCTAssertEqual(reasoning.first(where: { $0.itemId == "reasoning-two" })?.text, "Second stable reasoning section")
    }

    func testLateStableReasoningReusesOnlyOneUniqueProvisionalRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        service.messagesByThread[threadID] = [
            CodexMessage(
                id: "provisional-reasoning",
                threadId: threadID,
                role: .system,
                kind: .thinking,
                text: "Provisional reasoning",
                turnId: turnID,
                itemId: "rollout-thinking:\(turnID)"
            ),
            CodexMessage(
                id: "other-stable-reasoning",
                threadId: threadID,
                role: .system,
                kind: .thinking,
                text: "Other stable reasoning",
                turnId: turnID,
                itemId: "reasoning-other"
            ),
        ]
        service.streamingSystemMessageByItemID.removeAll()

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "reasoning-current",
            kind: .thinking,
            text: "Current canonical reasoning",
            isStreaming: false
        )

        let reasoning = service.messages(for: threadID).filter { $0.kind == .thinking }
        XCTAssertEqual(reasoning.count, 2)
        XCTAssertEqual(reasoning.first(where: { $0.id == "provisional-reasoning" })?.itemId, "reasoning-current")
        XCTAssertEqual(reasoning.first(where: { $0.id == "provisional-reasoning" })?.text, "Current canonical reasoning")
        XCTAssertEqual(reasoning.first(where: { $0.id == "other-stable-reasoning" })?.text, "Other stable reasoning")
    }

    func testLateStableReasoningDoesNotChooseBetweenAmbiguousProvisionalRows() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        service.messagesByThread[threadID] = [
            CodexMessage(
                id: "provisional-reasoning-one",
                threadId: threadID,
                role: .system,
                kind: .thinking,
                text: "First provisional reasoning",
                turnId: turnID,
                itemId: service.syntheticStreamingItemId(turnId: turnID, kind: .thinking)
            ),
            CodexMessage(
                id: "provisional-reasoning-two",
                threadId: threadID,
                role: .system,
                kind: .thinking,
                text: "Second provisional reasoning",
                turnId: turnID,
                itemId: "rollout-thinking:\(turnID)"
            ),
        ]
        service.streamingSystemMessageByItemID.removeAll()
        service.streamingSystemMessageByItemID[
            service.streamingItemMessageKey(
                threadId: threadID,
                itemId: service.syntheticStreamingItemId(turnId: turnID, kind: .thinking)
            )
        ] = "provisional-reasoning-one"

        service.upsertStreamingSystemItemMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "reasoning-current",
            kind: .thinking,
            text: "Current canonical reasoning",
            isStreaming: false
        )

        let reasoning = service.messages(for: threadID).filter { $0.kind == .thinking }
        XCTAssertEqual(reasoning.count, 3)
        XCTAssertEqual(reasoning.first(where: { $0.id == "provisional-reasoning-one" })?.itemId, service.syntheticStreamingItemId(turnId: turnID, kind: .thinking))
        XCTAssertEqual(reasoning.first(where: { $0.id == "provisional-reasoning-two" })?.itemId, "rollout-thinking:\(turnID)")
        XCTAssertNotNil(reasoning.first(where: { $0.itemId == "reasoning-current" }))
    }

    func testTurnTerminalStatePersistsCompletedGroupingAfterRelaunch() {
        let suiteName = "CodexServiceIncomingCommandExecutionTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let messages = [
            CodexMessage(
                id: "user",
                threadId: threadID,
                role: .user,
                text: "make an icon",
                turnId: turnID
            ),
            CodexMessage(
                id: "preamble",
                threadId: threadID,
                role: .assistant,
                text: "Using imagegen...",
                turnId: turnID,
                itemId: "status"
            ),
            CodexMessage(
                id: "reasoning-summary",
                threadId: threadID,
                role: .system,
                kind: .thinking,
                text: "**Planning image generation**\n\n<!-- -->",
                turnId: turnID,
                itemId: "reasoning-summary"
            ),
            CodexMessage(
                id: "final",
                threadId: threadID,
                role: .assistant,
                text: "Done.",
                turnId: turnID,
                itemId: "final"
            ),
        ]

        let firstService = CodexService(defaults: defaults)
        firstService.messagesByThread[threadID] = messages
        firstService.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)

        let reloadedService = CodexService(defaults: defaults)
        reloadedService.messagesByThread[threadID] = messages
        reloadedService.refreshThreadTimelineState(for: threadID)
        Self.retainedServices.append(firstService)
        Self.retainedServices.append(reloadedService)

        let snapshot = reloadedService.timelineState(for: threadID).renderSnapshot
        let renderItems = TurnTimelineRenderProjection.project(
            messages: snapshot.messages,
            completedTurnIDs: snapshot.completedTurnIDs
        )

        XCTAssertEqual(reloadedService.turnTerminalState(for: turnID), .completed)
        XCTAssertTrue(snapshot.completedTurnIDs.contains(turnID))
        XCTAssertTrue(renderItems.contains {
            if case .previousMessages = $0 { return true }
            return false
        })
        let previousGroup = renderItems.compactMap { item -> TurnTimelinePreviousMessagesGroup? in
            guard case .previousMessages(let group) = item else { return nil }
            return group
        }.first
        XCTAssertEqual(previousGroup?.messages.map(\.id), ["preamble", "reasoning-summary"])
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceIncomingCommandExecutionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]
        // CodexService currently crashes while deallocating in unit-test environment.
        // Keep instances alive for the process lifetime so assertions can run deterministically.
        Self.retainedServices.append(service)
        return service
    }
}
