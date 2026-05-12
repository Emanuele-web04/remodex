// FILE: RemodexTerminalPrivateKeyStore.swift
// Purpose: Stores the phone-side SSH private key material used by the native terminal.
// Layer: Service
// Exports: RemodexTerminalPrivateKeyStore
// Depends on: Foundation, SecureStore

import Foundation
import Security

enum RemodexTerminalPrivateKeyStore {
    static func loadPrivateKey() -> String {
        SecureStore.readString(for: CodexSecureKeys.terminalSSHPrivateKey) ?? ""
    }

    static func savePrivateKey(_ value: String) {
        SecureStore.writeString(
            normalizedPrivateKey(value),
            for: CodexSecureKeys.terminalSSHPrivateKey,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    static func loadPassphrase() -> String {
        SecureStore.readString(for: CodexSecureKeys.terminalSSHPrivateKeyPassphrase) ?? ""
    }

    static func savePassphrase(_ value: String) {
        SecureStore.writeString(
            value,
            for: CodexSecureKeys.terminalSSHPrivateKeyPassphrase,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    static func hasPrivateKey(_ value: String? = nil) -> Bool {
        let key = normalizedPrivateKey(value ?? loadPrivateKey())
        return key.contains("PRIVATE KEY")
    }

    private static func normalizedPrivateKey(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
