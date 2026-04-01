// FILE: CodexApprovalResponsePayloadTests.swift
// Purpose: Verifies approval replies use the app-server decision object shape expected by manual approval flows.
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

    private func makeService() -> CodexService {
        let suiteName = "CodexApprovalResponsePayloadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)

        Self.retainedServices.append(service)
        return service
    }
}
