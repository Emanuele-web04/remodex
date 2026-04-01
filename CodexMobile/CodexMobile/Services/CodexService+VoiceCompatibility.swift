// FILE: CodexService+VoiceCompatibility.swift
// Purpose: Maps voice-mode runtime failures into stable recovery reasons the UI can present cleanly.
// Layer: Service
// Exports: CodexVoiceFailureReason, CodexService voice compatibility helpers
// Depends on: Foundation, CodexServiceError, GPTVoiceTranscriptionError

import Foundation

enum CodexVoiceFailureReason: Equatable {
    case reconnectRequired
    case bridgeSessionUnsupported
    case macLoginRequired
    case macReauthenticationRequired
    case voiceSyncInProgress
    case chatGPTRequired
    case microphonePermissionRequired
    case microphoneUnavailable
    case recorderUnavailable
    case generic(String)
}

extension CodexService {
    // Learns that this bridge predates the bridge-owned voice RPCs so future mic taps can short-circuit immediately.
    func consumeUnsupportedVoiceBridgeAuth(_ error: Error) -> Bool {
        guard shouldTreatAsUnsupportedVoiceBridgeAuth(error) else {
            return false
        }

        supportsBridgeVoiceAuth = false
        return true
    }

    // Normalizes voice failures from the recorder, bridge RPC, and transcription API into UI-friendly buckets.
    func classifyVoiceFailure(_ error: Error) -> CodexVoiceFailureReason {
        if !supportsBridgeVoiceAuth || shouldTreatAsUnsupportedVoiceBridgeAuth(error) {
            return .bridgeSessionUnsupported
        }

        if let voiceError = error as? GPTVoiceTranscriptionError {
            return classifyVoiceFailure(voiceError)
        }

        guard let serviceError = error as? CodexServiceError else {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return .generic(message.isEmpty ? "Voice transcription failed." : message)
        }

        switch serviceError {
        case .disconnected:
            return .reconnectRequired
        case .invalidInput(let reason), .invalidResponse(let reason):
            return classifyVoiceFailureMessage(reason)
        case .rpcError(let rpcError):
            if let classifiedRPCError = classifyVoiceRPCError(rpcError) {
                return classifiedRPCError
            }
            return classifyVoiceFailureMessage(rpcError.message)
        case .invalidServerURL(_), .encodingFailed, .noPendingApproval:
            return .generic(serviceError.localizedDescription)
        }
    }

    func shouldTreatAsUnsupportedVoiceBridgeAuth(_ error: Error) -> Bool {
        guard let serviceError = error as? CodexServiceError,
              case .rpcError(let rpcError) = serviceError else {
            return false
        }

        if rpcError.code == -32601 {
            return true
        }

        let message = rpcError.message.lowercased()
        let mentionsUnsupportedRequest = message.contains("method not found")
            || message.contains("unknown method")
            || message.contains("not implemented")
            || message.contains("does not support")
            || message.contains("unknown variant")
            || message.contains("expected one of")
        let mentionsBridgeVoiceMethod = message.contains("voice/resolveauth")
            || message.contains("voice resolveauth")
            || message.contains("voice/resolveauth`")
            || message.contains("voice/transcribe")
            || message.contains("voice transcribe")
            || message.contains("voice/transcribe`")

        guard rpcError.code == -32600 || rpcError.code == -32602 || rpcError.code == -32000 else {
            return mentionsUnsupportedRequest && mentionsBridgeVoiceMethod
        }

        return mentionsUnsupportedRequest && mentionsBridgeVoiceMethod
    }

    private func classifyVoiceFailure(_ error: GPTVoiceTranscriptionError) -> CodexVoiceFailureReason {
        switch error {
        case .microphonePermissionDenied:
            return .microphonePermissionRequired
        case .missingMicrophoneInput:
            return .microphoneUnavailable
        case .unableToConfigureAudioSession,
             .unableToPrepareAudioEngine,
             .unableToCreateOutputFile,
             .alreadyRecording,
             .notRecording:
            return .recorderUnavailable
        case .authExpired:
            return .macReauthenticationRequired
        case .transcriptionFailed(let message):
            return classifyVoiceFailureMessage(message)
        }
    }

