// FILE: OpenCodeProvidersSettingsView.swift
// Purpose: Lists OpenCode providers from bridge providerInventory with connection badges.
// Layer: Settings UI
// Exports: OpenCodeProvidersSettingsView
// Depends on: SwiftUI, CodexService, RuntimeProviderLogo

import SwiftUI

struct OpenCodeProvidersSettingsView: View {
    @Environment(CodexService.self) private var codex

    var body: some View {
        List {
            if let footnote = inventoryFootnote {
                Text(footnote)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if entries.isEmpty {
                Text("No OpenCode providers reported by the Mac bridge.")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.id) { entry in
                    HStack(spacing: 12) {
                        RuntimeProviderLogoView(provider: entry.logoProviderId ?? entry.id, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                                .font(AppFont.body())
                            if let modelCount = entry.modelCount {
                                Text("\(modelCount) models on Mac")
                                    .font(AppFont.caption())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        badge(for: entry)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("OpenCode providers")
        .task {
            guard codex.isConnected, codex.isInitialized else { return }
            await codex.refreshRuntimeMetadataSequential()
        }
    }

    private var entries: [OpenCodeProviderInventoryEntry] {
        guard let opencode = codex.availableRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == "opencode"
        }) else {
            return []
        }
        return opencode.opencode?.providerInventory ?? []
    }

    private var inventoryFootnote: String? {
        guard let opencode = codex.availableRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == "opencode"
        })?.opencode else {
            return nil
        }
        if opencode.providerInventoryPartial == true || opencode.authDiscoveryReasonCode != "ok" {
            return "Some authenticated providers could not be listed. Check OpenCode auth on your Mac."
        }
        let connected = entries.filter(\.connectedOnServe).count
        let authOnly = entries.filter { $0.authenticated && !$0.connectedOnServe }.count
        if connected > 0 || authOnly > 0 {
            return "\(connected) connected on serve · \(authOnly) authenticated (not on serve)"
        }
        return nil
    }

    @ViewBuilder
    private func badge(for entry: OpenCodeProviderInventoryEntry) -> some View {
        if entry.connectedOnServe {
            Text("Connected on Mac")
                .font(AppFont.caption())
                .foregroundStyle(.green)
        } else if entry.authenticated {
            Text("Not connected on serve")
                .font(AppFont.caption())
                .foregroundStyle(.orange)
        }
    }
}

struct SettingsOpenCodeProvidersLink: View {
    @Environment(CodexService.self) private var codex

    var body: some View {
        NavigationLink {
            OpenCodeProvidersSettingsView()
        } label: {
            HStack {
                Text("OpenCode providers on Mac")
                Spacer()
                if inventoryCount > 0 {
                    Text("\(inventoryCount)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!showsLink)
    }

    private var showsLink: Bool {
        codex.availableRuntimes.contains {
            CodexModelOption.normalizedProvider($0.id) == "opencode"
        }
    }

    private var inventoryCount: Int {
        codex.availableRuntimes.first(where: {
            CodexModelOption.normalizedProvider($0.id) == "opencode"
        })?.opencode?.providerInventory?.count ?? 0
    }
}