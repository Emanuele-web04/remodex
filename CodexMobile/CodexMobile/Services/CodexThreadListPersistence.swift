// FILE: CodexThreadListPersistence.swift
// Purpose: Persists the local thread list snapshot between app launches.
// Layer: Service
// Exports: CodexThreadListSnapshot, CodexThreadListPersistence
// Depends on: Foundation, CodexThread

import Foundation

nonisolated struct CodexThreadListSnapshot: Codable, Equatable, Sendable {
    var threads: [CodexThread]
    var lastActiveThreadId: String?
    var savedAt: Date
    var serverIdentity: String?
    var relayMacDeviceId: String?
}

nonisolated struct CodexThreadListPersistence {
    private let fileName = "codex-thread-list-v1.json"
    private let namespace: String

    nonisolated init(namespace: String = "default") {
        self.namespace = namespace
    }

    // Loads the stored thread list snapshot from disk. Returns nil on failure.
    nonisolated func load() -> CodexThreadListSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storeURL) else {
            return nil
        }

        if let snapshot = try? decoder.decode(CodexThreadListSnapshot.self, from: data) {
            return snapshot
        }

        return try? JSONDecoder().decode(CodexThreadListSnapshot.self, from: data)
    }

    // Persists the thread list snapshot atomically to avoid partial writes.
    nonisolated func save(_ snapshot: CodexThreadListSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else {
            return
        }

        ensureParentDirectoryExists(for: storeURL)
        try? data.write(to: storeURL, options: [.atomic])
    }

    nonisolated func clear() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private nonisolated var storeURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.codexmobile.app"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private nonisolated func ensureParentDirectoryExists(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
