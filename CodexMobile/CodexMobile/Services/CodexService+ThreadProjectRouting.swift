// FILE: CodexService+ThreadProjectRouting.swift
// Purpose: Keeps thread-to-project routing helpers separate from broader turn lifecycle code.
// Layer: Service Extension
// Exports: CodexService thread project routing helpers

import Foundation

extension CodexService {
    // Reuses the same runtime-readiness gate across every UI entry point that starts a new chat.
    func startThreadIfReady(
        preferredProjectPath: String? = nil,
        pendingComposerAction: CodexPendingThreadComposerAction? = nil,
        runtimeOverride: CodexThreadRuntimeOverride? = nil
    ) async throws -> CodexThread {
        guard isConnected else {
            throw CodexServiceError.invalidInput("Connect to runtime first.")
        }
        guard isInitialized else {
            throw CodexServiceError.invalidInput("Runtime is still initializing. Wait a moment and retry.")
        }

        if let pendingComposerAction {
            return try await startThread(
                preferredProjectPath: preferredProjectPath,
                pendingComposerAction: pendingComposerAction,
                runtimeOverride: runtimeOverride
            )
        }

        return try await startThread(
            preferredProjectPath: preferredProjectPath,
            runtimeOverride: runtimeOverride
        )
    }

    // Rebinds the existing chat to a new local project path so worktree handoff keeps the same thread id.
    @discardableResult
    func moveThreadToProjectPath(threadId: String, projectPath: String) async throws -> CodexThread {
        let normalizedThreadId = normalizedInterruptIdentifier(threadId) ?? threadId
        guard let normalizedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(projectPath) else {
            throw CodexServiceError.invalidInput("A valid project path is required.")
        }
        guard var currentThread = thread(for: normalizedThreadId) else {
            throw CodexServiceError.invalidInput("Thread not found.")
        }

        let previousThread = currentThread
        let previousAuthoritativePath = authoritativeProjectPathByThreadID[normalizedThreadId]
        let previousAssociatedManagedWorktreePath = associatedManagedWorktreePath(for: normalizedThreadId)
        let wasResumed = resumedThreadIDs.contains(normalizedThreadId)

        beginAuthoritativeProjectPathTransition(
            threadId: normalizedThreadId,
            projectPath: normalizedProjectPath
        )
        if CodexThread.projectIconSystemName(for: normalizedProjectPath) == "arrow.triangle.branch" {
            rememberAssociatedManagedWorktreePath(normalizedProjectPath, for: normalizedThreadId)
        }

        currentThread.cwd = normalizedProjectPath
        currentThread.updatedAt = Date()
        upsertThread(currentThread)
        activeThreadId = normalizedThreadId
        markThreadAsViewed(normalizedThreadId)
        rememberRepoRoot(normalizedProjectPath, forWorkingDirectory: normalizedProjectPath)

        resumedThreadIDs.remove(normalizedThreadId)
        do {
            let resumedThread = try await ensureThreadResumed(
                threadId: normalizedThreadId,
                force: true,
                preferredProjectPath: normalizedProjectPath
            )
            confirmAuthoritativeProjectPathIfNeeded(
                threadId: normalizedThreadId,
                projectPath: resumedThread?.normalizedProjectPath
            )
        } catch {
            if shouldAllowProjectRebindWithoutResume(error) {
                // Keep the local worktree switch even if the runtime has not materialized a rollout yet.
                // The immediate sync is safe because thread/read and thread/resume server merges
                // are both wrapped by applyingAuthoritativeProjectPath(...) until the runtime
                // confirms the new cwd.
                requestImmediateActiveThreadSync(threadId: normalizedThreadId)
                return thread(for: normalizedThreadId) ?? currentThread
            }

            upsertThread(previousThread)
            if let previousAuthoritativePath {
                authoritativeProjectPathByThreadID[normalizedThreadId] = previousAuthoritativePath
            } else {
                authoritativeProjectPathByThreadID.removeValue(forKey: normalizedThreadId)
            }
            rememberAssociatedManagedWorktreePath(previousAssociatedManagedWorktreePath, for: normalizedThreadId)
            if wasResumed {
                resumedThreadIDs.insert(normalizedThreadId)
            } else {
                resumedThreadIDs.remove(normalizedThreadId)
            }
            requestImmediateActiveThreadSync(threadId: normalizedThreadId)
            throw error
        }

        requestImmediateActiveThreadSync(threadId: normalizedThreadId)
        return thread(for: normalizedThreadId) ?? currentThread
    }

    func associatedManagedWorktreePath(for threadId: String?) -> String? {
        guard let normalizedThreadId = normalizedInterruptIdentifier(threadId) ?? normalizedThreadIdValue(threadId) else {
            return nil
        }

        return normalizedStoredProjectPath(associatedManagedWorktreePathByThreadID[normalizedThreadId])
    }

    func rememberAssociatedManagedWorktreePath(_ projectPath: String?, for threadId: String) {
        guard let normalizedThreadId = normalizedInterruptIdentifier(threadId) ?? normalizedThreadIdValue(threadId) else {
            return
        }

        let normalizedProjectPath = normalizedStoredProjectPath(projectPath)
        if associatedManagedWorktreePathByThreadID[normalizedThreadId] == normalizedProjectPath {
            return
        }

        if let normalizedProjectPath {
            associatedManagedWorktreePathByThreadID[normalizedThreadId] = normalizedProjectPath
        } else {
            associatedManagedWorktreePathByThreadID.removeValue(forKey: normalizedThreadId)
        }
        persistAssociatedManagedWorktreePaths()
    }

