// FILE: TurnView+WorktreeActions.swift
// Purpose: Isolates TurnView worktree handoff/open flows from the main view body.
// Layer: View Support
// Exports: TurnViewWorktreeActions

import Foundation

@MainActor
enum TurnViewWorktreeActions {
    // Moves the current thread into the selected managed worktree without creating a sibling chat.
    static func handoffCurrentThreadToWorktree(
        projectPath: String,
        branch: String,
        codex: CodexService,
        viewModel: TurnViewModel,
        threadID: String
    ) {
        guard let normalizedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(projectPath) else {
            viewModel.gitSyncAlert = TurnGitSyncAlert(
                title: "Worktree Handoff Failed",
                message: "Could not resolve the worktree path for \(branch).",
                action: .dismissOnly
            )
            return
        }

        let resolvedProjectPath = TurnWorktreeRouting.canonicalProjectPath(normalizedProjectPath) ?? normalizedProjectPath

        Task { @MainActor in
            do {
                _ = try await codex.moveThreadToProjectPath(threadId: threadID, projectPath: resolvedProjectPath)
                viewModel.refreshGitBranchTargets(
                    codex: codex,
                    workingDirectory: resolvedProjectPath,
                    threadID: threadID
                )
            } catch {
                viewModel.gitSyncAlert = TurnGitSyncAlert(
                    title: "Worktree Handoff Failed",
                    message: error.localizedDescription.isEmpty
                        ? "Could not hand off the thread to \(branch)."
                        : error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    // Resolves the chat already associated with a branch that is checked out in another worktree.
    static func liveThreadForCheckedOutElsewhereBranch(
        projectPath: String,
        codex: CodexService,
        currentThread: CodexThread
    ) -> CodexThread? {
        guard let normalizedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(projectPath) else {
            return nil
        }

        let resolvedProjectPath = TurnWorktreeRouting.canonicalProjectPath(normalizedProjectPath) ?? normalizedProjectPath
        let currentComparablePath = TurnWorktreeRouting.comparableProjectPath(currentThread.normalizedProjectPath)

        if currentComparablePath == resolvedProjectPath {
            return nil
        }

        return TurnWorktreeRouting.matchingLiveThread(
            in: codex.threads,
            projectPath: resolvedProjectPath,
            sort: codex.sortThreads
        )
    }
}
