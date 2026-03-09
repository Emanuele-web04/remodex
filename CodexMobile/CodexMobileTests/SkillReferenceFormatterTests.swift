// FILE: SkillReferenceFormatterTests.swift
// Purpose: Verifies renderer-only skill normalization recognizes dedicated skill roots without hijacking project files.
// Layer: Unit Test
// Exports: SkillReferenceFormatterTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class SkillReferenceFormatterTests: XCTestCase {
    func testReplacesKnownSkillMarkdownLinkWithMentionToken() {
        let source = "[Check Code](/Users/me/.codex/skills/check-code/SKILL.md) changed"

        let transformed = SkillReferenceFormatter.replacingSkillReferences(
            in: source,
            style: .mentionToken
        )

        XCTAssertEqual(transformed, "$check-code changed")
    }

    func testReplacesKnownAgentSkillPathWithDisplayName() {
        let source = "Use /Users/me/project/.agents/skills/review/SKILL.md before shipping"

        let transformed = SkillReferenceFormatter.replacingSkillReferences(
            in: source,
            style: .displayName
        )

        XCTAssertEqual(transformed, "Use Review before shipping")
    }

    func testDoesNotTreatProjectSkillMarkdownLinkAsSkill() {
        let source = "[Skill](Skills/Skill.md) is app documentation"

        let transformed = SkillReferenceFormatter.replacingSkillReferences(
            in: source,
            style: .mentionToken
        )

        XCTAssertEqual(transformed, source)
    }

    func testDoesNotTreatProjectSkillsFolderFileAsSkill() {
        let source = "Open /Users/me/app/Skills/Skill.md in the project"

        let transformed = SkillReferenceFormatter.replacingSkillReferences(
            in: source,
            style: .displayName
        )

        XCTAssertEqual(transformed, source)
    }
}
