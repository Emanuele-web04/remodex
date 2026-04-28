// FILE: TurnViewModel+GitBranchWorktree.swift
// Purpose: Isolates branch/worktree routing and preflight flows from the main TurnViewModel file.
// Layer: View Model Extension
// Exports: TurnViewModel git branch/worktree operations

import Foundation

// Captures the repo state needed to build stable git-branch alerts without reading mutable view-model state mid-flow.
private struct GitBranchAlertState {
    let currentBranch: String
    let defaultBranch: String
    let isDirty: Bool
    let localOnlyCommitCount: Int
    let dirtyFiles: [GitChangedFile]

    private var onDefaultBranch: Bool {
        !currentBranch.isEmpty && currentBranch == defaultBranch
    }

    func alert(for operation: TurnViewModel.GitBranchUserOperation) -> TurnGitSyncAlert? {
        switch operation {
        case .create(let branchName):
            if isDirty {
                return TurnGitSyncAlert(
                    title: "Bring local changes to '\(branchName)'?",
                    message: newBranchDirtyAlertMessage(branchName: branchName),
                    buttons: [
                        TurnGitSyncAlertButton(title: "Cancel", role: .cancel, action: .dismissOnly),
                        TurnGitSyncAlertButton(
                            title: "Carry to New Branch",
                            role: nil,
                            action: .continueGitBranchOperation
                        ),
                        TurnGitSyncAlertButton(
                            title: "Commit, Create & Switch",
                            role: nil,
                            action: .commitAndContinueGitBranchOperation
                        )
                    ]
                )
            }

            if onDefaultBranch && localOnlyCommitCount > 0 {
                let commitLabel = localOnlyCommitCount == 1 ? "1 local commit" : "\(localOnlyCommitCount) local commits"
                var message = "\(defaultBranch) already has \(commitLabel) that are not on the remote. Creating '\(branchName)' now starts the new branch from the current HEAD, but those commits stay in \(defaultBranch)'s history."
                if isDirty {
                    message += " Uncommitted changes also stay in this working copy and will follow onto the new branch after checkout."
                }
                return TurnGitSyncAlert(
                    title: "Local commits stay on \(defaultBranch)",
                    message: message,
                    buttons: [
                        TurnGitSyncAlertButton(title: "Cancel", role: .cancel, action: .dismissOnly),
                        TurnGitSyncAlertButton(title: "Create Anyway", role: nil, action: .continueGitBranchOperation)
                    ]
                )
            }

            return nil

        case .createWorktree(let branchName, let baseBranch, let changeTransfer):
            return worktreeAlert(
                titleNoun: "'\(branchName)'",
                worktreeNoun: "the new worktree",
                baseBranch: baseBranch,
                changeTransfer: changeTransfer,
                createMessage: "Creating '\(branchName)' can %@ local changes only from the current branch. Switch the base branch to '\(currentBranch)' or clean up local changes before creating the worktree."
            )

        case .createManagedWorktree(let baseBranch, let changeTransfer):
            return worktreeAlert(
                titleNoun: "a managed worktree",
                worktreeNoun: "the managed worktree",
                baseBranch: baseBranch,
                changeTransfer: changeTransfer,
                createMessage: "Creating a managed worktree can %@ local changes only from the current branch. Switch the base branch to '\(currentBranch)' or clean up local changes before creating the worktree."
            )

        case .switchTo(let branchName):
            _ = branchName
            return nil
        }
    }

