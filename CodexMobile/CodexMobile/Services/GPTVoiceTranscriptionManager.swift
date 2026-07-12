// FILE: GPTVoiceTranscriptionManager.swift
// Purpose: Captures microphone audio with AVAudioEngine and produces normalized 24 kHz mono WAV clips for voice transcription.
// Layer: Service
// Exports: GPTVoiceRecordingClip, GPTVoiceTranscriptionManager
// Depends on: AVFoundation, Foundation

import AVFoundation
import Combine
import Foundation

private func codexLogVoiceRecording(_ message: String) {
    print("[VOICE] \(message)")
}

private struct VoiceAudioSessionSnapshot: Sendable {
    let inputRoutes: [String]
    let sampleRate: Double
    let inputChannelCount: Int
}

struct GPTVoiceRecordingClip: Sendable {
    let url: URL
    let mimeType: String
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
    private static let audioSessionQueue = DispatchQueue(label: "com.remodex.voice.audio-session")
    private static let targetSampleRate: Double = 24_000
    private static let wavMimeType = "audio/wav"
    private static let m4aMimeType = "audio/mp4"
    private static let maxRecordingDurationSeconds = CodexVoiceTranscriptionPreflight.maxDurationSeconds
    // Keeps enough metering history for the capsule to fill the composer width.
    private static let maxAudioLevels = 240
    // One waveform bar per fixed time window. Aggregating tap buffers into
    // windows keeps the bar cadence deterministic: iOS treats installTap's
    // bufferSize as a hint, so real devices deliver buffers of varying size.
    static let meterWindowSeconds: TimeInterval = 0.08

    private var engine: AVAudioEngine?
    private let collector = AudioSampleCollector()
    private let meterAccumulator = MeterWindowAccumulator()
    private var captureSampleRate: Double = 0
    private var isRecording = false
    private var isStarting = false
    private var recordingSessionID = 0
    private var durationTimer: Timer?
    private var audioSessionObservers: [NSObjectProtocol] = []

    /// Rolling window of normalized (0…1) amplitude samples for waveform visualization.
    @Published var audioLevels: [CGFloat] = []
    /// Elapsed seconds since recording started.
    @Published var recordingDuration: TimeInterval = 0
    /// Incremented when iOS invalidates the capture path so views can reset their local mic state.
    @Published var captureInvalidationID = 0

