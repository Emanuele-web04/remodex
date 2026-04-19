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

        // Once the silent wake attempt has already failed, prefer the explicit wake fallback over passive retry copy.
        if showsWakeSavedMacDisplayAction {
            return ConnectionRecoverySnapshot(
                summary: trimmedError?.isEmpty == false
                    ? trimmedError ?? ""
                    : "Wake your Mac screen to keep this chat in sync.",
                status: .interrupted,
                trailingStyle: .action("Wake Screen")
            )
        }

        if isWakingMacDisplayRecovery {
            return ConnectionRecoverySnapshot(
                summary: trimmedError?.isEmpty == false
                    ? trimmedError ?? ""
                    : "Trying to wake your Mac display.",
                status: .reconnecting,
                trailingStyle: .progress
            )
        }

        if isConnecting || shouldAutoReconnectOnForeground || isRetryingConnectionRecovery {
            return ConnectionRecoverySnapshot(
                summary: "Trying to reconnect to your Mac.",
                status: .reconnecting,
                trailingStyle: .progress
            )
        }

        return ConnectionRecoverySnapshot(
            summary: trimmedError?.isEmpty == false
                ? trimmedError ?? ""
                : "Reconnect to your Mac to keep this chat in sync.",
            status: .interrupted,
            trailingStyle: .action("Reconnect")
        )
    }
}
