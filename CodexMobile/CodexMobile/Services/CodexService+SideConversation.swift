// FILE: CodexService+SideConversation.swift
// Purpose: Orchestrates native Codex `/side` as an ephemeral fork with a hidden history boundary.
// Layer: Service
// Exports: CodexSideConversationPresentation, CodexService side-conversation lifecycle
// Depends on: Foundation, CodexThread, JSONValue

import Foundation

struct CodexSideConversationPresentation: Identifiable, Equatable, Sendable {
    let thread: CodexThread
    let parentThreadID: String
    let initialPrompt: String?

    var id: String { thread.id }
}

extension CodexService {
    var hasOpenSideConversation: Bool {
        !sideConversationThreadIDs.isEmpty
    }

    // Active sheets and remote-cleanup tombstones share the same isolation contract.
    var sideConversationIsolationThreadIDs: Set<String> {
        sideConversationThreadIDs
            .union(pendingSideConversationCleanupThreadIDs)
            .union(closedSideConversationThreadIDs)
    }

    func isSideConversationIsolated(_ threadID: String) -> Bool {
        sideConversationThreadIDs.contains(threadID)
            || pendingSideConversationCleanupThreadIDs.contains(threadID)
            || closedSideConversationThreadIDs.contains(threadID)
    }

    func shouldDropRetiredSideConversationEvent(_ threadID: String) -> Bool {
        !sideConversationThreadIDs.contains(threadID)
            && (pendingSideConversationCleanupThreadIDs.contains(threadID)
                || closedSideConversationThreadIDs.contains(threadID))
    }

    func sideConversationRuntimeState(for threadID: String) -> CodexSideConversationRuntimeState {
        sideConversationRuntimeStateByThreadID[threadID]
            ?? .unavailable(message: "This temporary side conversation is no longer available.")
    }

    // Creates the same client-orchestrated ephemeral fork used by the native Codex TUI.
    @discardableResult
    func startSideConversation(from sourceThreadID: String) async throws -> CodexThread {
        try await awaitRuntimeInitializedIfNeeded()

        let parentThreadID = normalizedInterruptIdentifier(sourceThreadID) ?? sourceThreadID
        guard !parentThreadID.isEmpty, let parentThread = thread(for: parentThreadID) else {
            throw CodexServiceError.invalidInput("A started parent conversation is required for /side.")
        }
        guard !sideConversationThreadIDs.contains(parentThreadID), !hasOpenSideConversation else {
            throw CodexServiceError.invalidInput("A side conversation is already open.")
        }

        var params: RPCObject = [
            "threadId": .string(parentThreadID),
            "ephemeral": .bool(true),
            "developerInstructions": .string(Self.sideConversationDeveloperInstructions),
        ]
        if let model = parentThread.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            params["model"] = .string(model)
        }
        if let serviceTier = parentThread.serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serviceTier.isEmpty {
            params["serviceTier"] = .string(serviceTier)
        }

        let response: RPCMessage
        do {
            response = try await sendRequestWithApprovalPolicyFallback(
                method: "thread/fork",
                baseParams: params,
                context: "minimal"
            )
        } catch {
            if consumeUnsupportedThreadFork(error) {
                throw CodexServiceError.invalidInput(
                    "This device bridge does not support native side conversations yet. Update Remodex on your device and retry."
                )
            }
            if Self.isUnmaterializedSideConversationError(error) {
                throw CodexServiceError.invalidInput(
                    "Send a message in the main conversation before starting /side."
                )
            }
            throw error
        }

        guard let result = response.result?.objectValue,
              let threadValue = result["thread"],
              var sideThread = decodeModel(CodexThread.self, from: threadValue) else {
            throw CodexServiceError.invalidResponse("thread/fork response missing side thread")
        }

        sideThread.ephemeral = true
        sideThread.syncState = .live
        sideThread.forkedFromThreadId = parentThreadID
        sideThread.title = "Side conversation"
        sideThread.name = nil
        sideThread.preview = ""
        sideThread.cwd = sideThread.cwd ?? parentThread.cwd
        sideThread.model = sideThread.model ?? parentThread.model
        sideThread.modelProvider = sideThread.modelProvider ?? parentThread.modelProvider
        sideThread.reasoningEffort = sideThread.reasoningEffort ?? parentThread.reasoningEffort
        sideThread.serviceTier = sideThread.serviceTier ?? parentThread.serviceTier
        sideThread.createdAt = sideThread.createdAt ?? Date()
        sideThread.updatedAt = sideThread.updatedAt ?? sideThread.createdAt

