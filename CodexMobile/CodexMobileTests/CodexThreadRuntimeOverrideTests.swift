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

    func testDefaultCodexCapabilitiesExposeReasoningEffort() {
        XCTAssertTrue(ProviderCapabilities.defaultCodex.supportsReasoningEffort)
    }

    func testReasoningFallbackWhenModelsListIsEmptyButCodexIsSelected() {
        let service = makeService()
        service.availableModels = []
        service.setSelectedModelId("codex:gpt-5.5")

        let efforts = service.supportedReasoningEffortsForSelectedModel().map(\.reasoningEffort)
        XCTAssertEqual(efforts, ["low", "medium", "high", "xhigh"])
    }

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
            if method == "turn/start" {
                capturedTurnStartParams.append(params ?? .null)
            }
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

    func testClearingSelectedModelFallsBackToGPT55Medium() {
        let service = makeService()
        service.availableModels = [makeGPT55Model(), makeModel()]
        service.setSelectedModelId("gpt-5.4")
        service.setSelectedReasoningEffort("high")

        service.setSelectedModelId(nil)

        XCTAssertEqual(service.selectedModelId, "codex:gpt-5.5")
        XCTAssertEqual(service.selectedReasoningEffort, "medium")
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.5")
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
        defaults.set("gpt-5.5", forKey: CodexService.selectedModelIdDefaultsKey)

        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        service.isBootstrappingConnectionSync = true

        XCTAssertTrue(service.availableModels.isEmpty)
        XCTAssertNil(service.visibleSelectedModelIDForComposer())
        XCTAssertTrue(service.isRuntimeSelectionLoadingForComposer())
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.5")
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
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(), "gpt-5.5")
        XCTAssertNil(defaults.string(forKey: CodexService.selectedModelIdDefaultsKey))
    }

    func testModelListRefreshPersistsResolvedDefaultForFutureLaunches() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let firstService = CodexService(defaults: defaults)
        Self.retainedServices.append(firstService)
        firstService.availableModels = [makeGPT55Model(), makeModel()]
        firstService.normalizeRuntimeSelectionsAfterModelsUpdate()

        XCTAssertTrue(firstService.hasPersistedSelectedModelId)
        XCTAssertEqual(firstService.selectedModelId, "codex:gpt-5.5")
        XCTAssertEqual(defaults.string(forKey: CodexService.selectedModelIdDefaultsKey), "codex:gpt-5.5")

        let secondService = CodexService(defaults: defaults)
        Self.retainedServices.append(secondService)

        XCTAssertTrue(secondService.hasPersistedSelectedModelId)
        XCTAssertEqual(secondService.selectedModelId, "codex:gpt-5.5")
    }

    func testProviderThreadKeepsUnresolvedRuntimeIdentity() {
        let service = makeService()
        service.availableModels = [makeGPT55Model()]
        service.setSelectedModelId("codex:gpt-5.5")
        service.upsertThread(CodexThread(
            id: "thread-opencode",
            cwd: "/tmp/project",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode"
        ))

        XCTAssertNil(service.selectedModelOption(threadId: "thread-opencode"))
        XCTAssertEqual(
            service.visibleSelectedModelIDForComposer(threadId: "thread-opencode"),
            "opencode:opencode/gpt-5.5"
        )
        XCTAssertEqual(
            service.runtimeModelIdentifierForTurn(threadId: "thread-opencode"),
            "opencode/gpt-5.5"
        )
        XCTAssertEqual(service.runtimeModelProviderForTurn(threadId: "thread-opencode"), "opencode")
        XCTAssertNil(service.selectedReasoningEffortForSelectedModel(threadId: "thread-opencode"))
    }

    func testLegacyCodexModelProviderMetadataStillFallsBackToCodexModel() {
        let service = makeService()
        service.availableModels = [makeModel()]
        service.setSelectedModelId("codex:gpt-5.4")
        service.upsertThread(CodexThread(
            id: "thread-legacy-provider",
            cwd: "/tmp/project",
            model: "gpt-5.4",
            modelProvider: "openai"
        ))

        XCTAssertEqual(
            service.selectedModelOption(threadId: "thread-legacy-provider")?.selectionKey,
            "codex:gpt-5.4"
        )
        XCTAssertEqual(service.runtimeModelIdentifierForTurn(threadId: "thread-legacy-provider"), "gpt-5.4")
        XCTAssertEqual(service.runtimeModelProviderForTurn(threadId: "thread-legacy-provider"), "codex")
        XCTAssertEqual(service.selectedReasoningEffortForSelectedModel(threadId: "thread-legacy-provider"), "medium")
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

    func testPerThreadAgentOverrideDoesNotAffectOtherThreads() {
        let service = makeService()
        service.availableAgents = [
            AgentOption(id: "build", displayName: "Build"),
            AgentOption(id: "plan", displayName: "Plan"),
        ]
        service.setDefaultOpenCodeAgent("build")
        service.setThreadOpenCodeAgentOverride("plan", for: "thread-a")

        XCTAssertEqual(service.effectiveOpenCodeAgent(threadId: "thread-a"), "plan")
        XCTAssertEqual(service.effectiveOpenCodeAgent(threadId: "thread-b"), "build")
    }

    func testSetDefaultOpenCodeAgentDoesNotAlterThreadAgentOverride() {
        let service = makeService()
        service.availableAgents = [
            AgentOption(id: "build", displayName: "Build"),
            AgentOption(id: "plan", displayName: "Plan"),
        ]
        service.setThreadOpenCodeAgentOverride("plan", for: "thread-locked")
        service.setDefaultOpenCodeAgent("build")

        XCTAssertEqual(service.effectiveOpenCodeAgent(threadId: "thread-locked"), "plan")
        XCTAssertEqual(service.defaultOpenCodeAgentId, "build")
    }

    func testThreadAgentOverridePersistsAcrossServiceRelaunch() {
        let suiteName = "CodexThreadRuntimeOverrideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let firstService = CodexService(defaults: defaults)
        Self.retainedServices.append(firstService)
        firstService.availableAgents = [AgentOption(id: "plan", displayName: "Plan")]
        firstService.setThreadOpenCodeAgentOverride("plan", for: "thread-agent")

        let secondService = CodexService(defaults: defaults)
        Self.retainedServices.append(secondService)
        secondService.availableAgents = [AgentOption(id: "plan", displayName: "Plan")]

        XCTAssertEqual(secondService.effectiveOpenCodeAgent(threadId: "thread-agent"), "plan")
    }

    func testTurnStartIncludesAgentForOpenCodeThread() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeOpenCodeModel()]
        service.availableAgents = [AgentOption(id: "plan", displayName: "Plan")]
        service.setSelectedModelId("opencode:gpt-5.5")
        service.setThreadOpenCodeAgentOverride("plan", for: "thread-opencode")

        var capturedTurnStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            if method == "turn/start" {
                capturedTurnStartParams.append(params ?? .null)
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-opencode")]),
                includeJSONRPC: false
            )
        }

        try await service.sendTurnStart("Ship it", to: "thread-opencode")

        XCTAssertEqual(capturedTurnStartParams.count, 1)
        XCTAssertEqual(capturedTurnStartParams[0].objectValue?["agent"]?.stringValue, "plan")
    }

    func testTurnStartOmitsAgentForCodexThread() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeModel()]
        service.setSelectedModelId("gpt-5.4")

        var capturedTurnStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            if method == "turn/start" {
                capturedTurnStartParams.append(params ?? .null)
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-codex")]),
                includeJSONRPC: false
            )
        }

        try await service.sendTurnStart("Ship it", to: "thread-codex")

        XCTAssertEqual(capturedTurnStartParams.count, 1)
        XCTAssertNil(capturedTurnStartParams[0].objectValue?["agent"])
    }

    func testStartThreadIncludesAgentForOpenCodeProvider() async throws {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeOpenCodeModel()]
        service.availableAgents = [
            AgentOption(id: "build", displayName: "Build"),
            AgentOption(id: "plan", displayName: "Plan"),
        ]
        service.setSelectedModelId("opencode:gpt-5.5")

        var capturedThreadStartParams: [JSONValue] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/start")
            capturedThreadStartParams.append(params ?? .null)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-opencode-new"),
                        "cwd": .string("/tmp/project"),
                        "modelProvider": .string("opencode"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let override = CodexThreadRuntimeOverride(
            opencodeAgentId: "plan",
            overridesAgent: true
        )
        _ = try await service.startThread(runtimeOverride: override)

        XCTAssertEqual(capturedThreadStartParams.first?.objectValue?["agent"]?.stringValue, "plan")
        XCTAssertEqual(capturedThreadStartParams.first?.objectValue?["modelProvider"]?.stringValue, "opencode")
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

    func testNilModelProvider_withoutOwnershipSource_returnsCodex() {
        let service = makeService()
        service.availableModels = [makeGPT55Model()]
        service.setSelectedModelId("codex:gpt-5.5")
        service.upsertThread(
            CodexThread(
                id: "thread-nil-provider",
                cwd: "/tmp/project",
                model: "big-pickle",
                modelProvider: nil
            )
        )

        XCTAssertEqual(service.runtimeModelProviderForTurn(threadId: "thread-nil-provider"), "codex")
    }

    func testTurnStartParamsUseThreadOwnershipProviderDespiteGlobalCodexSelection() throws {
        let service = makeService()
        service.availableModels = [makeOpenCodeModel(), makeGPT55Model()]
        service.setSelectedModelId("codex:gpt-5.5")
        service.upsertThread(
            CodexThread(
                id: "thread-opencode-owned",
                cwd: "/tmp/project",
                model: "big-pickle",
                modelProvider: "opencode"
            )
        )

        let params = try service.buildTurnStartRequestParams(
            threadId: "thread-opencode-owned",
            userInput: "Hey",
            attachments: [],
            skillMentions: [],
            mentionMentions: [],
            imageURLKey: "url",
            includeStructuredSkillItems: false,
            includeStructuredMentionItems: false,
            collaborationMode: nil,
            includeServiceTier: false
        )

        XCTAssertEqual(params["modelProvider"]?.stringValue, "opencode")
    }

    func testIncomingRunningSuppressedAfterTurnStartFailureUntilServerTurnId() {
        let service = makeService()
        let threadID = "thread-mirror-suppress"
        service.mirroredRunningSuppressedAfterTurnStartFailureThreadIDs.insert(threadID)

        XCTAssertFalse(service.shouldAcceptIncomingRunningMark(threadId: threadID, turnId: "turn-late"))
        service.setActiveTurnID("turn-confirmed", for: threadID)
        XCTAssertTrue(
            service.shouldAcceptIncomingRunningMark(threadId: threadID, turnId: "turn-confirmed")
        )
    }

    func testTurnComposerRuntimeStateShowsAccessModeWhenCapabilityTrue() {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeOpenCodeModelAccessMode(enabled: true)]
        service.setSelectedModelId("gpt-5.5")
        service.availableRuntimes = [
            RuntimeInfo(
                id: "opencode",
                name: "OpenCode",
                enabled: true,
                capabilities: ProviderCapabilities(
                    supportsAgentSelection: true,
                    supportsReasoningEffort: false,
                    supportsFastMode: false,
                    supportsPlanMode: false,
                    supportsStreamingTools: true,
                    supportsApprovals: true,
                    supportsFork: true,
                    supportsVoice: false,
                    supportsDesktopHandoff: true,
                    supportsSlashCommands: true,
                    supportsMCP: false,
                    supportsWorktree: false,
                    supportsSkillAutocomplete: true,
                    supportsSteer: false,
                    supportsQueue: true,
                    supportsAccessMode: true
                )
            ),
        ]

        let state = TurnComposerRuntimeState.resolve(
            codex: service,
            reasoningDisplayOptions: []
        )
        XCTAssertTrue(state.showsComposerAccessMode)
    }

    func testTurnComposerRuntimeStateHidesAccessModeWhenCapabilityFalse() {
        let service = makeService()
        service.isConnected = true
        service.availableModels = [makeOpenCodeModelAccessMode(enabled: false)]
        service.setSelectedModelId("gpt-5.5")
        service.availableRuntimes = [
            RuntimeInfo(
                id: "opencode",
                name: "OpenCode",
                enabled: true,
                capabilities: ProviderCapabilities(
                    supportsAgentSelection: true,
                    supportsReasoningEffort: false,
                    supportsFastMode: false,
                    supportsPlanMode: false,
                    supportsStreamingTools: true,
                    supportsApprovals: true,
                    supportsFork: true,
                    supportsVoice: false,
                    supportsDesktopHandoff: true,
                    supportsSlashCommands: true,
                    supportsMCP: false,
                    supportsWorktree: false,
                    supportsSkillAutocomplete: true,
                    supportsSteer: false,
                    supportsQueue: true,
                    supportsAccessMode: false
                )
            ),
        ]

        let state = TurnComposerRuntimeState.resolve(
            codex: service,
            reasoningDisplayOptions: []
        )
        XCTAssertFalse(state.showsComposerAccessMode)
    }

    private func makeOpenCodeModelAccessMode(enabled: Bool) -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5.5",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode",
            displayName: "GPT-5.5",
            description: "OpenCode model",
            isDefault: true,
            supportsFastMode: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil,
            capabilities: ProviderCapabilities(
                supportsAgentSelection: true,
                supportsReasoningEffort: false,
                supportsFastMode: false,
                supportsPlanMode: false,
                supportsStreamingTools: true,
                supportsApprovals: true,
                supportsFork: true,
                supportsVoice: false,
                supportsDesktopHandoff: true,
                supportsSlashCommands: true,
                supportsMCP: false,
                supportsWorktree: false,
                supportsSkillAutocomplete: true,
                supportsSteer: false,
                supportsQueue: true,
                supportsAccessMode: enabled
            )
        )
    }

    private func makeOpenCodeModel() -> CodexModelOption {
        CodexModelOption(
            id: "gpt-5.5",
            model: "opencode/gpt-5.5",
            modelProvider: "opencode",
            displayName: "GPT-5.5",
            description: "OpenCode model",
            isDefault: true,
            supportsFastMode: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil,
            capabilities: ProviderCapabilities(
                supportsAgentSelection: true,
                supportsReasoningEffort: false,
                supportsFastMode: false,
                supportsPlanMode: false,
                supportsStreamingTools: true,
                supportsApprovals: true,
                supportsFork: false,
                supportsVoice: false,
                supportsDesktopHandoff: false,
                supportsSlashCommands: true,
                supportsMCP: true,
                supportsWorktree: true,
                supportsSkillAutocomplete: false,
                supportsSteer: false,
                supportsQueue: true
            )
        )
    }
}
