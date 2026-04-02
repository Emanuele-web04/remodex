// FILE: BridgeMenuBarViews.swift
// Purpose: Renders the menu bar "control center" UI, including the global-CLI blocker, status cards, relay controls, and action buttons.
// Layer: Companion app view
// Exports: BridgeMenuBarContentView, BridgeMenuBarLabel
// Depends on: SwiftUI, AppKit, CoreImage, BridgeMenuBarStore, BridgeControlModels

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct BridgeMenuBarContentView: View {
    @ObservedObject var store: BridgeMenuBarStore
    @State private var relayDraft = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                headerSection
                if store.isCLIAvailable {
                    statusSection
                    relaySection
                    commandSection
                    qrSection
                    logsSection
                    feedbackSection
                } else {
                    cliSetupCard
                }
            }
            .padding(14)
        }
        .frame(width: 360, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            relayDraft = store.relayOverride
        }
        .onChange(of: store.relayOverride) { _, newValue in
            relayDraft = newValue
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Remodex Ctrl")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                statusIndicator
            }

            HStack(spacing: 8) {
                metricChip("Installed", store.snapshot?.currentVersion ?? store.cliAvailability.versionLabel ?? "—")
                metricChip("Latest", store.updateState.latestVersion ?? (store.isCLIAvailable ? "…" : "—"))
                metricChip("Relay", store.snapshot?.relayKindLabel ?? (store.isCLIAvailable ? "…" : "—"))
            }
        }
        .padding(12)
        .background(cardFill, in: cardShape)
        .overlay(cardBorder)
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusTint)
                .frame(width: 7, height: 7)
            Text(currentStatusTitle.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Status")

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    statusTile("Daemon", store.snapshot?.launchdLoaded == true ? "Loaded" : "Stopped")
                    statusTile("Connection", store.snapshot?.bridgeStatus?.connectionStatus ?? "unknown")
                }
                GridRow {
                    statusTile("PID", pidLabel)
                    statusTile("Updated", store.snapshot?.statusFootnote ?? "n/a")
                }
            }

            if let relay = store.snapshot?.effectiveRelayURL, !relay.isEmpty {
                LabelValueRow(label: "Relay URL", value: relay)
            } else {
                LabelValueRow(label: "Relay URL", value: "Not configured yet")
            }
        }
        .padding(12)
        .background(cardFill, in: cardShape)
        .overlay(cardBorder)
    }

    // MARK: - Relay

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Relay Override")

            Text("Optional. Leave empty to use whatever `remodex` resolves from your shell or saved daemon config.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)

            TextField("ws://localhost:9000/relay", text: $relayDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 6) {
                CompactActionButton("Save", style: .primary) {
                    store.saveRelayOverride(relayDraft)
                }
                CompactActionButton("Defaults", style: .secondary) {
                    relayDraft = ""
                    store.clearRelayOverride()
                }
            }
        }
        .padding(12)
        .background(cardFill, in: cardShape)
        .overlay(cardBorder)
    }

    // MARK: - Commands

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Commands")

            HStack(spacing: 6) {
                CompactActionButton("Start", style: .primary) {
                    store.startBridge()
                }
                CompactActionButton("Stop", style: .destructive) {
                    store.stopBridge()
                }
                CompactActionButton("Resume", style: .secondary) {
                    store.resumeLastThread()
                }
            }

            HStack(spacing: 6) {
                CompactActionButton("Refresh", style: .secondary) {
                    Task { await store.refresh(showSpinner: true) }
                }
                CompactActionButton("Reset Pair", style: .destructive) {
                    store.resetPairing()
                }
                if store.updateState.isUpdateAvailable {
                    CompactActionButton("Update", style: .primary) {
                        store.updateBridgePackage()
                    }
                }
            }
        }
        .padding(12)
        .background(cardFill, in: cardShape)
        .overlay(cardBorder)
    }

    // MARK: - QR

    @ViewBuilder
    private var qrSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Pairing")
                Spacer()
                if let payload = store.snapshot?.pairingSession?.pairingPayload {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(payload.isExpired ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        Text(payload.isExpired ? "Expired" : "Ready")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let payload = store.snapshot?.pairingSession?.pairingPayload {
                HStack(alignment: .top, spacing: 12) {
                    PairingQRCodeView(payload: payload)
                        .frame(width: 100, height: 100)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        LabelValueRow(label: "Session", value: payload.sessionId)
                        LabelValueRow(label: "Device", value: payload.macDeviceId)
                        LabelValueRow(label: "Expires", value: payload.expiryDate.formatted(date: .omitted, time: .shortened))
                    }
                }
            } else {
                Text("Start the bridge to generate a pairing QR.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(cardFill, in: cardShape)
        .overlay(cardBorder)
    }

    // MARK: - Logs

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Logs")

            if let snapshot = store.snapshot {
                LabelValueRow(label: "Stdout", value: snapshot.stdoutLogPath)
                LabelValueRow(label: "Stderr", value: snapshot.stderrLogPath)
            }

            HStack(spacing: 6) {
                CompactActionButton("Folder", style: .secondary) {
                    store.openLogsFolder()
                }
                CompactActionButton("Stdout", style: .secondary) {
                    store.openStdoutLog()
                }
                CompactActionButton("Stderr", style: .secondary) {
                    store.openStderrLog()
                }
            }
        }
        .padding(12)
        .background(cardFill, in: cardShape)
        .overlay(cardBorder)
    }

    // MARK: - Feedback

    @ViewBuilder
    private var feedbackSection: some View {
        let hasUpdateError = !(store.updateState.errorMessage?.isEmpty ?? true)
        let hasBridgeError = !(store.snapshot?.lastErrorMessage ?? "").isEmpty
        if !store.errorMessage.isEmpty || !store.transientMessage.isEmpty || hasUpdateError || hasBridgeError {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Feedback")

                if !store.transientMessage.isEmpty {
                    feedbackLine(store.transientMessage, tint: .green)
                }
                if !store.errorMessage.isEmpty {
                    feedbackLine(store.errorMessage, tint: .red)
                }
                if let bridgeError = store.snapshot?.lastErrorMessage, !bridgeError.isEmpty {
                    feedbackLine(bridgeError, tint: .pink)
                }
                if let updateError = store.updateState.errorMessage, !updateError.isEmpty {
                    feedbackLine(updateError, tint: .orange)
                }
            }
            .padding(12)
            .background(cardFill, in: cardShape)
            .overlay(cardBorder)
        }
    }

    // MARK: - CLI Setup (when not installed)

    private var cliSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Global CLI")
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(cliStatusTint)
                        .frame(width: 6, height: 6)
                    Text(store.cliAvailability.statusLabel.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Text(store.cliAvailability.setupTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text(store.cliAvailability.setupMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabelValueRow(label: "Install", value: BridgeCLIAvailability.installCommand)

            Text("After installing, reopen the menu or press retry.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            CompactActionButton("Retry", style: .primary) {
                store.retryCLISetup()
            }
        }
        .padding(12)
        .background(cardFill, in: cardShape)
        .overlay(cardBorder)
    }

    // MARK: - Shared primitives

    private let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    private var cardFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.45 : 0.6)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
    }

    private var statusTint: Color {
        if !store.isCLIAvailable { return cliStatusTint }
        if store.updateState.isUpdateAvailable { return .orange }

        let status = store.snapshot?.bridgeStatus?.connectionStatus?.lowercased()
        if status == "connected" { return .green }
        if status == "connecting" || status == "starting" { return .yellow }
        if status == "error" { return .red }

        return store.snapshot?.launchdLoaded == true ? .blue : .gray
    }

    private var cliStatusTint: Color {
        switch store.cliAvailability {
        case .checking: return .yellow
        case .available: return .green
        case .missing: return .orange
        case .broken: return .red
        }
    }

    private var currentStatusTitle: String {
        if let snapshot = store.snapshot { return snapshot.statusHeadline }
        switch store.cliAvailability {
        case .available: return "Loading"
        case .checking: return "Checking"
        case .missing: return "CLI Missing"
        case .broken: return "CLI Error"
        }
    }

    private var pidLabel: String {
        if let pid = store.snapshot?.launchdPid { return String(pid) }
        if let pid = store.snapshot?.bridgeStatus?.pid { return String(pid) }
        return "—"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private func statusTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func metricChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func feedbackLine(_ message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Menu bar icon

struct BridgeMenuBarLabel: View {
    let snapshot: BridgeSnapshot?
    let updateState: BridgePackageUpdateState
    let isBusy: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "terminal")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isBusy ? Color.primary.opacity(0.7) : Color.primary)
            if updateState.isUpdateAvailable {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .offset(x: 4, y: -2)
            } else if snapshot?.bridgeStatus?.connectionStatus?.lowercased() == "connected" {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .offset(x: 4, y: -2)
            }
        }
    }
}

