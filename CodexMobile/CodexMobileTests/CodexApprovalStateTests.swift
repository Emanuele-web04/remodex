// FILE: CodexApprovalStateTests.swift
// Purpose: Verifies approval requests queue safely, clean up on server resolution, and survive failed replies.
// Layer: Unit Test
// Exports: CodexApprovalStateTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexApprovalStateTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testIncomingApprovalRequestsQueueWithoutOverwritingDifferentThreads() {
        let service = makeService()
        let firstRequestID: JSONValue = .string("approval-1")
        let secondRequestID: JSONValue = .string("approval-2")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: firstRequestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                    "command": .string("git commit"),
                ]),
                includeJSONRPC: false
            )
        )
        service.handleIncomingRPCMessage(
            RPCMessage(
                id: secondRequestID,
                method: "item/fileChange/requestApproval",
                params: .object([
                    "threadId": .string("thread-b"),
                    "turnId": .string("turn-b"),
                    "reason": .string("Write file"),
                ]),
                includeJSONRPC: false
            )
        )

        XCTAssertEqual(service.pendingApprovals.count, 2)
        XCTAssertEqual(service.pendingApproval(for: "thread-a")?.id, service.idKey(from: firstRequestID))
        XCTAssertEqual(service.pendingApproval(for: "thread-b")?.id, service.idKey(from: secondRequestID))
    }

    func testServerRequestResolvedRemovesOnlyMatchingApproval() {
        let service = makeService()
        let firstRequestID: JSONValue = .string("approval-1")
        let secondRequestID: JSONValue = .string("approval-2")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: firstRequestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                ]),
                includeJSONRPC: false
            )
        )
        service.handleIncomingRPCMessage(
            RPCMessage(
                id: secondRequestID,
                method: "item/fileChange/requestApproval",
                params: .object([
                    "threadId": .string("thread-b"),
                    "turnId": .string("turn-b"),
                ]),
                includeJSONRPC: false
            )
        )

        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "serverRequest/resolved",
                params: .object([
                    "threadId": .string("thread-a"),
                    "requestId": firstRequestID,
                ]),
                includeJSONRPC: false
            )
        )

        XCTAssertEqual(service.pendingApprovals.count, 1)
        XCTAssertNil(service.pendingApproval(for: "thread-a"))
        XCTAssertEqual(service.pendingApproval(for: "thread-b")?.id, service.idKey(from: secondRequestID))
    }

    func testServerRequestResolvedDoesNotRemoveDifferentApprovalFromSameThread() {
        let service = makeService()
        let approvalRequestID: JSONValue = .string("approval-1")
        let structuredInputRequestID: JSONValue = .string("structured-input-1")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: approvalRequestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                ]),
                includeJSONRPC: false
            )
        )

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: structuredInputRequestID,
                method: "item/tool/requestUserInput",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                    "questions": .array([
                        .object([
                            "id": .string("question-1"),
                            "header": .string("Question"),
                            "question": .string("Choose one"),
                            "options": .array([
                                .object([
                                    "label": .string("Yes"),
                                    "description": .string("Confirm"),
                                ])
                            ]),
                        ])
                    ]),
                ]),
                includeJSONRPC: false
            )
        )

        service.handleIncomingRPCMessage(
            RPCMessage(
                method: "serverRequest/resolved",
                params: .object([
                    "threadId": .string("thread-a"),
                    "requestId": structuredInputRequestID,
                ]),
                includeJSONRPC: false
            )
        )

        XCTAssertEqual(service.pendingApprovals.count, 1)
        XCTAssertEqual(service.pendingApproval(for: "thread-a")?.id, service.idKey(from: approvalRequestID))
    }

    func testFailedApproveKeepsApprovalQueued() async {
        let service = makeService()
        let requestID: JSONValue = .string("approval-1")

        service.handleIncomingRPCMessage(
            RPCMessage(
                id: requestID,
                method: "item/commandExecution/requestApproval",
                params: .object([
                    "threadId": .string("thread-a"),
                    "turnId": .string("turn-a"),
                    "command": .string("git commit"),
                ]),
                includeJSONRPC: false
            )
        )

        let request = try XCTUnwrap(service.pendingApproval(for: "thread-a"))

        await XCTAssertThrowsErrorAsync(
            try await service.approvePendingRequest(request)
        )
        XCTAssertEqual(service.pendingApprovals.count, 1)
        XCTAssertEqual(service.pendingApproval(for: "thread-a")?.id, request.id)
    }

    func testApproveTreatsAlreadyResolvedRequestAsCompleted() async {
        let service = makeService()
        let viewModel = TurnViewModel()
        let request = CodexApprovalRequest(
            id: "approval-1",
            requestID: .string("approval-1"),
            method: "item/commandExecution/requestApproval",
            command: "git status",
            reason: nil,
            threadId: "thread-a",
            turnId: "turn-a",
            params: nil
        )

        let didSucceed = await withCheckedContinuation { continuation in
            viewModel.approve(request, codex: service) { didSucceed in
                continuation.resume(returning: didSucceed)
            }
        }

        XCTAssertTrue(didSucceed)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexApprovalStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)

        Self.retainedServices.append(service)
        return service
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
    }
}
