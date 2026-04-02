// FILE: CodexMobileFullAppTests.swift
// Purpose: Functional e2e tests for full app navigation without backend.
// Layer: UI Test
// Exports: CodexMobileFullAppTests
// Depends on: XCTest

import XCTest

final class CodexMobileFullAppTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch the full production app with onboarding skipped and Pro forced.
    /// Starts in offline home state — no backend needed.
    private func launchFullApp(_ app: XCUIApplication) {
        app.launchArguments += [
            "-CodexSkipOnboarding",
            "-CodexDebugForceProAccess",
        ]
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 45),
            "App did not reach foreground in time."
        )
    }

    // MARK: - Home Empty State

    func testHomeEmptyStateShowsOfflinePhase() {
        let app = XCUIApplication()
        launchFullApp(app)

        let statusLabel = app.staticTexts["home.connection_status_label"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 10), "Connection status label should appear")

        let primaryButton = app.buttons["home.primary_action_button"]
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 10), "Primary action button should appear")
    }

    func testHomePrimaryActionShowsScanQRWhenDisconnected() {
        let app = XCUIApplication()
        launchFullApp(app)

        let primaryButton = app.buttons["home.primary_action_button"]
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 10))
        // Offline with no reconnect candidate → button should say "Scan QR Code"
        XCTAssertEqual(primaryButton.label, "Scan QR Code")
    }

    // MARK: - Sidebar Navigation

    func testSidebarOpensViaHamburger() {
        let app = XCUIApplication()
        launchFullApp(app)

        let hamburgerButton = app.buttons["content.hamburger_button"]
        XCTAssertTrue(hamburgerButton.waitForExistence(timeout: 10), "Hamburger button should appear")
        hamburgerButton.tap()

        // Sidebar should appear with search, settings, and new chat
        let searchField = app.textFields["sidebar.search_field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Sidebar search field should appear after tapping hamburger")

        let newChatButton = app.buttons["sidebar.new_chat_button"]
        XCTAssertTrue(newChatButton.waitForExistence(timeout: 5), "New chat button should appear in sidebar")

        let settingsButton = app.buttons["sidebar.settings_button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should appear in sidebar")
    }

    // MARK: - Settings Navigation

    func testSettingsNavigationShowsRuntimeDefaults() {
        let app = XCUIApplication()
        launchFullApp(app)

        // Open sidebar and navigate to settings
        let hamburgerButton = app.buttons["content.hamburger_button"]
        XCTAssertTrue(hamburgerButton.waitForExistence(timeout: 10))
        hamburgerButton.tap()

        let settingsButton = app.buttons["sidebar.settings_button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        // Settings should load — look for the runtime defaults section pickers
        let profilePicker = app.menuButtons["settings.profile_picker"]
        XCTAssertTrue(profilePicker.waitForExistence(timeout: 10), "Profile picker should appear in settings")

        let modelPicker = app.menuButtons["settings.model_picker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 5), "Model picker should appear")

        let accessPicker = app.menuButtons["settings.access_picker"]
        XCTAssertTrue(accessPicker.waitForExistence(timeout: 5), "Access picker should appear")
    }

    func testSettingsConnectionSectionShowsNoPairedMac() {
        let app = XCUIApplication()
        launchFullApp(app)

        // Navigate to settings
        let hamburgerButton = app.buttons["content.hamburger_button"]
        XCTAssertTrue(hamburgerButton.waitForExistence(timeout: 10))
        hamburgerButton.tap()

        let settingsButton = app.buttons["sidebar.settings_button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        // Should show "No paired Mac" text and transport picker
        let noPairedMacLabel = app.staticTexts.containing(NSPredicate(format: "label LIKE %@", "No paired Mac"))
        XCTAssertTrue(noPairedMacLabel.element.waitForExistence(timeout: 10), "Should show 'No paired Mac' text")

        let transportPicker = app.menuButtons["settings.transport_picker"]
        XCTAssertTrue(transportPicker.waitForExistence(timeout: 5), "Transport picker should appear")
    }

    func testSettingsArchivedChatsLinkPresent() {
        let app = XCUIApplication()
        launchFullApp(app)

        // Navigate to settings
        let hamburgerButton = app.buttons["content.hamburger_button"]
        XCTAssertTrue(hamburgerButton.waitForExistence(timeout: 10))
        hamburgerButton.tap()

        let settingsButton = app.buttons["sidebar.settings_button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        let archivedChatsLink = app.buttons["settings.archived_chats_link"]
        XCTAssertTrue(archivedChatsLink.waitForExistence(timeout: 10), "Archived chats link should appear in settings")
    }

    func testSettingsAllPickersArePresent() {
        let app = XCUIApplication()
        launchFullApp(app)

        // Navigate to settings
        let hamburgerButton = app.buttons["content.hamburger_button"]
        XCTAssertTrue(hamburgerButton.waitForExistence(timeout: 10))
        hamburgerButton.tap()

        let settingsButton = app.buttons["sidebar.settings_button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        // Verify all 6 pickers exist
        let pickers = [
            "settings.profile_picker",
            "settings.model_picker",
            "settings.reasoning_picker",
            "settings.speed_picker",
            "settings.access_picker",
            "settings.transport_picker",
        ]

        for pickerID in pickers {
            let picker = app.menuButtons[pickerID]
            XCTAssertTrue(
                picker.waitForExistence(timeout: 5),
                "Picker '\(pickerID)' should appear in settings"
            )
        }
    }
}
