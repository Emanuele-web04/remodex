// FILE: ContentNavigationSwipePolicyTests.swift
// Purpose: Guards route-aware full-width swipe behavior for Back and sidebar open/close.
// Layer: Unit Test
// Exports: ContentNavigationSwipePolicyTests
// Depends on: XCTest, CoreGraphics, CodexMobile

import CoreGraphics
import XCTest
@testable import CodexMobile

final class ContentNavigationSwipePolicyTests: XCTestCase {
    func testRightSwipeAtRootOpensSidebarEvenWhenStartedFromMiddleOfScreen() {
        let action = RootNavigationSwipePolicy.action(
            startLocationX: 240,
            translationWidth: 64,
            translationHeight: 8,
            isSidebarOpen: false,
            navigationDepth: 0
        )

        XCTAssertEqual(action, .openSidebar)
    }

    func testRightSwipeOnPushedRouteNavigatesBackInsteadOfOpeningSidebar() {
        let action = RootNavigationSwipePolicy.action(
            startLocationX: 220,
            translationWidth: 54,
            translationHeight: 10,
            isSidebarOpen: false,
            navigationDepth: 1
        )

        XCTAssertEqual(action, .navigateBack)
    }

    func testRightSwipeNearScreenEdgeOnPushedRouteDefersToSystemBackGesture() {
        let action = RootNavigationSwipePolicy.action(
            startLocationX: 18,
            translationWidth: 54,
            translationHeight: 6,
            isSidebarOpen: false,
            navigationDepth: 1
        )

        XCTAssertNil(action)
    }

    func testMostlyVerticalGestureDoesNotTriggerNavigationAction() {
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
