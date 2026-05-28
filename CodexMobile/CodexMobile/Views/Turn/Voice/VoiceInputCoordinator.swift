// FILE: VoiceInputCoordinator.swift
// Purpose: Owns shared voice recording, transcription, lifecycle, and recovery state for turn composers.
// Layer: View Support
// Exports: VoiceInputCoordinator
// Depends on: Combine, SwiftUI, CodexService, GPTVoiceTranscriptionManager

import Combine
import SwiftUI

@MainActor
final class VoiceInputCoordinator: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPreflighting = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var recoveryReason: CodexVoiceFailureReason?
    @Published var isShowingSetupSheet = false

    let transcriptionManager = GPTVoiceTranscriptionManager()

    private var preflightGeneration = 0
    private var operationGeneration = 0
    private var transcriptionTask: Task<Void, Never>?
    private var hasTriggeredAutoStop = false
    private var meteringCancellable: AnyCancellable?

    init() {
        meteringCancellable = transcriptionManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isInputActive: Bool {
        isRecording || isPreflighting || isTranscribing
    }

    var audioLevels: [CGFloat] {
        transcriptionManager.audioLevels
    }

    var recordingDuration: TimeInterval {
        transcriptionManager.recordingDuration
    }

    // Mirrors the mic CTA state so composers can swap between ready, record, and stop.
    func buttonPresentation(isConnected: Bool) -> TurnComposerVoiceButtonPresentation {
        TurnVoiceButtonPresentationBuilder.presentation(
            isTranscribing: isTranscribing,
            isPreflighting: isPreflighting,
            isRecording: isRecording,
            isConnected: isConnected
        )
    }

    func clearRecovery() {
        recoveryReason = nil
    }

    func clearReconnectRecoveryIfNeeded() {
        if recoveryReason == .reconnectRequired {
            clearRecovery()
        }
    }

    // Switches the mic button between login, recording, and transcription states.
    func handleButtonTap(
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        if isTranscribing {
            return
        }

        if isRecording {
            beginStopTranscription(codex: codex, onTranscript: onTranscript, onDismissInput: onDismissInput)
            return
        }

        Task { @MainActor [weak self] in
            await self?.startRecordingIfReady(codex: codex, onDismissInput: onDismissInput)
        }
    }

    // Auto-stops a clip just before the hard validation limit.
    func handleRecordingDuration(
        _ duration: TimeInterval,
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        guard isRecording,
              !isTranscribing,
              !hasTriggeredAutoStop,
              duration >= voiceAutoStopThreshold else {
            return
        }

        hasTriggeredAutoStop = true
        beginStopTranscription(codex: codex, onTranscript: onTranscript, onDismissInput: onDismissInput)
    }

    // Leaving the active scene stops capture and attempts transcription while the view remains alive.
    func handleScenePhaseChange(
        _ phase: ScenePhase,
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        guard phase != .active else {
            return
        }

        if isRecording {
            beginStopTranscription(codex: codex, onTranscript: onTranscript, onDismissInput: onDismissInput)
        } else if isPreflighting {
            invalidatePendingPreflight()
        }
    }

    // Disappearing outside the background path treats voice input as abandoned and cancels it.
    func handleViewDisappear(
        scenePhase: ScenePhase,
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        guard scenePhase == .background else {
            cancelInputIfNeeded()
            clearRecovery()
            return
        }

        handleScenePhaseChange(
            scenePhase,
            codex: codex,
            onTranscript: onTranscript,
            onDismissInput: onDismissInput
        )
    }

    // Resets UI state when iOS invalidates the mic route underneath active recording.
    func handleCaptureInvalidation(codex: CodexService) {
        guard isRecording || isPreflighting else {
            return
        }

        cancelTranscriptionIfNeeded()
        invalidatePendingPreflight()
        isRecording = false
        isPreflighting = false
        hasTriggeredAutoStop = false
        presentRecovery(for: .recorderUnavailable, codex: codex)
    }

    // User-initiated cancel clears the full voice flow, including a stop/upload race.
    func cancelInputIfNeeded() {
        cancelTranscriptionIfNeeded()
        cancelRecordingIfNeeded()
        invalidatePendingPreflight()
    }

    func startVoiceLoginOnMac(codex: CodexService) {
        Task { @MainActor [weak self] in
            do {
                try await codex.startOrResumeGPTLoginOnMac()
                self?.presentRecovery(for: .voiceSyncInProgress, codex: codex)
            } catch {
                self?.presentRecovery(for: error, codex: codex)
            }
        }
    }

    private func beginStopTranscription(
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) {
        guard isRecording, !isTranscribing else {
            return
        }

        hasTriggeredAutoStop = false
        isTranscribing = true
        operationGeneration += 1
        let currentGeneration = operationGeneration
        transcriptionTask?.cancel()
        transcriptionTask = Task { @MainActor [weak self] in
            await self?.stopTranscription(
                operationGeneration: currentGeneration,
                codex: codex,
                onTranscript: onTranscript,
                onDismissInput: onDismissInput
            )
        }
    }

    private func stopTranscription(
        operationGeneration: Int,
        codex: CodexService,
        onTranscript: @escaping @MainActor (String) -> Void,
        onDismissInput: @escaping @MainActor () -> Void
    ) async {
        defer {
            if isOperationCurrent(operationGeneration) {
                isTranscribing = false
                transcriptionTask = nil
            }
        }

        do {
            guard let clip = try transcriptionManager.stopRecording() else {
                if isOperationCurrent(operationGeneration) {
                    isRecording = false
                    transcriptionManager.resetMeteringState()
                    presentRecovery(for: .recorderUnavailable, codex: codex)
                }
                return
            }

            defer {
                try? FileManager.default.removeItem(at: clip.url)
            }

            isRecording = false
            transcriptionManager.resetMeteringState()
            let transcript = try await VoiceTranscriptionBackgroundTask.run {
                try await codex.transcribeVoiceAudioFile(
                    at: clip.url,
                    durationSeconds: clip.durationSeconds
                )
            }
            guard isOperationCurrent(operationGeneration), !Task.isCancelled else {
                return
            }

            clearRecovery()
            onTranscript(transcript)
            onDismissInput()
        } catch {
            guard isOperationCurrent(operationGeneration), !Task.isCancelled else {
                return
            }
            isRecording = false
            transcriptionManager.resetMeteringState()
            presentRecovery(for: error, codex: codex)
        }
    }

    // Starts microphone capture; auth resolves only after the user stops recording.
    private func startRecordingIfReady(
        codex: CodexService,
        onDismissInput: @escaping @MainActor () -> Void
    ) async {
        guard !isPreflighting else {
            return
        }

        guard codex.supportsBridgeVoiceTranscription else {
            presentRecovery(for: .bridgeSessionUnsupported, codex: codex)
            return
        }

        guard codex.isConnected else {
            presentRecovery(for: .reconnectRequired, codex: codex)
            return
        }

        clearRecovery()
        codex.lastErrorMessage = nil
        hasTriggeredAutoStop = false
        onDismissInput()
        let currentGeneration = preflightGeneration + 1
        preflightGeneration = currentGeneration
        isPreflighting = true
        defer {
            if isPreflightCurrent(currentGeneration) {
                isPreflighting = false
            }
        }

        do {
            guard isPreflightCurrent(currentGeneration) else {
                return
            }
            try await transcriptionManager.startRecording()
            guard isPreflightCurrent(currentGeneration) else {
                transcriptionManager.cancelRecording()
                return
            }
            isRecording = true
            onDismissInput()
        } catch {
            guard isPreflightCurrent(currentGeneration) else {
                return
            }
            presentRecovery(for: error, codex: codex)
        }
    }

    private func cancelRecordingIfNeeded() {
        guard isRecording || isPreflighting else {
            return
        }

        transcriptionManager.cancelRecording()
        isRecording = false
        isPreflighting = false
        hasTriggeredAutoStop = false
    }

    private func cancelTranscriptionIfNeeded() {
        guard isTranscribing || transcriptionTask != nil else {
            return
        }

        operationGeneration += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
    }

    private func invalidatePendingPreflight() {
        preflightGeneration += 1
        isPreflighting = false
        transcriptionManager.cancelRecording()
    }

    private func presentRecovery(for error: Error, codex: CodexService) {
        presentRecovery(for: codex.classifyVoiceFailure(error), codex: codex)
    }

    private func presentRecovery(for reason: CodexVoiceFailureReason, codex: CodexService? = nil) {
        recoveryReason = reason
        codex?.lastErrorMessage = nil
    }

    private var voiceAutoStopThreshold: TimeInterval {
        max(0, CodexVoiceTranscriptionPreflight.maxDurationSeconds - 0.25)
    }

    private func isPreflightCurrent(_ generation: Int) -> Bool {
        generation == preflightGeneration
    }

    private func isOperationCurrent(_ generation: Int) -> Bool {
        generation == operationGeneration
    }
}
