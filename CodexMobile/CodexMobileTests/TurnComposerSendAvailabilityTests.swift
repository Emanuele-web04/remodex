// FILE: TurnComposerSendAvailabilityTests.swift
// Purpose: Locks send-button enable/disable truth table after composer refactor.
// Layer: Unit Test
// Exports: TurnComposerSendAvailabilityTests
// Depends on: XCTest, CodexMobile

import XCTest
@testable import CodexMobile

@MainActor
final class TurnComposerSendAvailabilityTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testSendDisabledWhenDisconnected() {
        let state = makeState(isConnected: false)
        XCTAssertTrue(state.isSendDisabled)
    }

    func testSendDisabledWhenSendingInFlight() {
        let state = makeState(isSending: true)
        XCTAssertTrue(state.isSendDisabled)
    }

    func testSendEnabledWhenActiveTurnExistsAndPayloadIsValid() {
        let state = makeState(trimmedInput: "queue this")
        XCTAssertFalse(state.isSendDisabled)
    }

    func testSendDisabledWhenInputAndImagesAreEmpty() {
        let state = makeState(trimmedInput: "", hasReadyImages: false)
        XCTAssertTrue(state.isSendDisabled)
    }

    func testSendDisabledWhenAttachmentStateIsBlocking() {
        let state = makeState(hasBlockingAttachmentState: true)
        XCTAssertTrue(state.isSendDisabled)
    }

    func testSendEnabledWhenConnectedAndPayloadIsValid() {
        let textState = makeState(trimmedInput: "Ship it", hasReadyImages: false)
        XCTAssertFalse(textState.isSendDisabled)

        let imageState = makeState(trimmedInput: "", hasReadyImages: true)
        XCTAssertFalse(imageState.isSendDisabled)
    }

    func testSendEnabledWhenReviewSelectionIsPresentWithoutText() {
        let reviewState = makeState(trimmedInput: "", hasReadyImages: false, hasReviewSelection: true)
        XCTAssertFalse(reviewState.isSendDisabled)
    }

    func testSendDisabledWhileReviewSelectionIsWaitingForTarget() {
        let reviewState = makeState(
            trimmedInput: "follow up",
            hasReadyImages: false,
            hasReviewSelection: false,
            hasPendingReviewSelection: true
        )
        XCTAssertTrue(reviewState.isSendDisabled)
    }

    func testSendTurnRestoresRawDraftWhenStartTurnFails() async {
        let service = makeService()
        service.isConnected = true

        let viewModel = TurnViewModel()
        let rawInput = "Please update @TurnView.swift"
        let rawMention = TurnComposerMentionedFile(
            fileName: "TurnView.swift",
            path: "Views/Turn/TurnView.swift"
        )
        let attachment = CodexImageAttachment(
            thumbnailBase64JPEG: "thumb",
            payloadDataURL: "data:image/jpeg;base64,AAAA"
        )

        viewModel.input = rawInput
        viewModel.composerMentionedFiles = [rawMention]
        viewModel.composerAttachments = [
            TurnComposerImageAttachment(id: "attachment-1", state: .ready(attachment))
        ]

        viewModel.sendTurn(codex: service, threadID: "thread-send-failure")
        await waitForSendCompletion(viewModel)

        XCTAssertFalse(viewModel.isSending)
        XCTAssertEqual(viewModel.input, rawInput)
        XCTAssertEqual(viewModel.composerMentionedFiles, [rawMention])
        XCTAssertEqual(viewModel.readyComposerAttachments, [attachment])
        XCTAssertEqual(viewModel.composerAttachments.count, 1)
    }

    private func makeState(
        isSending: Bool = false,
        isConnected: Bool = true,
        trimmedInput: String = "hello",
        hasReadyImages: Bool = false,
        hasBlockingAttachmentState: Bool = false,
        hasReviewSelection: Bool = false,
        hasPendingReviewSelection: Bool = false
    ) -> TurnComposerSendAvailability {
        TurnComposerSendAvailability(
            isSending: isSending,
            isConnected: isConnected,
            trimmedInput: trimmedInput,
            hasReadyImages: hasReadyImages,
            hasBlockingAttachmentState: hasBlockingAttachmentState,
            hasReviewSelection: hasReviewSelection,
            hasPendingReviewSelection: hasPendingReviewSelection
        )
    }

    private func waitForSendCompletion(_ viewModel: TurnViewModel, maxPollCount: Int = 120) async {
        for _ in 0..<maxPollCount where viewModel.isSending {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeService() -> CodexService {
        let suiteName = "TurnComposerSendAvailabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]

        // CodexService currently crashes while deallocating in unit-test environment.
        // Keep instances alive for process lifetime so assertions remain deterministic.
        Self.retainedServices.append(service)
        return service
    }
}
