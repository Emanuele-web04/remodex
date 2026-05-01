// FILE: CodexService+WorkspaceCheckpoints.swift
// Purpose: Talks to the Mac bridge's hidden Git checkpoint API for turn-scoped restore.
// Layer: Service extension
// Exports: WorkspaceCheckpointKind, WorkspaceCheckpointCaptureResult, WorkspaceCheckpointRestorePreview,
//   WorkspaceCheckpointRestoreApplyResult, CodexService checkpoint helpers
// Depends on: Foundation, CodexService, JSONValue

import Foundation

enum WorkspaceCheckpointKind: String, Sendable {
    case messageStart
    case turnStart
    case turnEnd
}

struct WorkspaceCheckpointCaptureResult: Sendable, Hashable {
    let repoRoot: String
    let checkpointRef: String
    let checkpointKind: String
    let commit: String?
    let threadId: String
    let turnId: String?
    let messageId: String?
    let copied: Bool?
    let sourceCheckpointRef: String?

    init(result: RPCObject) {
        repoRoot = result["repoRoot"]?.stringValue ?? ""
        checkpointRef = result["checkpointRef"]?.stringValue ?? ""
        checkpointKind = result["checkpointKind"]?.stringValue ?? ""
        commit = result["commit"]?.stringValue
        threadId = result["threadId"]?.stringValue ?? ""
        turnId = result["turnId"]?.stringValue
        messageId = result["messageId"]?.stringValue
        copied = result["copied"]?.boolValue
        sourceCheckpointRef = result["sourceCheckpointRef"]?.stringValue
    }
}

struct WorkspaceCheckpointRestorePreview: Sendable, Hashable {
    let canRestore: Bool
    let repoRoot: String
    let checkpointRef: String
    let commit: String?
    let affectedFiles: [String]
    let stagedFiles: [String]
    let untrackedFiles: [String]

