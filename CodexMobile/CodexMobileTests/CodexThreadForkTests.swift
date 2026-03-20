// FILE: CodexThreadForkTests.swift
// Purpose: Verifies native thread/fork payloads, cwd routing, and runtime compatibility fallback behavior.
// Layer: Unit Test
// Exports: CodexThreadForkTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexThreadForkTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testLocalForkUsesSourceThreadWorkingDirectory() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var capturedForkParams: [String: JSONValue] = [:]
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/fork":
                capturedForkParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "cwd": .string("/tmp/remodex"),
                        "thread": .object([
                            "id": .string("fork-local"),
                            "cwd": .string("/tmp/remodex"),
                            "title": .string("Fork Local"),
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
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)

        XCTAssertEqual(capturedForkParams["threadId"]?.stringValue, "source-thread")
        XCTAssertEqual(capturedForkParams["cwd"]?.stringValue, "/tmp/remodex")
        XCTAssertEqual(capturedForkParams["model"]?.stringValue, "gpt-5.4")
        XCTAssertEqual(capturedForkParams["modelProvider"]?.stringValue, "openai")
        XCTAssertEqual(service.activeThreadId, "fork-local")
        XCTAssertEqual(forkedThread.id, "fork-local")
        XCTAssertEqual(service.thread(for: "fork-local")?.gitWorkingDirectory, "/tmp/remodex")
    }

    func testWorktreeForkUsesProvidedProjectPath() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var capturedForkParams: [String: JSONValue] = [:]
        service.requestTransportOverride = { method, params in
            switch method {
            case "thread/fork":
                capturedForkParams = params?.objectValue ?? [:]
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "cwd": .string("/tmp/remodex-worktree"),
                        "thread": .object([
                            "id": .string("fork-worktree"),
                            "cwd": .string("/tmp/remodex-worktree"),
                            "title": .string("Fork Worktree"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-worktree"),
                            "cwd": .string("/tmp/remodex-worktree"),
                            "title": .string("Fork Worktree"),
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

        XCTAssertEqual(capturedForkParams["cwd"]?.stringValue, "/tmp/remodex-worktree")
        XCTAssertEqual(forkedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
    }

    func testForkStillReturnsCreatedThreadWhenHydrationFails() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var requestedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            requestedMethods.append(method)
            switch method {
            case "thread/fork":
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "cwd": .string("/tmp/remodex-worktree"),
                        "thread": .object([
                            "id": .string("fork-partial"),
                            "cwd": .string("/tmp/remodex-worktree"),
                            "title": .string("Fork Partial"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                throw CodexServiceError.disconnected
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(
            from: "source-thread",
            target: .projectPath("/tmp/remodex-worktree")
        )

        XCTAssertEqual(requestedMethods, ["thread/fork", "thread/resume"])
        XCTAssertEqual(forkedThread.id, "fork-partial")
        XCTAssertEqual(forkedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.activeThreadId, "fork-partial")
        XCTAssertEqual(service.thread(for: "fork-partial")?.gitWorkingDirectory, "/tmp/remodex-worktree")
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
                            "cwd": .string("/tmp/remodex"),
                            "title": .string("Fork Local"),
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

    func testForkAssignsLocalTimestampsWhenResponseOmitsThem() async throws {
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
                            "cwd": .string("/tmp/remodex"),
                            "title": .string("Fork Local"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                throw CodexServiceError.disconnected
            default:
                XCTFail("Unexpected method: \(method)")
                throw CodexServiceError.invalidInput("Unexpected method")
            }
        }

        let forkedThread = try await service.forkThreadIfReady(from: "source-thread", target: .currentProject)

        XCTAssertNotNil(forkedThread.createdAt)
        XCTAssertNotNil(forkedThread.updatedAt)
        XCTAssertNotNil(service.thread(for: "fork-local")?.updatedAt)
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
                            "cwd": .string("/tmp/remodex"),
                            "title": .string("Fork Local"),
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

    func testForkFallsBackToMinimalRequestWhenOverridesAreRejected() async throws {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var forkRequests: [[String: JSONValue]] = []
        var resumeRequests: [[String: JSONValue]] = []
        var forkAttemptCount = 0

        service.requestTransportOverride = { method, params in
            let object = params?.objectValue ?? [:]
            switch method {
            case "thread/fork":
                forkAttemptCount += 1
                forkRequests.append(object)
                if forkAttemptCount == 1 {
                    throw CodexServiceError.rpcError(
                        RPCError(code: -32602, message: "Invalid params: unknown field modelProvider")
                    )
                }

                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-minimal"),
                            "cwd": .string("/tmp/remodex"),
                            "title": .string("Fork Minimal"),
                        ]),
                    ]),
                    includeJSONRPC: false
                )
            case "thread/resume":
                resumeRequests.append(object)
                return RPCMessage(
                    id: .string(UUID().uuidString),
                    result: .object([
                        "thread": .object([
                            "id": .string("fork-minimal"),
                            "cwd": .string("/tmp/remodex-worktree"),
                            "title": .string("Fork Minimal"),
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

        XCTAssertEqual(forkRequests.count, 2)
        XCTAssertEqual(forkRequests.first?["cwd"]?.stringValue, "/tmp/remodex-worktree")
        XCTAssertEqual(forkRequests.first?["modelProvider"]?.stringValue, "openai")
        XCTAssertEqual(forkRequests.last?["threadId"]?.stringValue, "source-thread")
        XCTAssertNil(forkRequests.last?["cwd"])
        XCTAssertNil(forkRequests.last?["model"])
        XCTAssertNil(forkRequests.last?["modelProvider"])
        XCTAssertEqual(resumeRequests.count, 1)
        XCTAssertEqual(resumeRequests.first?["threadId"]?.stringValue, "fork-minimal")
        XCTAssertEqual(resumeRequests.first?["cwd"]?.stringValue, "/tmp/remodex-worktree")
        XCTAssertEqual(resumeRequests.first?["model"]?.stringValue, "gpt-5.4")
        XCTAssertEqual(forkedThread.gitWorkingDirectory, "/tmp/remodex-worktree")
        XCTAssertEqual(service.thread(for: "fork-minimal")?.gitWorkingDirectory, "/tmp/remodex-worktree")
    }

    func testForkDoesNotFallbackWhenOverrideValueIsUnsupported() async {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.threads = [makeSourceThread()]

        var forkRequestCount = 0
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "thread/fork")
            forkRequestCount += 1
            throw CodexServiceError.rpcError(
                RPCError(code: -32000, message: "model gpt-5.4 not supported")
            )
        }

        do {
            _ = try await service.forkThreadIfReady(
                from: "source-thread",
                target: .projectPath("/tmp/remodex-worktree")
            )
            XCTFail("Expected unsupported model value to fail without retry")
        } catch {
            XCTAssertEqual(forkRequestCount, 1)
        }
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
            XCTAssertEqual(
                service.bridgeUpdatePrompt?.message,
                "This Mac bridge does not support native conversation forks yet. Update the Remodex npm package to use /fork and worktree fork flows."
            )
            XCTAssertEqual(service.bridgeUpdatePrompt?.command, "npm install -g remodex@latest")
        }
    }

    func testLocalForkFallsBackToCurrentWorktreeWhenLocalCheckoutIsUnavailable() {
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

        let fallbackPath = TurnThreadForkCoordinator.localForkProjectPath(
            for: worktreeThread,
            localCheckoutPath: nil
        )

        XCTAssertEqual(fallbackPath, worktreePath.path)
    }

    func testLocalForkAcceptsRemotePathsWithoutCheckingClientFilesystem() {
        let worktreeThread = CodexThread(
            id: "source-thread",
            title: "Source",
            cwd: "/Users/emanueledipietro/.codex/worktrees/a8b4/phodex-website",
            model: "gpt-5.4",
            modelProvider: "openai"
        )

        let localForkPath = TurnThreadForkCoordinator.localForkProjectPath(
            for: worktreeThread,
            localCheckoutPath: "/Users/emanueledipietro/Developer/Remodex/phodex-website"
        )

        XCTAssertEqual(localForkPath, "/Users/emanueledipietro/Developer/Remodex/phodex-website")
    }

    func testLocalForkIsUnavailableWhenCurrentWorktreeHasBeenRemoved() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missingWorktreePath = tempRoot
            .appendingPathComponent(".codex/worktrees/a8b4/phodex-website", isDirectory: true)

        let worktreeThread = CodexThread(
            id: "source-thread",
            title: "Source",
            cwd: missingWorktreePath.path,
            model: "gpt-5.4",
            modelProvider: "openai"
        )

        let fallbackPath = TurnThreadForkCoordinator.localForkProjectPath(
            for: worktreeThread,
            localCheckoutPath: nil,
            pathValidator: existingDirectoryPath
        )

        XCTAssertNil(fallbackPath)
    }

    private func existingDirectoryPath(_ rawPath: String?) -> String? {
        guard let rawPath else {
            return nil
        }

        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return trimmedPath
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
