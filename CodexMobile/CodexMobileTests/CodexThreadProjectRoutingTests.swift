// FILE: CodexThreadProjectRoutingTests.swift
// Purpose: Verifies same-thread project rebind behavior for managed worktree handoff flows.
// Layer: Unit Test
// Exports: CodexThreadProjectRoutingTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadProjectRoutingTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testStartThreadIfReadyWaitsForRuntimeInitializationDuringReconnect() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = false

        var didStartThread = false
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/start")
            XCTAssertTrue(service.isInitialized)
            didStartThread = true
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-new"),
                        "cwd": .string("/tmp/remodex-local"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let readinessTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            service.isInitialized = true
        }
        defer { readinessTask.cancel() }

        let thread = try await service.startThreadIfReady(preferredProjectPath: "/tmp/remodex-local")

        XCTAssertTrue(didStartThread)
        XCTAssertEqual(thread.id, "thread-new")
        XCTAssertEqual(service.activeThreadId, "thread-new")
    }

    func testMoveThreadToProjectPathKeepsRebindWhenResumeFailsOnlyBecauseRolloutIsMissing() async throws {
        let service = makeService()
        let originalThread = CodexThread(
            id: "thread-1",
            title: "Source",
            cwd: "/tmp/remodex-local"
        )
        service.upsertThread(originalThread)
        service.activeThreadId = "thread-1"
        service.resumedThreadIDs = ["thread-1"]

        var resumeRequests: [[String: JSONValue]] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/resume")
            resumeRequests.append(params?.objectValue ?? [:])
            throw CodexServiceError.rpcError(
                RPCError(code: -32600, message: "no rollout found for thread id thread-1")
            )
        }

        let movedThread = try await service.moveThreadToProjectPath(
            threadId: "thread-1",
            projectPath: "/tmp/remodex-worktree"
        )

        XCTAssertEqual(resumeRequests.count, 1)
        XCTAssertEqual(resumeRequests.first?["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(resumeRequests.first?["cwd"]?.stringValue, "/tmp/remodex-worktree")
        XCTAssertEqual(movedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.currentAuthoritativeProjectPath(for: "thread-1"), "/tmp/remodex-worktree")
        XCTAssertEqual(service.activeThreadId, "thread-1")
        XCTAssertFalse(service.resumedThreadIDs.contains("thread-1"))
    }

    func testRolloutMissingFallbackStillRejectsImmediateStaleServerProjectPath() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            )
        )
        service.activeThreadId = "thread-1"

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/resume")
            throw CodexServiceError.rpcError(
                RPCError(code: -32600, message: "no rollout found for thread id thread-1")
            )
        }

        _ = try await service.moveThreadToProjectPath(
            threadId: "thread-1",
            projectPath: "/tmp/remodex-worktree"
        )

        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.currentAuthoritativeProjectPath(for: "thread-1"), "/tmp/remodex-worktree")

        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-worktree"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertNil(service.currentAuthoritativeProjectPath(for: "thread-1"))
    }

    func testServerStateCannotOverwriteAuthoritativeRebindUntilMatchingPathArrives() {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            )
        )

        service.beginAuthoritativeProjectPathTransition(
            threadId: "thread-1",
            projectPath: "/tmp/remodex-worktree"
        )

        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.currentAuthoritativeProjectPath(for: "thread-1"), "/tmp/remodex-worktree")

        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-worktree"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "thread-1")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertNil(service.currentAuthoritativeProjectPath(for: "thread-1"))
    }

    func testManagedWorktreeAssociationPersistsAcrossLocalHandoffs() async throws {
        let service = makeService()
        service.upsertThread(
            CodexThread(
                id: "thread-1",
                title: "Source",
                cwd: "/tmp/remodex-local"
            )
        )

        var resumeResponses: [String] = []
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/resume")
            let cwd = params?.objectValue?["cwd"]?.stringValue ?? ""
            resumeResponses.append(cwd)
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("thread-1"),
                        "cwd": .string(cwd),
                        "title": .string("Source"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let worktreePath = "/Users/me/.codex/worktrees/a1b2/remodex"
        _ = try await service.moveThreadToProjectPath(threadId: "thread-1", projectPath: worktreePath)
        _ = try await service.moveThreadToProjectPath(threadId: "thread-1", projectPath: "/tmp/remodex-local")

        XCTAssertEqual(resumeResponses, [worktreePath, "/tmp/remodex-local"])
        XCTAssertEqual(service.associatedManagedWorktreePath(for: "thread-1"), worktreePath)
    }

    func testManagedWorktreeAssociationIsScopedPerMac() {
        let suiteName = "CodexThreadProjectRoutingTests.macScope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = makeService(defaults: defaults)
        let macA = "mac-a-\(UUID().uuidString)"
        let macB = "mac-b-\(UUID().uuidString)"

        service.setCurrentTrustedMacDeviceId(macA)
        service.rememberAssociatedManagedWorktreePath("/tmp/worktree-a", for: "thread-a")
        service.planSessionSourceByThread["thread-a"] = .requested

        service.setCurrentTrustedMacDeviceId(macB)
        service.loadMacScopedDefaultsState(for: macB)
        service.rememberAssociatedManagedWorktreePath("/tmp/worktree-b", for: "thread-b")
        service.planSessionSourceByThread["thread-b"] = .compatibilityFallback

        service.setCurrentTrustedMacDeviceId(macA)
        service.loadMacScopedDefaultsState(for: macA)
        XCTAssertEqual(service.associatedManagedWorktreePath(for: "thread-a"), "/tmp/worktree-a")
        XCTAssertNil(service.associatedManagedWorktreePath(for: "thread-b"))
        XCTAssertEqual(service.planSessionSourceByThread["thread-a"], .requested)
        XCTAssertNil(service.planSessionSourceByThread["thread-b"])

        service.setCurrentTrustedMacDeviceId(macB)
        service.loadMacScopedDefaultsState(for: macB)
        XCTAssertEqual(service.associatedManagedWorktreePath(for: "thread-b"), "/tmp/worktree-b")
        XCTAssertNil(service.associatedManagedWorktreePath(for: "thread-a"))
        XCTAssertEqual(service.planSessionSourceByThread["thread-b"], .compatibilityFallback)
        XCTAssertNil(service.planSessionSourceByThread["thread-a"])
    }

    func testClearInMemoryMacScopedStateClearsAuthoritativeProjectPathTransitions() {
        let service = makeService()

        service.beginAuthoritativeProjectPathTransition(
            threadId: "thread-1",
            projectPath: "/tmp/remodex-worktree"
        )

        service.clearInMemoryMacScopedState()

        XCTAssertNil(service.currentAuthoritativeProjectPath(for: "thread-1"))
    }

    func testProjectlessThreadResumeDoesNotInjectCwd() async throws {
        let service = makeService()
        service.upsertThread(CodexThread(id: "quick-chat", title: "Quick Chat", cwd: nil))

        var resumeParams: RPCObject?
        service.requestTransportOverride = { method, params in
            XCTAssertEqual(method, "thread/resume")
            resumeParams = params?.objectValue
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object([
                    "thread": .object([
                        "id": .string("quick-chat"),
                        "title": .string("Quick Chat"),
                    ]),
                ]),
                includeJSONRPC: false
            )
        }

        let resumedThread = try await service.ensureThreadResumed(
            threadId: "quick-chat",
            force: true
        )

        XCTAssertNil(resumeParams?["cwd"])
        XCTAssertNil(resumedThread?.gitWorkingDirectory)
        XCTAssertNil(service.thread(for: "quick-chat")?.gitWorkingDirectory)
    }

    func testProjectlessThreadTurnStartDoesNotInjectCwd() async throws {
        let service = makeService()
        service.upsertThread(CodexThread(id: "quick-chat", title: "Quick Chat", cwd: nil))

        var recordedMethods: [String] = []
        var resumeParams: RPCObject?
        var turnStartParams: RPCObject?
        service.requestTransportOverride = { method, params in
            recordedMethods.append(method)
            switch method {
            case "thread/resume":
                resumeParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("quick-chat"),
                            "title": .string("Quick Chat"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "turn/start":
                turnStartParams = params?.objectValue
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object(["turnId": .string("turn-quick-chat")]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method \(method)")
                return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
            }
        }

        try await service.startTurn(
            userInput: "follow up",
            threadId: "quick-chat",
            shouldAppendUserMessage: false
        )

        XCTAssertEqual(recordedMethods, ["thread/resume", "turn/start"])
        XCTAssertNil(resumeParams?["cwd"])
        XCTAssertNil(turnStartParams?["cwd"])
        XCTAssertEqual(turnStartParams?["threadId"]?.stringValue, "quick-chat")
        XCTAssertNil(service.thread(for: "quick-chat")?.gitWorkingDirectory)
    }

    private func makeService(defaults: UserDefaults? = nil) -> CodexService {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else {
            let suiteName = "CodexThreadProjectRoutingTests.\(UUID().uuidString)"
            let isolatedDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            isolatedDefaults.removePersistentDomain(forName: suiteName)
            resolvedDefaults = isolatedDefaults
        }

        let service = CodexService(defaults: resolvedDefaults)
        Self.retainedServices.append(service)
        return service
    }
}
