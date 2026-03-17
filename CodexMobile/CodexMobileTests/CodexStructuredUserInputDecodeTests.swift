// FILE: CodexStructuredUserInputDecodeTests.swift
// Purpose: Verifies history/live decoders reconstruct `$skill` tokens from structured input items.
// Layer: Unit Test
// Exports: CodexStructuredUserInputDecodeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexStructuredUserInputDecodeTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testDecodeItemTextReconstructsSkillMentionsFromStructuredInput() {
        let service = makeService()
        let itemObject: [String: JSONValue] = [
            "content": .array([
                .object([
                    "type": .string("skill"),
                    "id": .string("review"),
                ]),
                .object([
                    "type": .string("text"),
                    "text": .string("please check latest changes"),
                ]),
            ]),
        ]

        let decoded = service.decodeItemText(from: itemObject)

        XCTAssertEqual(decoded, "$review\nplease check latest changes")
    }

    func testExtractIncomingMessageTextReconstructsSkillMentionsFromStructuredInput() {
        let service = makeService()
        let itemObject: [String: JSONValue] = [
            "content": .array([
                .object([
                    "type": .string("skill"),
                    "name": .string("check-code"),
                ]),
                .object([
                    "type": .string("text"),
                    "text": .string("run the audit"),
                ]),
            ]),
        ]

        let decoded = service.extractIncomingMessageText(from: itemObject)

        XCTAssertEqual(decoded, "$check-code\nrun the audit")
    }

    func testDecodeSubagentActionItemBuildsAgentRows() {
        let service = makeService()
        let itemObject: [String: JSONValue] = [
            "type": .string("collabAgentToolCall"),
            "tool": .string("spawnAgent"),
            "status": .string("in_progress"),
            "prompt": .string("Explore the repo"),
            "receiverThreadIds": .array([
                .string("thread-abc"),
                .string("thread-def"),
            ]),
            "receiverAgents": .array([
                .object([
                    "threadId": .string("thread-abc"),
                    "agentId": .string("agent-1"),
                    "agentNickname": .string("Locke"),
                    "agentRole": .string("explorer"),
                    "model": .string("gpt-5.4"),
                ]),
                .object([
                    "threadId": .string("thread-def"),
                    "agentId": .string("agent-2"),
                    "agentNickname": .string("Dalton"),
                    "agentRole": .string("worker"),
                    "modelProvider": .string("gpt-5.3-codex"),
                ]),
            ]),
            "agentsStates": .object([
                "thread-abc": .object([
                    "status": .string("running"),
                    "message": .string("Scanning modules"),
                ]),
                "thread-def": .object([
                    "status": .string("completed"),
                ]),
            ]),
        ]

        let decoded = service.decodeSubagentActionItem(from: itemObject)

        XCTAssertEqual(decoded?.summaryText, "Spawning 2 agents")
        XCTAssertEqual(decoded?.agentRows.count, 2)
        XCTAssertEqual(decoded?.agentRows.first?.displayLabel, "Locke [explorer]")
        XCTAssertEqual(decoded?.agentRows.first?.model, "gpt-5.4")
        XCTAssertEqual(decoded?.agentRows.first?.fallbackStatus, "running")
        XCTAssertEqual(decoded?.agentRows.first?.fallbackMessage, "Scanning modules")
        XCTAssertEqual(decoded?.agentRows.last?.model, "gpt-5.3-codex")
    }

    func testDecodeSubagentActionItemIgnoresGenericTypeWhenResolvingRole() {
        let service = makeService()
        let itemObject: [String: JSONValue] = [
            "type": .string("collabToolCall"),
            "tool": .string("wait"),
            "status": .string("in_progress"),
            "receiverThreadId": .string("thread-locke"),
            "newAgentNickname": .string("Locke"),
            "agentType": .string("explorer"),
        ]

        let decoded = service.decodeSubagentActionItem(from: itemObject)

        XCTAssertEqual(decoded?.agentRows.first?.displayLabel, "Locke [explorer]")
    }

    func testDecodeSubagentActionItemDoesNotUseTopLevelNameAsAgentNickname() {
        let service = makeService()
        let itemObject: [String: JSONValue] = [
            "type": .string("collabAgentToolCall"),
            "tool": .string("spawnAgent"),
            "status": .string("in_progress"),
            "receiverThreadId": .string("thread-nash"),
            "newAgentRole": .string("explorer"),
            "name": .string("Review the latest unstaged git changes"),
        ]

        let decoded = service.decodeSubagentActionItem(from: itemObject)

        XCTAssertEqual(decoded?.agentRows.first?.displayLabel, "Explorer")
    }

    func testResolvedSubagentPresentationReusesIdentityAcrossSparseFollowUpEvents() {
        let service = makeService()
        let spawnItem: [String: JSONValue] = [
            "type": .string("collabAgentToolCall"),
            "tool": .string("spawnAgent"),
            "status": .string("completed"),
            "receiverThreadId": .string("thread-nash"),
            "newAgentNickname": .string("Nash"),
            "newAgentRole": .string("explorer"),
        ]
        let waitItem: [String: JSONValue] = [
            "type": .string("collabAgentToolCall"),
            "tool": .string("wait"),
            "status": .string("in_progress"),
            "receiverThreadId": .string("thread-nash"),
        ]

        let spawnAction = service.decodeSubagentActionItem(from: spawnItem)
        XCTAssertEqual(spawnAction?.agentRows.first?.displayLabel, "Nash [explorer]")

        let waitAction = service.decodeSubagentActionItem(from: waitItem)
        let resolved = waitAction.map { action in
            service.resolvedSubagentPresentation(action.agentRows[0], parentThreadId: "parent-thread")
        }

        XCTAssertEqual(resolved?.displayLabel, "Nash [explorer]")
    }

    func testResolvedSubagentPresentationPrefersChildThreadIdentity() {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "thread-nash",
                parentThreadId: "parent-thread",
                agentNickname: "Nash",
                agentRole: "explorer"
            )
        )

        let generic = CodexSubagentThreadPresentation(
            threadId: "thread-nash",
            agentId: nil,
            nickname: nil,
            role: nil,
            model: nil,
            modelIsRequestedHint: false,
            prompt: "Review the latest unstaged git changes",
            fallbackStatus: "running",
            fallbackMessage: nil
        )

        let resolved = service.resolvedSubagentPresentation(generic, parentThreadId: "parent-thread")

        XCTAssertEqual(resolved.displayLabel, "Nash [explorer]")
    }

    func testDecodeSubagentActionItemFallsBackToTopLevelRequestedModel() {
        let service = makeService()
        let itemObject: [String: JSONValue] = [
            "type": .string("collabAgentToolCall"),
            "tool": .string("spawnAgent"),
            "status": .string("completed"),
            "prompt": .string("Inspect the parser"),
            "model": .string("gpt-5.3-codex-spark"),
            "receiverThreadIds": .array([
                .string("thread-child-1"),
            ]),
            "agentsStates": .object([
                "thread-child-1": .object([
                    "status": .string("pending_init"),
                ]),
            ]),
        ]

        let decoded = service.decodeSubagentActionItem(from: itemObject)

        XCTAssertEqual(decoded?.model, "gpt-5.3-codex-spark")
        XCTAssertEqual(decoded?.agentRows.count, 1)
        XCTAssertEqual(decoded?.agentRows.first?.threadId, "thread-child-1")
        XCTAssertEqual(decoded?.agentRows.first?.model, "gpt-5.3-codex-spark")
        XCTAssertEqual(decoded?.agentRows.first?.modelIsRequestedHint, true)
        XCTAssertEqual(decoded?.agentRows.first?.fallbackStatus, "pending_init")
    }

    func testResolvedSubagentPresentationPrefersRealChildThreadModelOverRequestedHint() {
        let service = makeService()
        let requestedOnly = CodexSubagentThreadPresentation(
            threadId: "thread-child-1",
            agentId: nil,
            nickname: "Locke",
            role: "explorer",
            model: "gpt-5.3-codex-spark",
            modelIsRequestedHint: true,
            prompt: "Inspect the parser",
            fallbackStatus: "pending_init",
            fallbackMessage: nil
        )
        service.upsertThread(
            CodexThread(
                id: "thread-child-1",
                parentThreadId: "thread-parent",
                agentNickname: "Locke",
                agentRole: "explorer",
                model: "gpt-5.4",
                modelProvider: "gpt-5.4"
            )
        )

        let resolved = service.resolvedSubagentPresentation(
            requestedOnly,
            parentThreadId: "thread-parent"
        )

        XCTAssertEqual(resolved.model, "gpt-5.4")
        XCTAssertEqual(resolved.modelIsRequestedHint, false)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexStructuredUserInputDecodeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]

        Self.retainedServices.append(service)
        return service
    }
}
