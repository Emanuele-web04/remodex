// FILE: AIChangeSetPersistence.swift
// Purpose: Persists assistant-scoped revertable change sets between app launches.
// Layer: Service
// Exports: AIChangeSetPersistence
// Depends on: Foundation, AIChangeSetModels

import Foundation

nonisolated struct AIChangeSetPersistence {
    private let fileName = "codex-ai-change-sets-v1.json"

    // Loads the stored change-set ledger from disk. Returns an empty array on failure.
    func load(macDeviceId: String? = nil, includeLegacyFallback: Bool = false) -> [AIChangeSet] {
        let decoder = JSONDecoder()
        for fileURL in storeURLs(macDeviceId: macDeviceId, includeLegacyFallback: includeLegacyFallback) {
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }

            if let decoded = try? decoder.decode([AIChangeSet].self, from: data) {
                return decoded
            }
        }

        return []
    }

    // Persists the full change-set ledger atomically to keep revert metadata durable.
    func save(_ value: [AIChangeSet], macDeviceId: String? = nil) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else {
            return
        }

        let fileURL = storeURL(macDeviceId: macDeviceId)
        ensureParentDirectoryExists(for: fileURL)
        try? data.write(to: fileURL, options: [.atomic])
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

    private func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func normalizedMacDeviceId(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
