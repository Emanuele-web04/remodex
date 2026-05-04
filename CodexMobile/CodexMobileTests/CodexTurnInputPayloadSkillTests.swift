// FILE: CodexTurnInputPayloadSkillTests.swift
// Purpose: Verifies turn/start input payload generation when structured skill items are enabled/disabled.
// Layer: Unit Test
// Exports: CodexTurnInputPayloadSkillTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class CodexTurnInputPayloadSkillTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testMakeTurnInputPayloadIncludesStructuredSkillItemsWhenEnabled() {
        let service = makeService()
        let payload = service.makeTurnInputPayload(
            userInput: "Run $review",
            attachments: [],
            imageURLKey: "url",
            skillMentions: [
                CodexTurnSkillMention(
                    id: "review",
                    name: "review",
                    path: "/Users/me/work/repo/.agents/skills/review/SKILL.md"
                ),
            ],
            includeStructuredSkillItems: true
        )

        let skillItem = payload
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "skill" })

        XCTAssertEqual(skillItem?["id"]?.stringValue, "review")
        XCTAssertEqual(skillItem?["name"]?.stringValue, "review")
        XCTAssertEqual(skillItem?["path"]?.stringValue, "/Users/me/work/repo/.agents/skills/review/SKILL.md")
    }

    func testMakeTurnInputPayloadSkipsStructuredSkillItemsWhenDisabled() {
        let service = makeService()
        let payload = service.makeTurnInputPayload(
            userInput: "Run $review",
            attachments: [],
            imageURLKey: "url",
            skillMentions: [
                CodexTurnSkillMention(id: "review", name: "review", path: nil),
            ],
            includeStructuredSkillItems: false
        )

        let hasSkillItem = payload
            .compactMap(\.objectValue)
            .contains(where: { $0["type"]?.stringValue == "skill" })

        XCTAssertFalse(hasSkillItem)
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexTurnInputPayloadSkillTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]

        Self.retainedServices.append(service)
        return service
    }
}
