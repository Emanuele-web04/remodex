// FILE: SettingsConnectionCard.swift
// Purpose: Presents paired-computer connection state and connection actions.
// Layer: Settings UI component
// Exports: SettingsConnectionCard
// Depends on: SwiftUI, CodexService connection state, SettingsSupportCards

import SwiftUI

struct SettingsConnectionCard: View {
    @Environment(CodexService.self) private var codex
    let onEditComputerName: () -> Void

    var body: some View {
        SettingsCard(title: "Connection") {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                SettingsTrustedComputerCard(
                    presentation: trustedPairPresentation,
                    connectionStatusLabel: connectionStatusLabel,
                    onEditName: onEditComputerName
                )
            } else {
                Text("No paired device")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
            }

            if connectionPhaseShowsProgress {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(connectionProgressLabel)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            if case .retrying(_, let message) = codex.connectionRecoveryState,
               !message.isEmpty {
                Text(message)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if let error = codex.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
            }

            if codex.supportsKeepAwakeWhileBridgeRuns {
                Toggle("Keep device reachable", isOn: keepMacAwakeWhileBridgeRunsBinding)
                    .tint(settingsToggleTintColor)

                    Text(codex.keepMacAwakeWhileBridgeRuns
                     ? "Uses the host device's keep-awake support while the bridge is running so the device stays reachable even if the display turns off. Best while charging."
                     : "The device can go back to sleeping normally when the bridge is idle.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                if !codex.isConnected {
                    Text("Saved on this iPhone. It will sync to the paired device the next time the bridge reconnects.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            if codex.isConnected {
                SettingsButton("Disconnect", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    disconnectRelay()
                }
            } else if codex.hasTrustedMacReconnectCandidate {
                SettingsButton("Forget Pair", role: .destructive) {
                    HapticFeedback.shared.triggerImpactFeedback()
                    codex.forgetTrustedMac()
                }
            }
        }
    }

    private var keepMacAwakeWhileBridgeRunsBinding: Binding<Bool> {
        Binding(
            get: { codex.keepMacAwakeWhileBridgeRuns },
            set: { nextValue in
                codex.setKeepMacAwakeWhileBridgeRunsPreference(nextValue)
                Task { @MainActor in
                    await codex.syncBridgeKeepMacAwakePreferenceIfNeeded(showFailureInUI: true)
                }
            }
        )
    }

    private var connectionPhaseShowsProgress: Bool {
        switch codex.connectionPhase {
        case .connecting, .loadingChats, .syncing:
            return true
        case .offline, .connected:
            return false
        }
    }

    private var connectionStatusLabel: String {
        switch codex.connectionPhase {
        case .offline:
            return "offline"
        case .connecting:
            return "connecting"
        case .loadingChats:
            return "loading chats"
        case .syncing:
            return "syncing"
        case .connected:
            return "connected"
        }
    }

    private var connectionProgressLabel: String {
        switch codex.connectionPhase {
        case .connecting:
            return "Connecting to relay..."
        case .loadingChats:
            return "Loading chats..."
        case .syncing:
            return "Syncing workspace..."
        case .offline, .connected:
            return ""
        }
    }

    // MARK: - Actions

    private func disconnectRelay() {
        Task { @MainActor in
            await codex.disconnect()
            codex.clearSavedRelaySession()
        }
    }

}
