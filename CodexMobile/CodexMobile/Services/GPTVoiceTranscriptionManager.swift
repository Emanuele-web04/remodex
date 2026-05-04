// FILE: GPTVoiceTranscriptionManager.swift
// Purpose: Captures microphone audio with AVAudioEngine and produces normalized 24 kHz mono WAV clips for bridge transcription.
// Layer: Service
// Exports: GPTVoiceRecordingClip, GPTVoiceTranscriptionManager
// Depends on: AVFoundation, Foundation

import AVFoundation
import Combine
import Foundation

private func codexLogVoiceRecording(_ message: String) {
    print("[VOICE] \(message)")
}

struct GPTVoiceRecordingClip: Sendable {
    let url: URL
    let durationSeconds: TimeInterval
    let byteCount: Int
}

enum GPTVoiceTranscriptionError: LocalizedError {
    case alreadyRecording
    case notRecording
    case microphonePermissionDenied
    case missingMicrophoneInput
    case unableToConfigureAudioSession
    case unableToPrepareAudioEngine
    case unableToCreateOutputFile
    case transcriptionFailed(String)
    case authExpired

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Voice recording is already running."
        case .notRecording:
            return "Voice recording is not running."
        case .microphonePermissionDenied:
            return "Microphone access is required for voice transcription."
        case .missingMicrophoneInput:
            return "No valid microphone input is available right now."
        case .unableToConfigureAudioSession:
            return "Unable to configure the microphone session."
        case .unableToPrepareAudioEngine:
            return "Unable to prepare the microphone recorder."
        case .unableToCreateOutputFile:
            return "Unable to create the temporary audio file."
        case .transcriptionFailed(let message):
            return message
        case .authExpired:
            return "Your ChatGPT login has expired. Sign in again."
        }
    }
}

final class GPTVoiceTranscriptionManager: ObservableObject {
    private let audioSession = AVAudioSession.sharedInstance()
    private static let targetSampleRate: Double = 24_000
    // Keeps enough metering history for the capsule to resample across the full composer width.
    private static let maxAudioLevels = 240

    private var engine: AVAudioEngine?
    private let collector = AudioBufferCollector()
    private var captureSampleRate: Double = 0
    private var isRecording = false
    private var durationTimer: Timer?

    /// Rolling window of normalized (0…1) amplitude samples for waveform visualization.
    @Published var audioLevels: [CGFloat] = []
    /// Elapsed seconds since recording started.
    @Published var recordingDuration: TimeInterval = 0

    // ─── Recording lifecycle ─────────────────────────────────────

