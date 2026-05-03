// FILE: GitActionModels.swift
// Purpose: Data models for git operations executed via the phodex-bridge.
// Layer: Model
// Exports: GitDiffTotals, GitRepoSyncResult, GitPushResult, GitStackedActionResult, TurnGitActionKind, TurnGitSyncAlert
// Depends on: JSONValue

import Foundation

// MARK: - Result types

enum GitWorktreeChangeTransferMode: String, Equatable, Sendable {
    case move
    case copy
    case none

    var transferVerb: String? {
        switch self {
        case .move:
            return "move"
        case .copy:
            return "copy"
        case .none:
            return nil
        }
    }
}

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

struct GitChangedFile: Equatable, Sendable {
    let path: String
    let status: String

    init?(from json: [String: JSONValue]) {
        let path = json["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            return nil
        }

        self.path = path
        self.status = json["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct GitRepoSyncResult: Sendable {
    let isGitRepository: Bool
    let repoRoot: String?
    let currentBranch: String?
    let trackingBranch: String?
    let isDirty: Bool
    let hasHeadCommit: Bool
    let hasPushRemote: Bool
    let aheadCount: Int
    let behindCount: Int
    let localOnlyCommitCount: Int
    let state: String
    let canPush: Bool
    let isPublishedToRemote: Bool
    let files: [GitChangedFile]
    let repoDiffTotals: GitDiffTotals?

    init(from json: [String: JSONValue]) {
        self.isGitRepository = json["isRepo"]?.boolValue ?? true
        self.repoRoot = json["repoRoot"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentBranch = json["branch"]?.stringValue
        self.trackingBranch = json["tracking"]?.stringValue
        self.isDirty = json["dirty"]?.boolValue ?? false
        self.hasHeadCommit = json["hasHeadCommit"]?.boolValue ?? true
        self.hasPushRemote = json["hasPushRemote"]?.boolValue ?? true
        self.aheadCount = json["ahead"]?.intValue ?? 0
        self.behindCount = json["behind"]?.intValue ?? 0
        self.localOnlyCommitCount = json["localOnlyCommitCount"]?.intValue ?? 0
        self.state = json["state"]?.stringValue ?? "up_to_date"
        self.canPush = json["canPush"]?.boolValue ?? false
        self.isPublishedToRemote = json["publishedToRemote"]?.boolValue ?? false
        self.files = json["files"]?.arrayValue?.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return GitChangedFile(from: object)
        } ?? []
        self.repoDiffTotals = GitDiffTotals(from: json["diff"]?.objectValue)
    }
}

struct GitInitResult: Sendable {
    let status: GitRepoSyncResult?

    init(from json: [String: JSONValue]) {
        if let statusObj = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObj)
        } else {
            self.status = nil
        }
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

struct GitGeneratedCommitMessageResult: Sendable {
    let subject: String
    let body: String
    let fullMessage: String

    init(from json: [String: JSONValue]) {
        self.subject = json["subject"]?.stringValue ?? ""
        self.body = json["body"]?.stringValue ?? ""
        self.fullMessage = json["fullMessage"]?.stringValue ?? ""
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
    let worktreePathByBranch: [String: String]
    let localCheckoutPath: String?
    let currentBranch: String?
    let defaultBranch: String?

    init(from json: [String: JSONValue]) {
        self.branches = json["branches"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.branchesCheckedOutElsewhere = Set(
            json["branchesCheckedOutElsewhere"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        self.worktreePathByBranch = Self.stringDictionary(from: json["worktreePathByBranch"]?.objectValue)
        self.localCheckoutPath = json["localCheckoutPath"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentBranch = json["current"]?.stringValue
        self.defaultBranch = json["default"]?.stringValue
    }
}

struct GitCreateBranchResult: Sendable {
    let branch: String
    let status: GitRepoSyncResult?

    init(from json: [String: JSONValue]) {
        self.branch = json["branch"]?.stringValue ?? ""
        if let statusObj = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObj)
        } else {
            self.status = nil
        }
    }
}

struct GitCreateWorktreeResult: Sendable {
    let branch: String
    let worktreePath: String
    let alreadyExisted: Bool

    init(from json: [String: JSONValue]) {
        self.branch = json["branch"]?.stringValue ?? ""
        self.worktreePath = json["worktreePath"]?.stringValue ?? ""
        self.alreadyExisted = json["alreadyExisted"]?.boolValue ?? false
    }
}

struct GitCreateManagedWorktreeResult: Sendable {
    let worktreePath: String
    let alreadyExisted: Bool
    let baseBranch: String
    let headMode: String
    let transferredChanges: Bool

    init(from json: [String: JSONValue]) {
        self.worktreePath = json["worktreePath"]?.stringValue ?? ""
        self.alreadyExisted = json["alreadyExisted"]?.boolValue ?? false
        self.baseBranch = json["baseBranch"]?.stringValue ?? ""
        self.headMode = json["headMode"]?.stringValue ?? ""
        self.transferredChanges = json["transferredChanges"]?.boolValue ?? false
    }
}

struct GitManagedHandoffTransferResult: Sendable {
    let success: Bool
    let targetPath: String?
    let transferredChanges: Bool

    init(from json: [String: JSONValue]) {
        self.success = json["success"]?.boolValue ?? false
        self.targetPath = json["targetPath"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transferredChanges = json["transferredChanges"]?.boolValue ?? false
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

struct GitPullRequestDraftResult: Sendable {
    let title: String
    let body: String

    init(from json: [String: JSONValue]) {
        self.title = json["title"]?.stringValue ?? ""
        self.body = json["body"]?.stringValue ?? ""
    }
}

struct GitPullRequestResult: Sendable {
    let status: String
    let url: String?
    let number: Int?
    let baseBranch: String?
    let headBranch: String?
    let title: String?

    init(from json: [String: JSONValue]?) {
        self.status = json?["status"]?.stringValue ?? "skipped_not_requested"
        self.url = json?["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.number = json?["number"]?.intValue
        self.baseBranch = json?["baseBranch"]?.stringValue
        self.headBranch = json?["headBranch"]?.stringValue
        self.title = json?["title"]?.stringValue
    }
}

struct GitStackedActionResult: Sendable {
    let action: String
    let push: GitPushResult?
    let pullRequest: GitPullRequestResult
    let status: GitRepoSyncResult?

    init(from json: [String: JSONValue]) {
        self.action = json["action"]?.stringValue ?? ""
        if let pushObj = json["push"]?.objectValue,
           pushObj["state"]?.stringValue == "pushed" || pushObj["branch"]?.stringValue != nil {
            self.push = GitPushResult(from: pushObj)
        } else {
            self.push = nil
        }
        self.pullRequest = GitPullRequestResult(from: json["pr"]?.objectValue)
        if let statusObj = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObj)
        } else {
            self.status = nil
        }
    }
}

struct GitBranchesWithStatusResult: Sendable {
    let branches: [String]
    let branchesCheckedOutElsewhere: Set<String>
    let worktreePathByBranch: [String: String]
    let localCheckoutPath: String?
    let currentBranch: String?
    let defaultBranch: String?
    let status: GitRepoSyncResult?

    init(from json: [String: JSONValue]) {
        self.branches = json["branches"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.branchesCheckedOutElsewhere = Set(
            json["branchesCheckedOutElsewhere"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        self.worktreePathByBranch = Self.stringDictionary(from: json["worktreePathByBranch"]?.objectValue)
        self.localCheckoutPath = json["localCheckoutPath"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentBranch = json["current"]?.stringValue
        self.defaultBranch = json["default"]?.stringValue
        if let statusObj = json["status"]?.objectValue {
            self.status = GitRepoSyncResult(from: statusObj)
        } else {
            self.status = nil
        }
    }
}

private extension GitBranchesResult {
    static func stringDictionary(from json: [String: JSONValue]?) -> [String: String] {
        json?.reduce(into: [:]) { partialResult, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty, !value.isEmpty else { return }
            partialResult[key] = value
        } ?? [:]
    }
}

private extension GitBranchesWithStatusResult {
    static func stringDictionary(from json: [String: JSONValue]?) -> [String: String] {
        GitBranchesResult.stringDictionary(from: json)
    }
}

// MARK: - Action kind

enum TurnGitActionKind: CaseIterable, Sendable {
    case initialize
    case syncNow
    case commit
    case push
    case commitAndPush
    case commitPushCreatePR
    case createPR
    case discardRuntimeChangesAndSync

    var title: String {
        switch self {
        case .initialize: return "Initialize Git"
        case .syncNow: return "Update"
        case .commit: return "Commit"
        case .push: return "Push"
        case .commitAndPush: return "Commit & Push"
        case .commitPushCreatePR: return "Commit, Push & PR"
        case .createPR: return "Create PR"
        case .discardRuntimeChangesAndSync: return "Discard Local Changes"
        }
    }

    var stackedActionIdentifier: String? {
        switch self {
        case .commit: return "commit"
        case .push: return "push"
        case .commitAndPush: return "commit_push"
        case .commitPushCreatePR: return "commit_push_pr"
        case .createPR: return "create_pr"
        case .initialize, .syncNow, .discardRuntimeChangesAndSync:
            return nil
        }
    }

    // Phases drive the toast title and checklist. Stacked actions emit live progress
    // events from the bridge; non-stacked actions advance phases manually from the view model.
    func plannedPhases(
        repoSync: GitRepoSyncResult?,
        hasCustomCommitMessage: Bool,
        willCreateFeatureBranch: Bool,
        hasWorkingTreeChanges: Bool? = nil
    ) -> [TurnGitActionPhase] {
        let branchPhases: [TurnGitActionPhase] = willCreateFeatureBranch ? [.branch] : []
        let shouldIncludeCommitPhases = hasWorkingTreeChanges ?? true
        let commitPhases: [TurnGitActionPhase] = hasCustomCommitMessage
            ? [.commit]
            : [.generatingCommit, .commit]

        switch self {
        case .initialize, .syncNow, .discardRuntimeChangesAndSync:
            return []
        case .commit:
            return branchPhases + commitPhases
        case .push:
            return [.push]
        case .commitAndPush:
            return branchPhases + (shouldIncludeCommitPhases ? commitPhases : []) + [.push]
        case .commitPushCreatePR:
            return branchPhases + (shouldIncludeCommitPhases ? commitPhases : []) + [.push, .createPR]
        case .createPR:
            let needsPush = repoSync.map { !$0.isDirty && (!$0.isPublishedToRemote || $0.aheadCount > 0 || $0.trackingBranch == nil) } ?? false
            return (needsPush ? [.push] : []) + [.createPR]
        }
    }

    // Single-step actions that don't run through the stacked action pipeline.
    var standaloneTitle: String? {
        switch self {
        case .initialize:
            return "Initializing Git..."
        case .syncNow:
            return "Updating..."
        case .discardRuntimeChangesAndSync:
            return "Discarding changes..."
        default:
            return nil
        }
    }
}

enum TurnGitActionPhase: String, CaseIterable, Sendable {
    case branch
    case generatingCommit
    case commit
    case push
    case createPR

    var activeTitle: String {
        switch self {
        case .branch: return "Preparing feature branch..."
        case .generatingCommit: return "Generating commit message..."
        case .commit: return "Committing..."
        case .push: return "Pushing..."
        case .createPR: return "Creating PR..."
        }
    }

    var pendingTitle: String {
        switch self {
        case .branch: return "Prepare feature branch"
        case .generatingCommit: return "Generate commit message"
        case .commit: return "Commit"
        case .push: return "Push"
        case .createPR: return "Create PR"
        }
    }

    var completedTitle: String {
        switch self {
        case .branch: return "Feature branch ready"
        case .generatingCommit: return "Commit message ready"
        case .commit: return "Committed"
        case .push: return "Pushed"
        case .createPR: return "PR created"
        }
    }

    // Maps the bridge `git/stackedAction/progress` `phase` field to a Swift case.
    init?(bridgePhase: String) {
        switch bridgePhase {
        case "branch": self = .branch
        case "commit": self = .commit
        case "push": self = .push
        case "createPR": self = .createPR
        default: return nil
        }
    }
}

enum TurnGitActionPhaseStatus: String, Sendable {
    case started
    case completed
    case skipped
}

struct TurnGitActionProgress: Equatable, Sendable {
    let action: TurnGitActionKind
    let plannedPhases: [TurnGitActionPhase]
    var currentPhase: TurnGitActionPhase?
    var completedPhases: Set<TurnGitActionPhase>
    var skippedPhases: Set<TurnGitActionPhase>

    init(
        action: TurnGitActionKind,
        plannedPhases: [TurnGitActionPhase],
        currentPhase: TurnGitActionPhase? = nil,
        completedPhases: Set<TurnGitActionPhase> = [],
        skippedPhases: Set<TurnGitActionPhase> = []
    ) {
        self.action = action
        self.plannedPhases = plannedPhases
        self.currentPhase = currentPhase
        self.completedPhases = completedPhases
        self.skippedPhases = skippedPhases
    }

    var activeTitle: String {
        if let currentPhase {
            return currentPhase.activeTitle
        }
        if let firstPending = plannedPhases.first(where: { !completedPhases.contains($0) && !skippedPhases.contains($0) }) {
            return firstPending.activeTitle
        }
        return action.title
    }

    func status(for phase: TurnGitActionPhase) -> PhaseDisplayStatus {
        if completedPhases.contains(phase) { return .completed }
        if skippedPhases.contains(phase) { return .skipped }
        if currentPhase == phase { return .active }
        return .pending
    }

    enum PhaseDisplayStatus {
        case pending
        case active
        case completed
        case skipped
    }
}

enum InlineCommitAndPushPhase: Sendable {
    case committing
    case pushing

    var title: String {
        switch self {
        case .committing:
            return "Committing..."
        case .pushing:
            return "Pushing..."
        }
    }
}

struct TurnGitActionSuccess: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case commit
        case push
        case pullRequest(url: String?)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String?

    var pullRequestURL: URL? {
        if case .pullRequest(let url) = kind, let url, let parsed = URL(string: url) {
            return parsed
        }
        return nil
    }
}

// MARK: - Alert types

struct TurnGitSyncAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let buttons: [TurnGitSyncAlertButton]

    init(title: String, message: String, action: TurnGitSyncAlertAction) {
        self.title = title
        self.message = message
        self.buttons = TurnGitSyncAlertButton.defaultButtons(for: action)
    }

    init(title: String, message: String, buttons: [TurnGitSyncAlertButton]) {
        self.title = title
        self.message = message
        self.buttons = buttons
    }
}

struct TurnGitSyncAlertButton: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let role: TurnGitSyncAlertButtonRole?
    let action: TurnGitSyncAlertAction

    // Keeps alert construction declarative while centralizing the button/action wiring.
    static func defaultButtons(for action: TurnGitSyncAlertAction) -> [TurnGitSyncAlertButton] {
        switch action {
        case .dismissOnly:
            return [
                TurnGitSyncAlertButton(title: "OK", role: .cancel, action: .dismissOnly)
            ]
        case .pullRebase:
            return [
                TurnGitSyncAlertButton(title: "Cancel", role: .cancel, action: .dismissOnly),
                TurnGitSyncAlertButton(title: "Pull & Rebase", role: nil, action: .pullRebase)
            ]
        case .continueGitBranchOperation:
            return [
                TurnGitSyncAlertButton(title: "Cancel", role: .cancel, action: .dismissOnly),
                TurnGitSyncAlertButton(title: "Continue", role: nil, action: .continueGitBranchOperation)
            ]
        case .commitAndContinueGitBranchOperation:
            return [
                TurnGitSyncAlertButton(title: "Cancel", role: .cancel, action: .dismissOnly),
                TurnGitSyncAlertButton(title: "Commit & Continue", role: nil, action: .commitAndContinueGitBranchOperation)
            ]
        case .discardRuntimeChanges:
            return [
                TurnGitSyncAlertButton(title: "Cancel", role: .cancel, action: .dismissOnly),
                TurnGitSyncAlertButton(title: "Discard Local Changes", role: .destructive, action: .discardRuntimeChanges)
            ]
        }
    }
}

enum TurnGitSyncAlertButtonRole: Sendable {
    case cancel
    case destructive
}

enum TurnGitSyncAlertAction: Equatable, Sendable {
    case dismissOnly
    case pullRebase
    case continueGitBranchOperation
    case commitAndContinueGitBranchOperation
    case discardRuntimeChanges
}