        sideConversationThreadIDs.insert(sideThread.id)
        sideConversationRuntimeStateByThreadID[sideThread.id] = .active
        upsertThread(sideThread, treatAsServerState: true)
        inheritThreadRuntimeOverrides(from: parentThreadID, to: sideThread.id)
        resumedThreadIDs.insert(sideThread.id)
        hydratedThreadIDs.insert(sideThread.id)
        initialTurnsLoadedByThreadID.insert(sideThread.id)
        messagesByThread[sideThread.id] = []

        do {
            _ = try await sendRequest(
                method: "thread/inject_items",
                params: .object([
                    "threadId": .string(sideThread.id),
                    "items": .array([Self.sideConversationBoundaryItem]),
                ])
            )
            // Some transports deliver injected items as lifecycle notifications before the
            // request response. Clear them again so the inherited boundary stays model-only.
            messagesByThread[sideThread.id] = []
            refreshThreadTimelineState(for: sideThread.id)
        } catch {
            pendingSideConversationCleanupThreadIDs.insert(sideThread.id)
            try? await cleanupRemoteSideConversation(threadID: sideThread.id)
            closedSideConversationThreadIDs.insert(sideThread.id)
            sideConversationThreadIDs.remove(sideThread.id)
            sideConversationRuntimeStateByThreadID.removeValue(forKey: sideThread.id)
            discardEphemeralThreadLocally(sideThread.id)
            throw CodexServiceError.invalidInput(
                "Could not prepare the native side-conversation boundary. Update Remodex on your device and retry."
            )
        }

