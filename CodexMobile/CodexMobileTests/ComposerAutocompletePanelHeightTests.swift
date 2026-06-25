// FILE: ComposerAutocompletePanelHeightTests.swift
// Purpose: Unit tests for PR6 inline autocomplete list height caps.
// Layer: Test
// Exports: ComposerAutocompletePanelHeightTests
// Depends on: XCTest, ComposerAutocompletePanelHeight

import XCTest
@testable import CodexMobile

final class ComposerAutocompletePanelHeightTests: XCTestCase {
    func testCappedListHeightLimitsToThreeRows() {
        let height = ComposerAutocompletePanelHeight.cappedListHeight(
            rowHeight: 60,
            headerHeights: 24,
            rowCount: 20,
            screenHeight: 1200
        )
        XCTAssertEqual(height, 60 * 3 + 24, accuracy: 0.01)
    }

    func testCappedListHeightRespectsScreenFraction() {
        let height = ComposerAutocompletePanelHeight.cappedListHeight(
            rowHeight: 60,
            headerHeights: 0,
            rowCount: 3,
            screenHeight: 400
        )
        XCTAssertEqual(height, 400 * 0.28, accuracy: 0.01)
    }

    func testCappedListHeightEmptyRows() {
        let height = ComposerAutocompletePanelHeight.cappedListHeight(
            rowHeight: 60,
            headerHeights: 12,
            rowCount: 0,
            screenHeight: 1000
        )
        XCTAssertEqual(height, 12, accuracy: 0.01)
    }
}