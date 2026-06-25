// FILE: OpenCodeRuntimeDetails.swift
// Purpose: Nested OpenCode status from runtime/catalog and bridge-status.json opencode blocks. (providers for BRAND-5 catalog logo resolver)
// Layer: Model
// Exports: OpenCodeRuntimeDetails, OpenCodeConnectedProviderSummary, OpenCodeModelListMeta, OpenCodeCatalogProvider
// Depends on: Foundation

import Foundation

struct OpenCodeConnectedProviderSummary: Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let modelCount: Int?
}

struct OpenCodeProviderInventoryEntry: Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let connectedOnServe: Bool
    let authenticated: Bool
    let modelCount: Int?
    let logoProviderId: String?
}

// Catalog provider entry from runtime/catalog.opencode.providers (RP-BRAND-1 + BRAND-5 stub).
// id is the provider key (e.g. "anthropic", "opencode-go"); logoAssetId present only for
// cleared branded (maps to asset in Assets.xcassets); others use SF fallback.
struct OpenCodeCatalogProvider: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let logoAssetId: String?
}

struct OpenCodeModelListMeta: Codable, Hashable, Sendable {
    let reasonCode: String?
    let connectedProviderIds: [String]?
    let fetchedAt: String?
    let stale: Bool?
    let modelCountBeforeCap: Int?
    let modelCountAfterCap: Int?
}

struct OpenCodeRuntimeDetails: Codable, Hashable, Sendable {
    let enabled: Bool?
    let serveUrl: String?
    let version: String?
    let minVersion: String?
    let versionBelowMinimum: Bool?
    let sessionCount: Int?
    let lastError: String?
    let command: String?
    let handoffEnvEnabled: Bool?
    let authConfigured: Bool?
    let connectedProviders: [OpenCodeConnectedProviderSummary]?
    let providerInventory: [OpenCodeProviderInventoryEntry]?
    let providerDiscoveryReasonCode: String?
    let authDiscoveryReasonCode: String? = nil
    let providerInventoryPartial: Bool? = nil
    let catalogRevision: String? = nil
    let providers: [OpenCodeCatalogProvider]? = nil
}