    @MainActor
    func startRecording() async throws {
        codexLogVoiceRecording("start requested")
        guard !isRecording else {
            throw GPTVoiceTranscriptionError.alreadyRecording
        }

        let isPermissionGranted = await requestMicrophonePermission()
        codexLogVoiceRecording("microphone permission: \(isPermissionGranted ? "granted" : "denied")")
        guard isPermissionGranted else {
            throw GPTVoiceTranscriptionError.microphonePermissionDenied
        }

        do {
            try configureAudioSession()

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            guard format.sampleRate > 0, format.channelCount > 0 else {
                codexLogVoiceRecording(
                    "invalid microphone format sampleRate=\(format.sampleRate) channels=\(format.channelCount)"
                )
                throw GPTVoiceTranscriptionError.missingMicrophoneInput
            }

            codexLogVoiceRecording(
                "capture format sampleRate=\(format.sampleRate) channels=\(format.channelCount)"
            )

            captureSampleRate = format.sampleRate
            collector.reset()

            // Collect raw buffers on the tap thread and compute audio levels for the waveform.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [collector, weak self] buffer, _ in
                collector.append(buffer)

                // Compute RMS power for waveform visualization.
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }

                var sumOfSquares: Float = 0
                let ptr = channelData
                for i in 0..<frameCount {
                    let sample = ptr[i]
                    sumOfSquares += sample * sample
                }
                let rms = sqrt(sumOfSquares / Float(frameCount))
                let dB = 20 * log10(max(rms, 1e-6))
                let normalized = CGFloat(max(0, min(1, (dB + 50) / 50)))

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.audioLevels.append(normalized)
                    if self.audioLevels.count > Self.maxAudioLevels {
                        self.audioLevels.removeFirst(self.audioLevels.count - Self.maxAudioLevels)
                    }
                }
            }

            self.engine = engine
            isRecording = true

            engine.prepare()
            try engine.start()
            startDurationTimer()
            codexLogVoiceRecording("recording active")
        } catch let error as GPTVoiceTranscriptionError {
            teardownEngine()
            codexLogVoiceRecording("start failed: \(error.localizedDescription)")
            throw error
        } catch {
            teardownEngine()
            codexLogVoiceRecording("engine start threw: \(error.localizedDescription)")
            throw GPTVoiceTranscriptionError.unableToPrepareAudioEngine
        }
    }

    // Stops the capture, resamples collected audio to 24 kHz mono WAV, and returns the clip.
    @MainActor
    func stopRecording() throws -> GPTVoiceRecordingClip? {
        guard isRecording else { return nil }
        isRecording = false

        stopDurationTimer()
        teardownEngine()

        let buffers = collector.drain()
        guard !buffers.isEmpty else { return nil }

        // Flatten all captured float samples from the first channel.
        var allSamples = [Float]()
        for buf in buffers {
            guard let data = buf.floatChannelData?[0] else { continue }
            allSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buf.frameLength)))
        }

        guard !allSamples.isEmpty else { return nil }

        let resampled = Self.resample(allSamples, from: captureSampleRate, to: Self.targetSampleRate)
        guard !resampled.isEmpty else { return nil }

        let wavData = Self.encodeWAV(samples: resampled, sampleRate: UInt32(Self.targetSampleRate))

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remodex-voice-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            try wavData.write(to: fileURL)
        } catch {
            codexLogVoiceRecording("WAV write failed: \(error.localizedDescription)")
            throw GPTVoiceTranscriptionError.unableToCreateOutputFile
        }

        let durationSeconds = Double(resampled.count) / Self.targetSampleRate
        codexLogVoiceRecording("clip ready: \(String(format: "%.1f", durationSeconds))s, \(wavData.count) bytes")

        return GPTVoiceRecordingClip(
            url: fileURL,
            durationSeconds: durationSeconds,
            byteCount: wavData.count
        )
    }

    @MainActor
    func cancelRecording() {
        let wasRecording = isRecording
        isRecording = false

        stopDurationTimer()
        resetMeteringState()

        if wasRecording || engine != nil {
            teardownEngine()
        }
        collector.reset()
    }

    @MainActor
    func resetMeteringState() {
        audioLevels = []
        recordingDuration = 0
    }

    // ─── Duration timer ─────────────────────────────────────────

    @MainActor
    private func startDurationTimer() {
        recordingDuration = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.recordingDuration += 0.1
            }
        }
    }

    @MainActor
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // ─── Mic permission ──────────────────────────────────────────

    private func requestMicrophonePermission() async -> Bool {
#if os(iOS)
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                break
            @unknown default:
                return false
            }

            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
