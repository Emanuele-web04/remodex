// FILE: RemodexTextKitMarkdownRenderingRegressionTests.swift
// Purpose: Guards against RemodexTextKit markdown rendering crashes from very fragmented rich text.
// Layer: Unit Test
// Exports: RemodexTextKitMarkdownRenderingRegressionTests
// Depends on: XCTest, SwiftUI, UIKit, CodexMobile

import SwiftUI
import UIKit
import XCTest
@testable import CodexMobile

@MainActor
final class RemodexTextKitMarkdownRenderingRegressionTests: XCTestCase {
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

    func testWorkspaceFileLinkResolverAcceptsLocalFileURLsAndAbsolutePaths() throws {
        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/example.swift"))
        let absolutePathURL = try XCTUnwrap(URL(string: "/Users/test/Project/App.swift"))
        let relativePathURL = try XCTUnwrap(URL(string: "README.md"))
        let nestedRelativePathURL = try XCTUnwrap(URL(string: "Sources/App.swift"))
        let extensionlessKnownFileURL = try XCTUnwrap(URL(string: "Dockerfile"))
        let lineSuffixURL = try XCTUnwrap(URL(string: "Sources/App.swift:42:7"))
        let fragmentURL = try XCTUnwrap(URL(string: "Sources/App.swift#L42"))
        let queryURL = try XCTUnwrap(URL(string: "Sources/App.swift?plain=1"))

        XCTAssertEqual(WorkspaceFileLinkResolver.localPath(from: fileURL), "/tmp/example.swift")
        XCTAssertEqual(WorkspaceFileLinkResolver.localPath(from: absolutePathURL), "/Users/test/Project/App.swift")
        XCTAssertEqual(WorkspaceFileLinkResolver.localPath(from: relativePathURL), "README.md")
        XCTAssertEqual(WorkspaceFileLinkResolver.localPath(from: nestedRelativePathURL), "Sources/App.swift")
        XCTAssertEqual(WorkspaceFileLinkResolver.localPath(from: extensionlessKnownFileURL), "Dockerfile")
        XCTAssertEqual(WorkspaceFileLinkResolver.localPath(from: try XCTUnwrap(URL(string: "assets/logo.svg"))), "assets/logo.svg")
        XCTAssertEqual(WorkspaceFileLinkResolver.localPath(from: lineSuffixURL), "Sources/App.swift")
        XCTAssertEqual(WorkspaceFileLinkResolver.localPath(from: fragmentURL), "Sources/App.swift")
        XCTAssertEqual(WorkspaceFileLinkResolver.localPath(from: queryURL), "Sources/App.swift")
    }

    func testWorkspaceFileLinkResolverIgnoresRemoteURLs() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/App.swift"))
        let bareWebHostURL = try XCTUnwrap(URL(string: "example.com"))
        let schemeLessWebURL = try XCTUnwrap(URL(string: "example.com/path"))
        let schemeLessWebFileURL = try XCTUnwrap(URL(string: "example.com/App.swift"))

        XCTAssertNil(WorkspaceFileLinkResolver.localPath(from: remoteURL))
        XCTAssertNil(WorkspaceFileLinkResolver.localPath(from: bareWebHostURL))
        XCTAssertNil(WorkspaceFileLinkResolver.localPath(from: schemeLessWebURL))
        XCTAssertNil(WorkspaceFileLinkResolver.localPath(from: schemeLessWebFileURL))
    }

    func testWorkspaceSVGPreviewHTMLBlocksExternalReferences() {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg">
          <image href="https://example.com/leak.png" />
          <use xlink:href='file:///tmp/local.svg#icon' />
          <image href="data:image/png;base64,AAAA" />
        </svg>
        """

        let html = WorkspaceSVGWebView.htmlDocument(svgSource: svg, isDark: false)

        XCTAssertTrue(html.contains(WorkspaceSVGPreviewSecurity.contentSecurityPolicy))
        XCTAssertFalse(html.contains("https://example.com/leak.png"))
        XCTAssertFalse(html.contains("file:///tmp/local.svg#icon"))
        XCTAssertTrue(html.contains("data:image/png;base64,AAAA"))
    }

    func testGhosttyDrawableViewportAllowsCompactTerminalSizes() {
        XCTAssertFalse(GhosttyTerminalView.isDrawableViewportSize(CGSize(width: 12, height: 390)))
        XCTAssertTrue(GhosttyTerminalView.isDrawableViewportSize(CGSize(width: 390, height: 120)))
        XCTAssertTrue(GhosttyTerminalView.isDrawableViewportSize(CGSize(width: 240, height: 44)))
    }

    // Builds many adjacent inline markdown runs, matching the RemodexTextKit path that used to
    // recursively interpolate SwiftUI Text values until large chats could crash.
    private static func largeFragmentedMarkdown(fragmentCount: Int) -> String {
        (0..<fragmentCount).map { index in
            "**bold-\(index)** [`file-\(index).swift`](file:///tmp/file-\(index).swift)"
        }
        .joined(separator: " ")
    }
}