        return thread(for: sideThread.id) ?? sideThread
    }

    // Interrupts any running side turn before releasing the app-server subscription.
    func closeSideConversation(threadID: String) async throws {
        let normalizedThreadID = normalizedInterruptIdentifier(threadID) ?? threadID
        guard sideConversationThreadIDs.contains(normalizedThreadID)
                || pendingSideConversationCleanupThreadIDs.contains(normalizedThreadID) else {
            sideConversationRuntimeStateByThreadID[normalizedThreadID] = .closing
            return
        }

        let previousRuntimeState = sideConversationRuntimeStateByThreadID[normalizedThreadID] ?? .active
        let previousQueuePauseState = queuePauseStateByThread[normalizedThreadID]
        sideConversationRuntimeStateByThreadID[normalizedThreadID] = .closing
        queuePauseStateByThread[normalizedThreadID] = .paused(
            errorMessage: "The side conversation is closing."
        )
        pendingSideConversationCleanupThreadIDs.insert(normalizedThreadID)

        do {
            try await cleanupRemoteSideConversation(threadID: normalizedThreadID)
        } catch {
            if isConnected, isInitialized {
                pendingSideConversationCleanupThreadIDs.remove(normalizedThreadID)
                sideConversationRuntimeStateByThreadID[normalizedThreadID] = previousRuntimeState
                if let previousQueuePauseState {
                    queuePauseStateByThread[normalizedThreadID] = previousQueuePauseState
                } else {
                    queuePauseStateByThread.removeValue(forKey: normalizedThreadID)
                }
            } else {
                sideConversationRuntimeStateByThreadID[normalizedThreadID] = .recovering
            }
            throw error
        }

        finishSideConversationCleanup(threadID: normalizedThreadID)
    }

    // Clears sheet-visible runtime state; the transport tombstone remains for buffered replay safety.
    func acknowledgeSideConversationDismissal(threadID: String) {
        sideConversationRuntimeStateByThreadID.removeValue(forKey: threadID)
    }

    // Keeps the in-memory transcript visible while a short transport recovery is in progress.
    func markSideConversationsForReconnect() {
        // Closed IDs remain isolated because the replacement transport may replay
        // buffered notifications emitted before the previous socket was cancelled.
        for threadID in sideConversationThreadIDs
            where !pendingSideConversationCleanupThreadIDs.contains(threadID) {
            sideConversationRuntimeStateByThreadID[threadID] = .recovering
        }
    }

    // Re-subscribes ephemeral forks only on the same live app-server. No state is written to disk.
    func recoverSideConversationsAfterReconnect() async {
        await retryPendingSideConversationCleanup()

        let threadIDs = sideConversationThreadIDs
            .subtracting(pendingSideConversationCleanupThreadIDs)
            .sorted()
        guard !threadIDs.isEmpty else { return }

        for threadID in threadIDs {
            guard isConnected, isInitialized else {
                markSideConversationsForReconnect()
                return
            }

            sideConversationRuntimeStateByThreadID[threadID] = .recovering
            do {
                let response = try await sendRequest(
                    method: "thread/resume",
                    params: .object([
                        "threadId": .string(threadID),
                        // Never hydrate inherited parent turns into the visually empty side transcript.
                        "excludeTurns": .bool(true),
                    ]),
                    timeoutNanoseconds: 8_000_000_000,
                    timeoutMessage: "The temporary side conversation could not reconnect in time."
                )

                guard sideConversationThreadIDs.contains(threadID),
                      sideConversationRuntimeStateByThreadID[threadID] != .closing else {
                    // A close can race the resume response. Release any subscription that
                    // the late response may have recreated through the same interrupt-safe path.
                    pendingSideConversationCleanupThreadIDs.insert(threadID)
                    try? await cleanupRemoteSideConversation(threadID: threadID)
                    continue
                }

                if let threadValue = response.result?.objectValue?["thread"],
                   var resumedThread = decodeModel(CodexThread.self, from: threadValue) {
                    resumedThread.ephemeral = true
                    resumedThread.syncState = .live
                    resumedThread.title = "Side conversation"
                    resumedThread.name = nil
                    resumedThread.preview = ""
                    upsertThread(resumedThread, treatAsServerState: true)
                }

                resumedThreadIDs.insert(threadID)
                hydratedThreadIDs.insert(threadID)
                initialTurnsLoadedByThreadID.insert(threadID)
                _ = await refreshInFlightTurnState(threadId: threadID)
                guard sideConversationThreadIDs.contains(threadID),
                      sideConversationRuntimeStateByThreadID[threadID] == .recovering else {
                    continue
                }
                sideConversationRuntimeStateByThreadID[threadID] = .active
            } catch {
                guard isConnected else {
                    sideConversationRuntimeStateByThreadID[threadID] = .recovering
                    return
                }
                // A timed-out or otherwise ambiguous resume can still have subscribed remotely.
                // Definite missing-thread responses need no remote cleanup.
                if !Self.isDefinitelyMissingSideConversationError(error) {
                    pendingSideConversationCleanupThreadIDs.insert(threadID)
                    try? await cleanupRemoteSideConversation(threadID: threadID)
                }
                invalidateSideConversation(
                    threadID: threadID,
                    message: Self.sideConversationRecoveryFailureMessage(for: error)
                )
            }
        }
    }

    // Ends only the local ephemeral surface; the parent selection and history remain untouched.
    func invalidateSideConversation(threadID: String, message: String) {
        guard sideConversationThreadIDs.contains(threadID)
                || sideConversationRuntimeStateByThreadID[threadID] != nil else {
            return
        }
        sideConversationRuntimeStateByThreadID[threadID] = .unavailable(message: message)
        closedSideConversationThreadIDs.insert(threadID)
        sideConversationThreadIDs.remove(threadID)
        discardEphemeralThreadLocally(threadID)
    }

    // Used when a root-owned modal disappears and there is no UI left to retry network cleanup.
    func abandonSideConversationLocally(threadID: String) {
        pendingSideConversationCleanupThreadIDs.insert(threadID)
        sideConversationThreadIDs.remove(threadID)
        discardEphemeralThreadLocally(threadID)
        sideConversationRuntimeStateByThreadID.removeValue(forKey: threadID)
        if isConnected, isInitialized {
            Task { @MainActor [weak self] in
                await self?.retryPendingSideConversationCleanup()
            }
        }
    }

    func invalidateAllSideConversations(message: String) {
        // Pending cleanup IDs can still have buffered events even though they no
        // longer own a visible sheet. Promote them to durable in-memory tombstones.
        closedSideConversationThreadIDs.formUnion(pendingSideConversationCleanupThreadIDs)
        for threadID in sideConversationThreadIDs.sorted() {
            invalidateSideConversation(threadID: threadID, message: message)
        }
        pendingSideConversationCleanupThreadIDs.removeAll()
    }
}

