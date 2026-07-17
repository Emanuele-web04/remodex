// FILE: CodexService+AutoApprovalReview.swift
// Purpose: Handles Codex automatic approval-review notifications and narrow retry approvals.
// Layer: Service
// Exports: CodexService auto-approval review APIs
// Depends on: CodexAutoApprovalReview, CodexMessage, JSONValue

import Foundation

extension CodexService {
    private static let maximumAutoApprovalRetryTokens = 10
    private static let autoApprovalRetryTokenLifetime: TimeInterval = 15 * 60

    func handleAutoApprovalReviewNotification(_ paramsObject: IncomingParamsObject?) {
        guard let paramsObject,
              let threadId = paramsObject["threadId"]?.stringValue else {
            return
        }
        guard let review = decodeAutoApprovalReview(from: paramsObject) else {
            // The payload is marked [UNSTABLE] upstream; log drops instead of
            // failing silently so shape changes surface in the runtime log.
            debugRuntimeLog("item/autoApprovalReview dropped: undecodable payload")
            return
        }

        upsertAutoApprovalReview(review, threadId: threadId)
    }

    func decodeAutoApprovalReview(from paramsObject: IncomingParamsObject) -> CodexAutoApprovalReview? {
        guard let reviewId = paramsObject["reviewId"]?.stringValue,
              !reviewId.isEmpty,
              let turnId = paramsObject["turnId"]?.stringValue,
              let reviewObject = paramsObject["review"]?.objectValue,
              let statusValue = reviewObject["status"]?.stringValue,
              let action = paramsObject["action"] else {
            return nil
        }
        let status = CodexAutoApprovalReviewStatus(rawValue: statusValue)

        var review = CodexAutoApprovalReview(
            reviewId: reviewId,
            targetItemId: paramsObject["targetItemId"]?.stringValue,
            turnId: turnId,
            startedAtMs: integerTimestamp(paramsObject["startedAtMs"]),
            completedAtMs: optionalIntegerTimestamp(paramsObject["completedAtMs"]),
            status: status,
            riskLevel: reviewObject["riskLevel"]?.stringValue,
            userAuthorization: reviewObject["userAuthorization"]?.stringValue,
            rationale: reviewObject["rationale"]?.stringValue,
            decisionSource: paramsObject["decisionSource"]?.stringValue,
            action: action,
            retryApproved: false,
            retryUnavailableReason: paramsObject["remodexGuardianRetrySupported"]?.boolValue == false
                || paramsObject["remodexDesktopIpcMirror"]?.boolValue == true
                ? "Approve this retry in Codex Desktop."
                : nil
        )
        if review.status == .denied,
           review.retryUnavailableReason == nil,
           review.coreDeniedEvent == nil {
            review.retryUnavailableReason = "This action cannot be retried safely here. Approve it in Codex."
        }
        return review
    }

