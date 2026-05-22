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
            accessibilityLabel: isConnected ? "Start voice transcription" : "Reconnect for voice transcription",
            isDisabled: false,
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
                    summary: "Reconnect to your device to use voice mode.",
                    detail: "Keep the Remodex bridge running on your paired device, then try the microphone again.",
                    status: .interrupted,
                    trailingStyle: .action("Reconnect")
                ),
                action: .reconnect
            )
        case .bridgeSessionUnsupported:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "This bridge session does not support voice mode yet.",
                    detail: "Restart Remodex on your device, then reconnect this iPhone. If it still happens, update Remodex on your device and pair again.",
                    status: .actionRequired,
                    trailingStyle: .action("Reconnect")
                ),
                action: .reconnect
            )
        case .macLoginRequired:
            return macLoginPresentation(
                summary: "Set up OpenAI auth on your device to use voice mode.",
                detail: "Sign in to ChatGPT or configure an OpenAI API key on the paired device, then try again."
            )
        case .macReauthenticationRequired:
            return macLoginPresentation(
                summary: "Voice mode needs fresh OpenAI auth on your device.",
                detail: "Sign in to ChatGPT again or update the OpenAI API key on the paired device, then retry voice mode here."
            )
        case .providerAuthenticationRejected(let message):
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAPIKeyRejection = trimmedMessage.lowercased().contains("api key")
            if isAPIKeyRejection {
                return setupHelpPresentation(
                    summary: trimmedMessage.isEmpty
                        ? "Voice transcription auth was rejected."
                        : trimmedMessage,
                    detail: "Update the OpenAI API key on the paired device, then retry voice mode here."
                )
            }

            return macLoginPresentation(
                summary: trimmedMessage.isEmpty
                    ? "Voice transcription auth was rejected."
                    : trimmedMessage,
                detail: "Refresh ChatGPT login on the paired device, then retry voice mode here."
            )
        case .voiceSyncInProgress:
            return VoiceRecoveryPresentation(
                snapshot: snapshot(
                    summary: "Voice mode is still syncing from your device.",
                    detail: "Keep the bridge connected for a moment, then try again.",
                    status: .syncing,
                    trailingStyle: .progress
                ),
                action: .none
            )
        case .chatGPTRequired:
            return setupHelpPresentation(
                summary: "Voice mode needs the updated bridge auth path.",
                detail: "Restart or update Remodex on the paired device. Current voice mode can use ChatGPT or an OpenAI API key without sending the token to your phone."
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

    private static func macLoginPresentation(
        summary: String,
        detail: String
    ) -> VoiceRecoveryPresentation {
        VoiceRecoveryPresentation(
            snapshot: snapshot(
                summary: summary,
                detail: detail,
                status: .actionRequired,
                trailingStyle: .action("Open Login")
            ),
            action: .openMacLogin
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
