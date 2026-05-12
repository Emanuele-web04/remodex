// FILE: RemodexSSHKnownHostStore.swift
// Purpose: Persists SSH host keys for trust-on-first-use validation.
// Layer: Service
// Exports: RemodexSSHKnownHostStore
// Depends on: Foundation, SecureStore

import Foundation

enum RemodexSSHKnownHostStore {
    nonisolated static func load(host: String, port: Int) -> String? {
        SecureStore.readString(for: storageKey(host: host, port: port))
    }

    nonisolated static func save(_ hostKey: String, host: String, port: Int) {
        SecureStore.writeString(hostKey, for: storageKey(host: host, port: port))
    }

    nonisolated static func delete(host: String, port: Int) {
        SecureStore.deleteValue(for: storageKey(host: host, port: port))
    }

    private nonisolated static func storageKey(host: String, port: Int) -> String {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(CodexSecureKeys.terminalSSHKnownHostPrefix).\(normalizedHost):\(port)"
    }
}
