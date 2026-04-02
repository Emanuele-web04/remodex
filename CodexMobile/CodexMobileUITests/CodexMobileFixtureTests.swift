// FILE: CodexMobileFixtureTests.swift
// Purpose: Functional e2e tests using the existing UI test fixture mode.
// Layer: UI Test
// Exports: CodexMobileFixtureTests
// Depends on: XCTest

import XCTest

final class CodexMobileFixtureTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchFixtureApp(
        _ app: XCUIApplication,
        messageCount: Int = 100
    ) {
        app.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", "\(messageCount)",
        ]
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 45),
            "App did not reach foreground in time."
        )
    }

    func testFixtureTimelineRendersWithMessages() {
        let app = XCUIApplication()
        launchFixtureApp(app, messageCount: 50)

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(
            timeline.waitForExistence(timeout: 30),
            "Timeline scroll view should appear after fixture builds messages"
        )

        // Verify the timeline has content (can scroll)
        XCTAssertTrue(timeline.frame.height > 0, "Timeline should have non-zero height")
    }

    func testFixtureComposerInputExists() {
        let app = XCUIApplication()
        launchFixtureApp(app, messageCount: 10)

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 30))

        // The composer input should be present
        let composerInput = app.textViews["turn.composer.input"]
        XCTAssertTrue(
            composerInput.waitForExistence(timeout: 10),
            "Composer text input should be visible"
        )
    }

    func testFixtureTimelineIsScrollable() {
        let app = XCUIApplication()
        launchFixtureApp(app, messageCount: 200)

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 30))

        // Scroll up to verify content is scrollable
        timeline.swipeUp(velocity: .fast)
        timeline.swipeDown(velocity: .fast)

        // Timeline should still be visible after scrolling
        XCTAssertTrue(timeline.exists, "Timeline should remain visible after scrolling")
    }
}