// MARK: - Shared components

private struct LabelValueRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

private struct CompactActionButton: View {
    let title: String
    let style: Style
    let action: () -> Void

    enum Style { case primary, secondary, destructive }

    init(_ title: String, style: Style = .secondary, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var backgroundColor: Color {
        switch style {
        case .primary: return .primary
        case .secondary: return Color(nsColor: .textBackgroundColor).opacity(0.5)
        case .destructive: return Color(nsColor: .textBackgroundColor).opacity(0.5)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: return Color(nsColor: .windowBackgroundColor)
        case .secondary: return .primary
        case .destructive: return .red
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary: return .clear
        case .secondary: return .primary.opacity(0.06)
        case .destructive: return .red.opacity(0.15)
        }
    }
}

private struct PairingQRCodeView: View {
    let payload: BridgePairingPayload
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        Group {
            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Text("QR unavailable")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var qrImage: NSImage? {
        let payloadObject = PairingQRPayloadEnvelope(
            v: payload.v,
            relay: payload.relay,
            sessionId: payload.sessionId,
            macDeviceId: payload.macDeviceId,
            macIdentityPublicKey: payload.macIdentityPublicKey,
            expiresAt: payload.expiresAt
        )
        guard let data = try? JSONEncoder().encode(payloadObject) else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

private struct PairingQRPayloadEnvelope: Encodable {
    let v: Int
    let relay: String
    let sessionId: String
    let macDeviceId: String
    let macIdentityPublicKey: String
    let expiresAt: Int64
}
