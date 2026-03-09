// FILE: AIChangeSetPersistence.swift
// Purpose: Persists assistant-scoped revertable change sets between app launches.
// Layer: Service
// Exports: AIChangeSetPersistence
// Depends on: Foundation, AIChangeSetModels

import Foundation

struct AIChangeSetPersistence {
    private let fileName = "codex-ai-change-sets-v1.json"

    // Loads the stored change-set ledger from disk. Returns an empty array on failure.
    func load() -> [AIChangeSet] {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: storeURL) else {
            return []
        }

        return (try? decoder.decode([AIChangeSet].self, from: data)) ?? []
    }

    // Persists the full change-set ledger atomically to keep revert metadata durable.
    func save(_ value: [AIChangeSet]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else {
            return
        }

        ensureParentDirectoryExists(for: storeURL)
        try? data.write(to: storeURL, options: [.atomic])
    }

    private var storeURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
