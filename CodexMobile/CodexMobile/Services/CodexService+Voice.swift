// FILE: CodexService+Voice.swift
// Purpose: Resolves a ChatGPT token from the bridge and transcribes voice clips directly from the phone.
// Layer: Service
// Exports: CodexVoiceTranscriptionPreflight, CodexService voice helpers
// Depends on: Foundation, RPCMessage, JSONValue

import Foundation

struct CodexVoiceTranscriptionPreflight: Equatable, Sendable {
    static let maxDurationSeconds: TimeInterval = 60
    static let maxByteCount: Int = 10 * 1024 * 1024

    let byteCount: Int
    let durationSeconds: TimeInterval

    var failureMessage: String? {
        if durationSeconds > Self.maxDurationSeconds {
            return "Voice clips must be 60 seconds or less."
        }

        if byteCount > Self.maxByteCount {
            return "Voice clips must be smaller than 10 MB."
        }

        return nil
    }

    func validate() throws {
        if let failureMessage {
            throw CodexServiceError.invalidInput(failureMessage)
        }
    }
}

extension CodexService {
    // Transcribes a local WAV clip by resolving a ChatGPT token from the bridge,
    // then calling the ChatGPT transcription API directly from the phone.
    func transcribeVoiceAudioFile(at url: URL, durationSeconds: TimeInterval) async throws -> String {
        guard isConnected else {
            throw CodexServiceError.disconnected
        }

        let audioData = try Data(contentsOf: url)
        let preflight = CodexVoiceTranscriptionPreflight(
            byteCount: audioData.count,
            durationSeconds: durationSeconds
        )
        try preflight.validate()

        let token: String
        do {
            token = try await resolveVoiceAuthToken()
        } catch {
            // Refresh auth state so the Settings UI reflects the real token situation.
            Task { await refreshGPTAccountState() }
            throw error
        }

        do {
            return try await GPTVoiceTranscriptionManager.transcribe(wavData: audioData, token: token)
        } catch GPTVoiceTranscriptionError.authExpired {
            Task { await refreshGPTAccountState() }
            let freshToken = try await resolveVoiceAuthToken()
            return try await GPTVoiceTranscriptionManager.transcribe(wavData: audioData, token: freshToken)
        }
    }

    // Asks the bridge for an ephemeral ChatGPT token over the E2E encrypted channel.
    private func resolveVoiceAuthToken() async throws -> String {
        let response: RPCMessage
        do {
            response = try await sendRequest(method: "voice/resolveAuth", params: nil)
        } catch {
            _ = consumeUnsupportedVoiceBridgeAuth(error)
            throw error
        }

        guard let payload = response.result?.objectValue,
              let token = payload["token"]?.stringValue,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexServiceError.invalidResponse("voice/resolveAuth did not return a valid token")
        }

        return token
    }
}
