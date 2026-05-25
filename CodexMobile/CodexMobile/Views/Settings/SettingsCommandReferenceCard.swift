// FILE: SettingsCommandReferenceCard.swift
// Purpose: Shows the local Remodex CLI commands users may need while pairing or managing the Mac bridge.
// Layer: Settings UI component
// Exports: SettingsCommandReferenceCard
// Depends on: SwiftUI, SettingsBaseComponents

import SwiftUI

struct SettingsCommandReferenceCard: View {
    private let commands = [
        SettingsCommandReference(
            command: "remodex up",
            detail: "Starts Remodex on your Mac, refreshes the bridge service, and prints a pairing QR for first-time setup or recovery."
        ),
        SettingsCommandReference(
            command: "remodex start",
            detail: "Starts the background bridge service without printing a QR in the current Terminal window."
        ),
        SettingsCommandReference(
            command: "remodex restart",
            detail: "Restarts the background bridge service when the Mac is paired but the app cannot reconnect cleanly."
        ),
        SettingsCommandReference(
            command: "remodex qr / remodex pair",
            detail: "Refreshes the bridge and prints a new QR code so this iPhone can scan and trust the Mac again."
        ),
        SettingsCommandReference(
            command: "remodex status",
            detail: "Shows whether the Mac bridge service is loaded and whether a recent pairing payload is available."
        ),
        SettingsCommandReference(
            command: "remodex stop",
            detail: "Stops the background bridge service on your Mac and clears its transient runtime status."
        ),
        SettingsCommandReference(
            command: "remodex reset-pairing",
            detail: "Clears saved pairing trust so the next connection requires a fresh QR scan."
        ),
        SettingsCommandReference(
            command: "remodex resume",
            detail: "Reopens the last active Remodex thread in Codex on your Mac."
        ),
        SettingsCommandReference(
            command: "remodex watch [threadId]",
            detail: "Tails a thread event log in real time from Terminal."
        ),
        SettingsCommandReference(
            command: "remodex --version",
            detail: "Prints the installed Remodex CLI version."
        )
    ]

    var body: some View {
        SettingsCard(title: "Mac commands") {
            Text("Run these in Terminal on your paired Mac when you need to start, repair, or inspect the local Remodex bridge.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)

            ForEach(commands) { command in
                SettingsCommandReferenceRow(command: command)
            }
        }
    }
}

private struct SettingsCommandReference: Identifiable {
    let command: String
    let detail: String

    var id: String { command }
}

private struct SettingsCommandReferenceRow: View {
    let command: SettingsCommandReference

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(command.command)
                .font(AppFont.mono(.caption))
                .foregroundStyle(.primary)

            Text(command.detail)
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
