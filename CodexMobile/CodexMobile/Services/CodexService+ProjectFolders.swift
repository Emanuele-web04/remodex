// FILE: CodexService+ProjectFolders.swift
// Purpose: Mac-local project folder browsing RPCs used by the sidebar new-chat flow.
// Layer: Service Extension
// Exports: CodexProjectLocation, CodexProjectDirectoryEntry, CodexProjectDirectoryListing, CodexService project folder APIs
// Depends on: Foundation, JSONValue, RPC transport

import Foundation

struct CodexProjectLocation: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let path: String
}

struct CodexProjectDirectoryEntry: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isSymlink: Bool
}

struct CodexProjectDirectoryListing: Equatable, Sendable {
    let path: String
    let parentPath: String?
    let entries: [CodexProjectDirectoryEntry]
}

extension CodexService {
    // Loads Mac-local shortcut folders through the bridge instead of the Codex runtime.
    func fetchProjectQuickLocations() async throws -> [CodexProjectLocation] {
        let response = try await sendRequest(method: "project/quickLocations", params: .object([:]))
        guard let locations = response.result?.objectValue?["locations"]?.arrayValue else {
            throw CodexServiceError.invalidResponse("project/quickLocations response missing locations")
        }

        return locations.compactMap(Self.decodeProjectLocation)
    }

    // Lists only child directories for the phone-side project picker.
    func listProjectDirectory(path: String) async throws -> CodexProjectDirectoryListing {
        let response = try await sendRequest(
            method: "project/listDirectory",
            params: .object([
                "path": .string(path),
                "limit": .integer(200),
            ])
        )
        guard let object = response.result?.objectValue,
              let currentPath = object["path"]?.stringValue,
              let rawEntries = object["entries"]?.arrayValue else {
            throw CodexServiceError.invalidResponse("project/listDirectory response missing entries")
        }

        return CodexProjectDirectoryListing(
            path: currentPath,
            parentPath: object["parentPath"]?.stringValue,
            entries: rawEntries.compactMap(Self.decodeProjectDirectoryEntry)
        )
    }

    // Searches folder names under a selected root so the picker can jump across deep trees.
    func searchProjectDirectories(rootPath: String, query: String) async throws -> [CodexProjectDirectoryEntry] {
        let response = try await sendRequest(
            method: "project/searchDirectories",
            params: .object([
                "path": .string(rootPath),
                "query": .string(query),
                "limit": .integer(80),
            ])
        )
        guard let rawEntries = response.result?.objectValue?["entries"]?.arrayValue else {
            throw CodexServiceError.invalidResponse("project/searchDirectories response missing entries")
        }

        return rawEntries.compactMap(Self.decodeProjectDirectoryEntry)
    }

    // Creates a child folder on the Mac and returns the created absolute path.
    func createProjectDirectory(parentPath: String, name: String) async throws -> String {
        let response = try await sendRequest(
            method: "project/createDirectory",
            params: .object([
                "parentPath": .string(parentPath),
                "name": .string(name),
            ])
        )
        guard let path = response.result?.objectValue?["path"]?.stringValue else {
            throw CodexServiceError.invalidResponse("project/createDirectory response missing path")
        }

        return path
    }
}

private extension CodexService {
    static func decodeProjectLocation(_ value: JSONValue) -> CodexProjectLocation? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let label = object["label"]?.stringValue,
              let path = object["path"]?.stringValue else {
            return nil
        }

        return CodexProjectLocation(id: id, label: label, path: path)
    }

    static func decodeProjectDirectoryEntry(_ value: JSONValue) -> CodexProjectDirectoryEntry? {
        guard let object = value.objectValue,
              let name = object["name"]?.stringValue,
              let path = object["path"]?.stringValue else {
            return nil
        }

        return CodexProjectDirectoryEntry(
            name: name,
            path: path,
            isSymlink: object["isSymlink"]?.boolValue ?? false
        )
    }
}
