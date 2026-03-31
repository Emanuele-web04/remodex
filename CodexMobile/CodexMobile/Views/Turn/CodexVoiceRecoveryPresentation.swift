// FILE: CodexVoiceRecoveryPresentation.swift
// Purpose: Maps `CodexVoiceFailureReason` to connection-style recovery UI for voice mode (shared by TurnView and tests).
// Layer: View support
// Exports: CodexVoiceRecoveryAction, CodexVoiceRecoveryPresentation, makeCodexVoiceRecoveryPresentation

import Foundation

enum CodexVoiceRecoveryAction: Equatable {
    case reconnect
    case showSetupHelp
    case openSystemSettings
    case none
}

struct CodexVoiceRecoveryPresentation: Equatable {
    let snapshot: ConnectionRecoverySnapshot
    let action: CodexVoiceRecoveryAction
}

func makeCodexVoiceRecoveryPresentation(for reason: CodexVoiceFailureReason) -> CodexVoiceRecoveryPresentation {
    switch reason {
    case .reconnectRequired:
        return CodexVoiceRecoveryPresentation(
            snapshot: ConnectionRecoverySnapshot(
                title: "Voice Mode",
                summary: "Reconnect to your Mac to use voice mode.",
                detail: "Keep the Remodex bridge running on your Mac, then try the microphone again.",
                status: .interrupted,
                trailingStyle: .action("Reconnect")
            ),
            action: .reconnect
        )
    case .bridgeSessionUnsupported:
        return CodexVoiceRecoveryPresentation(
            snapshot: ConnectionRecoverySnapshot(
                title: "Voice Mode",
                summary: "This bridge session does not support voice mode yet.",
                detail: "Restart Remodex on your Mac, then reconnect this iPhone. If it still happens, update Remodex on your Mac and pair again.",
                status: .actionRequired,
                trailingStyle: .action("Reconnect")
            ),
            action: .reconnect
        )
    case .macLoginRequired:
        return CodexVoiceRecoveryPresentation(
            snapshot: ConnectionRecoverySnapshot(
                title: "Voice Mode",
                summary: "Sign in to ChatGPT on your Mac to use voice mode.",
                detail: "Open ChatGPT on the paired Mac, sign in there, then come back here and try again.",
                status: .actionRequired,
                trailingStyle: .action("How To Fix")
            ),
            action: .showSetupHelp
        )
    case .macReauthenticationRequired:
        return CodexVoiceRecoveryPresentation(
            snapshot: ConnectionRecoverySnapshot(
                title: "Voice Mode",
                summary: "ChatGPT voice needs a fresh sign-in on your Mac.",
                detail: "Open ChatGPT on the paired Mac, sign in again there, then retry voice mode here.",
                status: .actionRequired,
                trailingStyle: .action("How To Fix")
            ),
            action: .showSetupHelp
        )
    case .voiceSyncInProgress:
        return CodexVoiceRecoveryPresentation(
            snapshot: ConnectionRecoverySnapshot(
                title: "Voice Mode",
                summary: "Voice mode is still syncing from your Mac.",
                detail: "Keep the bridge connected for a moment, then try again.",
                status: .syncing,
                trailingStyle: .progress
            ),
            action: .none
        )
    case .chatGPTRequired:
        return CodexVoiceRecoveryPresentation(
            snapshot: ConnectionRecoverySnapshot(
                title: "Voice Mode",
                summary: "Voice mode needs a ChatGPT session on your Mac.",
                detail: "API-key-only auth is not enough here. Sign in to ChatGPT on the paired Mac, then try again.",
                status: .actionRequired,
                trailingStyle: .action("How To Fix")
            ),
            action: .showSetupHelp
        )
    case .microphonePermissionRequired:
        return CodexVoiceRecoveryPresentation(
            snapshot: ConnectionRecoverySnapshot(
                title: "Voice Mode",
                summary: "Microphone access is off for Remodex.",
                detail: "Open iPhone Settings, allow Microphone for Remodex, then try recording again.",
                status: .actionRequired,
                trailingStyle: .action("Open Settings")
            ),
            action: .openSystemSettings
        )
    case .microphoneUnavailable:
        return CodexVoiceRecoveryPresentation(
            snapshot: ConnectionRecoverySnapshot(
                title: "Voice Mode",
                summary: "No microphone input is available right now.",
                detail: "Check that another app is not holding the microphone, then try again.",
                status: .actionRequired,
                trailingStyle: .none
            ),
            action: .none
        )
    case .recorderUnavailable:
        return CodexVoiceRecoveryPresentation(
            snapshot: ConnectionRecoverySnapshot(
                title: "Voice Mode",
                summary: "Remodex could not start the recorder.",
                detail: "Close other audio-heavy apps, then try voice mode again.",
                status: .actionRequired,
                trailingStyle: .none
            ),
            action: .none
        )
    case .generic(let message):
        return CodexVoiceRecoveryPresentation(
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
