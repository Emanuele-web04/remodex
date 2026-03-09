// FILE: TurnComposerAttachmentIntakePlanTests.swift
// Purpose: Verifies attachment slot limiting and overflow behavior for the refactored composer.
// Layer: Unit Test
// Exports: TurnComposerAttachmentIntakePlanTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

final class TurnComposerAttachmentIntakePlanTests: XCTestCase {
    func testIntakePlanAcceptsAllWhenWithinRemainingSlots() {
        let plan = TurnComposerAttachmentIntakePlan.make(requestedCount: 2, remainingSlots: 4)

        XCTAssertEqual(plan.acceptedCount, 2)
        XCTAssertEqual(plan.droppedCount, 0)
        XCTAssertFalse(plan.hasOverflow)
    }

    func testIntakePlanDropsOverflowingItems() {
        let plan = TurnComposerAttachmentIntakePlan.make(requestedCount: 6, remainingSlots: 4)

        XCTAssertEqual(plan.acceptedCount, 4)
        XCTAssertEqual(plan.droppedCount, 2)
        XCTAssertTrue(plan.hasOverflow)
    }

    func testIntakePlanDropsAllWhenNoRemainingSlots() {
        let plan = TurnComposerAttachmentIntakePlan.make(requestedCount: 3, remainingSlots: 0)

        XCTAssertEqual(plan.acceptedCount, 0)
        XCTAssertEqual(plan.droppedCount, 3)
        XCTAssertTrue(plan.hasOverflow)
    }

}
