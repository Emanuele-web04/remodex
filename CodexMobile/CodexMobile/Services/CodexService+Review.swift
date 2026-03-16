// FILE: CodexService+Review.swift
// Purpose: Starts Codex reviewer runs and applies the same optimistic message bookkeeping as chat sends.
// Layer: Service
// Exports: CodexService review-start helpers
// Depends on: CodexService, RPCMessage

import Foundation

enum CodexReviewTarget {
    case uncommittedChanges
    case baseBranch
}

private struct ReviewStartRequest {
    let promptText: String
    let target: CodexReviewTarget
    let baseBranch: String?
}

extension CodexService {
    // Starts an inline code review for the current thread without forking to a detached review thread.
    func startReview(
        threadId: String,
        target: CodexReviewTarget?,
        baseBranch: String? = nil
    ) async throws {
        guard let target else {
            throw CodexServiceError.invalidInput("Choose a review target first.")
        }

        let request = ReviewStartRequest(
            promptText: reviewPromptText(target: target, baseBranch: baseBranch),
            target: target,
            baseBranch: baseBranch
        )
        let initialThreadId = try await resolveThreadID(threadId)
        let resolvedThreadId = try await sendReviewStartRecoveringThread(
            request,
            initialThreadId: initialThreadId
        )
        activeThreadId = resolvedThreadId
    }

    // Keeps review-start aligned with turn/start by recovering stale archived threads before retrying.
    private func sendReviewStartRecoveringThread(
        _ request: ReviewStartRequest,
        initialThreadId: String
    ) async throws -> String {
        do {
            try await ensureThreadResumed(threadId: initialThreadId)
        } catch {
            if shouldTreatAsThreadNotFound(error) {
                return try await continueReviewStart(
                    request,
                    fromMissingThreadId: initialThreadId,
                    removePendingUserMessage: false
                )
            }
        }

        do {
            try await sendReviewStart(
                request,
                to: initialThreadId,
            )
            return initialThreadId
        } catch {
            if shouldTreatAsThreadNotFound(error) {
                return try await continueReviewStart(
                    request,
                    fromMissingThreadId: initialThreadId,
                    removePendingUserMessage: true
                )
            }
            throw error
        }
    }

    // Uses the review/start target schema expected by the local Codex runtime.
    private func buildReviewStartParams(
        threadId: String,
        target: CodexReviewTarget,
        baseBranch: String?
    ) throws -> RPCObject {
        var targetObject: RPCObject

        switch target {
        case .uncommittedChanges:
            targetObject = [
                "type": .string("uncommittedChanges"),
            ]

        case .baseBranch:
            let normalizedBaseBranch = baseBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolvedBaseBranch = normalizedBaseBranch,
                  !resolvedBaseBranch.isEmpty else {
                throw CodexServiceError.invalidInput("Choose a base branch before starting this review.")
            }
            targetObject = [
                "type": .string("baseBranch"),
                "branch": .string(resolvedBaseBranch),
            ]
        }

        return [
            "threadId": .string(threadId),
            "delivery": .string("inline"),
            "target": .object(targetObject),
        ]
    }

    // Replays the review request onto a continuation thread when the original one no longer exists server-side.
    private func continueReviewStart(
        _ request: ReviewStartRequest,
        fromMissingThreadId missingThreadId: String,
        removePendingUserMessage: Bool
    ) async throws -> String {
        if removePendingUserMessage {
            removeLatestFailedUserMessage(
                threadId: missingThreadId,
                matchingText: request.promptText,
                matchingAttachments: []
            )
        }
        handleMissingThread(missingThreadId)

        let continuationThread = try await createContinuationThread(from: missingThreadId)
        try await ensureThreadResumed(threadId: continuationThread.id)
        try await sendReviewStart(
            request,
            to: continuationThread.id
        )
        lastErrorMessage = nil
        return continuationThread.id
    }

    // Sends `review/start` with the same optimistic row + runtime compatibility behavior as a chat send.
    private func sendReviewStart(
        _ request: ReviewStartRequest,
        to threadId: String
    ) async throws {
        let pendingMessageId = appendUserMessage(
            threadId: threadId,
            text: request.promptText
        )
        activeThreadId = threadId
        markThreadAsRunning(threadId)
        setProtectedRunningFallback(true, for: threadId)

        do {
            // Reuse the turn/start compatibility path so review runs honor the selected access mode.
            let requestParams = try buildReviewStartParams(
                threadId: threadId,
                target: request.target,
                baseBranch: request.baseBranch
            )
            let response = try await sendRequestWithSandboxFallback(
                method: "review/start",
                baseParams: requestParams
            )
            handleSuccessfulReviewStartResponse(
                response,
                pendingMessageId: pendingMessageId,
                threadId: threadId
            )
        } catch {
            try handleTurnStartFailure(
                error,
                pendingMessageId: pendingMessageId,
                threadId: threadId
            )
        }
    }

    // Confirms the optimistic user row and associates it with the real review turn when available.
    private func handleSuccessfulReviewStartResponse(
        _ response: RPCMessage,
        pendingMessageId: String,
        threadId: String
    ) {
        let turnID = extractTurnID(from: response.result)
        let resolvedTurnID = turnID ?? activeTurnIdByThread[threadId]
        let deliveryState: CodexMessageDeliveryState = (resolvedTurnID == nil) ? .pending : .confirmed
        markMessageDeliveryState(
            threadId: threadId,
            messageId: pendingMessageId,
            state: deliveryState,
            turnId: resolvedTurnID
        )

        if let resolvedTurnID {
            activeTurnId = resolvedTurnID
            setActiveTurnID(resolvedTurnID, for: threadId)
            threadIdByTurnID[resolvedTurnID] = threadId
            setProtectedRunningFallback(false, for: threadId)
        }

        if let index = threadIndex(for: threadId) {
            threads[index].updatedAt = Date()
            threads[index].syncState = .live
            threads = sortThreads(threads)
        }
    }

    private func reviewPromptText(target: CodexReviewTarget, baseBranch: String?) -> String {
        switch target {
        case .uncommittedChanges:
            return "Review current changes"
        case .baseBranch:
            let trimmedBaseBranch = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedBaseBranch, !trimmedBaseBranch.isEmpty {
                return "Review against base branch \(trimmedBaseBranch)"
            }
            return "Review against base branch"
        }
    }
}
