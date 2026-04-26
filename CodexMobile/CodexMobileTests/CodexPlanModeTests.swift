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
        XCTAssertNil(
            capturedTurnStartParams[0]
                .objectValue?["collaborationMode"]?
                .objectValue?["settings"]?
                .objectValue?["developer_instructions"]?
                .stringValue
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

    func testBuildCollaborationModePayloadUsesBuiltInPlanInstructionsByDefault() throws {
        let service = makeService()
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")

        let payload = try service.buildCollaborationModePayload(
            for: .plan,
            threadId: "thread-plan"
        )

        let instructions = payload?
            .objectValue?["settings"]?
            .objectValue?["developer_instructions"]?
            .stringValue
        XCTAssertEqual(payload?.objectValue?["mode"]?.stringValue, "plan")
        XCTAssertNil(instructions)
    }

    func testBuildCollaborationModePayloadUsesCompatibilityInstructionsAfterFallback() throws {
        let service = makeService()
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")
        service.markCompatibilityPlanFallback(for: "thread-plan")

        let payload = try service.buildCollaborationModePayload(
            for: .plan,
            threadId: "thread-plan"
        )

        let instructions = payload?
            .objectValue?["settings"]?
            .objectValue?["developer_instructions"]?
            .stringValue
        XCTAssertEqual(payload?.objectValue?["mode"]?.stringValue, "plan")
        XCTAssertTrue(instructions?.contains("request_user_input") == true)
        XCTAssertTrue(instructions?.contains("<proposed_plan>") == true)
    }

    func testRequestedPlanSessionStaysNativeFirstWithoutCompatibilityInstructions() throws {
        let service = makeService()
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")
        service.markRequestedPlanSession(for: "thread-plan")

        let payload = try service.buildCollaborationModePayload(
            for: .plan,
            threadId: "thread-plan"
        )

        let instructions = payload?
            .objectValue?["settings"]?
            .objectValue?["developer_instructions"]?
            .stringValue
        XCTAssertNil(instructions)
        XCTAssertTrue(service.allowsInferredPlanQuestionnaireFallback(for: "thread-plan"))
        XCTAssertTrue(service.allowsAssistantPlanFallbackRecovery(for: "thread-plan"))
    }

    func testCompatibilityFallbackCanOverrideNativePlanThread() {
        let service = makeService()

        service.markNativePlanSession(for: "thread-plan")
        XCTAssertTrue(service.currentPlanSessionSource(for: "thread-plan")?.isNative == true)

        service.markCompatibilityPlanFallback(for: "thread-plan")

        XCTAssertEqual(service.currentPlanSessionSource(for: "thread-plan"), .compatibilityFallback)
    }

    func testAssistantFallbackRecoveryRemainsAvailableForNativePlanThread() {
        let service = makeService()

        service.markNativePlanSession(for: "thread-plan")

        XCTAssertFalse(service.allowsInferredPlanQuestionnaireFallback(for: "thread-plan"))
        XCTAssertTrue(service.allowsAssistantPlanFallbackRecovery(for: "thread-plan"))
    }

    func testPlanSessionSourcePersistsAcrossRelaunch() {
        let suiteName = "CodexPlanModeTests.Persistence.PlanSource.\(UUID().uuidString)"
        let firstService = makeService(suiteName: suiteName, reset: true)
        firstService.markCompatibilityPlanFallback(for: "thread-plan")

        let relaunchedService = makeService(suiteName: suiteName, reset: false)

        XCTAssertEqual(
            relaunchedService.currentPlanSessionSource(for: "thread-plan"),
            .compatibilityFallback
        )
    }

    func testCompatibilityFallbackStaysStickyAcrossNewPlanTurnStarts() async throws {
        let service = makeService()
        service.isConnected = true
        service.supportsTurnCollaborationMode = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")
        service.markCompatibilityPlanFallback(for: "thread-plan")

        var capturedTurnStartParams: JSONValue?
        service.requestTransportOverride = { method, params in
            if method == "turn/start" {
                capturedTurnStartParams = params
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "turn": .object([
                            "id": .string("turn-live"),
                            "status": .string("inProgress"),
                            "items": .array([]),
                            "error": .null,
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        try await service.startTurn(
            userInput: "Keep planning",
            threadId: "thread-plan",
            shouldAppendUserMessage: false,
            collaborationMode: .plan
        )

        let instructions = capturedTurnStartParams?
            .objectValue?["collaborationMode"]?
            .objectValue?["settings"]?
            .objectValue?["developer_instructions"]?
            .stringValue

        XCTAssertEqual(service.currentPlanSessionSource(for: "thread-plan"), .compatibilityFallback)
        XCTAssertTrue(instructions?.contains("request_user_input") == true)
    }

    func testSubmittingInferredQuestionnaireDoesNotDowngradeConfirmedNativePlanThread() async throws {
        let service = makeService()
        service.isConnected = true
        service.supportsTurnCollaborationMode = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")
        service.markNativePlanSession(for: "thread-plan")

        var capturedTurnSteerParams: JSONValue?
        service.requestTransportOverride = { method, params in
            if method == "turn/steer" {
                capturedTurnSteerParams = params
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-live")]),
                    includeJSONRPC: false
                )
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        service.setActiveTurnID("turn-live", for: "thread-plan")

        try await service.submitInferredPlanQuestionnaireResponse(
            threadId: "thread-plan",
            questions: [
                CodexStructuredUserInputQuestion(
                    id: "scope",
                    header: "Scope",
                    question: "What scope should we use?",
                    options: [
                        CodexStructuredUserInputOption(label: "Ship now", description: nil),
                        CodexStructuredUserInputOption(label: "Stage behind a flag", description: nil),
                    ],
                    allowsMultiple: false
                ),
            ],
            answersByQuestionID: [
                "scope": ["Ship now"],
            ]
        )

        XCTAssertTrue(capturedTurnSteerParams != nil)
        XCTAssertTrue(service.currentPlanSessionSource(for: "thread-plan")?.isNative == true)
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
        XCTAssertNil(service.currentPlanSessionSource(for: threadID))
        XCTAssertEqual(
            service.messages(for: threadID).last(where: { $0.role == .system })?.text,
            "Plan mode is not supported by this runtime. Sent as a normal turn instead."
        )

        capturedTurnStartParams.removeAll()
        try await service.sendTurnStart("Try plan mode again", to: threadID, collaborationMode: .plan)

        XCTAssertEqual(capturedTurnStartParams.count, 1)
        XCTAssertNil(capturedTurnStartParams[0].objectValue?["collaborationMode"])
        XCTAssertNil(service.currentPlanSessionSource(for: threadID))
    }

    func testPlanSessionStateMigratesToContinuationThread() async throws {
        let service = makeService()
        service.supportsTurnCollaborationMode = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")

        let archivedThreadID = "thread-archived"
        let continuationThreadID = "thread-continuation"

        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/resume":
                let threadId = params?.objectValue?["threadId"]?.stringValue
                if threadId == archivedThreadID {
                    throw CodexServiceError.rpcError(
                        RPCError(code: -32000, message: "thread not found")
                    )
                }
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(threadId ?? continuationThreadID),
                        ]),
                    ]),
                    includeJSONRPC: false
                )

            case "thread/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string(continuationThreadID),
                        ]),
                    ]),
                    includeJSONRPC: false
                )

            case "turn/start":
                XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, continuationThreadID)
                XCTAssertEqual(
                    params?.objectValue?["collaborationMode"]?.objectValue?["mode"]?.stringValue,
                    "plan"
                )
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-live")]),
                    includeJSONRPC: false
                )

            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), includeJSONRPC: false)
            }
        }

        try await service.startTurn(
            userInput: "Plan this continuation",
            threadId: archivedThreadID,
            collaborationMode: .plan
        )

        XCTAssertNil(service.currentPlanSessionSource(for: archivedThreadID))
        XCTAssertEqual(service.currentPlanSessionSource(for: continuationThreadID), .requested)
    }

    func testNonPlanSteerClearsStalePlanSessionState() async throws {
        let service = makeService()
        let threadID = "thread-plan"
        let turnID = "turn-live"

        service.markCompatibilityPlanFallback(for: threadID)
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/steer")
            XCTAssertEqual(params?.objectValue?["threadId"]?.stringValue, threadID)
            XCTAssertNil(params?.objectValue?["collaborationMode"])
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string(turnID)]),
                includeJSONRPC: false
            )
        }

        try await service.steerTurn(
            userInput: "Normal follow-up",
            threadId: threadID,
            expectedTurnId: turnID,
            collaborationMode: nil
        )

        XCTAssertNil(service.currentPlanSessionSource(for: threadID))
    }

    func testImplementProposedPlanSteerExplicitlyReturnsToDefaultMode() async throws {
        let service = makeService()
        service.supportsTurnCollaborationMode = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")

        let threadID = "thread-plan"
        let turnID = "turn-live"
        service.markNativePlanSession(for: threadID)
        service.setActiveTurnID(turnID, for: threadID)

        var capturedTurnSteerParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/steer")
            capturedTurnSteerParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string(turnID)]),
                includeJSONRPC: false
            )
        }

        try await service.implementProposedPlan(
            threadId: threadID,
            proposedPlan: CodexProposedPlan(body: "1. Ship it")
        )

        XCTAssertEqual(
            capturedTurnSteerParams?
                .objectValue?["collaborationMode"]?
                .objectValue?["mode"]?
                .stringValue,
            CodexCollaborationModeKind.default.rawValue
        )
        XCTAssertNil(service.currentPlanSessionSource(for: threadID))
    }

    func testImplementProposedPlanStartExplicitlyReturnsToDefaultMode() async throws {
        let service = makeService()
        service.supportsTurnCollaborationMode = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")

        let threadID = "thread-plan"
        service.markNativePlanSession(for: threadID)

        var capturedTurnStartParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedTurnStartParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-implement")]),
                includeJSONRPC: false
            )
        }

        try await service.implementProposedPlan(
            threadId: threadID,
            proposedPlan: CodexProposedPlan(body: "1. Ship it")
        )

        XCTAssertEqual(
            capturedTurnStartParams?
                .objectValue?["collaborationMode"]?
                .objectValue?["mode"]?
                .stringValue,
            CodexCollaborationModeKind.default.rawValue
        )
        XCTAssertNil(service.currentPlanSessionSource(for: threadID))
    }

    func testRuntimeSupportsPlanCollaborationModeUsesOfficialCollaborationModeListShape() async {
        let service = makeService()

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "collaborationMode/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([
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

    func testRuntimeSupportsPlanCollaborationModeReturnsFalseWhenPlanMissingFromOfficialShape() async {
        let service = makeService()

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "collaborationMode/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([
                        .object(["mode": .string("default")]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let isSupported = await service.runtimeSupportsPlanCollaborationMode()
        XCTAssertFalse(isSupported)
    }

    func testRuntimeSupportsPlanCollaborationModeStillAcceptsLegacyModesShape() async {
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
                        "status": .string("inProgress"),
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
        XCTAssertEqual(planMessages[0].planState?.steps[1].status, .inProgress)
    }

    func testTurnPlanUpdatedWithoutThreadIDUsesTurnMapping() {
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
            method: "turn/plan/updated",
            params: .object([
                "turnId": .string(turnID),
                "explanation": .string("Use the stored turn mapping when threadId is omitted."),
                "plan": .array([
                    .object([
                        "step": .string("Keep the clarification UI native"),
                        "status": .string("inProgress"),
                    ]),
                ]),
            ])
        )

        let planMessages = service.messages(for: threadID).filter { $0.kind == .plan }
        XCTAssertEqual(planMessages.count, 1)
        XCTAssertEqual(planMessages[0].planState?.steps.first?.status, .inProgress)
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

    func testToolRequestUserInputMethodCreatesPromptCard() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let requestID: JSONValue = .string("request-\(UUID().uuidString)")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "tool/requestUserInput",
                params: .object([
                    "threadId": .string(threadID),
                    "questions": .array([
                        .object([
                            "id": .string("path"),
                            "header": .string("Direction"),
                            "question": .string("Which path should we take?"),
                            "isOther": .bool(true),
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
        XCTAssertEqual(promptMessages[0].structuredUserInputRequest?.questions.first?.id, "path")
        XCTAssertEqual(promptMessages[0].structuredUserInputRequest?.questions.first?.isOther, true)
    }

    func testToolRequestUserInputWithoutThreadIDUsesTurnMapping() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let requestID: JSONValue = .string("request-\(UUID().uuidString)")

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "tool/requestUserInput",
                params: .object([
                    "turnId": .string(turnID),
                    "questions": .array([
                        .object([
                            "id": .string("path"),
                            "header": .string("Direction"),
                            "question": .string("Which path should we take?"),
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
        XCTAssertEqual(promptMessages[0].turnId, turnID)
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

    func testCancelStructuredPlanSessionInterruptsTurnAndClearsPromptState() async throws {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let requestID: JSONValue = .string("request-\(UUID().uuidString)")
        let secondRequestID: JSONValue = .string("request-\(UUID().uuidString)")

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
        service.handleIncomingRPCMessage(
            RPCMessage(
                id: secondRequestID,
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "questions": .array([
                        .object([
                            "id": .string("scope"),
                            "header": .string("Scope"),
                            "question": .string("Do we keep the old flow too?"),
                            "options": .array([
                                .object([
                                    "label": .string("Yes"),
                                    "description": .string("Keep both for now"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        )
        service.markNativePlanSession(for: threadID)

        var interruptParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/interrupt")
            interruptParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([:]),
                includeJSONRPC: false
            )
        }

        try await service.cancelStructuredPlanSession(
            requestID: requestID,
            turnId: turnID,
            threadId: threadID
        )

        XCTAssertEqual(interruptParams?.objectValue?["turnId"]?.stringValue, turnID)
        XCTAssertEqual(interruptParams?.objectValue?["threadId"]?.stringValue, threadID)
        XCTAssertTrue(service.messages(for: threadID).filter { $0.kind == .userInputPrompt }.isEmpty)
        XCTAssertNil(service.currentPlanSessionSource(for: threadID))
    }

    func testCancelStructuredPlanSessionFailurePreservesPromptState() async {
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
                            "id": .string("scope"),
                            "header": .string("Scope"),
                            "question": .string("Do we keep the old flow too?"),
                            "options": .array([
                                .object([
                                    "label": .string("Yes"),
                                    "description": .string("Keep both for now"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        )
        service.markNativePlanSession(for: threadID)

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "turn/interrupt")
            throw CodexServiceError.disconnected
        }

        do {
            try await service.cancelStructuredPlanSession(
                requestID: requestID,
                turnId: turnID,
                threadId: threadID
            )
            XCTFail("Expected cancelStructuredPlanSession to throw")
        } catch let error as CodexServiceError {
            XCTAssertEqual(error, .disconnected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(service.messages(for: threadID).filter { $0.kind == .userInputPrompt }.count, 1)
        XCTAssertEqual(service.currentPlanSessionSource(for: threadID), .native)
    }

    func testDismissStructuredPlanPromptFailureKeepsPromptVisible() async {
        let service = makeService()
        let viewModel = makeViewModel()
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
                            "id": .string("scope"),
                            "header": .string("Scope"),
                            "question": .string("Do we keep the old flow too?"),
                            "options": .array([
                                .object([
                                    "label": .string("Yes"),
                                    "description": .string("Keep both for now"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        )
        service.markNativePlanSession(for: threadID)

        guard let promptMessage = service.messages(for: threadID).last(where: { $0.kind == .userInputPrompt }) else {
            XCTFail("Expected a structured prompt message")
            return
        }

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "turn/interrupt")
            throw CodexServiceError.disconnected
        }

        viewModel.dismissStructuredPlanPrompt(promptMessage, codex: service, threadID: threadID)
        await waitForStructuredPromptDismissCompletion(
            viewModel,
            requestID: requestID,
            codex: service
        )

        XCTAssertFalse(viewModel.isStructuredPlanPromptDismissed(requestID, codex: service))
        XCTAssertFalse(viewModel.isStructuredPlanPromptDismissing(requestID, codex: service))
        XCTAssertEqual(service.messages(for: threadID).filter { $0.kind == .userInputPrompt }.count, 1)
        XCTAssertEqual(service.currentPlanSessionSource(for: threadID), .native)
        XCTAssertEqual(service.lastErrorMessage, service.userFacingTurnErrorMessage(from: CodexServiceError.disconnected))
    }

    func testResolvedInferredPlanQuestionnairePrefersMatchingNativePrompt() {
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let assistantMessage = CodexMessage(
            threadId: threadID,
            role: .assistant,
            text: """
            I have one question for you before I finalize the plan:

            1. Which path should we take?
            - Ship it
            - Stage it
            """,
            turnId: turnID
        )
        let nativePrompt = CodexMessage(
            threadId: threadID,
            role: .system,
            kind: .userInputPrompt,
            text: "Direction\nWhich path should we take?",
            turnId: turnID,
            structuredUserInputRequest: CodexStructuredUserInputRequest(
                requestID: .string("request-\(UUID().uuidString)"),
                questions: [
                    CodexStructuredUserInputQuestion(
                        id: "direction",
                        header: "Direction",
                        question: "Which path should we take?",
                        isOther: false,
                        isSecret: false,
                        options: [
                            CodexStructuredUserInputOption(label: "Ship it", description: "Build the fastest version"),
                            CodexStructuredUserInputOption(label: "Stage it", description: "Ship in smaller slices"),
                        ]
                    ),
                ]
            )
        )

        let questionnaire = resolvedInferredPlanQuestionnaire(
            bodyText: assistantMessage.text,
            message: assistantMessage,
            threadMessages: [assistantMessage, nativePrompt],
            parse: InferredPlanQuestionnaireParser.parseAssistantMessage
        )

        XCTAssertNil(questionnaire)
    }

    func testAssistantFallbackQuestionnaireWithoutCueStillParses() {
        let text = """
        1. Which rollout path should we take?
        - Ship it now
        - Stage it behind a flag

        2. Which validation level do you want?
        - Smoke test only
        - Add focused regression coverage
        """

        let questionnaire = InferredPlanQuestionnaireParser.parseAssistantMessage(text)

        XCTAssertEqual(questionnaire?.questions.count, 2)
        XCTAssertEqual(
            questionnaire?.questions.first?.options.map(\.label),
            ["Ship it now", "Stage it behind a flag"]
        )
    }

    func testAssistantFallbackQuestionnaireWithMarkdownNumberingParses() {
        let text = """
        A few quick questions before I finalize the plan:

        **1. Which rollout path should we take?**
        - Ship it now
        - Stage it behind a flag
        """

        let questionnaire = InferredPlanQuestionnaireParser.parseAssistantMessage(text)

        XCTAssertEqual(questionnaire?.questions.count, 1)
        XCTAssertEqual(questionnaire?.questions.first?.question, "Which rollout path should we take?")
        XCTAssertEqual(
            questionnaire?.questions.first?.options.map(\.label),
            ["Ship it now", "Stage it behind a flag"]
        )
    }

    func testAssistantFallbackChoiceListParsesIntoSingleQuestion() {
        let text = """
        My strongest recommendation is to focus on trust first.

        If you want, next I can turn this into one of these:

        1. a prioritized roadmap for the next 2-4 weeks
        2. a feature matrix with quick wins vs bigger bets
        3. a concrete implementation plan mapped to the current codebase
        """

        let questionnaire = InferredPlanQuestionnaireParser.parseAssistantMessage(text)

        XCTAssertEqual(questionnaire?.questions.count, 1)
        XCTAssertEqual(questionnaire?.questions.first?.header, "Next step")
        XCTAssertEqual(questionnaire?.questions.first?.question, "What should Codex produce next?")
        XCTAssertEqual(
            questionnaire?.questions.first?.options.map(\.label),
            [
                "a prioritized roadmap for the next 2-4 weeks",
                "a feature matrix with quick wins vs bigger bets",
                "a concrete implementation plan mapped to the current codebase",
            ]
        )
    }

    func testResolvedFallbackChoiceListStillAppearsAfterNativeThreadDegradesToPlainText() {
        let assistantMessage = CodexMessage(
            role: .assistant,
            text: """
            Suggested Roadmap If we wanted a practical sequence, I'd do:

            1. Polish onboarding and first-run UX
            2. Improve status clarity and calibration experience
            3. Expand actions beyond open app

            If you want, next I can turn this into one of these:

            1. a concrete 2-week roadmap
            2. a feature-priority matrix
            3. a "v1 vs v2" product strategy doc
            """,
            threadId: "thread-plan",
            turnId: "turn-plan",
            orderIndex: 3
        )

        let questionnaire = resolvedInferredPlanQuestionnaire(
            bodyText: assistantMessage.text,
            message: assistantMessage,
            threadMessages: [assistantMessage],
            parse: InferredPlanQuestionnaireParser.parseAssistantMessage
        )

        XCTAssertEqual(questionnaire?.questions.count, 1)
        XCTAssertEqual(questionnaire?.questions.first?.header, "Next step")
        XCTAssertEqual(
            questionnaire?.questions.first?.options.map(\.label),
            [
                "a concrete 2-week roadmap",
                "a feature-priority matrix",
                "a \"v1 vs v2\" product strategy doc",
            ]
        )
    }

    func testResolvedFallbackChoiceListDoesNotAppearOutsidePlanModeSession() {
        let assistantMessage = CodexMessage(
            role: .assistant,
            text: """
            If you want, next I can turn this into one of these:

            1. a concrete 2-week roadmap
            2. a feature-priority matrix
            3. a "v1 vs v2" product strategy doc
            """,
            threadId: "thread-default",
            turnId: "turn-default",
            orderIndex: 3
        )

        let questionnaire = resolvedInferredPlanQuestionnaire(
            bodyText: assistantMessage.text,
            message: assistantMessage,
            threadMessages: [assistantMessage],
            shouldRecoverFallback: false,
            parse: InferredPlanQuestionnaireParser.parseAssistantMessage
        )

        XCTAssertNil(questionnaire)
    }

    func testResolvedFallbackChoiceListDoesNotAppearAfterNativePlanSessionIsConfirmed() {
        let service = makeService()
        service.markNativePlanSession(for: "thread-native")

        let assistantMessage = CodexMessage(
            role: .assistant,
            text: """
            If you want, next I can turn this into one of these:

            1. a concrete 2-week roadmap
            2. a feature-priority matrix
            3. a "v1 vs v2" product strategy doc
            """,
            threadId: "thread-native",
            turnId: "turn-native",
            orderIndex: 3
        )

        let questionnaire = resolvedInferredPlanQuestionnaire(
            bodyText: assistantMessage.text,
            message: assistantMessage,
            threadMessages: [assistantMessage],
            shouldRecoverFallback: service.allowsAssistantPlanFallbackRecovery(for: "thread-native"),
            parse: InferredPlanQuestionnaireParser.parseAssistantMessage
        )

        XCTAssertNil(questionnaire)
    }

    func testProposedPlanParserExtractsBodyAndRemovesEnvelope() {
        let rawText = """
        I explored the current flow and here is the final plan.

        <proposed_plan>
        ## Summary
        - Make native structured questions the primary path.
        - Render final plan blocks with an implementation action.
        </proposed_plan>
        """

        let proposedPlan = CodexProposedPlanParser.parse(from: rawText)

        XCTAssertEqual(
            proposedPlan?.body,
            """
            ## Summary
            - Make native structured questions the primary path.
            - Render final plan blocks with an implementation action.
            """
        )
        XCTAssertEqual(
            CodexProposedPlanParser.removingEnvelope(from: rawText),
            "I explored the current flow and here is the final plan."
        )
        XCTAssertEqual(
            proposedPlan?.summary,
            "Summary"
        )
    }

    func testImplementProposedPlanUsesMinimalThreadReferencePrompt() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5-codex")

        var capturedParams: JSONValue?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedParams = params
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-live")]),
                includeJSONRPC: false
            )
        }

        try await service.implementProposedPlan(
            threadId: "thread-plan",
            proposedPlan: CodexProposedPlan(
                body: """
                ## Summary
                - Make Plan Mode native-first.
                """
            )
        )

        XCTAssertEqual(
            textInput(from: capturedParams),
            "Implement the latest approved plan from the most recent <proposed_plan> in this thread."
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
                                        "status": .string("inProgress"),
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

    func testCompletedHistoryTurnFinalizesPlanSteps() {
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
                        "status": .string("completed"),
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
                                    .object([
                                        "step": .string("Verify"),
                                        "status": .string("pending"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].planState?.steps.map(\.status), [.completed, .completed, .completed])
        XCTAssertFalse(messages[0].shouldDisplayPinnedPlanAccessory)
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
        XCTAssertFalse(completedPlan.shouldDisplayInlinePlanResult)
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

    func testCompletedSystemPlanWithEmbeddedProposedPlanDoesNotMasqueradeAsFinalPlan() {
        let completedPlan = CodexMessage(
            threadId: "thread-\(UUID().uuidString)",
            role: .system,
            kind: .plan,
            text: """
            <proposed_plan>
            ## Ship
            - Tighten native Plan Mode first.
            </proposed_plan>
            """,
            isStreaming: false,
            planState: CodexPlanState(
                explanation: "The plan is finalized.",
                steps: [
                    CodexPlanStep(step: "Inspect the current behavior", status: .completed),
                    CodexPlanStep(step: "Implement the fix", status: .completed),
                ]
            )
        )

        XCTAssertFalse(completedPlan.shouldDisplayInlinePlanResult)
        XCTAssertNil(completedPlan.proposedPlan)
    }

    func testAssistantProposedPlanStaysSeparateFromSystemStepPlan() {
        let finalAssistantPlan = CodexMessage(
            threadId: "thread-\(UUID().uuidString)",
            role: .assistant,
            text: """
            <proposed_plan>
            ## Ship
            - Tighten native Plan Mode first.
            </proposed_plan>
            """,
            isStreaming: false
        )

        XCTAssertEqual(finalAssistantPlan.proposedPlan?.summary, "Ship")
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

    private func waitForStructuredPromptDismissCompletion(
        _ viewModel: TurnViewModel,
        requestID: JSONValue,
        codex: CodexService
    ) async {
        for _ in 0..<120 {
            if !viewModel.isStructuredPlanPromptDismissing(requestID, codex: codex) {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected structured prompt dismiss to complete")
    }

    private func textInput(from params: JSONValue?) -> String? {
        params?
            .objectValue?["input"]?
            .arrayValue?
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "text" })?["text"]?
            .stringValue
    }
}
