// FILE: CodexStructuredUserInputDecodeTests.swift
// Purpose: Verifies history/live decoders reconstruct `$skill` tokens from structured input items.
// Layer: Unit Test
// Exports: CodexStructuredUserInputDecodeTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexStructuredUserInputDecodeTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testDecodeItemTextReconstructsSkillMentionsFromStructuredInput() {
        let service = makeService()
        let itemObject: [String: JSONValue] = [
            "content": .array([
                .object([
                    "type": .string("skill"),
                    "id": .string("review"),
                ]),
                .object([
                    "type": .string("text"),
                    "text": .string("please check latest changes"),
                ]),
            ]),
        ]

        let decoded = service.decodeItemText(from: itemObject)

        XCTAssertEqual(decoded, "$review\nplease check latest changes")
    }

    func testExtractIncomingMessageTextReconstructsSkillMentionsFromStructuredInput() {
        let service = makeService()
        let itemObject: [String: JSONValue] = [
            "content": .array([
                .object([
                    "type": .string("skill"),
                    "name": .string("check-code"),
                ]),
                .object([
                    "type": .string("text"),
                    "text": .string("run the audit"),
                ]),
            ]),
        ]

        let decoded = service.extractIncomingMessageText(from: itemObject)

        XCTAssertEqual(decoded, "$check-code\nrun the audit")
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexStructuredUserInputDecodeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]

        Self.retainedServices.append(service)
        return service
    }
}
