// FILE: CodexMessagePersistence.swift
// Purpose: Persists per-thread message timelines to disk between app launches.
// Layer: Service
// Exports: CodexMessagePersistence
// Depends on: Foundation, CodexMessage

import Foundation

struct CodexMessagePersistence {
    // v5 introduces persisted user image attachments with backward-compatible defaults.
    private let fileName = "codex-message-history-v5.json"
    private let legacyFileNames = [
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

            if let value = try? decoder.decode([String: [CodexMessage]].self, from: data) {
                return sanitizedForPersistence(value)
            }
        }

        return [:]
    }

    // Persists all thread timelines atomically to avoid corrupt partial writes.
    func save(_ value: [String: [CodexMessage]]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(sanitizedForPersistence(value)) else {
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

    // Structured input cards are live request state, not durable history; dropping them
    // here prevents stale prompts from resurfacing after reconnects or relaunches.
    private func sanitizedForPersistence(_ value: [String: [CodexMessage]]) -> [String: [CodexMessage]] {
        value.mapValues { messages in
            messages.filter { $0.kind != .userInputPrompt }
        }
    }
}
