// FILE: SecureStore.swift
// Purpose: Small Keychain wrapper for sensitive app settings.
// Layer: Service
// Exports: SecureStore, CodexSecureKeys
// Depends on: Security

import Foundation
import Security

enum CodexSecureKeys {
    static let relaySessionId = "codex.relay.sessionId"
    static let relayUrl = "codex.relay.url"
    static let relayMacDeviceId = "codex.relay.macDeviceId"
    static let relayMacIdentityPublicKey = "codex.relay.macIdentityPublicKey"
    static let relayProtocolVersion = "codex.relay.protocolVersion"
    static let relayLastAppliedBridgeOutboundSeq = "codex.relay.lastAppliedBridgeOutboundSeq"
    static let pushDeviceToken = "codex.push.deviceToken"
    static let trustedMacRegistry = "codex.secure.trustedMacRegistry"
    static let lastTrustedMacDeviceId = "codex.secure.lastTrustedMacDeviceId"
    static let phoneIdentityState = "codex.secure.phoneIdentityState"
    static let messageHistoryKey = "codex.local.messageHistoryKey"
}

enum SecureStore {
    // Reads a UTF-8 string value from Keychain.
    static func readString(for key: String) -> String? {
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
    static func readData(for key: String) -> Data? {
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
    static func writeString(_ value: String, for key: String) {
        if value.isEmpty {
            deleteValue(for: key)
            return
        }

        writeData(Data(value.utf8), for: key)
    }

    // Stores raw data in Keychain; used by local message-history encryption keys.
    static func writeData(_ value: Data, for key: String) {
        if value.isEmpty {
            deleteValue(for: key)
            return
        }

        deleteValue(for: key)

        var query = baseQuery(for: key)
        query[kSecValueData as String] = value

        SecItemAdd(query as CFDictionary, nil)
    }

    // Convenience wrapper for small Codable payloads kept in Keychain.
    static func readCodable<Value: Decodable>(_ type: Value.Type, for key: String) -> Value? {
        guard let data = readData(for: key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    // Convenience wrapper for small Codable payloads kept in Keychain.
    static func writeCodable<Value: Encodable>(_ value: Value, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        writeData(data, for: key)
    }

    static func deleteValue(for key: String) {
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
    }

    private static var serviceName: String {
        Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
    }
}
