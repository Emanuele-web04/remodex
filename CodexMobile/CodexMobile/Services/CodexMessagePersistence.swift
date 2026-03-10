// FILE: CodexMessagePersistence.swift
// Purpose: Persists per-thread message timelines to disk between app launches.
// Layer: Service
// Exports: CodexMessagePersistence
// Depends on: Foundation, CryptoKit, CodexMessage

import CryptoKit
import Foundation

struct CodexMessagePersistence {
    // v6 encrypts the on-device message cache while keeping backward-compatible legacy fallbacks.
    private let fileName = "codex-message-history-v6.bin"
    private let legacyFileNames = [
        "codex-message-history-v5.json",
        "codex-message-history-v4.json",
        "codex-message-history-v3.json",
        "codex-message-history-v2.json",
        "codex-message-history.json",
    ]

    // Loads the saved message map from disk. Returns an empty store on failure.
    func load() -> [String: [CodexMessage]] {
        let decoder = JSONDecoder()

        for fileURL in storeURLs {
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
    func save(_ value: [String: [CodexMessage]]) {
        let encoder = JSONEncoder()
        guard let plaintext = try? encoder.encode(sanitizedForPersistence(value)),
              let data = encryptPersistedPayload(plaintext) else {
            return
        }

        let fileURL = storeURL
        ensureParentDirectoryExists(for: fileURL)
        try? data.write(to: fileURL, options: [.atomic])
    }

    private var storeURL: URL {
        storeURLs[0]
    }

    private var storeURLs: [URL] {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        let directory = base.appendingPathComponent(bundleID, isDirectory: true)
        let names = [fileName] + legacyFileNames
        return names.map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    private func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Uses a Keychain-backed AES key so chat history remains private if the app data is copied out.
    private func encryptPersistedPayload(_ plaintext: Data) -> Data? {
        let key = messageHistoryKey()
        let sealedBox = try? AES.GCM.seal(plaintext, using: key)
        return sealedBox?.combined
    }

    // Opens the encrypted chat cache while still allowing plaintext fallbacks from older app versions.
    private func decryptPersistedPayload(_ encryptedData: Data) -> Data? {
        let key = messageHistoryKey()
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedData) else {
            return nil
        }
        return try? AES.GCM.open(sealedBox, using: key)
    }

    private func messageHistoryKey() -> SymmetricKey {
        if let storedKey = SecureStore.readData(for: CodexSecureKeys.messageHistoryKey) {
            return SymmetricKey(data: storedKey)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        SecureStore.writeData(keyData, for: CodexSecureKeys.messageHistoryKey)
        return newKey
    }

    // Structured input cards are live request state, not durable history; dropping them
    // here prevents stale prompts from resurfacing after reconnects or relaunches.
    private func sanitizedForPersistence(_ value: [String: [CodexMessage]]) -> [String: [CodexMessage]] {
        value.mapValues { messages in
            messages.filter { $0.kind != .userInputPrompt }
        }
    }
}
