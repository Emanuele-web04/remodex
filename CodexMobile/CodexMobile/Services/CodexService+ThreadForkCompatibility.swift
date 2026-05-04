// FILE: CodexService+ThreadForkCompatibility.swift
// Purpose: Isolates bridge-compatibility fallbacks and upgrade prompts used only by native thread forking.
// Layer: Service
// Exports: CodexService thread-fork compatibility helpers
// Depends on: Foundation

import Foundation

extension CodexService {
    // Falls back to a minimal `thread/fork(threadId)` when older runtimes reject newer override fields.
    func consumeUnsupportedThreadForkOverrides(
        _ error: Error,
        usesMinimalForkParams: inout Bool
    ) -> Bool {
        guard !usesMinimalForkParams,
              shouldRetryThreadForkWithoutOverrides(error) else {
            return false
        }

        usesMinimalForkParams = true
        return true
    }

    func shouldRetryThreadForkWithoutOverrides(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        guard rpcError.code == -32600 || rpcError.code == -32602 || rpcError.code == -32000 else {
            return false
        }

        let message = rpcError.message.lowercased()
        let mentionsUnknownField = message.contains("unknown field")
            || message.contains("unexpected field")
            || message.contains("unrecognized field")
        let mentionsInvalidNamedField = (message.contains("invalid param") || message.contains("invalid params"))
            && (message.contains("field") || message.contains("parameter") || message.contains("param"))
        let mentionsForkOverride = message.contains("cwd")
            || message.contains("modelprovider")
            || message.contains("model provider")
            || message.contains("model")
            || message.contains("sandbox")

        return (mentionsUnknownField || mentionsInvalidNamedField) && mentionsForkOverride
    }

    // Learns that this runtime does not expose native thread forking and suppresses `/fork` for the session.
    func consumeUnsupportedThreadFork(_ error: Error) -> Bool {
        guard shouldTreatAsUnsupportedThreadFork(error) else {
            return false
        }

        markThreadForkUnsupportedForCurrentBridge()
        return true
    }

    func shouldTreatAsUnsupportedThreadFork(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code == -32601 {
            return true
        }

        let message = rpcError.message.lowercased()
        let mentionsUnsupportedMethod = message.contains("method not found")
            || message.contains("unknown method")
            || message.contains("not implemented")
            || message.contains("does not support")
        let mentionsForkSpecificUnsupported = (message.contains("thread/fork") || message.contains("thread fork"))
            && (message.contains("unsupported") || message.contains("not supported"))

        guard rpcError.code == -32600 || rpcError.code == -32602 || rpcError.code == -32000 else {
            return mentionsUnsupportedMethod || mentionsForkSpecificUnsupported
        }

        return mentionsUnsupportedMethod || mentionsForkSpecificUnsupported
    }

    func markThreadForkUnsupportedForCurrentBridge() {
        supportsThreadFork = false

        guard !hasPresentedThreadForkBridgeUpdatePrompt else {
            return
        }

        hasPresentedThreadForkBridgeUpdatePrompt = true
        bridgeUpdatePrompt = threadForkBridgeUpdatePrompt
    }
}

private extension CodexService {
    var threadForkBridgeUpdatePrompt: CodexBridgeUpdatePrompt {
        CodexBridgeUpdatePrompt(
            title: "Update Remodex on your Mac to use /fork",
            message: "This Mac bridge does not support native conversation forks yet. Update the Remodex npm package to use /fork and worktree fork flows.",
            command: "npm install -g remodex@latest"
        )
    }
}
