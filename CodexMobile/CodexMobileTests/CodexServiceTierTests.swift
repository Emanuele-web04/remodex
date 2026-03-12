// FILE: CodexServiceTierTests.swift
// Purpose: Verifies Fast Mode runtime selection is persisted and sent to app-server payloads.
// Layer: Unit Test
// Exports: CodexServiceTierTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceTierTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testTurnStartIncludesSelectedServiceTier() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedServiceTier(.fast)

        var capturedTurnStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            capturedTurnStartParams.append(params ?? .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-fast")]),
                includeJSONRPC: false
            )
        }

        try await service.sendTurnStart("Ship this quickly", to: "thread-fast")

        XCTAssertEqual(
            capturedTurnStartParams.first?.objectValue?["serviceTier"]?.stringValue,
            "fast"
        )
    }

    func testSetSelectedServiceTierPersistsChoice() {
        let service = makeService()

        service.setSelectedServiceTier(.fast)

        XCTAssertEqual(service.selectedServiceTier, .fast)
        XCTAssertEqual(
            service.defaults.string(forKey: CodexService.selectedServiceTierDefaultsKey),
            "fast"
        )
    }

    func testUnsupportedServiceTierDisablesFutureRetriesAndShowsUpdatePromptOnce() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedServiceTier(.fast)

        var capturedTurnStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "turn/start")
            let safeParams = params ?? .null
            capturedTurnStartParams.append(safeParams)

            if safeParams.objectValue?["serviceTier"]?.stringValue != nil {
                throw CodexServiceError.rpcError(
                    RPCError(code: -32602, message: "Unknown field serviceTier")
                )
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string(UUID().uuidString)]),
                includeJSONRPC: false
            )
        }

        try await service.sendTurnStart("First send", to: "thread-fast-1")
        try await service.sendTurnStart("Second send", to: "thread-fast-2")

        XCTAssertEqual(capturedTurnStartParams.count, 3)
        XCTAssertEqual(capturedTurnStartParams[0].objectValue?["serviceTier"]?.stringValue, "fast")
        XCTAssertNil(capturedTurnStartParams[1].objectValue?["serviceTier"]?.stringValue)
        XCTAssertNil(capturedTurnStartParams[2].objectValue?["serviceTier"]?.stringValue)
        XCTAssertFalse(service.supportsServiceTier)
        XCTAssertEqual(service.bridgeUpdatePrompt?.title, "Update Remodex on your Mac to use Speed controls")
        XCTAssertEqual(
            service.bridgeUpdatePrompt?.message,
            "This Mac bridge does not support the selected speed setting yet. Update the Remodex npm package to use Fast Mode and other speed controls."
        )
        XCTAssertEqual(service.bridgeUpdatePrompt?.command, "npm install -g remodex@1.1.4")
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceTierTests.\(UUID().uuidString)"
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
            ],
            defaultReasoningEffort: "medium"
        )
    }
}