    init() {
        installAudioSessionObservers()
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // ─── Recording lifecycle ─────────────────────────────────────

    @MainActor
    func startRecording() async throws {
        codexLogVoiceRecording("start requested")
        guard !isRecording, !isStarting else {
            throw GPTVoiceTranscriptionError.alreadyRecording
        }

        recordingSessionID += 1
        let sessionID = recordingSessionID
        isStarting = true

        let isPermissionGranted = await requestMicrophonePermission()
        codexLogVoiceRecording("microphone permission: \(isPermissionGranted ? "granted" : "denied")")
        guard isStarting, recordingSessionID == sessionID else {
            throw GPTVoiceTranscriptionError.notRecording
        }
        guard isPermissionGranted else {
            isStarting = false
            throw GPTVoiceTranscriptionError.microphonePermissionDenied
        }

        do {
            try await configureAudioSession()
            guard isStarting, recordingSessionID == sessionID else {
                teardownEngine()
                throw GPTVoiceTranscriptionError.notRecording
            }

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
            collector.beginSession(sessionID)

            resetMeteringState()

            meterAccumulator.beginSession(sampleRate: format.sampleRate)

            // Copy tap samples immediately; AVAudioEngine owns the callback buffer lifetime.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [collector, meterAccumulator, weak self] buffer, _ in
                guard let samples = collector.append(buffer, sessionID: sessionID) else { return }

                let newLevels = meterAccumulator.append(samples)
                guard !newLevels.isEmpty else { return }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.audioLevels.append(contentsOf: newLevels)
                    if self.audioLevels.count > Self.maxAudioLevels {
                        self.audioLevels.removeFirst(self.audioLevels.count - Self.maxAudioLevels)
                    }
                }
            }

            self.engine = engine

            engine.prepare()
            guard isStarting, recordingSessionID == sessionID else {
                teardownEngine()
                throw GPTVoiceTranscriptionError.notRecording
            }
            try engine.start()
            guard isStarting, recordingSessionID == sessionID else {
                teardownEngine()
                throw GPTVoiceTranscriptionError.notRecording
            }
            isStarting = false
            isRecording = true
            startDurationTimer()
            codexLogVoiceRecording("recording active")
        } catch let error as GPTVoiceTranscriptionError {
            teardownEngine()
            collector.reset()
            codexLogVoiceRecording("start failed: \(error.localizedDescription)")
            throw error
        } catch {
            teardownEngine()
            collector.reset()
            codexLogVoiceRecording("engine start threw: \(error.localizedDescription)")
            throw GPTVoiceTranscriptionError.unableToPrepareAudioEngine
        }
    }

    // Stops the capture, resamples collected audio to 24 kHz mono, and returns the clip.
    @MainActor
    func stopRecording(preferM4A: Bool = false) throws -> GPTVoiceRecordingClip? {
        guard isRecording else { return nil }
        let sessionID = recordingSessionID
        isRecording = false

        stopDurationTimer()
        teardownEngine()

        let allSamples = collector.drain(sessionID: sessionID)
        guard !allSamples.isEmpty else { return nil }

        let resampled = Self.resample(allSamples, from: captureSampleRate, to: Self.targetSampleRate)
        let maxSampleCount = Int(Self.targetSampleRate * Self.maxRecordingDurationSeconds)
        let boundedSamples = Array(resampled.prefix(maxSampleCount))
        guard !boundedSamples.isEmpty else { return nil }

        let durationSeconds = Double(boundedSamples.count) / Self.targetSampleRate
        let clipFile: (url: URL, mimeType: String, byteCount: Int)
        if preferM4A {
            clipFile = try Self.writeM4AFile(samples: boundedSamples)
        } else {
            clipFile = try Self.writeWAVFile(samples: boundedSamples)
        }
        codexLogVoiceRecording(
            "clip ready: \(String(format: "%.1f", durationSeconds))s, \(clipFile.byteCount) bytes mime=\(clipFile.mimeType)"
        )

        return GPTVoiceRecordingClip(
            url: clipFile.url,
            mimeType: clipFile.mimeType,
            durationSeconds: durationSeconds,
            byteCount: clipFile.byteCount
        )
    }

    @MainActor
    func cancelRecording() {
        let wasActive = isRecording || isStarting || engine != nil
        recordingSessionID += 1
        isStarting = false
        isRecording = false

        stopDurationTimer()
        resetMeteringState()

        if wasActive {
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
        } else {
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
#else
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
#endif
    }

    // ─── Audio session ───────────────────────────────────────────

    @MainActor
    private func configureAudioSession() async throws {
        do {
            let snapshot = try await Self.performAudioSessionWork {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
                try audioSession.setActive(true)
                return VoiceAudioSessionSnapshot(
                    inputRoutes: audioSession.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" },
                    sampleRate: audioSession.sampleRate,
                    inputChannelCount: audioSession.inputNumberOfChannels
                )
            }

            codexLogVoiceRecording("active input route: \(snapshot.inputRoutes.isEmpty ? "none" : snapshot.inputRoutes.joined(separator: ", "))")
            codexLogVoiceRecording("hardware sampleRate=\(snapshot.sampleRate) channels=\(snapshot.inputChannelCount)")

            guard !snapshot.inputRoutes.isEmpty else {
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

    // ─── Audio interruptions ────────────────────────────────────────

    private func installAudioSessionObservers() {
        let center = NotificationCenter.default
        audioSessionObservers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] notification in
                let typeRawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleAudioSessionInterruption(typeRawValue: typeRawValue)
                }
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] notification in
                let reasonRawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleAudioRouteChange(reasonRawValue: reasonRawValue)
                }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereLostNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.invalidateActiveCapture(reason: "audio media services were lost")
                }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.invalidateActiveCapture(reason: "audio media services were reset")
                }
            }
        ]
    }

    @MainActor
    private func handleAudioSessionInterruption(typeRawValue: UInt?) {
        guard let typeRawValue,
              AVAudioSession.InterruptionType(rawValue: typeRawValue) == .began else {
            return
        }

        invalidateActiveCapture(reason: "audio session interruption began")
    }

    @MainActor
    private func handleAudioRouteChange(reasonRawValue: UInt?) {
        guard isRecording || isStarting || engine != nil else {
            return
        }

        guard let reasonRawValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRawValue) else {
            cancelCaptureIfInputDisappeared(reason: "audio route changed: unknown")
            return
        }

        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory, .routeConfigurationChange:
            cancelCaptureIfInputDisappeared(reason: "audio route changed: \(String(describing: reason))")
        default:
            codexLogVoiceRecording("ignored audio route change: \(String(describing: reason))")
        }
    }

    @MainActor
    private func cancelCaptureIfInputDisappeared(reason: String) {
        guard audioSession.currentRoute.inputs.isEmpty else {
            codexLogVoiceRecording("\(reason); microphone input still available")
            return
        }

        invalidateActiveCapture(reason: reason)
    }

    @MainActor
    private func invalidateActiveCapture(reason: String) {
        guard isRecording || isStarting || engine != nil else {
            return
        }

        codexLogVoiceRecording("\(reason); cancelling active capture")
        cancelRecording()
        captureInvalidationID += 1
    }

    // ─── Engine teardown ─────────────────────────────────────────

    // Clears AVAudioEngine state after normal stops and failed starts so the next mic tap can retry.
    @MainActor
    private func teardownEngine() {
        isStarting = false
        isRecording = false
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        Self.deactivateAudioSessionInBackground()
    }

    // Keeps AVAudioSession activation/deactivation off the main actor to avoid
    // system-gesture stalls on iOS 26 while preserving ordering across retries.
    private static func performAudioSessionWork<T: Sendable>(
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            audioSessionQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func deactivateAudioSessionInBackground() {
        audioSessionQueue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                codexLogVoiceRecording("audio session deactivate failed: \(error.localizedDescription)")
            }
        }
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

    // ─── File encoding ───────────────────────────────────────────

    private static func writeWAVFile(samples: [Int16]) throws -> (url: URL, mimeType: String, byteCount: Int) {
        let wavData = encodeWAV(samples: samples, sampleRate: UInt32(targetSampleRate))
        let fileURL = temporaryVoiceURL(fileExtension: "wav")
        do {
            try wavData.write(to: fileURL)
            return (fileURL, wavMimeType, wavData.count)
        } catch {
            codexLogVoiceRecording("WAV write failed: \(error.localizedDescription)")
            throw GPTVoiceTranscriptionError.unableToCreateOutputFile
        }
    }

    private static func writeM4AFile(samples: [Int16]) throws -> (url: URL, mimeType: String, byteCount: Int) {
        let fileURL = temporaryVoiceURL(fileExtension: "m4a")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            throw GPTVoiceTranscriptionError.unableToCreateOutputFile
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            channel[index] = Float(samples[index]) / Float(Int16.max)
        }

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
            ]
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount > 0 else {
                throw GPTVoiceTranscriptionError.unableToCreateOutputFile
            }
            return (fileURL, m4aMimeType, byteCount)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            codexLogVoiceRecording("M4A write failed: \(error.localizedDescription)")
            throw GPTVoiceTranscriptionError.unableToCreateOutputFile
        }
    }

    private static func temporaryVoiceURL(fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remodex-voice-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
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
        try await transcribe(audioData: wavData, mimeType: wavMimeType, token: token)
    }

    static func transcribe(audioData: Data, mimeType: String, token: String) async throws -> String {
        if let transcribeOverride {
            return try await transcribeOverride(audioData, token)
        }

        let normalizedToken = token
            .replacingOccurrences(of: #"(?i)^bearer\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw GPTVoiceTranscriptionError.authExpired
        }

        let boundary = "Remodex-\(UUID().uuidString)"

        var body = Data()
        let fileExtension = mimeType == m4aMimeType ? "m4a" : "wav"
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"voice.\(fileExtension)\"\r\n")
        body.appendUTF8("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: chatGPTTranscriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(normalizedToken)", forHTTPHeaderField: "Authorization")
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

