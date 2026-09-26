// FILE: ManagedWorktreeCleanupSheet.swift
// Purpose: Lists managed checkouts for a Local project and confirms safe cleanup.
// Layer: View Component
// Exports: ManagedWorktreeCleanupSheet

import SwiftUI

struct ManagedWorktreeCleanupSheet: View {
    let localCheckoutPath: String

    @Environment(CodexService.self) private var codex
    @Environment(\.dismiss) private var dismiss
    @State private var worktrees: [GitManagedWorktree] = []
    @State private var isLoading = true
    @State private var isRemoving = false
    @State private var isRemovalConfirmationPresented = false
    @State private var pendingRemoval: GitManagedWorktree?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading worktrees…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if worktrees.isEmpty {
                    ContentUnavailableView(
                        "No managed worktrees",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("This project has no managed worktrees to clean up.")
                    )
                } else {
                    List(worktrees) { worktree in
                        worktreeRow(worktree)
                    }
                }
            }
            .navigationTitle("Managed Worktrees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
            .confirmationDialog(
                "Remove this worktree?",
                isPresented: $isRemovalConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Remove Worktree", role: .destructive) {
                    guard let worktree = pendingRemoval else { return }
                    Task { await remove(worktree) }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("Git will remove this clean checkout. Chats and local files in use block removal.")
            }
            .alert("Could not remove worktree", isPresented: errorPresented) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }

    private func worktreeRow(_ worktree: GitManagedWorktree) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(URL(fileURLWithPath: worktree.path).deletingLastPathComponent().lastPathComponent)
                .font(AppFont.body(weight: .semibold))
            Text(worktree.path)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let branch = worktree.branch {
                Text(branch)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
            }
            if !worktree.isClean {
                Label("Contains local files", systemImage: "exclamationmark.triangle")
                    .font(AppFont.footnote())
                    .foregroundStyle(.orange)
            }
            Button("Remove Worktree", role: .destructive) {
                pendingRemoval = worktree
                isRemovalConfirmationPresented = true
            }
            .disabled(!worktree.isClean || isRemoving)
        }
        .padding(.vertical, 4)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let service = GitActionsService(codex: codex, workingDirectory: localCheckoutPath)
            worktrees = try await service.managedWorktrees()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ worktree: GitManagedWorktree) async {
        isRemoving = true
        pendingRemoval = nil
        defer { isRemoving = false }
        do {
            try await WorktreeFlowCoordinator.removeManagedWorktree(
                at: worktree.path,
                branch: worktree.branch,
                codex: codex
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