    // Reuses the same branch/base-branch warnings for standard and managed worktree creation.
    private func worktreeAlert(
        titleNoun: String,
        worktreeNoun: String,
        baseBranch: String,
        changeTransfer: GitWorktreeChangeTransferMode,
        createMessage: String
    ) -> TurnGitSyncAlert? {
        if isDirty && changeTransfer != .none && currentBranch != baseBranch {
            let transferVerb = changeTransfer.transferVerb ?? "move"
            return TurnGitSyncAlert(
                title: "\(transferVerb.capitalized) local changes from the current branch",
                message: createMessage.replacingOccurrences(of: "%@", with: transferVerb),
                action: .dismissOnly
            )
        }

        if onDefaultBranch && currentBranch == baseBranch && localOnlyCommitCount > 0 {
            let commitLabel = localOnlyCommitCount == 1 ? "1 local commit" : "\(localOnlyCommitCount) local commits"
            let dirtySuffix: String
            if isDirty, changeTransfer == .move {
                dirtySuffix = " Local changes will move into \(worktreeNoun); ignored files stay here."
            } else if isDirty, changeTransfer == .copy {
                dirtySuffix = " Local changes will also be copied into \(worktreeNoun); ignored files stay here."
            } else {
                dirtySuffix = ""
            }
            return TurnGitSyncAlert(
                title: "Local commits stay on \(defaultBranch)",
                message: "\(defaultBranch) already has \(commitLabel) that are not on the remote. Creating \(titleNoun) from \(baseBranch) starts from the current HEAD, but those commits stay in \(defaultBranch)'s history too.\(dirtySuffix)",
                buttons: [
                    TurnGitSyncAlertButton(title: "Cancel", role: .cancel, action: .dismissOnly),
                    TurnGitSyncAlertButton(title: "Create Anyway", role: nil, action: .continueGitBranchOperation)
                ]
            )
        }

        return nil
    }

    private func dirtyBranchAlertMessage(intro: String) -> String {
        guard !dirtyFiles.isEmpty else {
            return intro
        }

        let previewFiles = dirtyFiles.prefix(3).map(\.path)
        let fileLines = previewFiles.map { "• \($0)" }.joined(separator: "\n")
        let remainingCount = dirtyFiles.count - previewFiles.count
        let overflowLine = remainingCount > 0 ? "\n• +\(remainingCount) more files" : ""

        return "\(intro)\n\nFiles with local changes:\n\(fileLines)\(overflowLine)"
    }

    private func newBranchDirtyAlertMessage(branchName: String) -> String {
        let sourceBranch = currentBranch.isEmpty ? "the current branch" : currentBranch
        var intro = "You're creating '\(branchName)' from \(sourceBranch). Carry your local changes onto the new branch, or commit first and then create + switch."

        if !defaultBranch.isEmpty,
           sourceBranch == defaultBranch,
           localOnlyCommitCount > 0 {
            let commitLabel = localOnlyCommitCount == 1 ? "1 local commit" : "\(localOnlyCommitCount) local commits"
            intro = "\(defaultBranch) already has \(commitLabel) that are not on the remote. Those commits stay on \(defaultBranch)'s history. " + intro
        }

        return dirtyBranchAlertMessage(intro: intro)
    }
}

// Packages the deferred operation and its callbacks so alert-confirmed actions can resume from one place.
private struct PendingGitBranchOperationState {
    let operation: TurnViewModel.GitBranchUserOperation?
    let worktreeOpenHandler: ((GitCreateWorktreeResult) -> Void)?
    let managedWorktreeOpenHandler: ((GitCreateManagedWorktreeResult) -> Void)?
}

