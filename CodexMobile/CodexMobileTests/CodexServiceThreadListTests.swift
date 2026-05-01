// FILE: CodexServiceThreadListTests.swift
// Purpose: Verifies thread-list fetch shape and local ordering so sidebar results stay recent-activity ordered.
// Layer: Unit Test
// Exports: CodexServiceThreadListTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexServiceThreadListTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testListThreadsRequestsSeventyActiveThreadsAndAppServerSourceKinds() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var activeRequestParams: RPCObject?
        var archivedRequestParams: RPCObject?

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }

            let isArchived = params?.objectValue?["archived"]?.boolValue ?? false
            if isArchived {
                archivedRequestParams = params?.objectValue
            } else {
                activeRequestParams = params?.objectValue
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "threads": .array([]),
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads()

        XCTAssertEqual(activeRequestParams?["limit"]?.intValue, 70)
        XCTAssertEqual(archivedRequestParams?["limit"]?.intValue, 10)
        XCTAssertEqual(archivedRequestParams?["archived"]?.boolValue, true)
        XCTAssertEqual(
            activeRequestParams?["sourceKinds"]?.arrayValue?.compactMap(\.stringValue),
            ["cli", "vscode", "appServer", "exec", "unknown"]
        )
    }

    func testSortThreadsUsesUpdatedAtBeforeCreatedAtFallback() {
        let service = makeService()
        let laterByUpdatedAt = CodexThread(
            id: "later-by-updated-at",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let laterByCreatedAt = CodexThread(
            id: "later-by-created-at",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: nil
        )
        let oldestThread = CodexThread(
            id: "oldest-thread",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: nil
        )

        let sorted = service.sortThreads([oldestThread, laterByCreatedAt, laterByUpdatedAt])

        XCTAssertEqual(
            sorted.map(\.id),
            ["later-by-updated-at", "later-by-created-at", "oldest-thread"]
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceThreadListTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}
