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
                    onSelect: openDirectory
                )
            }
            .navigationTitle("Add Local Folder")
            .navigationBarTitleDisplayMode(.inline)
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
    let onSelect: (String) -> Void

    var body: some View {
        Section("Folders") {
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
