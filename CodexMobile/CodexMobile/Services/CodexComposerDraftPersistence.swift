// FILE: CodexComposerDraftPersistence.swift
// Purpose: Persists unsent per-thread composer drafts, including local image payloads.
// Layer: Service Persistence
// Exports: CodexComposerDraftPersistence
// Depends on: Foundation, CryptoKit, SecureStore, TurnComposerLocalDraft

import CryptoKit
import Foundation

nonisolated struct CodexComposerDraftPersistence {
    private let fileName = "codex-composer-drafts-v1.bin"

    // Loads locally saved composer drafts. Corrupt or undecryptable stores safely fall back to empty.
    func load(macDeviceId: String? = nil, includeLegacyFallback: Bool = false) -> [String: TurnComposerLocalDraft] {
        for fileURL in storeURLs(macDeviceId: macDeviceId, includeLegacyFallback: includeLegacyFallback) {
            guard let data = try? Data(contentsOf: fileURL),
                  let decrypted = decryptPersistedPayload(data),
                  let value = try? JSONDecoder().decode([String: TurnComposerLocalDraft].self, from: decrypted) else {
                continue
            }

            return value.filter { !$0.value.isEmpty }
        }

        return [:]
    }

    // Saves the current non-empty draft map atomically.
    func save(_ value: [String: TurnComposerLocalDraft], macDeviceId: String? = nil) {
        let sanitized = value.filter { !$0.value.isEmpty }
        let fileURL = storeURL(macDeviceId: macDeviceId)
        guard !sanitized.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        guard let plaintext = try? JSONEncoder().encode(sanitized),
              let data = encryptPersistedPayload(plaintext) else {
            return
        }

        ensureParentDirectoryExists(for: fileURL)
        try? data.write(to: fileURL, options: [.atomic])
    }

    // Removes the scoped draft cache after a rotated device id has been merged elsewhere.
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
        let rootDirectory = base.appendingPathComponent(bundleID, isDirectory: true)
        let scopedDirectory: URL
        if let normalizedMacDeviceId = normalizedMacDeviceId(macDeviceId) {
            scopedDirectory = rootDirectory
                .appendingPathComponent("mac", isDirectory: true)
                .appendingPathComponent(normalizedMacDeviceId, isDirectory: true)
        } else {
            scopedDirectory = rootDirectory
        }

        let scopedURL = scopedDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard normalizedMacDeviceId(macDeviceId) != nil, includeLegacyFallback else {
            return [scopedURL]
        }

        return [scopedURL, rootDirectory.appendingPathComponent(fileName, isDirectory: false)]
    }

    private func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func encryptPersistedPayload(_ plaintext: Data) -> Data? {
        let key = localHistoryKey()
        let sealedBox = try? AES.GCM.seal(plaintext, using: key)
        return sealedBox?.combined
    }

    private func decryptPersistedPayload(_ encryptedData: Data) -> Data? {
        let key = localHistoryKey()
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedData) else {
            return nil
        }
        return try? AES.GCM.open(sealedBox, using: key)
    }

    private func localHistoryKey() -> SymmetricKey {
        if let storedKey = SecureStore.readData(for: CodexSecureKeys.messageHistoryKey) {
            return SymmetricKey(data: storedKey)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        SecureStore.writeData(keyData, for: CodexSecureKeys.messageHistoryKey)
        return newKey
    }

    private func normalizedMacDeviceId(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
