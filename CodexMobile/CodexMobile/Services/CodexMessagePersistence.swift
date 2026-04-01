// FILE: CodexMessagePersistence.swift
// Purpose: Persists per-thread message timelines to disk between app launches.
// Layer: Service
// Exports: CodexMessagePersistence
// Depends on: Foundation, CryptoKit, CodexMessage

import CryptoKit
import Foundation

nonisolated struct CodexMessagePersistence {
    // Serializes load/save and key material access. Detached `persistMessages` tasks can otherwise
    // race with the next `CodexService` init on the main actor and corrupt CryptoKit / malloc state.
    nonisolated(unsafe) private static let gate = NSLock()

    // v6 encrypts the on-device message cache while keeping backward-compatible legacy fallbacks.
    private let namespace: String
    private let fileName = "codex-message-history-v6.bin"
    private let legacyFileNames = [
        "codex-message-history-v5.json",
        "codex-message-history-v4.json",
        "codex-message-history-v3.json",
        "codex-message-history-v2.json",
        "codex-message-history.json",
    ]

    nonisolated init(namespace: String) {
        self.namespace = namespace
    }

    private nonisolated var bundleSupportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    private nonisolated var namespacedDirectory: URL {
        bundleSupportDirectory.appendingPathComponent(namespace, isDirectory: true)
    }

    /// Reads namespaced files first, then pre-namespace flat files under the bundle directory (one-time migration).
    private nonisolated var loadCandidateURLs: [URL] {
        let names = [fileName] + legacyFileNames
        let namespaced = names.map { namespacedDirectory.appendingPathComponent($0, isDirectory: false) }
        let legacyFlat = names.map { bundleSupportDirectory.appendingPathComponent($0, isDirectory: false) }
        return namespaced + legacyFlat
    }

    private nonisolated var primaryStoreURL: URL {
        namespacedDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    // Loads the saved message map from disk. Returns an empty store on failure.
    nonisolated func load() -> [String: [CodexMessage]] {
        Self.gate.lock()
        defer { Self.gate.unlock() }

        let decoder = JSONDecoder()

        for fileURL in loadCandidateURLs {
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }

            if fileURL.lastPathComponent == fileName,
               let decrypted = decryptPersistedPayload(data),
               let value = try? decoder.decode([String: [CodexMessage]].self, from: decrypted) {
                return sanitizedForPersistence(value)
            }

            if let value = try? decoder.decode([String: [CodexMessage]].self, from: data) {
                return sanitizedForPersistence(value)
            }
        }

        return [:]
    }

    // Persists all thread timelines atomically to avoid corrupt partial writes.
    nonisolated func save(_ value: [String: [CodexMessage]]) {
        Self.gate.lock()
        defer { Self.gate.unlock() }

        let encoder = JSONEncoder()
        guard let plaintext = try? encoder.encode(sanitizedForPersistence(value)),
              let data = encryptPersistedPayload(plaintext) else {
            return
        }

        let fileURL = primaryStoreURL
        ensureParentDirectoryExists(for: fileURL)
        try? data.write(to: fileURL, options: [.atomic])
    }

    private nonisolated func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Uses a Keychain-backed AES key so chat history remains private if the app data is copied out.
    private nonisolated func encryptPersistedPayload(_ plaintext: Data) -> Data? {
        let key = messageHistoryKey()
        let sealedBox = try? AES.GCM.seal(plaintext, using: key)
        return sealedBox?.combined
    }

    // Opens the encrypted chat cache while still allowing plaintext fallbacks from older app versions.
    private nonisolated func decryptPersistedPayload(_ encryptedData: Data) -> Data? {
        let key = messageHistoryKey()
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedData) else {
            return nil
        }
        return try? AES.GCM.open(sealedBox, using: key)
    }

    private nonisolated func messageHistoryKey() -> SymmetricKey {
        // Caller must hold `gate` (load/save already do).
        if let storedKey = SecureStore.readData(for: CodexSecureKeys.messageHistoryKey) {
            return SymmetricKey(data: storedKey)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { rawBuffer in
            Data(rawBuffer)
        }
        SecureStore.writeData(keyData, for: CodexSecureKeys.messageHistoryKey)
        return newKey
    }

    // Keep pending structured prompts on disk so reconnects and relaunches can still surface
    // a request the server is waiting on; lifecycle cleanup removes them once the request resolves.
    private func sanitizedForPersistence(_ value: [String: [CodexMessage]]) -> [String: [CodexMessage]] {
        value
    }
}
