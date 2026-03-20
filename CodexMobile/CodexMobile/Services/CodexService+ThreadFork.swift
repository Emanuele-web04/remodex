// FILE: CodexService+ThreadFork.swift
// Purpose: Owns native thread fork requests and keeps conversation branching separate from handoff/worktree routing.
// Layer: Service
// Exports: CodexService thread fork APIs
// Depends on: Foundation, CodexThread, JSONValue

import Foundation

extension CodexService {
    // Reuses the standard runtime-readiness gate before calling native thread/fork.
    func forkThreadIfReady(
        from sourceThreadId: String,
        target: CodexThreadForkTarget
    ) async throws -> CodexThread {
        guard isConnected else {
            throw CodexServiceError.invalidInput("Connect to runtime first.")
        }
        guard isInitialized else {
            throw CodexServiceError.invalidInput("Runtime is still initializing. Wait a moment and retry.")
        }

        return try await forkThread(from: sourceThreadId, target: target)
    }

    // Forks the existing conversation into a brand-new thread while preserving the source thread.
    @discardableResult
    func forkThread(
        from sourceThreadId: String,
        target: CodexThreadForkTarget
    ) async throws -> CodexThread {
        let normalizedSourceThreadId = normalizedInterruptIdentifier(sourceThreadId) ?? sourceThreadId
        guard !normalizedSourceThreadId.isEmpty else {
            throw CodexServiceError.invalidInput("A source thread id is required.")
        }

        guard let sourceThread = thread(for: normalizedSourceThreadId) else {
            throw CodexServiceError.invalidInput("Thread not found.")
        }

        let sourceRuntimeOverride = threadRuntimeOverride(for: normalizedSourceThreadId)
        let resolvedProjectPath = resolvedForkProjectPath(for: target, sourceThread: sourceThread)
        let preferredModelIdentifier = sourceThread.model ?? runtimeModelIdentifierForTurn()
        let serviceTier = sourceRuntimeOverride?.overridesServiceTier == true
            ? sourceRuntimeOverride?.serviceTierRawValue
            : runtimeServiceTierForTurn(threadId: normalizedSourceThreadId)
        var includesServiceTier = serviceTier != nil
        var includesSandbox = true
        var usesMinimalForkParams = false

        while true {
            let params = makeThreadForkParams(
                sourceThreadId: normalizedSourceThreadId,
                sourceThread: sourceThread,
                targetProjectPath: resolvedProjectPath,
                serviceTier: includesServiceTier ? serviceTier : nil,
                includeSandbox: includesSandbox,
                usesMinimalForkParams: usesMinimalForkParams
            )

            do {
                let response = try await sendRequestWithApprovalPolicyFallback(
                    method: "thread/fork",
                    baseParams: params,
                    context: includesSandbox ? "sandbox" : "minimal"
                )
                let forkedThread = try await handleThreadForkResponse(
                    response,
                    sourceThreadId: normalizedSourceThreadId,
                    fallbackProjectPath: resolvedProjectPath,
                    preferredModelIdentifier: preferredModelIdentifier,
                    usesPostForkResumeOverrides: usesMinimalForkParams
                )
                return forkedThread
            } catch {
                if consumeUnsupportedThreadFork(error) {
                    throw CodexServiceError.invalidInput(
                        "This Mac bridge does not support native thread forks yet. Update Remodex on your Mac and retry."
                    )
                }
                if consumeUnsupportedThreadForkOverrides(error, usesMinimalForkParams: &usesMinimalForkParams) {
                    includesServiceTier = false
                    includesSandbox = false
                    continue
                }
                if consumeUnsupportedServiceTier(error, includesServiceTier: &includesServiceTier) {
                    continue
                }
                if includesSandbox, shouldFallbackFromSandboxPolicy(error) {
                    includesSandbox = false
                    continue
                }
                throw error
            }
        }
    }
}

