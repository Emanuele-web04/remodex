// FILE: CodexService+AIChangeSets.swift
// Purpose: Tracks assistant-scoped patch ledgers and executes safe reverse-patch previews/applies.
// Layer: Service
// Exports: CodexService AI change-set APIs
// Depends on: AIChangeSetModels, CodexService transport, GitActionModels

import Foundation

enum AIChangeSetError: LocalizedError {
    case missingWorkingDirectory
    case missingPatch
    case bridgeError(code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .missingWorkingDirectory:
            return "The selected local folder is not available on this Mac."
        case .missingPatch:
            return "This response cannot be auto-reverted because no exact patch was captured."
        case .bridgeError(let code, let message):
            switch code {
            case "missing_patch":
                return "This response cannot be auto-reverted because no exact patch was captured."
            case "missing_working_directory":
                return "The selected local folder is not available on this Mac."
            default:
                return message ?? "Patch revert failed."
            }
        }
    }
}

extension CodexService {
    // Returns the change set associated with a specific assistant response, falling back to turn scope while streaming.
    func aiChangeSet(forAssistantMessage message: CodexMessage) -> AIChangeSet? {
        if let assistantMessageId = normalizedIdentifier(message.id),
           let changeSetId = aiChangeSetIDByAssistantMessageID[assistantMessageId],
           let changeSet = aiChangeSetsByID[changeSetId] {
            return changeSet
        }

        if let turnId = normalizedIdentifier(message.turnId),
           let changeSetId = aiChangeSetIDByTurnID[turnId] {
            return aiChangeSetsByID[changeSetId]
        }

        return nil
    }

    // Builds assistant-row button state while keeping repo-wide run safety in one place.
    func assistantRevertPresentation(
        for message: CodexMessage,
        workingDirectory: String?
    ) -> AssistantRevertPresentation? {
        guard message.role == .assistant else {
            return nil
        }

        guard let changeSet = aiChangeSet(forAssistantMessage: message) else {
            return nil
        }

        let repoBusy = hasActiveRun(in: changeSet.repoRoot ?? workingDirectory)
        let hasWorkingDirectory = normalizedWorkingDirectory(workingDirectory) != nil

        switch changeSet.status {
        case .ready:
            if repoBusy {
                return AssistantRevertPresentation(
                    title: "Revert changes",
                    isEnabled: false,
                    helperText: "Finish the active run in this repo before reverting."
                )
            }
            if !hasWorkingDirectory {
                return AssistantRevertPresentation(
                    title: "Cannot revert",
                    isEnabled: false,
                    helperText: "The selected local folder is not available on this Mac."
                )
            }
            return AssistantRevertPresentation(title: "Revert changes", isEnabled: true, helperText: nil)
        case .collecting:
            return AssistantRevertPresentation(
                title: "Revert changes",
                isEnabled: false,
                helperText: "This response is still collecting its final patch."
            )
        case .reverted:
            return AssistantRevertPresentation(title: "Reverted", isEnabled: false, helperText: nil)
        case .failed, .notRevertable:
            return AssistantRevertPresentation(
                title: "Cannot revert",
                isEnabled: false,
                helperText: changeSet.unsupportedReasons.first
            )
        }
    }

    // Blocks repo-scoped revert actions while any thread bound to the same repo is still running.
    func hasActiveRun(in workingDirectory: String?) -> Bool {
        guard let normalizedWorkingDirectory = normalizedWorkingDirectory(workingDirectory) else {
            return false
        }

        return threads.contains { thread in
            guard repositoriesOverlap(thread.gitWorkingDirectory, normalizedWorkingDirectory) else {
                return false
            }
            return runningThreadIDs.contains(thread.id)
                || activeTurnIdByThread[thread.id] != nil
                || protectedRunningFallbackThreadIDs.contains(thread.id)
        }
    }

    // Provides the latest finalized patch metadata for UI sheets and action handlers.
    func readyChangeSet(forAssistantMessage message: CodexMessage) -> AIChangeSet? {
        guard let changeSet = aiChangeSet(forAssistantMessage: message),
              changeSet.status == .ready else {
            return nil
        }
        return changeSet
    }

    // Asks the bridge to dry-run the reverse patch against the current working tree.
    func previewRevert(
        changeSet: AIChangeSet,
        workingDirectory: String
    ) async throws -> RevertPreviewResult {
        let normalizedWorkingDirectory = normalizedWorkingDirectory(workingDirectory)
        guard let normalizedWorkingDirectory else {
            throw AIChangeSetError.missingWorkingDirectory
        }
        guard !changeSet.forwardUnifiedPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIChangeSetError.missingPatch
        }

