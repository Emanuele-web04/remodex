// FILE: CodexServiceTests.swift
// Purpose: Verifies CodexService provider-scoped runtime auth error handling.
// Layer: Unit test
// Exports: CodexServiceTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceTests: XCTestCase {
    func testAuthErrorScopedToProvider() {
        let service = makeService()
        service.threadRuntimeOverridesByThreadID["thread-codex"] = CodexThreadRuntimeOverride(
            modelId: "gpt-5.5",
            modelProvider: "codex"
        )
        service.threadRuntimeOverridesByThreadID["thread-opencode"] = CodexThreadRuntimeOverride(
            modelId: "anthropic/claude",
            modelProvider: "opencode"
        )
        service.setModelsErrorMessage("codex_catalog_failed", forProvider: "codex")

        service.handleNotification(
            method: "runtime/auth/error",
            params: .object([
                "message": .string("auth_failed"),
                "provider": .string("opencode"),
            ])
        )

        XCTAssertEqual(service.modelsErrorMessageByProvider["opencode"], "auth_failed")
        XCTAssertEqual(service.modelsErrorMessage(forThreadId: "thread-opencode"), "auth_failed")
        XCTAssertEqual(service.modelsErrorMessageByProvider["codex"], "codex_catalog_failed")
        XCTAssertEqual(service.modelsErrorMessage(forThreadId: "thread-codex"), "codex_catalog_failed")
        XCTAssertEqual(service.lastModelListOpenCodeMeta?.reasonCode, "provider_auth_error")

        let expectation = expectation(description: "concurrent auth error updates complete")
        expectation.expectedFulfillmentCount = 20

        for index in 0..<20 {
            DispatchQueue.global(qos: .userInitiated).async {
                Task { @MainActor in
                    service.handleNotification(
                        method: "runtime/auth/error",
                        params: .object([
                            "message": .string("auth_failed_\(index)"),
                            "provider": .string("opencode"),
                        ])
                    )
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNotNil(service.modelsErrorMessageByProvider["opencode"])
        XCTAssertTrue(service.modelsErrorMessageByProvider["opencode"]?.hasPrefix("auth_failed") == true)
        XCTAssertEqual(service.modelsErrorMessageByProvider["codex"], "codex_catalog_failed")
        XCTAssertEqual(service.modelsErrorMessage(forThreadId: "thread-codex"), "codex_catalog_failed")
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return CodexService(defaults: defaults)
    }
}
