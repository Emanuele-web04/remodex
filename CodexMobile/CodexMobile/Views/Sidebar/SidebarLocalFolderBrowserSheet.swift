// FILE: SidebarLocalFolderBrowserSheet.swift
// Purpose: Presents Mac-local folder browsing/creation for starting project-scoped chats.
// Layer: View
// Exports: SidebarLocalFolderBrowserSheet
// Depends on: SwiftUI, CodexService project folder RPC helpers

import Foundation
import SwiftUI

struct SidebarLocalFolderBrowserSheet: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.dismiss) private var dismiss

    let onSelectFolder: (String) -> Void

    @State private var quickLocations: [CodexProjectLocation] = []
    @State private var currentPath: String?
    @State private var parentPath: String?
    @State private var entries: [CodexProjectDirectoryEntry] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isCreatingFolder = false
    @State private var isShowingNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var activeLoadRequestID: UUID?
    @State private var searchText = ""
    @State private var searchResults: [CodexProjectDirectoryEntry] = []
    @State private var searchErrorMessage: String?
    @State private var isSearchingFolders = false
    @State private var activeSearchRequestID: UUID?

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var folderSearchTaskID: String {
        "\(currentPath ?? "")\n\(searchText)"
    }

    var body: some View {
        NavigationStack {
            List {
                SidebarLocalFolderErrorSection(errorMessage: errorMessage)
                SidebarLocalFolderLocationsSection(
                    locations: quickLocations,
                    onSelect: openDirectory
                )
                SidebarLocalFolderCurrentSection(currentPath: currentPath)
                SidebarLocalFolderEntriesSection(
                    parentPath: parentPath,
                    entries: entries,
                    isLoading: isLoading,
                    searchQuery: trimmedSearchText,
                    searchResults: searchResults,
                    searchErrorMessage: searchErrorMessage,
                    isSearchingFolders: isSearchingFolders,
                    onSelect: openDirectory
                )
            }
            .navigationTitle("Add Local Folder")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search folders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: presentNewFolderPrompt) {
                        Image(systemName: "folder.badge.plus")
                    }
                    .disabled(currentPath == nil || isCreatingFolder)

                    Button("Use", action: useCurrentFolder)
                        .disabled(currentPath == nil)
                }
            }
        }
        .task {
            await loadInitialDirectory()
        }
        .task(id: folderSearchTaskID) {
            await updateFolderSearch()
        }
        .alert("New Folder", isPresented: $isShowingNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                Task { await createFolderAndSelect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create this folder on your Mac and start a chat there.")
        }
    }

    private func presentNewFolderPrompt() {
        newFolderName = ""
        isShowingNewFolderPrompt = true
    }

    private func useCurrentFolder() {
        guard let currentPath else { return }

        dismiss()
        onSelectFolder(currentPath)
    }

    private func openDirectory(_ path: String) {
        clearFolderSearch()
        Task { await loadDirectory(path) }
    }

    // Starts from Developer when present, otherwise falls back to the Mac home folder.
    private func loadInitialDirectory() async {
        guard quickLocations.isEmpty, currentPath == nil else { return }

        do {
            let locations = try await codex.fetchProjectQuickLocations()
            quickLocations = locations
            let startPath = locations.first(where: { $0.id == "developer" })?.path ?? locations.first?.path
            if let startPath {
                await loadDirectory(startPath)
            } else {
                errorMessage = "No local folders are available from this Mac."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Reads one Mac directory through the bridge and updates the visible folder list.
    private func loadDirectory(_ path: String) async {
        let requestID = UUID()
        activeLoadRequestID = requestID
        isLoading = true
        defer {
            if activeLoadRequestID == requestID {
                isLoading = false
                activeLoadRequestID = nil
            }
        }

        do {
            let listing = try await codex.listProjectDirectory(path: path)
            guard activeLoadRequestID == requestID else { return }
            currentPath = listing.path
            parentPath = listing.parentPath
            entries = listing.entries
            errorMessage = nil
        } catch {
            guard activeLoadRequestID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }

    // Debounces remote folder-name search under the current browser root.
    private func updateFolderSearch() async {
        let query = trimmedSearchText
        guard !query.isEmpty else {
            clearFolderSearch()
            return
        }
        guard let currentPath else { return }

        let requestID = UUID()
        activeSearchRequestID = requestID
        searchErrorMessage = nil
        isSearchingFolders = true
        defer {
            if activeSearchRequestID == requestID {
                isSearchingFolders = false
            }
        }

        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            let results = try await codex.searchProjectDirectories(rootPath: currentPath, query: query)
            guard activeSearchRequestID == requestID else { return }
            searchResults = results
        } catch is CancellationError {
            return
        } catch {
            guard activeSearchRequestID == requestID else { return }
            searchResults = []
            searchErrorMessage = error.localizedDescription
        }
    }

    private func clearFolderSearch() {
        searchText = ""
        searchResults = []
        searchErrorMessage = nil
        isSearchingFolders = false
        activeSearchRequestID = nil
    }

    // Creates a folder at the current location and immediately opens the new chat there.
    private func createFolderAndSelect() async {
        guard let currentPath else { return }
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isCreatingFolder = true
        defer { isCreatingFolder = false }

        do {
            let createdPath = try await codex.createProjectDirectory(
                parentPath: currentPath,
                name: trimmedName
            )
            dismiss()
            onSelectFolder(createdPath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SidebarLocalFolderErrorSection: View {
    let errorMessage: String?

    var body: some View {
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .font(AppFont.body())
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SidebarLocalFolderLocationsSection: View {
    let locations: [CodexProjectLocation]
    let onSelect: (String) -> Void

    var body: some View {
        if !locations.isEmpty {
            Section("Locations") {
                ForEach(locations) { location in
                    Button {
                        onSelect(location.path)
                    } label: {
                        SidebarLocalFolderRow(
                            iconSystemName: "folder",
                            title: location.label,
                            subtitle: location.path
                        )
                    }
                }
            }
        }
    }
}

private struct SidebarLocalFolderCurrentSection: View {
    let currentPath: String?

    var body: some View {
        Section("Current Folder") {
            if let currentPath {
                SidebarLocalFolderRow(
                    iconSystemName: "folder.fill",
                    title: Self.displayName(for: currentPath),
                    subtitle: currentPath
                )
            } else {
                Text("Loading folders...")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func displayName(for path: String) -> String {
        let lastComponent = (path as NSString).lastPathComponent
        return lastComponent.isEmpty ? path : lastComponent
    }
}

private struct SidebarLocalFolderEntriesSection: View {
    let parentPath: String?
    let entries: [CodexProjectDirectoryEntry]
    let isLoading: Bool
    let searchQuery: String
    let searchResults: [CodexProjectDirectoryEntry]
    let searchErrorMessage: String?
    let isSearchingFolders: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Section(searchQuery.isEmpty ? "Folders" : "Matching Folders") {
            if searchQuery.isEmpty {
                folderBrowserRows
            } else {
                folderSearchRows
            }
        }
    }

    @ViewBuilder
    private var folderBrowserRows: some View {
        if let parentPath {
            Button {
                onSelect(parentPath)
            } label: {
                SidebarLocalFolderRow(
                    iconSystemName: "arrow.uturn.left",
                    title: "Parent Folder",
                    subtitle: parentPath
                )
            }
        }

        if isLoading {
            HStack {
                ProgressView()
                Text("Loading")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
            }
        } else if entries.isEmpty {
            Text("No child folders here.")
                .font(AppFont.body())
                .foregroundStyle(.secondary)
        } else {
            ForEach(entries) { entry in
                folderButton(entry)
            }
        }
    }

    @ViewBuilder
    private var folderSearchRows: some View {
        if isSearchingFolders {
            HStack {
                ProgressView()
                Text("Searching folders...")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
            }
        } else if let searchErrorMessage {
            Text(searchErrorMessage)
                .font(AppFont.body())
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if searchResults.isEmpty {
            Text("No matching folders under this folder.")
                .font(AppFont.body())
                .foregroundStyle(.secondary)
        } else {
            ForEach(searchResults) { entry in
                folderButton(entry)
            }
        }
    }

    private func folderButton(_ entry: CodexProjectDirectoryEntry) -> some View {
        Button {
            onSelect(entry.path)
        } label: {
            SidebarLocalFolderRow(
                iconSystemName: entry.isSymlink ? "folder.badge.gearshape" : "folder",
                title: entry.name,
                subtitle: entry.path
            )
        }
    }
}

private struct SidebarLocalFolderRow: View {
    let iconSystemName: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconSystemName)
                .font(AppFont.body(weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(subtitle)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }
}
