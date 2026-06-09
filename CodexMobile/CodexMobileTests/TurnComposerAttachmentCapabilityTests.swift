// FILE: TurnComposerAttachmentCapabilityTests.swift
// Purpose: Verifies capability-driven composer image attachment gating for OpenCode.

import XCTest
@testable import CodexMobile

@MainActor
final class TurnComposerAttachmentCapabilityTests: XCTestCase {
    private static var retainedServices: [CodexService] = []
    private static var retainedViewModels: [TurnViewModel] = []

    func testOpenCameraBlockedWhenImageAttachmentsDisabled() {
        let service = makeService(capabilities: capabilities(imageAttachments: false))
        let viewModel = makeViewModel()
        service.upsertThread(CodexThread(id: "thread-1", title: "T", modelProvider: "opencode"))

        viewModel.openCamera(codex: service, threadID: "thread-1")

        XCTAssertNotNil(service.lastErrorMessage)
        XCTAssertFalse(viewModel.isCameraPresented)
    }

    func testOpenCameraAllowedWhenImageAttachmentsEnabled() {
        let service = makeService(capabilities: capabilities(imageAttachments: true))
        let viewModel = makeViewModel()
        service.upsertThread(CodexThread(id: "thread-2", title: "T", modelProvider: "opencode"))

        viewModel.openCamera(codex: service, threadID: "thread-2")

        XCTAssertTrue(viewModel.isCameraPresented)
    }

    func testCodexProviderAlwaysAllowsImageAttachments() {
        let service = makeService(capabilities: .defaultCodex)
        service.upsertThread(CodexThread(id: "thread-codex", title: "T", modelProvider: "codex"))
        let viewModel = makeViewModel()

        viewModel.openCamera(codex: service, threadID: "thread-codex")

        XCTAssertTrue(viewModel.isCameraPresented)
    }

    private func capabilities(imageAttachments: Bool) -> ProviderCapabilities {
        ProviderCapabilities(
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
            supportsImageAttachments: imageAttachments,
            supportsSteer: false,
            supportsQueue: true
        )
    }

    private func makeService(capabilities: ProviderCapabilities) -> CodexService {
        let suiteName = "TurnComposerAttachmentCapabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.availableRuntimes = [
            RuntimeInfo(id: "opencode", name: "OpenCode", enabled: true, capabilities: capabilities),
        ]
        Self.retainedServices.append(service)
        return service
    }

    private func makeViewModel() -> TurnViewModel {
        let viewModel = TurnViewModel()
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }
}