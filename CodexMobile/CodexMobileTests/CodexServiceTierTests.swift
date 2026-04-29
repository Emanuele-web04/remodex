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

    func testModelFastCapabilityDecodesFromRuntimeMetadata() throws {
        let payload = """
        [
          {
            "slug": "gpt-5.5",
            "name": "GPT-5.5",
            "additionalSpeedTiers": ["fast"],
            "supportedReasoningEfforts": [{ "value": "medium", "label": "Medium" }]
          },
          {
            "slug": "gpt-5.3-codex",
            "name": "GPT-5.3 Codex",
            "supportsFastMode": false,
            "supportedReasoningEfforts": ["medium"]
          }
        ]
        """

        let models = try JSONDecoder().decode([CodexModelOption].self, from: Data(payload.utf8))

        XCTAssertEqual(models[0].id, "gpt-5.5")
        XCTAssertEqual(models[0].displayName, "GPT-5.5")
        XCTAssertTrue(models[0].supportsFastMode)
        XCTAssertEqual(models[0].supportedReasoningEfforts.first?.reasoningEffort, "medium")
        XCTAssertEqual(models[1].id, "gpt-5.3-codex")
        XCTAssertFalse(models[1].supportsFastMode)
    }

    func testKnownFastModelsUseStaticFallbackWhenRuntimeMetadataOmitsCapability() throws {
        let payload = """
        [
          {
            "slug": "gpt-5.4",
            "name": "GPT-5.4",
            "supportedReasoningEfforts": ["medium"]
          },
          {
            "slug": "gpt-5.5",
            "name": "GPT-5.5",
            "supportedReasoningEfforts": ["medium"]
          },
          {
            "slug": "unknown-model",
            "name": "Unknown Model",
            "supportedReasoningEfforts": ["medium"]
          }
        ]
        """

        let models = try JSONDecoder().decode([CodexModelOption].self, from: Data(payload.utf8))

        XCTAssertTrue(models[0].supportsFastMode)
        XCTAssertTrue(models[1].supportsFastMode)
        XCTAssertFalse(models[2].supportsFastMode)
    }

    func testSwitchingBetweenFastCapableModelsKeepsSelectedServiceTier() {
        let service = makeService()
        service.availableModels = [
            makeModel(id: "gpt-5.4", supportsFastMode: true),
            makeModel(id: "gpt-5.5", supportsFastMode: true),
        ]

        service.setSelectedModelId("gpt-5.4")
        service.setSelectedServiceTier(.fast)
        service.setSelectedModelId("gpt-5.5")

        XCTAssertEqual(service.selectedServiceTier, .fast)
        XCTAssertEqual(service.effectiveServiceTier(), .fast)

        service.setSelectedModelId("gpt-5.4")

        XCTAssertEqual(service.selectedServiceTier, .fast)
        XCTAssertEqual(service.effectiveServiceTier(), .fast)
    }

    func testSwitchingToModelWithoutFastModeClearsSelectedServiceTier() {
        let service = makeService()
        service.availableModels = [
            makeModel(id: "gpt-5.5", supportsFastMode: true),
            makeModel(id: "gpt-5.3-codex", supportsFastMode: false),
        ]

        service.setSelectedModelId("gpt-5.5")
        service.setSelectedServiceTier(.fast)
        XCTAssertEqual(service.selectedServiceTier, .fast)
        XCTAssertEqual(service.effectiveServiceTier(), .fast)

        service.setSelectedModelId("gpt-5.3-codex")

        XCTAssertNil(service.selectedServiceTier)
        XCTAssertNil(service.effectiveServiceTier())
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

    private func makeModel(id: String = "gpt-5.4", supportsFastMode: Bool = true) -> CodexModelOption {
        CodexModelOption(
            id: id,
            model: id,
            displayName: id.uppercased(),
            description: "Test model",
            isDefault: true,
            supportsFastMode: supportsFastMode,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
            ],
            defaultReasoningEffort: "medium"
        )
    }
}
