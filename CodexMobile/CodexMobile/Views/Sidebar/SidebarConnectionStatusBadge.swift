// FILE: SidebarConnectionStatusBadge.swift
// Purpose: Compact capsule pill that surfaces the live relay connection phase
//          in the sidebar's chip row under search. Hides itself when the relay
//          is fully `.connected` so the happy path never has a stale status
//          indicator hanging around.
// Layer: View Component
// Exports: SidebarConnectionStatusBadge
// Depends on: SwiftUI, CodexConnectionPhase, AppFont, AdaptiveGlassModifier

import SwiftUI

struct SidebarConnectionStatusBadge: View {
    let connectionPhase: CodexConnectionPhase

    @State private var dotPulse = false
    @State private var connectionAttemptStartedAt: Date?

    var body: some View {
        if connectionPhase == .connected {
            EmptyView()
        } else {
            // No self-applied frame/padding so the parent (the panel's centered
            // VStack) decides alignment + rhythm. The `.connected` branch above
            // stays a pure EmptyView so the parent's stack spacing collapses
            // cleanly when there is nothing to show.
            badge
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
    }

    private var badge: some View {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .adaptiveGlass(
            .regular,
            isInteractive: false,
            fallbackMaterial: .ultraThinMaterial,
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Connection status: \(statusLabel)"))
    }

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
}

#if DEBUG
#Preview("Offline") {
    SidebarConnectionStatusBadge(connectionPhase: .offline)
        .padding()
}

#Preview("Connecting") {
    SidebarConnectionStatusBadge(connectionPhase: .connecting)
        .padding()
}

#Preview("Loading chats") {
    SidebarConnectionStatusBadge(connectionPhase: .loadingChats)
        .padding()
}

#Preview("Connected (hidden)") {
    SidebarConnectionStatusBadge(connectionPhase: .connected)
        .padding()
        .border(.red)
}
#endif