        let params: JSONValue = .object([
            "cwd": .string(normalizedWorkingDirectory),
            "forwardPatch": .string(changeSet.forwardUnifiedPatch),
        ])

        do {
            let response = try await sendRequest(method: "workspace/revertPatchPreview", params: params)
            guard let result = response.result?.objectValue else {
                throw AIChangeSetError.bridgeError(code: nil, message: "Invalid response from bridge.")
            }
            return RevertPreviewResult(from: result)
        } catch let error as CodexServiceError {
            throw bridgeError(from: error)
        }
    }

    // Reverse-applies the stored patch, then marks the change set as reverted only after success.
    func applyRevert(
        changeSet: AIChangeSet,
        workingDirectory: String
    ) async throws -> RevertApplyResult {
        let normalizedWorkingDirectory = normalizedWorkingDirectory(workingDirectory)
        guard let normalizedWorkingDirectory else {
            throw AIChangeSetError.missingWorkingDirectory
        }
        guard !changeSet.forwardUnifiedPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIChangeSetError.missingPatch
        }

        markRevertAttempt(changeSetId: changeSet.id)

        let params: JSONValue = .object([
            "cwd": .string(normalizedWorkingDirectory),
            "forwardPatch": .string(changeSet.forwardUnifiedPatch),
        ])

        do {
            let response = try await sendRequest(method: "workspace/revertPatchApply", params: params)
            guard let result = response.result?.objectValue else {
                throw AIChangeSetError.bridgeError(code: nil, message: "Invalid response from bridge.")
            }

            let applyResult = RevertApplyResult(from: result)
            rememberRepoRoot(applyResult.status?.repoRoot, forWorkingDirectory: normalizedWorkingDirectory)
            if applyResult.success {
                markChangeSetReverted(changeSetId: changeSet.id)
                appendSystemMessage(
                    threadId: changeSet.threadId,
                    text: "Reverted changes from this response.",
                    turnId: changeSet.turnId,
                    kind: .chat
                )
            } else {
                recordChangeSetError(
                    changeSetId: changeSet.id,
                    message: firstNonEmptyString(
                        applyResult.unsupportedReasons.first,
                        applyResult.conflicts.first?.message,
                        applyResult.stagedFiles.isEmpty ? nil : "Some targeted files have staged changes. Unstage them first to keep revert predictable."
                    ) ?? "Patch revert failed."
                )
            }

            return applyResult
        } catch let error as CodexServiceError {
            let mapped = bridgeError(from: error)
            recordChangeSetError(changeSetId: changeSet.id, message: mapped.localizedDescription)
            throw mapped
        }
    }
}

// ─── Ledger mutation helpers ───────────────────────────────────────

extension CodexService {
    // Tracks the authoritative turn-level unified diff for a response and upgrades fallback patches when possible.
    func recordTurnDiffChangeSet(threadId: String, turnId: String, diff: String) {
        recordChangeSetPatch(
            threadId: threadId,
            turnId: turnId,
            patch: diff,
            source: .turnDiff
        )
    }

    // Tracks a conservative single-patch fallback when no final turn diff is available.
    func recordFallbackFileChangePatch(threadId: String, turnId: String, patch: String) {
        recordChangeSetPatch(
            threadId: threadId,
            turnId: turnId,
            patch: patch,
            source: .fileChangeFallback
        )
    }

    // Links an assistant row to the turn-scoped change set once the canonical response message exists.
    func noteAssistantMessage(
        threadId: String,
        turnId: String?,
        assistantMessageId: String
    ) {
        guard let normalizedTurnId = normalizedIdentifier(turnId),
              let normalizedAssistantMessageId = normalizedIdentifier(assistantMessageId),
              let changeSetId = aiChangeSetIDByTurnID[normalizedTurnId],
              var changeSet = aiChangeSetsByID[changeSetId] else {
            return
        }

        changeSet.assistantMessageId = normalizedAssistantMessageId
        changeSet.repoRoot = changeSet.repoRoot ?? gitWorkingDirectory(for: threadId)
        aiChangeSetsByID[changeSetId] = changeSet
        aiChangeSetIDByAssistantMessageID[normalizedAssistantMessageId] = changeSetId
        finalizeChangeSetIfPossible(changeSetId: changeSetId)
        persistAIChangeSets()
    }