// ─── Thread-safe sample collector ────────────────────────────────

// Converts the audio-thread sample stream into one normalized waveform level
// per fixed time window (`meterWindowSeconds`), independent of how iOS sizes
// the tap buffers. Each emitted level is the RMS power of exactly one window,
// so a bar's height is the decibel reading of that moment and never changes.
private final class MeterWindowAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var windowSampleCount = 1
    private var sumOfSquares: Float = 0
    private var sampleCount = 0

    func beginSession(sampleRate: Double) {
        lock.lock()
        windowSampleCount = max(1, Int(sampleRate * GPTVoiceTranscriptionManager.meterWindowSeconds))
        sumOfSquares = 0
        sampleCount = 0
        lock.unlock()
    }

    /// Feeds tap samples and returns the levels for every window completed by
    /// this buffer (usually zero or one; more when a large buffer spans several).
    func append(_ samples: [Float]) -> [CGFloat] {
        lock.lock()
        defer { lock.unlock() }

        var levels: [CGFloat] = []
        var index = 0
        while index < samples.count {
            let needed = windowSampleCount - sampleCount
            let take = min(needed, samples.count - index)
            for offset in index..<(index + take) {
                let sample = samples[offset]
                sumOfSquares += sample * sample
            }
            sampleCount += take
            index += take

            if sampleCount >= windowSampleCount {
                let rms = sqrt(sumOfSquares / Float(sampleCount))
                let dB = 20 * log10(max(rms, 1e-6))
                levels.append(CGFloat(max(0, min(1, (dB + 50) / 50))))
                sumOfSquares = 0
                sampleCount = 0
            }
        }
        return levels
    }
}

