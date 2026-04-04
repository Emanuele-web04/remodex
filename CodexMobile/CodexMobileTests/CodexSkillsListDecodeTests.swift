// FILE: CodexSkillsListDecodeTests.swift
// Purpose: Verifies skills/list response decoding across supported payload shapes.
// Layer: Unit Test
// Exports: CodexSkillsListDecodeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexSkillsListDecodeTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testFetchServerThreadsPaginatesAndRequestsExplicitSourceKinds() async throws {
        let service = makeService()
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)

            switch capturedParams.count {
            case 1:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "thread-1", cwd: "/Users/me/work/app"),
                        ]),
                        "nextCursor": .string("cursor-2"),
                    ]),
                    includeJSONRPC: false
                )
            case 2:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "thread-2", cwd: "/Users/me/work/site"),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected extra thread/list request")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            }
        }

        let threads = try await service.fetchServerThreads()

        XCTAssertEqual(threads.map(\.id), ["thread-1", "thread-2"])
        XCTAssertEqual(capturedParams.count, 2)
        XCTAssertEqual(capturedParams[0]["cursor"], .null)
        XCTAssertEqual(capturedParams[1]["cursor"]?.stringValue, "cursor-2")

        let requestedSourceKinds = capturedParams[0]["sourceKinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(requestedSourceKinds.contains("appServer"))
        XCTAssertTrue(requestedSourceKinds.contains("cli"))
        XCTAssertTrue(requestedSourceKinds.contains("vscode"))
    }

    func testListThreadsDefaultsToFullHistoryPagination() async throws {
        let service = makeService()
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "data": .array([]),
                    "nextCursor": .null,
                ]),
                includeJSONRPC: false
            )
        }

        try await service.listThreads()

        XCTAssertEqual(capturedParams.count, 2)
        XCTAssertNil(capturedParams[0]["limit"]?.intValue)
        XCTAssertNil(capturedParams[0]["archived"]?.boolValue)
        XCTAssertNil(capturedParams[1]["limit"]?.intValue)
        XCTAssertEqual(capturedParams[1]["archived"]?.boolValue, true)
    }

    func testListThreadsPaginatesActiveAndArchivedResultsUntilCursorIsExhausted() async throws {
        let service = makeService()
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)

            let archived = object["archived"]?.boolValue == true
            let cursor = object["cursor"]

            switch (archived, cursor) {
            case (false, .some(.null)):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "active-1", cwd: "/Users/me/work/app"),
                        ]),
                        "nextCursor": .string("active-cursor-2"),
                    ]),
                    includeJSONRPC: false
                )
            case (false, .some(.string("active-cursor-2"))):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "active-2", cwd: "/Users/me/work/site"),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            case (true, .some(.null)):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "archived-1", cwd: "/Users/me/work/old"),
                        ]),
                        "nextCursor": .string("archived-cursor-2"),
                    ]),
                    includeJSONRPC: false
                )
            case (true, .some(.string("archived-cursor-2"))):
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "archived-2", cwd: "/Users/me/work/older"),
                        ]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected thread/list request: \(object)")
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([]),
                        "nextCursor": .null,
                    ]),
                    includeJSONRPC: false
                )
            }
        }

        try await service.listThreads()

        XCTAssertEqual(capturedParams.count, 4)
        XCTAssertEqual(Set(service.threads.map(\.id)), Set(["active-1", "active-2", "archived-1", "archived-2"]))
        XCTAssertEqual(Set(service.threads.filter { $0.syncState == .live }.map(\.id)), Set(["active-1", "active-2"]))
        XCTAssertEqual(Set(service.threads.filter { $0.syncState == .archivedLocal }.map(\.id)), Set(["archived-1", "archived-2"]))
    }

    func testSyncThreadsListKeepsRealtimePollingScopedToRecentWindow() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)

            let archived = object["archived"]?.boolValue == true
            switch archived {
            case false:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "active-1", cwd: "/Users/me/work/app"),
                        ]),
                        "nextCursor": .string("active-cursor-2"),
                    ]),
                    includeJSONRPC: false
                )
            case true:
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "data": .array([
                            self.makeThreadJSON(id: "archived-1", cwd: "/Users/me/work/old"),
                        ]),
                        "nextCursor": .string("archived-cursor-2"),
                    ]),
                    includeJSONRPC: false
                )
            }
        }

        await service.syncThreadsList()

        XCTAssertEqual(capturedParams.count, 2)
        XCTAssertEqual(capturedParams[0]["limit"]?.intValue, service.realtimeThreadListLimit)
        XCTAssertNil(capturedParams[0]["archived"]?.boolValue)
        XCTAssertEqual(capturedParams[1]["limit"]?.intValue, service.realtimeThreadListLimit)
        XCTAssertEqual(capturedParams[1]["archived"]?.boolValue, true)
        XCTAssertEqual(Set(service.threads.map(\.id)), Set(["active-1", "archived-1"]))
    }

    func testDecodeSkillsListParsesBucketedDataShape() {
        let service = makeService()
        let result: JSONValue = .object([
            "data": .array([
                .object([
                    "cwd": .string("/Users/me/work/repo"),
                    "skills": .array([
                        .object([
                            "name": .string("review"),
                            "description": .string("Review recent changes"),
                            "path": .string("/Users/me/work/repo/.agents/skills/review/SKILL.md"),
                            "scope": .string("project"),
                            "enabled": .bool(true),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let skills = service.decodeSkillMetadata(from: result)

        XCTAssertEqual(skills?.count, 1)
        XCTAssertEqual(skills?.first?.name, "review")
        XCTAssertEqual(skills?.first?.description, "Review recent changes")
        XCTAssertEqual(skills?.first?.scope, "project")
        XCTAssertEqual(skills?.first?.enabled, true)
    }

    func testDecodeSkillsListParsesFlatSkillsShape() {
        let service = makeService()
        let result: JSONValue = .object([
            "skills": .array([
                .object([
                    "name": .string("check-code"),
                    "description": .string("Audit code changes"),
                    "path": .string("/Users/me/.codex/skills/check-code/SKILL.md"),
                    "scope": .string("global"),
                    "enabled": .bool(true),
                ]),
            ]),
        ])

        let skills = service.decodeSkillMetadata(from: result)

        XCTAssertEqual(skills?.count, 1)
        XCTAssertEqual(skills?.first?.name, "check-code")
        XCTAssertEqual(skills?.first?.scope, "global")
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexSkillsListDecodeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]

        // Keep instances alive to avoid deallocation issues in the unit-test runtime.
        Self.retainedServices.append(service)
        return service
    }

    private func makeThreadJSON(id: String, cwd: String) -> JSONValue {
        .object([
            "id": .string(id),
            "title": .string(id),
            "cwd": .string(cwd),
        ])
    }
}
