// FILE: OpenCodeDiscoveryParamsTests.swift
// Purpose: Verifies Remodex app sends discoverOpenCodeSessions/Projects on thread/list by default.
// Layer: Unit Test
// Exports: OpenCodeDiscoveryParamsTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class OpenCodeDiscoveryParamsTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testOpenCodeExternalDiscoveryDefaultsOnWhenUnset() {
        let service = makeService()
        XCTAssertTrue(service.openCodeExternalDiscoveryEnabled)
    }

    func testFetchServerThreadsCapturesMaterializationBlockedMeta() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([]),
                    "meta": .object([
                        "materializationBlocked": .integer(2),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        _ = try await service.fetchServerThreads(limit: 25)
        XCTAssertEqual(service.lastThreadListMaterializationBlocked, 2)
    }

    func testListThreadsSendsDiscoverOpenCodeSessionsByDefault() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestParams: RPCObject?
        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }

            requestParams = params?.objectValue
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([]),
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads()

        XCTAssertEqual(requestParams?["discoverOpenCodeSessions"]?.boolValue, true)
        XCTAssertEqual(requestParams?["discoverOpenCodeProjects"]?.boolValue, true)
    }

    func testPaginatedFetchServerThreadsKeepsDiscoveryParamsOnEveryPage() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var requestParams: [RPCObject] = []
        var requestCount = 0

        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }

            requestCount += 1
            requestParams.append(params?.objectValue ?? [:])

            if requestCount == 1 {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            .object([
                                "id": .string("thread-page-1"),
                                "title": .string("Page one"),
                            ]),
                        ]),
                        "nextCursor": .string("cursor-page-2"),
                    ]),
                    includeJSONRPC: false
                )
            }

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([
                        .object([
                            "id": .string("thread-page-2"),
                            "title": .string("Page two"),
                        ]),
                    ]),
                    "nextCursor": .null,
                ]),
                includeJSONRPC: false
            )
        }

        let threads = try await service.fetchServerThreads(limit: 2)

        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(requestParams.count, 2)
        for params in requestParams {
            XCTAssertEqual(params["discoverOpenCodeSessions"]?.boolValue, true)
            XCTAssertEqual(params["discoverOpenCodeProjects"]?.boolValue, true)
        }
    }

    func testListThreadsOmitsDiscoveryParamsWhenUserDisabled() async throws {
        let suiteName = "OpenCodeDiscoveryParamsTests.disabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: CodexService.openCodeExternalDiscoveryDefaultsKey)

        let service = makeService(defaults: defaults)
        service.isConnected = true
        service.isInitialized = true

        var requestParams: RPCObject?
        service.requestTransportOverride = { method, params in
            guard method == "thread/list" else {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }

            requestParams = params?.objectValue
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([]),
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads()

        XCTAssertNil(requestParams?["discoverOpenCodeSessions"])
        XCTAssertNil(requestParams?["discoverOpenCodeProjects"])
    }

    private func makeService(defaults: UserDefaults? = nil) -> CodexService {
        let suiteName = "OpenCodeDiscoveryParamsTests.\(UUID().uuidString)"
        let resolvedDefaults = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        if defaults == nil {
            resolvedDefaults.removePersistentDomain(forName: suiteName)
        }
        let service = CodexService(defaults: resolvedDefaults)
        Self.retainedServices.append(service)
        return service
    }
}