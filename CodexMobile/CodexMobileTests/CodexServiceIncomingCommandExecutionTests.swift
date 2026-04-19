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
