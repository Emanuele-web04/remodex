// FILE: AIChangeSetPersistence.swift
// Purpose: Persists assistant-scoped revertable change sets between app launches.
// Layer: Service
// Exports: AIChangeSetPersistence
// Depends on: Foundation, CryptoKit, AIChangeSetModels, CodexLocalPersistenceKeyProvider

import CryptoKit
import Foundation

nonisolated struct AIChangeSetPersistence {
    // Keep the original path so migration can replace the plaintext ledger atomically.
    private let fileName = "codex-ai-change-sets-v1.json"
    private let encryptedHeader = Data("RMDX-AI-CHANGE-SETS-V2\n".utf8)

    // A missing ledger is empty. An unreadable ledger must not be overwritten with an empty one.
    func load(macDeviceId: String? = nil, includeLegacyFallback: Bool = false) -> [AIChangeSet]? {
        let decoder = JSONDecoder()
        for fileURL in storeURLs(macDeviceId: macDeviceId, includeLegacyFallback: includeLegacyFallback) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                return nil
            }

            if data.starts(with: encryptedHeader) {
                guard let key = CodexLocalPersistenceKeyProvider.durableHistoryKey(),
                      let sealed = try? AES.GCM.SealedBox(combined: data.dropFirst(encryptedHeader.count)),
                      let plaintext = try? AES.GCM.open(sealed, using: key) else {
                    return nil
                }
                return try? decoder.decode([AIChangeSet].self, from: plaintext)
            }

            guard let decoded = try? decoder.decode([AIChangeSet].self, from: data) else {
                return nil
            }
            // A temporarily unavailable key or failed write leaves the old ledger intact.
            writeEncrypted(data, to: fileURL)
            return decoded
        }
        return []
    }

    @discardableResult
    func save(_ value: [AIChangeSet], macDeviceId: String? = nil) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else {
            return false
        }
        return writeEncrypted(data, to: storeURL(macDeviceId: macDeviceId))
    }

    @discardableResult
    private func writeEncrypted(_ data: Data, to fileURL: URL) -> Bool {
        guard let key = CodexLocalPersistenceKeyProvider.durableHistoryKey(),
              let sealed = try? AES.GCM.seal(data, using: key),
              let combined = sealed.combined else {
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (encryptedHeader + combined).write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    // Removes the scoped change-set cache after a rotated device id has been merged elsewhere.
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
        guard normalizedMacDeviceId(macDeviceId) != nil else {
            return [scopedURL]
        }

        guard includeLegacyFallback else {
            return [scopedURL]
        }

        let legacyURL = rootDirectory.appendingPathComponent(fileName, isDirectory: false)
        return [scopedURL, legacyURL]
    }

    private func normalizedMacDeviceId(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
