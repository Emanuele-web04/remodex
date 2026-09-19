import Foundation

extension TurnViewModel {
    // Use the same send gate as the composer without consuming an unsent draft.
    func continueAfterStreamFailure(
        _ failure: CodexStreamFailure, codex: CodexService,
        subscriptions: SubscriptionService, threadID: String
    ) {
        guard !isSending, codex.recoverableStreamFailure(for: threadID)?.id == failure.id else { return }
        guard subscriptions.hasAppAccess else {
            codex.dismissStreamFailure(threadId: threadID, failureID: failure.id)
            codex.lastErrorMessage = "Your 5 free messages are over. Unlock Remodex Pro to keep chatting."
            return
        }
        isSending = true
        Task { @MainActor in
            defer { isSending = false }
            do {
                try await codex.continueAfterStreamFailure(threadId: threadID, failureID: failure.id) {
                    subscriptions.consumeFreeSendAttemptIfNeeded()
                }
            } catch {
                guard codex.recoverableStreamFailuresByThread[threadID]?.id == failure.id else { return }
                codex.dismissStreamFailure(threadId: threadID, failureID: failure.id)
                codex.lastErrorMessage = codex.userFacingTurnErrorMessageForFooter(from: error)
            }
        }
    }
}
