// FILE: SettingsCommandReferenceCard.swift
// Purpose: Sheet with local Remodex CLI commands for pairing and bridge management.
// Layer: Settings UI component
// Exports: SettingsCommandReferenceSheet
// Depends on: SwiftUI, UIKit, SettingsBaseComponents

import SwiftUI
import UIKit

private struct SettingsCommandReference: Identifiable {
    static let commands = [
        SettingsCommandReference(
            command: "remodex up",
            detail: "Starts the bridge and prints a pairing QR for first-time setup."
        ),
        SettingsCommandReference(
            command: "remodex start",
            detail: "Starts the background bridge without printing a QR."
        ),
        SettingsCommandReference(
            command: "remodex restart",
            detail: "Restarts the bridge when the app can't reconnect cleanly."
        ),
        SettingsCommandReference(
            command: "remodex qr / pair",
            detail: "Refreshes the bridge and prints a new pairing QR code."
        ),
        SettingsCommandReference(
            command: "remodex status",
            detail: "Shows whether the bridge is loaded and recently paired."
        ),
        SettingsCommandReference(
            command: "remodex stop",
            detail: "Stops the background bridge on your Mac."
        ),
        SettingsCommandReference(
            command: "remodex reset-pairing",
            detail: "Clears saved trust so the next connection needs a fresh QR."
        ),
        SettingsCommandReference(
            command: "remodex resume",
            detail: "Reopens the last active Remodex thread in Codex."
        ),
        SettingsCommandReference(
            command: "remodex watch [threadId]",
            detail: "Tails a thread event log in real time."
        ),
        SettingsCommandReference(
            command: "remodex --version",
            detail: "Prints the installed Remodex CLI version."
        )
    ]

    let command: String
    let detail: String

    var id: String { command }
}

struct SettingsCommandReferenceSheet: View {
    private let commands = SettingsCommandReference.commands

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Run these in Terminal on your paired Mac when you need to start, repair, or inspect the local Remodex bridge.")
                        .font(AppFont.footnote())
                        .foregroundStyle(.secondary)
                }

                Section("Commands") {
                    ForEach(commands) { command in
                        SettingsCommandReferenceRow(command: command)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .font(AppFont.body())
            .navigationTitle("Terminal Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SettingsCommandReferenceRow: View {
    let command: SettingsCommandReference
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(command.command)
                    .font(AppFont.mono(.subheadline))
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(command.detail)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                copyCommand()
            } label: {
                RemodexIcon.image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Copied \(command.command)" : "Copy \(command.command)")
        }
        .padding(.vertical, 4)
    }

    private func copyCommand() {
        UIPasteboard.general.string = command.command
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopy = false
        }
    }
}
