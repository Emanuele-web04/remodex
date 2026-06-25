// FILE: CodexStructuredSkillCapabilityTests.swift
// Purpose: Verifies supportsStructuredSkillInput(forThreadId:) follows runtime/catalog for OpenCode.
// Layer: Unit Test
// Exports: CodexStructuredSkillCapabilityTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexStructuredSkillCapabilityTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testSupportsStructuredSkillInputIsFalseForOpenCodeThread() {
        let service = makeService()
        service.availableRuntimes = [
            RuntimeInfo(
                id: "opencode",
                label: "OpenCode",
                enabled: true,
                unavailableReason: nil,
                reasonCode: nil,
                showsBetaLabel: true,
                capabilities: .defaultOpenCode,
                agents: [AgentOption(id: "build", label: "Build")]
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
        service.threads = [
            CodexThread(
                id: "thread-opencode-1",
                model: "openai/gpt-5.5",
                modelProvider: "opencode"
            ),
        ]

        XCTAssertFalse(service.supportsStructuredSkillInput(forThreadId: "thread-opencode-1"))
    }

    func testSupportsStructuredSkillInputIsTrueForCodexThread() {
        let service = makeService()
        service.availableRuntimes = [
            RuntimeInfo(
                id: "codex",
                label: "Codex",
                enabled: true,
                unavailableReason: nil,
                reasonCode: nil,
                showsBetaLabel: false,
                capabilities: .defaultCodex,
                agents: []
            ),
        ]
        service.availableModels = [
            CodexModelOption(
                id: "gpt-5.4",
                model: "gpt-5.4",
                modelProvider: "codex",
                displayName: "GPT-5.4",
                description: "",
                capabilities: .defaultCodex
            ),
        ]
        service.supportsStructuredSkillInput = true

        XCTAssertTrue(service.supportsStructuredSkillInput(forThreadId: nil))
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexStructuredSkillCapabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}