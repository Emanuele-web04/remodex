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

    func testMakeTurnInputPayloadKeepsStructuredSkillTokenInTextItemForDesktopFallback() {
        let service = makeService()
        let payload = service.makeTurnInputPayload(
            userInput: "$check-code one last time",
            attachments: [],
            imageURLKey: "url",
            skillMentions: [
                CodexTurnSkillMention(id: "check-code", name: "check-code", path: nil),
            ],
            includeStructuredSkillItems: true
        )

        let textItem = payload
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "text" })

        XCTAssertEqual(textItem?["text"]?.stringValue, "$check-code one last time")
    }

    func testMakeTurnInputPayloadAppendsMissingStructuredSkillFallbackToTextItem() {
        let service = makeService()
        let payload = service.makeTurnInputPayload(
            userInput: "pls",
            attachments: [],
            imageURLKey: "url",
            skillMentions: [
                CodexTurnSkillMention(id: "check-code", name: "check-code", path: nil),
            ],
            includeStructuredSkillItems: true
        )

        let textItem = payload
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "text" })

        XCTAssertEqual(textItem?["text"]?.stringValue, "pls\n\n$check-code")
    }

    func testMakeTurnInputPayloadKeepsSlashSkillTokenInTextItem() {
        let service = makeService()
        let payload = service.makeTurnInputPayload(
            userInput: "/recap pls",
            attachments: [],
            imageURLKey: "url",
            skillMentions: [
                CodexTurnSkillMention(id: "recap", name: "recap", path: nil),
            ],
            includeStructuredSkillItems: true
        )

        let textItem = payload
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "text" })

        XCTAssertEqual(textItem?["text"]?.stringValue, "/recap pls")
    }

    func testRemoveBoundedMentionTokenDoesNotStripInsidePath() {
        XCTAssertEqual(
            CodexService.removeBoundedMentionToken("/check-code", from: "docs/check-code now"),
            "docs/check-code now"
        )
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

    func testMakeTurnInputPayloadUsesLegacyTextForSkillOnlyFallback() {
        let service = makeService()
        let payload = service.makeTurnInputPayload(
            userInput: "",
            attachments: [],
            imageURLKey: "url",
            skillMentions: [
                CodexTurnSkillMention(id: "check-code", name: "check-code", path: nil),
            ],
            includeStructuredSkillItems: false
        )

        let textItem = payload
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "text" })

        XCTAssertEqual(textItem?["text"]?.stringValue, "$check-code")
    }

    func testMakeTurnInputPayloadAppendsMissingLegacySkillToTextFallback() {
        let service = makeService()
        let payload = service.makeTurnInputPayload(
            userInput: "Review these changes",
            attachments: [],
            imageURLKey: "url",
            skillMentions: [
                CodexTurnSkillMention(id: "check-code", name: "check-code", path: nil),
            ],
            includeStructuredSkillItems: false
        )

        let textItem = payload
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "text" })

        XCTAssertEqual(textItem?["text"]?.stringValue, "Review these changes\n\n$check-code")
    }

    func testMakeTurnInputPayloadDoesNotDuplicateExistingLegacySkillInTextFallback() {
        let service = makeService()
        let payload = service.makeTurnInputPayload(
            userInput: "Run $check-code on this",
            attachments: [],
            imageURLKey: "url",
            skillMentions: [
                CodexTurnSkillMention(id: "check-code", name: "check-code", path: nil),
            ],
            includeStructuredSkillItems: false
        )

        let textItem = payload
            .compactMap(\.objectValue)
            .first(where: { $0["type"]?.stringValue == "text" })

        XCTAssertEqual(textItem?["text"]?.stringValue, "Run $check-code on this")
    }

    func testGenericInputItemErrorsDisableStructuredSkillRetry() {
        let service = makeService()
        let error = CodexServiceError.rpcError(
            RPCError(code: -32602, message: "Invalid input item type")
        )

        XCTAssertTrue(service.shouldRetryTurnStartWithoutSkillItems(error))
    }

    func testImageURLFallbackAcceptsExplicitImageURLError() {
        let service = makeService()
        let error = CodexServiceError.rpcError(
            RPCError(code: -32602, message: "missing field image_url")
        )

        XCTAssertTrue(service.shouldRetryTurnStartWithImageURLField(error))
    }

    func testImageURLFallbackAcceptsRejectedURLFieldError() {
        let service = makeService()
        let error = CodexServiceError.rpcError(
            RPCError(code: -32602, message: "unexpected field url")
        )

        XCTAssertTrue(service.shouldRetryTurnStartWithImageURLField(error))
    }

    func testStartTurnRejectsEmptyStructuredMentions() async {
        let service = makeService()
        service.isConnected = true

        do {
            try await service.startTurn(
                userInput: "",
                threadId: "thread-empty-skill",
                skillMentions: [
                    CodexTurnSkillMention(id: " ", name: nil, path: nil),
                ]
            )
            XCTFail("Expected empty structured mention to be rejected.")
        } catch let error as CodexServiceError {
            XCTAssertEqual(error.localizedDescription, "User input, images, and mentions cannot all be empty")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartTurnOptimisticMessageKeepsTextSeparateFromSkillChip() async throws {
        let service = makeService()
        service.isConnected = true
        service.resumedThreadIDs.insert("thread-skill-display")
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "turn/start")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-skill-display")]),
                includeJSONRPC: false
            )
        }

        try await service.startTurn(
            userInput: "Review these changes",
            threadId: "thread-skill-display",
            skillMentions: [
                CodexTurnSkillMention(id: "check-code", name: "check-code", path: nil),
            ]
        )

        let message = service.messagesByThread["thread-skill-display"]?.last
        XCTAssertEqual(message?.text, "Review these changes")
        XCTAssertEqual(message?.skillMentions, ["check-code"])
    }

    func testStartTurnOptimisticMessageShowsOnlySkillChipForMentionOnlySend() async throws {
        let service = makeService()
        service.isConnected = true
        service.resumedThreadIDs.insert("thread-skill-only-display")
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "turn/start")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-skill-only-display")]),
                includeJSONRPC: false
            )
        }

        try await service.startTurn(
            userInput: "/recap",
            threadId: "thread-skill-only-display",
            skillMentions: [
                CodexTurnSkillMention(id: "recap", name: "recap", path: nil),
            ]
        )

        let message = service.messagesByThread["thread-skill-only-display"]?.last
        XCTAssertEqual(message?.text, "")
        XCTAssertEqual(message?.skillMentions, ["recap"])
    }

    func testStartTurnOptimisticMessageKeepsSkillLabelInLocalTextWhenThereIsProse() async throws {
        let service = makeService()
        service.isConnected = true
        service.resumedThreadIDs.insert("thread-skill-text-display")
        service.requestTransportOverride = { method, _ in
            XCTAssertEqual(method, "turn/start")
            return RPCMessage(
                id: .string(UUID().uuidString),
                result: .object(["turnId": .string("turn-skill-text-display")]),
                includeJSONRPC: false
            )
        }

        try await service.startTurn(
            userInput: "/recap pls",
            threadId: "thread-skill-text-display",
            skillMentions: [
                CodexTurnSkillMention(id: "recap", name: "recap", path: nil),
            ]
        )

        let message = service.messagesByThread["thread-skill-text-display"]?.last
        XCTAssertEqual(message?.text, "Recap pls")
        XCTAssertEqual(message?.skillMentions, ["recap"])
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