extension TurnViewModel {
    func refreshGitBranchTargets(codex: CodexService, workingDirectory: String?, threadID: String) {
        guard !isLoadingGitBranchTargets else { return }
        isLoadingGitBranchTargets = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingGitBranchTargets = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let result = try await gitService.branchesWithStatus()
                applyGitBranchTargets(result)
                if let status = result.status {
                    applyObservedGitRepoSync(
                        status,
                        codex: codex,
                        workingDirectory: workingDirectory,
                        threadID: threadID
                    )
                }
            } catch {
                // Silently fail — branches will just be empty.
            }
        }
    }

    // Adds preflight confirmations for dirty checkouts and the special case of local commits already on main.
    func requestCreateGitBranch(
        named rawName: String,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?
    ) {
        let branchName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else { return }

        let operation = GitBranchUserOperation.create(branchName)
        if let alert = gitBranchAlert(for: operation) {
            enqueuePendingGitBranchOperation(operation, alert: alert)
            return
        }

        createGitBranch(
            named: branchName,
            codex: codex,
            workingDirectory: workingDirectory,
            threadID: threadID,
            activeTurnID: activeTurnID
        )
    }

    // Creates a new branch, checks it out, and refreshes the visible branch targets.
    func createGitBranch(
        named rawName: String,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard activeTurnID == nil,
                  !codex.runningThreadIDs.contains(threadID),
                  !self.isRunningGitAction,
                  !self.isSwitchingGitBranch else { return }

            let branchName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branchName.isEmpty else { return }

            self.isSwitchingGitBranch = true
            defer { self.isSwitchingGitBranch = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let createResult = try await gitService.createBranch(name: branchName)
                currentGitBranch = createResult.branch
                if let status = createResult.status {
                    applyGitRepoSync(status)
                }
            } catch let error as GitActionsError {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Branch Creation Failed",
                    message: error.errorDescription ?? "Could not create branch.",
                    action: .dismissOnly
                )
                return
            } catch {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Branch Creation Failed",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
                return
            }

            do {
                let branchesResult = try await gitService.branchesWithStatus()
                applyGitBranchTargets(branchesResult)
                if let status = branchesResult.status {
                    applyGitRepoSync(status)
                }
            } catch {
                // The branch may already be created and checked out; keep the optimistic local state.
                availableGitBranchTargets = Array(Set(availableGitBranchTargets + [branchName])).sorted()
            }
        }
    }

    // Debounces repo status refreshes so live file-change streams can update the topbar safely.
    func scheduleGitStatusRefresh(codex: CodexService, workingDirectory: String?, threadID: String) {
        gitStatusRefreshTask?.cancel()
        gitStatusRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: gitStatusRefreshDebounceNanoseconds)
            } catch {
                return
            }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let result = try await gitService.status()
                applyObservedGitRepoSync(
                    result,
                    codex: codex,
                    workingDirectory: workingDirectory,
                    threadID: threadID
                )
            } catch {
                // Non-fatal: the next lifecycle refresh/manual action can recover the badge.
            }
        }
    }

    func requestSwitchGitBranch(
        to branch: String,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?
    ) {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { return }

        if gitBranchesCheckedOutElsewhere.contains(trimmedBranch) {
            gitSyncAlert = TurnGitSyncAlert(
                title: "Branch Switch Failed",
                message: "Cannot switch branches: this branch is already open in another worktree.",
                action: .dismissOnly
            )
            return
        }

        let operation = GitBranchUserOperation.switchTo(trimmedBranch)
        if let alert = gitBranchAlert(for: operation) {
            pendingGitBranchOperation = operation
            gitSyncAlert = alert
            return
        }

        switchGitBranch(
            to: trimmedBranch,
            codex: codex,
            workingDirectory: workingDirectory,
            threadID: threadID,
            activeTurnID: activeTurnID
        )
    }

    func requestCreateGitWorktree(
        named rawName: String,
        fromBaseBranch rawBaseBranch: String,
        changeTransfer: GitWorktreeChangeTransferMode = .move,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?,
        onOpenWorktree: @escaping (GitCreateWorktreeResult) -> Void
    ) {
        let branchName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseBranch = rawBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty, !baseBranch.isEmpty else { return }

        let operation = GitBranchUserOperation.createWorktree(
            branchName: branchName,
            baseBranch: baseBranch,
            changeTransfer: changeTransfer
        )
        if let alert = gitBranchAlert(for: operation) {
            enqueuePendingGitBranchOperation(
                operation,
                alert: alert,
                pendingWorktreeOpenHandler: onOpenWorktree
            )
            return
        }

        createGitWorktree(
            named: branchName,
            fromBaseBranch: baseBranch,
            changeTransfer: changeTransfer,
            codex: codex,
            workingDirectory: workingDirectory,
            threadID: threadID,
            activeTurnID: activeTurnID,
            onOpenWorktree: onOpenWorktree
        )
    }

    func requestCreateManagedGitWorktree(
        fromBaseBranch rawBaseBranch: String,
        changeTransfer: GitWorktreeChangeTransferMode = .move,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?,
        onOpenWorktree: @escaping (GitCreateManagedWorktreeResult) -> Void
    ) {
        let baseBranch = rawBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseBranch.isEmpty else { return }

        let operation = GitBranchUserOperation.createManagedWorktree(
            baseBranch: baseBranch,
            changeTransfer: changeTransfer
        )
        if let alert = gitBranchAlert(for: operation) {
            enqueuePendingGitBranchOperation(
                operation,
                alert: alert,
                pendingManagedGitWorktreeOpenHandler: onOpenWorktree
            )
            return
        }

        createManagedGitWorktree(
            fromBaseBranch: baseBranch,
            changeTransfer: changeTransfer,
            codex: codex,
            workingDirectory: workingDirectory,
            threadID: threadID,
            activeTurnID: activeTurnID,
            onOpenWorktree: onOpenWorktree
        )
    }

    func switchGitBranch(
        to branch: String,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard activeTurnID == nil,
                  !codex.runningThreadIDs.contains(threadID),
                  !self.isRunningGitAction,
                  !self.isSwitchingGitBranch else { return }

            if gitBranchesCheckedOutElsewhere.contains(branch) {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Branch Switch Failed",
                    message: "Cannot switch branches: this branch is already open in another worktree.",
                    action: .dismissOnly
                )
                return
            }

            self.isSwitchingGitBranch = true
            defer { self.isSwitchingGitBranch = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let result = try await gitService.checkout(branch: branch)
                currentGitBranch = result.currentBranch
                if let status = result.status {
                    applyGitRepoSync(status)
                }
            } catch let error as GitActionsError {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Branch Switch Failed",
                    message: error.errorDescription ?? "Could not switch branch.",
                    action: .dismissOnly
                )
            } catch {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Branch Switch Failed",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    func selectGitBaseBranch(_ branch: String) {
        selectedGitBaseBranch = branch
    }

    // Creates a managed worktree, then lets the caller route into the resulting thread.
    func createGitWorktree(
        named rawName: String,
        fromBaseBranch rawBaseBranch: String,
        changeTransfer: GitWorktreeChangeTransferMode = .move,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?,
        onOpenWorktree: @escaping (GitCreateWorktreeResult) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard activeTurnID == nil,
                  !codex.runningThreadIDs.contains(threadID),
                  !self.isRunningGitAction,
                  !self.isSwitchingGitBranch,
                  !self.isCreatingGitWorktree else { return }

            let branchName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseBranch = rawBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branchName.isEmpty, !baseBranch.isEmpty else { return }

            self.isCreatingGitWorktree = true
            defer { self.isCreatingGitWorktree = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let result = try await gitService.createWorktree(
                    name: branchName,
                    baseBranch: baseBranch,
                    changeTransfer: changeTransfer
                )
                let resolvedBranch = result.branch.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedWorktreePath = result.worktreePath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resolvedBranch.isEmpty, !resolvedWorktreePath.isEmpty else {
                    throw GitActionsError.invalidResponse
                }

                availableGitBranchTargets = Array(Set(availableGitBranchTargets + [resolvedBranch])).sorted()
                gitWorktreePathsByBranch[resolvedBranch] = resolvedWorktreePath
                gitBranchesCheckedOutElsewhere.insert(resolvedBranch)
                onOpenWorktree(result)
            } catch let error as GitActionsError {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Worktree Creation Failed",
                    message: error.errorDescription ?? "Could not create worktree.",
                    action: .dismissOnly
                )
            } catch {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Worktree Creation Failed",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    // Creates a detached managed worktree, then lets the caller route into the resulting thread.
    func createManagedGitWorktree(
        fromBaseBranch rawBaseBranch: String,
        changeTransfer: GitWorktreeChangeTransferMode = .move,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?,
        onOpenWorktree: @escaping (GitCreateManagedWorktreeResult) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard activeTurnID == nil,
                  !codex.runningThreadIDs.contains(threadID),
                  !self.isRunningGitAction,
                  !self.isSwitchingGitBranch,
                  !self.isCreatingGitWorktree else { return }

            let baseBranch = rawBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseBranch.isEmpty else { return }

            self.isCreatingGitWorktree = true
            defer { self.isCreatingGitWorktree = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
            do {
                let result = try await gitService.createManagedWorktree(
                    baseBranch: baseBranch,
                    changeTransfer: changeTransfer
                )
                let resolvedWorktreePath = result.worktreePath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resolvedWorktreePath.isEmpty else {
                    throw GitActionsError.invalidResponse
                }

                onOpenWorktree(result)
            } catch let error as GitActionsError {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Worktree Creation Failed",
                    message: error.errorDescription ?? "Could not create worktree.",
                    action: .dismissOnly
                )
            } catch {
                gitSyncAlert = TurnGitSyncAlert(
                    title: "Worktree Creation Failed",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    func worktreePathForCheckedOutElsewhereBranch(_ branch: String) -> String? {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty,
              gitBranchesCheckedOutElsewhere.contains(trimmedBranch) else {
            return nil
        }

        return gitWorktreePathsByBranch[trimmedBranch]
    }

    // Removes a failed managed worktree from the optimistic local branch cache until the next refresh arrives.
    func forgetGitWorktree(branch: String, worktreePath: String?) {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { return }

        availableGitBranchTargets.removeAll { $0 == trimmedBranch }
        gitBranchesCheckedOutElsewhere.remove(trimmedBranch)

        let trimmedPath = worktreePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedPath, !trimmedPath.isEmpty {
            let normalizedPath = TurnWorktreeRouting.comparableProjectPath(trimmedPath)
            if let existingPath = gitWorktreePathsByBranch[trimmedBranch],
               TurnWorktreeRouting.comparableProjectPath(existingPath) != normalizedPath {
                return
            }
        }

        gitWorktreePathsByBranch.removeValue(forKey: trimmedBranch)
    }

    func applyGitRepoSync(_ result: GitRepoSyncResult) {
        gitRepoSync = result
        guard result.isGitRepository else {
            currentGitBranch = ""
            availableGitBranchTargets = []
            gitBranchesCheckedOutElsewhere = []
            gitWorktreePathsByBranch = [:]
            gitLocalCheckoutPath = nil
            gitDefaultBranch = ""
            selectedGitBaseBranch = ""
            return
        }

        if let branch = result.currentBranch, !branch.isEmpty {
            currentGitBranch = branch
        }
    }

    // Keeps repo totals fresh and resets the per-chat sidebar badge after a manual push.
    func handleSuccessfulPush(
        _ result: GitPushResult,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String
    ) {
        if let status = result.status {
            applyGitRepoSync(status)
        }

        codex.appendHiddenPushResetMarkers(
            threadId: threadID,
            workingDirectory: workingDirectory,
            branch: result.branch,
            remote: result.remote
        )
    }

    func dismissGitSyncAlert() {
        clearPendingGitBranchOperationState()
    }

    func confirmGitSyncAlertAction(
        _ alertAction: TurnGitSyncAlertAction,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?
    ) {
        let pendingOperationState = capturePendingGitBranchOperationState()
        clearPendingGitBranchOperationState()

        switch alertAction {
        case .dismissOnly:
            return
        case .pullRebase:
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard activeTurnID == nil,
                      !codex.runningThreadIDs.contains(threadID),
                      !self.isRunningGitAction,
                      !self.isSwitchingGitBranch else { return }

                self.runningGitAction = .syncNow
                defer { self.runningGitAction = nil }

                let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
                do {
                    let result = try await gitService.pull()
                    if let status = result.status {
                        applyGitRepoSync(status)
                    }
                } catch {
                    gitSyncAlert = TurnGitSyncAlert(
                        title: "Pull Failed",
                        message: error.localizedDescription,
                        action: .dismissOnly
                    )
                }
            }
        case .continueGitBranchOperation:
            continueGitBranchOperation(
                pendingOperationState,
                codex: codex,
                workingDirectory: workingDirectory,
                threadID: threadID,
                activeTurnID: activeTurnID
            )
        case .commitAndContinueGitBranchOperation:
            guard pendingOperationState.operation != nil else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard activeTurnID == nil,
                      !codex.runningThreadIDs.contains(threadID),
                      !self.isRunningGitAction,
                      !self.isSwitchingGitBranch,
                      !self.isCreatingGitWorktree else { return }

                self.runningGitAction = .commit
                defer { self.runningGitAction = nil }

                let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
                do {
                    _ = try await gitService.commit(message: "WIP before switching branches")
                    if let statusAfter = try? await gitService.status() {
                        applyGitRepoSync(statusAfter)
                    }

                    continueGitBranchOperation(
                        pendingOperationState,
                        codex: codex,
                        workingDirectory: workingDirectory,
                        threadID: threadID,
                        activeTurnID: activeTurnID
                    )
                } catch {
                    gitSyncAlert = TurnGitSyncAlert(
                        title: "Commit Failed",
                        message: error.localizedDescription,
                        action: .dismissOnly
                    )
                }
            }
        case .discardRuntimeChanges:
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard activeTurnID == nil,
                      !codex.runningThreadIDs.contains(threadID),
                      !self.isRunningGitAction,
                      !self.isSwitchingGitBranch,
                      !self.isCreatingGitWorktree else { return }

                self.runningGitAction = .discardRuntimeChangesAndSync
                defer { self.runningGitAction = nil }

                let gitService = GitActionsService(codex: codex, workingDirectory: workingDirectory)
                do {
                    let result = try await gitService.resetToRemote()
                    if let status = result.status {
                        applyGitRepoSync(status)
                    }
                } catch {
                    gitSyncAlert = TurnGitSyncAlert(
                        title: "Discard Failed",
                        message: error.localizedDescription,
                        action: .dismissOnly
                    )
                }
            }
        }
    }

    func gitBranchAlert(for operation: GitBranchUserOperation) -> TurnGitSyncAlert? {
        let alertState = GitBranchAlertState(
            currentBranch: currentGitBranch.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultBranch: gitDefaultBranch.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirty: gitRepoSync?.isDirty ?? false,
            localOnlyCommitCount: gitRepoSync?.localOnlyCommitCount ?? 0,
            dirtyFiles: gitRepoSync?.files ?? []
        )
        return alertState.alert(for: operation)
    }

    // Applies branch metadata without overwriting an explicit PR base the user already chose.
    func applyGitBranchTargets(_ result: GitBranchesWithStatusResult) {
        availableGitBranchTargets = result.branches
        gitBranchesCheckedOutElsewhere = result.branchesCheckedOutElsewhere
        gitWorktreePathsByBranch = result.worktreePathByBranch
        gitLocalCheckoutPath = CodexThreadStartProjectBinding.normalizedProjectPath(result.localCheckoutPath)
        if let current = result.currentBranch, !current.isEmpty {
            currentGitBranch = current
        }
        if let defaultBranch = result.defaultBranch, !defaultBranch.isEmpty {
            gitDefaultBranch = defaultBranch
            let currentSelectedBaseBranch = selectedGitBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            let localDefaultBranch = remodexSelectableDefaultBranch(
                defaultBranch: defaultBranch,
                availableGitBranchTargets: result.branches
            ) ?? ""
            let isValidSelectedBaseBranch = currentSelectedBaseBranch.isEmpty
                || result.branches.contains(currentSelectedBaseBranch)

            if !isValidSelectedBaseBranch {
                selectedGitBaseBranch = localDefaultBranch
            } else if currentSelectedBaseBranch.isEmpty {
                selectedGitBaseBranch = localDefaultBranch
            }
        }
    }
}

