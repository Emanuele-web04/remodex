// FILE: SubscriptionServiceTests.swift
// Purpose: Verifies local development Pro override behavior stays limited to debug-only local toggles.
// Layer: Unit Test
// Exports: SubscriptionServiceTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class SubscriptionServiceTests: XCTestCase {
    func testDebugForceProAccessDefaultMarksServiceReadyImmediately() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: "codex.subscription.debugForceProAccess")
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let service = SubscriptionService(defaults: defaults)

        XCTAssertEqual(service.bootstrapState, .ready)
        XCTAssertTrue(service.hasProAccess)
        XCTAssertFalse(service.isLoading)
        XCTAssertNil(service.lastErrorMessage)
    }

    func testCachedFreeStateIsOverriddenByDebugForceProAccess() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let cachedState = [
            "hasProAccess": false,
            "latestPurchaseDate": NSNull(),
            "willRenew": false,
            "managementURLString": NSNull(),
        ] as [String: Any]
        let encoded = try! JSONSerialization.data(withJSONObject: cachedState)
        defaults.set(encoded, forKey: "codex.subscription.cachedState")
        defaults.set(true, forKey: "codex.subscription.debugForceProAccess")
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let service = SubscriptionService(defaults: defaults)

        XCTAssertEqual(service.bootstrapState, .ready)
        XCTAssertTrue(service.hasProAccess)
    }

    func testCachedFreeStateStaysFreeWithoutExplicitDebugOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let cachedState = [
            "hasProAccess": false,
            "latestPurchaseDate": NSNull(),
            "willRenew": false,
            "managementURLString": NSNull(),
        ] as [String: Any]
        let encoded = try! JSONSerialization.data(withJSONObject: cachedState)
        defaults.set(encoded, forKey: "codex.subscription.cachedState")
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let service = SubscriptionService(defaults: defaults)

        XCTAssertEqual(service.bootstrapState, .idle)
        XCTAssertFalse(service.hasProAccess)
    }

    func testPersonalDebugBundleIdentifierEnablesLocalDevelopmentOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let service = SubscriptionService(
            defaults: defaults,
            bundleIdentifier: "com.zackkirsh.remodex"
        )

        XCTAssertTrue(service.isUsingLocalDevelopmentProOverride)
        XCTAssertEqual(service.bootstrapState, .ready)
        XCTAssertTrue(service.hasProAccess)
    }
}
