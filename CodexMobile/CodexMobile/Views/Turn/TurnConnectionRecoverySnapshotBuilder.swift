// FILE: TurnConnectionRecoverySnapshotBuilder.swift
// Purpose: Centralizes the turn recovery card decision so offline wake affordances stay testable.
// Layer: View support
// Exports: TurnConnectionRecoverySnapshotBuilder
// Depends on: Foundation, ConnectionRecoveryCard, CodexSecureTransportModels

import Foundation

enum TurnConnectionRecoverySnapshotBuilder {
    static func makeSnapshot(
        hasReconnectCandidate: Bool,
        isConnected: Bool,
        secureConnectionState: CodexSecureConnectionState,
        showsWakeSavedMacDisplayAction: Bool,
        isWakingMacDisplayRecovery: Bool,
        isConnecting: Bool,
        shouldAutoReconnectOnForeground: Bool,
        isRetryingConnectionRecovery: Bool,
        lastErrorMessage: String?
    ) -> ConnectionRecoverySnapshot? {
        guard hasReconnectCandidate,
              !isConnected,
              secureConnectionState != .rePairRequired else {
            return nil
        }

        let trimmedError = lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)

        if isWakingMacDisplayRecovery {
            return ConnectionRecoverySnapshot(
                summary: trimmedError?.isEmpty == false
                    ? trimmedError ?? ""
                    : "Trying to wake the computer display.",
                status: .reconnecting,
                trailingStyle: .progress
            )
        }

        // While foreground auto-recovery is still running, keep the card in progress
        // instead of surfacing the manual wake fallback on every app switch.
        if isConnecting || shouldAutoReconnectOnForeground || isRetryingConnectionRecovery {
            return ConnectionRecoverySnapshot(
                summary: "Trying to reconnect to your computer.",
                status: .reconnecting,
                trailingStyle: .progress
            )
        }

        if showsWakeSavedMacDisplayAction {
            return ConnectionRecoverySnapshot(
                summary: trimmedError?.isEmpty == false
                    ? trimmedError ?? ""
                    : "Wake the computer screen to keep this chat in sync.",
                status: .interrupted,
                trailingStyle: .action("Wake Screen")
            )
        }

        return ConnectionRecoverySnapshot(
            summary: trimmedError?.isEmpty == false
                ? trimmedError ?? ""
                : "Reconnect to your computer to keep this chat in sync.",
            status: .interrupted,
            trailingStyle: .action("Reconnect")
        )
    }
}