private extension TurnViewModel {
    // Detects push-like repo transitions that happen outside the toolbar callback path.
    func applyObservedGitRepoSync(
        _ result: GitRepoSyncResult,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String
    ) {
        let previousSync = gitRepoSync
        applyGitRepoSync(result)

        guard let previousSync else {
            return
        }

        let branchStayedStable = previousSync.currentBranch == result.currentBranch
        let didClearAheadQueue = previousSync.aheadCount > 0 && result.aheadCount == 0
        guard branchStayedStable, didClearAheadQueue else {
            return
        }

        codex.appendHiddenPushResetMarkers(
            threadId: threadID,
            workingDirectory: workingDirectory,
            branch: result.currentBranch ?? "",
            remote: trackingRemoteName(from: result.trackingBranch)
        )
    }

    // Runs the deferred branch/worktree action after an alert-confirmed preflight step.
    func continueGitBranchOperation(
        _ pendingOperationState: PendingGitBranchOperationState,
        codex: CodexService,
        workingDirectory: String?,
        threadID: String,
        activeTurnID: String?
    ) {
        guard let pendingBranchOperation = pendingOperationState.operation else { return }

        switch pendingBranchOperation {
        case .create(let branchName):
            createGitBranch(
                named: branchName,
                codex: codex,
                workingDirectory: workingDirectory,
                threadID: threadID,
                activeTurnID: activeTurnID
            )
        case .switchTo(let branchName):
            switchGitBranch(
                to: branchName,
                codex: codex,
                workingDirectory: workingDirectory,
                threadID: threadID,
                activeTurnID: activeTurnID
            )
        case .createWorktree(let branchName, let baseBranch, let changeTransfer):
            guard let pendingWorktreeOpenHandler = pendingOperationState.worktreeOpenHandler else { return }
            createGitWorktree(
                named: branchName,
                fromBaseBranch: baseBranch,
                changeTransfer: changeTransfer,
                codex: codex,
                workingDirectory: workingDirectory,
                threadID: threadID,
                activeTurnID: activeTurnID,
                onOpenWorktree: pendingWorktreeOpenHandler
            )
        case .createManagedWorktree(let baseBranch, let changeTransfer):
            guard let pendingManagedGitWorktreeOpenHandler = pendingOperationState.managedWorktreeOpenHandler else { return }
            createManagedGitWorktree(
                fromBaseBranch: baseBranch,
                changeTransfer: changeTransfer,
                codex: codex,
                workingDirectory: workingDirectory,
                threadID: threadID,
                activeTurnID: activeTurnID,
                onOpenWorktree: pendingManagedGitWorktreeOpenHandler
            )
        }
    }

