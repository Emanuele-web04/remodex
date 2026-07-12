// FILE: CodexThreadListPersistence.swift
// Purpose: Persists a small encrypted per-Mac sidebar snapshot for instant cold-start rendering.
// Layer: Service Persistence
// Exports: CodexThreadListPersistence
// Depends on: Foundation, CryptoKit, SecureStore, CodexThread

import CryptoKit
import Foundation

nonisolated struct CodexThreadListPersistence {
    private let fileName = "codex-thread-list-v1.bin"

    func load(macDeviceId: String? = nil, includeLegacyFallback: Bool = false) -> [CodexThread] {
        for fileURL in storeURLs(macDeviceId: macDeviceId, includeLegacyFallback: includeLegacyFallback) {
            guard let data = try? Data(contentsOf: fileURL),
                  let decrypted = decrypt(data),
                  let value = try? JSONDecoder().decode([CodexThread].self, from: decrypted) else {
                continue
            }
            return deduplicated(value)
        }
        return []
    }

    func save(_ value: [CodexThread], macDeviceId: String? = nil) {
        let fileURL = storeURL(macDeviceId: macDeviceId)
        guard !value.isEmpty else {
            delete(macDeviceId: macDeviceId)
            return
        }
        let encoder = JSONEncoder()
        // CodexThread's tolerant decoder treats numeric dates as Unix time.
        // Use milliseconds explicitly instead of Foundation's 2001 reference
        // epoch so cached ordering survives an encode/decode round trip.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let plaintext = try? encoder.encode(value),
              let encrypted = encrypt(plaintext) else {
            return
        }
        ensureParentDirectoryExists(for: fileURL)
        try? encrypted.write(to: fileURL, options: [.atomic])
    }

    func delete(macDeviceId: String?) {
        for fileURL in storeURLs(macDeviceId: macDeviceId) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func storeURL(macDeviceId: String?) -> URL {
        storeURLs(macDeviceId: macDeviceId)[0]
    }

    private func storeURLs(macDeviceId: String?, includeLegacyFallback: Bool = false) -> [URL] {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
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
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func encrypt(_ plaintext: Data) -> Data? {
        try? AES.GCM.seal(
            plaintext,
            using: CodexLocalPersistenceKeyProvider.historyKey()
        ).combined
    }

    private func decrypt(_ encrypted: Data) -> Data? {
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encrypted) else {
            return nil
        }
        return try? AES.GCM.open(
            sealedBox,
            using: CodexLocalPersistenceKeyProvider.historyKey()
        )
    }

    private func deduplicated(_ threads: [CodexThread]) -> [CodexThread] {
        var seenThreadIDs: Set<String> = []
        return threads.filter { seenThreadIDs.insert($0.id).inserted }
    }

    private func normalizedMacDeviceId(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
