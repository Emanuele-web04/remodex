// FILE: DesktopHandoffService.swift
// Purpose: Sends explicit "continue on Mac" requests over the existing bridge connection.
// Layer: Service
// Exports: DesktopHandoffService, DesktopHandoffError
// Depends on: CodexService

import Foundation

enum DesktopHandoffError: LocalizedError {
    case disconnected
    case invalidResponse
    case bridgeError(code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "Not connected to your Mac."
        case .invalidResponse:
            return "The Mac app did not return a valid response."
        case .bridgeError(let code, let message):
            return userMessage(for: code, fallback: message)
        }
    }

    private func userMessage(for code: String?, fallback: String?) -> String {
        switch code {
        case "missing_thread_id":
            return "This chat does not have a valid thread id yet."
        case "unsupported_platform":
            return "Mac handoff works only when the bridge is running on macOS."
        case "handoff_failed":
            return fallback ?? "Could not relaunch Codex.app on your Mac."
        default:
            return fallback ?? "Could not continue this chat on your Mac."
        }
    }
}

@MainActor
final class DesktopHandoffService {
    private let codex: CodexService

    init(codex: CodexService) {
        self.codex = codex
    }

    func continueOnMac(threadId: String) async throws {
        let trimmedThreadID = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadID.isEmpty else {
            throw DesktopHandoffError.bridgeError(
                code: "missing_thread_id",
                message: "This chat does not have a valid thread id yet."
            )
        }

        let params: JSONValue = .object([
            "threadId": .string(trimmedThreadID),
        ])

        do {
            let response = try await codex.sendRequest(method: "desktop/continueOnMac", params: params)
            guard let resultObject = response.result?.objectValue,
                  resultObject["success"]?.boolValue == true else {
                throw DesktopHandoffError.invalidResponse
            }
        } catch let error as CodexServiceError {
            switch error {
            case .disconnected:
                throw DesktopHandoffError.disconnected
            case .rpcError(let rpcError):
                let errorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue
                throw DesktopHandoffError.bridgeError(code: errorCode, message: rpcError.message)
            default:
                throw DesktopHandoffError.bridgeError(code: nil, message: error.errorDescription)
            }
        }
    }
}
