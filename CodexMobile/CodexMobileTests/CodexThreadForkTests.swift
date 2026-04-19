// FILE: CodexThreadForkTests.swift
// Purpose: Verifies native thread/fork payloads, hydration, and unsupported-runtime handling.
// Layer: Unit Test
// Exports: CodexThreadForkTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadForkTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testForkSendsOnlyThreadIdToThreadFork() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var capturedForkParams: [String: JSONValue] = [:]
        var capturedResumeParams: [String: JSONValue] = [:]
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/fork":
                capturedForkParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                capturedResumeParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                            "cwd": .string("/tmp/remodex-worktree"),
                            "title": .string("Fork Local"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                            "cwd": .string("/tmp/remodex-worktree"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(
            from: "source-thread",
            target: .projectPath("/tmp/remodex-worktree")
        )

        XCTAssertEqual(capturedForkParams["threadId"]?.stringValue, "source-thread")
        XCTAssertEqual(capturedForkParams.count, 1)
        XCTAssertEqual(capturedResumeParams["threadId"]?.stringValue, "fork-local")
        XCTAssertEqual(capturedResumeParams["cwd"]?.stringValue, "/tmp/remodex-worktree")
        XCTAssertEqual(forkedThread.id, "fork-local")
        XCTAssertEqual(forkedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.activeThreadId, "fork-local")
    }

    func testForkMarksCreatedThreadAsForkedFromSource() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        service.requestTransportOverride = { method, _ in
            switch method {
            case "thread/fork":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                            "cwd": .string("/tmp/remodex"),
                            "title": .string("Fork Local"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                            "cwd": .string("/tmp/remodex"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)

        XCTAssertEqual(forkedThread.forkedFromThreadId, "source-thread")
        XCTAssertTrue(forkedThread.isForkedThread)
        XCTAssertEqual(service.thread(for: "fork-local")?.forkedFromThreadId, "source-thread")
    }

    func testPersistedForkOriginRehydratesAfterServiceReload() async throws {
        let suiteName = "CodexThreadForkTests.persistedForkOrigin.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let service = makeService(defaults: defaults)
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        service.requestTransportOverride = { method, _ in
            switch method {
            case "thread/fork":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                            "cwd": .string("/tmp/remodex"),
                            "title": .string("Fork Local"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/read":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                            "cwd": .string("/tmp/remodex"),
                            "turns": .array([]),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        _ = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)

        let reloadedService = makeService(defaults: defaults)
        reloadedService.upsertThread(
            CodexThread(
                id: "fork-local",
                title: "Fork Local",
                cwd: "/tmp/remodex"
            )
        )

        XCTAssertEqual(reloadedService.thread(for: "fork-local")?.forkedFromThreadId, "source-thread")
        XCTAssertTrue(reloadedService.thread(for: "fork-local")?.isForkedThread == true)
    }

    func testUnsupportedThreadForkDisablesCapabilityAndShowsUpdatePrompt() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/fork")
            throw CodexServiceError.rpcError(
                RPCError(code: -32601, message: "Method not found: thread/fork")
            )
        }

        do {
            _ = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)
            XCTFail("Expected thread/fork to fail")
        } catch {
            XCTAssertFalse(service.supportsThreadFork)
            XCTAssertEqual(service.bridgeUpdatePrompt?.title, "Update Remodex on your Mac to use /fork")
        }
    }

    func testForkKeepsAuthoritativeProjectPathWhenResumeFallsBackToMissingRollout() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        service.requestTransportOverride = { method, _ in
            switch method {
            case "thread/fork":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-local"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                throw CodexServiceError.rpcError(
                    RPCError(code: -32600, message: "no rollout found for thread id fork-local")
                )
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(
            from: "source-thread",
            target: .projectPath("/tmp/remodex-worktree")
        )

        XCTAssertEqual(forkedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.currentAuthoritativeProjectPath(for: "fork-local"), "/tmp/remodex-worktree")

        service.upsertThread(
            CodexThread(
                id: "fork-local",
                title: "Fork Local",
                cwd: "/tmp/remodex"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "fork-local")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.currentAuthoritativeProjectPath(for: "fork-local"), "/tmp/remodex-worktree")

        service.upsertThread(
            CodexThread(
                id: "fork-local",
                title: "Fork Local",
                cwd: "/tmp/remodex-worktree"
            ),
            treatAsServerState: true
        )

        XCTAssertEqual(service.thread(for: "fork-local")?.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertNil(service.currentAuthoritativeProjectPath(for: "fork-local"))
    }

    func testLocalForkReturnsNilWhenWorktreeThreadHasNoLocalCheckout() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktreePath = tempRoot
            .appendingPathComponent(".codex/worktrees/a8b4/phodex-website", isDirectory: true)

        try? FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let worktreeThread = CodexThread(
            id: "source-thread",
            title: "Source",
            cwd: worktreePath.path,
            model: "gpt-5.4",
            modelProvider: "openai"
        )

        let fallbackPath = WorktreeFlowCoordinator.localForkProjectPath(
            for: worktreeThread,
            localCheckoutPath: nil
        )

        XCTAssertNil(fallbackPath)
    }

    private func makeService(defaults: UserDefaults? = nil) -> CodexService {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else {
            let suiteName = "CodexThreadForkTests.\(UUID().uuidString)"
            let isolatedDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            isolatedDefaults.removePersistentDomain(forName: suiteName)
            resolvedDefaults = isolatedDefaults
        }
        let service = CodexService(defaults: resolvedDefaults)
        Self.retainedServices.append(service)
        return service
    }

    private func makeSourceThread() -> CodexThread {
        CodexThread(
            id: "source-thread",
            title: "Source",
            cwd: "/tmp/remodex",
            model: "gpt-5.4",
            modelProvider: "openai"
        )
    }
}
