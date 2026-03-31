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

    func testParseExtractsFindingsFromJSONArrayPayload() {
        let source = """
        [
          {
            "title": "[P1] Active thread can stay stuck",
            "body": "The sync state returns early and hides the final output.",
            "file": "CodexService+Sync.swift",
            "startLine": 432,
            "endLine": 441,
            "confidence": 0.92
          },
          {
            "title": "[P2] Missing stale guard",
            "body": "The refresh path should short-circuit for cached data.",
            "path": "ContentView.swift",
            "line": 183,
            "severity": "medium"
          }
        ]
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertEqual(parsed.findings.map(\.title), [
            "Active thread can stay stuck",
            "Missing stale guard",
        ])
        XCTAssertEqual(parsed.findings.map(\.file), [
            "CodexService+Sync.swift",
            "ContentView.swift",
        ])
        XCTAssertEqual(parsed.findings.map(\.priority), [1, 2])
        XCTAssertEqual(parsed.findings.last?.startLine, 183)
        XCTAssertEqual(parsed.findings.last?.endLine, 183)
        XCTAssertTrue(parsed.fallbackText.isEmpty)
    }

    func testParseExtractsFindingsFromJSONObjectPayloadAndKeepsSummary() {
        let source = """
        {
          "summary": "Review complete. Two issues found.",
          "findings": [
            {
              "headline": "[P1] Regression risk",
              "description": "The reconnect flow can overwrite local state.",
              "file_path": "CodexService.swift",
              "start": "120",
              "end": "128",
              "severity": "high",
              "score": "0.88"
            }
          ]
        }
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertEqual(parsed.findings.count, 1)
        XCTAssertEqual(parsed.findings.first?.title, "Regression risk")
        XCTAssertEqual(parsed.findings.first?.file, "CodexService.swift")
        XCTAssertEqual(parsed.findings.first?.priority, 1)
        XCTAssertEqual(parsed.findings.first?.confidence ?? 0, 0.88, accuracy: 0.0001)
        XCTAssertEqual(parsed.fallbackText, "Review complete. Two issues found.")
    }

    func testParseExtractsFindingsFromEmbeddedJSONFenceAndPreservesProse() {
        let source = """
        Review complete. Two issues found.

        ```json
        {
          "findings": [
            {
              "title": "[P2] Missing guard",
              "body": "The reconnect path should reuse cached state.",
              "file": "ContentView.swift",
              "line": 183
            }
          ]
        }
        ```

        Please fix before merging.
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertEqual(parsed.findings.count, 1)
        XCTAssertEqual(parsed.findings.first?.title, "Missing guard")
        XCTAssertEqual(parsed.findings.first?.file, "ContentView.swift")
        XCTAssertEqual(parsed.findings.first?.priority, 2)
        XCTAssertEqual(
            parsed.fallbackText,
            """
            Review complete. Two issues found.

            Please fix before merging.
            """
        )
    }

    func testParseExtractsFindingsFromNestedCodeLocationJSON() {
        let source = """
        {
          "findings": [
            {
              "title": "[P1] Seed the rate limiter with a small initial token budget",
              "body": "Starting with a full bucket permits a large cold-start burst.",
              "confidence_score": 0.91,
              "priority": 1,
              "code_location": {
                "absolute_file_path": "/Users/zackjackson/ai-train/scripts/alpaca_options_utils.py",
                "line_range": {
                  "start": 246,
                  "end": 250
                }
              }
            }
          ],
          "overall_explanation": "The limiter still allows an unsafe startup burst."
        }
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertEqual(parsed.findings.count, 1)
        XCTAssertEqual(parsed.findings.first?.title, "Seed the rate limiter with a small initial token budget")
        XCTAssertEqual(parsed.findings.first?.file, "/Users/zackjackson/ai-train/scripts/alpaca_options_utils.py")
        XCTAssertEqual(parsed.findings.first?.startLine, 246)
        XCTAssertEqual(parsed.findings.first?.endLine, 250)
        XCTAssertEqual(parsed.findings.first?.priority, 1)
        XCTAssertEqual(parsed.fallbackText, "The limiter still allows an unsafe startup burst.")
    }

    func testParseSummaryOnlyJSONReviewWithoutLeakingRawPayload() {
        let source = """
        {
          "findings": [],
          "overall_correctness": "patch is correct",
          "overall_explanation": "No actionable findings."
        }
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertTrue(parsed.findings.isEmpty)
        XCTAssertEqual(parsed.fallbackText, "No actionable findings.")
    }

    func testParseMapsP0SeverityToPriorityZero() {
        let source = """
        {
          "findings": [
            {
              "title": "[P0] Blocking issue",
              "body": "This breaks every request.",
              "file": "CodexService.swift",
              "line": 42,
              "severity": "p0"
            }
          ]
        }
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertEqual(parsed.findings.count, 1)
        XCTAssertEqual(parsed.findings.first?.priority, 0)
    }

    func testParseExtractsMultipleStandaloneJSONObjectPayloadsAndPreservesPrettySummary() {
        let source = """
        {"findings":[{"title":"[P1] Seed the rate limiter with a small initial token budget","body":"Starting with a full bucket permits a large cold-start burst.","priority":1,"code_location":{"absolute_file_path":"/Users/zackjackson/ai-train/scripts/alpaca_options_utils.py","line_range":{"start":246,"end":250}}}],"overall_explanation":"The limiter still allows an unsafe startup burst."}
        The new archive path still has multiple correctness problems: the limiter can burst far above the configured rate, low RPM caps are not honored, output ordering is nondeterministic, and symbol validation does not actually prevent bad contracts from entering summaries.
        {"findings":[{"title":"[P2] Filter or normalize contracts before joining snapshots","body":"Invalid symbols still participate in the summary join.","priority":2,"code_location":{"absolute_file_path":"/Users/zackjackson/ai-train/scripts/build_alpaca_options_archive.py","line_range":{"start":515,"end":548}}}],"overall_explanation":"The symbol-validation path still allows malformed rows into the archive."}
        """

        let parsed = CodeCommentDirectiveParser.parse(from: source)

        XCTAssertEqual(parsed.findings.map(\.title), [
            "Seed the rate limiter with a small initial token budget",
            "Filter or normalize contracts before joining snapshots",
        ])
        XCTAssertEqual(parsed.findings.map(\.startLine), [246, 515])
        XCTAssertEqual(
            parsed.fallbackText,
            "The new archive path still has multiple correctness problems: the limiter can burst far above the configured rate, low RPM caps are not honored, output ordering is nondeterministic, and symbol validation does not actually prevent bad contracts from entering summaries."
        )
    }
}
