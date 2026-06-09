// FILE: TurnViewModelSkillsAutocompleteTests.swift
// Purpose: Validates skills autocomplete inline cap vs full list count and provider-signature cache bust.
// Layer: Unit Test
// Exports: TurnViewModelSkillsAutocompleteTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnViewModelSkillsAutocompleteTests: XCTestCase {
    private static var retainedServices: [CodexService] = []
    private static var retainedViewModels: [TurnViewModel] = []

    func testSkillAutocompleteInlineCapUsesFilteredTotalCount() async throws {
        let service = makeService()
        service.isConnected = true
        let viewModel = makeViewModel()
        let thread = makeThread(cwd: "/Users/me/work/repo")

        var skillsListCallCount = 0
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "skills/list")
            skillsListCallCount += 1
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: self.makeSkillsListResult(skillCount: 15),
                includeJSONRPC: false
            )
        }

        viewModel.onInputChangedForSkillAutocomplete(
            "$",
            codex: service,
            thread: thread,
            activeTurnID: nil
        )
        await waitForSkillAutocomplete(viewModel)

        XCTAssertEqual(skillsListCallCount, 1)
        XCTAssertEqual(viewModel.skillTotalCount, 15)
        XCTAssertEqual(viewModel.skillFullListItems.count, 15)
        XCTAssertEqual(viewModel.skillAutocompleteItems.count, 12)
        XCTAssertTrue(viewModel.isSkillAutocompleteVisible)
    }

    func testSkillAutocompleteRebuildsCacheWhenProvidersSignatureChanges() async throws {
        let service = makeService()
        service.isConnected = true
        let viewModel = makeViewModel()
        let thread = makeThread(cwd: "/Users/me/work/repo")

        var skillsListCallCount = 0
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "skills/list")
            skillsListCallCount += 1
            let providers: [JSONValue]
            if skillsListCallCount == 1 {
                providers = [.string("codex")]
            } else {
                providers = [.string("codex"), .string("opencode")]
            }
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: self.makeSkillsListResult(
                    skills: [
                        self.makeSkillJSON(
                            name: "review",
                            provider: "codex",
                            providers: providers
                        ),
                    ]
                ),
                includeJSONRPC: false
            )
        }

        viewModel.onInputChangedForSkillAutocomplete(
            "$",
            codex: service,
            thread: thread,
            activeTurnID: nil
        )
        await waitForSkillAutocomplete(viewModel)

        XCTAssertEqual(skillsListCallCount, 1)
        XCTAssertEqual(viewModel.skillFullListItems.first?.providerIds, ["codex"])

        viewModel.onInputChangedForSkillAutocomplete(
            "$",
            codex: service,
            thread: thread,
            activeTurnID: nil
        )
        await waitForSkillAutocomplete(viewModel)

        XCTAssertEqual(skillsListCallCount, 2)
        XCTAssertEqual(viewModel.skillFullListItems.first?.providerIds, ["codex", "opencode"])
    }

    func testSkillAutocompleteQueryFilterKeepsUncappedFullListCount() async throws {
        let service = makeService()
        service.isConnected = true
        let viewModel = makeViewModel()
        let thread = makeThread(cwd: "/Users/me/work/repo")

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "skills/list")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: self.makeSkillsListResult(
                    skills: [
                        self.makeSkillJSON(name: "review", provider: "codex"),
                        self.makeSkillJSON(name: "check-code", provider: "codex"),
                        self.makeSkillJSON(name: "lint", provider: "opencode"),
                    ]
                ),
                includeJSONRPC: false
            )
        }

        viewModel.onInputChangedForSkillAutocomplete(
            "$re",
            codex: service,
            thread: thread,
            activeTurnID: nil
        )
        await waitForSkillAutocomplete(viewModel)

        XCTAssertEqual(viewModel.skillTotalCount, 1)
        XCTAssertEqual(viewModel.skillFullListItems.map(\.name), ["review"])
        XCTAssertEqual(viewModel.skillAutocompleteItems.map(\.name), ["review"])
    }

    private func waitForSkillAutocomplete(
        _ viewModel: TurnViewModel,
        maxPollCount: Int = 80
    ) async {
        for _ in 0..<maxPollCount where viewModel.isSkillAutocompleteLoading {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func makeSkillsListResult(skillCount: Int) -> JSONValue {
        let skills = (1...skillCount).map { index in
            makeSkillJSON(name: "skill-\(index)", provider: "codex")
        }
        return makeSkillsListResult(skills: skills)
    }

    private func makeSkillsListResult(skills: [JSONValue]) -> JSONValue {
        .object([
            "data": .array([
                .object([
                    "cwd": .string("/Users/me/work/repo"),
                    "skills": .array(skills),
                ]),
            ]),
        ])
    }

    private func makeSkillJSON(
        name: String,
        provider: String,
        providers: [JSONValue]? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "description": .string("Skill \(name)"),
            "path": .string("/Users/me/work/repo/.agents/skills/\(name)/SKILL.md"),
            "scope": .string("project"),
            "provider": .string(provider),
            "enabled": .bool(true),
        ]
        if let providers {
            object["providers"] = .array(providers)
        }
        return .object(object)
    }

    private func makeThread(cwd: String) -> CodexThread {
        CodexThread(
            id: "thread-skills",
            cwd: cwd
        )
    }

    private func makeViewModel() -> TurnViewModel {
        let viewModel = TurnViewModel()
        Self.retainedViewModels.append(viewModel)
        return viewModel
    }

    private func makeService() -> CodexService {
        let suiteName = "TurnViewModelSkillsAutocompleteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]
        Self.retainedServices.append(service)
        return service
    }
}