// FILE: TurnThreadForkCoordinator.swift
// Purpose: Isolates thread-fork orchestration, readiness checks, and failed-worktree cleanup.
// Layer: View Support
// Exports: TurnThreadForkCoordinator, TurnThreadForkCleanupResult
// Depends on: Foundation, CodexService, TurnViewModel, GitActionsService

import Foundation

enum TurnThreadForkCleanupResult {
    case notNeeded
    case removed
    case preserved(String?)
    case failed(String)
}

enum TurnThreadForkCoordinator {
    private static let readinessRetryDelays: [UInt64] = [
        0,
        350_000_000,
        900_000_000,
    ]

    // Resolves the preferred Local fork target, then falls back to the current project when needed.
    // Mobile clients must trust runtime-provided Mac paths here instead of checking the phone filesystem.
    static func localForkProjectPath(
        for thread: CodexThread,
        localCheckoutPath: String?,
        pathValidator: (String?) -> String? = normalizedProjectPath
    ) -> String? {
        let currentProjectPath = pathValidator(thread.normalizedProjectPath)
        if !thread.isManagedWorktreeProject {
            return currentProjectPath
        }

        if let trimmedLocalCheckoutPath = pathValidator(localCheckoutPath) {
            return trimmedLocalCheckoutPath
        }

        // When the paired Local checkout is not ready yet, keep the fork in the current live worktree.
        return currentProjectPath
    }

    // Centralizes the user-facing copy shown when neither the Local nor current project path can be resolved.
    static func localForkUnavailableAlert(for thread: CodexThread) -> TurnGitSyncAlert {
        TurnGitSyncAlert(
            title: "Local Fork Unavailable",
            message: thread.isManagedWorktreeProject
                ? "Could not resolve either the Local checkout or the current worktree path for this thread."
                : "Could not resolve the local project path for this thread.",
            action: .dismissOnly
        )
    }

    // Waits for runtime readiness before attempting a non-idempotent worktree fork request.
    static func forkThreadIntoPreparedWorktree(
        codex: CodexService,
        sourceThreadId: String,
        projectPath: String
    ) async throws -> CodexThread {
        try await awaitPreparedWorktreeForkReadiness(codex: codex)
        return try await codex.forkThreadIfReady(
            from: sourceThreadId,
            target: .projectPath(projectPath)
        )
    }

    // Gives reconnect/initialize a brief window before the fork flow calls into the runtime.
    static func awaitPreparedWorktreeForkReadiness(codex: CodexService) async throws {
        for (index, delay) in readinessRetryDelays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }

            if codex.isConnected && codex.isInitialized {
                return
            }

            let hasMoreAttempts = index < (readinessRetryDelays.count - 1)
            guard hasMoreAttempts else { break }
        }

        if !codex.isConnected {
            throw CodexServiceError.invalidInput("Connect to runtime first.")
        }

        throw CodexServiceError.invalidInput("Runtime is still initializing. Wait a moment and retry.")
    }

    // Cleans up only when the runtime definitely failed before creating a durable forked thread.
    static func cleanupResultForFailedWorktreeFork(
        _ result: GitCreateWorktreeResult,
        sourceWorkingDirectory: String?,
        error: Error,
        codex: CodexService,
        viewModel: TurnViewModel,
        threadID: String
    ) async -> TurnThreadForkCleanupResult {
        switch failedWorktreeForkDisposition(for: error) {
        case .cleanupSafe:
            return await cleanupFailedForkWorktree(
                result,
                sourceWorkingDirectory: sourceWorkingDirectory,
                codex: codex,
                viewModel: viewModel,
                threadID: threadID
            )
        case .preserveWorktree(let detail):
            return .preserved(detail)
        }
    }

    // Builds the post-failure alert without spreading cleanup wording across the view layer.
    static func failedWorktreeForkMessage(
        for error: Error,
        branch: String,
        cleanupResult: TurnThreadForkCleanupResult
    ) -> String {
        let baseMessage = error.localizedDescription.isEmpty
            ? "Could not fork the thread into '\(branch)'."
            : error.localizedDescription

        switch cleanupResult {
        case .notNeeded:
            return baseMessage
        case .removed:
            return "\(baseMessage)\n\nThe temporary worktree was removed automatically."
        case .preserved(let detail):
            let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = trimmedDetail.isEmpty
                ? "The new worktree was kept in case the fork already exists. Wait a moment for sync, then check your thread list."
                : trimmedDetail
            return "\(baseMessage)\n\n\(suffix)"
        case .failed(let cleanupMessage):
            let detail = cleanupMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty
                ? "We could not remove the temporary worktree automatically."
                : "We could not remove the temporary worktree automatically: \(detail)"
            return "\(baseMessage)\n\n\(suffix)"
        }
    }

    // Transport drops and malformed responses are ambiguous once `thread/fork` has been sent, so keep the worktree.
    private static func failedWorktreeForkDisposition(for error: Error) -> TurnThreadForkCleanupDisposition {
        guard let serviceError = error as? CodexServiceError else {
            return .preserveWorktree("The runtime may have created the fork before the error reached the app.")
        }

        switch serviceError {
        case .disconnected, .invalidResponse:
            return .preserveWorktree(
                "The connection dropped after the fork request was sent, so the new thread may still appear once the runtime syncs."
            )
        case .invalidServerURL:
            return .cleanupSafe
        case .rpcError(let rpcError):
            let normalizedMessage = rpcError.message.lowercased()
            if normalizedMessage.contains("timeout")
                || normalizedMessage.contains("temporarily unavailable")
                || normalizedMessage.contains("connection")
                || normalizedMessage.contains("network") {
                return .preserveWorktree(
                    "The runtime may still be finalizing the fork. The new worktree was kept so we do not discard a thread that may already exist."
                )
            }
            return .cleanupSafe
        case .invalidInput:
            return .cleanupSafe
        case .encodingFailed, .noPendingApproval:
            return .cleanupSafe
        }
    }

    // Removes a temporary managed worktree and refreshes the source thread's branch cache if needed.
    private static func cleanupFailedForkWorktree(
        _ result: GitCreateWorktreeResult,
        sourceWorkingDirectory: String?,
        codex: CodexService,
        viewModel: TurnViewModel,
        threadID: String
    ) async -> TurnThreadForkCleanupResult {
        guard !result.alreadyExisted else {
            return .notNeeded
        }

        let cleanupService = GitActionsService(codex: codex, workingDirectory: result.worktreePath)
        do {
            try await cleanupService.removeManagedWorktree(branch: result.branch)
            viewModel.forgetGitWorktree(branch: result.branch, worktreePath: result.worktreePath)
            if let sourceWorkingDirectory {
                viewModel.refreshGitBranchTargets(
                    codex: codex,
                    workingDirectory: sourceWorkingDirectory,
                    threadID: threadID
                )
            }
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // Normalizes runtime-provided project paths without assuming the current device can stat the remote filesystem.
    private static func normalizedProjectPath(_ rawPath: String?) -> String? {
        guard let rawPath else {
            return nil
        }

        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        return trimmedPath
    }
}

private enum TurnThreadForkCleanupDisposition {
    case cleanupSafe
    case preserveWorktree(String?)
}
