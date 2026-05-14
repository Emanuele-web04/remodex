// FILE: RootNavigationSwipePolicyTests.swift
// Purpose: Guards full-width sidebar/back swipe decisions.
// Layer: Unit Test
// Exports: RootNavigationSwipePolicyTests
// Depends on: XCTest, CoreGraphics, CodexMobile

import CoreGraphics
import XCTest
@testable import CodexMobile

final class RootNavigationSwipePolicyTests: XCTestCase {
    func testRightSwipeAtRootOpensSidebarFromMiddleOfScreen() {
        let action = RootNavigationSwipePolicy.action(
            startLocationX: 240,
            translationWidth: 64,
            translationHeight: 8,
            isSidebarOpen: false,
            navigationDepth: 0
        )

        XCTAssertEqual(action, .openSidebar)
    }

    func testRightSwipeOnPushedRouteNavigatesBackFromMiddleOfScreen() {
        let action = RootNavigationSwipePolicy.action(
            startLocationX: 220,
            translationWidth: 54,
            translationHeight: 10,
            isSidebarOpen: false,
            navigationDepth: 1
        )

        XCTAssertEqual(action, .navigateBack)
    }

    func testRightSwipeNearEdgeOnPushedRouteDefersToSystemBackGesture() {
        let action = RootNavigationSwipePolicy.action(
            startLocationX: 18,
            translationWidth: 54,
            translationHeight: 6,
            isSidebarOpen: false,
            navigationDepth: 1
        )

        XCTAssertNil(action)
    }

    func testMostlyVerticalGestureDoesNotTriggerSidebarOrBackAction() {
        let action = RootNavigationSwipePolicy.action(
            startLocationX: 180,
            translationWidth: 28,
            translationHeight: 48,
            isSidebarOpen: false,
            navigationDepth: 0
        )

        XCTAssertNil(action)
    }

    func testLeftSwipeClosesSidebarWhenDrawerIsOpen() {
        let action = RootNavigationSwipePolicy.action(
            startLocationX: 250,
            translationWidth: -52,
            translationHeight: 6,
            isSidebarOpen: true,
            navigationDepth: 0
        )

        XCTAssertEqual(action, .closeSidebar)
    }
}
