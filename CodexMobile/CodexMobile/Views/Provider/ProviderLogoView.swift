// FILE: ProviderLogoView.swift
// Purpose: Resolves runtime-provider logos from catalog logoAssetId and committed bundle assets.
// Layer: View Component
// Exports: ProviderLogo, ProviderLogoView
// Depends on: SwiftUI, UIKit, CodexModelOption, RemodexIcon, CodexService (for catalog)

import SwiftUI
import UIKit

enum ProviderLogo {
    private struct Manifest: Decodable {
        let version: Int
        let assetNamePattern: String
        let coreProviderIds: [String]
        let committedExternalProviderIds: [String]
        let aliases: [String: String]
    }

    private enum ManifestRegistry {
        static let shared: Manifest? = {
            let candidates: [URL?] = [
                Bundle.main.url(
                    forResource: "provider-logo-manifest",
                    withExtension: "json",
                    subdirectory: "ProviderLogos"
                ),
                Bundle.main.url(
                    forResource: "provider-logo-manifest",
                    withExtension: "json",
                    subdirectory: "Resources/ProviderLogos"
                ),
                Bundle.main.url(forResource: "provider-logo-manifest", withExtension: "json"),
            ]
            guard let url = candidates.compactMap({ $0 }).first else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Manifest.self, from: data)
        }()

        static func logoAssetId(for provider: String) -> String? {
            guard let manifest = shared else { return nil }
            let normalized = CodexModelOption.normalizedProvider(provider).lowercased()
            guard !normalized.isEmpty else { return nil }

            let logoProviderId = manifest.aliases[normalized] ?? normalized
            if manifest.coreProviderIds.contains(logoProviderId)
                || manifest.committedExternalProviderIds.contains(logoProviderId) {
                return manifest.assetNamePattern.replacingOccurrences(of: "{logoProviderId}", with: logoProviderId)
            }
            return nil
        }
    }

    private enum CatalogLogoResolver {
        static func logoAssetId(for provider: String, in catalogProviders: [OpenCodeCatalogProvider]) -> String? {
            let norm = CodexModelOption.normalizedProvider(provider)
            for entry in catalogProviders {
                let entryNorm = CodexModelOption.normalizedProvider(entry.id)
                if entryNorm == norm || entry.id == provider || entryNorm == provider {
                    return entry.logoAssetId
                }
            }
            return nil
        }
    }

    static func assetName(for provider: String, catalogProviders: [OpenCodeCatalogProvider] = []) -> String? {
        if let fromCatalog = CatalogLogoResolver.logoAssetId(for: provider, in: catalogProviders) {
            return fromCatalog
        }
        if let fromManifest = ManifestRegistry.logoAssetId(for: provider) {
            return fromManifest
        }
        return nil
    }

    static func assetName(for provider: String) -> String? {
        assetName(for: provider, catalogProviders: [])
    }

    static func emergencySFSymbolName(for provider: String) -> String {
        let normalized = CodexModelOption.normalizedProvider(provider).lowercased()
        switch normalized {
        case "openai": return "cloud"
        case "anthropic": return "cpu"
        case "google", "gemini": return "globe"
        case "groq": return "network"
        default: return "globe"
        }
    }

    static func sfSymbolName(for provider: String) -> String {
        emergencySFSymbolName(for: provider)
    }

    @ViewBuilder
    static func image(provider: String, size: CGFloat = 20, catalogProviders: [OpenCodeCatalogProvider] = []) -> some View {
        if let assetName = assetName(for: provider, catalogProviders: catalogProviders) {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        } else {
            RemodexIcon.image(systemName: emergencySFSymbolName(for: provider), size: size)
        }
    }

    @ViewBuilder
    static func image(provider: String, size: CGFloat = 20) -> some View {
        image(provider: provider, size: size, catalogProviders: [])
    }

    static func menuUIImage(provider: String, catalogProviders: [OpenCodeCatalogProvider] = []) -> UIImage? {
        if let assetName = assetName(for: provider, catalogProviders: catalogProviders) {
            guard let image = UIImage(named: assetName) else { return nil }
            return resizedMenuImage(image)
        }
        return RemodexIcon.menuUIImage(systemName: emergencySFSymbolName(for: provider))
    }

    static func menuUIImage(provider: String) -> UIImage? {
        menuUIImage(provider: provider, catalogProviders: [])
    }

    private static func resizedMenuImage(_ image: UIImage) -> UIImage {
        let pointSize = UIFontMetrics.default.scaledValue(for: 20)
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysTemplate)
    }
}

struct ProviderLogoView: View {
    let provider: String
    var size: CGFloat = 20

    @Environment(CodexService.self) private var codex: CodexService?

    var body: some View {
        ProviderLogo.image(
            provider: provider,
            size: size,
            catalogProviders: codex?.openCodeCatalogProviders ?? []
        )
    }
}

// Back-compat exports for existing call sites (composer, sidebar, UIKit menus).
typealias RuntimeProviderLogo = ProviderLogo
typealias RuntimeProviderLogoView = ProviderLogoView