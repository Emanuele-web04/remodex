// FILE: CodexService+ProjectFolders.swift
// Purpose: Mac-local project folder browsing RPCs used by the sidebar new-chat flow.
// Layer: Service Extension
// Exports: CodexProjectLocation, CodexKnownProject, CodexProjectDirectoryEntry,
//          CodexProjectDirectoryListing, CodexService project folder APIs
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

struct CodexProjectlessChatRoots: Equatable, Sendable {
    let roots: [String]
    let codexHome: String?
    let documentedThreadsRoot: String?
    let desktopDocumentsRoot: String?
}

struct CodexKnownProject: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let path: String
    let source: String?
    let sources: [String]
    let providerHints: [String]
    let lastSeenAt: Date?
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

    // Reads host-side Codex chat roots so projectless classification survives custom CODEX_HOME.
    func fetchProjectlessChatRoots() async throws -> CodexProjectlessChatRoots {
        let response = try await sendRequest(method: "project/projectlessRoots", params: .object([:]))
        guard let object = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("project/projectlessRoots response missing payload")
        }

        let roots = object["roots"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return CodexProjectlessChatRoots(
            roots: roots,
            codexHome: object["codexHome"]?.stringValue,
            documentedThreadsRoot: object["documentedThreadsRoot"]?.stringValue,
            desktopDocumentsRoot: object["desktopDocumentsRoot"]?.stringValue
        )
    }

    // Loads provider-neutral projects remembered by the bridge from Codex,
    // OpenCode, and manual local-folder selections.
    func fetchKnownProjects() async throws -> [CodexKnownProject] {
        let response = try await sendRequest(method: "project/knownProjects", params: .object([:]))
        guard let projects = response.result?.objectValue?["projects"]?.arrayValue else {
            throw CodexServiceError.invalidResponse("project/knownProjects response missing projects")
        }

        return projects.compactMap(Self.decodeKnownProject)
    }

    // Stores a user-picked local folder so future provider pickers can offer it
    // even before any provider has written a thread in that repo.
    @discardableResult
    func rememberKnownProject(path: String) async throws -> CodexKnownProject? {
        let response = try await sendRequest(
            method: "project/rememberKnownProject",
            params: .object([
                "path": .string(path),
                "source": .string("ios-picker"),
            ])
        )

        guard let projectValue = response.result?.objectValue?["project"] else {
            return nil
        }
        return Self.decodeKnownProject(projectValue)
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

    // Asks the bridge to materialize a Codex-Desktop-style projectless chat root
    // (`~/Documents/Codex/<DATE>/<slug>` or its Windows equivalent) and returns
    // the absolute path so the iOS client can pass it as `cwd` to `thread/start`.
    // The bridge derives the slug from `promptHint`, falling back to `new-chat`
    // when no meaningful hint is available (e.g. the Quick Chat top button).
    func createRootlessChatRoot(promptHint: String?) async throws -> String {
        var params: [String: JSONValue] = [:]
        if let promptHint, !promptHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["promptHint"] = .string(promptHint)
        }

        let response = try await sendRequest(
            method: "project/createRootlessChatRoot",
            params: .object(params)
        )
        guard let path = response.result?.objectValue?["path"]?.stringValue,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexServiceError.invalidResponse("project/createRootlessChatRoot response missing path")
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

    static func decodeKnownProject(_ value: JSONValue) -> CodexKnownProject? {
        guard let object = value.objectValue,
              let path = object["path"]?.stringValue else {
            return nil
        }

        let label = object["label"]?.stringValue ?? CodexThread.projectDisplayLabel(for: path)
        return CodexKnownProject(
            id: object["id"]?.stringValue ?? path,
            label: label,
            path: path,
            source: object["source"]?.stringValue,
            sources: object["sources"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            providerHints: object["providerHints"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            lastSeenAt: decodeKnownProjectDate(object["lastSeenAt"])
        )
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

    static func decodeKnownProjectDate(_ value: JSONValue?) -> Date? {
        if let stringValue = value?.stringValue {
            return CodexTimestampParser.parseString(stringValue)
        }
        if let doubleValue = value?.doubleValue {
            return CodexTimestampParser.decodeUnixTimestamp(doubleValue)
        }
        return nil
    }
}
