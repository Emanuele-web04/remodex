// FILE: SidebarConnectionEmptyStatePanel.swift
// Purpose: Centered connect/reconnect/scan-QR card shown in the sidebar when
//          the relay session is offline and there are no cached chats.
//          Focuses on the remembered host identity + primary reconnect CTA,
//          while the status chip and footer stay owned by the surrounding
//          sidebar layout.
// Layer: View Component
// Exports: SidebarConnectionEmptyStatePanel
// Depends on: SwiftUI, CodexConnectionPhase, CodexTrustedPairPresentation,
//             AppFont

import SwiftUI

struct SidebarConnectionEmptyStatePanel: View {
    let connectionPhase: CodexConnectionPhase
    let trustedPairPresentation: CodexTrustedPairPresentation?
    let securityLabel: String?
    let hasReconnectCandidate: Bool
    let isWakingSavedMacDisplay: Bool
    let shouldOfferWakeAction: Bool
    let isPreparingManualScanner: Bool
    let isResolvingManualPairingCode: Bool
    let offlinePrimaryButtonTitle: String
    let onPrimaryAction: () -> Void
    let onScanNewQR: () -> Void
    let onPairWithCode: () -> Void
    let onWakeMacDisplay: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            identityBlock

            primaryButton

            if showsRetryAffordances {
                if hasReconnectCandidate {
                    secondaryActions
                }

                if shouldOfferWakeAction {
                    wakeDisplayButton
                }
            }
        }
        .frame(maxWidth: 300)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: - Identity (hero + name + detail)

    private var identityBlock: some View {
        VStack(spacing: 10) {
            heroIcon

            Text(heroTitle)
                .font(AppFont.headline(weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let detailText {
                detailRow(detailText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityIdentityLabel))
    }

    private var heroIcon: some View {
        ZStack {
            Circle()
                .fill(.tertiary.opacity(0.06))
            Circle()
                .strokeBorder(.tertiary.opacity(0.08), lineWidth: 1)
            RemodexIcon.image(systemName: heroIconName, size: 28, weight: .regular)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }

    // MARK: - Detail row

    // Highlights security states that need user attention ("Re-pair required",
    // "Update required", "Not paired") with a small amber glyph + primary text
    // color. Stays quiet for neutral informational details.
    @ViewBuilder
    private func detailRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isDetailWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Text(text)
                .font(AppFont.caption(weight: .regular))
                .foregroundStyle(isDetailWarning ? .secondary : .tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 6)
    }

    private var heroIconName: String {
        trustedPairPresentation == nil ? "qrcode.viewfinder" : "desktopcomputer"
    }

    private var heroTitle: String {
        trustedPairPresentation?.name ?? "No Mac paired yet"
    }

    private var accessibilityIdentityLabel: String {
        guard let detailText else { return heroTitle }
        return "\(heroTitle). \(detailText)"
    }

    private var isDetailWarning: Bool {
        guard let text = detailText?.lowercased() else { return false }
        return text.contains("re-pair required")
            || text.contains("update required")
            || text.contains("not paired")
    }

    // MARK: - Buttons

    private var primaryButton: some View {
        Button(action: onPrimaryAction) {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView()
                        .tint(primaryButtonForeground)
                        .scaleEffect(0.9)
                }

                Text(primaryButtonTitle)
                    .font(AppFont.body(weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .foregroundStyle(primaryButtonForeground)
            .background(primaryButtonBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var wakeDisplayButton: some View {
        Button(action: onWakeMacDisplay) {
            HStack(spacing: 6) {
                if isWakingSavedMacDisplay {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.primary)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                }

                Text(isWakingSavedMacDisplay ? "Waking Screen…" : "Wake Screen")
                    .font(AppFont.footnote(weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPreparingManualScanner || isWakingSavedMacDisplay)
    }

    private var secondaryActions: some View {
        HStack(spacing: 10) {
            secondaryButton("New QR Code", systemName: "qrcode.viewfinder", action: onScanNewQR)
                .disabled(isPreparingManualScanner)

            secondaryButton("Pair with Code", systemName: "keyboard", action: onPairWithCode)
                .disabled(isPreparingManualScanner || isResolvingManualPairingCode)
        }
    }

    // Mirrors the primary button's shape so the outlined retry chips read as
    // the same family: identical corner radius, continuous style, and vertical
    // padding — only the fill is swapped for a 1pt stroke.
    private func secondaryButton(
        _ title: String,
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .foregroundStyle(.primary)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .buttonStyle(.plain)
    }

    // MARK: - Derived state

    // Prefer the trusted pair detail (e.g. "Re-pair required") and fall back to
    // the generic security label when no pair is remembered yet.
    private var detailText: String? {
        if let detail = trustedPairPresentation?.detail, !detail.isEmpty {
            return detail
        }
        if trustedPairPresentation == nil,
           let securityLabel,
           !securityLabel.isEmpty {
            return securityLabel
        }
        return nil
    }

    // Mirrors HomeEmptyStateView: only expose wake + secondary CTAs while a
    // reconnect attempt is live, so first-run installs see just the scan button.
    private var showsRetryAffordances: Bool {
        connectionPhase == .connecting || (hasReconnectCandidate && connectionPhase != .connected)
    }

    private var isBusy: Bool {
        switch connectionPhase {
        case .connecting, .loadingChats, .syncing:
            return true
        case .offline, .connected:
            return false
        }
    }

    private var primaryButtonTitle: String {
        switch connectionPhase {
        case .connecting:
            return "Reconnecting…"
        case .loadingChats:
            return "Loading chats…"
        case .syncing:
            return "Syncing…"
        case .connected:
            return "Disconnect"
        case .offline:
            return offlinePrimaryButtonTitle
        }
    }

    private var primaryButtonBackground: Color {
        isSocketReady ? Color(.secondarySystemFill) : Color.primary
    }

    private var primaryButtonForeground: Color {
        isSocketReady ? Color.primary : Color(.systemBackground)
    }

    private var isSocketReady: Bool {
        switch connectionPhase {
        case .loadingChats, .syncing, .connected:
            return true
        case .offline, .connecting:
            return false
        }
    }
}

#if DEBUG
#Preview("Offline — fresh install") {
    SidebarConnectionEmptyStatePanel(
        connectionPhase: .offline,
        trustedPairPresentation: nil,
        securityLabel: nil,
        hasReconnectCandidate: false,
        isWakingSavedMacDisplay: false,
        shouldOfferWakeAction: false,
        isPreparingManualScanner: false,
        isResolvingManualPairingCode: false,
        offlinePrimaryButtonTitle: "Scan QR Code",
        onPrimaryAction: {},
        onScanNewQR: {},
        onPairWithCode: {},
        onWakeMacDisplay: {}
    )
}

#Preview("Offline — reconnect candidate") {
    SidebarConnectionEmptyStatePanel(
        connectionPhase: .offline,
        trustedPairPresentation: CodexTrustedPairPresentation(
            deviceId: "abc",
            title: "Trusted Computer",
            name: "Mac 8026751ACA1A",
            systemName: nil,
            detail: "Re-pair required"
        ),
        securityLabel: nil,
        hasReconnectCandidate: true,
        isWakingSavedMacDisplay: false,
        shouldOfferWakeAction: true,
        isPreparingManualScanner: false,
        isResolvingManualPairingCode: false,
        offlinePrimaryButtonTitle: "Reconnect",
        onPrimaryAction: {},
        onScanNewQR: {},
        onPairWithCode: {},
        onWakeMacDisplay: {}
    )
}

#Preview("Offline — neutral detail") {
    SidebarConnectionEmptyStatePanel(
        connectionPhase: .offline,
        trustedPairPresentation: CodexTrustedPairPresentation(
            deviceId: "abc",
            title: "Trusted Computer",
            name: "Studio Mini",
            systemName: nil,
            detail: "Trusted Computer ready"
        ),
        securityLabel: nil,
        hasReconnectCandidate: true,
        isWakingSavedMacDisplay: false,
        shouldOfferWakeAction: true,
        isPreparingManualScanner: false,
        isResolvingManualPairingCode: false,
        offlinePrimaryButtonTitle: "Reconnect",
        onPrimaryAction: {},
        onScanNewQR: {},
        onPairWithCode: {},
        onWakeMacDisplay: {}
    )
}

#Preview("Connecting") {
    SidebarConnectionEmptyStatePanel(
        connectionPhase: .connecting,
        trustedPairPresentation: nil,
        securityLabel: nil,
        hasReconnectCandidate: true,
        isWakingSavedMacDisplay: false,
        shouldOfferWakeAction: false,
        isPreparingManualScanner: false,
        isResolvingManualPairingCode: false,
        offlinePrimaryButtonTitle: "Reconnect",
        onPrimaryAction: {},
        onScanNewQR: {},
        onPairWithCode: {},
        onWakeMacDisplay: {}
    )
}
#endif
