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

    func testMakeTurnInputPayloadIncludesPluginMentionItemsWhenEnabled() {
        let service = makeService()
        let payload = service.makeTurnInputPayload(
            userInput: "Use @gmail",
            attachments: [],
            imageURLKey: "url",
            mentionMentions: [
                CodexTurnMention(name: "gmail", path: "plugin://gmail@openai-curated"),
            ],
            includeStructuredMentionItems: true
        )

        let mentionItem = payload
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "mention" })

        XCTAssertEqual(mentionItem?["name"]?.stringValue, "gmail")
        XCTAssertEqual(mentionItem?["path"]?.stringValue, "plugin://gmail@openai-curated")
    }

    func testDecodePluginMetadataFiltersMarketplaceFieldsIntoMentionPath() {
        let service = makeService()
        let plugins = service.decodePluginMetadata(
            from: .object([
                "marketplaces": .array([
                    .object([
                        "name": .string("openai-curated"),
                        "path": .null,
                        "plugins": .array([
                            .object([
                                "id": .string("gmail@openai-curated"),
                                "name": .string("gmail"),
                                "installed": .bool(true),
                                "enabled": .bool(true),
                                "installPolicy": .string("AVAILABLE"),
                                "interface": .object([
                                    "displayName": .string("Gmail"),
                                    "shortDescription": .string("Search mail"),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )

        XCTAssertEqual(plugins?.first?.name, "gmail")
        XCTAssertEqual(plugins?.first?.mentionPath, "plugin://gmail@openai-curated")
        XCTAssertEqual(plugins?.first?.displayTitle, "Gmail")
    }

    func testDecodePluginMetadataMarksDefaultInstalledPluginsMentionable() {
        let service = makeService()
        let plugins = service.decodePluginMetadata(
            from: .object([
                "marketplaces": .array([
                    .object([
                        "name": .string("openai-curated"),
                        "path": .string("/plugins"),
                        "plugins": .array([
                            .object([
                                "id": .string("browser@openai-curated"),
                                "name": .string("browser"),
                                "installed": .bool(false),
                                "enabled": .bool(false),
                                "installPolicy": .string("INSTALLED_BY_DEFAULT"),
                                "interface": .null,
                            ]),
                        ]),
                    ]),
                ]),
            ])
        )

        XCTAssertEqual(plugins?.first?.installPolicy, "INSTALLED_BY_DEFAULT")
        XCTAssertEqual(plugins?.first?.isAvailableForMention, true)
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
