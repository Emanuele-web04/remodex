// FILE: GitActionsService.swift
// Purpose: Executes git operations via bridge JSON-RPC over the existing WebSocket.
// Layer: Service
// Exports: GitActionsService, GitActionsError
// Depends on: CodexService, GitActionModels

import Foundation

enum GitActionsError: LocalizedError {
    case disconnected
    case invalidResponse
    case bridgeError(code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "Not connected to bridge."
        case .invalidResponse:
            return "Invalid response from bridge."
        case .bridgeError(let code, let message):
            return userMessage(for: code, fallback: message)
        }
    }

    private func userMessage(for code: String?, fallback: String?) -> String {
        switch code {
        case "nothing_to_commit": return "Nothing to commit."
        case "nothing_to_push": return "Nothing to push."
        case "push_rejected": return "Push rejected. Pull changes first."
        case "branch_is_main": return "Cannot operate on the main branch."
        case "protected_branch": return "This branch is protected."
        case "branch_behind_remote": return "Branch is behind remote. Pull first."
        case "dirty_and_behind": return "Uncommitted changes and branch is behind remote."
        case "checkout_conflict_dirty_tree": return "Cannot switch branches: you have uncommitted changes."
        case "checkout_branch_in_other_worktree":
            return "Cannot switch branches: this branch is already open in another worktree."
        case "pull_conflict": return "Pull failed due to conflicts."
        case "branch_exists": return fallback ?? "Branch already exists."
        case "invalid_branch_name": return fallback ?? "Branch name is not valid for Git."
        case "missing_branch", "missing_branch_name": return "Branch name is required."
        case "missing_base_branch": return fallback ?? "Base branch is required."
        case "branch_already_open_here":
            return fallback ?? "This branch is already open in the current project."
        case "branch_in_other_worktree":
            return fallback ?? "This branch is already open in another worktree."
        case "confirmation_required": return "Confirmation is required for this action."
        case "stash_pop_conflict": return "Stash pop failed due to conflicts."
        case "missing_local_repo": return "Run `remodex up` from an existing local directory first."
        case "missing_working_directory":
            return fallback ?? "The selected local folder is not available on this Mac."
        case "cannot_remove_local_checkout":
            return fallback ?? "Cannot remove the main local checkout."
        case "unmanaged_worktree":
            return fallback ?? "Only managed worktrees can be cleaned up automatically."
        case "worktree_cleanup_failed":
            return fallback ?? "We could not clean up the temporary worktree automatically."
        case "handoff_target_dirty":
            return fallback ?? "The handoff destination already has uncommitted changes."
        case "handoff_target_mismatch":
            return fallback ?? "The selected handoff destination belongs to a different checkout."
        case "handoff_transfer_failed":
            return fallback ?? "Could not move local changes into the handoff destination."
        case "missing_handoff_source":
            return fallback ?? "The current handoff source is no longer available on this Mac."
        case "missing_handoff_target":
            return fallback ?? "The handoff destination is no longer available on this Mac."
        default: return fallback ?? "Git operation failed."
        }
    }
}

@MainActor
final class GitActionsService {
    private let codex: CodexService
    private let workingDirectory: String?

    init(codex: CodexService, workingDirectory: String?) {
        self.codex = codex
        self.workingDirectory = Self.normalizedWorkingDirectory(workingDirectory)
    }

    func status() async throws -> GitRepoSyncResult {
        let json = try await request(method: "git/status")
        let result = GitRepoSyncResult(from: json)
        rememberRepoRoot(from: result)
        return result
    }

    func diff() async throws -> GitRepoDiffResult {
        let json = try await request(method: "git/diff")
        return GitRepoDiffResult(from: json)
    }

