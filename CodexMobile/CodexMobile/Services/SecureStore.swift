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

    // Writes a UTF-8 string to Keychain; empty values are treated as delete.
    static func writeString(_ value: String, for key: String) {
        if value.isEmpty {
            deleteValue(for: key)
            return
        }

        deleteValue(for: key)

        var query = baseQuery(for: key)
        query[kSecValueData as String] = Data(value.utf8)

        SecItemAdd(query as CFDictionary, nil)
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
