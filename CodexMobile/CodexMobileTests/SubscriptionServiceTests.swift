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

        let service = SubscriptionService(
            defaults: defaults,
            bundleIdentifier: "com.example.remodex",
            pricingRuntimeSupported: true
        )

        XCTAssertEqual(service.bootstrapState, .ready)
        XCTAssertTrue(service.hasProAccess)
        XCTAssertTrue(service.shouldBypassSubscriptionGates)
        XCTAssertEqual(
            service.subscriptionBypassStatusMessage,
            "Pro access is enabled for this build because a local or debug override is active, so subscription paywalls are bypassed."
        )
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

        let service = SubscriptionService(
            defaults: defaults,
            bundleIdentifier: "com.example.remodex",
            pricingRuntimeSupported: true
        )

        XCTAssertEqual(service.bootstrapState, .ready)
        XCTAssertTrue(service.hasProAccess)
        XCTAssertTrue(service.shouldBypassSubscriptionGates)
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

        let service = SubscriptionService(
            defaults: defaults,
            bundleIdentifier: "com.example.remodex",
            pricingRuntimeSupported: true
        )

        XCTAssertEqual(service.bootstrapState, .idle)
        XCTAssertFalse(service.hasProAccess)
        XCTAssertFalse(service.shouldBypassSubscriptionGates)
        XCTAssertNil(service.subscriptionBypassStatusMessage)
    }

    func testPricingUnavailableBuildBypassesSubscriptionGates() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let service = SubscriptionService(
            defaults: defaults,
            bundleIdentifier: "com.example.remodex",
            pricingRuntimeSupported: false
        )

        XCTAssertTrue(service.isUsingLocalDevelopmentProOverride)
        XCTAssertTrue(service.shouldBypassSubscriptionGates)
        XCTAssertEqual(
            service.subscriptionBypassStatusMessage,
            "Pro access is enabled for this build because subscription pricing is unavailable here, so subscription paywalls are bypassed."
        )
        XCTAssertEqual(service.bootstrapState, .ready)
        XCTAssertTrue(service.hasProAccess)
    }

    func testPersonalDebugBundleIdentifierEnablesLocalDevelopmentOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let service = SubscriptionService(
            defaults: defaults,
            bundleIdentifier: "com.zackkirsh.remodex",
            pricingRuntimeSupported: true
        )

        XCTAssertTrue(service.isUsingLocalDevelopmentProOverride)
        XCTAssertTrue(service.shouldBypassSubscriptionGates)
        XCTAssertEqual(service.bootstrapState, .ready)
        XCTAssertTrue(service.hasProAccess)
        XCTAssertEqual(
            service.subscriptionBypassStatusMessage,
            "Pro access is enabled for this build because a local or debug override is active, so subscription paywalls are bypassed."
        )
    }

    func testSubscriptionGatesAreNotBypassedWithoutLocalOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let service = SubscriptionService(
            defaults: defaults,
            bundleIdentifier: "com.example.remodex",
            pricingRuntimeSupported: true
        )

        XCTAssertFalse(service.isUsingLocalDevelopmentProOverride)
        XCTAssertFalse(service.shouldBypassSubscriptionGates)
        XCTAssertNil(service.subscriptionBypassStatusMessage)
    }
}
