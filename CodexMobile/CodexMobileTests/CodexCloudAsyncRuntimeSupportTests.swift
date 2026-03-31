import Foundation
import XCTest
@testable import CodexMobile

private final class StubAsyncRequestTransport: CodexAsyncRequestTransporting {
    func availability(for service: CodexService) async -> CodexCloudAsyncAvailability {
        .available
    }

    func performRequest(
        method: String,
        params: JSONValue?,
        requestID: JSONValue,
        service: CodexService
    ) async throws -> RPCMessage {
        RPCMessage(id: requestID, result: .object([:]), includeJSONRPC: false)
    }

    func performNotification(
        method: String,
        params: JSONValue?,
        service: CodexService
    ) async throws {}
}

final class CodexCloudAsyncRuntimeSupportTests: XCTestCase {
    func testAppEnvironmentConvexSiteURLIsHardcodedDeploymentURL() {
        XCTAssertEqual(
            AppEnvironment.convexSiteURL.absoluteString,
            "https://determined-ladybug-18.convex.site"
        )
    }

    func testIsSupportedReturnsTrueForICloudContainerEntitlement() {
        let supported = CodexCloudAsyncRuntimeSupport.isSupported(
            provisioningProfileText: """
            <key>Entitlements</key>
            <dict>
                <key>com.apple.developer.icloud-container-identifiers</key>
                <array>
                    <string>iCloud.com.example.Remodex</string>
                </array>
            </dict>
            """
        )

        XCTAssertTrue(supported)
    }

    func testIsSupportedReturnsTrueForUbiquityKVSIdentifier() {
        let supported = CodexCloudAsyncRuntimeSupport.isSupported(
            provisioningProfileText: """
            <key>Entitlements</key>
            <dict>
                <key>com.apple.developer.ubiquity-kvstore-identifier</key>
                <string>TEAMID.com.example.Remodex</string>
            </dict>
            """
        )

        XCTAssertTrue(supported)
    }

    func testIsSupportedReturnsFalseWithoutICloudEntitlements() {
        let supported = CodexCloudAsyncRuntimeSupport.isSupported(
            provisioningProfileText: """
            <key>Entitlements</key>
            <dict>
                <key>get-task-allow</key>
                <true/>
            </dict>
            """
        )

        XCTAssertFalse(supported)
    }

    func testIsSupportedReturnsFalseWhenProvisioningProfileIsUnavailable() {
        let supported = CodexCloudAsyncRuntimeSupport.isSupported(
            bundleIdentifier: "com.example.Remodex",
            provisioningProfileText: nil
        )

        XCTAssertFalse(supported)
    }

    func testIsSupportedReturnsFalseByDefaultInSimulatorOrTestHost() {
        let supported = CodexCloudAsyncRuntimeSupport.isSupported(
            bundleIdentifier: "com.example.Remodex"
        )

        XCTAssertFalse(supported)
    }

    func testMakeIfSupportedReturnsNilInSimulator() {
        #if targetEnvironment(simulator)
        XCTAssertNil(CodexCloudAsyncTransport.makeIfSupported())
        #endif
    }

    func testIgnoresICloudMentionsOutsideEntitlementsSection() {
        let supported = CodexCloudAsyncRuntimeSupport.isSupported(
            bundleIdentifier: "com.example.Remodex",
            provisioningProfileText: """
            <key>DER-Encoded-Profile</key>
            <data>com.apple.developer.icloud-services</data>
            <key>Entitlements</key>
            <dict>
                <key>get-task-allow</key>
                <true/>
            </dict>
            """
        )

        XCTAssertFalse(supported)
    }

    func testDisabledPersonalBundleIdentifierForcesCloudAsyncOff() {
        let supported = CodexCloudAsyncRuntimeSupport.isSupported(
            bundleIdentifier: "com.zackkirsh.remodex",
            provisioningProfileText: """
            <key>Entitlements</key>
            <dict>
                <key>com.apple.developer.icloud-services</key>
                <array>
                    <string>CloudKit</string>
                </array>
            </dict>
            """
        )

        XCTAssertFalse(supported)
    }

    func testOffLANSupportReturnsTrueWhenConvexSiteURLIsConfigured() {
        let supported = CodexOffLANAsyncRuntimeSupport.isSupported(
            bundleIdentifier: "com.zackkirsh.remodex",
            provisioningProfileText: nil,
            convexSiteURL: URL(string: "https://example.convex.site")
        )

        XCTAssertTrue(supported)
    }

    func testOffLANSupportReturnsTrueForHardcodedConvexDeploymentURL() {
        let supported = CodexOffLANAsyncRuntimeSupport.isSupported(
            bundleIdentifier: "com.zackkirsh.remodex",
            provisioningProfileText: nil,
            convexSiteURL: AppEnvironment.convexSiteURL
        )

        XCTAssertTrue(supported)
    }

    func testAsyncTransportFactoryPrefersConvexTransportWhenConfigured() {
        let spy = AsyncTransportFactorySpy()

        let transport = CodexAsyncTransportFactory.make(
            convexSiteURL: URL(string: "https://example.convex.site"),
            cloudKitFactory: spy.cloudKitFactory,
            convexFactory: spy.convexFactory
        )

        XCTAssertTrue(transport === spy.fallback)
        XCTAssertEqual(spy.convexFactoryURLs, [URL(string: "https://example.convex.site")!])
        XCTAssertFalse(spy.cloudKitFactoryCalled)
    }

    func testAsyncTransportFactoryFallsBackToCloudKitTransportWhenConvexIsMissing() {
        let fallback = StubAsyncRequestTransport()
        var convexFactoryCalled = false
        var cloudKitFactoryCalled = false
        let transport = CodexAsyncTransportFactory.make(
            convexSiteURL: nil,
            cloudKitFactory: {
                cloudKitFactoryCalled = true
                return fallback
            },
            convexFactory: { _ in
                convexFactoryCalled = true
                return fallback
            }
        )

        XCTAssertTrue(transport === fallback)
        XCTAssertFalse(convexFactoryCalled)
        XCTAssertTrue(cloudKitFactoryCalled)
    }

    func testConvexTransportConfigurationRequiresHTTPURLWithHost() {
        XCTAssertTrue(CodexConvexAsyncTransport.isConfigured(siteURL: URL(string: "https://example.convex.site")))
        XCTAssertTrue(CodexConvexAsyncTransport.isConfigured(siteURL: URL(string: "https://example.convex.site/")))
        XCTAssertFalse(CodexConvexAsyncTransport.isConfigured(siteURL: URL(string: "ftp://example.com")))
        XCTAssertFalse(CodexConvexAsyncTransport.isConfigured(siteURL: URL(string: "https://example.convex.site/path")))
        XCTAssertFalse(CodexConvexAsyncTransport.isConfigured(siteURL: URL(string: "https://example.convex.site?foo=bar")))
        XCTAssertFalse(CodexConvexAsyncTransport.isConfigured(siteURL: URL(string: "https://example.convex.site#fragment")))
        XCTAssertFalse(CodexConvexAsyncTransport.isConfigured(siteURL: nil))
    }
}

private final class AsyncTransportFactorySpy {
    let fallback = StubAsyncRequestTransport()
    private(set) var convexFactoryURLs: [URL] = []
    private(set) var cloudKitFactoryCalled = false

    func cloudKitFactory() -> CodexAsyncRequestTransporting? {
        cloudKitFactoryCalled = true
        return fallback
    }

    func convexFactory(_ url: URL) -> CodexAsyncRequestTransporting {
        convexFactoryURLs.append(url)
        return fallback
    }
}