    // Finalizes the change set once the turn has finished, even if the diff arrives slightly later.
    func noteTurnFinished(turnId: String?) {
        guard let normalizedTurnId = normalizedIdentifier(turnId),
              let changeSetId = aiChangeSetIDByTurnID[normalizedTurnId] else {
            return
        }

        finalizeChangeSetIfPossible(changeSetId: changeSetId)
        persistAIChangeSets()
    }

    // Remembers canonical repo roots so repo-scoped safety checks stay consistent across sibling chat folders.
    func rememberRepoRoot(_ repoRoot: String?, forWorkingDirectory workingDirectory: String?) {
        guard let normalizedRepoRoot = normalizedWorkingDirectory(repoRoot) else {
            return
        }

        knownRepoRoots.insert(normalizedRepoRoot)
        repoRootByWorkingDirectory[normalizedRepoRoot] = normalizedRepoRoot

        if let normalizedWorkingDirectory = normalizedWorkingDirectory(workingDirectory) {
            repoRootByWorkingDirectory[normalizedWorkingDirectory] = normalizedRepoRoot
        }
    }

    // Preserves the exact diff body while guaranteeing the trailing newline git apply expects.
    func normalizedUnifiedPatchPayload(_ rawPatch: String) -> String? {
        guard !rawPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return rawPatch.hasSuffix("\n") ? rawPatch : rawPatch + "\n"
    }
}

// ─── Private helpers ───────────────────────────────────────────────

private extension CodexService {
    func recordChangeSetPatch(
        threadId: String,
        turnId: String,
        patch: String,
        source: AIChangeSetSource
    ) {
        let normalizedTurnId = turnId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTurnId.isEmpty,
              let normalizedPatch = normalizedUnifiedPatchPayload(patch) else {
            return
        }

        let analysis = AIUnifiedPatchParser.analyze(normalizedPatch)
        let changeSetId = aiChangeSetIDByTurnID[normalizedTurnId] ?? UUID().uuidString
        var changeSet = aiChangeSetsByID[changeSetId] ?? AIChangeSet(
            id: changeSetId,
            repoRoot: gitWorkingDirectory(for: threadId),
            threadId: threadId,
            turnId: normalizedTurnId,
            assistantMessageId: latestAssistantMessageId(for: threadId, turnId: normalizedTurnId),
            source: source
        )

        if source == .fileChangeFallback && changeSet.source == .turnDiff {
            return
        }

        if source == .fileChangeFallback {
            if changeSet.forwardUnifiedPatch == normalizedPatch {
                changeSet.fallbackPatchCount = max(changeSet.fallbackPatchCount, 1)
            } else {
                changeSet.fallbackPatchCount += 1
                if changeSet.forwardUnifiedPatch.isEmpty {
                    changeSet.forwardUnifiedPatch = normalizedPatch
                }
            }
        } else {
            changeSet.fallbackPatchCount = max(changeSet.fallbackPatchCount, 0)
        }

        changeSet.threadId = threadId
        changeSet.repoRoot = changeSet.repoRoot ?? gitWorkingDirectory(for: threadId)
        changeSet.assistantMessageId = changeSet.assistantMessageId ?? latestAssistantMessageId(for: threadId, turnId: normalizedTurnId)
        changeSet.source = source
        changeSet.forwardUnifiedPatch = normalizedPatch
        changeSet.patchHash = AIUnifiedPatchParser.hash(for: normalizedPatch)
        changeSet.fileChanges = analysis.fileChanges
        changeSet.unsupportedReasons = analysis.unsupportedReasons
        changeSet.status = .collecting

        aiChangeSetsByID[changeSetId] = changeSet
        aiChangeSetIDByTurnID[normalizedTurnId] = changeSetId
        if let assistantMessageId = changeSet.assistantMessageId {
            aiChangeSetIDByAssistantMessageID[assistantMessageId] = changeSetId
        }

        finalizeChangeSetIfPossible(changeSetId: changeSetId)
        persistAIChangeSets()
    }
    func finalizeChangeSetIfPossible(changeSetId: String) {
        guard var changeSet = aiChangeSetsByID[changeSetId] else {
            return
        }

        guard turnTerminalState(for: changeSet.turnId) != nil else {
            aiChangeSetsByID[changeSetId] = changeSet
            return
        }

        guard changeSet.status != .reverted else {
            return
        }

        changeSet.repoRoot = changeSet.repoRoot ?? gitWorkingDirectory(for: changeSet.threadId)
        changeSet.assistantMessageId = changeSet.assistantMessageId ?? latestAssistantMessageId(
            for: changeSet.threadId,
            turnId: changeSet.turnId
        )

        if changeSet.forwardUnifiedPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            changeSet.status = .notRevertable
            changeSet.unsupportedReasons = ["This response cannot be auto-reverted because no exact patch was captured."]
        } else if changeSet.source == .fileChangeFallback && changeSet.fallbackPatchCount > 1 {
            changeSet.status = .notRevertable
            changeSet.unsupportedReasons = ["This response emitted multiple file-change patches, so v1 cannot safely auto-revert it."]
        } else if !changeSet.unsupportedReasons.isEmpty || changeSet.fileChanges.isEmpty {
            changeSet.status = .notRevertable
        } else {
            changeSet.status = .ready
        }

