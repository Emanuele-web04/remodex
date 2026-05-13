// FILE: SecureStore.swift
// Purpose: Small Keychain wrapper for sensitive app settings.
// Layer: Service
// Exports: SecureStore, CodexSecureKeys
// Depends on: Security

import Foundation
import Security

enum CodexSecureKeys {
    nonisolated static let relaySessionId = "codex.relay.sessionId"
    nonisolated static let relayUrl = "codex.relay.url"
    nonisolated static let relayMacDeviceId = "codex.relay.macDeviceId"
    nonisolated static let relayMacIdentityPublicKey = "codex.relay.macIdentityPublicKey"
    nonisolated static let relayProtocolVersion = "codex.relay.protocolVersion"
    nonisolated static let relayLastAppliedBridgeOutboundSeq = "codex.relay.lastAppliedBridgeOutboundSeq"
    nonisolated static let pushDeviceToken = "codex.push.deviceToken"
    nonisolated static let trustedMacRegistry = "codex.secure.trustedMacRegistry"
    nonisolated static let lastTrustedMacDeviceId = "codex.secure.lastTrustedMacDeviceId"
    nonisolated static let phoneIdentityState = "codex.secure.phoneIdentityState"
    nonisolated static let messageHistoryKey = "codex.local.messageHistoryKey"
    nonisolated static let terminalSSHProfile = "codex.terminal.sshProfile"
    nonisolated static let terminalSSHPrivateKey = "codex.terminal.sshPrivateKey"
    nonisolated static let terminalSSHPrivateKeyPassphrase = "codex.terminal.sshPrivateKeyPassphrase"
    nonisolated static let terminalSSHKnownHostPrefix = "codex.terminal.sshKnownHost"
}

enum SecureStore {
    // Reads a UTF-8 string value from Keychain.
    nonisolated static func readString(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let stringValue = String(data: data, encoding: .utf8) else {
            return nil
        }

        return stringValue
    }

    // Reads opaque key material or encrypted payload blobs from Keychain.
    nonisolated static func readData(for key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return data
    }

    // Writes a UTF-8 string to Keychain; empty values are treated as delete.
    nonisolated static func writeString(_ value: String, for key: String) {
        writeString(value, for: key, accessibility: nil)
    }

    // Writes sensitive strings with optional Keychain accessibility constraints.
    nonisolated static func writeString(_ value: String, for key: String, accessibility: CFString?) {
        if value.isEmpty {
            deleteValue(for: key)
            return
        }

        writeData(Data(value.utf8), for: key, accessibility: accessibility)
    }

    // Stores raw data in Keychain; used by local message-history encryption keys.
    nonisolated static func writeData(_ value: Data, for key: String) {
        writeData(value, for: key, accessibility: nil)
    }

    // Stores raw data in Keychain with optional accessibility constraints for key material.
    nonisolated static func writeData(_ value: Data, for key: String, accessibility: CFString?) {
        if value.isEmpty {
            deleteValue(for: key)
            return
        }

        deleteValue(for: key)

        var query = baseQuery(for: key)
        query[kSecValueData as String] = value
        if let accessibility {
            query[kSecAttrAccessible as String] = accessibility
        }

        SecItemAdd(query as CFDictionary, nil)
    }

    // Convenience wrapper for small Codable payloads kept in Keychain.
    nonisolated static func readCodable<Value: Decodable>(_ type: Value.Type, for key: String) -> Value? {
        guard let data = readData(for: key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    // Convenience wrapper for small Codable payloads kept in Keychain.
    nonisolated static func writeCodable<Value: Encodable>(_ value: Value, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        writeData(data, for: key)
    }

    nonisolated static func deleteValue(for key: String) {
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
    }

    private nonisolated static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
    }

    private nonisolated static var serviceName: String {
        Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
    }
}
