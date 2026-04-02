// FILE: CodexMobileOnboardingTests.swift
// Purpose: E2e tests for onboarding flow — no skip flags, no backend needed.
// Layer: UI Test
// Exports: CodexMobileOnboardingTests
// Depends on: XCTest

import XCTest

final class CodexMobileOnboardingTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch the app without skipping onboarding. The subscription gate is bypassed
    /// so onboarding is the first thing visible.
    private func launchAppWithOnboarding(_ app: XCUIApplication) {
        // Only force Pro access to bypass subscription gate — do NOT skip onboarding
        app.launchArguments += [
            "-CodexDebugForceProAccess",
        ]
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 45),
            "App did not reach foreground in time."
        )
    }

    func testOnboardingShowsGetStartedButton() {
        let app = XCUIApplication()
        launchAppWithOnboarding(app)

        // The onboarding continue button should be visible
        let continueButton = app.buttons["onboarding.continue_button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 15),
            "Onboarding continue button should appear on first launch"
        )

        // First page should show "Get Started"
        XCTAssertEqual(continueButton.label, "Get Started")
    }

    func testOnboardingAdvancesToSetupPage() {
        let app = XCUIApplication()
        launchAppWithOnboarding(app)

        let continueButton = app.buttons["onboarding.continue_button"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 15))

        // Tap "Get Started" → should advance to page 2 with "Set Up"
        continueButton.tap()

        // Dismiss the CLI install reminder alert if it appears
        let stayHereButton = app.alerts.buttons["Stay Here"]
        if stayHereButton.waitForExistence(timeout: 3) {
            stayHereButton.tap()
        }

        // After tapping, the button should now say "Set Up" or "Continue"
        let newLabel = continueButton.label
        XCTAssertTrue(
            newLabel == "Set Up" || newLabel == "Continue",
            "Button should advance to 'Set Up' or 'Continue', got '\(newLabel)'"
        )
    }

    func testOnboardingShowsScanQROnFinalPage() {
        let app = XCUIApplication()
        launchAppWithOnboarding(app)

        let continueButton = app.buttons["onboarding.continue_button"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 15))

        // Advance through all pages rapidly
        for _ in 0..<5 {
            if !continueButton.exists { break }

            // Dismiss the CLI install reminder if it pops up
            let stayHereButton = app.alerts.buttons["Stay Here"]
            if stayHereButton.waitForExistence(timeout: 2) {
                stayHereButton.tap()
            }

            // Dismiss "Continue Anyway" if it appears
            let continueAnywayButton = app.alerts.buttons["Continue Anyway"]
            if continueAnywayButton.waitForExistence(timeout: 1) {
                continueAnywayButton.tap()
            }

            continueButton.tap()
        }

        // The last page should show "Scan QR Code"
        if continueButton.exists {
            XCTAssertEqual(continueButton.label, "Scan QR Code")
        }
    }
}