    func approveAutoApprovalRetry(threadId: String, reviewId: String) async throws {
        guard let review = messagesByThread[threadId]?
            .first(where: { $0.autoApprovalReview?.reviewId == reviewId })?
            .autoApprovalReview,
              !review.retryApproved else {
            throw CodexServiceError.invalidInput("This denied action is no longer available for approval.")
        }
        if let retryUnavailableReason = review.retryUnavailableReason {
            throw CodexServiceError.invalidInput(retryUnavailableReason)
        }

        let retryKey = retryTokenKey(threadId: threadId, reviewId: reviewId)
        guard autoApprovalRetryReviewIDsInFlight.insert(retryKey).inserted else {
            throw CodexServiceError.invalidInput("This denied action is already being approved.")
        }
        defer {
            autoApprovalRetryReviewIDsInFlight.remove(retryKey)
        }

        guard let token = autoApprovalRetryTokensByReviewKey.removeValue(forKey: retryKey),
              token.expiresAt > Date() else {
            updateRetryPresentation(
                threadId: threadId,
                reviewId: reviewId,
                retryApproved: false,
                unavailableReason: CodexAutoApprovalReview.expiredRetryUnavailableReason
            )
            persistMessages()
            updateCurrentOutput(for: threadId)
            throw CodexServiceError.invalidInput(
                "This retry is no longer available. Wait for Codex to request the action again."
            )
        }

        updateRetryPresentation(
            threadId: threadId,
            reviewId: reviewId,
            retryApproved: false,
            unavailableReason: "Retry approval submitted. Check Codex before trying again."
        )

        do {
            _ = try await sendRequest(
                method: "thread/approveGuardianDeniedAction",
                params: .object([
                    "threadId": .string(threadId),
                    "event": token.event,
                ])
            )
        } catch {
            // A transport failure is ambiguous: the approval may have reached
            // Codex before the connection dropped, and the server does not
            // deduplicate approvals by review, so restoring the one-shot token
            // could double-grant a denied action. Fail closed — token stays
            // consumed — but replace the optimistic "submitted" copy with an
            // accurate status.
            updateRetryPresentation(
                threadId: threadId,
                reviewId: reviewId,
                retryApproved: false,
                unavailableReason: "Retry approval may not have reached Codex. Check Codex before trying again."
            )
            persistMessages()
            updateCurrentOutput(for: threadId)
            throw error
        }

        updateRetryPresentation(
            threadId: threadId,
            reviewId: reviewId,
            retryApproved: true,
            unavailableReason: nil
        )
        persistMessages()
        updateCurrentOutput(for: threadId)
    }

    private func upsertAutoApprovalReview(
        _ review: CodexAutoApprovalReview,
        threadId: String
    ) {
        storeRetryTokenIfAvailable(review, threadId: threadId)

        if var threadMessages = messagesByThread[threadId],
           let messageIndex = threadMessages.firstIndex(where: {
               $0.autoApprovalReview?.reviewId == review.reviewId
           }),
           let existingReview = threadMessages[messageIndex].autoApprovalReview {
            if existingReview.status.isTerminal, !review.status.isTerminal {
                return
            }

            var updatedReview = review
            updatedReview.retryApproved = existingReview.retryApproved
            updatedReview.retryUnavailableReason = review.retryUnavailableReason
                ?? existingReview.retryUnavailableReason
            applyMissingRetryTokenReason(&updatedReview, threadId: threadId)
            threadMessages[messageIndex].text = updatedReview.actionSummary
            threadMessages[messageIndex].turnId = updatedReview.turnId
            threadMessages[messageIndex].isStreaming = !updatedReview.status.isTerminal
                && !isApplyingReplayedBridgeEvent
            threadMessages[messageIndex].autoApprovalReview = updatedReview
            messagesByThread[threadId] = threadMessages
            persistMessages()
            updateCurrentOutput(for: threadId)
            return
        }

        var newReview = review
        applyMissingRetryTokenReason(&newReview, threadId: threadId)
        let createdAt = newReview.startedAtMs > 0
            ? Date(timeIntervalSince1970: Double(newReview.startedAtMs) / 1_000)
            : Date()
        appendMessage(
            CodexMessage(
                threadId: threadId,
                role: .system,
                kind: .autoApprovalReview,
                text: newReview.actionSummary,
                createdAt: createdAt,
                turnId: newReview.turnId,
                itemId: "auto-approval-review:\(newReview.reviewId)",
                isStreaming: newReview.status == .inProgress,
                autoApprovalReview: newReview
            )
        )
    }

    // The retry button's visibility is derived from retryUnavailableReason, so
    // any denied review without a live token (replayed reconnect events skip
    // token storage) must carry a reason or the card advertises a dead retry.
    private func applyMissingRetryTokenReason(
        _ review: inout CodexAutoApprovalReview,
        threadId: String
    ) {
        guard review.status == .denied,
              !review.retryApproved,
              review.retryUnavailableReason == nil,
              autoApprovalRetryTokensByReviewKey[
                  retryTokenKey(threadId: threadId, reviewId: review.reviewId)
              ] == nil else {
            return
        }
        review.retryUnavailableReason = CodexAutoApprovalReview.liveSessionRetryUnavailableReason
    }