#endif
        switch audioSession.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            break
        @unknown default:
            return false
        }

        return await withCheckedContinuation { continuation in
            audioSession.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    // ─── Audio session ───────────────────────────────────────────

    @MainActor
    private func configureAudioSession() throws {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let inputs = audioSession.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
            codexLogVoiceRecording("active input route: \(inputs.isEmpty ? "none" : inputs.joined(separator: ", "))")
            codexLogVoiceRecording("hardware sampleRate=\(audioSession.sampleRate) channels=\(audioSession.inputNumberOfChannels)")

            guard !audioSession.currentRoute.inputs.isEmpty else {
                throw GPTVoiceTranscriptionError.missingMicrophoneInput
            }
        } catch {
            if let recordingError = error as? GPTVoiceTranscriptionError {
                throw recordingError
            }
            codexLogVoiceRecording("audio session config failed: \(error.localizedDescription)")
            throw GPTVoiceTranscriptionError.unableToConfigureAudioSession
        }
    }

    // ─── Engine teardown ─────────────────────────────────────────

    @MainActor
    private func teardownEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // ─── Resampling ──────────────────────────────────────────────

    // Resamples Float32 audio to Int16 at the target rate using linear interpolation.
    private static func resample(_ samples: [Float], from srcRate: Double, to dstRate: Double) -> [Int16] {
        guard !samples.isEmpty else { return [] }

        if abs(srcRate - dstRate) < 1.0 {
            return samples.map { floatToInt16($0) }
        }

        let ratio = dstRate / srcRate
        let outCount = Int(Double(samples.count) * ratio)
        guard outCount > 0 else { return [] }

        var out = [Int16](repeating: 0, count: outCount)
        let lastIndex = samples.count - 1

        for i in 0..<outCount {
            let srcIdx = Double(i) / ratio
            let idx = Int(srcIdx)
            let frac = Float(srcIdx - Double(idx))
            let s0 = samples[min(idx, lastIndex)]
            let s1 = samples[min(idx + 1, lastIndex)]
            out[i] = floatToInt16(s0 + frac * (s1 - s0))
        }

        return out
    }

    private static func floatToInt16(_ value: Float) -> Int16 {
        Int16(max(-1.0, min(1.0, value)) * Float(Int16.max))
    }

    // ─── WAV encoding ────────────────────────────────────────────

    // Builds a minimal RIFF/WAV file from 16-bit mono PCM samples.
    private static func encodeWAV(samples: [Int16], sampleRate: UInt32) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var wav = Data(capacity: 44 + Int(dataSize))

        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE(UInt32(36 + dataSize))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLE(UInt32(16))            // subchunk size
        wav.appendLE(UInt16(1))             // PCM format
        wav.appendLE(UInt16(1))             // mono
        wav.appendLE(sampleRate)            // sample rate
        wav.appendLE(sampleRate * 2)        // byte rate
        wav.appendLE(UInt16(2))             // block align
        wav.appendLE(UInt16(16))            // bits per sample
        wav.append(contentsOf: "data".utf8)
        wav.appendLE(dataSize)

        samples.withUnsafeBytes { rawBuffer in
            wav.append(contentsOf: rawBuffer)
        }

        return wav
    }
}

// ─── Direct ChatGPT transcription ────────────────────────────────

extension GPTVoiceTranscriptionManager {
    private static let chatGPTTranscriptionURL = URL(string: "https://chatgpt.com/backend-api/transcribe")!
    static var transcribeOverride: ((Data, String) async throws -> String)?

    static func transcribe(wavData: Data, token: String) async throws -> String {
        if let transcribeOverride {
            return try await transcribeOverride(wavData, token)
        }

        let boundary = "Remodex-\(UUID().uuidString)"

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\n")
        body.appendUTF8("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: chatGPTTranscriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GPTVoiceTranscriptionError.transcriptionFailed("Invalid HTTP response.")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw GPTVoiceTranscriptionError.authExpired
        }

        guard (200..<300).contains(http.statusCode) else {
            let serverMessage = extractErrorMessage(from: data)
            throw GPTVoiceTranscriptionError.transcriptionFailed(
                serverMessage ?? "Transcription failed (\(http.statusCode))."
            )
        }

        return try decodeTranscriptText(from: data)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String { return msg }
        return json["message"] as? String
    }

    private static func decodeTranscriptText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GPTVoiceTranscriptionError.transcriptionFailed("Could not parse transcript response.")
        }
        for key in ["text", "transcript"] {
            if let text = json[key] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw GPTVoiceTranscriptionError.transcriptionFailed("Transcript response was empty.")
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

// ─── Thread-safe buffer collector ────────────────────────────────

private final class AudioBufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
    }

    func drain() -> [AVAudioPCMBuffer] {
        lock.lock()
        let result = buffers
        buffers = []
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        buffers = []
        lock.unlock()
    }
}

// ─── Data helpers ────────────────────────────────────────────────

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
