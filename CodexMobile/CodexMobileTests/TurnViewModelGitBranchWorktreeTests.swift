// FILE: TurnViewModelGitBranchWorktreeTests.swift
// Purpose: Verifies worktree-backed branches are exposed to the UI only when Git reports them as checked out elsewhere.
// Layer: Unit Test
// Exports: TurnViewModelGitBranchWorktreeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnViewModelGitBranchWorktreeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TurnViewModel.resetGitBranchTargetsCacheForTests()
    }

    func testWorktreePathResolvesOnlyForBranchesCheckedOutElsewhere() {
        let viewModel = TurnViewModel()
        viewModel.gitBranchesCheckedOutElsewhere = ["remodex/feature-a"]
        viewModel.gitWorktreePathsByBranch = [
            "remodex/feature-a": "/tmp/remodex-feature-a",
            "main": "/tmp/remodex-main"
        ]

        XCTAssertEqual(
            viewModel.worktreePathForCheckedOutElsewhereBranch("remodex/feature-a"),
            "/tmp/remodex-feature-a"
        )
        XCTAssertNil(viewModel.worktreePathForCheckedOutElsewhereBranch("main"))
        XCTAssertNil(viewModel.worktreePathForCheckedOutElsewhereBranch("remodex/missing"))
    }

    func testPrepareGitPresentationKeepsWarmStateWithinSameRepo() {
        let viewModel = TurnViewModel()
        viewModel.prepareGitPresentationForDisplayedThread(workingDirectory: "/tmp/repo")
        viewModel.currentGitBranch = "feature"
        viewModel.gitDefaultBranch = "main"
        viewModel.availableGitBranchTargets = ["feature", "main"]
        viewModel.gitRepoSync = makeGitRepoSync(
            repoRoot: "/tmp/repo",
            branch: "feature",
            tracking: "origin/feature"
        )
        viewModel.noteGitBranchTargetsRefreshed(
            workingDirectory: "/tmp/repo",
            now: Date(timeIntervalSince1970: 100)
        )

        viewModel.prepareGitPresentationForDisplayedThread(workingDirectory: "/tmp/repo")

        XCTAssertEqual(viewModel.currentGitBranch, "feature")
        XCTAssertEqual(viewModel.gitDefaultBranch, "main")
        XCTAssertEqual(viewModel.availableGitBranchTargets, ["feature", "main"])
        XCTAssertFalse(
            viewModel.shouldRefreshGitBranchTargetsOnOpen(
                workingDirectory: "/tmp/repo",
                now: Date(timeIntervalSince1970: 105)
            )
        )
    }

    func testPrepareGitPresentationClearsStaleStateWhenRepoChanges() {
        let viewModel = TurnViewModel()
        viewModel.prepareGitPresentationForDisplayedThread(workingDirectory: "/tmp/repo-a")
        viewModel.currentGitBranch = "feature-a"
        viewModel.gitDefaultBranch = "main"
        viewModel.availableGitBranchTargets = ["feature-a", "main"]
        viewModel.gitRepoSync = makeGitRepoSync(
            repoRoot: "/tmp/repo-a",
            branch: "feature-a",
            tracking: "origin/feature-a"
        )

        viewModel.prepareGitPresentationForDisplayedThread(workingDirectory: "/tmp/repo-b")

        XCTAssertEqual(viewModel.currentGitBranch, "")
        XCTAssertEqual(viewModel.gitDefaultBranch, "")
        XCTAssertTrue(viewModel.availableGitBranchTargets.isEmpty)
        XCTAssertNil(viewModel.gitRepoSync)
        XCTAssertTrue(viewModel.shouldRefreshGitBranchTargetsOnOpen(workingDirectory: "/tmp/repo-b"))
    }

    func testWarmGitBranchStateExpiresAfterMinimumInterval() {
        let viewModel = TurnViewModel()
        viewModel.prepareGitPresentationForDisplayedThread(workingDirectory: "/tmp/repo")
        viewModel.currentGitBranch = "feature"
        viewModel.gitDefaultBranch = "main"
        viewModel.availableGitBranchTargets = ["feature", "main"]
        viewModel.gitRepoSync = makeGitRepoSync(
            repoRoot: "/tmp/repo",
            branch: "feature",
            tracking: "origin/feature"
        )
        viewModel.noteGitBranchTargetsRefreshed(
            workingDirectory: "/tmp/repo",
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertFalse(
            viewModel.shouldRefreshGitBranchTargetsOnOpen(
                workingDirectory: "/tmp/repo",
                now: Date(timeIntervalSince1970: 111)
            )
        )
        XCTAssertTrue(
            viewModel.shouldRefreshGitBranchTargetsOnOpen(
                workingDirectory: "/tmp/repo",
                now: Date(timeIntervalSince1970: 113)
            )
        )
    }

    func testPassiveRefreshKeepsBranchLoadingIndicatorHidden() async {
        let viewModel = TurnViewModel()
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        service.requestTransportOverride = { method, _ in
            guard method == "git/branchesWithStatus" else {
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([:]),
                    includeJSONRPC: false
                )
            }

            try? await Task.sleep(nanoseconds: 40_000_000)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "branches": .array([.string("main"), .string("remodex/feature-a")]),
                    "current": .string("main"),
                    "default": .string("main"),
                    "status": .object([
                        "branch": .string("main"),
                        "tracking": .string("origin/main"),
                        "state": .string("up_to_date"),
                        "dirty": .bool(false),
                        "ahead": .integer(0),
                        "behind": .integer(0),
                        "canPush": .bool(false),
                        "publishedToRemote": .bool(true),
                        "files": .array([])
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        viewModel.refreshGitBranchTargets(
            codex: service,
            workingDirectory: "/tmp/remodex",
            threadID: "thread-a",
            requestTimeoutMs: GitActionsService.passiveRequestTimeoutMs,
            force: true,
            showsLoadingIndicator: false
        )

        await Task.yield()
        XCTAssertFalse(viewModel.isLoadingGitBranchTargets)

        while viewModel.availableGitBranchTargets.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.availableGitBranchTargets, ["main", "remodex/feature-a"])
        XCTAssertEqual(viewModel.currentGitBranch, "main")
        XCTAssertFalse(viewModel.isLoadingGitBranchTargets)
    }

    func testPrepareGitPresentationSeedsWarmStateFromSharedCache() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true

        let workingDirectory = "/tmp/remodex-\(UUID().uuidString)"
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "git/branchesWithStatus")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "branches": .array([.string("main"), .string("remodex/feature-a")]),
                    "current": .string("remodex/feature-a"),
                    "default": .string("main"),
                    "status": .object([
                        "repoRoot": .string(workingDirectory),
                        "branch": .string("remodex/feature-a"),
                        "tracking": .string("origin/remodex/feature-a"),
                        "state": .string("up_to_date"),
                        "dirty": .bool(false),
                        "ahead": .integer(0),
                        "behind": .integer(0),
                        "canPush": .bool(false),
                        "publishedToRemote": .bool(true),
                        "files": .array([])
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let firstViewModel = TurnViewModel()
        firstViewModel.refreshGitBranchTargets(
            codex: service,
            workingDirectory: workingDirectory,
            threadID: "thread-a",
            requestTimeoutMs: GitActionsService.passiveRequestTimeoutMs,
            force: true,
            showsLoadingIndicator: false
        )

        while firstViewModel.availableGitBranchTargets.isEmpty {
            await Task.yield()
        }

        let secondViewModel = TurnViewModel()
        secondViewModel.prepareGitPresentationForDisplayedThread(workingDirectory: workingDirectory)

        XCTAssertEqual(secondViewModel.currentGitBranch, "remodex/feature-a")
        XCTAssertEqual(secondViewModel.gitDefaultBranch, "main")
        XCTAssertEqual(secondViewModel.availableGitBranchTargets, ["main", "remodex/feature-a"])
        XCTAssertEqual(secondViewModel.gitRepoSync?.currentBranch, "remodex/feature-a")
        XCTAssertFalse(secondViewModel.shouldRefreshGitBranchTargetsOnOpen(workingDirectory: workingDirectory))
    }

    private func makeService() -> CodexService {
        let suiteName = "TurnViewModelGitBranchWorktreeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return CodexService(defaults: defaults)
    }

    private func makeGitRepoSync(
        repoRoot: String,
        branch: String,
        tracking: String
    ) -> GitRepoSyncResult {
        GitRepoSyncResult(from: [
            "repoRoot": .string(repoRoot),
            "branch": .string(branch),
            "tracking": .string(tracking),
            "dirty": .bool(false),
            "ahead": .integer(0),
            "behind": .integer(0),
            "localOnlyCommitCount": .integer(0),
            "state": .string("up_to_date"),
            "canPush": .bool(false),
            "publishedToRemote": .bool(true),
            "files": .array([]),
        ])
    }
}
