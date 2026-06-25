// FILE: OpenCodeModelListRetryTests.swift
// Purpose: Verifies OpenCode model/list retry stops on terminal discovery meta.
// Layer: Unit test
// Exports: OpenCodeModelListRetryTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class OpenCodeModelListRetryTests: XCTestCase {
    func testTerminalReasonCodesSkipRetry() {
        let service = makeService()
        service.availableRuntimes = [makeOpenCodeRuntime(enabled: true)]

        for reason in ["no_connected_providers", "unknown", "provider_list_failed"] {
            service.lastModelListOpenCodeMeta = OpenCodeModelListMeta(
                reasonCode: reason,
                connectedProviderIds: [],
                fetchedAt: nil,
                stale: nil,
                modelCountBeforeCap: nil,
                modelCountAfterCap: nil
            )
            XCTAssertTrue(
                service.isOpenCodeModelListRetryTerminal(),
                "expected terminal for \(reason)"
            )
        }
    }

    func testOkWithZeroOpenCodeModelsIsTerminal() {
        let service = makeService()
        service.availableRuntimes = [makeOpenCodeRuntime(enabled: true)]
        service.availableModels = [
            CodexModelOption(
                id: "gpt-5.5",
                model: "gpt-5.5",
                modelProvider: "codex",
                displayName: "GPT-5.5",
                description: "",
                isDefault: true,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            ),
        ]
        service.lastModelListOpenCodeMeta = OpenCodeModelListMeta(
            reasonCode: "ok",
            connectedProviderIds: ["anthropic"],
            fetchedAt: nil,
            stale: nil,
            modelCountBeforeCap: nil,
            modelCountAfterCap: nil
        )

        XCTAssertTrue(service.isOpenCodeModelListRetryTerminal())
    }

    func testOkWithOpenCodeModelsIsNotTerminal() {
        let service = makeService()
        service.availableRuntimes = [makeOpenCodeRuntime(enabled: true)]
        service.availableModels = [
            CodexModelOption(
                id: "anthropic/claude",
                model: "anthropic/claude",
                modelProvider: "opencode",
                displayName: "Claude",
                description: "",
                isDefault: false,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            ),
        ]
        service.lastModelListOpenCodeMeta = OpenCodeModelListMeta(
            reasonCode: "ok",
            connectedProviderIds: ["anthropic"],
            fetchedAt: nil,
            stale: nil,
            modelCountBeforeCap: nil,
            modelCountAfterCap: nil
        )

        XCTAssertFalse(service.isOpenCodeModelListRetryTerminal())
    }

    func testModelsErrorMessageIsScopedByProvider() {
        let service = makeService()
        service.setModelsErrorMessage("OpenCode models failed", forProvider: "opencode")
        service.threadRuntimeOverridesByThreadID["thread-codex"] = CodexThreadRuntimeOverride(
            modelId: "gpt-5.5",
            modelProvider: "codex"
        )
        service.threadRuntimeOverridesByThreadID["thread-oc"] = CodexThreadRuntimeOverride(
            modelId: "anthropic/claude",
            modelProvider: "opencode"
        )

        XCTAssertNil(service.modelsErrorMessage(forThreadId: "thread-codex"))
        XCTAssertEqual(service.modelsErrorMessage(forThreadId: "thread-oc"), "OpenCode models failed")
    }

    func testReconcileDoesNotScheduleRetryForUnknown() {
        let service = makeService()
        service.availableRuntimes = [makeOpenCodeRuntime(enabled: true)]
        service.isConnected = true
        service.isInitialized = true
        service.lastModelListOpenCodeMeta = OpenCodeModelListMeta(
            reasonCode: "unknown",
            connectedProviderIds: ["orphan"],
            fetchedAt: nil,
            stale: nil,
            modelCountBeforeCap: nil,
            modelCountAfterCap: nil
        )

        service.reconcileOpenCodeModelsAfterList()

        XCTAssertEqual(service.openCodeModelRetryCount, 0)
        XCTAssertNil(service.openCodeModelsRetryTask)
    }

    private func makeService() -> CodexService {
        let suiteName = "OpenCodeModelListRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return CodexService(defaults: defaults)
    }

    private func makeOpenCodeRuntime(enabled: Bool) -> RuntimeInfo {
        RuntimeInfo(
            id: "opencode",
            label: "OpenCode",
            enabled: enabled,
            showsBetaLabel: true,
            unavailableReason: nil,
            reasonCode: nil,
            agents: [],
            capabilities: ProviderCapabilities.defaultOpenCode,
            opencode: OpenCodeRuntimeDetails(
                enabled: enabled,
                serveUrl: "http://127.0.0.1:4200",
                version: "1.15.13",
                minVersion: "1.15.12",
                versionBelowMinimum: false,
                sessionCount: 0,
                lastError: nil,
                command: "opencode",
                handoffEnvEnabled: false,
                authConfigured: true,
                connectedProviders: nil,
                providerDiscoveryReasonCode: "ok"
            )
        )
    }
}