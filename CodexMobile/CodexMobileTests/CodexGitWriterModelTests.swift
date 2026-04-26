// FILE: CodexGitWriterModelTests.swift
// Purpose: Verifies Git writer model fallback and persistence stay independent from runtime chat defaults.
// Layer: Unit Test
// Exports: CodexGitWriterModelTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexGitWriterModelTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testGitWriterModelDefaultsToGPT54MiniWhenAvailable() {
        let service = makeService()
        service.availableModels = [
            makeModel(id: "gpt-5.4", isDefault: true),
            makeModel(id: "gpt-5.4-mini"),
        ]

        XCTAssertEqual(service.selectedGitWriterModelOption()?.model, "gpt-5.4-mini")
        XCTAssertEqual(service.gitWriterModelIdentifier(), "gpt-5.4-mini")
    }

    func testGitWriterModelFallsBackToRuntimeSelectionWhenMiniUnavailable() {
        let service = makeService()
        service.availableModels = [
            makeModel(id: "gpt-5.4", isDefault: true),
            makeModel(id: "gpt-5.3"),
        ]
        service.setSelectedModelId("gpt-5.3")

        XCTAssertEqual(service.selectedGitWriterModelOption()?.model, "gpt-5.3")
    }

    func testGitWriterModelPreferencePersistsSeparatelyFromRuntimeModel() {
        let suiteName = "CodexGitWriterModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let firstService = CodexService(defaults: defaults)
        Self.retainedServices.append(firstService)
        firstService.availableModels = [
            makeModel(id: "gpt-5.4", isDefault: true),
            makeModel(id: "gpt-5.4-mini"),
        ]
        firstService.setSelectedModelId("gpt-5.4")
        firstService.setSelectedGitWriterModelId("gpt-5.4-mini")

        let secondService = CodexService(defaults: defaults)
        Self.retainedServices.append(secondService)
        secondService.availableModels = firstService.availableModels

        XCTAssertEqual(secondService.selectedModelOption()?.model, "gpt-5.4")
        XCTAssertEqual(secondService.selectedGitWriterModelOption()?.model, "gpt-5.4-mini")
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexGitWriterModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeModel(id: String, isDefault: Bool = false) -> CodexModelOption {
        CodexModelOption(
            id: id,
            model: id,
            displayName: id.uppercased(),
            description: "Test model",
            isDefault: isDefault,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
            ],
            defaultReasoningEffort: "medium"
        )
    }
}