    func currentAuthoritativeProjectPath(for threadId: String?) -> String? {
        guard let normalizedThreadId = normalizedInterruptIdentifier(threadId) ?? normalizedThreadIdValue(threadId) else {
            return nil
        }

        return normalizedStoredProjectPath(authoritativeProjectPathByThreadID[normalizedThreadId])
    }

    func beginAuthoritativeProjectPathTransition(threadId: String, projectPath: String) {
        guard let normalizedThreadId = normalizedInterruptIdentifier(threadId) ?? normalizedThreadIdValue(threadId),
              let normalizedProjectPath = normalizedStoredProjectPath(projectPath) else {
            return
        }

        authoritativeProjectPathByThreadID[normalizedThreadId] = normalizedProjectPath
    }

    func clearAuthoritativeProjectPathTransition(threadId: String) {
        guard let normalizedThreadId = normalizedInterruptIdentifier(threadId) ?? normalizedThreadIdValue(threadId) else {
            return
        }

        authoritativeProjectPathByThreadID.removeValue(forKey: normalizedThreadId)
    }

    // Protects an in-flight handoff/fork rebind until the runtime confirms the same cwd.
    func applyingAuthoritativeProjectPath(
        to thread: CodexThread,
        treatAsServerState: Bool
    ) -> CodexThread {
        guard let authoritativePath = currentAuthoritativeProjectPath(for: thread.id) else {
            return thread
        }

        if thread.normalizedProjectPath == authoritativePath {
            if treatAsServerState, let normalizedThreadId = normalizedThreadIdValue(thread.id) {
                authoritativeProjectPathByThreadID.removeValue(forKey: normalizedThreadId)
            }
            return thread
        }

        var protectedThread = thread
        protectedThread.cwd = authoritativePath
        return protectedThread
    }

    // Lets tool-call telemetry repair stale local/main thread bindings once a managed worktree path is observed.
    @discardableResult
    func adoptManagedWorktreeProjectPathIfNeeded(threadId: String, projectPath: String?) -> Bool {
        guard let normalizedThreadId = normalizedInterruptIdentifier(threadId),
              let observedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(projectPath),
              var currentThread = thread(for: normalizedThreadId),
              currentThread.isManagedWorktreeProject,
              let currentProjectPath = currentThread.normalizedProjectPath else {
            return false
        }

        let canonicalCurrentPath = canonicalRepoIdentifier(for: currentProjectPath) ?? currentProjectPath
        let canonicalObservedPath = canonicalRepoIdentifier(for: observedProjectPath) ?? observedProjectPath
        guard canonicalCurrentPath == canonicalObservedPath,
              CodexThread.projectIconSystemName(for: canonicalObservedPath) == "arrow.triangle.branch" else {
            return false
        }

        if currentThread.normalizedProjectPath == canonicalObservedPath {
            confirmAuthoritativeProjectPathIfNeeded(threadId: normalizedThreadId, projectPath: canonicalObservedPath)
            return false
        }

        currentThread.cwd = canonicalObservedPath
        currentThread.updatedAt = Date()
        upsertThread(currentThread)
        rememberRepoRoot(canonicalObservedPath, forWorkingDirectory: observedProjectPath)
        confirmAuthoritativeProjectPathIfNeeded(threadId: normalizedThreadId, projectPath: canonicalObservedPath)
        if activeThreadId == normalizedThreadId {
            requestImmediateActiveThreadSync(threadId: normalizedThreadId)
        }
        return true
    }

    // Some local runtimes reject the immediate worktree rebind until a rollout exists
    // for the new cwd. Keep the local project switch instead of bouncing the user back.
    func shouldAllowProjectRebindWithoutResume(_ error: Error) -> Bool {
        let message: String
        if let serviceError = error as? CodexServiceError,
           case .rpcError(let rpcError) = serviceError {
            message = rpcError.message.lowercased()
        } else {
            message = error.localizedDescription.lowercased()
        }

        return message.contains("no rollout found")
            || message.contains("no rollout file found")
    }
}

private extension CodexService {
    func confirmAuthoritativeProjectPathIfNeeded(threadId: String, projectPath: String?) {
        guard let normalizedThreadId = normalizedInterruptIdentifier(threadId) ?? normalizedThreadIdValue(threadId),
              let authoritativeProjectPath = currentAuthoritativeProjectPath(for: normalizedThreadId),
              let normalizedProjectPath = normalizedStoredProjectPath(projectPath),
              normalizedProjectPath == authoritativeProjectPath else {
            return
        }

        authoritativeProjectPathByThreadID.removeValue(forKey: normalizedThreadId)
    }

    func persistAssociatedManagedWorktreePaths() {
        guard let encoded = try? encoder.encode(associatedManagedWorktreePathByThreadID) else {
            return
        }

        defaults.set(encoded, forKey: Self.associatedManagedWorktreePathsDefaultsKey)
    }

    func normalizedThreadIdValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalizedStoredProjectPath(_ value: String?) -> String? {
        CodexThreadStartProjectBinding.normalizedProjectPath(value)
    }
}
