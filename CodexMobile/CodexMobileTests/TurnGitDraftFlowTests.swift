// FILE: TurnGitDraftFlowTests.swift
// Purpose: Verifies git draft generation is used before commit and PR URLs include GitHub prefill params.
// Layer: Unit Test
// Exports: TurnGitDraftFlowTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnGitDraftFlowTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testFirstTurnGeneratesAutomaticThreadTitle() async throws {
        let service = makeService()
        service.availableModels = [
            makeModel(id: "gpt-5.4-mini"),
        ]
        service.threads = [
            CodexThread(id: "thread-1", title: CodexThread.defaultDisplayTitle),
        ]
        service.resumedThreadIDs.insert("thread-1")

        var recordedMethods: [String] = []
        let titleExpectation = expectation(description: "Thread title generation completes")
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "turn/start":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-1")]),
                    includeJSONRPC: false
                )
            case "thread/generateTitle":
                XCTAssertEqual(
                    params?.objectValue?["message"]?.stringValue,
                    "Fix the sidebar thread naming after the first message"
                )
                titleExpectation.fulfill()
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["title": .string("Fix Thread Naming")]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method: \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.startTurn(
            userInput: "Fix the sidebar thread naming after the first message",
            threadId: "thread-1"
        )
        await fulfillment(of: [titleExpectation], timeout: 2.0)

        XCTAssertEqual(recordedMethods, ["turn/start", "thread/generateTitle"])
        XCTAssertEqual(service.thread(for: "thread-1")?.displayTitle, "Fix Thread Naming")
    }

    func testAutomaticThreadTitleDoesNotOverwriteUserRename() {
        let service = makeService()
        service.threads = [
            CodexThread(id: "thread-1", title: CodexThread.defaultDisplayTitle),
        ]

        service.renameThread("thread-1", name: "Manual Title")
        let didApply = service.applyAutomaticThreadTitle(
            "Generated Title",
            for: "thread-1",
            replacing: [CodexThread.defaultDisplayTitle, "Fix thread naming"]
        )

        XCTAssertFalse(didApply)
        XCTAssertEqual(service.thread(for: "thread-1")?.displayTitle, "Manual Title")
    }

    func testAutomaticThreadTitleOnlyReplacesExpectedFallbackTitles() {
        let service = makeService()
        service.threads = [
            CodexThread(id: "thread-1", title: "Server Title", name: "Fallback Title"),
        ]

        let didApply = service.applyAutomaticThreadTitle(
            "Generated Title",
            for: "thread-1",
            replacing: [CodexThread.defaultDisplayTitle, "Fallback Title"]
        )

        XCTAssertFalse(didApply)
        XCTAssertEqual(service.thread(for: "thread-1")?.displayTitle, "Fallback Title")
    }

    func testCommitActionGeneratesDraftBeforeCommitting() async throws {
        let service = makeService()
        service.availableModels = [
            makeModel(id: "gpt-5.4-mini"),
        ]

        var recordedMethods: [String] = []
        var committedMessage: String?
        let commitExpectation = expectation(description: "Commit flow completes")
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            if method == "git/runStackedAction" {
                committedMessage = params?.objectValue?["commitMessage"]?.stringValue
                XCTAssertEqual(params?.objectValue?["action"]?.stringValue, "commit")
                commitExpectation.fulfill()
            }

            switch method {
            case "git/generateCommitMessage":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "subject": .string("Update git flow"),
                        "body": .string("- Draft a commit message before committing\n- Refresh status after the commit"),
                        "fullMessage": .string("Update git flow\n\n- Draft a commit message before committing\n- Refresh status after the commit"),
                    ]),
                    includeJSONRPC: false
                )
            case "git/runStackedAction":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "action": .string("commit"),
                        "commit": .object([
                            "status": .string("created"),
                            "hash": .string("abc123"),
                            "branch": .string("remodex/topic"),
                            "summary": .string("1 file changed"),
                        ]),
                        "push": .object(["status": .string("skipped_not_requested")]),
                        "pr": .object(["status": .string("skipped_not_requested")]),
                        "status": .object([
                            "branch": .string("remodex/topic"),
                            "tracking": .string("origin/remodex/topic"),
                            "dirty": .bool(false),
                            "ahead": .integer(0),
                            "behind": .integer(0),
                            "localOnlyCommitCount": .integer(0),
                            "state": .string("up_to_date"),
                            "canPush": .bool(false),
                            "publishedToRemote": .bool(true),
                            "files": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method: \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        let viewModel = TurnViewModel()
        viewModel.triggerGitAction(
            .commit,
            codex: service,
            workingDirectory: "/tmp/project",
            threadID: "thread-1",
            activeTurnID: nil
        )

        await fulfillment(of: [commitExpectation], timeout: 2.0)

        XCTAssertEqual(Array(recordedMethods.prefix(2)), ["git/generateCommitMessage", "git/runStackedAction"])
        XCTAssertEqual(
            committedMessage,
            "Update git flow\n\n- Draft a commit message before committing\n- Refresh status after the commit"
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "TurnGitDraftFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeModel(id: String) -> CodexModelOption {
        CodexModelOption(
            id: id,
            model: id,
            displayName: id.uppercased(),
            description: "Test model",
            isDefault: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: "Medium"),
            ],
            defaultReasoningEffort: "medium"
        )
    }
}
