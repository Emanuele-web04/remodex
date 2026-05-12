// FILE: TerminalConnectionEditorFields.swift
// Purpose: Reusable form rows and inputs for the SSH connection editor sheet.
// Layer: View Component
// Exports: TerminalEditorSection, TerminalConnectionStringField, TerminalTextField
// Depends on: SwiftUI, UIKit, RemodexTerminalPrivateKeyStore

import SwiftUI
import UIKit

struct TerminalEditorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
            content
        }
    }
}

struct TerminalConnectionStringField: View {
    @Binding var connection: String

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Text("ssh")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)

            TextField("user@hostname", text: $connection)
                .font(.system(size: 15, weight: .medium))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct TerminalRoundedTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 15, weight: .medium))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .padding(.horizontal, 22)
            .frame(height: 64)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct TerminalEditorRow: View {
    let title: String
    let value: String
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 46)
    }
}

struct TerminalPrivateKeyEditor: View {
    @Binding var privateKey: String
    @Binding var passphrase: String
    @State private var isShowingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Private key")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(isShowingKey ? "Hide" : "Paste/Edit", action: toggleKeyVisibility)
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
            }

            if isShowingKey || !RemodexTerminalPrivateKeyStore.hasPrivateKey(privateKey) {
                TextEditor(text: $privateKey)
                    .font(.system(size: 11, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 124)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            } else {
                TerminalPrivateKeySavedRow()
            }

            SecureField("Passphrase (optional)", text: $passphrase)
                .font(.system(size: 11, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func toggleKeyVisibility() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            isShowingKey.toggle()
        }
    }
}

private struct TerminalPrivateKeySavedRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Private key saved")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TerminalTextField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder.isEmpty ? title : placeholder, text: $text)
                .font(.system(size: 11, design: .monospaced))
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
