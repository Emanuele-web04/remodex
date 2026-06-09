// FILE: OpenCodeAllModelsSheetTests.swift
// Purpose: Verifies full OpenCode model list fetch and filtering helpers.

import XCTest
@testable import CodexMobile

@MainActor
final class OpenCodeAllModelsSheetTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testFetchFullOpenCodeModelListRequestsFullFlag() async throws {
        let service = makeService()
        service.isConnected = true
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "model/list")
            XCTAssertEqual(params?.objectValue?["full"]?.boolValue, true)
            XCTAssertEqual(params?.objectValue?["provider"]?.stringValue, "opencode")
            return RPCMessage(
                id: .string("1"),
                result: .object([
                    "items": .array([
                        .object([
                            "id": .string("anthropic/claude-sonnet"),
                            "model": .string("anthropic/claude-sonnet"),
                            "modelProvider": .string("opencode"),
                            "displayName": .string("Claude Sonnet"),
                        ]),
                        .object([
                            "id": .string("codex/gpt-5"),
                            "model": .string("codex/gpt-5"),
                            "modelProvider": .string("codex"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let models = try await service.fetchFullOpenCodeModelList(threadId: nil)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.modelProvider, "opencode")
    }

    func testFetchFullOpenCodeModelListSortsByTitle() async throws {
        let service = makeService()
        service.isConnected = true
        service.requestTransportOverride = { _, _ in
            RPCMessage(
                id: .string("1"),
                result: .object([
                    "items": .array([
                        .object([
                            "id": .string("zeta/model"),
                            "model": .string("zeta/model"),
                            "modelProvider": .string("opencode"),
                            "displayName": .string("Zeta"),
                        ]),
                        .object([
                            "id": .string("alpha/model"),
                            "model": .string("alpha/model"),
                            "modelProvider": .string("opencode"),
                            "displayName": .string("Alpha"),
                        ]),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let models = try await service.fetchFullOpenCodeModelList(threadId: "thread-1")
        XCTAssertEqual(TurnComposerMetaMapper.modelTitle(for: models[0]), "Alpha")
        XCTAssertEqual(TurnComposerMetaMapper.modelTitle(for: models[1]), "Zeta")
    }

    func testSupportsSkillFileInjectionUsesCatalogCapabilities() {
        let service = makeService()
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
                    supportsStructuredSkillInput: false,
                    supportsSkillFileInjection: true,
                    supportsImageAttachments: true,
                    supportsSteer: false,
                    supportsQueue: true
                )
            ),
        ]
        service.upsertThread(CodexThread(id: "thread-oc", title: "OC", modelProvider: "opencode"))

        XCTAssertTrue(service.supportsSkillFileInjection(forThreadId: "thread-oc"))
    }

    func testSupportsImageAttachmentsHonorsRollbackFlag() {
        let service = makeService()
        service.availableRuntimes = [
            RuntimeInfo(
                id: "opencode",
                name: "OpenCode",
                enabled: true,
                capabilities: .defaultOpenCode
            ),
        ]
        service.upsertThread(CodexThread(id: "thread-img", title: "OC", modelProvider: "opencode"))

        XCTAssertTrue(service.supportsImageAttachments(forThreadId: "thread-img"))
    }

    func testSupportsImageAttachmentsDisabledWhenCatalogCapabilityFalse() {
        let service = makeService()
        let base = ProviderCapabilities.defaultOpenCode
        let capabilities = ProviderCapabilities(
            supportsAgentSelection: base.supportsAgentSelection,
            supportsReasoningEffort: base.supportsReasoningEffort,
            supportsFastMode: base.supportsFastMode,
            supportsPlanMode: base.supportsPlanMode,
            supportsStreamingTools: base.supportsStreamingTools,
            supportsApprovals: base.supportsApprovals,
            supportsFork: base.supportsFork,
            supportsVoice: base.supportsVoice,
            supportsDesktopHandoff: base.supportsDesktopHandoff,
            supportsSlashCommands: base.supportsSlashCommands,
            supportsSlashCommandExecute: base.supportsSlashCommandExecute,
            supportsMCP: base.supportsMCP,
            supportsWorktree: base.supportsWorktree,
            supportsSkillAutocomplete: base.supportsSkillAutocomplete,
            supportsStructuredSkillInput: base.supportsStructuredSkillInput,
            supportsSkillFileInjection: base.supportsSkillFileInjection,
            supportsImageAttachments: false,
            supportsSteer: base.supportsSteer,
            supportsQueue: base.supportsQueue
        )
        service.availableRuntimes = [
            RuntimeInfo(
                id: "opencode",
                label: "OpenCode",
                enabled: true,
                unavailableReason: nil,
                reasonCode: nil,
                showsBetaLabel: true,
                capabilities: capabilities,
                agents: []
            ),
        ]
        service.upsertThread(CodexThread(id: "thread-img", title: "OC", modelProvider: "opencode"))

        XCTAssertFalse(service.supportsImageAttachments(forThreadId: "thread-img"))
    }

    private func makeService() -> CodexService {
        let suiteName = "OpenCodeAllModelsSheetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}