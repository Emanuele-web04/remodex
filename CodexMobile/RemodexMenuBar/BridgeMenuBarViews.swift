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
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                if store.isCLIAvailable {
                    statusGrid
                    relayCard
                    actionDeck
                    qrCard
                    logsCard
                    feedbackCard
                } else {
                    cliSetupCard
                }
            }
            .padding(18)
        }
        .frame(width: 380, height: 620)
        .background(backgroundGradient)
        .task {
            relayDraft = store.relayOverride
        }
        .onChange(of: store.relayOverride) { _, newValue in
            relayDraft = newValue
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Remodex Ctrl")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Bridge cockpit from the menu bar")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                statusPill(
                    title: currentStatusTitle,
                    tint: statusTint
                )
            }

            HStack(spacing: 10) {
                metricChip("Installed", store.snapshot?.currentVersion ?? store.cliAvailability.versionLabel ?? "Required")
                metricChip("Latest", store.updateState.latestVersion ?? (store.isCLIAvailable ? "..." : "--"))
                metricChip("Relay", store.snapshot?.relayKindLabel ?? (store.isCLIAvailable ? "..." : "--"))
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(cardStroke)
    }

    private var cliSetupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                cardTitle("Global CLI")
                Spacer()
                statusPill(
                    title: store.cliAvailability.statusLabel,
                    tint: cliStatusTint
                )
            }

            Text(store.cliAvailability.setupTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)

            Text(store.cliAvailability.setupMessage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabelValueRow(label: "Install", value: BridgeCLIAvailability.installCommand)

            Text("After installing, reopen the menu or press retry so the companion can detect the global CLI.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ControlActionButton("Retry", style: .primary) {
                    store.retryCLISetup()
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(cardStroke)
    }

    private var statusGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Status")

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
        .padding(16)
        .background(cardBackground)
        .overlay(cardStroke)
    }

    private var relayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Relay Override")

            Text("Optional. Leave empty to use whatever `remodex` resolves from your shell or saved daemon config.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)

            TextField("ws://localhost:9000/relay", text: $relayDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 8) {
                ControlActionButton("Save Relay", style: .primary) {
                    store.saveRelayOverride(relayDraft)
                }
                ControlActionButton("Use Defaults", style: .secondary) {
                    relayDraft = ""
                    store.clearRelayOverride()
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(cardStroke)
    }

    private var actionDeck: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Command Deck")

            HStack(spacing: 8) {
                ControlActionButton("Start", style: .primary) {
                    store.startBridge()
                }
                ControlActionButton("Stop", style: .destructive) {
                    store.stopBridge()
                }
                ControlActionButton("Resume", style: .secondary) {
                    store.resumeLastThread()
                }
            }

            HStack(spacing: 8) {
                ControlActionButton("Refresh", style: .secondary) {
                    Task {
                        await store.refresh(showSpinner: true)
                    }
                }
                ControlActionButton("Reset Pair", style: .destructive) {
                    store.resetPairing()
                }

                if store.updateState.isUpdateAvailable {
                    ControlActionButton("Update", style: .primary) {
                        store.updateBridgePackage()
                    }
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(cardStroke)
    }

    @ViewBuilder
    private var qrCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                cardTitle("Pairing QR")
                Spacer()

                if let payload = store.snapshot?.pairingSession?.pairingPayload {
                    statusPill(
                        title: payload.isExpired ? "Expired" : "Ready",
                        tint: payload.isExpired ? .orange : .green
                    )
                }
            }

            if let payload = store.snapshot?.pairingSession?.pairingPayload {
                HStack(alignment: .top, spacing: 14) {
                    PairingQRCodeView(payload: payload)
                        .frame(width: 124, height: 124)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 8) {
                        LabelValueRow(label: "Session", value: payload.sessionId)
                        LabelValueRow(label: "Device", value: payload.macDeviceId)
                        LabelValueRow(label: "Expires", value: payload.expiryDate.formatted(date: .omitted, time: .shortened))
                    }
                }
            } else {
                Text("Start the bridge to publish a fresh pairing payload here without opening Terminal.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(cardStroke)
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Logs & State")

            if let snapshot = store.snapshot {
                LabelValueRow(label: "Stdout", value: snapshot.stdoutLogPath)
                LabelValueRow(label: "Stderr", value: snapshot.stderrLogPath)
            }

            HStack(spacing: 8) {
                ControlActionButton("Logs Folder", style: .secondary) {
                    store.openLogsFolder()
                }
                ControlActionButton("Stdout", style: .secondary) {
                    store.openStdoutLog()
                }
                ControlActionButton("Stderr", style: .secondary) {
                    store.openStderrLog()
                }
            }
        }
        .padding(16)
        .background(cardBackground)
        .overlay(cardStroke)
    }

    @ViewBuilder
    private var feedbackCard: some View {
        let hasUpdateError = !(store.updateState.errorMessage?.isEmpty ?? true)
        let hasBridgeError = !(store.snapshot?.lastErrorMessage ?? "").isEmpty
        if !store.errorMessage.isEmpty || !store.transientMessage.isEmpty || hasUpdateError || hasBridgeError {
            VStack(alignment: .leading, spacing: 8) {
                cardTitle("Feedback")

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
            .padding(16)
            .background(cardBackground)
            .overlay(cardStroke)
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.accentColor.opacity(colorScheme == .dark ? 0.12 : 0.08),
                            .clear,
                        ],
                        center: .topTrailing,
                        startRadius: 10,
                        endRadius: 380
                    )
                )
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.62 : 0.78))
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }

    private var statusTint: Color {
        if !store.isCLIAvailable {
            return cliStatusTint
        }

        if store.updateState.isUpdateAvailable {
            return .orange
        }

        let connectionStatus = store.snapshot?.bridgeStatus?.connectionStatus?.lowercased()
        if connectionStatus == "connected" {
            return .green
        }
        if connectionStatus == "connecting" || connectionStatus == "starting" {
            return .yellow
        }
        if connectionStatus == "error" {
            return .red
        }

        return store.snapshot?.launchdLoaded == true ? .blue : .gray
    }

    private var cliStatusTint: Color {
        switch store.cliAvailability {
        case .checking:
            return .yellow
        case .available:
            return .green
        case .missing:
            return .orange
        case .broken:
            return .red
        }
    }

    private var currentStatusTitle: String {
        if let snapshot = store.snapshot {
            return snapshot.statusHeadline
        }

        switch store.cliAvailability {
        case .available:
            return "Loading"
        case .checking:
            return "Checking"
        case .missing:
            return "CLI Missing"
        case .broken:
            return "CLI Error"
        }
    }

    private var pidLabel: String {
        if let launchdPid = store.snapshot?.launchdPid {
            return String(launchdPid)
        }
        if let bridgePid = store.snapshot?.bridgeStatus?.pid {
            return String(bridgePid)
        }

        return "n/a"
    }

    private func cardTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(1)
    }

    private func statusPill(title: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.12), in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.22), lineWidth: 1)
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
        .background(Color(nsColor: .textBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func feedbackLine(_ message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BridgeMenuBarLabel: View {
    let snapshot: BridgeSnapshot?
    let updateState: BridgePackageUpdateState
    let isBusy: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: isBusy ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .symbolRenderingMode(.monochrome)
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

private struct LabelValueRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

private struct ControlActionButton: View {
    let title: String
    let style: ControlActionButtonStyle
    let action: () -> Void

    init(_ title: String, style: ControlActionButtonStyle = .secondary, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return .black
        case .secondary:
            return Color(nsColor: .textBackgroundColor).opacity(0.82)
        case .destructive:
            return Color(nsColor: .textBackgroundColor).opacity(0.82)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:
            return .white
        case .secondary:
            return .primary
        case .destructive:
            return .red
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return .black.opacity(0.9)
        case .secondary:
            return .primary.opacity(0.06)
        case .destructive:
            return .red.opacity(0.18)
        }
    }
}

private enum ControlActionButtonStyle {
    case primary
    case secondary
    case destructive
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
                    .padding(10)
            } else {
                Text("QR unavailable")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.7))
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
        guard let data = try? JSONEncoder().encode(payloadObject) else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

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