        if changeSet.finalizedAt == nil {
            changeSet.finalizedAt = Date()
        }

        aiChangeSetsByID[changeSetId] = changeSet
        if let assistantMessageId = changeSet.assistantMessageId {
            aiChangeSetIDByAssistantMessageID[assistantMessageId] = changeSetId
        }
    }

    func persistAIChangeSets() {
        aiChangeSetPersistence.save(
            aiChangeSetsByID.values.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id < $1.id
            }
        )
    }

    func latestAssistantMessageId(for threadId: String, turnId: String) -> String? {
        messagesByThread[threadId]?.last(where: { message in
            message.role == .assistant && message.turnId == turnId
        })?.id
    }

    func gitWorkingDirectory(for threadId: String) -> String? {
        let workingDirectory = threads.first(where: { $0.id == threadId })?.gitWorkingDirectory
        return canonicalRepoIdentifier(for: workingDirectory) ?? workingDirectory
    }

    func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func bridgeError(from error: CodexServiceError) -> AIChangeSetError {
        switch error {
        case .disconnected:
            return .bridgeError(code: "disconnected", message: "Not connected to bridge.")
        case .rpcError(let rpcError):
            let errorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue
            return .bridgeError(code: errorCode, message: rpcError.message)
        default:
            return .bridgeError(code: nil, message: error.errorDescription)
        }
    }

    func markRevertAttempt(changeSetId: String) {
        guard var changeSet = aiChangeSetsByID[changeSetId] else { return }
        changeSet.revertMetadata.revertAttemptedAt = Date()
        changeSet.revertMetadata.lastRevertError = nil
        aiChangeSetsByID[changeSetId] = changeSet
        persistAIChangeSets()
    }

    func markChangeSetReverted(changeSetId: String) {
        guard var changeSet = aiChangeSetsByID[changeSetId] else { return }
        changeSet.status = .reverted
        changeSet.revertMetadata.revertedAt = Date()
        changeSet.revertMetadata.lastRevertError = nil
        aiChangeSetsByID[changeSetId] = changeSet
        persistAIChangeSets()
    }

    func recordChangeSetError(changeSetId: String, message: String) {
        guard var changeSet = aiChangeSetsByID[changeSetId] else { return }
        changeSet.revertMetadata.lastRevertError = message
        aiChangeSetsByID[changeSetId] = changeSet
        persistAIChangeSets()
    }

    func firstNonEmptyString(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    func canonicalRepoIdentifier(for workingDirectory: String?) -> String? {
        guard let normalizedWorkingDirectory = normalizedWorkingDirectory(workingDirectory) else {
            return nil
        }

        if let knownRoot = repoRootByWorkingDirectory[normalizedWorkingDirectory] {
            return knownRoot
        }

        let matchingRoot = knownRepoRoots
            .sorted { $0.count > $1.count }
            .first { isSameOrDescendantPath(normalizedWorkingDirectory, root: $0) }
        return matchingRoot ?? normalizedWorkingDirectory
    }

    func repositoriesOverlap(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let left = normalizedWorkingDirectory(lhs),
              let right = normalizedWorkingDirectory(rhs) else {
            return false
        }

        let canonicalLeft = canonicalRepoIdentifier(for: left) ?? left
        let canonicalRight = canonicalRepoIdentifier(for: right) ?? right
        if canonicalLeft == canonicalRight {
            return true
        }

        return isSameOrDescendantPath(left, root: right)
            || isSameOrDescendantPath(right, root: left)
            || isSameOrDescendantPath(canonicalLeft, root: canonicalRight)
            || isSameOrDescendantPath(canonicalRight, root: canonicalLeft)
    }

    func isSameOrDescendantPath(_ candidate: String, root: String) -> Bool {
        guard !candidate.isEmpty, !root.isEmpty else {
            return false
        }
        if candidate == root {
            return true
        }
        if root == "/" {
            return candidate.hasPrefix("/")
        }
        return candidate.hasPrefix(root + "/")
    }
}
