// FILE: GitActionModels.swift
// Purpose: Data models for git operations executed via the phodex-bridge.
// Layer: Model
// Exports: GitDiffTotals, GitRepoSyncResult, GitRepoDiffResult, GitCommitResult, GitPushResult, GitBranchesResult, GitCheckoutResult, GitPullResult, GitResetResult, TurnGitActionKind, TurnGitSyncAlert, TurnGitSyncAlertAction
// Depends on: JSONValue

import Foundation

// MARK: - Result types

struct GitDiffTotals: Equatable, Sendable {
    let additions: Int
    let deletions: Int
    let binaryFiles: Int

    var hasChanges: Bool {
        additions > 0 || deletions > 0 || binaryFiles > 0
    }

    init(additions: Int, deletions: Int, binaryFiles: Int = 0) {
        self.additions = additions
        self.deletions = deletions
        self.binaryFiles = binaryFiles
    }

    init?(from json: [String: JSONValue]?) {
        guard let json else {
            return nil
        }

        let additions = json["additions"]?.intValue ?? 0
        let deletions = json["deletions"]?.intValue ?? 0
        let binaryFiles = json["binaryFiles"]?.intValue ?? 0
        let totals = GitDiffTotals(additions: additions, deletions: deletions, binaryFiles: binaryFiles)
        guard totals.hasChanges else {
            return nil
        }

        self = totals
    }
}

struct GitRepoSyncResult: Sendable {
    let repoRoot: String?
    let currentBranch: String?
    let trackingBranch: String?
    let isDirty: Bool
    let aheadCount: Int
    let behindCount: Int
    let state: String
    let canPush: Bool
    let repoDiffTotals: GitDiffTotals?

    init(from json: [String: JSONValue]) {
        self.repoRoot = json["repoRoot"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentBranch = json["branch"]?.stringValue
        self.trackingBranch = json["tracking"]?.stringValue
        self.isDirty = json["dirty"]?.boolValue ?? false
        self.aheadCount = json["ahead"]?.intValue ?? 0
        self.behindCount = json["behind"]?.intValue ?? 0
        self.state = json["state"]?.stringValue ?? "up_to_date"
        self.canPush = json["canPush"]?.boolValue ?? false
        self.repoDiffTotals = GitDiffTotals(from: json["diff"]?.objectValue)
    }
}

struct GitRepoDiffResult: Sendable {
    let patch: String

    init(from json: [String: JSONValue]) {
        self.patch = json["patch"]?.stringValue ?? ""
    }
}

struct GitCommitResult: Sendable {
    let commitHash: String
    let branch: String
    let summary: String

    init(from json: [String: JSONValue]) {
        self.commitHash = json["hash"]?.stringValue ?? ""
        self.branch = json["branch"]?.stringValue ?? ""
        self.summary = json["summary"]?.stringValue ?? ""
    }
}

struct GitPushResult: Sendable {
    let branch: String
    let remote: String?
    let status: GitRepoSyncResult?

    init(from json: [String: JSONValue]) {
        self.branch = json["branch"]?.stringValue ?? ""
        self.remote = json["remote"]?.stringValue
        if let statusObj = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObj)
        } else {
            self.status = nil
        }
    }
}

struct GitBranchesResult: Sendable {
    let branches: [String]
    let branchesCheckedOutElsewhere: Set<String>
    let currentBranch: String?
    let defaultBranch: String?

    init(from json: [String: JSONValue]) {
        self.branches = json["branches"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.branchesCheckedOutElsewhere = Set(
            json["branchesCheckedOutElsewhere"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        self.currentBranch = json["current"]?.stringValue
        self.defaultBranch = json["default"]?.stringValue
    }
}

struct GitCheckoutResult: Sendable {
    let currentBranch: String
    let tracking: String?
    let status: GitRepoSyncResult?

    init(from json: [String: JSONValue]) {
        self.currentBranch = json["current"]?.stringValue ?? ""
        self.tracking = json["tracking"]?.stringValue
        if let statusObj = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObj)
        } else {
            self.status = nil
        }
    }
}

struct GitPullResult: Sendable {
    let success: Bool
    let status: GitRepoSyncResult?

    init(from json: [String: JSONValue]) {
        self.success = json["success"]?.boolValue ?? false
        if let statusObj = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObj)
        } else {
            self.status = nil
        }
    }
}

struct GitResetResult: Sendable {
    let success: Bool
    let status: GitRepoSyncResult?

    init(from json: [String: JSONValue]) {
        self.success = json["success"]?.boolValue ?? false
        if let statusObj = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObj)
        } else {
            self.status = nil
        }
    }
}

struct GitRemoteUrlResult: Sendable {
    let url: String
    let ownerRepo: String?

    init(from json: [String: JSONValue]) {
        self.url = json["url"]?.stringValue ?? ""
        self.ownerRepo = json["ownerRepo"]?.stringValue
    }
}

struct GitBranchesWithStatusResult: Sendable {
    let branches: [String]
    let branchesCheckedOutElsewhere: Set<String>
    let currentBranch: String?
    let defaultBranch: String?
    let status: GitRepoSyncResult?

    init(from json: [String: JSONValue]) {
        self.branches = json["branches"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.branchesCheckedOutElsewhere = Set(
            json["branchesCheckedOutElsewhere"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        self.currentBranch = json["current"]?.stringValue
        self.defaultBranch = json["default"]?.stringValue
        if let statusObj = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObj)
        } else {
            self.status = nil
        }
    }
}

// MARK: - Action kind

enum TurnGitActionKind: CaseIterable, Sendable {
    case syncNow
    case commit
    case push
    case commitAndPush
    case createPR
    case discardRuntimeChangesAndSync

    var title: String {
        switch self {
        case .syncNow: return "Update"
        case .commit: return "Commit"
        case .push: return "Push"
        case .commitAndPush: return "Commit & Push"
        case .createPR: return "Create PR"
        case .discardRuntimeChangesAndSync: return "Discard Local Changes"
        }
    }
}

// MARK: - Alert types

struct TurnGitSyncAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: TurnGitSyncAlertAction
}

enum TurnGitSyncAlertAction: Sendable {
    case dismissOnly
    case pullRebase
}