    func trackingRemoteName(from trackingBranch: String?) -> String? {
        guard let trackingBranch else {
            return nil
        }

        let trimmed = trackingBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
    }

    // Queues the pending branch/worktree operation so alert-confirmed actions can resume the exact same request.
    func enqueuePendingGitBranchOperation(
        _ operation: GitBranchUserOperation,
        alert: TurnGitSyncAlert,
        pendingWorktreeOpenHandler: ((GitCreateWorktreeResult) -> Void)? = nil,
        pendingManagedGitWorktreeOpenHandler: ((GitCreateManagedWorktreeResult) -> Void)? = nil
    ) {
        pendingGitBranchOperation = operation
        self.pendingGitWorktreeOpenHandler = pendingWorktreeOpenHandler
        self.pendingManagedGitWorktreeOpenHandler = pendingManagedGitWorktreeOpenHandler
        gitSyncAlert = alert
    }

    func capturePendingGitBranchOperationState() -> PendingGitBranchOperationState {
        PendingGitBranchOperationState(
            operation: pendingGitBranchOperation,
            worktreeOpenHandler: pendingGitWorktreeOpenHandler,
            managedWorktreeOpenHandler: pendingManagedGitWorktreeOpenHandler
        )
    }

    func clearPendingGitBranchOperationState() {
        gitSyncAlert = nil
        pendingGitBranchOperation = nil
        pendingGitWorktreeOpenHandler = nil
        pendingManagedGitWorktreeOpenHandler = nil
    }
}
