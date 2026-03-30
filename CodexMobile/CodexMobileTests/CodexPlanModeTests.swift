// FILE: CodexPlanModeTests.swift
// Purpose: Verifies plan-mode turn/start payloads and inline timeline state for plan events.
// Layer: Unit Test
// Exports: CodexPlanModeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexPlanModeTests: XCTestCase {
    private static var retainedServices: [CodexService] = []
    private static var retainedViewModels: [TurnViewModel] = []

    func testSendTurnUsesPlanModeOnceAndThenResets() async {
        let service = makeService()
        service.isConnected = true
        service.supportsTurnCollaborationMode = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")

        var capturedTurnStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedTurnStartParams.append(params ?? .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-live")]),
                includeJSONRPC: false
            )
        }

        let viewModel = makeViewModel()
        viewModel.input = "Plan this refactor"
        viewModel.setPlanModeArmed(true)
        viewModel.sendTurn(codex: service, threadID: "thread-plan")
        await waitForSendCompletion(viewModel)

        XCTAssertFalse(viewModel.isPlanModeArmed)
        XCTAssertEqual(capturedTurnStartParams.count, 1)
        XCTAssertEqual(
            capturedTurnStartParams[0].objectValue?["collaborationMode"]?.objectValue?["mode"]?.stringValue,
            "plan"
        )
        XCTAssertEqual(
            capturedTurnStartParams[0].objectValue?["model"]?.stringValue,
            "gpt-5-codex"
        )
        XCTAssertEqual(
            capturedTurnStartParams[0].objectValue?["effort"]?.stringValue,
            "medium"
        )

        viewModel.input = "Normal follow-up"
        viewModel.sendTurn(codex: service, threadID: "thread-plan")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(capturedTurnStartParams.count, 2)
        XCTAssertNil(capturedTurnStartParams[1].objectValue?["collaborationMode"])
    }

    func testUnsupportedPlanModeFallsBackToNormalTurnAndStopsRetryingPlanField() async throws {
        let service = makeService()
        service.isConnected = true
        service.supportsTurnCollaborationMode = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")

        let threadID = "thread-\(UUID().uuidString)"
        var capturedTurnStartParams: [JSONValue] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            let requestParams = params ?? .null
            capturedTurnStartParams.append(requestParams)

            if capturedTurnStartParams.count == 1 {
                throw CodexServiceError.rpcError(
                    RPCError(
                        code: -32600,
                        message: "turn/start.collaborationMode requires experimentalApi capability"
                    )
                )
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-live")]),
                includeJSONRPC: false
            )
        }

        try await service.sendTurnStart("Plan this flow", to: threadID, collaborationMode: .plan)

        XCTAssertEqual(capturedTurnStartParams.count, 2)
        XCTAssertEqual(
            capturedTurnStartParams[0].objectValue?["collaborationMode"]?.objectValue?["mode"]?.stringValue,
            "plan"
        )
        XCTAssertNil(capturedTurnStartParams[1].objectValue?["collaborationMode"])
        XCTAssertFalse(service.supportsTurnCollaborationMode)
        XCTAssertEqual(
            service.messages(for: threadID).last(where: { $0.role == .system })?.text,
            "Plan mode is not supported by this runtime. Sent as a normal turn instead."
        )

        capturedTurnStartParams.removeAll()
        try await service.sendTurnStart("Try plan mode again", to: threadID, collaborationMode: .plan)

        XCTAssertEqual(capturedTurnStartParams.count, 1)
        XCTAssertNil(capturedTurnStartParams[0].objectValue?["collaborationMode"])
    }

    func testRuntimeSupportsPlanCollaborationModeUsesCollaborationModeList() async {
        let service = makeService()

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "collaborationMode/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "modes": .array([
                        .object(["mode": .string("default")]),
                        .object(["mode": .string("plan")]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let isSupported = await service.runtimeSupportsPlanCollaborationMode()
        XCTAssertTrue(isSupported)
    }

    func testRuntimeSupportsPlanCollaborationModeReturnsFalseWhenPlanMissing() async {
        let service = makeService()

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "collaborationMode/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "modes": .array([
                        .object(["mode": .string("default")]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let isSupported = await service.runtimeSupportsPlanCollaborationMode()
        XCTAssertFalse(isSupported)
    }

    func testPlanModeSendFailureRearmsToggleAndSkipsFallbackRequest() async {
        let service = makeService()
        service.isConnected = true

        var attemptedRequestCount = 0
        service.requestTransportOverride = { _, _ in
            attemptedRequestCount += 1
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        let viewModel = makeViewModel()
        viewModel.input = "Plan this flow"
        viewModel.setPlanModeArmed(true)
        viewModel.sendTurn(codex: service, threadID: "thread-plan-failure")
        await waitForSendCompletion(viewModel)

        XCTAssertEqual(attemptedRequestCount, 0)
        XCTAssertTrue(viewModel.isPlanModeArmed)
        XCTAssertEqual(viewModel.input, "Plan this flow")
        XCTAssertEqual(
            service.lastErrorMessage,
            "Plan mode requires an available model before starting a plan turn."
        )
    }

    func testTurnPlanNotificationsKeepStructuredStateAndFinalText() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "item-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/plan/updated",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "explanation": .string("We should break the work into safe slices."),
                "plan": .array([
                    .object([
                        "step": .string("Audit the current flow"),
                        "status": .string("completed"),
                    ]),
                    .object([
                        "step": .string("Implement the UI toggle"),
                        "status": .string("in_progress"),
                    ]),
                ]),
            ])
        )

        service.handleNotification(
            method: "item/plan/delta",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "delta": .string("1. Audit the current flow\n2. Implement the UI toggle"),
            ])
        )

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("plan"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("1. Audit the current flow\n2. Implement the UI toggle\n3. Add tests"),
                        ]),
                    ]),
                ]),
            ])
        )

        let planMessages = service.messages(for: threadID).filter { $0.kind == .plan }
        XCTAssertEqual(planMessages.count, 1)
        XCTAssertEqual(planMessages[0].text, "1. Audit the current flow\n2. Implement the UI toggle\n3. Add tests")
        XCTAssertEqual(planMessages[0].planState?.explanation, "We should break the work into safe slices.")
        XCTAssertEqual(planMessages[0].planState?.steps.count, 2)
        XCTAssertEqual(planMessages[0].planState?.steps[0].status, .completed)
    }

    func testStructuredUserInputRequestCreatesAndResolvedRemovesPromptCard() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "item-\(UUID().uuidString)"
        let requestID: JSONValue = .string("request-\(UUID().uuidString)")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "itemId": .string(itemID),
                    "questions": .array([
                        .object([
                            "id": .string("mode"),
                            "header": .string("Direction"),
                            "question": .string("Which path should we take?"),
                            "isOther": .bool(false),
                            "isSecret": .bool(false),
                            "options": .array([
                                .object([
                                    "label": .string("Ship it"),
                                    "description": .string("Build the fastest version"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        )

        let promptMessages = service.messages(for: threadID).filter { $0.kind == .userInputPrompt }
        XCTAssertEqual(promptMessages.count, 1)
        XCTAssertEqual(promptMessages[0].structuredUserInputRequest?.questions.first?.header, "Direction")

        service.handleNotification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string(threadID),
                "requestId": requestID,
            ])
        )

        XCTAssertTrue(service.messages(for: threadID).filter { $0.kind == .userInputPrompt }.isEmpty)
    }

    func testStructuredUserInputPromptPersistsAcrossRelaunchUntilResolved() {
        let suiteName = "CodexPlanModeTests.Persistence.\(UUID().uuidString)"
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "item-\(UUID().uuidString)"
        let requestID: JSONValue = .string("request-\(UUID().uuidString)")

        let firstService = makeService(suiteName: suiteName)
        firstService.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "itemId": .string(itemID),
                    "questions": .array([
                        .object([
                            "id": .string("path"),
                            "header": .string("Direction"),
                            "question": .string("Which path should we take?"),
                            "isOther": .bool(false),
                            "isSecret": .bool(false),
                            "options": .array([
                                .object([
                                    "label": .string("Ship it"),
                                    "description": .string("Build the fastest version"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        )

        let relaunchedService = makeService(suiteName: suiteName, reset: false)
        let promptMessages = relaunchedService.messages(for: threadID).filter { $0.kind == .userInputPrompt }
        XCTAssertEqual(promptMessages.count, 1)
        XCTAssertEqual(promptMessages[0].structuredUserInputRequest?.questions.first?.id, "path")
    }

    func testStructuredUserInputPromptWithoutTurnIDStillCreatesPromptCard() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let requestID: JSONValue = .string("request-\(UUID().uuidString)")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(threadID),
                    "questions": .array([
                        .object([
                            "id": .string("path"),
                            "header": .string("Direction"),
                            "question": .string("Which path should we take?"),
                            "isOther": .bool(false),
                            "isSecret": .bool(false),
                            "options": .array([
                                .object([
                                    "label": .string("Ship it"),
                                    "description": .string("Build the fastest version"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        )

        let promptMessages = service.messages(for: threadID).filter { $0.kind == .userInputPrompt }
        XCTAssertEqual(promptMessages.count, 1)
        XCTAssertNil(promptMessages[0].turnId)
    }

    func testTurnStartedDoesNotClearPendingStructuredUserInputPromptBeforeResolution() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let requestID: JSONValue = .string("request-\(UUID().uuidString)")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "questions": .array([
                        .object([
                            "id": .string("path"),
                            "header": .string("Direction"),
                            "question": .string("Which path should we take?"),
                            "isOther": .bool(false),
                            "isSecret": .bool(false),
                            "options": .array([
                                .object([
                                    "label": .string("Ship it"),
                                    "description": .string("Build the fastest version"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        )

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string("turn-\(UUID().uuidString)"),
            ])
        )

        let promptMessages = service.messages(for: threadID).filter { $0.kind == .userInputPrompt }
        XCTAssertEqual(promptMessages.count, 1)
        XCTAssertEqual(promptMessages[0].structuredUserInputRequest?.requestID, requestID)
    }

    func testTurnCompletionDoesNotClearPendingStructuredUserInputPromptBeforeResolution() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let requestID: JSONValue = .string("request-\(UUID().uuidString)")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "questions": .array([
                        .object([
                            "id": .string("path"),
                            "header": .string("Direction"),
                            "question": .string("Which path should we take?"),
                            "isOther": .bool(false),
                            "isSecret": .bool(false),
                            "options": .array([
                                .object([
                                    "label": .string("Ship it"),
                                    "description": .string("Build the fastest version"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        )

        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )

        let promptMessages = service.messages(for: threadID).filter { $0.kind == .userInputPrompt }
        XCTAssertEqual(promptMessages.count, 1)
        XCTAssertEqual(promptMessages[0].structuredUserInputRequest?.requestID, requestID)

        service.handleNotification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string(threadID),
                "requestId": requestID,
            ])
        )

        XCTAssertTrue(service.messages(for: threadID).filter { $0.kind == .userInputPrompt }.isEmpty)
    }

    func testBuildStructuredUserInputResponseMatchesServerShape() {
        let service = makeService()

        let response = service.buildStructuredUserInputResponse(
            answersByQuestionID: [
                "path": ["Ship it"],
                "notes": ["Keep the old composer styling"],
            ]
        )

        let answers = response.objectValue?["answers"]?.objectValue
        XCTAssertEqual(
            answers?["path"]?.objectValue?["answers"]?.arrayValue?.compactMap(\.stringValue),
            ["Ship it"]
        )
        XCTAssertEqual(
            answers?["notes"]?.objectValue?["answers"]?.arrayValue?.compactMap(\.stringValue),
            ["Keep the old composer styling"]
        )
    }

    func testHistoryPlanItemsRestoreStructuredState() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "item-\(UUID().uuidString)"

        let messages = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "createdAt": .double(1_700_000_000),
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string(itemID),
                                "type": .string("plan"),
                                "content": .array([
                                    .object([
                                        "type": .string("text"),
                                        "text": .string("1. Audit\n2. Implement\n3. Verify"),
                                    ]),
                                ]),
                                "explanation": .string("Break the work into safe slices."),
                                "plan": .array([
                                    .object([
                                        "step": .string("Audit"),
                                        "status": .string("completed"),
                                    ]),
                                    .object([
                                        "step": .string("Implement"),
                                        "status": .string("in_progress"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].kind, .plan)
        XCTAssertEqual(messages[0].text, "1. Audit\n2. Implement\n3. Verify")
        XCTAssertEqual(messages[0].planState?.explanation, "Break the work into safe slices.")
        XCTAssertEqual(messages[0].planState?.steps.count, 2)
        XCTAssertEqual(messages[0].planState?.steps.last?.status, .inProgress)
    }

    func testCompletedPlanDoesNotStayPinnedInConversationAccessory() {
        let completedPlan = CodexMessage(
            threadId: "thread-\(UUID().uuidString)",
            role: .system,
            kind: .plan,
            text: "All steps are done.",
            isStreaming: false,
            planState: CodexPlanState(
                explanation: "The plan finished successfully.",
                steps: [
                    CodexPlanStep(step: "Inspect the current behavior", status: .completed),
                    CodexPlanStep(step: "Implement the fix", status: .completed),
                    CodexPlanStep(step: "Verify the result", status: .completed),
                ]
            )
        )

        XCTAssertTrue(completedPlan.isPlanSystemMessage)
        XCTAssertFalse(completedPlan.shouldDisplayPinnedPlanAccessory)
    }

    func testIncompletePlanRemainsPinnedInConversationAccessory() {
        let activePlan = CodexMessage(
            threadId: "thread-\(UUID().uuidString)",
            role: .system,
            kind: .plan,
            text: "Working through the plan.",
            isStreaming: false,
            planState: CodexPlanState(
                explanation: "The plan is still active.",
                steps: [
                    CodexPlanStep(step: "Inspect the current behavior", status: .completed),
                    CodexPlanStep(step: "Implement the fix", status: .inProgress),
                    CodexPlanStep(step: "Verify the result", status: .pending),
                ]
            )
        )

        XCTAssertTrue(activePlan.shouldDisplayPinnedPlanAccessory)
    }

    private func makeService(
        suiteName: String = "CodexPlanModeTests.\(UUID().uuidString)",
        reset: Bool = true
    ) -> CodexService {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if reset {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let service = CodexService(defaults: defaults)
        if reset {
            service.messagesByThread = [:]
        }
        Self.retainedServices.append(service)
        return service
    }

    private func makeViewModel() -> TurnViewModel {
        let viewModel = TurnViewModel()
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }

    private func makeModel() -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5-codex",
            model: "gpt-5-codex",
            displayName: "GPT-5 Codex",
            description: "Test model",
            isDefault: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
            ],
            defaultReasoningEffort: "medium"
        )
    }

    private func waitForSendCompletion(_ viewModel: TurnViewModel) async {
        for _ in 0..<120 {
            if !viewModel.isSending {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected send to complete")
    }
}
