// FILE: OpenCodePermissionQueueTests.swift
// Purpose: Verifies OpenCode permission queue semantics separate from Codex approvals.

import XCTest
@testable import CodexMobile

@MainActor
final class OpenCodePermissionQueueTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    override func setUp() {
        super.setUp()
        // Clear any previous test state
        Self.retainedServices.removeAll()
    }

    override func tearDown() {
        // Clean up services to prevent state leakage
        Self.retainedServices.removeAll()
        super.tearDown()
    }

    func testPendingOpenCodePermissionReturnsNilWhenNoMatchForThread() {
        let service = makeService()
        service.enqueuePendingOpenCodePermission(makePermission(id: "perm-1", threadId: "thread-a"))

        XCTAssertNil(service.pendingOpenCodePermission(for: "thread-b"))
        XCTAssertEqual(service.pendingOpenCodePermission(for: "thread-a")?.permissionId, "perm-1")
    }

    func testEnqueuePendingOpenCodePermissionIsFIFOPerThread() {
        let service = makeService()
        let first = makePermission(id: "perm-1", threadId: "thread-a")
        let second = makePermission(id: "perm-2", threadId: "thread-a")

        service.enqueuePendingOpenCodePermission(first)
        service.enqueuePendingOpenCodePermission(second)

        XCTAssertEqual(service.pendingOpenCodePermissions.count, 2)
        XCTAssertEqual(service.pendingOpenCodePermission(for: "thread-a")?.permissionId, "perm-1")
    }

    func testPendingOpenCodePermissionSurvivesTransportOnlyDisconnect() async {
        let service = makeService()
        service.isConnected = true
        service.enqueuePendingOpenCodePermission(makePermission(id: "perm-keep", threadId: "thread-1"))

        await service.disconnect(preserveReconnectIntent: true)

        XCTAssertEqual(service.pendingOpenCodePermissions.count, 1)
    }

    func testCodexPendingApprovalsRemainSeparate() {
        let service = makeService()
        service.enqueuePendingApproval(
            CodexApprovalRequest(
                id: "codex-1",
                requestID: .string("req"),
                method: "item/commandExecution/requestApproval",
                command: "ls",
                reason: nil,
                threadId: "thread-1",
                turnId: nil,
                params: nil
            )
        )
        service.enqueuePendingOpenCodePermission(makePermission(id: "perm-1", threadId: "thread-1"))

        XCTAssertEqual(service.pendingApprovals.count, 1)
        XCTAssertEqual(service.pendingOpenCodePermissions.count, 1)
    }

    func testDenyReplyRequiresPendingQueueEntry() async {
        let service = makeService()
        service.isConnected = true
        var requestCount = 0
        service.requestTransportOverride = { _, _ in
            requestCount += 1
            return RPCMessage(id: .string("1"), result: .object(["success": .bool(true)]), includeJSONRPC: false)
        }

        let request = makePermission(id: "perm-deny", threadId: "thread-deny")
        try? await service.replyToOpenCodePermission(request, allow: false, scope: .once)

        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(service.pendingOpenCodePermissions.isEmpty)
    }

    func testPermissionsUIDisabledAutoDeniesWithoutQueueing() async {
        let service = makeService()
        service.isConnected = true
        service.openCodePermissionsUIEnabledOverride = false
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "permission/reply")
            return RPCMessage(id: .string("1"), result: .object(["success": .bool(true)]), includeJSONRPC: false)
        }

        service.handleOpenCodePermissionRequest(paramsObject: [
            "permissionId": .string("perm-auto"),
            "threadId": .string("thread-auto"),
            "tool": .string("bash"),
            "args": .object(["command": .string("npm test")]),
        ])

        // Wait for async denial to complete with timeout
        try await withTimeout(seconds: 2.0) {
            while !service.pendingOpenCodePermissions.isEmpty {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        XCTAssertTrue(service.pendingOpenCodePermissions.isEmpty)
    }

    private func withTimeout(seconds: TimeInterval, operation: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }

            let result = await group.next()
            group.cancelAll()

            switch result {
            case .success:
                return
            case .failure(let error):
                if error is TimeoutError {
                    XCTFail("Operation timed out after \(seconds)s")
                } else {
                    throw error
                }
            case .none:
                XCTFail("Task group completed without result")
            }
        }
    }

    private struct TimeoutError: Error {}

    private func makePermission(id: String, threadId: String) -> OpenCodePermissionRequest {
        OpenCodePermissionRequest(
            permissionId: id,
            threadId: threadId,
            turnId: "turn-1",
            sessionId: "ses-1",
            tool: "bash",
            argsSummary: "npm test",
            cwd: "/tmp",
            receivedAt: Date()
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "OpenCodePermissionQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        Self.retainedServices.append(service)
        return service
    }
}