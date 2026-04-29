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
