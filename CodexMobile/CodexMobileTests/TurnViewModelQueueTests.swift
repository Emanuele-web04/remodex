// FILE: TurnViewModelQueueTests.swift
// Purpose: Validates client-side per-thread turn queue behavior.
// Layer: Unit Test
// Exports: TurnViewModelQueueTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnViewModelQueueTests: XCTestCase {
    private static var retainedServices: [CodexService] = []
    private static var retainedViewModels: [TurnViewModel] = []

    func testSendTurnQueuesImmediatelyWhenThreadBusy() async throws {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")
        service.activeTurnIdByThread["thread-queue"] = "turn-live"

        let viewModel = makeViewModel()
        let attachment = CodexImageAttachment(
            thumbnailBase64JPEG: "thumb",
            payloadDataURL: "data:image/jpeg;base64,AAAA"
        )
        var recordedMethods: [String] = []

        viewModel.input = "Please inspect @TurnView.swift"
        viewModel.composerMentionedFiles = [
            TurnComposerMentionedFile(
                fileName: "TurnView.swift",
                path: "CodexMobile/Views/Turn/TurnView.swift"
            )
        ]
        viewModel.composerMentionedSkills = [
            TurnComposerMentionedSkill(
                name: "check-code",
                path: "/Users/me/.codex/skills/check-code/SKILL.md",
                description: "Review code"
            )
        ]
        viewModel.composerAttachments = [
            TurnComposerImageAttachment(id: "att-1", state: .ready(attachment))
        ]
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            XCTFail("sendTurn should queue instead of calling \(method) while the thread is busy")
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        viewModel.sendTurn(codex: service, threadID: "thread-queue")
        await waitForSendCompletion(viewModel)

        XCTAssertTrue(recordedMethods.isEmpty)
        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 1)
        XCTAssertTrue(viewModel.input.isEmpty)
        XCTAssertTrue(viewModel.composerMentionedFiles.isEmpty)
        XCTAssertTrue(viewModel.composerMentionedSkills.isEmpty)
        XCTAssertTrue(viewModel.composerAttachments.isEmpty)
        XCTAssertFalse(viewModel.isQueuePaused(codex: service, threadID: "thread-queue"))
        let queuedDraft = try XCTUnwrap(service.queuedTurnDraftsByThread["thread-queue"]?.first)
        XCTAssertEqual(queuedDraft.text, "Please inspect @CodexMobile/Views/Turn/TurnView.swift")
        XCTAssertEqual(queuedDraft.skillMentions.map(\.id), ["check-code"])
        XCTAssertEqual(queuedDraft.attachments.count, 1)
        XCTAssertTrue(service.messagesByThread["thread-queue"]?.isEmpty ?? true)
    }

    func testFlushQueueDoesNothingWhenDisconnected() {
        let service = makeService()
        service.isConnected = false

        let viewModel = makeViewModel()
        service.queuedTurnDraftsByThread["thread-queue"] = [makeDraft(text: "queued")]

        viewModel.flushQueueIfPossible(codex: service, threadID: "thread-queue")

        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 1)
        XCTAssertFalse(viewModel.isSending)
    }

    func testFlushQueueDoesNothingWhenThreadBusy() {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")

        let viewModel = makeViewModel()
        service.queuedTurnDraftsByThread["thread-queue"] = [makeDraft(text: "queued")]

        viewModel.flushQueueIfPossible(codex: service, threadID: "thread-queue")

        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 1)
        XCTAssertFalse(viewModel.isSending)
    }

    func testFlushQueueFailureRequeuesAndPausesQueue() async {
        let service = makeService()
        service.isConnected = true

        let viewModel = makeViewModel()
        service.queuedTurnDraftsByThread["thread-queue"] = [makeDraft(text: "queued")]

        viewModel.flushQueueIfPossible(codex: service, threadID: "thread-queue")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 1)
        XCTAssertTrue(viewModel.isQueuePaused(codex: service, threadID: "thread-queue"))
        XCTAssertNotNil(viewModel.queuePauseMessage(codex: service, threadID: "thread-queue"))
        XCTAssertEqual(service.lastErrorMessage?.hasPrefix("Queue paused:"), true)
    }

    func testResumeQueueClearsPauseState() {
        let service = makeService()
        service.isConnected = false

        let viewModel = makeViewModel()
        service.queuedTurnDraftsByThread["thread-queue"] = [makeDraft(text: "queued")]
        service.queuePauseStateByThread["thread-queue"] = .paused(errorMessage: "temporary")

        viewModel.resumeQueueAndFlushIfPossible(codex: service, threadID: "thread-queue")

        XCTAssertFalse(viewModel.isQueuePaused(codex: service, threadID: "thread-queue"))
        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 1)
    }

    func testQueuedDraftsPersistAcrossViewModelRecreationForSameThread() {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")

        let firstViewModel = makeViewModel()
        firstViewModel.input = "Message one"
        firstViewModel.sendTurn(codex: service, threadID: "thread-queue")

        let secondViewModel = makeViewModel()
        XCTAssertEqual(secondViewModel.queuedCount(codex: service, threadID: "thread-queue"), 1)
        XCTAssertEqual(secondViewModel.queuedCount(codex: service, threadID: "other-thread"), 0)
    }

    func testSendTurnStartsImmediatelyWhenRunningFlagRefreshClearsStaleBusyState() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")
        service.resumedThreadIDs.insert("thread-queue")

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            if method == "thread/read" {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "turns": .array([])
                        ])
                    ]),
                    includeJSONRPC: false
                )
            }

            XCTAssertEqual(method, "turn/start")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-new")]),
                includeJSONRPC: false
            )
        }

        let viewModel = makeViewModel()
        viewModel.input = "send now"

        viewModel.sendTurn(codex: service, threadID: "thread-queue")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(recordedMethods, ["thread/read", "turn/start"])
        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 0)
        XCTAssertEqual(service.activeTurnID(for: "thread-queue"), "turn-new")
    }

    func testSendTurnQueuesAfterBusyRefreshConfirmsActiveRun() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            if method == "thread/read" {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "turns": .array([
                                .object([
                                    "id": .string("turn-fallback"),
                                    "status": .string("in_progress"),
                                ])
                            ])
                        ])
                    ]),
                    includeJSONRPC: false
                )
            }

            XCTFail("sendTurn should not steer automatically after busy refresh")
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        let viewModel = makeViewModel()
        viewModel.input = "Follow up now"

        viewModel.sendTurn(codex: service, threadID: "thread-queue")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(recordedMethods, ["thread/read"])
        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 1)
        XCTAssertEqual(service.queuedTurnDraftsByThread["thread-queue"]?.first?.text, "Follow up now")
        XCTAssertTrue(service.messagesByThread["thread-queue"]?.isEmpty ?? true)
    }

    func testSendTurnStoresOnlyConfirmedFileMentionsOnUserMessage() async {
        let service = makeService()
        service.isConnected = true
        service.resumedThreadIDs.insert("thread-queue")
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "turn/start")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-new")]),
                includeJSONRPC: false
            )
        }

        let viewModel = makeViewModel()
        viewModel.input = "Please inspect @TurnView.swift"
        viewModel.composerMentionedFiles = [
            TurnComposerMentionedFile(
                fileName: "TurnView.swift",
                path: "CodexMobile/Views/Turn/TurnView.swift"
            )
        ]

        viewModel.sendTurn(codex: service, threadID: "thread-queue")
        await waitForSendCompletion(viewModel)

        let message = try XCTUnwrap(service.messagesByThread["thread-queue"]?.last)
        XCTAssertEqual(message.text, "Please inspect @CodexMobile/Views/Turn/TurnView.swift")
        XCTAssertEqual(message.fileMentions, ["CodexMobile/Views/Turn/TurnView.swift"])
    }

    func testSendTurnDoesNotStoreManualFileLikeTextAsConfirmedMention() async {
        let service = makeService()
        service.isConnected = true
        service.resumedThreadIDs.insert("thread-queue")
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "turn/start")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-new")]),
                includeJSONRPC: false
            )
        }

        let viewModel = makeViewModel()
        viewModel.input = "Please inspect @CodexMobile/Views/Turn/TurnView.swift"

        viewModel.sendTurn(codex: service, threadID: "thread-queue")
        await waitForSendCompletion(viewModel)

        let message = try XCTUnwrap(service.messagesByThread["thread-queue"]?.last)
        XCTAssertEqual(message.text, "Please inspect @CodexMobile/Views/Turn/TurnView.swift")
        XCTAssertTrue(message.fileMentions.isEmpty)
    }

    func testFlushQueuePreservesPlanModeFromBusyThreadQueue() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")

        let viewModel = makeViewModel()
        viewModel.isPlanModeArmed = true
        viewModel.input = "Plan the rollout"

        viewModel.sendTurn(codex: service, threadID: "thread-queue")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 1)
        XCTAssertEqual(
            service.queuedTurnDraftsByThread["thread-queue"]?.first?.collaborationMode,
            .plan
        )

        service.runningThreadIDs.remove("thread-queue")
        service.activeTurnIdByThread["thread-queue"] = nil

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-plan")]),
                includeJSONRPC: false
            )
        }

        viewModel.flushQueueIfPossible(codex: service, threadID: "thread-queue")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(
            capturedParams?.objectValue?["collaborationMode"]?.stringValue,
            CodexCollaborationModeKind.plan.rawValue
        )
        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 0)
    }

    func testSendTurnQueuesWhenBusyEvenIfActiveTurnMappingExists() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")
        service.activeTurnIdByThread["thread-queue"] = "turn-live"

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            XCTFail("sendTurn should not call \(method) while an active turn exists")
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        let viewModel = makeViewModel()
        viewModel.input = "Retry as new turn"

        viewModel.sendTurn(codex: service, threadID: "thread-queue")
        await waitForSendCompletion(viewModel)

        XCTAssertTrue(recordedMethods.isEmpty)
        XCTAssertEqual(viewModel.queuedCount(codex: service, threadID: "thread-queue"), 1)
        XCTAssertEqual(service.queuedTurnDraftsByThread["thread-queue"]?.first?.text, "Retry as new turn")
        XCTAssertTrue(service.messagesByThread["thread-queue"]?.isEmpty ?? true)
    }

    func testSteerQueuedDraftRemovesOnlySelectedRowAndPreservesOrder() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")
        service.activeTurnIdByThread["thread-queue"] = "turn-live"

        var recordedMethods: [String] = []
        var recordedParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            recordedParams.append(params ?? .null)
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["turnId": .string("turn-live")]), includeJSONRPC: false)
        }

        let viewModel = makeViewModel()
        let first = makeDraft(text: "first")
        let second = makeDraft(text: "second")
        let third = makeDraft(text: "third")
        service.queuedTurnDraftsByThread["thread-queue"] = [first, second, third]

        viewModel.steerQueuedDraft(id: second.id, codex: service, threadID: "thread-queue")
        await waitForSteerCompletion(viewModel)

        XCTAssertEqual(recordedMethods, ["turn/steer"])
        XCTAssertEqual(
            service.queuedTurnDraftsByThread["thread-queue"]?.map(\.id),
            [first.id, third.id]
        )
        XCTAssertEqual(recordedParams.count, 1)
    }

    func testSteerQueuedDraftKeepsFullPayloadShape() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")
        service.activeTurnIdByThread["thread-queue"] = "turn-live"

        let attachment = CodexImageAttachment(
            thumbnailBase64JPEG: "thumb",
            payloadDataURL: "data:image/jpeg;base64,BBBB"
        )
        let draft = QueuedTurnDraft(
            id: "draft-rich",
            text: "Please inspect this",
            attachments: [attachment],
            skillMentions: [
                CodexTurnSkillMention(
                    id: "check-code",
                    name: "check-code",
                    path: "/Users/me/.codex/skills/check-code/SKILL.md"
                )
            ],
            collaborationMode: nil,
            createdAt: Date()
        )

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/steer")
            capturedParams = params
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["turnId": .string("turn-live")]), includeJSONRPC: false)
        }

        let viewModel = makeViewModel()
        service.queuedTurnDraftsByThread["thread-queue"] = [draft]

        viewModel.steerQueuedDraft(id: draft.id, codex: service, threadID: "thread-queue")
        await waitForSteerCompletion(viewModel)

        let paramsObject = capturedParams?.objectValue
        let inputItems = paramsObject?["input"]?.arrayValue ?? []
        XCTAssertEqual(paramsObject?["threadId"]?.stringValue, "thread-queue")
        XCTAssertEqual(paramsObject?["expectedTurnId"]?.stringValue, "turn-live")
        XCTAssertEqual(inputItems.count, 3)
        XCTAssertEqual(inputItems[0].objectValue?["type"]?.stringValue, "image")
        XCTAssertEqual(inputItems[0].objectValue?["url"]?.stringValue, attachment.payloadDataURL)
        XCTAssertEqual(inputItems[1].objectValue?["type"]?.stringValue, "text")
        XCTAssertEqual(inputItems[1].objectValue?["text"]?.stringValue, draft.text)
        XCTAssertEqual(inputItems[2].objectValue?["type"]?.stringValue, "skill")
        XCTAssertEqual(inputItems[2].objectValue?["id"]?.stringValue, "check-code")
    }

    func testSteerQueuedDraftPreservesPlanMode() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")
        service.activeTurnIdByThread["thread-queue"] = "turn-live"
        service.selectedModelId = "gpt-5.3-codex"

        let draft = QueuedTurnDraft(
            id: "draft-plan",
            text: "Plan the rollout",
            attachments: [],
            skillMentions: [],
            collaborationMode: .plan,
            createdAt: Date()
        )

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/steer")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-live")]),
                includeJSONRPC: false
            )
        }

        let viewModel = makeViewModel()
        service.queuedTurnDraftsByThread["thread-queue"] = [draft]

        viewModel.steerQueuedDraft(id: draft.id, codex: service, threadID: "thread-queue")
        await waitForSteerCompletion(viewModel)

        XCTAssertEqual(
            capturedParams?.objectValue?["collaborationMode"]?.objectValue?["mode"]?.stringValue,
            CodexCollaborationModeKind.plan.rawValue
        )
    }

    func testSteerQueuedDraftFailureKeepsRowAndDoesNotPauseQueue() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")
        service.activeTurnIdByThread["thread-queue"] = "turn-live"
        service.requestTransportOverride = { _, _ in
            throw CodexServiceError.rpcError(RPCError(code: -32000, message: "turn already completed"))
        }

        let viewModel = makeViewModel()
        let draft = makeDraft(text: "queued")
        service.queuedTurnDraftsByThread["thread-queue"] = [draft]

        viewModel.steerQueuedDraft(id: draft.id, codex: service, threadID: "thread-queue")
        await waitForSteerCompletion(viewModel)

        XCTAssertEqual(service.queuedTurnDraftsByThread["thread-queue"]?.map(\.id), [draft.id])
        XCTAssertFalse(viewModel.isQueuePaused(codex: service, threadID: "thread-queue"))
        XCTAssertEqual(service.lastErrorMessage, "turn already completed")
        XCTAssertTrue(service.messagesByThread["thread-queue"]?.isEmpty ?? true)
    }

    func testSteerQueuedDraftResolvesFallbackTurnIDWhenActiveMappingMissing() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")

        var recordedMethods: [String] = []
        var expectedTurnIDs: [String] = []
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            if method == "thread/read" {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "turns": .array([
                                .object([
                                    "id": .string("turn-fallback"),
                                    "status": .string("in_progress"),
                                ])
                            ])
                        ])
                    ]),
                    includeJSONRPC: false
                )
            }
            expectedTurnIDs.append(params?.objectValue?["expectedTurnId"]?.stringValue ?? "")
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["turnId": .string("turn-fallback")]), includeJSONRPC: false)
        }

        let viewModel = makeViewModel()
        let draft = makeDraft(text: "queued")
        service.queuedTurnDraftsByThread["thread-queue"] = [draft]

        viewModel.steerQueuedDraft(id: draft.id, codex: service, threadID: "thread-queue")
        await waitForSteerCompletion(viewModel)

        XCTAssertEqual(recordedMethods, ["thread/read", "turn/steer"])
        XCTAssertEqual(expectedTurnIDs, ["turn-fallback"])
        XCTAssertTrue(service.queuedTurnDraftsByThread["thread-queue"]?.isEmpty ?? false)
    }

    func testSteerQueuedDraftStartsTurnWhenRunningFlagRefreshClearsStaleBusyState() async {
        let service = makeService()
        service.isConnected = true
        service.runningThreadIDs.insert("thread-queue")
        service.resumedThreadIDs.insert("thread-queue")

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            if method == "thread/read" {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "turns": .array([])
                        ])
                    ]),
                    includeJSONRPC: false
                )
            }

            XCTAssertEqual(method, "turn/start")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-new")]),
                includeJSONRPC: false
            )
        }

        let viewModel = makeViewModel()
        let draft = makeDraft(text: "queued")
        service.queuedTurnDraftsByThread["thread-queue"] = [draft]

        viewModel.steerQueuedDraft(id: draft.id, codex: service, threadID: "thread-queue")
        await waitForSteerCompletion(viewModel)

        XCTAssertEqual(recordedMethods, ["thread/read", "turn/start"])
        XCTAssertTrue(service.queuedTurnDraftsByThread["thread-queue"]?.isEmpty ?? false)
        XCTAssertEqual(service.activeTurnID(for: "thread-queue"), "turn-new")
    }

    func testRestoreQueuedDraftMovesSelectedRowIntoComposerAndRemovesItFromQueue() {
        let service = makeService()
        let attachment = CodexImageAttachment(
            thumbnailBase64JPEG: "thumb",
            payloadDataURL: "data:image/jpeg;base64,DDDD"
        )
        let first = makeDraft(text: "keep queued")
        let second = QueuedTurnDraft(
            id: "draft-restore",
            text: "Please inspect @CodexMobile/Views/Turn/TurnView.swift",
            attachments: [attachment],
            skillMentions: [
                CodexTurnSkillMention(
                    id: "check-code",
                    name: "check-code",
                    path: "/Users/me/.codex/skills/check-code/SKILL.md"
                )
            ],
            collaborationMode: .plan,
            rawInput: "Please inspect @TurnView.swift",
            rawFileMentions: [
                TurnComposerMentionedFile(
                    fileName: "TurnView.swift",
                    path: "CodexMobile/Views/Turn/TurnView.swift"
                )
            ],
            rawSkillMentions: [
                TurnComposerMentionedSkill(
                    name: "check-code",
                    path: "/Users/me/.codex/skills/check-code/SKILL.md",
                    description: "Review code"
                )
            ],
            rawAttachments: [
                TurnComposerImageAttachment(id: "att-restore", state: .ready(attachment))
            ],
            rawSubagentsSelectionArmed: true,
            createdAt: Date()
        )

        let viewModel = makeViewModel()
        service.queuedTurnDraftsByThread["thread-queue"] = [first, second]

        viewModel.restoreQueuedDraftToComposer(id: second.id, codex: service, threadID: "thread-queue")

        XCTAssertEqual(service.queuedTurnDraftsByThread["thread-queue"]?.map(\.id), [first.id])
        XCTAssertEqual(viewModel.input, "Please inspect @TurnView.swift")
        XCTAssertEqual(viewModel.composerMentionedFiles.map(\.path), ["CodexMobile/Views/Turn/TurnView.swift"])
        XCTAssertEqual(viewModel.composerMentionedSkills.map(\.name), ["check-code"])
        XCTAssertEqual(viewModel.composerAttachments.count, 1)
        XCTAssertTrue(viewModel.isSubagentsSelectionArmed)
        XCTAssertTrue(viewModel.isPlanModeArmed)
    }

    func testRestoreQueuedDraftDoesNothingWhenComposerAlreadyHasContent() {
        let service = makeService()
        let viewModel = makeViewModel()
        let draft = makeDraft(text: "queued")
        service.queuedTurnDraftsByThread["thread-queue"] = [draft]
        viewModel.input = "Already editing"

        viewModel.restoreQueuedDraftToComposer(id: draft.id, codex: service, threadID: "thread-queue")

        XCTAssertEqual(service.queuedTurnDraftsByThread["thread-queue"]?.map(\.id), [draft.id])
        XCTAssertEqual(viewModel.input, "Already editing")
    }

    func testRefreshInFlightTurnStateUsesLatestTurnAndClearsOlderInterruptibleTurn() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.runningThreadIDs.insert("thread-queue")
        service.activeTurnIdByThread["thread-queue"] = "turn-old"
        service.activeTurnId = "turn-old"

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/read")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "turns": .array([
                            .object([
                                "id": .string("turn-old"),
                                "status": .string("in_progress"),
                            ]),
                            .object([
                                "id": .string("turn-latest"),
                                "status": .string("completed"),
                            ]),
                        ])
                    ])
                ]),
                includeJSONRPC: false
            )
        }

        let didRefresh = await service.refreshInFlightTurnState(threadId: "thread-queue")

        XCTAssertTrue(didRefresh)
        XCTAssertFalse(service.runningThreadIDs.contains("thread-queue"))
        XCTAssertNil(service.activeTurnIdByThread["thread-queue"])
    }

    func testRefreshInFlightTurnStateKeepsLatestTurnWhenStatusIsMissing() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.runningThreadIDs.insert("thread-queue")
        service.activeTurnIdByThread["thread-queue"] = "turn-old"
        service.activeTurnId = "turn-old"

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/read")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "turns": .array([
                            .object([
                                "id": .string("turn-old"),
                                "status": .string("in_progress"),
                            ]),
                            .object([
                                "id": .string("turn-latest"),
                            ]),
                        ])
                    ])
                ]),
                includeJSONRPC: false
            )
        }

        let didRefresh = await service.refreshInFlightTurnState(threadId: "thread-queue")

        XCTAssertTrue(didRefresh)
        XCTAssertTrue(service.runningThreadIDs.contains("thread-queue"))
        XCTAssertEqual(service.activeTurnIdByThread["thread-queue"], "turn-latest")
        XCTAssertEqual(service.activeTurnId, "turn-latest")
    }

    func testInterruptTurnDoesNotTargetCompletedLatestTurnWhenRunningTurnHasNoID() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.runningThreadIDs.insert("thread-queue")
        service.protectedRunningFallbackThreadIDs.insert("thread-queue")

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            XCTAssertEqual(method, "thread/read")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "turns": .array([
                            .object([
                                "status": .string("in_progress"),
                            ]),
                            .object([
                                "id": .string("turn-completed"),
                                "status": .string("completed"),
                            ]),
                        ])
                    ])
                ]),
                includeJSONRPC: false
            )
        }

        do {
            try await service.interruptTurn(turnId: nil, threadId: "thread-queue")
            XCTFail("interruptTurn should fail when no interruptible turn id is available")
        } catch {
            XCTAssertTrue(
                service.userFacingTurnErrorMessage(from: error).contains("interruptible turn ID")
            )
        }

        XCTAssertEqual(recordedMethods, ["thread/read"])
        XCTAssertFalse(service.runningThreadIDs.contains("thread-queue"))
        XCTAssertTrue(service.protectedRunningFallbackThreadIDs.contains("thread-queue"))
    }

    func testSteerQueuedDraftIsNoOpWhenThreadIsNotRunning() async {
        let service = makeService()
        service.isConnected = true

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        let viewModel = makeViewModel()
        let draft = makeDraft(text: "queued")
        service.queuedTurnDraftsByThread["thread-queue"] = [draft]

        viewModel.steerQueuedDraft(id: draft.id, codex: service, threadID: "thread-queue")
        await waitForSteerCompletion(viewModel)

        XCTAssertTrue(recordedMethods.isEmpty)
        XCTAssertEqual(service.queuedTurnDraftsByThread["thread-queue"]?.map(\.id), [draft.id])
    }

    func testSteerTurnSendsExpectedRequestShapeAndDoesNotAppendUserMessage() async throws {
        let service = makeService()
        let attachment = CodexImageAttachment(
            thumbnailBase64JPEG: "thumb",
            payloadDataURL: "data:image/jpeg;base64,CCCC"
        )

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/steer")
            capturedParams = params
            return RPCMessage(id: .string(UUID().uuidString), result: .object(["turnId": .string("turn-123")]), includeJSONRPC: false)
        }

        try await service.steerTurn(
            userInput: "Steer this",
            threadId: "thread-steer",
            expectedTurnId: "turn-123",
            attachments: [attachment],
            skillMentions: [
                CodexTurnSkillMention(
                    id: "check-code",
                    name: "check-code",
                    path: "/Users/me/.codex/skills/check-code/SKILL.md"
                )
            ]
        )

        let paramsObject = try XCTUnwrap(capturedParams?.objectValue)
        XCTAssertEqual(paramsObject["threadId"]?.stringValue, "thread-steer")
        XCTAssertEqual(paramsObject["expectedTurnId"]?.stringValue, "turn-123")
        XCTAssertEqual(paramsObject["input"]?.arrayValue?.count, 3)
        let optimisticMessage = try XCTUnwrap(service.messagesByThread["thread-steer"]?.last)
        XCTAssertEqual(optimisticMessage.role, .user)
        XCTAssertEqual(optimisticMessage.text, "Steer this")
        XCTAssertEqual(optimisticMessage.deliveryState, .confirmed)
        XCTAssertEqual(optimisticMessage.turnId, "turn-123")
    }

    func testSteerTurnRetriesOnceWithRefreshedTurnID() async throws {
        let service = makeService()
        var steerAttemptTurnIDs: [String] = []

        service.requestTransportOverride = { method, params in
            if method == "turn/steer" {
                let expectedTurnID = params?.objectValue?["expectedTurnId"]?.stringValue ?? ""
                steerAttemptTurnIDs.append(expectedTurnID)
                if steerAttemptTurnIDs.count == 1 {
                    throw CodexServiceError.rpcError(RPCError(code: -32000, message: "no active turn"))
                }
                return RPCMessage(id: .string(UUID().uuidString), result: .object(["turnId": .string(expectedTurnID)]), includeJSONRPC: false)
            }

            XCTAssertEqual(method, "thread/read")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "turns": .array([
                            .object([
                                "id": .string("turn-refreshed"),
                                "status": .string("in_progress"),
                            ])
                        ])
                    ])
                ]),
                includeJSONRPC: false
            )
        }

        try await service.steerTurn(
            userInput: "Retry steer",
            threadId: "thread-steer",
            expectedTurnId: "turn-stale"
        )

        XCTAssertEqual(steerAttemptTurnIDs, ["turn-stale", "turn-refreshed"])
    }

    private func makeDraft(text: String) -> QueuedTurnDraft {
        QueuedTurnDraft(
            id: UUID().uuidString,
            text: text,
            attachments: [],
            skillMentions: [],
            collaborationMode: nil,
            createdAt: Date()
        )
    }

    private func waitForSendCompletion(_ viewModel: TurnViewModel, maxPollCount: Int = 160) async {
        for _ in 0..<maxPollCount where viewModel.isSending {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForSteerCompletion(_ viewModel: TurnViewModel, maxPollCount: Int = 160) async {
        for _ in 0..<maxPollCount where viewModel.steeringDraftID != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeViewModel() -> TurnViewModel {
        let viewModel = TurnViewModel()
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }

    private func makeService() -> CodexService {
        let suiteName = "TurnViewModelQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]

        // CodexService currently crashes while deallocating in unit-test environment.
        // Keep instances alive for process lifetime so assertions remain deterministic.
        Self.retainedServices.append(service)
        return service
    }
}
