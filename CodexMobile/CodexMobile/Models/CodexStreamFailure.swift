import Foundation

// A terminal model-service failure can be continued in the existing conversation.
// Keep the original message for reports; never infer retryability from relay errors.
struct CodexStreamFailure: Equatable {
    let id = UUID()
    let turnID: String
    let message: String
    let runGeneration: Int
    var isDismissed = false
    var hasAttemptedContinuation = false

    static let explanation = "Codex lost its connection to the model service. You can continue in this chat."
    static let continuationPrompt = "Continue from where you stopped. Check what already completed before repeating any actions."

    static func isRecoverable(message: String, errorInfo: JSONValue? = nil) -> Bool {
        let text = message.lowercased()
        let permanentErrors = ["unauthorized", "authentication", "invalid api key", "invalid_api_key",
                               "invalid_grant", "quota", "usage limit", "rate limit", "context window",
                               "context length", "permission denied", "policy violation"]
        guard !permanentErrors.contains(where: text.contains) else { return false }

        if let kind = errorInfo?.stringValue, kind != "other" {
            return kind == "serverOverloaded" || kind == "internalServerError"
        }
        if let info = errorInfo?.objectValue {
            let streamKinds = ["responseStreamDisconnected", "responseStreamConnectionFailed",
                               "responseTooManyFailedAttempts", "httpConnectionFailed"]
            guard let kind = streamKinds.first(where: { info[$0] != nil }) else { return false }
            if let status = info[kind]?.objectValue?["httpStatusCode"]?.intValue {
                return status == 408 || (500...599).contains(status)
            }
            return true
        }

        // Legacy bridges may only carry text. Restrict this fallback to model-stream failures.
        guard text.contains("stream disconnected before completion") else { return false }
        return ["service temporarily unavailable", "service unavailable", "server overloaded",
                "internal server error", "connection reset", "stream closed", "timed out",
                "timeout"].contains(where: text.contains)
    }
}
