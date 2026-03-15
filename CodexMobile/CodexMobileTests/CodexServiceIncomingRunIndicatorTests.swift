// FILE: CodexServiceIncomingRunIndicatorTests.swift
// Purpose: Verifies sidebar run badge transitions (running/ready/failed) from app-server events.
// Layer: Unit Test
// Exports: CodexServiceIncomingRunIndicatorTests
// Depends on: XCTest, CodexMobile

import XCTest
import Network
@testable import CodexMobile

@MainActor
final class CodexServiceIncomingRunIndicatorTests: XCTestCase {
    private static var retainedServices: [CodexService] = []

    func testTurnStartedMarksThreadAsRunning() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
    }

    func testIncomingMethodIsTrimmedBeforeRouting() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleIncomingRPCMessage(
            RPCMessage(
                method: " turn/started ",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                ])
            )
        )

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
        XCTAssertEqual(service.activeTurnID(for: threadID), turnID)
    }

    func testTurnStartedSupportsConversationIDSnakeCase() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "conversation_id": .string(threadID),
                "turnId": .string(turnID),
            ])
        )

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
        XCTAssertEqual(service.activeTurnID(for: threadID), turnID)
    }

    func testTurnStartedWithoutTurnIDStillMarksThreadAsRunning() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
            ])
        )

        XCTAssertNil(service.activeTurnID(for: threadID))
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
    }

    func testTurnStartedAcceptsTopLevelIDAsTurnID() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "id": .string(turnID),
            ])
        )

        XCTAssertEqual(service.activeTurnID(for: threadID), turnID)
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
    }

    func testTurnCompletedAcceptsTopLevelIDAsTurnID() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)

        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "id": .string(turnID),
            ])
        )

        XCTAssertNil(service.activeTurnID(for: threadID))
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .ready)
    }

    func testThreadStatusChangedActiveMarksRunning() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.handleNotification(
            method: "thread/status/changed",
            params: .object([
                "threadId": .string(threadID),
                "status": .object([
                    "type": .string("active"),
                ]),
            ])
        )

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
    }

    func testThreadStatusChangedIdleStopsRunning() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        service.handleNotification(
            method: "thread/status/changed",
            params: .object([
                "threadId": .string(threadID),
                "status": .object([
                    "type": .string("active"),
                ]),
            ])
        )

        service.handleNotification(
            method: "thread/status/changed",
            params: .object([
                "threadId": .string(threadID),
                "status": .object([
                    "type": .string("idle"),
                ]),
            ])
        )

        XCTAssertNil(service.threadRunBadgeState(for: threadID))
    }

    func testThreadStatusChangedIdleDoesNotClearWhileTurnIsStillActive() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)

        service.handleNotification(
            method: "thread/status/changed",
            params: .object([
                "threadId": .string(threadID),
                "status": .object([
                    "type": .string("idle"),
                ]),
            ])
        )

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
        XCTAssertEqual(service.activeTurnID(for: threadID), turnID)
    }

    func testThreadStatusChangedIdleDoesNotClearWhileProtectedRunningFallbackIsStillActive() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.runningThreadIDs.insert(threadID)
        service.protectedRunningFallbackThreadIDs.insert(threadID)
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)

        service.handleNotification(
            method: "thread/status/changed",
            params: .object([
                "threadId": .string(threadID),
                "status": .object([
                    "type": .string("idle"),
                ]),
            ])
        )

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
        XCTAssertNil(service.latestTurnTerminalState(for: threadID))
    }

    func testStreamingFallbackMarksRunningWithoutActiveTurnMapping() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.appendSystemMessage(
            threadId: threadID,
            text: "Thinking...",
            kind: .thinking,
            isStreaming: true
        )

        XCTAssertNil(service.activeTurnID(for: threadID))
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
    }

    func testSuccessfulCompletionMarksThreadAsReadyWhenUnread() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)
        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .ready)
    }

    func testStoppedCompletionRecordsStoppedTerminalStateWithoutReadyBadge() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)
        sendTurnCompletedStopped(service: service, threadID: threadID, turnID: turnID)

        XCTAssertNil(service.threadRunBadgeState(for: threadID))
        XCTAssertEqual(service.latestTurnTerminalState(for: threadID), .stopped)
        XCTAssertEqual(service.turnTerminalState(for: turnID), .stopped)
    }

    func testStoppedCompletionUpdatesThreadStoppedTurnCache() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)
        sendTurnCompletedStopped(service: service, threadID: threadID, turnID: turnID)

        XCTAssertEqual(service.stoppedTurnIDs(for: threadID), Set([turnID]))
        XCTAssertEqual(service.timelineState(for: threadID).renderSnapshot.stoppedTurnIDs, Set([turnID]))
    }

    func testTimelineStateTracksLatestRepoRefreshSignal() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.appendSystemMessage(
            threadId: threadID,
            text: "Status: completed\n\nPath: Sources/App.swift\nKind: update\nTotals: +1 -0",
            kind: .fileChange
        )

        let state = service.timelineState(for: threadID)

        XCTAssertNotNil(state.repoRefreshSignal)
        XCTAssertEqual(state.repoRefreshSignal, state.renderSnapshot.repoRefreshSignal)
    }

    func testErrorWithWillRetryDoesNotMarkFailed() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)

        service.handleNotification(
            method: "error",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "message": .string("temporary"),
                "willRetry": .bool(true),
            ])
        )

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
        XCTAssertTrue(service.failedThreadIDs.isEmpty)
    }

    func testCompletionFailureMarksThreadAsFailed() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)
        sendTurnCompletedFailure(service: service, threadID: threadID, turnID: turnID, message: "boom")

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .failed)
        XCTAssertEqual(service.lastErrorMessage, "boom")
    }

    func testMarkThreadAsViewedClearsReadyAndFailedBadges() {
        let service = makeService()
        let readyThreadID = "thread-ready-\(UUID().uuidString)"
        let failedThreadID = "thread-failed-\(UUID().uuidString)"
        let readyTurnID = "turn-\(UUID().uuidString)"
        let failedTurnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: readyThreadID, turnID: readyTurnID)
        sendTurnCompletedSuccess(service: service, threadID: readyThreadID, turnID: readyTurnID)

        sendTurnStarted(service: service, threadID: failedThreadID, turnID: failedTurnID)
        sendTurnFailed(service: service, threadID: failedThreadID, turnID: failedTurnID, message: "failed")

        service.markThreadAsViewed(readyThreadID)
        service.markThreadAsViewed(failedThreadID)

        XCTAssertNil(service.threadRunBadgeState(for: readyThreadID))
        XCTAssertNil(service.threadRunBadgeState(for: failedThreadID))
    }

    func testPrepareThreadForDisplayClearsOutcomeBadge() async {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)
        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .ready)

        await service.prepareThreadForDisplay(threadId: threadID)

        XCTAssertNil(service.threadRunBadgeState(for: threadID))
    }

    func testActiveThreadDoesNotReceiveReadyOrFailedBadge() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let successTurnID = "turn-\(UUID().uuidString)"
        let failedTurnID = "turn-\(UUID().uuidString)"

        service.activeThreadId = threadID
        sendTurnStarted(service: service, threadID: threadID, turnID: successTurnID)
        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: successTurnID)
        XCTAssertNil(service.threadRunBadgeState(for: threadID))

        sendTurnStarted(service: service, threadID: threadID, turnID: failedTurnID)
        sendTurnFailed(service: service, threadID: threadID, turnID: failedTurnID, message: "boom")
        XCTAssertNil(service.threadRunBadgeState(for: threadID))
    }

    func testNewTurnClearsPreviousOutcomeBeforeRunning() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let failedTurnID = "turn-\(UUID().uuidString)"
        let resumedTurnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: failedTurnID)
        sendTurnFailed(service: service, threadID: threadID, turnID: failedTurnID, message: "boom")
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .failed)

        sendTurnStarted(service: service, threadID: threadID, turnID: resumedTurnID)
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)

        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: resumedTurnID)
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .ready)
    }

    func testMultipleThreadsTrackIndependentBadgeStates() {
        let service = makeService()
        let runningThreadID = "thread-running-\(UUID().uuidString)"
        let readyThreadID = "thread-ready-\(UUID().uuidString)"
        let failedThreadID = "thread-failed-\(UUID().uuidString)"
        let runningTurnID = "turn-\(UUID().uuidString)"
        let readyTurnID = "turn-\(UUID().uuidString)"
        let failedTurnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: runningThreadID, turnID: runningTurnID)

        sendTurnStarted(service: service, threadID: readyThreadID, turnID: readyTurnID)
        sendTurnCompletedSuccess(service: service, threadID: readyThreadID, turnID: readyTurnID)

        sendTurnStarted(service: service, threadID: failedThreadID, turnID: failedTurnID)
        sendTurnFailed(service: service, threadID: failedThreadID, turnID: failedTurnID, message: "failed")

        XCTAssertEqual(service.threadRunBadgeState(for: runningThreadID), .running)
        XCTAssertEqual(service.threadRunBadgeState(for: readyThreadID), .ready)
        XCTAssertEqual(service.threadRunBadgeState(for: failedThreadID), .failed)
    }

    func testDisconnectClearsOutcomeBadges() async {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)
        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)
        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .ready)

        await service.disconnect()

        XCTAssertTrue(service.runningThreadIDs.isEmpty)
        XCTAssertTrue(service.readyThreadIDs.isEmpty)
        XCTAssertTrue(service.failedThreadIDs.isEmpty)
        XCTAssertNil(service.threadRunBadgeState(for: threadID))
    }

    func testThreadHasActiveOrRunningTurnUsesRunningFallback() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        XCTAssertFalse(service.threadHasActiveOrRunningTurn(threadID))
        service.runningThreadIDs.insert(threadID)
        XCTAssertTrue(service.threadHasActiveOrRunningTurn(threadID))
    }

    func testBackgroundConnectionAbortSuppressesErrorAndArmsReconnect() {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.lastErrorMessage = nil
        service.setForegroundState(false)

        service.handleReceiveError(NWError.posix(.ECONNABORTED))

        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isInitialized)
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
    }

    func testForegroundConnectionAbortArmsReconnect() {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.lastErrorMessage = nil
        service.setForegroundState(true)

        service.handleReceiveError(NWError.posix(.ECONNABORTED))

        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isInitialized)
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(
            service.connectionRecoveryState,
            .retrying(attempt: 0, message: "Reconnecting...")
        )
    }

    func testForegroundConnectionTimeoutSuppressesErrorAndArmsReconnect() {
        let service = makeService()
        service.isConnected = true
        service.isInitialized = true
        service.lastErrorMessage = nil
        service.setForegroundState(true)

        service.handleReceiveError(NWError.posix(.ETIMEDOUT))

        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.isInitialized)
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(
            service.connectionRecoveryState,
            .retrying(attempt: 0, message: "Connection timed out. Retrying...")
        )
    }

    func testRelaySessionReplacementClearsSavedPairingAndDisablesReconnect() {
        let service = makeService()

        withSavedRelayPairing(sessionId: "session-\(UUID().uuidString)", relayURL: "wss://relay.test/relay") {
            service.relaySessionId = SecureStore.readString(for: CodexSecureKeys.relaySessionId)
            service.relayUrl = SecureStore.readString(for: CodexSecureKeys.relayUrl)
            service.isConnected = true
            service.isInitialized = true

            service.handleReceiveError(
                CodexServiceError.disconnected,
                relayCloseCode: .privateCode(4001)
            )

            XCTAssertFalse(service.isConnected)
            XCTAssertFalse(service.shouldAutoReconnectOnForeground)
            XCTAssertNil(service.relaySessionId)
            XCTAssertNil(service.relayUrl)
            XCTAssertEqual(
                service.lastErrorMessage,
                "This relay session was replaced by another Mac connection. Scan a new QR code to reconnect."
            )
        }
    }

    func testMacUnavailableCloseClearsSavedPairingAndDisablesReconnect() {
        let service = makeService()

        withSavedRelayPairing(sessionId: "session-\(UUID().uuidString)", relayURL: "wss://relay.test/relay") {
            service.relaySessionId = SecureStore.readString(for: CodexSecureKeys.relaySessionId)
            service.relayUrl = SecureStore.readString(for: CodexSecureKeys.relayUrl)
            service.isConnected = true
            service.isInitialized = true

            service.handleReceiveError(
                CodexServiceError.disconnected,
                relayCloseCode: .privateCode(4002)
            )

            XCTAssertFalse(service.isConnected)
            XCTAssertFalse(service.shouldAutoReconnectOnForeground)
            XCTAssertNil(service.relaySessionId)
            XCTAssertNil(service.relayUrl)
            XCTAssertEqual(
                service.lastErrorMessage,
                "This relay pairing is no longer valid. Scan a new QR code to reconnect."
            )
        }
    }

    func testRetryableDisconnectResetsEncryptedSecurityStateBackToTrustedMac() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let macPublicKey = "public-key-\(UUID().uuidString)"

        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "wss://relay.test/relay"
        service.relayMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date()
        )
        service.secureConnectionState = .encrypted
        service.secureMacFingerprint = codexSecureFingerprint(for: macPublicKey)
        service.isConnected = true
        service.isInitialized = true

        service.handleReceiveError(NWError.posix(.ECONNABORTED))

        XCTAssertEqual(service.secureConnectionState, .trustedMac)
        XCTAssertEqual(service.secureMacFingerprint, codexSecureFingerprint(for: macPublicKey))
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
    }

    func testRepeatedTrustedReconnectDisconnectsEscalateToManualRePair() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let macPublicKey = "public-key-\(UUID().uuidString)"

        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "wss://relay.test/relay"
        service.relayMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date()
        )

        for _ in 0..<3 {
            service.secureConnectionState = .reconnecting
            service.handleReceiveError(NWError.posix(.ECONNABORTED))
        }

        XCTAssertEqual(service.trustedReconnectFailureCount, 3)
        XCTAssertFalse(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.connectionRecoveryState, .idle)
        XCTAssertEqual(service.secureConnectionState, .rePairRequired)
        XCTAssertEqual(
            service.lastErrorMessage,
            "Secure reconnect could not be restored. Scan a new QR code to reconnect."
        )
    }

    func testTrustedReconnectHandshakeFailureCounterResetsForFreshPairing() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"

        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "wss://relay.test/relay"
        service.relayMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: "public-key-\(UUID().uuidString)",
            lastPairedAt: Date()
        )

        XCTAssertFalse(service.recordTrustedReconnectFailureIfNeeded(isTrustedReconnectAttempt: true))
        XCTAssertEqual(service.trustedReconnectFailureCount, 1)

        service.rememberRelayPairing(
            CodexPairingQRPayload(
                v: codexPairingQRVersion,
                relay: "wss://relay.test/relay",
                sessionId: "fresh-session-\(UUID().uuidString)",
                macDeviceId: macDeviceID,
                macIdentityPublicKey: "fresh-public-key-\(UUID().uuidString)",
                expiresAt: Int64(Date().timeIntervalSince1970) + 60
            )
        )

        XCTAssertEqual(service.trustedReconnectFailureCount, 0)
    }

    func testSavedRelaySessionRequiresBothSessionIdAndRelayURL() {
        let service = makeService()

        XCTAssertFalse(service.hasSavedRelaySession)

        service.relaySessionId = "session-1"
        XCTAssertFalse(service.hasSavedRelaySession)

        service.relayUrl = "wss://relay.test/relay"
        XCTAssertTrue(service.hasSavedRelaySession)
    }

    func testRecoverableTimeoutMapsToFriendlyFailureMessage() {
        let service = makeService()

        XCTAssertTrue(service.isRecoverableTransientConnectionError(NWError.posix(.ETIMEDOUT)))
        XCTAssertEqual(
            service.userFacingConnectFailureMessage(NWError.posix(.ETIMEDOUT)),
            "Connection timed out. Check server/network."
        )
    }

    func testAssistantStreamingKeepsSeparateBlocksWhenItemChangesWithinTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " chunk")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-2", delta: "Second")

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages[0].itemId, "item-1")
        XCTAssertEqual(assistantMessages[0].text, "First chunk")
        XCTAssertFalse(assistantMessages[0].isStreaming)

        XCTAssertEqual(assistantMessages[1].itemId, "item-2")
        XCTAssertEqual(assistantMessages[1].text, "Second")
        XCTAssertTrue(assistantMessages[1].isStreaming)
    }

    func testAssistantStreamingUpdatesExistingRenderSnapshotText() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        _ = service.timelineState(for: threadID)
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        let firstSnapshot = service.timelineState(for: threadID).renderSnapshot

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " chunk")
        let secondSnapshot = service.timelineState(for: threadID).renderSnapshot

        XCTAssertEqual(firstSnapshot.messages.count, 1)
        XCTAssertEqual(firstSnapshot.messages[0].text, "First")
        XCTAssertEqual(secondSnapshot.messages.count, 1)
        XCTAssertEqual(secondSnapshot.messages[0].text, "First chunk")
        XCTAssertGreaterThan(secondSnapshot.timelineChangeToken, firstSnapshot.timelineChangeToken)
    }

    func testAssistantStreamingFastPathKeepsCurrentOutputInSync() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        _ = service.timelineState(for: threadID)
        service.activeThreadId = threadID

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " chunk")

        XCTAssertEqual(service.currentOutput, "First chunk")
    }

    func testMarkTurnCompletedFinalizesAllAssistantItemsForTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "A")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-2", delta: "B")

        service.markTurnCompleted(threadId: threadID, turnId: turnID)

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertTrue(assistantMessages.allSatisfy { !$0.isStreaming })

        let turnStreamingKey = "\(threadID)|\(turnID)"
        XCTAssertFalse(service.streamingAssistantMessageByTurnID.keys.contains { key in
            key == turnStreamingKey || key.hasPrefix("\(turnStreamingKey)|item:")
        })
    }

    func testLegacyAgentDeltaParsesTopLevelTurnIdAndMessageId() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-1"),
                    "delta": .string("Primo blocco"),
                ]),
            ])
        )

        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-2"),
                    "delta": .string("Secondo blocco"),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages[0].turnId, turnID)
        XCTAssertEqual(assistantMessages[0].itemId, "message-1")
        XCTAssertEqual(assistantMessages[0].text, "Primo blocco")
        XCTAssertFalse(assistantMessages[0].isStreaming)

        XCTAssertEqual(assistantMessages[1].turnId, turnID)
        XCTAssertEqual(assistantMessages[1].itemId, "message-2")
        XCTAssertEqual(assistantMessages[1].text, "Secondo blocco")
        XCTAssertTrue(assistantMessages[1].isStreaming)
    }

    func testLegacyAgentCompletionUsesMessageIdToFinalizeMatchingStream() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/agent_message_content_delta",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message_content_delta"),
                    "message_id": .string("message-1"),
                    "delta": .string("Testo parziale"),
                ]),
            ])
        )

        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message"),
                    "message_id": .string("message-1"),
                    "message": .string("Testo finale"),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages[0].turnId, turnID)
        XCTAssertEqual(assistantMessages[0].itemId, "message-1")
        XCTAssertEqual(assistantMessages[0].text, "Testo finale")
        XCTAssertFalse(assistantMessages[0].isStreaming)
    }

    private func sendTurnStarted(service: CodexService, threadID: String, turnID: String) {
        service.handleNotification(
            method: "turn/started",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
    }

    private func sendTurnCompletedSuccess(service: CodexService, threadID: String, turnID: String) {
        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
            ])
        )
    }

    private func sendTurnCompletedFailure(
        service: CodexService,
        threadID: String,
        turnID: String,
        message: String
    ) {
        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object([
                    "id": .string(turnID),
                    "status": .string("failed"),
                    "error": .object([
                        "message": .string(message),
                    ]),
                ]),
            ])
        )
    }

    private func sendTurnCompletedStopped(service: CodexService, threadID: String, turnID: String) {
        service.handleNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string(threadID),
                "turn": .object([
                    "id": .string(turnID),
                    "status": .string("interrupted"),
                ]),
            ])
        )
    }

    private func sendTurnFailed(service: CodexService, threadID: String, turnID: String, message: String) {
        service.handleNotification(
            method: "turn/failed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "message": .string(message),
            ])
        )
    }

    private func makeService() -> CodexService {
        let suiteName = "CodexServiceIncomingRunIndicatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let service = CodexService(defaults: defaults)
        service.messagesByThread = [:]
        // CodexService currently crashes while deallocating in unit-test environment.
        // Keep instances alive for process lifetime so assertions remain deterministic.
        Self.retainedServices.append(service)
        return service
    }

    // Persists a relay pairing the same way the app does so close-code cleanup can be tested honestly.
    private func withSavedRelayPairing(
        sessionId: String,
        relayURL: String,
        perform body: () -> Void
    ) {
        SecureStore.writeString(sessionId, for: CodexSecureKeys.relaySessionId)
        SecureStore.writeString(relayURL, for: CodexSecureKeys.relayUrl)
        defer {
            SecureStore.deleteValue(for: CodexSecureKeys.relaySessionId)
            SecureStore.deleteValue(for: CodexSecureKeys.relayUrl)
        }

        body()
    }

    private func flushAsyncSideEffects() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
}
