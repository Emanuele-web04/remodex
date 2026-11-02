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

    // Use this for migrations that must not overwrite existing data with an ephemeral key.
    static func durableHistoryKey() -> SymmetricKey? {
        storage.durableHistoryKey()
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedHistoryKey: SymmetricKey?
        private var cachedDurableHistoryKey: SymmetricKey?

        func historyKey() -> SymmetricKey {
            lock.lock()
            defer { lock.unlock() }

            if let cachedHistoryKey {
                return cachedHistoryKey
            }
            let key = loadDurableHistoryKey() ?? SymmetricKey(size: .bits256)
            cachedHistoryKey = key
            return key
        }

        func durableHistoryKey() -> SymmetricKey? {
            lock.lock()
            defer { lock.unlock() }
            return loadDurableHistoryKey()
        }

        private func loadDurableHistoryKey() -> SymmetricKey? {
            if let cachedDurableHistoryKey {
                return cachedDurableHistoryKey
            }

            let keyName = CodexSecureKeys.messageHistoryKey
            var keyData = SecureStore.readData(for: keyName)
            if keyData == nil {
                let candidate = cachedHistoryKey ?? SymmetricKey(size: .bits256)
                SecureStore.addDataIfAbsent(candidate.withUnsafeBytes { Data($0) }, for: keyName)
                keyData = SecureStore.readData(for: keyName)
            }

            guard let storedKey = keyData, storedKey.count == 32 else {
                return nil
            }
            let key = SymmetricKey(data: storedKey)
            cachedDurableHistoryKey = key
            return key
        }
    }
}
