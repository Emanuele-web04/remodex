// FILE: TurnViewModelDesktopHandoffTests.swift
// Purpose: Verifies TurnViewModel desktop handoff respects capability gates and provider routing.
// Layer: Unit Test
// Exports: TurnViewModelDesktopHandoffTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnViewModelDesktopHandoffTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testContinueOnDesktopReturnsNilWhenHandoffCapabilityDisabled() async throws {
        let service = makeService()
        var transportCalled = false
        service.requestTransportOverride = { _, _ in
            transportCalled = true
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["success": .bool(true)]),
                includeJSONRPC: false
            )
        }
        service.availableRuntimes = [
            RuntimeInfo(
                id: "opencode",
                label: "OpenCode",
                enabled: true,
                unavailableReason: nil,
                reasonCode: nil,
                showsBetaLabel: true,
                capabilities: .defaultOpenCode,
                agents: []
            ),
        ]
        service.availableModels = [
            CodexModelOption(
                id: "openai/gpt-5.5",
                model: "openai/gpt-5.5",
                modelProvider: "opencode",
                displayName: "GPT-5.5",
                description: "",
                capabilities: .defaultOpenCode
            ),
        ]

        let thread = CodexThread(
            id: "thread-opencode-handoff",
            model: "openai/gpt-5.5",
            modelProvider: "opencode"
        )
        service.threads = [thread]
        let viewModel = TurnViewModel()
        let outcome = try await viewModel.continueOnDesktop(codex: service, thread: thread)

        XCTAssertNil(outcome)
        XCTAssertFalse(transportCalled)
    }

    private func makeService() -> CodexService {
        let suiteName = "TurnViewModelDesktopHandoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}