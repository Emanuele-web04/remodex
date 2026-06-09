// FILE: OpenCodeModelMenuGroupingTests.swift
// Purpose: Verifies OpenCode model menu grouping by upstream provider id.
// Layer: Unit test
// Exports: OpenCodeModelMenuGroupingTests
// Depends on: XCTest, CodexModelOption, TurnComposerMetaMapper

import XCTest
@testable import CodexMobile

final class OpenCodeModelMenuGroupingTests: XCTestCase {
    func testGroupsOpenCodeModelsByUpstreamProvider() {
        let models = [
            makeOpenCodeModel(
                id: "anthropic/claude-sonnet-4",
                upstreamId: "anthropic",
                upstreamName: "Anthropic"
            ),
            makeOpenCodeModel(
                id: "openai/gpt-5.5",
                upstreamId: "openai",
                upstreamName: "OpenAI"
            ),
        ]

        let groups = TurnComposerMetaMapper.openCodeModelsGroupedByUpstream(models)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].upstreamId, "anthropic")
        XCTAssertEqual(groups[0].title, "Anthropic")
        XCTAssertEqual(groups[1].upstreamId, "openai")
        XCTAssertEqual(groups[1].title, "OpenAI")
    }

    func testEmptyConnectedDiscoveryReasonSkipsUpstreamGroups() {
        let models: [CodexModelOption] = []
        XCTAssertTrue(TurnComposerMetaMapper.openCodeModelsGroupedByUpstream(models).isEmpty)
    }

    func testReturnsEmptyWhenNoUpstreamMetadata() {
        let models = [
            CodexModelOption(
                id: "opencode/gpt-5.5",
                model: "opencode/gpt-5.5",
                modelProvider: "opencode",
                displayName: "GPT-5.5",
                description: "",
                isDefault: true,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: nil
            ),
        ]

        XCTAssertTrue(TurnComposerMetaMapper.openCodeModelsGroupedByUpstream(models).isEmpty)
    }

    private func makeOpenCodeModel(
        id: String,
        upstreamId: String,
        upstreamName: String
    ) -> CodexModelOption {
        CodexModelOption(
            id: id,
            model: id,
            modelProvider: "opencode",
            displayName: id,
            description: "",
            isDefault: false,
            supportedReasoningEfforts: [],
            defaultReasoningEffort: nil,
            upstreamProviderId: upstreamId,
            upstreamProviderDisplayName: upstreamName
        )
    }
}
