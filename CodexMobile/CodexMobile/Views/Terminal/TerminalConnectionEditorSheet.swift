// FILE: TerminalConnectionEditorSheet.swift
// Purpose: Owns the SSH connection editor sheet and its form sections.
// Layer: View Component
// Exports: TerminalConnectionEditorSheet
// Depends on: SwiftUI, UIKit, RemodexTerminalModels, RemodexTerminalPrivateKeyStore

import SwiftUI
import UIKit

struct TerminalConnectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var profile: RemodexTerminalProfile
    @Binding var connection: String
    @Binding var privateKey: String
    @Binding var passphrase: String

    let canSave: Bool
    let onSave: () -> Void
    let onResetKnownHost: () -> Void

    @State private var isShowingAdvanced = false
    @State private var isShowingKeyEditor = false
    @State private var isConfirmingKnownHostReset = false
    @State private var isShowingConnectionHelp = false

    private var keyLabel: String {
        RemodexTerminalPrivateKeyStore.hasPrivateKey(privateKey) ? "Imported" : "Import"
    }

    private var advancedLabel: String {
        profile.port == 22 ? "Default" : "Custom"
    }

    private var isAdvancedVisible: Bool {
        isShowingAdvanced
            || profile.port != 22
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { String(profile.port) },
            set: { value in
                if let parsedPort = Int(value) {
                    profile.port = max(1, min(65535, parsedPort))
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TerminalEditorSection(title: "Connection") {
                        TerminalConnectionStringField(connection: $connection)
                    }

                    TerminalEditorSection(title: "Nickname") {
                        TerminalRoundedTextField(
                            placeholder: "Nickname",
                            text: $profile.nickname
                        )
                    }

                    TerminalAuthenticationSection(
                        keyLabel: keyLabel,
                        privateKey: $privateKey,
                        passphrase: $passphrase,
                        isShowingKeyEditor: $isShowingKeyEditor
                    )

                    TerminalSSHSection(
                        profile: $profile,
                        portBinding: portBinding,
                        isShowingAdvanced: $isShowingAdvanced,
                        isConfirmingKnownHostReset: $isConfirmingKnownHostReset,
                        advancedLabel: advancedLabel,
                        isAdvancedVisible: isAdvancedVisible
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
            }
            .navigationTitle("New Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        HapticFeedback.shared.triggerImpactFeedback(style: .light)
                        isShowingConnectionHelp = true
                    } label: {
                        RemodexIcon.image(systemName: "questionmark.circle")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .accessibilityLabel("SSH setup guide")

                    Button("Connect", action: onSave)
                        .font(.system(size: 15, weight: .bold))
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $isShowingConnectionHelp) {
                TerminalConnectionHelpSheet()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "Reset saved SSH host key?",
                isPresented: $isConfirmingKnownHostReset,
                titleVisibility: .visible
            ) {
                Button("Reset Host Key", role: .destructive, action: onResetKnownHost)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The next connection to this host will trust the key it presents.")
            }
        }
    }
}

private struct TerminalAuthenticationSection: View {
    let keyLabel: String
    @Binding var privateKey: String
    @Binding var passphrase: String
    @Binding var isShowingKeyEditor: Bool

    var body: some View {
        TerminalEditorSection(title: "Authentication") {
            VStack(spacing: 0) {
                TerminalEditorRow(title: "Method", value: "SSH Key")
                Divider()
                Button(action: toggleKeyEditor) {
                    TerminalEditorRow(
                        title: "SSH Key",
                        value: keyLabel,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                if isShowingKeyEditor || !RemodexTerminalPrivateKeyStore.hasPrivateKey(privateKey) {
                    TerminalPrivateKeyEditor(privateKey: $privateKey, passphrase: $passphrase)
                        .padding(.top, 14)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func toggleKeyEditor() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isShowingKeyEditor.toggle()
        }
    }
}

private struct TerminalSSHSection: View {
    @Binding var profile: RemodexTerminalProfile
    let portBinding: Binding<String>
    @Binding var isShowingAdvanced: Bool
    @Binding var isConfirmingKnownHostReset: Bool
    let advancedLabel: String
    let isAdvancedVisible: Bool

    var body: some View {
        TerminalEditorSection(title: "SSH") {
            VStack(spacing: 0) {
                Button(action: toggleAdvanced) {
                    TerminalEditorRow(
                        title: "Advanced Configuration",
                        value: advancedLabel,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                if isAdvancedVisible {
                    Divider()
                    TerminalTextField(
                        title: "Port",
                        text: portBinding,
                        placeholder: "22",
                        keyboardType: .numberPad
                    )
                    .padding(.top, 14)
                }

                Divider()
                Button {
                    isConfirmingKnownHostReset = true
                } label: {
                    TerminalEditorRow(
                        title: "Known Host",
                        value: "Reset"
                    )
                }
                .buttonStyle(.plain)
                .disabled(profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func toggleAdvanced() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isShowingAdvanced.toggle()
        }
    }
}