    init(result: RPCObject) {
        canRestore = result["canRestore"]?.boolValue ?? false
        repoRoot = result["repoRoot"]?.stringValue ?? ""
        checkpointRef = result["checkpointRef"]?.stringValue ?? ""
        commit = result["commit"]?.stringValue
        affectedFiles = result["affectedFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        stagedFiles = result["stagedFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        untrackedFiles = result["untrackedFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

struct WorkspaceCheckpointRestoreConfirmation: Sendable, Hashable {
    fileprivate let checkpointRef: String
    fileprivate let expectedTargetCommit: String?

    fileprivate init(preview: WorkspaceCheckpointRestorePreview) {
        checkpointRef = preview.checkpointRef
        expectedTargetCommit = preview.commit
    }
}

extension WorkspaceCheckpointRestorePreview {
    func destructiveRestoreConfirmation(userConfirmed: Bool) -> WorkspaceCheckpointRestoreConfirmation? {
        guard userConfirmed, canRestore, !checkpointRef.isEmpty else {
            return nil
        }
        return WorkspaceCheckpointRestoreConfirmation(preview: self)
    }
}

struct WorkspaceCheckpointDiffResult: Sendable, Hashable {
    let repoRoot: String
    let fromCheckpointRef: String
    let toCheckpointRef: String
    let diff: String

    init(result: RPCObject) {
        repoRoot = result["repoRoot"]?.stringValue ?? ""
        fromCheckpointRef = result["fromCheckpointRef"]?.stringValue ?? ""
        toCheckpointRef = result["toCheckpointRef"]?.stringValue ?? ""
        diff = result["diff"]?.stringValue ?? ""
    }
}

struct WorkspaceCheckpointRestoreApplyResult: Sendable {
    let success: Bool
    let repoRoot: String
    let checkpointRef: String
    let backupCheckpointRef: String?
    let backupCommit: String?
    let restoredFiles: [String]
    let status: GitRepoSyncResult?

    init(result: RPCObject) {
        success = result["success"]?.boolValue ?? false
        repoRoot = result["repoRoot"]?.stringValue ?? ""
        checkpointRef = result["checkpointRef"]?.stringValue ?? ""
        backupCheckpointRef = result["backupCheckpointRef"]?.stringValue
        backupCommit = result["backupCommit"]?.stringValue
        restoredFiles = result["restoredFiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let statusObject = result["status"]?.objectValue {
            status = GitRepoSyncResult(from: statusObject)
        } else {
            status = nil
        }
    }
}

extension CodexService {
    // Starts pre-turn checkpointing early; sendTurnStart awaits it before the runtime can mutate files.
    @discardableResult
    func scheduleMessageStartWorkspaceCheckpointIfPossible(threadId: String, messageId: String) -> Task<Void, Never>? {
        guard normalizedCheckpointIdentifier(messageId) != nil else { return nil }
        return Task { @MainActor [weak self] in
            await self?.captureMessageStartWorkspaceCheckpointIfPossible(
                threadId: threadId,
                messageId: messageId
            )
        }
    }

    // Links the async pre-send snapshot to the real turn id without delaying turn/start completion.
    @discardableResult
    func scheduleMessageStartWorkspaceCheckpointCopyIfPossible(
        threadId: String,
        messageId: String,
        turnId: String,
        after messageStartCheckpointTask: Task<Void, Never>? = nil
    ) -> Task<Void, Never>? {
        guard normalizedCheckpointIdentifier(messageId) != nil,
              let normalizedTurnId = normalizedCheckpointIdentifier(turnId) else { return nil }
        let task = Task { @MainActor [weak self] in
            if let messageStartCheckpointTask {
                await messageStartCheckpointTask.value
            }
            await self?.copyMessageStartWorkspaceCheckpointIfPossible(
                threadId: threadId,
                messageId: messageId,
                turnId: turnId
            )
        }
        workspaceCheckpointCopyTaskByTurnID[normalizedTurnId] = task
        return task
    }

    // Ensures fast turn completion cannot diff before the message-id snapshot is aliased to turn-id.
    func awaitTurnStartWorkspaceCheckpointCopyIfNeeded(turnId: String) async {
        guard let normalizedTurnId = normalizedCheckpointIdentifier(turnId),
              let copyTask = workspaceCheckpointCopyTaskByTurnID.removeValue(forKey: normalizedTurnId) else {
            return
        }
        await copyTask.value
    }

    // Drops pending alias work for turns that will not produce a final workspace checkpoint.
    func discardTurnStartWorkspaceCheckpointCopyIfNeeded(turnId: String?) {
        guard let normalizedTurnId = normalizedCheckpointIdentifier(turnId),
              let copyTask = workspaceCheckpointCopyTaskByTurnID.removeValue(forKey: normalizedTurnId) else {
            return
        }
        copyTask.cancel()
    }

    // Best-effort pre-turn snapshot; normal chat send must not fail because checkpointing is unavailable.
    func captureMessageStartWorkspaceCheckpointIfPossible(threadId: String, messageId: String) async {
        guard normalizedCheckpointIdentifier(messageId) != nil else { return }
        do {
            _ = try await captureWorkspaceCheckpoint(
                threadId: threadId,
                messageId: messageId,
                kind: .messageStart,
                workingDirectory: gitWorkingDirectory(for: threadId)
            )
        } catch {
            debugRuntimeLog("workspace checkpoint messageStart skipped thread=\(threadId): \(error.localizedDescription)")
        }
    }

    // Best-effort alias from optimistic user-message id to the runtime turn id.
    func copyMessageStartWorkspaceCheckpointIfPossible(
        threadId: String,
        messageId: String,
        turnId: String
    ) async {
        guard normalizedCheckpointIdentifier(messageId) != nil,
              normalizedCheckpointIdentifier(turnId) != nil else { return }
        do {
            let result = try await copyMessageStartCheckpointToTurnStart(
                threadId: threadId,
                messageId: messageId,
                turnId: turnId,
                workingDirectory: gitWorkingDirectory(for: threadId)
            )
            if result.copied == false {
                await captureTurnStartWorkspaceCheckpointIfPossible(threadId: threadId, turnId: turnId)
            }
        } catch {
            debugRuntimeLog("workspace checkpoint turnStart alias skipped thread=\(threadId) turn=\(turnId): \(error.localizedDescription)")
        }
    }

    // Captures the settled workspace so future diffs can be derived from refs instead of streamed patch text.
    func captureTurnEndWorkspaceCheckpointIfPossible(threadId: String, turnId: String?) async {
        guard let turnId = normalizedCheckpointIdentifier(turnId) else { return }
        await awaitTurnStartWorkspaceCheckpointCopyIfNeeded(turnId: turnId)
        do {
            _ = try await captureWorkspaceCheckpoint(
                threadId: threadId,
                turnId: turnId,
                kind: .turnEnd,
                workingDirectory: gitWorkingDirectory(for: threadId)
            )
            let diffResult = try await diffWorkspaceCheckpointsForTurn(
                threadId: threadId,
                turnId: turnId,
                workingDirectory: gitWorkingDirectory(for: threadId)
            )
            recordWorkspaceCheckpointChangeSet(
                threadId: threadId,
                turnId: turnId,
                diff: diffResult.diff
            )
        } catch {
            debugRuntimeLog("workspace checkpoint turnEnd skipped thread=\(threadId) turn=\(turnId): \(error.localizedDescription)")
        }
    }

    // Fallback for remotely-started turns where there was no local optimistic message snapshot.
    func captureTurnStartWorkspaceCheckpointIfPossible(threadId: String, turnId: String?) async {
        guard let turnId = normalizedCheckpointIdentifier(turnId) else { return }
        do {
            _ = try await captureWorkspaceCheckpoint(
                threadId: threadId,
                turnId: turnId,
                kind: .turnStart,
                workingDirectory: gitWorkingDirectory(for: threadId)
            )
        } catch {
            debugRuntimeLog("workspace checkpoint turnStart skipped thread=\(threadId) turn=\(turnId): \(error.localizedDescription)")
        }
    }

    // Captures a hidden Git snapshot through the paired Mac. Failures are caller-managed.
    @discardableResult
    func captureWorkspaceCheckpoint(
        threadId: String,
        turnId: String? = nil,
        messageId: String? = nil,
        kind: WorkspaceCheckpointKind,
        workingDirectory: String?
    ) async throws -> WorkspaceCheckpointCaptureResult {
        var params = baseWorkspaceCheckpointParams(
            threadId: threadId,
            workingDirectory: workingDirectory
        )
        params["checkpointKind"] = .string(kind.rawValue)
        if let turnId = normalizedCheckpointIdentifier(turnId) {
            params["turnId"] = .string(turnId)
        }
        if let messageId = normalizedCheckpointIdentifier(messageId) {
            params["messageId"] = .string(messageId)
        }

        let response = try await sendRequest(method: "workspace/checkpointCapture", params: .object(params))
        return WorkspaceCheckpointCaptureResult(result: try checkpointResultObject(from: response))
    }

    // Reuses the pre-send snapshot once the runtime reports the real turn id.
    @discardableResult
    func copyMessageStartCheckpointToTurnStart(
        threadId: String,
        messageId: String,
        turnId: String,
        workingDirectory: String?
    ) async throws -> WorkspaceCheckpointCaptureResult {
        var params = baseWorkspaceCheckpointParams(
            threadId: threadId,
            workingDirectory: workingDirectory
        )
        params["sourceCheckpointKind"] = .string(WorkspaceCheckpointKind.messageStart.rawValue)
        params["sourceMessageId"] = .string(messageId)
        params["targetCheckpointKind"] = .string(WorkspaceCheckpointKind.turnStart.rawValue)
        params["targetTurnId"] = .string(turnId)

        let response = try await sendRequest(method: "workspace/checkpointCopy", params: .object(params))
        return WorkspaceCheckpointCaptureResult(result: try checkpointResultObject(from: response))
    }

    func previewWorkspaceCheckpointRestore(
        threadId: String,
        turnId: String,
        workingDirectory: String?
    ) async throws -> WorkspaceCheckpointRestorePreview {
        var params = baseWorkspaceCheckpointParams(threadId: threadId, workingDirectory: workingDirectory)
        params["targetCheckpointKind"] = .string(WorkspaceCheckpointKind.turnStart.rawValue)
        params["targetTurnId"] = .string(turnId)

        let response = try await sendRequest(method: "workspace/checkpointRestorePreview", params: .object(params))
        return WorkspaceCheckpointRestorePreview(result: try checkpointResultObject(from: response))
    }

    func diffWorkspaceCheckpointsForTurn(
        threadId: String,
        turnId: String,
        workingDirectory: String?
    ) async throws -> WorkspaceCheckpointDiffResult {
        var params = baseWorkspaceCheckpointParams(threadId: threadId, workingDirectory: workingDirectory)
        params["fromCheckpointKind"] = .string(WorkspaceCheckpointKind.turnStart.rawValue)
        params["fromTurnId"] = .string(turnId)
        params["toCheckpointKind"] = .string(WorkspaceCheckpointKind.turnEnd.rawValue)
        params["toTurnId"] = .string(turnId)

        let response = try await sendRequest(method: "workspace/checkpointDiff", params: .object(params))
        return WorkspaceCheckpointDiffResult(result: try checkpointResultObject(from: response))
    }

    func restoreWorkspaceCheckpoint(
        threadId: String,
        turnId: String,
        workingDirectory: String?,
        confirmation: WorkspaceCheckpointRestoreConfirmation
    ) async throws -> WorkspaceCheckpointRestoreApplyResult {
        var params = baseWorkspaceCheckpointParams(threadId: threadId, workingDirectory: workingDirectory)
        params["targetCheckpointRef"] = .string(confirmation.checkpointRef)
        params["targetTurnId"] = .string(turnId)
        if let expectedTargetCommit = confirmation.expectedTargetCommit {
            params["expectedTargetCommit"] = .string(expectedTargetCommit)
        }
        params["confirmDestructiveRestore"] = .bool(true)

        let response = try await sendRequest(method: "workspace/checkpointRestoreApply", params: .object(params))
        return WorkspaceCheckpointRestoreApplyResult(result: try checkpointResultObject(from: response))
    }

    private func baseWorkspaceCheckpointParams(
        threadId: String,
        workingDirectory: String?
    ) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
        ]
        if let workingDirectory = normalizedCheckpointIdentifier(workingDirectory) {
            params["cwd"] = .string(workingDirectory)
        }
        return params
    }

    private func checkpointResultObject(from response: RPCMessage) throws -> RPCObject {
        guard let result = response.result?.objectValue else {
            throw CodexServiceError.invalidResponse("Workspace checkpoint response was missing a result.")
        }
        return result
    }

    private func normalizedCheckpointIdentifier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