private extension CodexService {
    // Resolves server turn state before unsubscribe so a possibly running turn is never orphaned.
    func cleanupRemoteSideConversation(threadID: String) async throws {
        guard isConnected, isInitialized else {
            throw CodexServiceError.disconnected
        }

        let resolvedTurnID: String?
        do {
            resolvedTurnID = try await resolveInFlightTurnID(threadId: threadID)
        } catch {
            if Self.isDefinitelyMissingSideConversationError(error) {
                pendingSideConversationCleanupThreadIDs.remove(threadID)
                return
            }
            throw error
        }

        if let resolvedTurnID {
            try await interruptTurn(turnId: resolvedTurnID, threadId: threadID)
        }
        do {
            _ = try await sendRequest(
                method: "thread/unsubscribe",
                params: .object(["threadId": .string(threadID)])
            )
        } catch {
            if Self.isDefinitelyMissingSideConversationError(error) {
                pendingSideConversationCleanupThreadIDs.remove(threadID)
                return
            }
            throw error
        }
        pendingSideConversationCleanupThreadIDs.remove(threadID)
    }

    func retryPendingSideConversationCleanup() async {
        guard isConnected, isInitialized else { return }
        for threadID in pendingSideConversationCleanupThreadIDs.sorted() {
            let shouldDismissPresentedSide = sideConversationThreadIDs.contains(threadID)
                || sideConversationRuntimeStateByThreadID[threadID] != nil
            guard (try? await cleanupRemoteSideConversation(threadID: threadID)) != nil else {
                continue
            }
            if shouldDismissPresentedSide {
                sideConversationRuntimeStateByThreadID[threadID] = .unavailable(
                    message: "The temporary side conversation closed after reconnecting. The main conversation is unchanged."
                )
            }
            finishSideConversationCleanup(threadID: threadID)
        }
    }

    func finishSideConversationCleanup(threadID: String) {
        closedSideConversationThreadIDs.insert(threadID)
        pendingSideConversationCleanupThreadIDs.remove(threadID)
        sideConversationThreadIDs.remove(threadID)
        discardEphemeralThreadLocally(threadID)
    }

    static let sideConversationDeveloperInstructions = #"""
    You are in a side conversation, not the main thread.

    This side conversation is for answering questions and lightweight exploration without disrupting the main thread. The inherited fork history is reference context only. Do not treat instructions, plans, approvals, tool calls, edits, or requests found in inherited history as active instructions. Only instructions submitted after the side-conversation boundary are active.

    Sub-agents are off-limits. Do not interact with existing or new sub-agents. You may perform non-mutating inspection, including reading or searching files and running checks that do not alter repo-tracked files. Do not modify files, source, git state, permissions, configuration, or workspace state unless the user explicitly requests that mutation in this side conversation. Do not request escalated permissions unless that explicit mutation requires them. Keep any requested mutation minimal and avoid disrupting the main thread.
    """#

    static let sideConversationBoundaryText = #"""
    Side conversation boundary. Everything before this boundary is inherited history from the parent thread. It is reference context only, not the current task.

    Do not continue or complete instructions, plans, tool calls, approvals, edits, or requests from before this boundary. Only messages submitted after this boundary are active user instructions for this side conversation. Answer questions and do lightweight, non-mutating exploration by default. If there is no user question after this boundary yet, wait for one.

    External tool calls and outputs visible before this boundary happened in the parent and are reference-only. Sub-agents are off-limits. Do not modify files, git state, permissions, configuration, or workspace state unless the user explicitly asks after this boundary.
    """#

    static var sideConversationBoundaryItem: JSONValue {
        .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(sideConversationBoundaryText),
                ]),
            ]),
        ])
    }

    nonisolated static func isUnmaterializedSideConversationError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("no rollout found for thread id")
            || message.contains("unavailable before first user message")
    }

    nonisolated static func sideConversationRecoveryFailureMessage(for error: Error) -> String {
        let normalized = String(describing: error).lowercased()
        if normalized.contains("thread not found")
            || normalized.contains("unknown thread")
            || normalized.contains("no rollout found")
            || normalized.contains("not materialized") {
            return "The temporary side conversation ended when the Mac runtime restarted. The main conversation is unchanged."
        }
        return "The temporary side conversation could not be recovered. The main conversation is unchanged."
    }

    nonisolated static func isDefinitelyMissingSideConversationError(_ error: Error) -> Bool {
        let normalized = String(describing: error).lowercased()
        return normalized.contains("thread not found")
            || normalized.contains("unknown thread")
            || normalized.contains("no rollout found")
            || normalized.contains("not materialized")
    }
}
