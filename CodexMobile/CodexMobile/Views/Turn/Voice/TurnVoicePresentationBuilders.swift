// FILE: TurnVoicePresentationBuilders.swift
// Purpose: Maps voice recording/auth state into composer and recovery UI presentations.
// Layer: View Support
// Exports: TurnVoiceButtonPresentationBuilder, TurnVoiceRecoveryPresentationBuilder
// Depends on: SwiftUI, TurnComposerVoiceButtonPresentation, ConnectionRecoverySnapshot

import SwiftUI

enum TurnVoiceButtonPresentationBuilder {
    static func presentation(
        isTranscribing: Bool,
        isPreflighting: Bool,
        isRecording: Bool,
        isConnected: Bool
    ) -> TurnComposerVoiceButtonPresentation {
        if isTranscribing {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "waveform",
                foregroundColor: Color(.secondaryLabel),
                backgroundColor: Color(.systemGray5),
                accessibilityLabel: "Transcribing voice note",
                isDisabled: true,
                showsProgress: true,
                hasCircleBackground: true
            )
        }

        if isPreflighting {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "hourglass",
                foregroundColor: Color(.secondaryLabel),
                backgroundColor: Color(.systemGray5),
                accessibilityLabel: "Preparing microphone",
                isDisabled: true,
                showsProgress: true,
                hasCircleBackground: true
            )
        }

        if isRecording {
            return TurnComposerVoiceButtonPresentation(
                systemImageName: "stop.fill",
                foregroundColor: Color(.systemBackground),
                backgroundColor: Color(.systemRed),
                accessibilityLabel: "Stop voice recording",
                isDisabled: false,
                showsProgress: false,
                hasCircleBackground: true
            )
        }

        return TurnComposerVoiceButtonPresentation(
            systemImageName: "mic",
            foregroundColor: Color(.secondaryLabel),
            backgroundColor: .clear,
            accessibilityLabel: "Start voice transcription",
            isDisabled: !isConnected,
            showsProgress: false,
            hasCircleBackground: false
        )
    }
}

enum TurnVoiceRecoveryPresentationBuilder {
    static func presentation(for reason: CodexVoiceFailureReason) -> VoiceRecoveryPresentation {
        switch reason {
        case .reconnectRequired:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "Reconnect to your Mac to use voice mode.",
                    detail: "Keep the Remodex bridge running on your paired computer, then try the microphone again.",
                    status: .interrupted,
                    trailingStyle: .action("Reconnect")
                ),
                action: .reconnect
            )
        case .bridgeSessionUnsupported:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "This bridge session does not support voice mode yet.",
                    detail: "Restart Remodex on your computer, then reconnect this iPhone. If it still happens, update Remodex on your computer and pair again.",
                    status: .actionRequired,
                    trailingStyle: .action("Reconnect")
                ),
                action: .reconnect
            )
        case .macLoginRequired:
            return setupHelpPresentation(
                summary: "Sign in to ChatGPT on your computer to use voice mode.",
                detail: "Open ChatGPT on the paired computer, sign in there, then come back here and try again."
            )
        case .macReauthenticationRequired:
            return setupHelpPresentation(
                summary: "ChatGPT voice needs a fresh sign-in on your computer.",
                detail: "Open ChatGPT on the paired computer, sign in again there, then retry voice mode here."
            )
        case .voiceSyncInProgress:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "Voice mode is still syncing from your Mac.",
                    detail: "Keep the bridge connected for a moment, then try again.",
                    status: .syncing,
                    trailingStyle: .progress
                ),
                action: .none
            )
        case .chatGPTRequired:
            return setupHelpPresentation(
                summary: "Voice mode needs a ChatGPT session on your computer.",
                detail: "API-key-only auth is not enough here. Sign in to ChatGPT on the paired computer, then try again."
            )
        case .microphonePermissionRequired:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "Microphone access is off for Remodex.",
                    detail: "Open iPhone Settings, allow Microphone for Remodex, then try recording again.",
                    status: .actionRequired,
                    trailingStyle: .action("Open Settings")
                ),
                action: .openSystemSettings
            )
        case .microphoneUnavailable:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "No microphone input is available right now.",
                    detail: "Check that another app is not holding the microphone, then try again.",
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        case .recorderUnavailable:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "Remodex could not start the recorder.",
                    detail: "Close other audio-heavy apps, then try voice mode again.",
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        case .generic(let message):
            return VoiceRecoveryPresentation(
                snapshot: ConnectionRecoverySnapshot(
                    title: "Voice Mode",
                    summary: message,
                    status: .actionRequired,
                    trailingStyle: .none
                ),
                action: .none
            )
        }
    }

    private static func setupHelpPresentation(
        summary: String,
        detail: String
    ) -> VoiceRecoveryPresentation {
        VoiceRecoveryPresentation(
            snapshot: snapshot(
                summary: summary,
                detail: detail,
                status: .actionRequired,
                trailingStyle: .action("How To Fix")
            ),
            action: .showSetupHelp
        )
    }

    private static func snapshot(
        summary: String,
        detail: String? = nil,
        status: ConnectionRecoveryStatus,
        trailingStyle: ConnectionRecoveryTrailingStyle
    ) -> ConnectionRecoverySnapshot {
        ConnectionRecoverySnapshot(
            title: "Voice Mode",
            summary: summary,
            detail: detail,
            status: status,
            trailingStyle: trailingStyle
        )
    }
}
