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

    func testPhoneRuntimeSettingsBecomeThreadScopedWithoutChangingAppDefaults() {
        let service = makeService()
        service.availableModels = [makeModel(), makeGPT55Model()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedReasoningEffort("medium")
        service.setSelectedServiceTier(nil)

        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-remote",
            model: "gpt-5.5",
            reasoningEffort: "high",
            serviceTier: "fast",
            runtimeSettingsRevision: 1,
            runtimeSettingsUpdatedAt: 123,
            runtimeSettingsSource: "phone"
        ))

        XCTAssertEqual(service.selectedModelId, "gpt-5.4")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.4")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-remote"), "gpt-5.5")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-remote"), "high")
        XCTAssertEqual(service.effectiveServiceTier(for: "thread-remote"), .fast)

        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-remote",
            model: "gpt-5.4",
            reasoningEffort: "medium",
            serviceTier: nil,
            runtimeSettingsRevision: 2,
            runtimeSettingsUpdatedAt: 456,
            runtimeSettingsSource: "phone"
        ))

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-remote"), "gpt-5.4")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-remote"), "medium")
        XCTAssertNil(service.effectiveServiceTier(for: "thread-remote"))
    }

    func testNewerTimestampWinsAfterBridgeRevisionResets() {
        let service = makeService()
        service.availableModels = [makeModel(), makeGPT55Model()]

        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-reset",
            model: "gpt-5.5",
            reasoningEffort: "high",
            serviceTier: "fast",
            runtimeSettingsRevision: 12,
            runtimeSettingsUpdatedAt: 100,
            runtimeSettingsSource: "phone"
        ))
        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-reset",
            model: "gpt-5.4",
            reasoningEffort: "medium",
            serviceTier: nil,
            runtimeSettingsRevision: 1,
            runtimeSettingsUpdatedAt: 200,
            runtimeSettingsSource: "phone"
        ))

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-reset"), "gpt-5.4")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-reset"), "medium")
        XCTAssertNil(service.effectiveServiceTier(for: "thread-reset"))
        XCTAssertEqual(service.threadRuntimeOverride(for: "thread-reset")?.runtimeSettingsRevision, 1)
    }

    func testDesktopRuntimeSettingsDoNotOverridePhoneSelection() {
        let service = makeService()
        service.availableModels = [makeModel(), makeGPT55Model()]
        service.setThreadModelOverride("gpt-5.4", for: "thread-phone-authority")
        service.setThreadReasoningEffortOverride("medium", for: "thread-phone-authority")

        service.applyRemoteRuntimeSettings(from: CodexThread(
            id: "thread-phone-authority",
            model: "gpt-5.5",
            reasoningEffort: "high",
            serviceTier: "fast",
            runtimeSettingsRevision: 9,
            runtimeSettingsUpdatedAt: 999,
            runtimeSettingsSource: "desktop"
        ))

        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-phone-authority"), "gpt-5.4")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-phone-authority"), "medium")
        XCTAssertNil(service.effectiveServiceTier(for: "thread-phone-authority"))
    }

    func testClearingSelectedModelFallsBackToGPT56SolMedium() {
        let service = makeService()
        service.availableModels = [makeGPT55Model(), makeGPT56Model(id: "gpt-5.6-sol"), makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedReasoningEffort("high")

        service.setSelectedModelId(nil)

        XCTAssertEqual(service.selectedModelId, "gpt-5.6-sol")
        XCTAssertEqual(service.selectedReasoningEffort, "medium")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.6-sol")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(), "medium")
    }

    func testPersistedModelSelectionIsUsableBeforeModelListRefresh() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("gpt-5.3-codex", forKey: CodexService.selectedModelIdDefaultsKey)

        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)

        XCTAssertTrue(service.availableModels.isEmpty)
        XCTAssertTrue(service.hasPersistedSelectedModelId)
        XCTAssertEqual(service.selectedModelId, "gpt-5.3-codex")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.3-codex")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(), "medium")
        XCTAssertEqual(
            TurnComposerMetaMapper.modelTitle(forIdentifier: service.selectedModelId),
            "GPT-5.3-Codex"
        )
    }

    func testComposerShowsLoadingForPersistedDefaultBeforeModelListRefresh() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("gpt-5.6-sol", forKey: CodexService.selectedModelIdDefaultsKey)

        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        service.isBootstrappingConnectionSync = true

        XCTAssertTrue(service.availableModels.isEmpty)
        XCTAssertNil(service.visibleSelectedModelIDForComposer())
        XCTAssertTrue(service.isRuntimeSelectionLoadingForComposer())
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.6-sol")
    }

    func testComposerKeepsCustomPersistedModelVisibleDuringBootstrap() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("gpt-5.3-codex", forKey: CodexService.selectedModelIdDefaultsKey)

        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        service.isBootstrappingConnectionSync = true

        XCTAssertEqual(service.visibleSelectedModelIDForComposer(), "gpt-5.3-codex")
        XCTAssertFalse(service.isRuntimeSelectionLoadingForComposer())
    }

    func testDefaultModelFallbackIsNotPersistedBeforeModelListRefresh() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        service.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertFalse(service.hasPersistedSelectedModelId)
        XCTAssertNil(service.selectedModelId)
        XCTAssertNil(service.selectedReasoningEffort)
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.6-sol")
        XCTAssertNil(defaults.string(forKey: CodexService.selectedModelIdDefaultsKey))
    }

    func testModelListRefreshPersistsResolvedDefaultForFutureLaunches() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let firstService = CodexService(defaults: defaults)
        Self.retainedServices.append(firstService)
        firstService.availableModels = [
            makeGPT55Model(),
            makeGPT56Model(id: "gpt-5.6-luna"),
            makeGPT56Model(id: "gpt-5.6-terra"),
            makeGPT56Model(id: "gpt-5.6-sol"),
            makeModel(),
        ]
        firstService.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertTrue(firstService.hasPersistedSelectedModelId)
        XCTAssertEqual(firstService.selectedModelId, "gpt-5.6-sol")
        XCTAssertEqual(defaults.string(forKey: CodexService.selectedModelIdDefaultsKey), "gpt-5.6-sol")

        let secondService = CodexService(defaults: defaults)
        Self.retainedServices.append(secondService)

        XCTAssertTrue(secondService.hasPersistedSelectedModelId)
        XCTAssertEqual(secondService.selectedModelId, "gpt-5.6-sol")
    }

    func testModelListRefreshFallsBackThroughGPT56FamilyBeforeGPT55() {
        let service = makeService()
        service.availableModels = [
            makeGPT55Model(),
            makeGPT56Model(id: "gpt-5.6-luna"),
            makeGPT56Model(id: "gpt-5.6-terra"),
            makeModel(),
        ]
        service.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertEqual(service.selectedModelId, "gpt-5.6-terra")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.6-terra")
    }

    func testModelListRefreshUsesGPT55WhenGPT56FamilyIsUnavailable() {
        let service = makeService()
        service.availableModels = [makeGPT55Model(), makeModel()]
        service.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertEqual(service.selectedModelId, "gpt-5.5")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.5")
    }

    func testGPT56ModelsAreFirstClassRuntimeMenuModels() {
        let orderedModels = TurnComposerMetaMapper.orderedModels(
            from: [
                makeModel(),
                makeGPT55Model(),
                makeGPT56Model(id: "gpt-5.6-luna"),
                makeGPT56Model(id: "gpt-5.6-terra"),
                makeGPT56Model(id: "gpt-5.6-sol"),
            ]
        )

        XCTAssertEqual(
            orderedModels.prefix(3).map(\.id),
            ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        )
        XCTAssertEqual(TurnComposerMetaMapper.modelTitle(forIdentifier: "gpt-5.6-sol"), "GPT-5.6-Sol")
        XCTAssertEqual(TurnComposerMetaMapper.modelTitle(forIdentifier: "gpt-5.6-terra"), "GPT-5.6-Terra")
        XCTAssertEqual(TurnComposerMetaMapper.modelTitle(forIdentifier: "gpt-5.6-luna"), "GPT-5.6-Luna")
    }

    func testGPT56ReasoningDisplayIncludesMaxAboveExtraHigh() {
        let options = TurnComposerMetaMapper.reasoningDisplayOptions(
            from: ["low", "medium", "high", "xhigh", "max"]
        )

        XCTAssertEqual(
            options.map(\.title),
            ["Max", "Extra High", "High", "Medium", "Low"]
        )
    }

    func testContinuationInheritsThreadRuntimeOverrides() {
        let service = makeService()
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.applyThreadRuntimeOverride(CodexThreadRuntimeOverride(
            modelId: "gpt-5.4",
            reasoningEffort: "high",
            serviceTierRawValue: CodexServiceTier.fast.rawValue,
            overridesModel: true,
            overridesReasoning: true,
            overridesServiceTier: true,
            runtimeSettingsRevision: 9,
            runtimeSettingsUpdatedAt: 123
        ), to: "thread-old")

        service.inheritThreadRuntimeOverrides(from: "thread-old", to: "thread-new")

        XCTAssertEqual(
            service.selectedReasoningEffortForSelectedModel(threadId: "thread-new"),
            "high"
        )
        XCTAssertEqual(service.effectiveServiceTier(for: "thread-new"), .fast)
        XCTAssertEqual(service.threadRuntimeOverride(for: "thread-new")?.runtimeSettingsRevision, 0)
        XCTAssertEqual(service.threadRuntimeOverride(for: "thread-new")?.runtimeSettingsUpdatedAt, 0)
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
        XCTAssertTrue(service.hydratedThreadIDs.contains("thread-new"))
        XCTAssertTrue(service.initialTurnsLoadedByThreadID.contains("thread-new"))
    }

    func testStartThreadDropsFastRuntimeOverrideWhenSelectedModelDoesNotSupportFastMode() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeLowOnlyModel()]
        service.setSelectedModelId("gpt-5.4-low")

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
            reasoningEffort: "low",
            serviceTierRawValue: "fast",
            overridesReasoning: true,
            overridesServiceTier: true
        )
        _ = try await service.startThread(runtimeOverride: override)

        XCTAssertNil(capturedThreadStartParams.first?.objectValue?["serviceTier"]?.stringValue)
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
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
                CodexReasoningEffortOption(reasoningEffort: "high", description: "High"),
            ],
            defaultReasoningEffort: "medium"
        )
    }

    private func makeGPT55Model() -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5.5",
            model: "gpt-5.5",
            displayName: "GPT-5.5",
            description: "Test model",
            isDefault: true,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
                CodexReasoningEffortOption(reasoningEffort: "high", description: "High"),
            ],
            defaultReasoningEffort: "medium"
        )
    }

    private func makeGPT56Model(id: String) -> CodexModelOption {
        CodexModelOption(
            id: id,
            model: id,
            displayName: id.uppercased(),
            description: "Test model",
            isDefault: true,
            supportsFastMode: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "low", description: "Low"),
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
                CodexReasoningEffortOption(reasoningEffort: "high", description: "High"),
                CodexReasoningEffortOption(reasoningEffort: "xhigh", description: "Extra High"),
                CodexReasoningEffortOption(reasoningEffort: "max", description: "Max"),
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
