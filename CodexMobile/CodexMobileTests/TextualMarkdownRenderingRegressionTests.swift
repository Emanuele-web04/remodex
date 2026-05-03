// FILE: TextualMarkdownRenderingRegressionTests.swift
// Purpose: Guards against Textual markdown rendering crashes from very fragmented rich text.
// Layer: Unit Test
// Exports: TextualMarkdownRenderingRegressionTests
// Depends on: XCTest, SwiftUI, UIKit, CodexMobile

import SwiftUI
import UIKit
import XCTest
@testable import CodexMobile

@MainActor
final class TextualMarkdownRenderingRegressionTests: XCTestCase {
    func testLargeFragmentedMarkdownRendersWithoutStackOverflowingTextBuilder() {
        let markdown = Self.largeFragmentedMarkdown(fragmentCount: 2_500)
        let host = UIHostingController(
            rootView: MarkdownTextView(
                text: markdown,
                profile: .assistantProse,
                constrainsToAvailableWidth: true
            )
        )

        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 1_000)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let measuredSize = host.sizeThatFits(
            in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)
        )
        XCTAssertGreaterThan(measuredSize.height, 0)
    }

    // Builds many adjacent inline markdown runs, matching the Textual path that used to
    // recursively interpolate SwiftUI Text values until large chats could crash.
    private static func largeFragmentedMarkdown(fragmentCount: Int) -> String {
        (0..<fragmentCount).map { index in
            "**bold-\(index)** [`file-\(index).swift`](file:///tmp/file-\(index).swift)"
        }
        .joined(separator: " ")
    }
}
