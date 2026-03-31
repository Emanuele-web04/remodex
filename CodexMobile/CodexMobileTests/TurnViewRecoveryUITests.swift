// FILE: TurnViewRecoveryUITests.swift
// Purpose: Verifies turn-screen layout pinning and voice recovery presentation stay actionable.
// Layer: Unit Test
// Exports: TurnViewRecoveryUITests
// Depends on: XCTest, CodexMobile

import XCTest
import Foundation
@testable import CodexMobile

@MainActor
final class TurnViewRecoveryUITests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    override func tearDown() {
        Self.retainedServices.removeAll()
        super.tearDown()
    }

    func testBuildMessageLayoutSeparatesPinnedPlanAndStructuredInput() {
        let layout = TurnConversationContainerView.buildMessageLayout(from: [
            makeChatMessage(id: "assistant-1", role: .assistant, text: "Hello"),
            makeActivePlanMessage(id: "plan-1"),
            makeStructuredUserInputMessage(id: "prompt-1"),
        ])

        XCTAssertEqual(layout.timelineMessages.map(\.id), ["assistant-1"])
        XCTAssertEqual(layout.pinnedTaskPlanMessage?.id, "plan-1")
        XCTAssertEqual(layout.pinnedStructuredUserInputMessage?.id, "prompt-1")
    }

    func testDisconnectedVoiceFailureBuildsReconnectAction() {
        let service = makeService()
        service.isConnected = false

        let reason = classifyVoiceFailure(CodexServiceError.disconnected, codex: service)
        let presentation = voiceRecoveryPresentation(for: reason)

        XCTAssertEqual(reason, .reconnectRequired)
        XCTAssertEqual(presentation.snapshot.actionTitle, "Reconnect")
        XCTAssertEqual(presentation.action, .reconnect)
        XCTAssertEqual(presentation.snapshot.status, .needsAction)
    }

    func testMicrophonePermissionDeniedBuildsOpenSettingsAction() {
        let service = makeService()
        service.isConnected = true

        let reason = classifyVoiceFailure(GPTVoiceTranscriptionError.microphonePermissionDenied, codex: service)
        let presentation = voiceRecoveryPresentation(for: reason)

        XCTAssertEqual(reason, .microphonePermissionRequired)
        XCTAssertEqual(presentation.snapshot.actionTitle, "Open Settings")
        XCTAssertEqual(presentation.action, .openSystemSettings)
        XCTAssertEqual(presentation.snapshot.summary, "Microphone access is off for Remodex.")
    }

    func testLoggedOutVoiceFailureBuildsSetupHelpAction() {
        let service = makeService()
        service.isConnected = true
        service.gptAccountSnapshot = makeAccountSnapshot(
            status: .notLoggedIn,
            loginInFlight: false,
            needsReauth: false,
            tokenReady: false
        )

        let reason = classifyVoiceFailure(CodexServiceError.invalidInput("voice unavailable"), codex: service)
        let presentation = voiceRecoveryPresentation(for: reason)

        XCTAssertEqual(reason, .macLoginRequired)
        XCTAssertEqual(presentation.snapshot.actionTitle, "How To Fix")
        XCTAssertEqual(presentation.action, .showSetupHelp)
        XCTAssertEqual(presentation.snapshot.summary, "Sign in to ChatGPT on your Mac to use voice mode.")
    }

    func testActiveLoginBuildsSyncingPresentationWithoutAction() {
        let service = makeService()
        service.isConnected = true
        service.gptAccountSnapshot = makeAccountSnapshot(
            status: .loginPending,
            loginInFlight: true,
            needsReauth: false,
            tokenReady: false
        )

        let reason = classifyVoiceFailure(CodexServiceError.invalidInput("voice unavailable"), codex: service)
        let presentation = voiceRecoveryPresentation(for: reason)

        XCTAssertEqual(reason, .voiceSyncInProgress)
        XCTAssertNil(presentation.snapshot.actionTitle)
        XCTAssertEqual(presentation.action, .none)
        XCTAssertEqual(presentation.snapshot.status, .syncing)
    }

    func testConnectedThreadHidesStaleSavedPairingTimeoutError() {
        let message = turnVisibleConversationErrorMessage(
            lastErrorMessage: "The saved pairing timed out while waiting for the Mac",
            isConnected: true,
            shouldSuppressConnectedMessage: false
        )

        XCTAssertNil(message)
    }

    func testConnectedThreadKeepsNonStaleErrorVisible() {
        let message = turnVisibleConversationErrorMessage(
            lastErrorMessage: "The secure Remodex payload could not be verified.",
            isConnected: true,
            shouldSuppressConnectedMessage: false
        )

        XCTAssertEqual(message, "The secure Remodex payload could not be verified.")
    }

    private func makeService() -> CodexService {
        let suiteName = "TurnViewRecoveryUITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]

        Self.retainedServices.append(service)
        return service
    }

    private func makeChatMessage(id: String, role: CodexMessageRole, text: String) -> CodexMessage {
        CodexMessage(
            id: id,
            threadId: "thread-1",
            role: role,
            text: text,
            createdAt: Date(),
            deliveryState: .confirmed
        )
    }

    private func makeActivePlanMessage(id: String) -> CodexMessage {
        CodexMessage(
            id: id,
            threadId: "thread-1",
            role: .system,
            kind: .plan,
            text: "Planning...",
            createdAt: Date(),
            isStreaming: true,
            deliveryState: .confirmed,
            planState: CodexPlanState(steps: [
                CodexPlanStep(step: "Review the repository", status: .inProgress)
            ])
        )
    }

    private func makeStructuredUserInputMessage(id: String) -> CodexMessage {
        CodexMessage(
            id: id,
            threadId: "thread-1",
            role: .system,
            kind: .userInputPrompt,
            text: "",
            createdAt: Date(),
            deliveryState: .confirmed,
            structuredUserInputRequest: CodexStructuredUserInputRequest(
                requestID: .string("request-1"),
                questions: [
                    CodexStructuredUserInputQuestion(
                        id: "question-1",
                        header: "Direction",
                        question: "Which path should we take?",
                        isOther: false,
                        isSecret: false,
                        options: [
                            CodexStructuredUserInputOption(
                                id: "option-1",
                                label: "Ship it",
                                description: "Build the fastest version."
                            )
                        ]
                    )
                ]
            )
        )
    }

    private func makeAccountSnapshot(
        status: CodexGPTAccountStatus,
        loginInFlight: Bool,
        needsReauth: Bool,
        tokenReady: Bool
    ) -> CodexGPTAccountSnapshot {
        CodexGPTAccountSnapshot(
            status: status,
            authMethod: .chatgpt,
            email: "tester@example.com",
            displayName: nil,
            planType: nil,
            loginInFlight: loginInFlight,
            needsReauth: needsReauth,
            expiresAt: nil,
            tokenReady: tokenReady,
            tokenUnavailableSince: nil,
            updatedAt: .now
        )
    }
}