private final class AudioSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSessionID: Int?
    private var sampleChunks: [[Float]] = []

    func beginSession(_ sessionID: Int) {
        lock.lock()
        activeSessionID = sessionID
        sampleChunks = []
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer, sessionID: Int) -> [Float]? {
        guard let samples = Self.copyMonoFloatSamples(from: buffer), !samples.isEmpty else { return nil }
        lock.lock()
        guard activeSessionID == sessionID else {
            lock.unlock()
            return nil
        }
        sampleChunks.append(samples)
        lock.unlock()
        return samples
    }

    // Copies a tap buffer into mono Float32 samples, averaging channels when the input is stereo.
    private static func copyMonoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        if let channelData = buffer.floatChannelData {
            var samples = [Float](repeating: 0, count: frameCount)
            if buffer.format.isInterleaved {
                let interleaved = channelData[0]
                for frameIndex in 0..<frameCount {
                    let baseIndex = frameIndex * channelCount
                    for channelIndex in 0..<channelCount {
                        samples[frameIndex] += interleaved[baseIndex + channelIndex]
                    }
                }
            } else {
                for channelIndex in 0..<channelCount {
                    let channel = channelData[channelIndex]
                    for frameIndex in 0..<frameCount {
                        samples[frameIndex] += channel[frameIndex]
                    }
                }
            }
            if channelCount > 1 {
                let divisor = Float(channelCount)
                for index in samples.indices {
                    samples[index] /= divisor
                }
            }
            return samples
        }

        return convertPCMBufferToMonoFloat(buffer)
    }

    // Fallback for hardware routes that deliver integer PCM instead of Float32.
    private static func convertPCMBufferToMonoFloat(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ),
              let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }

        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var didFeedInput = false
        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if didFeedInput {
                status.pointee = .noDataNow
                return nil
            }
            didFeedInput = true
            status.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &conversionError, withInputFrom: inputBlock)
        guard conversionError == nil,
              let channelData = convertedBuffer.floatChannelData?[0],
              convertedBuffer.frameLength > 0 else {
            return nil
        }

        return Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))
    }

    func drain(sessionID: Int) -> [Float] {
        lock.lock()
        guard activeSessionID == sessionID else {
            lock.unlock()
            return []
        }
        let chunks = sampleChunks
        sampleChunks = []
        activeSessionID = nil
        lock.unlock()
        return chunks.flatMap { $0 }
    }

    func reset() {
        lock.lock()
        activeSessionID = nil
        sampleChunks = []
        lock.unlock()
    }
}

// ─── Data helpers ────────────────────────────────────────────────

private extension Data {
    mutating func appendUTF8(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
