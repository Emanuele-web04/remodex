import XCTest
@testable import CodexMobile

final class AssistantMemoryCitationParserTests: XCTestCase {
    private let citation = """
    <oai-mem-citation>
    <citation_entries>
    MEMORY.md:190-212|note=[local bridge context]
    </citation_entries>
    <rollout_ids>
    01a08d7b-8e89-7870-b2ee-4e563c96dd2d
    </rollout_ids>
    </oai-mem-citation>
    """

    func testRemovesMemoryEnvelopeFromCompletedAnswer() {
        let answer = "The overview is in **README.md**."
        XCTAssertEqual(visible(answer + "\n\n" + citation), answer)
        XCTAssertEqual(visible(citation), "")
    }

    func testEveryStreamingPrefixKeepsMetadataHidden() {
        for length in 1...citation.count {
            let raw = "Answer.\n\n" + citation.prefix(length)
            XCTAssertEqual(
                AssistantMemoryCitationParser.visibleText(in: raw, isStreaming: true),
                "Answer.",
                "Leaked metadata at prefix \(length)"
            )
        }
    }

    func testInterruptedEnvelopeStaysHiddenAfterCompletion() {
        XCTAssertEqual(visible("Answer.\n<oai-mem-citation>\n<citation_entries>\nMEMORY.md:1-2"), "Answer.")
    }

    func testPreservesCodeExamplesAndOrdinaryTagMentions() {
        let examples = [
            "```xml\n\(citation)\n```",
            "~~~~xml\n~~~\n\(citation)\n~~~~",
            "`\(citation)`",
            "``example\n\(citation)\nexample``",
            citation.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"),
            "The `<oai-mem-citation>` tag contains metadata.",
            "Example: <oai-mem-citation>literal</oai-mem-citation>",
            "<other-tag>visible</other-tag>"
        ]
        for example in examples {
            XCTAssertEqual(visible(example), example)
            XCTAssertEqual(visible(example + "\n\n" + citation), example)
        }
    }

    func testKeepsProseAroundMultipleEnvelopes() {
        XCTAssertEqual(visible("First.\n\(citation)\nSecond.\n\(citation)\nLast."), "First.\nSecond.\nLast.")
        XCTAssertEqual(visible("<oai-mem-citation>metadata</oai-mem-citation>After."), "After.")
    }

    func testStreamingCandidateReturnsWhenItIsOrdinaryText() {
        XCTAssertEqual(AssistantMemoryCitationParser.visibleText(in: "Answer.\n<oai-", isStreaming: true), "Answer.")
        XCTAssertEqual(AssistantMemoryCitationParser.visibleText(in: "Answer.\n<other>", isStreaming: true), "Answer.\n<other>")
        XCTAssertEqual(visible("Answer.\n<oai-"), "Answer.\n<oai-")
    }

    func testLongUnicodeAnswerIsPreservedBeforeTimelineClipping() {
        let answer = String(repeating: "Risposta 👋🏽 café\n", count: 4_000) + "Finale."
        XCTAssertEqual(visible(answer + "\n\n" + citation), answer)
        XCTAssertEqual(visible("  Plain text.\n\n"), "  Plain text.\n\n")
    }

    private func visible(_ text: String) -> String {
        AssistantMemoryCitationParser.visibleText(in: text, isStreaming: false)
    }
}
