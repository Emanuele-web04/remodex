// FILE: AboutRemodexView.swift
// Purpose: Full-screen guide explaining how Remodex works, styled as a blog page.
// Layer: View
// Exports: AboutRemodexView

import SwiftUI

struct AboutRemodexView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header
                    howItWorksSection
                    Divider().opacity(0.3)
                    architectureDiagram
                    Divider().opacity(0.3)
                    relaySection
                    Divider().opacity(0.3)
                    appServerSection
                    Divider().opacity(0.3)
                    pairingSection
                    Divider().opacity(0.3)
                    encryptionSection
                    Divider().opacity(0.3)
                    gitSection
                    Divider().opacity(0.3)
                    resilienceSection
                    Divider().opacity(0.3)
                    desktopSection
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .font(AppFont.body())
            .navigationTitle("About Remodex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remodex")
                .font(AppFont.headline(weight: .bold))
                .foregroundStyle(.primary)

            Text("Control **Codex** from your iPhone.")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)

            calloutCard(
                icon: "desktopcomputer",
                color: .cyan,
                text: "The Codex runtime stays on your Mac. Your phone is a secure remote control connected through a relay."
            )
        }
        .padding(.top, 8)
    }

    // MARK: - How It Works

    @ViewBuilder private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("How It Works")

            bodyText("Your Mac runs a lightweight **bridge** that connects to a **relay server** over WebSocket.")

            bulletList([
                "You send a prompt from your phone",
                "It travels through the relay to the bridge on your Mac",
                "The bridge forwards it to `codex app-server` via JSON-RPC",
                "Responses stream back the same path in real time",
            ])

            calloutCard(
                icon: "lock.shield.fill",
                color: .green,
                text: "All execution happens locally on your Mac — code generation, tool use, file edits. Nothing runs on the relay."
            )
        }
    }

    // MARK: - Architecture

    @ViewBuilder private var architectureDiagram: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Architecture")

            VStack(spacing: 0) {
                diagramStep(from: "Remodex iOS", to: "Bridge (Mac)", via: "WebSocket")
                diagramStep(from: "Bridge (Mac)", to: "codex app-server", via: "JSON-RPC")
                diagramStep(from: "codex app-server", to: "~/.codex/sessions", via: "JSONL rollout", isLast: true)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.tertiarySystemFill).opacity(0.5))
            )
        }
    }

    @ViewBuilder
    private func diagramStep(from: String, to: String, via: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(from)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                VStack(spacing: 2) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text(via)
                        .font(AppFont.caption2())
                        .foregroundStyle(.secondary)
                        .italic()
                }
                .frame(width: 90)

                Text(to)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 1, height: 14)
            }
        }
    }

    // MARK: - Relay

    @ViewBuilder private var relaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("The Relay")

            bodyText("A lightweight WebSocket server that routes messages between your iPhone and your Mac.")

            iconRow("arrow.triangle.2.circlepath", "Handles session discovery so your phone finds the Mac's live session")
            iconRow("eye.slash.fill", "Never sees decrypted message contents after the handshake")
            iconRow("tag.fill", "Only observes connection metadata — session IDs, device IDs, timing")

            Spacer().frame(height: 4)

            bodyText("You can **self-host** the relay on your own VPS, or use the default hosted endpoint from the npm package.")
        }
    }

    // MARK: - App-Server

    @ViewBuilder private var appServerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Codex App-Server")

            bodyText("The bridge spawns a **`codex app-server`** process — the same JSON-RPC interface behind the Codex desktop app and IDE extensions.")

            bulletList([
                "Phone conversations are first-class Codex sessions",
                "Produces JSONL rollout files under `~/.codex/sessions/`",
                "Threads started from your phone show up in Codex.app",
            ])

            calloutCard(
                icon: "point.topleft.down.to.point.bottomright.curvepath",
                color: .orange,
                text: "Already have a running Codex instance? Point the bridge at it with REMODEX_CODEX_ENDPOINT instead of spawning a new one."
            )
        }
    }

    // MARK: - Pairing

    @ViewBuilder private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Pairing & Security")

            bodyText("On first connect, the bridge prints a **QR code** containing:")

            bulletList([
                "The relay URL",
                "The session ID",
                "The bridge's identity public key",
            ])

            bodyText("Scan it once from this app. After the handshake:")

            iconRow("checkmark.shield.fill", "iPhone saves the Mac as a **trusted device** in Keychain")
            iconRow("desktopcomputer", "Bridge persists your phone's identity locally")
            iconRow("arrow.clockwise", "Later launches auto-reconnect — no QR needed")

            Spacer().frame(height: 4)

            bodyText("The QR remains available as a recovery path if trust changes or the session can't be resolved.")
        }
    }

    // MARK: - Encryption

    @ViewBuilder private var encryptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("End-to-End Encryption")

            bodyText("After pairing, every message is wrapped in encrypted envelopes:")

            specRow("Cipher", "AES-256-GCM")
            specRow("Key derivation", "HKDF-SHA256, per-direction keys")
            specRow("Key exchange", "X25519 ephemeral")
            specRow("Identity", "Ed25519 signatures")
            specRow("Replay protection", "Monotonic counters")
            specRow("At-rest (iPhone)", "Keychain-backed AES key")
        }
    }

    // MARK: - Git

    @ViewBuilder private var gitSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Git & Workspace")

            bodyText("The bridge handles **git commands** from your phone locally on the Mac:")

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    gitCommand("status")
                    gitCommand("commit")
                    gitCommand("push")
                    gitCommand("pull")
                    gitCommand("branches")
                    gitCommand("checkout")
                }
                VStack(alignment: .leading, spacing: 6) {
                    gitCommand("createBranch")
                    gitCommand("log")
                    gitCommand("stash")
                    gitCommand("stashPop")
                    gitCommand("resetToRemote")
                    gitCommand("remoteUrl")
                }
            }

            Spacer().frame(height: 4)

            bodyText("Also supports **workspace revert** — preview and apply reverse patches when the assistant makes changes you want to undo.")
        }
    }

    // MARK: - Resilience

    @ViewBuilder private var resilienceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Connection Resilience")

            iconRow("arrow.clockwise", "Auto-reconnect with exponential backoff (1s → 5s)")
            iconRow("envelope.badge.fill", "Bounded outbound buffer re-sends missed encrypted messages")
            iconRow("cpu.fill", "Codex process stays alive across transient drops")
            iconRow("power", "SIGINT / SIGTERM trigger clean shutdown")
        }
    }

    // MARK: - Desktop

    @ViewBuilder private var desktopSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Desktop App Integration")

            bodyText("Threads from your phone are persisted as JSONL rollout files, so they appear in **Codex.app** on your Mac.")

            calloutCard(
                icon: "macbook.and.iphone",
                color: .blue,
                text: "The desktop app doesn't live-reload external writes. Use the Hand off to Mac button in the app to continue the current thread on your Mac."
            )
        }
    }

    // MARK: - Reusable components

    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.headline(weight: .semibold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func bodyText(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(AppFont.subheadline())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Text("->")
                        .font(AppFont.caption(weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18)

                    Text(LocalizedStringKey(item))
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func iconRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            Text(LocalizedStringKey(text))
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func specRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func gitCommand(_ name: String) -> some View {
        Text("git/\(name)")
            .font(AppFont.mono(.caption2))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func calloutCard(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.1))
                )

            Text(LocalizedStringKey(text))
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.4))
        )
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        VStack(spacing: 10) {
            OpenSourceBadge(style: .dark)

            Text("ISC License")
                .font(AppFont.caption())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

#Preview {
    AboutRemodexView()
}