    private func storeRetryTokenIfAvailable(
        _ review: CodexAutoApprovalReview,
        threadId: String
    ) {
        guard !isApplyingReplayedBridgeEvent,
              review.status == .denied,
              review.retryUnavailableReason == nil,
              let event = review.coreDeniedEvent else {
            return
        }
        let now = Date()
        var droppedKeys = autoApprovalRetryTokensByReviewKey
            .filter { $0.value.expiresAt <= now }
            .map(\.key)
        for key in droppedKeys {
            autoApprovalRetryTokensByReviewKey.removeValue(forKey: key)
        }
        let key = retryTokenKey(threadId: threadId, reviewId: review.reviewId)
        autoApprovalRetryTokensByReviewKey[key] = CodexAutoApprovalRetryToken(
            event: event,
            expiresAt: now.addingTimeInterval(Self.autoApprovalRetryTokenLifetime)
        )
        if autoApprovalRetryTokensByReviewKey.count > Self.maximumAutoApprovalRetryTokens,
           let oldest = autoApprovalRetryTokensByReviewKey.min(by: {
               $0.value.expiresAt < $1.value.expiresAt
           }) {
            autoApprovalRetryTokensByReviewKey.removeValue(forKey: oldest.key)
            droppedKeys.append(oldest.key)
        }
        markRetryUnavailableForDroppedTokens(droppedKeys)
    }

    // Cap eviction and lazy expiry silently invalidate tokens for cards that
    // still render an active retry button; mark those reviews so visibility
    // stays in sync with actual retry capability.
    private func markRetryUnavailableForDroppedTokens(_ keys: [String]) {
        var affectedThreadIds: Set<String> = []
        for key in keys {
            let parts = key.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  var threadMessages = messagesByThread[parts[0]],
                  let messageIndex = threadMessages.firstIndex(where: {
                      $0.autoApprovalReview?.reviewId == parts[1]
                  }),
                  var review = threadMessages[messageIndex].autoApprovalReview,
                  review.status == .denied,
                  !review.retryApproved,
                  review.retryUnavailableReason == nil else {
                continue
            }
            review.retryUnavailableReason = CodexAutoApprovalReview.expiredRetryUnavailableReason
            threadMessages[messageIndex].autoApprovalReview = review
            messagesByThread[parts[0]] = threadMessages
            affectedThreadIds.insert(parts[0])
        }
        guard !affectedThreadIds.isEmpty else {
            return
        }
        persistMessages()
        for threadId in affectedThreadIds {
            updateCurrentOutput(for: threadId)
        }
    }

    private func retryTokenKey(threadId: String, reviewId: String) -> String {
        "\(threadId)\u{0}\(reviewId)"
    }

    private func updateRetryPresentation(
        threadId: String,
        reviewId: String,
        retryApproved: Bool,
        unavailableReason: String?
    ) {
        guard var threadMessages = messagesByThread[threadId],
              let messageIndex = threadMessages.firstIndex(where: {
                  $0.autoApprovalReview?.reviewId == reviewId
              }),
              var updatedReview = threadMessages[messageIndex].autoApprovalReview else {
            return
        }
        updatedReview.retryApproved = retryApproved
        updatedReview.retryUnavailableReason = unavailableReason
        threadMessages[messageIndex].autoApprovalReview = updatedReview
        messagesByThread[threadId] = threadMessages
    }

    private func integerTimestamp(_ value: JSONValue?) -> Int {
        optionalIntegerTimestamp(value) ?? 0
    }

    private func optionalIntegerTimestamp(_ value: JSONValue?) -> Int? {
        if let integer = value?.intValue {
            return integer
        }
        if let double = value?.doubleValue {
            return Int(double)
        }
        return nil
    }
}
