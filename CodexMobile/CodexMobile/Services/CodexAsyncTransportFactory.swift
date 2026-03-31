// FILE: CodexAsyncTransportFactory.swift
// Purpose: Chooses the active off-LAN async transport without coupling callers to a specific backend.
// Layer: Service support
// Exports: CodexAsyncTransportFactory
// Depends on: Foundation

import Foundation

enum CodexAsyncTransportFactory {
    static func make(
        convexSiteURL: URL? = AppEnvironment.convexSiteURL,
        cloudKitFactory: () -> CodexAsyncRequestTransporting? = { CodexCloudAsyncTransport.makeIfSupported() },
        convexFactory: (URL) -> CodexAsyncRequestTransporting = { CodexConvexAsyncTransport(siteURL: $0) }
    ) -> CodexAsyncRequestTransporting? {
        if CodexConvexAsyncTransport.isConfigured(siteURL: convexSiteURL),
           let convexSiteURL {
            return convexFactory(convexSiteURL)
        }

        return cloudKitFactory()
    }
}
