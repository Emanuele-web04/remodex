// FILE: CodexApprovalResponsePayloadTests.swift
// Purpose: Verifies approval replies match each app-server approval response shape.
// Layer: Unit Test
// Exports: CodexApprovalResponsePayloadTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexApprovalResponsePayloadTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testApprovalDecisionResultWrapsAcceptInDecisionObject() {
        let service = makeService()

        XCTAssertEqual(
            service.approvalDecisionResult("accept"),
            .object(["decision": .string("accept")])
        )
    }

    func testApprovalDecisionResultWrapsAcceptForSessionInDecisionObject() {
        let service = makeService()

        XCTAssertEqual(
            service.approvalDecisionResult("acceptForSession"),
            .object(["decision": .string("acceptForSession")])
        )
    }

    func testApprovalDecisionResultWrapsDeclineInDecisionObject() {
        let service = makeService()

        XCTAssertEqual(
            service.approvalDecisionResult("decline"),
            .object(["decision": .string("decline")])
        )
    }

    func testCommandApprovalResponseKeepsDecisionObjectShape() {
        let service = makeService()
        let request = CodexApprovalRequest(
            id: "approval-1",
            requestID: .string("approval-1"),
            method: "item/commandExecution/requestApproval",
            command: "npm test",
            reason: nil,
            threadId: "thread-1",
            turnId: "turn-1",
            params: nil
        )

        XCTAssertEqual(
            service.approvalResponseResult(for: request, decision: "accept", forSession: true),
            .object(["decision": .string("acceptForSession")])
        )
    }

    func testPermissionsApprovalResponseGrantsRequestedPermissionsForTurn() {
        let service = makeService()
        let requestedPermissions: JSONValue = .object([
            "network": .object(["enabled": .bool(true)]),
        ])
        let request = CodexApprovalRequest(
            id: "permissions-1",
            requestID: .string("permissions-1"),
            method: "item/permissions/requestApproval",
            command: nil,
            reason: "Need network access",
            threadId: "thread-1",
            turnId: "turn-1",
            params: .object(["permissions": requestedPermissions])
        )

        XCTAssertEqual(
            service.approvalResponseResult(for: request, decision: "accept"),
            .object([
                "permissions": requestedPermissions,
                "scope": .string("turn"),
            ])
        )
    }

    func testPermissionsDeclineResponseReturnsEmptyTurnGrant() {
        let service = makeService()
        let request = CodexApprovalRequest(
            id: "permissions-1",
            requestID: .string("permissions-1"),
            method: "item/permissions/requestApproval",
            command: nil,
            reason: nil,
            threadId: "thread-1",
            turnId: "turn-1",
            params: .object([
                "permissions": .object([
                    "fileSystem": .object(["read": .array([.string("/tmp")])]),
                ]),
            ])
        )

        XCTAssertEqual(
            service.approvalResponseResult(for: request, decision: "decline"),
            .object([
                "permissions": .object([:]),
                "scope": .string("turn"),
            ])
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexApprovalResponsePayloadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)

        Self.retainedServices.append(service)
        return service
    }
}