    func commit(message: String?) async throws -> GitCommitResult {
        var params: [String: JSONValue] = [:]
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["message"] = .string(message)
        }
        let json = try await request(method: "git/commit", params: params)
        return GitCommitResult(from: json)
    }

    func push() async throws -> GitPushResult {
        let json = try await request(method: "git/push")
        let result = GitPushResult(from: json)
        rememberRepoRoot(from: result.status)
        return result
    }

    func pull() async throws -> GitPullResult {
        let json = try await request(method: "git/pull")
        let result = GitPullResult(from: json)
        rememberRepoRoot(from: result.status)
        return result
    }

    func branches() async throws -> GitBranchesResult {
        let json = try await request(method: "git/branches")
        return GitBranchesResult(from: json)
    }

    // Creates a local branch and checks it out in the bound repo.
    func createBranch(name: String) async throws -> GitCreateBranchResult {
        let json = try await request(method: "git/createBranch", params: ["name": .string(name)])
        let result = GitCreateBranchResult(from: json)
        rememberRepoRoot(from: result.status)
        return result
    }

    // Creates or reuses a managed worktree rooted under CODEX_HOME/worktrees.
    func createWorktree(
        name: String,
        baseBranch: String,
        changeTransfer: GitWorktreeChangeTransferMode = .move
    ) async throws -> GitCreateWorktreeResult {
        let json = try await request(
            method: "git/createWorktree",
            params: [
                "name": .string(name),
                "baseBranch": .string(baseBranch),
                "changeTransfer": .string(changeTransfer.rawValue),
            ]
        )
        return GitCreateWorktreeResult(from: json)
    }

    // Creates a Codex-managed detached worktree rooted under CODEX_HOME/worktrees.
    func createManagedWorktree(
        baseBranch: String,
        changeTransfer: GitWorktreeChangeTransferMode = .move
    ) async throws -> GitCreateManagedWorktreeResult {
        let json = try await request(
            method: "git/createManagedWorktree",
            params: [
                "baseBranch": .string(baseBranch),
                "changeTransfer": .string(changeTransfer.rawValue),
            ]
        )
        return GitCreateManagedWorktreeResult(from: json)
    }

    func transferManagedHandoff(targetProjectPath: String) async throws -> GitManagedHandoffTransferResult {
        let json = try await request(
            method: "git/transferManagedHandoff",
            params: ["targetPath": .string(targetProjectPath)]
        )
        return GitManagedHandoffTransferResult(from: json)
    }

    func removeManagedWorktree(branch: String?) async throws {
        var params: [String: JSONValue] = [:]
        if let branch, !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["branch"] = .string(branch)
        }
        _ = try await request(method: "git/removeWorktree", params: params)
    }

    func checkout(branch: String) async throws -> GitCheckoutResult {
        let json = try await request(method: "git/checkout", params: ["branch": .string(branch)])
        let result = GitCheckoutResult(from: json)
        rememberRepoRoot(from: result.status)
        return result
    }

    func resetToRemote() async throws -> GitResetResult {
        let json = try await request(
            method: "git/resetToRemote",
            params: ["confirm": .string("discard_runtime_changes")]
        )
        let result = GitResetResult(from: json)
        rememberRepoRoot(from: result.status)
        return result
    }

    func remoteUrl() async throws -> GitRemoteUrlResult {
        let json = try await request(method: "git/remoteUrl")
        return GitRemoteUrlResult(from: json)
    }

    func branchesWithStatus() async throws -> GitBranchesWithStatusResult {
        let json = try await request(method: "git/branchesWithStatus")
        let result = GitBranchesWithStatusResult(from: json)
        rememberRepoRoot(from: result.status)
        return result
    }

    // MARK: - Private

    private func request(method: String, params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        guard let workingDirectory else {
            throw GitActionsError.bridgeError(
                code: "missing_working_directory",
                message: "The selected local folder is not available on this Mac."
            )
        }

        var scopedParams = params
        scopedParams["cwd"] = .string(workingDirectory)
        let rpcParams: JSONValue = .object(scopedParams)

        do {
            let response = try await codex.sendRequest(method: method, params: rpcParams)

            guard let resultObj = response.result?.objectValue else {
                throw GitActionsError.invalidResponse
            }
            return resultObj
        } catch let error as CodexServiceError {
            switch error {
            case .disconnected:
                throw GitActionsError.disconnected
            case .rpcError(let rpcError):
                let errorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue
                throw GitActionsError.bridgeError(code: errorCode, message: rpcError.message)
            default:
                throw GitActionsError.bridgeError(code: nil, message: error.errorDescription)
            }
        }
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func rememberRepoRoot(from result: GitRepoSyncResult?) {
        codex.rememberRepoRoot(result?.repoRoot, forWorkingDirectory: workingDirectory)
    }
}
