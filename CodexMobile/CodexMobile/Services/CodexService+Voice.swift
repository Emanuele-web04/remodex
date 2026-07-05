// FILE: CodexService+Voice.swift
// Purpose: Transcribes local voice clips through the bridge, with the legacy phone upload as a reliability fallback.
// Layer: Service
// Exports: CodexVoiceTranscriptionPreflight, CodexService voice helpers
// Depends on: Foundation, RPCMessage, JSONValue

import Foundation

private func codexLogVoiceTranscription(_ message: String) {
    print("[VOICE] \(message)")
}

struct CodexVoiceTranscriptionPreflight: Equatable, Sendable {
    static let maxDurationSeconds: TimeInterval = 150
    static let maxByteCount: Int = 10 * 1024 * 1024
    static let requestTimeoutNanoseconds: UInt64 = 180_000_000_000
    private static let maxDurationDisplaySeconds = Int(maxDurationSeconds)

    let byteCount: Int
    let durationSeconds: TimeInterval

    var failureMessage: String? {
        if !durationSeconds.isFinite || durationSeconds <= 0 {
            return "Voice clips must include recorded audio."
        }

        if durationSeconds > Self.maxDurationSeconds {
            return "Voice clips must be \(Self.maxDurationDisplaySeconds) seconds or less."
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

private struct VoiceTranscriptionRequestPayload: Sendable {
    let audioData: Data
    let audioBase64: String
    let mimeType: String
    let byteCount: Int
    let durationSeconds: TimeInterval
    let durationMilliseconds: Int
}

extension CodexService {
    // Fire-and-forget: asks the bridge to warm provider/auth state and report
    // supported audio formats. Errors are swallowed so older bridges keep working.
    func prewarmVoiceTranscription() {
        guard isConnected, supportsBridgeVoiceTranscription else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let response = try? await sendRequest(
                method: "voice/prewarm",
                params: nil,
                timeoutNanoseconds: 10_000_000_000,
                timeoutMessage: "voice/prewarm timed out"
            ) else {
                return
            }
            updateVoiceTranscriptionFormats(from: response)
        }
    }

    var prefersM4AVoiceTranscription: Bool {
        supportsBridgeVoiceTranscription && supportedBridgeVoiceTranscriptionFormats.contains("m4a")
    }

    private func updateVoiceTranscriptionFormats(from response: RPCMessage) {
        guard let formats = response.result?.objectValue?["formats"]?.arrayValue?.compactMap(\.stringValue),
              !formats.isEmpty else {
            return
        }
        supportedBridgeVoiceTranscriptionFormats = Set(formats.map { $0.lowercased() })
        if supportedBridgeVoiceTranscriptionFormats.isEmpty {
            supportedBridgeVoiceTranscriptionFormats = ["wav"]
        }
    }

    // Prefers bridge-owned transcription, then falls back to the prior phone-upload flow if the bridge/provider rejects it.
    func transcribeVoiceAudioFile(
        at url: URL,
        durationSeconds: TimeInterval,
        mimeType: String = "audio/wav"
    ) async throws -> String {
        guard isConnected else {
            throw CodexServiceError.disconnected
        }

        let payload = try await Self.prepareVoiceTranscriptionPayload(
            at: url,
            durationSeconds: durationSeconds,
            mimeType: mimeType
        )
        codexLogVoiceTranscription(
            "transcription request prepared duration=\(String(format: "%.1f", payload.durationSeconds))s bytes=\(payload.byteCount)"
        )

        guard supportsBridgeVoiceTranscription else {
            codexLogVoiceTranscription("bridge transcription unavailable; legacy fallback starting")
            do {
                return try await transcribeVoiceDirectlyFromPhone(audioData: payload.audioData, mimeType: payload.mimeType)
            } catch {
                handleVoiceTranscriptionTerminalFailure(error)
                codexLogVoiceTranscription("legacy transcription fallback failed: \(classifyVoiceFailure(error))")
                throw error
            }
        }

        do {
            return try await transcribeVoiceViaBridge(payload: payload)
        } catch {
            let bridgeMethodUnsupported = consumeUnsupportedVoiceBridgeMethod(error)
            if bridgeMethodUnsupported || shouldAttemptLegacyVoiceUploadFallback(after: error) {
                codexLogVoiceTranscription("bridge transcription fallback starting: \(classifyVoiceFailure(error))")
                do {
                    return try await transcribeVoiceDirectlyFromPhone(audioData: payload.audioData, mimeType: payload.mimeType)
                } catch {
                    handleVoiceTranscriptionTerminalFailure(error)
                    codexLogVoiceTranscription("legacy transcription fallback failed: \(classifyVoiceFailure(error))")
                    throw error
                }
            }

            handleVoiceTranscriptionTerminalFailure(error)
            codexLogVoiceTranscription("bridge transcription failed: \(classifyVoiceFailure(error))")
            throw error
        }
    }

    private func transcribeVoiceViaBridge(payload: VoiceTranscriptionRequestPayload) async throws -> String {
        let response: RPCMessage
        codexLogVoiceTranscription(
            "voice/transcribe sending durationMs=\(payload.durationMilliseconds) bytes=\(payload.byteCount)"
        )
        response = try await sendRequest(
            method: "voice/transcribe",
            params: .object([
                "mimeType": .string(payload.mimeType),
                "audioBase64": .string(payload.audioBase64),
                "sampleRateHz": .integer(24_000),
                "durationMs": .integer(payload.durationMilliseconds),
            ]),
            timeoutNanoseconds: CodexVoiceTranscriptionPreflight.requestTimeoutNanoseconds,
            timeoutMessage: "Voice transcription timed out. Try a shorter clip or retry when the connection is stable."
        )

        guard let text = response.result?.objectValue?["text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw CodexServiceError.invalidResponse("voice/transcribe did not return transcript text")
        }

        codexLogVoiceTranscription("voice/transcribe succeeded chars=\(text.count)")
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

    private func transcribeVoiceDirectlyFromPhone(audioData: Data, mimeType: String) async throws -> String {
        let token: String
        do {
            token = try await resolveVoiceAuthToken()
        } catch {
            Task { await refreshGPTAccountState() }
            throw error
        }

        do {
            let transcript = try await GPTVoiceTranscriptionManager.transcribe(
                audioData: audioData,
                mimeType: mimeType,
                token: token
            )
            codexLogVoiceTranscription("legacy phone transcription succeeded chars=\(transcript.count)")
            return transcript
        } catch GPTVoiceTranscriptionError.authExpired {
            Task { await refreshGPTAccountState() }
            let freshToken = try await resolveVoiceAuthToken()
            do {
                let transcript = try await GPTVoiceTranscriptionManager.transcribe(
                    audioData: audioData,
                    mimeType: mimeType,
                    token: freshToken
                )
                codexLogVoiceTranscription("legacy phone transcription succeeded after refresh chars=\(transcript.count)")
                return transcript
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
    private nonisolated static func prepareVoiceTranscriptionPayload(
        at url: URL,
        durationSeconds: TimeInterval,
        mimeType: String
    ) async throws -> VoiceTranscriptionRequestPayload {
        try await Task.detached(priority: .userInitiated) {
            let audioData = try Data(contentsOf: url)
            let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let preflight = CodexVoiceTranscriptionPreflight(
                byteCount: audioData.count,
                durationSeconds: durationSeconds
            )
            try preflight.validate()
            switch normalizedMimeType {
            case "audio/wav":
                try validateVoiceWAVData(audioData)
            case "audio/mp4":
                try validateVoiceM4AData(audioData)
            default:
                throw CodexServiceError.invalidInput("Voice transcription supports WAV or M4A audio.")
            }

            return VoiceTranscriptionRequestPayload(
                audioData: audioData,
                audioBase64: audioData.base64EncodedString(),
                mimeType: normalizedMimeType,
                byteCount: audioData.count,
                durationSeconds: durationSeconds,
                durationMilliseconds: Int((durationSeconds * 1_000).rounded())
            )
        }.value
    }

    // Parses chunked WAV metadata instead of assuming the fmt/data chunks sit at fixed offsets.
    private nonisolated static func validateVoiceWAVData(_ data: Data) throws {
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

    private nonisolated static func validateVoiceM4AData(_ data: Data) throws {
        guard data.count >= 16,
              let ftypSize = data.uint32BigEndian(at: 0),
              ftypSize >= 16,
              Int(ftypSize) <= data.count,
              data.asciiString(in: 4..<8) == "ftyp" else {
            throw CodexServiceError.invalidInput("The recorded audio is not a valid M4A file.")
        }

        let majorBrand = data.asciiString(in: 8..<12)
        var brands: Set<String> = []
        if let majorBrand {
            brands.insert(majorBrand)
        }
        var cursor = 16
        while cursor + 4 <= Int(ftypSize) {
            if let brand = data.asciiString(in: cursor..<(cursor + 4)) {
                brands.insert(brand)
            }
            cursor += 4
        }

        guard brands.contains("M4A ") else {
            throw CodexServiceError.invalidInput("The recorded audio is not a valid M4A file.")
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

    func uint32BigEndian(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else {
            return nil
        }

        return (UInt32(byte(at: offset)) << 24)
            | (UInt32(byte(at: offset + 1)) << 16)
            | (UInt32(byte(at: offset + 2)) << 8)
            | UInt32(byte(at: offset + 3))
    }

    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }
}