    private func classifyVoiceRPCError(_ rpcError: RPCError) -> CodexVoiceFailureReason? {
        let bridgeErrorCode = rpcError.data?.objectValue?["errorCode"]?.stringValue?.lowercased()
        switch bridgeErrorCode {
        case "auth_unavailable":
            return .reconnectRequired
        case "token_missing", "not_authenticated":
            return classifyMissingVoiceTokenState()
        case "not_chatgpt":
            return .chatGPTRequired
        default:
            return nil
        }
    }

    private func classifyMissingVoiceTokenState() -> CodexVoiceFailureReason {
        if gptAccountSnapshot.needsReauth || gptAccountSnapshot.status == .expired {
            return .macReauthenticationRequired
        }

        if gptAccountSnapshot.isAuthenticated && !gptAccountSnapshot.isVoiceTokenReady {
            return .voiceSyncInProgress
        }

        if gptAccountSnapshot.hasActiveLogin
            || gptAccountSnapshot.status == .notLoggedIn
            || gptAccountSnapshot.status == .unknown {
            return .macLoginRequired
        }

        return .chatGPTRequired
    }

    // Clears auth-driven recovery once the refreshed snapshot is healthy again.
    // used by: TurnView voice recovery banner
    private func resolveAuthSensitiveVoiceRecoveryReason() -> CodexVoiceFailureReason? {
        guard !gptAccountSnapshot.isAuthenticated || !gptAccountSnapshot.isVoiceTokenReady else {
            return nil
        }

        return classifyMissingVoiceTokenState()
    }

    // Re-derives auth-sensitive voice recovery from the latest bridge snapshot so stale
    // in-flight refreshes do not leave the banner stuck on the wrong instruction.
    func resolveVoiceRecoveryReason(_ reason: CodexVoiceFailureReason) -> CodexVoiceFailureReason? {
        switch reason {
        case .macLoginRequired, .macReauthenticationRequired, .voiceSyncInProgress:
            return resolveAuthSensitiveVoiceRecoveryReason()
        default:
            return reason
        }
    }

    private func classifyVoiceFailureMessage(_ message: String) -> CodexVoiceFailureReason {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .generic("Voice transcription failed.")
        }

        let normalized = trimmed.lowercased()
        if (normalized.contains("voice/resolveauth") || normalized.contains("voice/transcribe"))
            && normalized.contains("unknown variant") {
            return .bridgeSessionUnsupported
        }
        if normalized.contains("connect to your mac before using voice transcription")
            || normalized == CodexServiceError.disconnected.localizedDescription.lowercased()
            || normalized.contains("bridge running")
            || normalized.contains("reconnect") {
            return .reconnectRequired
        }
        if normalized.contains("microphone access") {
            return .microphonePermissionRequired
        }
        if normalized.contains("no valid microphone input") {
            return .microphoneUnavailable
        }
        if normalized.contains("unable to configure the microphone")
            || normalized.contains("unable to prepare the microphone")
            || normalized.contains("unable to create the temporary audio file") {
            return .recorderUnavailable
        }
        if normalized.contains("chatgpt login has expired")
            || normalized.contains("fresh sign-in")
            || normalized.contains("sign in again") {
            return .macReauthenticationRequired
        }
        if normalized.contains("waiting for voice sync") {
            return .voiceSyncInProgress
        }
        if normalized.contains("sign in to chatgpt")
            || normalized.contains("no chatgpt session token") {
            return classifyMissingVoiceTokenState()
        }
        if normalized.contains("requires a chatgpt account") {
            return .chatGPTRequired
        }

        return .generic(trimmed)
    }
}