private extension CodexService {
    // Resolves only service-level fork targets; product-level "Fork into local" is resolved in the UI first.
    func resolvedForkProjectPath(
        for target: CodexThreadForkTarget,
        sourceThread: CodexThread
    ) -> String? {
        switch target {
        case .currentProject:
            return sourceThread.gitWorkingDirectory
        case .projectPath(let rawPath):
            return CodexThreadStartProjectBinding.normalizedProjectPath(rawPath)
        }
    }

    // Builds the fork payload without mixing in handoff-specific state transitions.
    func makeThreadForkParams(
        sourceThreadId: String,
        sourceThread: CodexThread,
        targetProjectPath: String?,
        serviceTier: String?,
        includeSandbox: Bool,
        usesMinimalForkParams: Bool
    ) -> RPCObject {
        var params: RPCObject = [
            "threadId": .string(sourceThreadId),
        ]

        if usesMinimalForkParams {
            return params
        }

        if let targetProjectPath {
            params["cwd"] = .string(targetProjectPath)
        }
        if let modelIdentifier = sourceThread.model ?? runtimeModelIdentifierForTurn() {
            params["model"] = .string(modelIdentifier)
        }
        if let modelProvider = sourceThread.modelProvider {
            params["modelProvider"] = .string(modelProvider)
        }
        if let serviceTier {
            params["serviceTier"] = .string(serviceTier)
        }
        if includeSandbox {
            params["sandbox"] = .string(selectedAccessMode.sandboxLegacyValue)
        }

        return params
    }

    // Normalizes the fork response, records the new thread immediately, then hydrates it best-effort.
    func handleThreadForkResponse(
        _ response: RPCMessage,
        sourceThreadId: String,
        fallbackProjectPath: String?,
        preferredModelIdentifier: String?,
        usesPostForkResumeOverrides: Bool
    ) async throws -> CodexThread {
        guard let resultObject = response.result?.objectValue,
              let threadValue = resultObject["thread"],
              var decodedThread = decodeModel(CodexThread.self, from: threadValue) else {
            throw CodexServiceError.invalidResponse("thread/fork response missing thread")
        }

        let forkCreationDate = Date()
        decodedThread.syncState = .live
        decodedThread.forkedFromThreadId = decodedThread.forkedFromThreadId
            ?? normalizedInterruptIdentifier(sourceThreadId)
            ?? sourceThreadId
        if decodedThread.createdAt == nil {
            decodedThread.createdAt = forkCreationDate
        }
        if decodedThread.updatedAt == nil {
            decodedThread.updatedAt = forkCreationDate
        }
        if usesPostForkResumeOverrides, let fallbackProjectPath {
            decodedThread.cwd = fallbackProjectPath
        } else if decodedThread.normalizedProjectPath == nil {
            let responseProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(
                resultObject["cwd"]?.stringValue
            )
            decodedThread.cwd = responseProjectPath ?? fallbackProjectPath
        }

        upsertThread(decodedThread)
        inheritThreadRuntimeOverrides(from: sourceThreadId, to: decodedThread.id)
        if let projectPath = decodedThread.gitWorkingDirectory {
            rememberRepoRoot(projectPath, forWorkingDirectory: projectPath)
        }

        activeThreadId = decodedThread.id
        markThreadAsViewed(decodedThread.id)
        requestImmediateSync(threadId: decodedThread.id)

        do {
            let resumedThread = try await ensureThreadResumed(
                threadId: decodedThread.id,
                force: true,
                preferredProjectPath: usesPostForkResumeOverrides ? fallbackProjectPath : nil,
                modelIdentifierOverride: usesPostForkResumeOverrides ? preferredModelIdentifier : nil
            )
            return resumedThread ?? thread(for: decodedThread.id) ?? decodedThread
        } catch {
            // If hydration fails after `thread/fork` succeeded, keep the created thread instead of
            // treating the whole fork as failed. Sync/resume can recover the richer payload later.
            return thread(for: decodedThread.id) ?? decodedThread
        }
    }
}
