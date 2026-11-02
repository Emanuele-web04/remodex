// FILE: CodexServiceError.swift
// Purpose: Error taxonomy used by CodexService operations.
// Layer: Service
// Exports: CodexServiceError
// Depends on: RPCError

import Foundation

enum CodexServiceError: LocalizedError {
    case invalidServerURL(String)
    case invalidInput(String)
    case invalidResponse(String)
    case encodingFailed
    case disconnected
    case noPendingApproval
    case rpcError(RPCError)

    var isDesktopSteerTurnEnded: Bool {
        guard case .rpcError(let error) = self else { return false }
        return error.data?.objectValue?["errorCode"]?.stringValue == "desktop_steer_turn_ended"
    }

    var errorDescription: String? {
        switch self {
        case .invalidServerURL(let value):
            return "Invalid server URL: \(value)"
        case .invalidInput(let reason):
            return reason
        case .invalidResponse(let reason):
            return reason
        case .encodingFailed:
            return "Unable to encode JSON-RPC payload"
        case .disconnected:
            return "WebSocket not connected"
        case .noPendingApproval:
            return "No pending approval request"
        case .rpcError(let rpcError):
            return "RPC error \(rpcError.code): \(rpcError.message)"
        }
    }
}
