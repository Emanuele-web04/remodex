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

        let resolvedProjectPath = resolvedForkProjectPath(for: target, sourceThread: sourceThread)
        let sourceModelIdentifier = sourceThread.model?.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let response = try await sendRequestWithApprovalPolicyFallback(
                method: "thread/fork",
                baseParams: ["threadId": .string(normalizedSourceThreadId)],
                context: "minimal"
            )
            let forkedThread = try await handleThreadForkResponse(
                response,
                sourceThreadId: normalizedSourceThreadId,
                targetProjectPath: resolvedProjectPath,
                sourceModelIdentifier: (sourceModelIdentifier?.isEmpty == false) ? sourceModelIdentifier : nil
            )
            activeThreadId = forkedThread.id
            markThreadAsViewed(forkedThread.id)
            requestImmediateSync(threadId: forkedThread.id)
            return forkedThread
        } catch {
            if consumeUnsupportedThreadFork(error) {
                throw CodexServiceError.invalidInput(
                    "This Mac bridge does not support native thread forks yet. Update Remodex on your Mac and retry."
                )
            }
            throw error
        }
    }
}

private extension CodexService {
    static let forkHydrationRetryDelays: [UInt64] = [
        0,
        250_000_000,
        800_000_000,
    ]

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

    // Normalizes the fork response, records the new thread immediately, then hydrates it before the UI opens it.
    func handleThreadForkResponse(
        _ response: RPCMessage,
        sourceThreadId: String,
        targetProjectPath: String?,
        sourceModelIdentifier: String?
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
        if let targetProjectPath {
            decodedThread.cwd = targetProjectPath
        } else if decodedThread.normalizedProjectPath == nil {
            let responseProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(
                resultObject["cwd"]?.stringValue
            )
            decodedThread.cwd = responseProjectPath
        }

        let sourceThread = thread(for: sourceThreadId)
        if let sourceThread {
            if decodedThread.model == nil {
                decodedThread.model = sourceThread.model
            }
            if decodedThread.modelProvider == nil {
                decodedThread.modelProvider = sourceThread.modelProvider
            }
        }

        upsertThread(decodedThread, treatAsServerState: true)
        if let targetProjectPath {
            beginAuthoritativeProjectPathTransition(
                threadId: decodedThread.id,
                projectPath: targetProjectPath
            )
        }
        if let normalizedProjectPath = decodedThread.normalizedProjectPath,
           CodexThread.projectIconSystemName(for: normalizedProjectPath) == "arrow.triangle.branch" {
            rememberAssociatedManagedWorktreePath(normalizedProjectPath, for: decodedThread.id)
        }
        inheritThreadRuntimeOverrides(from: sourceThreadId, to: decodedThread.id)
        if let projectPath = decodedThread.gitWorkingDirectory {
            rememberRepoRoot(projectPath, forWorkingDirectory: projectPath)
        }

        let hydratedThread = try await hydrateForkedThread(
            threadId: decodedThread.id,
            targetProjectPath: targetProjectPath,
            sourceModelIdentifier: sourceModelIdentifier,
            sourceModelProvider: sourceThread?.modelProvider
        )
        if let hydratedThread {
            return hydratedThread
        }

        let fallbackThread = thread(for: decodedThread.id) ?? decodedThread
        return patchedForkThread(
            fallbackThread,
            targetProjectPath: targetProjectPath,
            sourceModelIdentifier: sourceModelIdentifier,
            sourceModelProvider: sourceThread?.modelProvider
        ) ?? fallbackThread
    }

    func hydrateForkedThread(
        threadId: String,
        targetProjectPath: String?,
        sourceModelIdentifier: String?,
        sourceModelProvider: String?
    ) async throws -> CodexThread? {
        for delay in Self.forkHydrationRetryDelays {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }

            let resumedThread: CodexThread?
            do {
                resumedThread = try await ensureThreadResumed(
                    threadId: threadId,
                    force: true,
                    preferredProjectPath: targetProjectPath,
                    modelIdentifierOverride: sourceModelIdentifier
                )
            } catch {
                if shouldAllowProjectRebindWithoutResume(error) {
                    continue
                }
                throw error
            }

            try await loadThreadHistoryIfNeeded(
                threadId: threadId,
                forceRefresh: true,
                markHydratedWhenNotMaterialized: false
            )

            if hydratedThreadIDs.contains(threadId) || !(messagesByThread[threadId] ?? []).isEmpty {
                return patchedForkThread(
                    resumedThread ?? thread(for: threadId),
                    targetProjectPath: targetProjectPath,
                    sourceModelIdentifier: sourceModelIdentifier,
                    sourceModelProvider: sourceModelProvider
                )
            }
        }

        return patchedForkThread(
            thread(for: threadId),
            targetProjectPath: targetProjectPath,
            sourceModelIdentifier: sourceModelIdentifier,
            sourceModelProvider: sourceModelProvider
        )
    }

    // Keeps fork semantics authoritative on the client even when the runtime resumes with stale cwd/model metadata.
    func patchedForkThread(
        _ thread: CodexThread?,
        targetProjectPath: String?,
        sourceModelIdentifier: String?,
        sourceModelProvider: String?
    ) -> CodexThread? {
        guard var thread else {
            return nil
        }

        var didPatch = false
        if let targetProjectPath,
           thread.normalizedProjectPath != targetProjectPath {
            thread.cwd = targetProjectPath
            didPatch = true
        }
        if thread.model == nil, let sourceModelIdentifier {
            thread.model = sourceModelIdentifier
            didPatch = true
        }
        if thread.modelProvider == nil, let sourceModelProvider {
            thread.modelProvider = sourceModelProvider
            didPatch = true
        }

        if didPatch {
            upsertThread(thread)
            if let normalizedProjectPath = thread.normalizedProjectPath,
               CodexThread.projectIconSystemName(for: normalizedProjectPath) == "arrow.triangle.branch" {
                rememberAssociatedManagedWorktreePath(normalizedProjectPath, for: thread.id)
            }
        }

        return thread
    }
}
