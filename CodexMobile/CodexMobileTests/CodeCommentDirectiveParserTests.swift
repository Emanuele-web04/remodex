// FILE: CodeCommentDirectiveParserTests.swift
// Purpose: Verifies assistant review directives parse into finding cards instead of leaking raw ::code-comment text.
// Layer: Unit Test
// Exports: CodeCommentDirectiveParserTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class CodeCommentDirectiveParserTests: XCTestCase {
    func testParseExtractsSingleFindingAndCleansFallbackText() {
        let source = """
        Review complete.

        ::code-comment{title="[P1] Active thread can stay stuck" body="The sync state returns early and hides the final output." file="CodexService+Sync.swift" start=432 end=441 priority=1 confidence=0.92}
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertEqual(parsed.findings.count, 1)
        XCTAssertEqual(parsed.findings.first?.title, "Active thread can stay stuck")
        XCTAssertEqual(parsed.findings.first?.priority, 1)
        XCTAssertEqual(parsed.findings.first?.startLine, 432)
        XCTAssertEqual(parsed.findings.first?.endLine, 441)
        XCTAssertEqual(parsed.findings.first?.confidence ?? 0, 0.92, accuracy: 0.0001)
        XCTAssertEqual(parsed.fallbackText, "Review complete.")
    }

    func testParseExtractsMultipleFindingsInOrder() {
        let source = """
        ::code-comment{title="[P1] First" body="First body." file="A.swift" start=10 end=12 priority=1 confidence=0.91}
        ::code-comment{title="[P2] Second" body="Second body." file="B.swift" start=20 end=24 priority=2 confidence=0.88}
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertEqual(parsed.findings.map(\.title), ["First", "Second"])
        XCTAssertEqual(parsed.findings.map(\.file), ["A.swift", "B.swift"])
        XCTAssertTrue(parsed.fallbackText.isEmpty)
    }

    func testParseLeavesProjectSkillMarkdownUntouchedInFallback() {
        let source = """
        Before shipping, review [Skill](Skills/Skill.md).

        ::code-comment{title="[P3] Missing test" body="A project Skill.md file should remain plain markdown." file="project.pbxproj" start=107 end=124 priority=3 confidence=0.77}
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertEqual(parsed.findings.count, 1)
        XCTAssertEqual(parsed.fallbackText, "Before shipping, review [Skill](Skills/Skill.md).")
    }
}
