// FILE: HomeEmptyStateView.swift
// Purpose: Minimal splash screen with branding and live connection status.
// Layer: View
// Exports: HomeEmptyStateView
// Depends on: SwiftUI

import SwiftUI

struct HomeEmptyStateView<AuthSection: View>: View {
    let connectionPhase: CodexConnectionPhase
    let statusMessage: String?
    let securityLabel: String?
    let trustedPairPresentation: CodexTrustedPairPresentation?
    let offlinePrimaryButtonTitle: String
    let onPrimaryAction: () -> Void
    @ViewBuilder let authSection: () -> AuthSection

    @State private var dotPulse = false
    @State private var connectionAttemptStartedAt: Date?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .adaptiveGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                        .scaleEffect(dotPulse ? 1.4 : 1.0)
                        .opacity(dotPulse ? 0.6 : 1.0)
                        .animation(
                            isBusy
                                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                : .default,
                            value: dotPulse
                        )

                    Text(statusLabel)
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

                if let trustedPairPresentation {
                    TrustedPairSummaryView(presentation: trustedPairPresentation)
                } else if let securityLabel, !securityLabel.isEmpty {
                    Text(securityLabel)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }

                if let statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Keeps reconnect or a fresh QR scan one tap away from the empty state.
                Button(action: onPrimaryAction) {
                    HStack(spacing: 10) {
                        if isBusy {
                            ProgressView()
                                .tint(.gray)
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
                .padding(.top, 6)

                authSection()
            }
            .frame(maxWidth: 280)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Remodex")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if connectionPhase == .connecting {
                connectionAttemptStartedAt = Date()
            }
            dotPulse = isBusy
        }
        .onChange(of: connectionPhase) { _, phase in
            connectionAttemptStartedAt = phase == .connecting ? Date() : nil
            dotPulse = isBusy
        }
    }

    // MARK: - Helpers

    private var isBusy: Bool {
        switch connectionPhase {
        case .connecting, .loadingChats, .syncing:
            return true
        case .offline, .connected:
            return false
        }
    }

    private var statusDotColor: Color {
        switch connectionPhase {
        case .connecting, .loadingChats, .syncing:
            return .orange
        case .connected:
            return .green
        case .offline:
            return Color(.tertiaryLabel)
        }
    }

    private var statusLabel: String {
        switch connectionPhase {
        case .connecting:
            guard let connectionAttemptStartedAt else { return "Connecting" }
            let elapsed = Date().timeIntervalSince(connectionAttemptStartedAt)
            if elapsed >= 12 { return "Still connecting…" }
            return "Connecting"
        case .loadingChats:
            return "Loading chats"
        case .syncing:
            return "Syncing"
        case .connected:
            return "Connected"
        case .offline:
            return "Offline"
        }
    }

    private var primaryButtonTitle: String {
        switch connectionPhase {
        case .connecting:
            return "Reconnecting..."
        case .loadingChats:
            return "Loading chats..."
        case .syncing:
            return "Syncing..."
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
