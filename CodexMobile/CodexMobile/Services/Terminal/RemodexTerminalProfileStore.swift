// FILE: RemodexTerminalProfileStore.swift
// Purpose: Persists the SSH terminal profile in Keychain-backed app storage.
// Layer: Service
// Exports: RemodexTerminalProfileStore
// Depends on: SecureStore, RemodexTerminalProfile

import Foundation

enum RemodexTerminalProfileStore {
    // Keeps host/key-path configuration with the same Keychain protection as pairing metadata.
    static func load() -> RemodexTerminalProfile {
        SecureStore.readCodable(RemodexTerminalProfile.self, for: CodexSecureKeys.terminalSSHProfile)
            ?? .empty
    }

    static func save(_ profile: RemodexTerminalProfile) {
        SecureStore.writeCodable(profile.normalizedForSave, for: CodexSecureKeys.terminalSSHProfile)
    }
}
