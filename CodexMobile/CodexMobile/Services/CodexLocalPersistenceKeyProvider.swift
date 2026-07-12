// FILE: CodexLocalPersistenceKeyProvider.swift
// Purpose: Provides one process-cached Keychain key for encrypted local app data.
// Layer: Service Persistence
// Exports: CodexLocalPersistenceKeyProvider
// Depends on: CryptoKit, Foundation, SecureStore

import CryptoKit
import Foundation

nonisolated enum CodexLocalPersistenceKeyProvider {
    private static let storage = Storage()

    static func historyKey() -> SymmetricKey {
        storage.historyKey()
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedHistoryKey: SymmetricKey?

        func historyKey() -> SymmetricKey {
            lock.lock()
            defer { lock.unlock() }

            if let cachedHistoryKey {
                return cachedHistoryKey
            }
            if let storedKey = SecureStore.readData(for: CodexSecureKeys.messageHistoryKey) {
                let key = SymmetricKey(data: storedKey)
                cachedHistoryKey = key
                return key
            }

            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            SecureStore.writeData(keyData, for: CodexSecureKeys.messageHistoryKey)
            cachedHistoryKey = key
            return key
        }
    }
}
