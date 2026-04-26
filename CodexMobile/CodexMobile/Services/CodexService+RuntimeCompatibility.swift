// FILE: CodexService+RuntimeCompatibility.swift
// Purpose: Centralizes app-server compatibility fallbacks that can be learned per bridge session.
// Layer: Service
// Exports: CodexService runtime compatibility helpers
// Depends on: Foundation

import Foundation

extension CodexService {
    // Consumes a rejected serviceTier field once, then remembers the bridge limitation for the session.
    func consumeUnsupportedServiceTier(
        _ error: Error,
        includesServiceTier: inout Bool
    ) -> Bool {
        guard includesServiceTier,
              shouldRetryTurnStartWithoutServiceTier(error) else {
            return false
        }

        markServiceTierUnsupportedForCurrentBridge()
        includesServiceTier = false
        return true
    }

    func shouldRetryTurnStartWithoutServiceTier(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        guard rpcError.code == -32600 || rpcError.code == -32602 else {
            return false
        }

        let message = rpcError.message.lowercased()
        return message.contains("servicetier")
            || message.contains("service tier")
            || message.contains("unknown field")
            || message.contains("unexpected field")
            || message.contains("unrecognized field")
            || message.contains("invalid param")
            || message.contains("invalid params")
    }

    func markServiceTierUnsupportedForCurrentBridge() {
        supportsServiceTier = false

        guard selectedServiceTier != nil,
              !hasPresentedServiceTierBridgeUpdatePrompt else {
            return
        }

        hasPresentedServiceTierBridgeUpdatePrompt = true
        bridgeUpdatePrompt = serviceTierBridgeUpdatePrompt
    }
}

private extension CodexService {
    var serviceTierBridgeUpdatePrompt: CodexBridgeUpdatePrompt {
        CodexBridgeUpdatePrompt(
            title: "Update Remodex on your computer to use Speed controls",
            message: "This computer bridge does not support the selected speed setting yet. Update the Remodex npm package to use Fast Mode and other speed controls.",
            command: "npm install -g remodex@latest"
        )
    }
}
