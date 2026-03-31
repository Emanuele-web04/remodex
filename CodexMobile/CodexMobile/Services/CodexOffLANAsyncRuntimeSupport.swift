// FILE: CodexOffLANAsyncRuntimeSupport.swift
// Purpose: Reports whether any off-LAN async transport is available for this build.
// Layer: Service support
// Exports: CodexOffLANAsyncRuntimeSupport
// Depends on: Foundation

import Foundation

enum CodexOffLANAsyncRuntimeSupport {
    static func isSupported(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        provisioningProfileText: String? = nil,
        convexSiteURL: URL? = AppEnvironment.convexSiteURL
    ) -> Bool {
        if CodexConvexAsyncTransport.isConfigured(siteURL: convexSiteURL) {
            return true
        }

        return CodexCloudAsyncRuntimeSupport.isSupported(
            bundleIdentifier: bundleIdentifier,
            provisioningProfileText: provisioningProfileText
        )
    }
}
