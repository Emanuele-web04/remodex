// FILE: CodexMobileUITests.swift
// Purpose: Measures timeline scrolling and streaming append performance on deterministic fixtures.
// Layer: UI Test
// Exports: CodexMobileUITests
// Depends on: XCTest

import XCTest

final class CodexMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchFixtureApp(
        _ app: XCUIApplication,
        extraArguments: [String] = []
    ) {
        app.launchArguments += [
            "-CodexUITestsFixture",
        ] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 45),
            "App did not reach foreground in time for UI testing (accessibility readiness)."
        )
    }

    func testTurnTimelineScrollingPerformance() {
        let app = XCUIApplication()
        launchFixtureApp(app, extraArguments: [
            "-CodexUITestsMessageCount", "1200",
        ])

        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 20))

        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
        }
    }

    func testTurnStreamingAppendPerformance() {
        let app = XCUIApplication()
        launchFixtureApp(app, extraArguments: [
            "-CodexUITestsMessageCount", "500",
            "-CodexUITestsAutoStream",
        ])

        XCTAssertTrue(app.scrollViews["turn.timeline.scrollview"].waitForExistence(timeout: 20))

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            // Wait window where fixture appends streaming chunks into the active timeline.
            RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        }
    }
}
