// FILE: CodexMessagePersistence.swift
// Purpose: Persists per-thread message timelines to disk between app launches.
// Layer: Service
// Exports: CodexMessagePersistence
// Depends on: Foundation, CryptoKit, CodexMessage

import CryptoKit
import Foundation

nonisolated struct CodexMessagePersistence {
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
    func load(macDeviceId: String? = nil, includeLegacyFallback: Bool = false) -> [String: [CodexMessage]] {
        let decoder = JSONDecoder()

        for fileURL in storeURLs(macDeviceId: macDeviceId, includeLegacyFallback: includeLegacyFallback) {
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
    func save(_ value: [String: [CodexMessage]], macDeviceId: String? = nil) {
        let encoder = JSONEncoder()
        guard let plaintext = try? encoder.encode(sanitizedForPersistence(value)),
              let data = encryptPersistedPayload(plaintext) else {
            return
        }

        let fileURL = storeURL(macDeviceId: macDeviceId)
        ensureParentDirectoryExists(for: fileURL)
        try? data.write(to: fileURL, options: [.atomic])
    }

    // Removes the scoped timeline cache after a rotated device id has been merged elsewhere.
    func delete(macDeviceId: String?) {
        for fileURL in storeURLs(macDeviceId: macDeviceId) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func storeURL(macDeviceId: String?) -> URL {
        storeURLs(macDeviceId: macDeviceId)[0]
    }

    private func storeURLs(macDeviceId: String?, includeLegacyFallback: Bool = false) -> [URL] {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        let directory = messageHistoryDirectory(base: base, bundleID: bundleID, macDeviceId: macDeviceId)
        let names = [fileName] + legacyFileNames
        let scopedStoreURLs = names.map { directory.appendingPathComponent($0, isDirectory: false) }

        guard normalizedMacDeviceId(macDeviceId) != nil else {
            return scopedStoreURLs
        }

        guard includeLegacyFallback else {
            return scopedStoreURLs
        }

        let legacyDirectory = base.appendingPathComponent(bundleID, isDirectory: true)
        let legacyStoreURLs = names.map { legacyDirectory.appendingPathComponent($0, isDirectory: false) }
        return scopedStoreURLs + legacyStoreURLs
    }

    private func messageHistoryDirectory(base: URL, bundleID: String, macDeviceId: String?) -> URL {
        let rootDirectory = base.appendingPathComponent(bundleID, isDirectory: true)
        guard let normalizedMacDeviceId = normalizedMacDeviceId(macDeviceId) else {
            return rootDirectory
        }

        return rootDirectory
            .appendingPathComponent("mac", isDirectory: true)
            .appendingPathComponent(normalizedMacDeviceId, isDirectory: true)
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

    // Keep pending structured prompts on disk so reconnects and relaunches can still surface
    // a request the server is waiting on; lifecycle cleanup removes them once the request resolves.
    private func sanitizedForPersistence(_ value: [String: [CodexMessage]]) -> [String: [CodexMessage]] {
        value.mapValues { messages in
            messages.map { message in
                guard !message.attachments.isEmpty else {
                    return message
                }

                var sanitizedMessage = message
                let shouldPreservePayloadDataURL = message.deliveryState == .pending
                sanitizedMessage.attachments = message.attachments.map {
                    $0.sanitizedForStorage(preservingPayloadDataURL: shouldPreservePayloadDataURL)
                }
                return sanitizedMessage
            }
        }
    }

    private func normalizedMacDeviceId(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
