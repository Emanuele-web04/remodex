// FILE: CodexThreadRuntimeOverrideTests.swift
// Purpose: Verifies per-thread runtime overrides for reasoning and speed beat app defaults.
// Layer: Unit Test
// Exports: CodexThreadRuntimeOverrideTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadRuntimeOverrideTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testTurnStartUsesThreadRuntimeOverridesInsteadOfAppDefaults() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedReasoningEffort("medium")
        service.setSelectedServiceTier(.fast)
        service.setThreadReasoningEffortOverride("high", for: "thread-override")
        service.setThreadServiceTierOverride(nil, for: "thread-override")

        var capturedTurnStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedTurnStartParams.append(params ?? .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-override")]),
                includeJSONRPC: false
            )
        }

        try await service.sendTurnStart("Ship it", to: "thread-override")

        XCTAssertEqual(capturedTurnStartParams.count, 1)
        XCTAssertEqual(capturedTurnStartParams[0].objectValue?["effort"]?.stringValue, "high")
        XCTAssertNil(capturedTurnStartParams[0].objectValue?["serviceTier"]?.stringValue)
    }

    func testThreadServiceTierOverridePersistsExplicitNormalSelection() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let firstService = CodexService(defaults: defaults)
        Self.retainedServices.append(firstService)
        firstService.setSelectedServiceTier(.fast)
        firstService.setThreadServiceTierOverride(nil, for: "thread-normal")

        XCTAssertTrue(firstService.isThreadServiceTierOverridden("thread-normal"))
        XCTAssertNil(firstService.effectiveServiceTier(for: "thread-normal"))

        let secondService = CodexService(defaults: defaults)
        Self.retainedServices.append(secondService)

        XCTAssertTrue(secondService.isThreadServiceTierOverridden("thread-normal"))
        XCTAssertNil(secondService.effectiveServiceTier(for: "thread-normal"))
    }

    func testContinuationInheritsThreadRuntimeOverrides() {
        let service = makeService()
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setThreadReasoningEffortOverride("high", for: "thread-old")
        service.setThreadServiceTierOverride(.fast, for: "thread-old")

        service.inheritThreadRuntimeOverrides(from: "thread-old", to: "thread-new")

        XCTAssertEqual(
            service.selectedReasoningEffortForSelectedModel(threadId: "thread-new"),
            "high"
        )
        XCTAssertEqual(service.effectiveServiceTier(for: "thread-new"), .fast)
    }

    func testStartThreadUsesProvidedRuntimeOverrideForServiceTier() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedServiceTier(nil)

        var capturedThreadStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/start")
            capturedThreadStartParams.append(params ?? .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-new"),
                        "cwd": .string("/tmp/project"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let override = CodexThreadRuntimeOverride(
            reasoningEffort: "high",
            serviceTierRawValue: "fast",
            overridesReasoning: true,
            overridesServiceTier: true
        )
        let thread = try await service.startThread(runtimeOverride: override)

        XCTAssertEqual(thread.id, "thread-new")
        XCTAssertEqual(capturedThreadStartParams.first?.objectValue?["serviceTier"]?.stringValue, "fast")
        XCTAssertEqual(service.effectiveServiceTier(for: "thread-new"), .fast)
    }

    func testUnsupportedThreadReasoningOverrideIsNotReportedAsActive() {
        let service = makeService()
        service.availableModels = [makeLowOnlyModel()]
        service.setSelectedModelId("gpt-5.4-low")
        service.setThreadReasoningEffortOverride("high", for: "thread-old")

        XCTAssertFalse(service.isThreadReasoningEffortOverridden("thread-old"))
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-old"), "low")
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeModel() -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5.4",
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            description: "Test model",
            isDefault: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
                CodexReasoningEffortOption(reasoningEffort: "high", description: "High"),
            ],
            defaultReasoningEffort: "medium"
        )
    }

    private func makeLowOnlyModel() -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5.4-low",
            model: "gpt-5.4-low",
            displayName: "GPT-5.4 Low",
            description: "Test model",
            isDefault: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: "Low"),
            ],
            defaultReasoningEffort: "low"
        )
    }
}
