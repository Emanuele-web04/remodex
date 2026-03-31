// FILE: CodexSkillsCachePersistenceTests.swift
// Purpose: Verifies persisted skills cache snapshots restore only for matching relay context.
// Layer: Unit Test
// Exports: CodexSkillsCachePersistenceTests
// Depends on: Foundation, XCTest, CodexMobile

import Foundation
import XCTest
@testable import CodexMobile

@MainActor
final class CodexSkillsCachePersistenceTests: XCTestCase {
    private static var retainedServices: [CodexService] = []
    private var defaultsByTestName: [String: UserDefaults] = [:]

    override func setUp() {
        super.setUp()
        clearStoredSecureRelayState()
        deletePersistedSkillsCacheFile()
    }

    override func tearDown() {
        defaultsByTestName.removeAll()
        deletePersistedSkillsCacheFile()
        clearStoredSecureRelayState()
        super.tearDown()
    }

    func testCachedSkillsPersistAcrossServiceReloadForMatchingRelayMac() async throws {
        let service = makeService(testName: "persistAcrossReload")
        service.relayMacDeviceId = "mac-test"
        service.requestTransportOverride = { method, _ in
            switch method {
            case "skills/list":
                return self.makeSkillsRPCResponse([
                    CodexSkillMetadata(
                        name: "alpha",
                        description: "Alpha skill",
                        path: "/tmp/project/alpha/SKILL.md",
                        scope: "project",
                        enabled: true
                    ),
                    CodexSkillMetadata(
                        name: "beta",
                        description: "Beta skill",
                        path: "/tmp/project/beta/SKILL.md",
                        scope: "project",
                        enabled: true
                    ),
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                return self.makeSkillsRPCResponse([])
            }
        }

        let listed = try await service.listSkills(cwds: ["/tmp/project"], forceReload: false)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(
            service.cachedAutocompleteSkills(for: "/tmp/project", query: "alp", limit: 6)?.map(\.name),
            ["alpha"]
        )

        let reloadedService = makeService(testName: "persistAcrossReload")
        reloadedService.relayMacDeviceId = "mac-test"
        let cached = reloadedService.cachedSkills(for: "/tmp/project")
        let cachedAutocomplete = reloadedService.cachedAutocompleteSkills(
            for: "/tmp/project",
            query: "alp",
            limit: 6
        )

        XCTAssertEqual(cached?.map(\.name), Optional(listed.map(\.name)))
        XCTAssertEqual(cachedAutocomplete?.map(\.name), ["alpha"])
    }

    func testCachedSkillsDoNotRestoreForMismatchedRelayMac() async throws {
        let service = makeService(testName: "mismatchedRelay")
        service.relayMacDeviceId = "mac-a"
        service.requestTransportOverride = { method, _ in
            switch method {
            case "skills/list":
                return self.makeSkillsRPCResponse([
                    CodexSkillMetadata(
                        name: "alpha",
                        description: "Alpha skill",
                        path: "/tmp/project/alpha/SKILL.md",
                        scope: "project",
                        enabled: true
                    ),
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                return self.makeSkillsRPCResponse([])
            }
        }

        _ = try await service.listSkills(cwds: ["/tmp/project"], forceReload: false)

        let reloadedService = makeService(testName: "mismatchedRelay")
        reloadedService.relayMacDeviceId = "mac-b"

        XCTAssertNil(reloadedService.cachedSkills(for: "/tmp/project"))
        XCTAssertNil(reloadedService.cachedAutocompleteSkills(for: "/tmp/project", query: "alp", limit: 6))
    }

    func testCachedSkillsRestoreForMatchingServerIdentityWithoutRelayContext() async throws {
        let service = makeService(testName: "matchingServerIdentity")
        service.connectedServerIdentity = "ws://example.test/socket"
        service.requestTransportOverride = { method, _ in
            switch method {
            case "skills/list":
                return self.makeSkillsRPCResponse([
                    CodexSkillMetadata(
                        name: "alpha",
                        description: "Alpha skill",
                        path: "/tmp/project/alpha/SKILL.md",
                        scope: "project",
                        enabled: true
                    ),
                    CodexSkillMetadata(
                        name: "beta",
                        description: "Beta skill",
                        path: "/tmp/project/beta/SKILL.md",
                        scope: "project",
                        enabled: true
                    ),
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                return self.makeSkillsRPCResponse([])
            }
        }

        let listed = try await service.listSkills(cwds: ["/tmp/project"], forceReload: false)
        XCTAssertEqual(listed.count, 2)

        let reloadedService = makeService(testName: "matchingServerIdentity")
        reloadedService.connectedServerIdentity = "ws://example.test/socket"
        let cached = reloadedService.cachedSkills(for: "/tmp/project")
        let cachedAutocomplete = reloadedService.cachedAutocompleteSkills(
            for: "/tmp/project",
            query: "alp",
            limit: 6
        )

        XCTAssertEqual(cached?.map(\.name), Optional(listed.map(\.name)))
        XCTAssertEqual(cachedAutocomplete?.map(\.name), ["alpha"])
    }

    func testCachedSkillsDoNotRestoreForMismatchedServerIdentityWithoutRelayContext() async throws {
        let service = makeService(testName: "mismatchedServerIdentity")
        service.connectedServerIdentity = "ws://example.test/socket-a"
        service.requestTransportOverride = { method, _ in
            switch method {
            case "skills/list":
                return self.makeSkillsRPCResponse([
                    CodexSkillMetadata(
                        name: "alpha",
                        description: "Alpha skill",
                        path: "/tmp/project/alpha/SKILL.md",
                        scope: "project",
                        enabled: true
                    ),
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                return self.makeSkillsRPCResponse([])
            }
        }

        _ = try await service.listSkills(cwds: ["/tmp/project"], forceReload: false)

        let reloadedService = makeService(testName: "mismatchedServerIdentity")
        reloadedService.connectedServerIdentity = "ws://example.test/socket-b"

        XCTAssertNil(reloadedService.cachedSkills(for: "/tmp/project"))
        XCTAssertNil(reloadedService.cachedAutocompleteSkills(for: "/tmp/project", query: "alp", limit: 6))
    }

    func testInMemorySkillsCacheDoesNotSurviveDirectServerIdentitySwitch() async throws {
        let service = makeService(testName: "directServerSwitch")
        service.connectedServerIdentity = "ws://example.test/socket-a"
        service.requestTransportOverride = { method, _ in
            switch method {
            case "skills/list":
                return self.makeSkillsRPCResponse([
                    CodexSkillMetadata(
                        name: "alpha",
                        description: "Alpha skill",
                        path: "/tmp/project/alpha/SKILL.md",
                        scope: "project",
                        enabled: true
                    ),
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                return self.makeSkillsRPCResponse([])
            }
        }

        let listed = try await service.listSkills(cwds: ["/tmp/project"], forceReload: false)
        XCTAssertEqual(listed.map(\.name), ["alpha"])
        XCTAssertEqual(service.cachedSkills(for: "/tmp/project")?.map(\.name), ["alpha"])
        XCTAssertEqual(
            service.cachedAutocompleteSkills(for: "/tmp/project", query: "alp", limit: 6)?.map(\.name),
            ["alpha"]
        )

        service.connectedServerIdentity = "ws://example.test/socket-b"

        XCTAssertNil(service.cachedSkills(for: "/tmp/project"))
        XCTAssertFalse(service.isUnsupportedSkillRoot("/tmp/project"))
        XCTAssertNil(service.cachedAutocompleteSkills(for: "/tmp/project", query: "alp", limit: 6))
    }

    func testResetSkillsCacheContextChangeClearsAutocompleteCacheForMismatchedRelayMac() async throws {
        let service = makeService(testName: "resetContextChange")
        service.relayMacDeviceId = "mac-a"
        service.requestTransportOverride = { method, _ in
            switch method {
            case "skills/list":
                return self.makeSkillsRPCResponse([
                    CodexSkillMetadata(
                        name: "alpha",
                        description: "Alpha skill",
                        path: "/tmp/project/alpha/SKILL.md",
                        scope: "project",
                        enabled: true
                    ),
                ])
            default:
                XCTFail("Unexpected method: \(method)")
                return self.makeSkillsRPCResponse([])
            }
        }

        _ = try await service.listSkills(cwds: ["/tmp/project"], forceReload: false)
        XCTAssertEqual(
            service.cachedAutocompleteSkills(for: "/tmp/project", query: "alp", limit: 6)?.map(\.name),
            ["alpha"]
        )

        service.relayMacDeviceId = "mac-b"
        service.resetSkillsCacheForConnectionContextChange()

        XCTAssertNil(service.cachedSkills(for: "/tmp/project"))
        XCTAssertNil(service.cachedAutocompleteSkills(for: "/tmp/project", query: "alp", limit: 6))
    }

    func testUnsupportedSkillRootPersistsAcrossServiceReload() {
        let service = makeService(testName: "unsupportedRoot")
        service.relayMacDeviceId = "mac-test"
        service.markUnsupportedSkillRoot("/tmp/project")

        let reloadedService = makeService(testName: "unsupportedRoot")
        reloadedService.relayMacDeviceId = "mac-test"

        XCTAssertTrue(reloadedService.isUnsupportedSkillRoot("/tmp/project"))
    }

    private func makeDefaults(testName: String) -> UserDefaults {
        if let existing = defaultsByTestName[testName] {
            return existing
        }

        let suiteName = "CodexSkillsCachePersistenceTests.\(testName)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Expected isolated UserDefaults suite")
        }

        defaults.removePersistentDomain(forName: suiteName)
        defaultsByTestName[testName] = defaults
        return defaults
    }

    private func makeService(testName: String) -> CodexService {
        let service = CodexService(defaults: makeDefaults(testName: testName))
        Self.retainedServices.append(service)
        return service
    }

    private func clearStoredSecureRelayState() {
        SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.deleteValue(for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.deleteValue(for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.deleteValue(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        SecureStore.deleteValue(for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.deleteValue(for: CodexSecureKeys.lastTrustedMacDeviceId)
    }

    private func deletePersistedSkillsCacheFile() {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        let rootURL = baseURL.appendingPathComponent(bundleIdentifier, isDirectory: true)

        try? FileManager.default.removeItem(at: rootURL)
    }

    private func makeSkillsRPCResponse(_ skills: [CodexSkillMetadata]) -> RPCMessage {
        let skillValues: [JSONValue] = skills.map { skill in
            .object([
                "name": .string(skill.name),
                "description": skill.description.map(JSONValue.string) ?? .null,
                "path": skill.path.map(JSONValue.string) ?? .null,
                "scope": skill.scope.map(JSONValue.string) ?? .null,
                "enabled": .bool(skill.enabled),
            ])
        }

        return RPCMessage(
            id: .string(UUID().uuidString),
            result: .object([
                "data": .array([
                    .object([
                        "skills": .array(skillValues),
                    ]),
                ]),
            ]),
            includeJSONRPC: false
        )
    }
}
