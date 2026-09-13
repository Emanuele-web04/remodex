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
        SettingsCard(
            title: "Device",
            footer: keepAwakeFooter
        ) {
            if let trustedPairPresentation = codex.trustedPairPresentation {
                SettingsTrustedComputerCard(
                    presentation: trustedPairPresentation,
                    connectionStatusLabel: connectionStatusLabel,
                    onEditName: onEditComputerName
                )
            } else {
                SettingsInlineMessage(text: "No paired device yet. Scan the QR code from your Mac to connect.")
            }

            if connectionPhaseShowsProgress {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(connectionProgressLabel)
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                }
            }

            if case .retrying(_, let message) = codex.connectionRecoveryState,
               !message.isEmpty {
                SettingsInlineMessage(text: message)
            }

            if let error = codex.lastErrorMessage, !error.isEmpty {
                SettingsInlineMessage(text: error, tint: .red)
            }

            if codex.supportsKeepAwakeWhileBridgeRuns {
                if codex.supportsKeepAwakeModes {
                    Picker("Keep device reachable", selection: keepMacAwakeModeBinding) {
                        ForEach(CodexKeepAwakeMode.allCases, id: \.self) { mode in
                            Text(keepAwakeModeLabel(mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    Toggle("Keep device reachable", isOn: keepMacAwakeWhileBridgeRunsBinding)
                        .tint(settingsToggleTintColor)
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

    private var keepAwakeFooter: String? {
        guard codex.supportsKeepAwakeWhileBridgeRuns else { return nil }

        switch codex.keepMacAwakeMode {
        case .acPower:
            return "Keeps your Mac reachable while it is plugged into power and the bridge is running."
        case .always:
            return "Keeps your Mac reachable on power and battery while the bridge is running."
        case .off:
            break
        }

        if !codex.isConnected {
            return "Preference is saved on this iPhone and syncs when the bridge reconnects."
        }

        return nil
    }

    private var keepMacAwakeModeBinding: Binding<CodexKeepAwakeMode> {
        Binding(
            get: { codex.keepMacAwakeMode },
            set: { nextMode in
                codex.setKeepMacAwakeModePreference(nextMode)
                Task { @MainActor in
                    await codex.syncBridgeKeepMacAwakePreferenceIfNeeded(showFailureInUI: true)
                }
            }
        )
    }

    private func keepAwakeModeLabel(_ mode: CodexKeepAwakeMode) -> String {
        switch mode {
        case .off:
            return "Off"
        case .acPower:
            return "While Plugged In"
        case .always:
            return "Always"
        }
    }

    private var keepMacAwakeWhileBridgeRunsBinding: Binding<Bool> {
        Binding(
            get: { codex.keepMacAwakeMode == .always },
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
            return "Offline"
        case .connecting:
            return "Connecting"
        case .loadingChats:
            return "Loading"
        case .syncing:
            return "Syncing"
        case .connected:
            return "Connected"
        }
    }

    private var connectionProgressLabel: String {
        switch codex.connectionPhase {
        case .connecting:
            return "Connecting to relay…"
        case .loadingChats:
            return "Loading chats…"
        case .syncing:
            return "Syncing workspace…"
        case .offline, .connected:
            return ""
        }
    }

    private func disconnectRelay() {
        Task { @MainActor in
            await codex.disconnect()
            codex.clearSavedRelaySession()
        }
    }
}
