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

    func testListThreadsDefaultsToCappedSidebarMetadata() async throws {
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
        let activeParams = try XCTUnwrap(capturedParams.first { $0["archived"]?.boolValue != true })
        let archivedParams = try XCTUnwrap(capturedParams.first { $0["archived"]?.boolValue == true })
        XCTAssertEqual(activeParams["limit"]?.intValue, 70)
        XCTAssertEqual(archivedParams["limit"]?.intValue, 10)
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
        XCTAssertEqual(skills?.first?.provider, nil)
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
        XCTAssertEqual(skills?.first?.provider, nil)
    }

    func testDecodeSkillsListParsesProvidersArrayFromBridgeMerge() {
        let service = makeService()
        let result: JSONValue = .object([
            "skills": .array([
                .object([
                    "name": .string("review"),
                    "description": .string("Review recent changes"),
                    "path": .string("/Users/me/work/repo/.agents/skills/review/SKILL.md"),
                    "scope": .string("project"),
                    "provider": .string("codex"),
                    "providers": .array([.string("codex"), .string("opencode")]),
                    "enabled": .bool(true),
                ]),
            ]),
        ])

        let skills = service.decodeSkillMetadata(from: result)

        XCTAssertEqual(skills?.count, 1)
        XCTAssertEqual(skills?.first?.name, "review")
        XCTAssertEqual(skills?.first?.provider, "codex")
        XCTAssertEqual(skills?.first?.providers, ["codex", "opencode"])
        XCTAssertEqual(skills?.first?.providerIds, ["codex", "opencode"])
    }

    func testDecodeSkillsListParsesProviderTagFromBridgeUnion() {
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
                            "provider": .string("opencode"),
                            "enabled": .bool(true),
                        ]),
                        .object([
                            "name": .string("check-code"),
                            "description": .string("Audit code changes"),
                            "path": .string("/Users/me/.codex/skills/check-code/SKILL.md"),
                            "scope": .string("global"),
                            "provider": .string("codex"),
                            "enabled": .bool(true),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let skills = service.decodeSkillMetadata(from: result)

        XCTAssertEqual(skills?.count, 2)
        XCTAssertEqual(skills?.first?.name, "review")
        XCTAssertEqual(skills?.first?.scope, "project")
        XCTAssertEqual(skills?.first?.provider, "opencode")
        XCTAssertEqual(skills?.last?.name, "check-code")
        XCTAssertEqual(skills?.last?.provider, "codex")
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
