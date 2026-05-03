// FILE: CodexService+TurnPaginationCompatibility.swift
// Purpose: Detects runtimes that cannot page thread turns and centralizes fallback state.
// Layer: Service
// Exports: CodexService turn-pagination compatibility helpers
// Depends on: Foundation, RPCMessage, CodexServiceError

import Foundation

extension CodexService {
    // Learns conservative turn-pagination support from initialize.user_agent when present.
    func learnTurnPaginationSupportFromInitializeResponse(_ response: RPCMessage) {
        guard let resultObject = response.result?.objectValue,
              let userAgent = resultObject["userAgent"]?.stringValue
                ?? resultObject["user_agent"]?.stringValue else {
            return
        }

        guard let version = codexCLIUserAgentVersion(userAgent),
              codexVersion(version, isOlderThan: (0, 125, 0)) else {
            return
        }

        markTurnPaginationUnsupportedForCurrentRuntime()
        debugRuntimeLog("turn pagination disabled from initialize userAgent=\(userAgent)")
    }

    // Returns true when an RPC failure means the runtime cannot page turns or exclude embedded turns.
    func shouldDisableTurnPagination(_ error: Error, attemptedMethod: String? = nil) -> Bool {
        guard let serviceError = error as? CodexServiceError else {
            return false
        }

        switch serviceError {
        case .rpcError(let rpcError):
            let message = rpcError.message.lowercased()
            let attemptedTurnList = attemptedMethod == "thread/turns/list"
            let mentionsMissingMethod = message.contains("method not found")
                || message.contains("unknown method")
                || message.contains("not implemented")
            let mentionsTurnList = message.contains("thread/turns/list")
                || message.contains("turns/list")
                || message.contains("turn pagination")
            let mentionsUnsupportedPagination = message.contains("unsupported")
                || message.contains("not supported")
            let mentionsExcludeTurns = message.contains("excludeturns")
                || message.contains("exclude_turns")
                || message.contains("exclude turns")
            let mentionsUnsupportedField = message.contains("unknown field")
                || message.contains("unrecognized field")
                || message.contains("failed to parse")
                || message.contains("invalid params")

            if rpcError.code == -32601 {
                return attemptedTurnList || mentionsTurnList || mentionsExcludeTurns
            }

            return mentionsMissingMethod
                && (attemptedTurnList || mentionsTurnList || mentionsExcludeTurns)
                || (attemptedTurnList && mentionsUnsupportedPagination)
                || (mentionsExcludeTurns && mentionsUnsupportedField)
        default:
            return false
        }
    }

    // Switches the current runtime back to legacy embedded-turn reads for the rest of the connection.
    @discardableResult
    func consumeUnsupportedTurnPagination(_ error: Error, attemptedMethod: String? = nil) -> Bool {
        guard shouldDisableTurnPagination(error, attemptedMethod: attemptedMethod) else {
            return false
        }

        markTurnPaginationUnsupportedForCurrentRuntime()
        return true
    }

    func markTurnPaginationUnsupportedForCurrentRuntime() {
        guard supportsTurnPagination else {
            return
        }

        supportsTurnPagination = false
        olderThreadHistoryCursorByThreadID.removeAll()
        exhaustedOlderThreadHistoryCursorByThreadID.removeAll()
        loadingOlderThreadHistoryIDs.removeAll()
        olderHistoryLoadErrorByThreadID.removeAll()
        persistThreadHistoryPaginationState()
        refreshAllThreadTimelineStates()
    }
}

private extension CodexService {
    // Litter uses codex_cli_rs/0.125.0 as the minimum app-server turn-pagination version.
    func codexCLIUserAgentVersion(_ userAgent: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = userAgent.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              parts[0] == "codex_cli_rs" else {
            return nil
        }

        let versionParts = parts[1].split(separator: ".")
        guard versionParts.count >= 2,
              let major = Int(versionParts[0]),
              let minor = Int(versionParts[1]) else {
            return nil
        }

        let patchText = versionParts.dropFirst(2).first.map { String($0.prefix { $0.isNumber }) } ?? "0"
        return (major, minor, Int(patchText) ?? 0)
    }

    func codexVersion(
        _ lhs: (major: Int, minor: Int, patch: Int),
        isOlderThan rhs: (major: Int, minor: Int, patch: Int)
    ) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}
