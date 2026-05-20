// FILE: CodexService+Voice.swift
// Purpose: Transcribes local voice clips through the bridge, with the legacy phone upload as a reliability fallback.
// Layer: Service
// Exports: CodexVoiceTranscriptionPreflight, CodexService voice helpers
// Depends on: Foundation, RPCMessage, JSONValue

import Foundation

struct CodexVoiceTranscriptionPreflight: Equatable, Sendable {
    static let maxDurationSeconds: TimeInterval = 120
    static let maxByteCount: Int = 10 * 1024 * 1024

    let byteCount: Int
    let durationSeconds: TimeInterval

    var failureMessage: String? {
        if !durationSeconds.isFinite || durationSeconds <= 0 {
            return "Voice clips must include recorded audio."
        }

        if durationSeconds > Self.maxDurationSeconds {
            return "Voice clips must be 120 seconds or less."
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
    // Prefers bridge-owned transcription, then falls back to the prior phone-upload flow if the bridge/provider rejects it.
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
        try Self.validateVoiceWAVData(audioData)

        do {
            return try await transcribeVoiceViaBridge(audioData: audioData, durationSeconds: durationSeconds)
        } catch {
            let bridgeMethodUnsupported = consumeUnsupportedVoiceBridgeMethod(error)
            if bridgeMethodUnsupported || shouldAttemptLegacyVoiceUploadFallback(after: error) {
                do {
                    return try await transcribeVoiceDirectlyFromPhone(audioData: audioData)
                } catch {
                    handleVoiceTranscriptionTerminalFailure(error)
                    throw error
                }
            }

            handleVoiceTranscriptionTerminalFailure(error)
            throw error
        }
    }

    private func transcribeVoiceViaBridge(audioData: Data, durationSeconds: TimeInterval) async throws -> String {
        let response: RPCMessage
        response = try await sendRequest(
            method: "voice/transcribe",
            params: .object([
                "mimeType": .string("audio/wav"),
                "audioBase64": .string(audioData.base64EncodedString()),
                "sampleRateHz": .integer(24_000),
                "durationMs": .integer(Int((durationSeconds * 1_000).rounded())),
            ])
        )

        guard let text = response.result?.objectValue?["text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw CodexServiceError.invalidResponse("voice/transcribe did not return transcript text")
        }

        return text
    }

    private func shouldAttemptLegacyVoiceUploadFallback(after error: Error) -> Bool {
        switch classifyVoiceFailure(error) {
        case .providerAuthenticationRejected, .bridgeSessionUnsupported:
            return true
        default:
            return false
        }
    }

    private func transcribeVoiceDirectlyFromPhone(audioData: Data) async throws -> String {
        let token: String
        do {
            token = try await resolveVoiceAuthToken()
        } catch {
            Task { await refreshGPTAccountState() }
            throw error
        }

        do {
            return try await GPTVoiceTranscriptionManager.transcribe(wavData: audioData, token: token)
        } catch GPTVoiceTranscriptionError.authExpired {
            Task { await refreshGPTAccountState() }
            let freshToken = try await resolveVoiceAuthToken()
            do {
                return try await GPTVoiceTranscriptionManager.transcribe(wavData: audioData, token: freshToken)
            } catch GPTVoiceTranscriptionError.authExpired {
                markGPTVoiceReauthenticationRequired()
                throw GPTVoiceTranscriptionError.authExpired
            }
        } catch {
            Task { await refreshGPTAccountState() }
            throw error
        }
    }

    private func handleVoiceTranscriptionTerminalFailure(_ error: Error) {
        switch classifyVoiceFailure(error) {
        case .providerAuthenticationRejected, .macReauthenticationRequired:
            markGPTVoiceReauthenticationRequired()
        default:
            Task { await refreshGPTAccountState() }
        }
    }

    // Asks the bridge for an ephemeral ChatGPT token over the E2E encrypted channel.
    private func resolveVoiceAuthToken() async throws -> String {
        let response: RPCMessage
        do {
            response = try await sendRequest(method: "voice/resolveAuth", params: nil)
        } catch {
            _ = consumeUnsupportedVoiceBridgeMethod(error)
            throw error
        }

        guard let payload = response.result?.objectValue,
              let rawToken = payload["token"]?.stringValue else {
            throw CodexServiceError.invalidResponse("voice/resolveAuth did not return a valid token")
        }

        let token = rawToken
            .replacingOccurrences(of: #"(?i)^bearer\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw CodexServiceError.invalidResponse("voice/resolveAuth did not return a valid token")
        }

        return token
    }

    // Parses chunked WAV metadata instead of assuming the fmt/data chunks sit at fixed offsets.
    private static func validateVoiceWAVData(_ data: Data) throws {
        guard data.count >= 44,
              data.asciiString(in: 0..<4) == "RIFF",
              data.asciiString(in: 8..<12) == "WAVE" else {
            throw CodexServiceError.invalidInput("The recorded audio is not a valid WAV file.")
        }

        var cursor = 12
        var formatCode: UInt16?
        var channelCount: UInt16?
        var sampleRate: UInt32?
        var bitsPerSample: UInt16?
        var hasAudioData = false

        while cursor + 8 <= data.count {
            guard let chunkID = data.asciiString(in: cursor..<(cursor + 4)),
                  let chunkSize = data.uint32LittleEndian(at: cursor + 4) else {
                break
            }

            let payloadStart = cursor + 8
            let payloadSize = Int(chunkSize)
            let payloadEnd = payloadStart + payloadSize
            guard payloadEnd <= data.count else {
                throw CodexServiceError.invalidInput("The recorded audio is not a valid WAV file.")
            }

            if chunkID == "fmt " {
                guard payloadSize >= 16 else {
                    throw CodexServiceError.invalidInput("The recorded audio is not a valid WAV file.")
                }
                formatCode = data.uint16LittleEndian(at: payloadStart)
                channelCount = data.uint16LittleEndian(at: payloadStart + 2)
                sampleRate = data.uint32LittleEndian(at: payloadStart + 4)
                bitsPerSample = data.uint16LittleEndian(at: payloadStart + 14)
            } else if chunkID == "data" {
                hasAudioData = payloadSize > 0
            }

            cursor = payloadEnd + (payloadSize.isMultiple(of: 2) ? 0 : 1)
        }

        guard hasAudioData else {
            throw CodexServiceError.invalidInput("The recorded audio is not a valid WAV file.")
        }

        guard formatCode == 1,
              channelCount == 1,
              sampleRate == 24_000,
              bitsPerSample == 16 else {
            throw CodexServiceError.invalidInput("Voice transcription requires 24 kHz mono WAV audio.")
        }
    }
}

private extension Data {
    func asciiString(in range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= count else {
            return nil
        }

        return String(data: subdata(in: range), encoding: .ascii)
    }

    func uint16LittleEndian(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else {
            return nil
        }

        return UInt16(byte(at: offset))
            | (UInt16(byte(at: offset + 1)) << 8)
    }

    func uint32LittleEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else {
            return nil
        }

        return UInt32(byte(at: offset))
            | (UInt32(byte(at: offset + 1)) << 8)
            | (UInt32(byte(at: offset + 2)) << 16)
            | (UInt32(byte(at: offset + 3)) << 24)
    }

    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }
}
