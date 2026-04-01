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
        let wasResumed = resumedThreadIDs.contains(normalizedThreadId)

        currentThread.cwd = normalizedProjectPath
        currentThread.updatedAt = Date()
        upsertThread(currentThread)
        activeThreadId = normalizedThreadId
        markThreadAsViewed(normalizedThreadId)
        rememberRepoRoot(normalizedProjectPath, forWorkingDirectory: normalizedProjectPath)

        resumedThreadIDs.remove(normalizedThreadId)
        do {
            _ = try await ensureThreadResumed(threadId: normalizedThreadId, force: true)
        } catch {
            upsertThread(previousThread)
            if wasResumed {
                resumedThreadIDs.insert(normalizedThreadId)
            } else {
                resumedThreadIDs.remove(normalizedThreadId)
            }
            requestImmediateActiveThreadSync(threadId: normalizedThreadId)
            throw error
        }

        // Keep the local handoff authoritative even if the resume payload is sparse or stale.
        if var resumedThread = thread(for: normalizedThreadId),
           resumedThread.normalizedProjectPath != normalizedProjectPath {
            resumedThread.cwd = normalizedProjectPath
            resumedThread.updatedAt = max(resumedThread.updatedAt ?? .distantPast, Date())
            upsertThread(resumedThread)
        }

        requestImmediateActiveThreadSync(threadId: normalizedThreadId)
        return thread(for: normalizedThreadId) ?? currentThread
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
            return false
        }

        currentThread.cwd = canonicalObservedPath
        currentThread.updatedAt = Date()
        upsertThread(currentThread)
        rememberRepoRoot(canonicalObservedPath, forWorkingDirectory: observedProjectPath)
        if activeThreadId == normalizedThreadId {
            requestImmediateActiveThreadSync(threadId: normalizedThreadId)
        }
        return true
    }
}
