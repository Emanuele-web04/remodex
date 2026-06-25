import XCTest
@testable import CodexMobile

final class OpenCodeProviderInventoryTests: XCTestCase {
    func testDecodesProviderInventoryEntryWithLogoProviderId() throws {
        let json = """
        {
          "id": "opencode",
          "displayName": "OpenCode Zen",
          "connectedOnServe": true,
          "authenticated": false,
          "modelCount": 3,
          "logoProviderId": "opencode-zen"
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let entry = try JSONDecoder().decode(OpenCodeProviderInventoryEntry.self, from: data)
        XCTAssertEqual(entry.id, "opencode")
        XCTAssertEqual(entry.logoProviderId, "opencode-zen")
        XCTAssertTrue(entry.connectedOnServe)
    }

    func testDecodesProviderInventoryEntryWithoutLogoProviderIdKey() throws {
        let json = """
        {
          "id": "opencode",
          "displayName": "OpenCode",
          "connectedOnServe": true,
          "authenticated": false,
          "modelCount": 1
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let entry = try JSONDecoder().decode(OpenCodeProviderInventoryEntry.self, from: data)
        XCTAssertEqual(entry.id, "opencode")
        XCTAssertNil(entry.logoProviderId)
    }

    func testDecodesProviderInventoryEntry() throws {
        let json = """
        {
          "id": "deepseek",
          "displayName": "DeepSeek",
          "connectedOnServe": false,
          "authenticated": true,
          "modelCount": null
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let entry = try JSONDecoder().decode(OpenCodeProviderInventoryEntry.self, from: data)
        XCTAssertEqual(entry.id, "deepseek")
        XCTAssertFalse(entry.connectedOnServe)
        XCTAssertTrue(entry.authenticated)
    }

    // Catalog resolver stub tests (RP-BRAND-5): unit coverage for fallback + known ids.
    // Exercises CatalogLogoResolver + assetName via catalog.providers shape from BRAND-1.
    func testDecodesOpenCodeRuntimeDetailsWithCatalogRevision() throws {
        let json = """
        {
          "enabled": true,
          "catalogRevision": "fp:1a2b3c4d",
          "providerInventory": [
            {
              "id": "opencode",
              "displayName": "OpenCode",
              "connectedOnServe": true,
              "authenticated": true,
              "modelCount": 2
            }
          ]
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let details = try JSONDecoder().decode(OpenCodeRuntimeDetails.self, from: data)
        XCTAssertEqual(details.catalogRevision, "fp:1a2b3c4d")
        XCTAssertEqual(details.providerInventory?.count, 1)
    }

    func testDecodesOpenCodeRuntimeDetailsWithCatalogProvidersForLogos() throws {
        let json = """
        {
          "enabled": true,
          "providers": [
            { "id": "anthropic", "name": "Anthropic", "logoAssetId": "provider-anthropic-logo" },
            { "id": "openai", "name": "OpenAI", "logoAssetId": "provider-openai-logo" },
            { "id": "opencode-go", "name": "OpenCode Go", "logoAssetId": "provider-opencode-go-logo" }
          ]
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let details = try JSONDecoder().decode(OpenCodeRuntimeDetails.self, from: data)
        XCTAssertEqual(details.providers?.count, 3)
        XCTAssertEqual(details.providers?.first?.id, "anthropic")
        XCTAssertEqual(details.providers?.first?.logoAssetId, "provider-anthropic-logo")
        XCTAssertEqual(details.providers?[1].logoAssetId, "provider-openai-logo")
        XCTAssertEqual(details.providers?.last?.logoAssetId, "provider-opencode-go-logo")
    }

    func testProviderLogoCatalogResolverKnownIdsAndFallback() {
        let catalog: [OpenCodeCatalogProvider] = [
            OpenCodeCatalogProvider(id: "opencode-go", name: "Go", logoAssetId: "provider-opencode-go-logo"),
            OpenCodeCatalogProvider(id: "anthropic", name: "Anthropic", logoAssetId: "provider-anthropic-logo"),
            OpenCodeCatalogProvider(id: "openai", name: "OpenAI", logoAssetId: "provider-openai-logo"),
        ]

        // catalog provides logoAssetId -> use it (drives asset render for cleared)
        XCTAssertEqual(
            ProviderLogo.assetName(for: "opencode-go", catalogProviders: catalog),
            "provider-opencode-go-logo"
        )
        XCTAssertEqual(
            RuntimeProviderLogo.assetName(for: "opencode-go", catalogProviders: catalog),
            "provider-opencode-go-logo"
        )

        // catalog provides logoAssetId for cleared providers
        XCTAssertEqual(
            ProviderLogo.assetName(for: "anthropic", catalogProviders: catalog),
            "provider-anthropic-logo"
        )
        XCTAssertEqual(
            ProviderLogo.assetName(for: "openai", catalogProviders: catalog),
            "provider-openai-logo"
        )

        // committed manifest resolves without catalog (TestFlight branding path)
        XCTAssertEqual(ProviderLogo.assetName(for: "codex", catalogProviders: []), "provider-codex-logo")
        XCTAssertEqual(ProviderLogo.assetName(for: "mistral", catalogProviders: []), "provider-mistral-logo")
        XCTAssertEqual(ProviderLogo.assetName(for: "amazon-bedrock", catalogProviders: []), "provider-bedrock-logo")
        XCTAssertEqual(ProviderLogo.assetName(for: "github-copilot", catalogProviders: []), "provider-github-logo")
        XCTAssertEqual(ProviderLogo.assetName(for: "opencode", catalogProviders: []), "provider-opencode-logo")

        // unknown provider -> nil (emergency SF fallback path; see provider-branding.md)
        XCTAssertNil(ProviderLogo.assetName(for: "some-long-tail", catalogProviders: catalog))

        // Emergency SF symbol names (documented in provider-branding.md only)
        XCTAssertEqual(ProviderLogo.emergencySFSymbolName(for: "openai"), "cloud")
        XCTAssertEqual(ProviderLogo.sfSymbolName(for: "anthropic"), "cpu")
        XCTAssertEqual(ProviderLogo.emergencySFSymbolName(for: "google"), "globe")
        XCTAssertEqual(ProviderLogo.emergencySFSymbolName(for: "groq"), "network")
        XCTAssertEqual(ProviderLogo.emergencySFSymbolName(for: "unknown-foo"), "globe")
    }
}