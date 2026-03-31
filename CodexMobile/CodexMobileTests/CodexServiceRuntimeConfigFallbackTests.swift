// FILE: CodexServiceRuntimeConfigFallbackTests.swift
// Purpose: Verifies runtime request-shape fallback is cached after the first compatible request succeeds.
// Layer: Unit Test
// Exports: CodexServiceRuntimeConfigFallbackTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceRuntimeConfigFallbackTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testSandboxRequestShapeCachesMinimalPayloadAfterFallbackSuccess() async throws {
        let service = makeService()
        var seenSandboxShapes: [String] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/start")
            let object = params?.objectValue ?? [:]
            if object["sandboxPolicy"] != nil {
                seenSandboxShapes.append("sandboxPolicy")
                throw CodexServiceError.rpcError(
                    RPCError(code: -32602, message: "Invalid params: unknown field sandboxPolicy")
                )
            }
            if object["sandbox"] != nil {
                seenSandboxShapes.append("sandbox")
                throw CodexServiceError.rpcError(
                    RPCError(code: -32602, message: "Invalid params: unknown field sandbox")
                )
            }

            seenSandboxShapes.append("minimal")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-1"),
                        "title": .string("Thread 1"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        _ = try await service.startThread()
        _ = try await service.startThread()

        XCTAssertEqual(
            seenSandboxShapes,
            ["sandboxPolicy", "sandbox", "minimal", "minimal"]
        )
        XCTAssertEqual(service.preferredSandboxRequestShape, .minimal)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceRuntimeConfigFallbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
