// FILE: ComposerCapabilityCopyTests.swift
// Purpose: Locks composer grey-out copy to capability-neutral strings from runtime/catalog.
// Layer: Unit Test
// Exports: ComposerCapabilityCopyTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class ComposerCapabilityCopyTests: XCTestCase {
    func testImageAttachmentsReasonIsCapabilityNeutral() {
        let reason = ComposerCapabilityCopy.capabilityReason(for: .imageAttachments)

        XCTAssertEqual(reason, "Image attachments not supported by this runtime")
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("OpenCode"))
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("placeholder"))
    }

    func testDesktopHandoffReasonMatchesBridgeErrorCopy() {
        XCTAssertEqual(
            ComposerCapabilityCopy.capabilityReason(for: .desktopHandoff),
            "Desktop handoff is not enabled on this Mac bridge"
        )
    }

    func testOpenCodeStatusSummaryReflectsHandoffEnvState() {
        XCTAssertTrue(
            ComposerCapabilityCopy.openCodeStatusSummary(
                version: "1.2.3",
                minVersion: "1.0.0",
                handoffEnvEnabled: true
            ).contains("Handoff env on")
        )
        XCTAssertTrue(
            ComposerCapabilityCopy.openCodeStatusSummary(
                version: nil,
                minVersion: nil,
                handoffEnvEnabled: false
            ).contains("Handoff env off")
        )
    }
}
