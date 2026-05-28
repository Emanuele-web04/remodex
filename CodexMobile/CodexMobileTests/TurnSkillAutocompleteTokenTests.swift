// FILE: TurnSkillAutocompleteTokenTests.swift
// Purpose: Verifies trailing `$` and `/` token parsing and replacement for skill autocomplete.
// Layer: Unit Test
// Exports: TurnSkillAutocompleteTokenTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnSkillAutocompleteTokenTests: XCTestCase {
    func testTrailingTokenParsesOnlyWhenItIsFinalToken() {
        let token = TurnViewModel.trailingSkillAutocompleteToken(in: "run $rev")
        XCTAssertEqual(token?.query, "rev")
        XCTAssertEqual(token?.trigger, Character("$"))
    }

    func testBareDollarParsesToOpenSkillList() {
        let token = TurnViewModel.trailingSkillAutocompleteToken(in: "$")
        XCTAssertEqual(token?.query, "")
    }

    func testPureNumericDollarTokenDoesNotParseAsSkill() {
        XCTAssertNil(TurnViewModel.trailingSkillAutocompleteToken(in: "$100"))
    }

    func testSlashSkillTokenParsesForSkillAutocomplete() {
        let token = TurnViewModel.trailingSkillAutocompleteToken(in: "run /check-code")
        XCTAssertEqual(token?.query, "check-code")
        XCTAssertEqual(token?.trigger, Character("/"))
    }

    func testPureNumericSlashTokenDoesNotParseAsSkill() {
        XCTAssertNil(TurnViewModel.trailingSkillAutocompleteToken(in: "/100"))
    }

    func testTrailingTokenDoesNotParseWhenDollarTokenIsNotFinal() {
        XCTAssertNil(TurnViewModel.trailingSkillAutocompleteToken(in: "run $rev now"))
    }

    func testReplacingTrailingTokenUpdatesOnlyFinalDollarToken() {
        let updated = TurnViewModel.replacingTrailingSkillAutocompleteToken(
            in: "compare $first and $rev",
            with: "review"
        )

        XCTAssertEqual(updated, "compare $first and $review ")
    }

    func testReplacingTrailingTokenPreservesSlashSkillTrigger() {
        let updated = TurnViewModel.replacingTrailingSkillAutocompleteToken(
            in: "run /check",
            with: "check-code"
        )

        XCTAssertEqual(updated, "run /check-code ")
    }

    func testSkillAutocompleteRefreshesWhenCachedIndexMissesQuery() async throws {
        let viewModel = TurnViewModel()
        let service = CodexService()
        service.isConnected = true
        let thread = CodexThread(id: "thread-1", cwd: "/Users/me/work/app")
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "skills/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)

            if capturedParams.count <= 2 {
                XCTAssertNil(object["forceReload"]?.boolValue)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: Self.skillsListResponse([
                        Self.skillJSON(name: "check-code", description: "Review changes"),
                    ]),
                    includeJSONRPC: false
                )
            }

            XCTAssertEqual(object["forceReload"]?.boolValue, true)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: Self.skillsListResponse([
                    Self.skillJSON(name: "build-ios-apps:swiftui-view-refactor", description: "Refactor and review SwiftUI views"),
                    Self.skillJSON(name: "check-code", description: "Review recent code changes and suggest refactors"),
                    Self.skillJSON(name: "clean-up", description: "Scan a codebase and systematically refactor"),
                    Self.skillJSON(name: "electron-performance", description: "Performance advice, not broad refactoring"),
                    Self.skillJSON(name: "frontend-skill", description: "Build polished frontend UI while avoiding refactor churn"),
                    Self.skillJSON(name: "release-prep", description: "Prepare releases after refactoring"),
                    Self.skillJSON(name: "check-code", description: "Review changes"),
                    Self.skillJSON(name: "refactor-code", description: "Refactor existing code"),
                ]),
                includeJSONRPC: false
            )
        }

        viewModel.onInputChangedForSkillAutocomplete(
            "run /old",
            codex: service,
            thread: thread,
            activeTurnID: nil
        )
        try await waitUntil { capturedParams.count == 2 }
        XCTAssertTrue(viewModel.skillAutocompleteItems.isEmpty)

        viewModel.onInputChangedForSkillAutocomplete(
            "run /refac",
            codex: service,
            thread: thread,
            activeTurnID: nil
        )

        try await waitUntil {
            viewModel.skillAutocompleteItems.contains { $0.name == "refactor-code" }
        }
        XCTAssertEqual(capturedParams.count, 4)
        XCTAssertNotNil(capturedParams[0]["cwds"]?.arrayValue)
        XCTAssertNil(capturedParams[1]["cwds"]?.arrayValue)
        XCTAssertNotNil(capturedParams[2]["cwds"]?.arrayValue)
        XCTAssertNil(capturedParams[3]["cwds"]?.arrayValue)
        XCTAssertEqual(capturedParams[2]["forceReload"]?.boolValue, true)
        XCTAssertEqual(capturedParams[3]["forceReload"]?.boolValue, true)
        XCTAssertEqual(viewModel.skillAutocompleteItems.first?.name, "refactor-code")
        XCTAssertTrue(viewModel.skillAutocompleteItems.map(\.name).contains("refactor-code"))
    }

    func testSkillAutocompleteDoesNotRepeatForceReloadForSameCachedMiss() async throws {
        let viewModel = TurnViewModel()
        let service = CodexService()
        service.isConnected = true
        let thread = CodexThread(id: "thread-1", cwd: "/Users/me/work/app")
        var capturedParams: [RPCObject] = []

        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "skills/list")
            let object = params?.objectValue ?? [:]
            capturedParams.append(object)

            return RPCMessage(
                id: .string(UUID().uuidString),
                result: Self.skillsListResponse([
                    Self.skillJSON(name: "check-code", description: "Review changes"),
                ]),
                includeJSONRPC: false
            )
        }

        viewModel.onInputChangedForSkillAutocomplete(
            "run /check",
            codex: service,
            thread: thread,
            activeTurnID: nil
        )
        try await waitUntil { capturedParams.count == 2 }

        viewModel.onInputChangedForSkillAutocomplete(
            "run /missing",
            codex: service,
            thread: thread,
            activeTurnID: nil
        )
        try await waitUntil { capturedParams.count == 4 }
        XCTAssertEqual(capturedParams[2]["forceReload"]?.boolValue, true)
        XCTAssertEqual(capturedParams[3]["forceReload"]?.boolValue, true)

        viewModel.onInputChangedForSkillAutocomplete(
            "run /missing",
            codex: service,
            thread: thread,
            activeTurnID: nil
        )
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(capturedParams.count, 4)
        XCTAssertFalse(viewModel.isSkillAutocompleteLoading)
        XCTAssertFalse(viewModel.isSkillAutocompleteVisible)
    }

    private static func skillJSON(name: String, description: String) -> JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "path": .string("/Users/me/.codex/skills/\(name)/SKILL.md"),
            "scope": .string("global"),
            "enabled": .bool(true),
        ])
    }

    private static func skillsListResponse(_ skills: [JSONValue]) -> JSONValue {
        .object([
            "skills": .array(skills),
        ])
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) >= timeout {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
