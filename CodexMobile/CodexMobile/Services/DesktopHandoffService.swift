// FILE: DesktopHandoffService.swift
// Purpose: Sends explicit desktop-app handoff and display-wake requests over the existing bridge connection.
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
            return "Not connected to your paired computer."
        case .invalidResponse:
            return "The desktop app did not return a valid response."
        case .bridgeError(let code, let message):
            return userMessage(for: code, fallback: message)
        }
    }

    private func userMessage(for code: String?, fallback: String?) -> String {
        DesktopHandoffError.userMessage(for: code, fallback: fallback)
    }
}

@MainActor
final class DesktopHandoffService {
    private let codex: CodexService
    private let savedPairConnector: ((String) async throws -> Void)?

    init(
        codex: CodexService,
        savedPairConnector: ((String) async throws -> Void)? = nil
    ) {
        self.codex = codex
        self.savedPairConnector = savedPairConnector
    }

    // Uses the platform-neutral desktop handoff RPC so the same iOS action works with macOS and Windows bridges.
    func continueOnDesktopApp(threadId: String) async throws {
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
            let response = try await codex.sendRequest(method: "desktop/continueOnDesktop", params: params)
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

    // Sends a short user-activity pulse so a saved local computer can wake its display before reconnecting.
    func wakeDisplay() async throws {
        if codex.isConnected {
            try await sendWakeDisplayRequest(using: codex)
            return
        }

        guard codex.canWakePreferredMacDisplay else {
            throw DesktopHandoffError.bridgeError(
                code: "saved_pair_required",
                message: "Reconnect to your paired computer first."
            )
        }

        guard let reconnectURL = try await preferredReconnectURLForWake() else {
            throw DesktopHandoffError.bridgeError(
                code: "saved_pair_required",
                message: "Reconnect to your paired computer or scan a new QR code first."
            )
        }

        if let savedPairConnector {
            try await savedPairConnector(reconnectURL)
        } else {
            try await codex.connect(
                serverURL: reconnectURL,
                token: "",
                role: "iphone",
                performInitialSync: false
            )
        }
        try await sendWakeDisplayRequest(using: codex)
    }

    func updateBridgeKeepMacAwakePreference(enabled: Bool) async throws {
        do {
            let response = try await codex.sendRequest(
                method: "desktop/preferences/update",
                params: .object([
                    "keepMacAwake": .bool(enabled),
                ])
            )
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

    // Reuses the existing JSON-RPC bridge channel so display wake follows the same secure pairing path.
    private func sendWakeDisplayRequest(using service: CodexService) async throws {
        do {
            let response = try await service.sendRequest(method: "desktop/wakeDisplay", params: .object([:]))
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

    // Rebuilds the last saved session URL so offline wake can use a temporary bridge connection.
    private var savedReconnectURL: String? {
        guard let sessionId = codex.normalizedRelaySessionId,
              let relayURL = codex.normalizedRelayURL else {
            return nil
        }

        return "\(relayURL)/\(sessionId)"
    }

    // Prefers a freshly resolved trusted session so display wake still works when the saved live session is gone.
    private func preferredReconnectURLForWake() async throws -> String? {
        if codex.hasTrustedMacReconnectCandidate {
            do {
                let resolved = try await codex.resolveTrustedMacSession()
                guard let relayURL = codex.normalizedRelayURL else {
                    return nil
                }
                return "\(relayURL)/\(resolved.sessionId)"
            } catch let error as CodexTrustedSessionResolveError {
                switch error {
                case .unsupportedRelay, .network, .noTrustedMac:
                    if let savedReconnectURL {
                        return savedReconnectURL
                    }
                case .macOffline, .rePairRequired, .invalidResponse:
                    break
                }

                throw DesktopHandoffError.bridgeError(code: nil, message: error.localizedDescription)
            }
        }

        return savedReconnectURL
    }
}

private extension DesktopHandoffError {
    static func userMessage(for code: String?, fallback: String?) -> String {
        switch code {
        case "missing_thread_id":
            return "This chat does not have a valid thread id yet."
        case "unsupported_platform":
            return "Desktop app handoff works only when the bridge is running on a supported desktop platform."
        case "handoff_failed":
            return fallback ?? "Could not relaunch Codex.app on this computer."
        case "wake_display_failed":
            return fallback ?? "Could not wake this computer's display right now."
        case "saved_pair_required":
            return fallback ?? "Reconnect to your paired computer or scan a new QR code first."
        case "unsupported_bridge_preferences":
            return fallback ?? "Update the Remodex bridge on your computer to sync this setting."
        case "invalid_bridge_preferences":
            return fallback ?? "The computer bridge rejected this setting update."
        case "bridge_preferences_persist_failed":
            return fallback ?? "The computer bridge could not save this setting."
        default:
            return fallback ?? "Could not continue this chat on the desktop app."
        }
    }
}
