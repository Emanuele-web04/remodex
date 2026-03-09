// FILE: HomeEmptyStateView.swift
// Purpose: Minimal splash screen with branding and live connection status.
// Layer: View
// Exports: HomeEmptyStateView
// Depends on: SwiftUI

import SwiftUI

struct HomeEmptyStateView<AuthSection: View>: View {
    let isConnected: Bool
    let isConnecting: Bool
    let onToggleConnection: () -> Void
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
                            isConnecting
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

                // Keeps the remembered relay pairing actionable after app relaunch or stale reconnects.
                Button(action: onToggleConnection) {
                    HStack(spacing: 10) {
                        if isConnecting {
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
                .disabled(isConnecting)
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
            if isConnecting {
                connectionAttemptStartedAt = Date()
                dotPulse = true
            }
        }
        .onChange(of: isConnecting) { _, connecting in
            connectionAttemptStartedAt = connecting ? Date() : nil
            dotPulse = connecting
        }
    }

    // MARK: - Helpers

    private var statusDotColor: Color {
        if isConnecting { return .orange }
        return isConnected ? .green : Color(.tertiaryLabel)
    }

    private var statusLabel: String {
        if isConnecting {
            guard let connectionAttemptStartedAt else { return "Connecting" }
            let elapsed = Date().timeIntervalSince(connectionAttemptStartedAt)
            if elapsed >= 12 { return "Still connecting…" }
            return "Connecting"
        }
        return isConnected ? "Connected" : "Offline"
    }

    private var primaryButtonTitle: String {
        if isConnecting {
            return "Reconnecting..."
        }
        return isConnected ? "Disconnect" : "Reconnect"
    }

    private var primaryButtonBackground: Color {
        isConnected ? Color(.secondarySystemFill) : .black
    }

    private var primaryButtonForeground: Color {
        isConnected ? Color.primary : .white
    }
}
