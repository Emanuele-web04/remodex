// FILE: CodexServiceRemodexEventAdapterTests.swift
// Purpose: Verifies runtime-neutral Remodex bridge events route through existing timeline handlers.
// Layer: Unit Test
// Exports: CodexServiceRemodexEventAdapterTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceRemodexEventAdapterTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testRawCodexEventWireIngressIsDropped() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.handleIncomingRPCMessage(RPCMessage(
            method: "codex/event/user_message",
            params: .object([
                "threadId": .string(threadID),
                "message": .string("Should not appear"),
            ])
        ))

        XCTAssertTrue(service.messages(for: threadID).isEmpty)
    }

    func testCanonicalTurnAndAssistantDeltaUseExistingTimelinePipeline() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "assistant-\(UUID().uuidString)"

        service.handleIncomingRPCMessage(canonicalEvent(
            type: "turn_started",
            threadID: threadID,
            turnID: turnID
        ))
        service.handleIncomingRPCMessage(canonicalEvent(
            type: "assistant_delta",
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            payload: ["delta": .string("Hello from Cursor")]
        ))
        service.flushAllPendingStreamingDeltas()

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
        XCTAssertEqual(service.activeTurnID(for: threadID), turnID)
        XCTAssertEqual(service.messages(for: threadID).first?.text, "Hello from Cursor")
        XCTAssertEqual(service.messages(for: threadID).first?.role, .assistant)
    }

    func testCanonicalReasoningDiffAndCompletionRouteToExistingHandlers() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let reasoningID = "reasoning-\(UUID().uuidString)"

        service.handleIncomingRPCMessage(canonicalEvent(
            type: "turn_started",
            threadID: threadID,
            turnID: turnID
        ))
        service.handleIncomingRPCMessage(canonicalEvent(
            type: "assistant_delta",
            threadID: threadID,
            turnID: turnID,
            itemID: reasoningID,
            payload: ["reasoning": .string("Checking files")]
        ))
        service.handleIncomingRPCMessage(canonicalEvent(
            type: "diff_updated",
            threadID: threadID,
            turnID: turnID,
            payload: ["diff": .string("diff --git a/a.txt b/a.txt\n")]
        ))
        service.handleIncomingRPCMessage(canonicalEvent(
            type: "turn_completed",
            threadID: threadID,
            turnID: turnID,
            payload: ["status": .string("completed")]
        ))
        service.flushAllPendingStreamingDeltas()

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .ready)
        XCTAssertTrue(service.messages(for: threadID).contains { $0.kind == .thinking && $0.text.contains("Checking files") })
    }

    func testCanonicalErrorMarksTurnFailed() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleIncomingRPCMessage(canonicalEvent(
            type: "turn_started",
            threadID: threadID,
            turnID: turnID
        ))
        service.handleIncomingRPCMessage(canonicalEvent(
            type: "error",
            threadID: threadID,
            turnID: turnID,
            payload: ["message": .string("Cursor failed")]
        ))

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .failed)
        XCTAssertEqual(service.lastErrorMessage, "Cursor failed")
    }

    func testCanonicalPermissionRequestQueuesExistingApprovalPrompt() {
        let service = makeService()
        let requestID: JSONValue = .string("cursor-permission-1")

        service.handleIncomingRPCMessage(RPCMessage(
            id: requestID,
            method: "remodex/request/permission",
            params: .object([
                "agentRuntime": .string("cursor"),
                "threadId": .string("thread-cursor"),
                "turnId": .string("turn-cursor"),
                "permissionId": .string("perm-1"),
                "payload": .object([
                    "sourceMethod": .string("permission/request"),
                    "request": .object([
                        "toolName": .string("shell"),
                        "reason": .string("Run git status"),
                        "permissions": .object([
                            "shell": .bool(true),
                        ]),
                    ]),
                ]),
            ])
        ))

        let approval = service.pendingApproval(for: "thread-cursor")
        XCTAssertEqual(approval?.id, service.idKey(from: requestID))
        XCTAssertEqual(approval?.method, "item/permissions/requestApproval")
        XCTAssertEqual(approval?.reason, "Run git status")
        XCTAssertEqual(approval?.params?.objectValue?["permissions"]?.objectValue?["shell"]?.boolValue, true)
    }

    func testRuntimeInventorySelectsReadyDefaultAndExposesCapabilities() {
        let service = makeService()
        service.learnAgentRuntimesFromInitializeResponse(RPCMessage(
            id: .string("initialize-1"),
            result: .object([
                "defaultAgentRuntime": .string("opencode"),
                "agentRuntimes": .array([
                    .object([
                        "id": .string("opencode"),
                        "displayName": .string("OpenCode"),
                        "status": .string("ready"),
                        "capabilities": .object([
                            "queue": .bool(false),
                            "steer": .bool(false),
                            "photos": .bool(false),
                            "planMode": .bool(true),
                            "permissions": .bool(true),
                            "desktopHandoff": .bool(false),
                            "subagents": .bool(false),
                        ]),
                        "defaultBuildAgentName": .string("build-agent"),
                        "defaultPlanAgentName": .string("plan-agent"),
                    ]),
                    .object([
                        "id": .string("cursor"),
                        "displayName": .string("Cursor"),
                        "status": .string("not_installed"),
                        "capabilities": .object([
                            "queue": .bool(false),
                            "steer": .bool(false),
                            "photos": .bool(false),
                            "planMode": .bool(false),
                            "permissions": .bool(true),
                            "desktopHandoff": .bool(false),
                            "subagents": .bool(false),
                        ]),
                    ]),
                ]),
            ])
        ))

        XCTAssertEqual(service.selectedAgentRuntimeForNewThreads, "opencode")
        XCTAssertEqual(service.agentRuntimeOptionsForComposer().map(\.id), ["codex", "opencode", "cursor"])
        XCTAssertEqual(service.agentRuntimeDescriptor(id: "opencode")?.defaultBuildAgentName, "build-agent")
        XCTAssertEqual(service.effectiveAgentRuntimeCapabilities(for: nil).planMode, true)

        service.setSelectedAgentRuntimeForNewThreads("cursor")
        XCTAssertEqual(service.selectedAgentRuntimeForNewThreads, "opencode")
    }

    func testRuntimeInventoryDecodesRuntimeModelCatalog() {
        let service = makeService()
        service.learnAgentRuntimesFromInitializeResponse(RPCMessage(
            id: .string("initialize-models"),
            result: .object([
                "defaultAgentRuntime": .string("opencode"),
                "agentRuntimes": .array([
                    .object([
                        "id": .string("opencode"),
                        "displayName": .string("OpenCode"),
                        "status": .string("ready"),
                        "capabilities": .object([
                            "queue": .bool(false),
                            "steer": .bool(false),
                            "photos": .bool(false),
                            "planMode": .bool(true),
                            "permissions": .bool(true),
                            "desktopHandoff": .bool(false),
                            "subagents": .bool(false),
                        ]),
                        "modelCatalog": .object([
                            "defaultModelId": .string("opencode-go/deepseek-v4-flash"),
                            "defaultProviderId": .string("opencode-go"),
                            "providers": .array([
                                .object([
                                    "id": .string("opencode-go"),
                                    "displayName": .string("OpenCode Go"),
                                    "modelIds": .array([
                                        .string("opencode-go/deepseek-v4-flash"),
                                        .string("opencode-go/qwen3.6-plus"),
                                    ]),
                                    "isDefault": .bool(true),
                                ]),
                                .object([
                                    "id": .string("vercel"),
                                    "displayName": .string("Vercel"),
                                    "modelIds": .array([
                                        .string("vercel/alibaba/qwen3.6-plus"),
                                    ]),
                                    "isDefault": .bool(false),
                                ]),
                            ]),
                            "models": .array([
                                .object([
                                    "id": .string("opencode-go/deepseek-v4-flash"),
                                    "model": .string("opencode-go/deepseek-v4-flash"),
                                    "displayName": .string("DeepSeek V4 Flash"),
                                    "description": .string("Verified fallback"),
                                    "isDefault": .bool(true),
                                    "providerID": .string("opencode-go"),
                                    "providerDisplayName": .string("OpenCode Go"),
                                    "modelID": .string("deepseek-v4-flash"),
                                ]),
                                .object([
                                    "id": .string("opencode-go/qwen3.6-plus"),
                                    "model": .string("opencode-go/qwen3.6-plus"),
                                    "displayName": .string("Qwen 3.6 Plus"),
                                    "description": .string("Verified fallback"),
                                    "isDefault": .bool(false),
                                    "providerID": .string("opencode-go"),
                                    "providerDisplayName": .string("OpenCode Go"),
                                    "modelID": .string("qwen3.6-plus"),
                                ]),
                                .object([
                                    "id": .string("vercel/alibaba/qwen3.6-plus"),
                                    "model": .string("vercel/alibaba/qwen3.6-plus"),
                                    "displayName": .string("Qwen 3.6 Plus"),
                                    "description": .string("Discovered"),
                                    "isDefault": .bool(false),
                                    "providerID": .string("vercel"),
                                    "providerDisplayName": .string("Vercel"),
                                    "modelID": .string("alibaba/qwen3.6-plus"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        ))

        XCTAssertEqual(service.modelOptions(for: nil).map(\.id), [
            "opencode-go/deepseek-v4-flash",
            "opencode-go/qwen3.6-plus",
            "vercel/alibaba/qwen3.6-plus",
        ])
        XCTAssertEqual(service.agentRuntimeDescriptor(id: "opencode")?.modelCatalog?.providers.map(\.id), [
            "opencode-go",
            "vercel",
        ])
        XCTAssertEqual(service.modelOptions(for: nil).first?.providerID, "opencode-go")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "opencode-go/deepseek-v4-flash")

        service.setSelectedRuntimeModelId("opencode-go/qwen3.6-plus", for: nil)

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "opencode-go/qwen3.6-plus")

        service.setSelectedRuntimeProviderId("vercel", for: nil)

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "vercel/alibaba/qwen3.6-plus")
    }

    func testCanonicalTurnCompletedCarriesRuntimeError() {
        let service = makeService()
        let adapted = service.remodexAdaptedRPCMessage(canonicalEvent(
            type: "turn_completed",
            threadID: "thread-opencode",
            turnID: "turn-1",
            payload: [
                "status": .string("failed"),
                "error": .object(["message": .string("OpenCode credits exhausted")]),
            ]
        ))

        XCTAssertEqual(adapted.method, "turn/completed")
        XCTAssertEqual(adapted.params?.objectValue?["status"]?.stringValue, "failed")
        XCTAssertEqual(
            adapted.params?.objectValue?["error"]?.objectValue?["message"]?.stringValue,
            "OpenCode credits exhausted"
        )
    }

    private func canonicalEvent(
        type: String,
        threadID: String,
        turnID: String? = nil,
        itemID: String? = nil,
        payload: [String: JSONValue] = [:]
    ) -> RPCMessage {
        var params: [String: JSONValue] = [
            "schemaVersion": .integer(1),
            "agentRuntime": .string("cursor"),
            "threadId": .string(threadID),
            "createdAt": .string("2026-05-24T00:00:00.000Z"),
            "payload": .object(payload)
        ]
        if let turnID {
            params["turnId"] = .string(turnID)
        }
        if let itemID {
            params["itemId"] = .string(itemID)
        }
        return RPCMessage(method: "remodex/event/\(type)", params: .object(params))
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceRemodexEventAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]
        Self.retainedServices.append(service)
        return service
    }
}
