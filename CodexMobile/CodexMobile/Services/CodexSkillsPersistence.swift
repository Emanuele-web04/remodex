// FILE: CodexSkillsPersistence.swift
// Purpose: Persists cached skills metadata between launches.
// Layer: Service
// Exports: CodexSkillsCacheEntry, CodexSkillsCacheSnapshot, CodexSkillsPersistence
// Depends on: Foundation, CodexSkillMetadata

import Foundation

nonisolated struct CodexSkillsCacheEntry: Codable, Equatable, Sendable {
    var skills: [CodexSkillMetadata]
    var savedAt: Date
    var serverIdentity: String?
    var relayMacDeviceId: String?
    var isUnsupported: Bool
}

nonisolated struct CodexSkillsCacheSnapshot: Codable, Equatable, Sendable {
    var entriesByRoot: [String: CodexSkillsCacheEntry]
}

nonisolated struct CodexSkillsPersistence {
    private let fileName = "codex-skills-cache-v1.json"
    private let namespace: String

    nonisolated init(namespace: String = "default") {
        self.namespace = namespace
    }

    nonisolated func load() -> CodexSkillsCacheSnapshot? {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: storeURL) else {
            return nil
        }

        return try? decoder.decode(CodexSkillsCacheSnapshot.self, from: data)
    }

    nonisolated func save(_ snapshot: CodexSkillsCacheSnapshot) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot) else {
            return
        }

        ensureParentDirectoryExists(for: storeURL)
        try? data.write(to: storeURL, options: [.atomic])
    }

    private nonisolated var storeURL: URL {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        return baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private nonisolated func ensureParentDirectoryExists(for fileURL: URL) {
        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
