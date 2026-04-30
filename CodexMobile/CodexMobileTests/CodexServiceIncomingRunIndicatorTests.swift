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

    func testAssistantDeltaCoalescingAppliesOrderedDeltasOnFlush() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "item-\(UUID().uuidString)"

        service.enqueueAssistantDelta(threadId: threadID, turnId: turnID, itemId: itemID, delta: "Hello")
        service.enqueueAssistantDelta(threadId: threadID, turnId: turnID, itemId: itemID, delta: " world")

        XCTAssertTrue(service.messages(for: threadID).isEmpty)

        service.flushAllPendingStreamingDeltas()

        let messages = service.messages(for: threadID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.text, "Hello world")
        XCTAssertTrue(messages.first?.isStreaming == true)
    }

    func testAssistantDeltaCoalescingMergesCumulativeSnapshotsBeforeFlush() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "item-\(UUID().uuidString)"

        service.enqueueAssistantDelta(threadId: threadID, turnId: turnID, itemId: itemID, delta: "Yes")
        service.enqueueAssistantDelta(threadId: threadID, turnId: turnID, itemId: itemID, delta: "Yes, the")
        service.enqueueAssistantDelta(threadId: threadID, turnId: turnID, itemId: itemID, delta: "Yes, the imagegen skill")

        service.flushAllPendingStreamingDeltas()

        let messages = service.messages(for: threadID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "Yes, the imagegen skill")
        XCTAssertTrue(messages.first?.isStreaming == true)
    }

    func testSystemDeltaCoalescingAppliesThinkingDeltasOnFlush() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "thinking-\(UUID().uuidString)"

        service.appendStreamingSystemItemDelta(
            threadId: threadID,
            turnId: turnID,
            itemId: itemID,
            kind: .thinking,
            delta: "Looking"
        )
        service.appendStreamingSystemItemDelta(
            threadId: threadID,
            turnId: turnID,
            itemId: itemID,
            kind: .thinking,
            delta: " around"
        )

        XCTAssertTrue(service.messages(for: threadID).isEmpty)

        service.flushAllPendingStreamingDeltas()

        let messages = service.messages(for: threadID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .system)
        XCTAssertEqual(messages.first?.kind, .thinking)
        XCTAssertEqual(messages.first?.text, "Looking around")
        XCTAssertTrue(messages.first?.isStreaming == true)
    }

    func testNilTurnSystemDeltasFlushBeforeTurnCompletionClosesRows() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let itemID = "thinking-\(UUID().uuidString)"

        service.appendStreamingSystemItemDelta(
            threadId: threadID,
            turnId: nil,
            itemId: itemID,
            kind: .thinking,
            delta: "Recovering"
        )

        XCTAssertTrue(service.messages(for: threadID).isEmpty)

        service.markTurnCompleted(threadId: threadID, turnId: nil)

        let messages = service.messages(for: threadID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.kind, .thinking)
        XCTAssertEqual(messages.first?.text, "Recovering")
        XCTAssertFalse(messages.first?.isStreaming ?? true)
        XCTAssertTrue(service.pendingSystemDeltasByKey.isEmpty)
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

    func testProtectedRunningFallbackAloneStillKeepsTimelineRunning() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.protectedRunningFallbackThreadIDs.insert(threadID)
        service.refreshThreadTimelineState(for: threadID)

        XCTAssertEqual(service.threadRunBadgeState(for: threadID), .running)
        XCTAssertTrue(service.timelineState(for: threadID).renderSnapshot.isThreadRunning)
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

    func testPrepareThreadForDisplaySkipsHydrationForFreshEmptyThread() async {
        let service = makeService()
        let freshThreadID = "thread-fresh-\(UUID().uuidString)"
        let runningThreadID = "thread-running-\(UUID().uuidString)"
        let runningTurnID = "turn-running-\(UUID().uuidString)"

        service.isConnected = true
        service.isInitialized = true
        service.threads = [
            CodexThread(id: freshThreadID, createdAt: Date(), updatedAt: Date()),
            CodexThread(id: runningThreadID, createdAt: Date(), updatedAt: Date())
        ]
        service.resumedThreadIDs.insert(freshThreadID)
        service.runningThreadIDs.insert(runningThreadID)
        service.activeTurnIdByThread[runningThreadID] = runningTurnID
        service.activeThreadId = runningThreadID

        var recordedMethods: [String] = []
        service.requestTransportOverride = { method, _ in
            recordedMethods.append(method)
            XCTFail("Fresh empty thread should not trigger RPC during initial display prep")
            return RPCMessage(id: .string(UUID().uuidString), result: .object([:]), includeJSONRPC: false)
        }

        let didPrepare = await service.prepareThreadForDisplay(threadId: freshThreadID)

        XCTAssertTrue(didPrepare)
        XCTAssertEqual(service.activeThreadId, freshThreadID)
        XCTAssertTrue(recordedMethods.isEmpty)
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

    func testMacUnavailableCloseKeepsSavedPairingAndRetriesReconnect() {
        let service = makeService()

        withSavedRelayPairing(sessionId: "session-\(UUID().uuidString)", relayURL: "wss://relay.test/relay") {
            service.relaySessionId = SecureStore.readString(for: CodexSecureKeys.relaySessionId)
            service.relayUrl = SecureStore.readString(for: CodexSecureKeys.relayUrl)
            service.isConnected = true
            service.isInitialized = true
            service.lastErrorMessage = nil
            service.setForegroundState(true)

            service.handleReceiveError(
                CodexServiceError.disconnected,
                relayCloseCode: .privateCode(4002)
            )

            XCTAssertFalse(service.isConnected)
            XCTAssertFalse(service.isInitialized)
            XCTAssertTrue(service.shouldAutoReconnectOnForeground)
            XCTAssertEqual(service.relaySessionId, SecureStore.readString(for: CodexSecureKeys.relaySessionId))
            XCTAssertEqual(service.relayUrl, SecureStore.readString(for: CodexSecureKeys.relayUrl))
            XCTAssertEqual(
                service.lastErrorMessage,
                "The saved Mac session is temporarily unavailable. Remodex will keep retrying. If you restarted the bridge on your Mac, scan the new QR code."
            )
            XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 0, message: "Reconnecting..."))
        }
    }

    func testReceiveErrorClearsResumedThreadCacheForReconnect() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"

        service.resumedThreadIDs = [threadID]
        service.isConnected = true
        service.isInitialized = true

        service.handleReceiveError(
            CodexServiceError.disconnected,
            relayCloseCode: .privateCode(4002)
        )

        XCTAssertTrue(service.resumedThreadIDs.isEmpty)
    }

    func testMacAbsenceBufferOverflowKeepsPairingAndShowsRetryMessage() {
        let service = makeService()

        withSavedRelayPairing(sessionId: "session-\(UUID().uuidString)", relayURL: "wss://relay.test/relay") {
            service.relaySessionId = SecureStore.readString(for: CodexSecureKeys.relaySessionId)
            service.relayUrl = SecureStore.readString(for: CodexSecureKeys.relayUrl)
            service.isConnected = true
            service.isInitialized = true
            service.lastErrorMessage = nil
            service.setForegroundState(true)

            service.handleReceiveError(
                CodexServiceError.disconnected,
                relayCloseCode: .privateCode(4004)
            )

            XCTAssertFalse(service.isConnected)
            XCTAssertFalse(service.isInitialized)
            XCTAssertTrue(service.shouldAutoReconnectOnForeground)
            XCTAssertEqual(service.connectionRecoveryState, .idle)
            XCTAssertEqual(service.relaySessionId, SecureStore.readString(for: CodexSecureKeys.relaySessionId))
            XCTAssertEqual(service.relayUrl, SecureStore.readString(for: CodexSecureKeys.relayUrl))
            XCTAssertEqual(
                service.lastErrorMessage,
                "The Mac was temporarily unavailable and this message could not be delivered. Wait a moment, then try again."
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

    func testTrustedReconnectReceiveErrorDoesNotAdvanceFailureBudgetByItself() {
        let service = makeService()
        let macDeviceID = "mac-\(UUID().uuidString)"
        let macPublicKey = "public-key-\(UUID().uuidString)"

        service.relaySessionId = "session-\(UUID().uuidString)"
        service.relayUrl = "wss://relay.test/relay"
        service.relayMacDeviceId = macDeviceID
        service.lastTrustedMacDeviceId = macDeviceID
        service.trustedMacRegistry.records[macDeviceID] = CodexTrustedMacRecord(
            macDeviceId: macDeviceID,
            macIdentityPublicKey: macPublicKey,
            lastPairedAt: Date(),
            relayURL: "wss://relay.test/relay"
        )

        for _ in 0..<3 {
            service.secureConnectionState = .reconnecting
            service.handleReceiveError(NWError.posix(.ECONNABORTED))
        }

        XCTAssertEqual(service.trustedReconnectFailureCount, 0)
        XCTAssertTrue(service.shouldAutoReconnectOnForeground)
        XCTAssertEqual(service.connectionRecoveryState, .retrying(attempt: 0, message: "Reconnecting..."))
        XCTAssertEqual(service.secureConnectionState, .trustedMac)
        XCTAssertNotNil(service.relaySessionId)
        XCTAssertNotNil(service.relayUrl)
        XCTAssertEqual(service.relayMacDeviceId, macDeviceID)
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertTrue(service.hasSavedRelaySession)
        XCTAssertTrue(service.hasTrustedMacReconnectCandidate)
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
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

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
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)
        let firstSnapshot = service.timelineState(for: threadID).renderSnapshot

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " chunk")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)
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
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        XCTAssertEqual(service.currentOutput, "First chunk")
    }

    func testAssistantStreamingFallbackKeepsCurrentOutputInSyncWithoutTimelineState() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.activeThreadId = threadID

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " chunk")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        XCTAssertEqual(service.currentOutput, "First chunk")
        XCTAssertEqual(service.timelineState(for: threadID).renderSnapshot.messages.first?.text, "First chunk")
    }

    func testLateDeltaForOlderAssistantItemDoesNotReplaceLatestOutput() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        _ = service.timelineState(for: threadID)
        service.activeThreadId = threadID

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-2", delta: "Second")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " tail")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        XCTAssertEqual(service.currentOutput, "Second")
    }

    func testLateOlderAssistantItemDeltaDoesNotStealTurnFallbackStream() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-2", delta: "Second")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: " tail")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: nil, delta: " current")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.map { $0.itemId ?? "" }, ["item-1", "item-2"])
        XCTAssertEqual(assistantMessages.map(\.text), ["First tail", "Second current"])
    }

    func testLateOlderAssistantCompletionDoesNotStealTurnFallbackStream() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-1", delta: "First")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-2", delta: "Second")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        service.completeAssistantMessage(threadId: threadID, turnId: turnID, itemId: "item-1", text: "First final")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: nil, delta: " current")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.map { $0.itemId ?? "" }, ["item-1", "item-2"])
        XCTAssertEqual(assistantMessages.map(\.text), ["First final", "Second current"])
    }

    func testUnseenItemCompletionDoesNotStealTurnFallbackStream() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: "item-2", delta: "Second")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        service.completeAssistantMessage(threadId: threadID, turnId: turnID, itemId: "item-1", text: "First final")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: nil, delta: " current")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.map { $0.itemId ?? "" }, ["item-2", "item-1"])
        XCTAssertEqual(assistantMessages.map(\.text), ["Second current", "First final"])
        XCTAssertFalse(assistantMessages.last?.isStreaming ?? true)
    }

    func testItemCompletionBeforeFallbackDoesNotCaptureTurnScopedDelta() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.completeAssistantMessage(threadId: threadID, turnId: turnID, itemId: "item-1", text: "First final")
        service.appendAssistantDelta(threadId: threadID, turnId: turnID, itemId: nil, delta: " current")
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.map { $0.itemId ?? "" }, ["item-1", ""])
        XCTAssertEqual(assistantMessages.map(\.text), ["First final", " current"])
        XCTAssertFalse(assistantMessages.first?.isStreaming ?? true)
        XCTAssertTrue(assistantMessages.last?.isStreaming ?? false)
    }

    func testCanonicalItemCompletionPreservesLateTurnImagePreview() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let imagePath = "/tmp/generated-preview.png"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: "Here is the generated image."
        )
        service.appendGeneratedImageReference(
            threadId: threadID,
            turnId: turnID,
            itemId: "image-item",
            imagePath: imagePath
        )
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "prose-item",
            text: "Here is the final generated image."
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.itemId, "prose-item")
        XCTAssertEqual(
            assistantMessages.first?.text,
            "Here is the final generated image.\n\n![Generated image](\(imagePath))"
        )
    }

    func testFinalReplayCompletionAbsorbsPriorImagePreviewBubble() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let introText = "Using the imagegen skill for this as a new bitmap icon asset."
        let finalText = "Done. Generated a polished wing icon image using the built-in image generation tool."
        let imagePath = "/tmp/generated-wing.png"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "intro-item",
            text: introText
        )
        service.appendGeneratedImageReference(
            threadId: threadID,
            turnId: turnID,
            itemId: "image-item",
            imagePath: imagePath
        )
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "final-item",
            text: "\(finalText)\n\n\(introText)"
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(
            assistantMessages.first?.text,
            "\(finalText)\n\n![Generated image](\(imagePath))"
        )
    }

    func testFinalCompletionAfterImagePreviewReplacesPreparatoryBubble() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let introText = "Using the imagegen skill for this as a new raster icon asset."
        let finalText = "Generated a clean wing icon image using the built-in image generator."
        let imagePath = "/tmp/generated-wing.png"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: introText
        )
        service.appendGeneratedImageReference(
            threadId: threadID,
            turnId: turnID,
            itemId: "image-item",
            imagePath: imagePath
        )
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: finalText
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(
            assistantMessages.first?.text,
            "\(finalText)\n\n![Generated image](\(imagePath))"
        )
    }

    func testTurnlessFinalAnswerCompletionUsesActiveTurnImagePreview() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let introText = "Preparing an image asset for the current request."
        let finalText = "Generated a clean wing icon image using the built-in image generator."
        let imagePath = "/tmp/generated-wing.png"

        sendTurnStarted(service: service, threadID: threadID, turnID: turnID)
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: introText
        )
        service.appendGeneratedImageReference(
            threadId: threadID,
            turnId: nil,
            itemId: "image-item",
            imagePath: imagePath
        )
        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "threadId": .string(threadID),
                "msg": .object([
                    "type": .string("agent_message"),
                    "phase": .string("final_answer"),
                    "message": .string(finalText),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.turnId, turnID)
        XCTAssertEqual(
            assistantMessages.first?.text,
            "\(finalText)\n\n![Generated image](\(imagePath))"
        )
    }

    func testItemScopedCompletionAfterImagePreviewStaysSeparate() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let introText = "Preparing an image asset for the current request."
        let laterItemText = "Here is a separate assistant item in the same turn."
        let imagePath = "/tmp/generated-wing.png"

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: introText
        )
        service.appendGeneratedImageReference(
            threadId: threadID,
            turnId: turnID,
            itemId: "image-item",
            imagePath: imagePath
        )
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "later-assistant-item",
            text: laterItemText
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(
            assistantMessages.first?.text,
            "\(introText)\n\n![Generated image](\(imagePath))"
        )
        XCTAssertEqual(assistantMessages.last?.text, laterItemText)
    }

    func testHistoryDecodeMergesGeneratedImageArtifactIntoFinalAssistantAnswer() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let introText = "Preparing an image asset for the current request."
        let finalText = "Generated a clean wing icon image using the built-in image generator."
        let imagePath = "/tmp/generated-wing.png"

        let messages = service.decodeMessagesFromThreadRead(
            threadId: threadID,
            threadObject: [
                "turns": .array([
                    .object([
                        "id": .string(turnID),
                        "items": .array([
                            .object([
                                "id": .string("intro-item"),
                                "type": .string("agentMessage"),
                                "content": .array([
                                    .object([
                                        "type": .string("output_text"),
                                        "text": .string(introText),
                                    ]),
                                ]),
                            ]),
                            .object([
                                "id": .string("image-item"),
                                "type": .string("imageGenerationCall"),
                                "file_path": .string(imagePath),
                            ]),
                            .object([
                                "id": .string("final-item"),
                                "type": .string("agentMessage"),
                                "content": .array([
                                    .object([
                                        "type": .string("output_text"),
                                        "text": .string(finalText),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]
        )

        let assistantMessages = messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages.first?.text, introText)
        XCTAssertEqual(
            assistantMessages.last?.text,
            "\(finalText)\n\n![Generated image](\(imagePath))"
        )
    }

    func testHistoryMergeCleansExistingDuplicateGeneratedImageArtifact() throws {
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let introText = "Preparing an image asset for the current request."
        let finalText = "Generated a clean wing icon image using the built-in image generator."
        let imagePath = "/tmp/generated-wing.png"
        let imageMarkdown = "![Generated image](\(imagePath))"

        let existing = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "\(introText)\n\n\(imageMarkdown)",
                turnId: turnID,
                itemId: "intro-item",
                isStreaming: false
            ),
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: finalText,
                turnId: turnID,
                itemId: "final-item",
                isStreaming: false
            ),
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: imageMarkdown,
                turnId: turnID,
                itemId: "image-item",
                isStreaming: false
            ),
        ]
        let history = [
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: introText,
                turnId: turnID,
                itemId: "intro-item",
                isStreaming: false
            ),
            CodexMessage(
                threadId: threadID,
                role: .assistant,
                text: "\(finalText)\n\n\(imageMarkdown)",
                turnId: turnID,
                itemId: "final-item",
                isStreaming: false
            ),
        ]

        let merged = try CodexService.mergeHistoryMessages(
            existing,
            history,
            activeThreadIDs: [],
            runningThreadIDs: []
        ).filter { $0.role == .assistant }

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.text, introText)
        XCTAssertEqual(merged.last?.text, "\(finalText)\n\n\(imageMarkdown)")
    }

    func testIdentifierlessLateCompletionDoesNotAttachPreviousResponseToNewTurn() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let firstTurnID = "turn-\(UUID().uuidString)"
        let secondTurnID = "turn-\(UUID().uuidString)"

        service.appendUserMessage(threadId: threadID, text: "First prompt", turnId: firstTurnID)
        service.appendAssistantDelta(
            threadId: threadID,
            turnId: firstTurnID,
            itemId: "item-1",
            delta: "Previous final"
        )
        service.flushPendingAssistantDeltas(for: threadID, turnId: firstTurnID)
        service.markTurnCompleted(threadId: threadID, turnId: firstTurnID)

        service.setActiveTurnID(secondTurnID, for: threadID)
        service.appendUserMessage(threadId: threadID, text: "Second prompt", turnId: secondTurnID)
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: nil,
            itemId: nil,
            text: "Previous final"
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.turnId, firstTurnID)
        XCTAssertEqual(assistantMessages.first?.text, "Previous final")
    }

    func testIdentifierlessLateCompletionDoesNotOverwriteActiveTurnResponse() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let firstTurnID = "turn-\(UUID().uuidString)"
        let secondTurnID = "turn-\(UUID().uuidString)"

        service.appendUserMessage(threadId: threadID, text: "First prompt", turnId: firstTurnID)
        service.appendAssistantDelta(
            threadId: threadID,
            turnId: firstTurnID,
            itemId: "item-1",
            delta: "Previous final"
        )
        service.flushPendingAssistantDeltas(for: threadID, turnId: firstTurnID)
        service.markTurnCompleted(threadId: threadID, turnId: firstTurnID)

        service.setActiveTurnID(secondTurnID, for: threadID)
        service.appendUserMessage(threadId: threadID, text: "Second prompt", turnId: secondTurnID)
        service.appendAssistantDelta(
            threadId: threadID,
            turnId: secondTurnID,
            itemId: nil,
            delta: "Current answer"
        )
        service.flushPendingAssistantDeltas(for: threadID, turnId: secondTurnID)

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: nil,
            itemId: nil,
            text: "Previous final\n\nOlder replay block"
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages.map(\.turnId), [firstTurnID, secondTurnID])
        XCTAssertEqual(assistantMessages.map(\.text), ["Previous final", "Current answer"])
        XCTAssertTrue(assistantMessages.last?.isStreaming ?? false)
    }

    func testNoItemCompletionReusesClosedAssistantRowWhileThreadStillLooksRunning() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let finalText = "Final answer that was already persisted before mirror replay."

        service.appendMessage(
            CodexMessage(
                id: "assistant-existing",
                threadId: threadID,
                role: .assistant,
                text: finalText,
                turnId: turnID,
                isStreaming: false
            )
        )
        service.markThreadAsRunning(threadID)

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            text: finalText
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.id, "assistant-existing")
        XCTAssertEqual(assistantMessages.first?.text, finalText)
        XCTAssertFalse(assistantMessages.first?.isStreaming ?? true)
    }

    func testFullBlockCompletionReplayDoesNotAppendDuplicateAssistantRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let introText = "I'll check Gmail for the latest TestFlight message."
        let finalText = "Latest TestFlight version: 1.4 (123)."

        service.appendMessage(
            CodexMessage(
                id: "assistant-intro",
                threadId: threadID,
                role: .assistant,
                text: introText,
                turnId: turnID,
                itemId: "item-intro",
                isStreaming: false
            )
        )
        service.appendMessage(
            CodexMessage(
                id: "assistant-final",
                threadId: threadID,
                role: .assistant,
                text: finalText,
                turnId: turnID,
                itemId: "item-final",
                isStreaming: false
            )
        )

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "item-replay",
            text: "\(introText)\n\n\(finalText)"
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.map(\.id), ["assistant-intro", "assistant-final"])
        XCTAssertEqual(assistantMessages.map(\.text), [introText, finalText])
    }

    func testFullBlockCompletionReplayWithoutTurnIdUsesActiveTurnAndDoesNotAppendDuplicateRow() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let introText = "I'll check Gmail for the latest TestFlight message."
        let finalText = "Latest TestFlight version: 1.4 (123)."

        service.setActiveTurnID(turnID, for: threadID)
        service.appendMessage(
            CodexMessage(
                id: "assistant-intro",
                threadId: threadID,
                role: .assistant,
                text: introText,
                turnId: turnID,
                itemId: "item-intro",
                isStreaming: false
            )
        )
        service.appendMessage(
            CodexMessage(
                id: "assistant-final",
                threadId: threadID,
                role: .assistant,
                text: finalText,
                turnId: nil,
                itemId: "item-final",
                isStreaming: false
            )
        )

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: nil,
            itemId: "item-replay",
            text: "\(introText)\n\n\(finalText)"
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.map(\.id), ["assistant-intro", "assistant-final"])
        XCTAssertEqual(assistantMessages.map(\.text), [introText, finalText])
    }

    func testLateDeltaForCompletedTurnDoesNotReopenAssistantBubble() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.appendAssistantDelta(
            threadId: threadID,
            turnId: turnID,
            itemId: "item-1",
            delta: "Final answer"
        )
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.markTurnCompleted(threadId: threadID, turnId: turnID)

        service.appendAssistantDelta(
            threadId: threadID,
            turnId: turnID,
            itemId: nil,
            delta: " replay"
        )
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.text, "Final answer replay")
        XCTAssertFalse(assistantMessages.first?.isStreaming ?? true)
    }

    func testTurnlessFinalThenTerminalReplayDoesNotDuplicateAssistantAnswer() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let finalText = """
        Latest TestFlight inbox email says:

        Remodex version 1.4, build 124

        Subject: "Remodex - Remote AI Coding 1.4 (124) for iOS is now available to test."
        """

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: nil,
            itemId: "item-final",
            text: finalText
        )
        service.recordTurnTerminalState(threadId: threadID, turnId: turnID, state: .completed)
        service.markTurnCompleted(threadId: threadID, turnId: turnID)

        service.appendAssistantDelta(
            threadId: threadID,
            turnId: turnID,
            itemId: "item-status",
            delta: "I'll use the Gmail connector to search your recent inbox."
        )
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID, itemId: "item-status")
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: turnID,
            itemId: "item-terminal",
            text: finalText
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.text, finalText)
        XCTAssertEqual(assistantMessages.first?.turnId, turnID)
        XCTAssertFalse(assistantMessages.first?.isStreaming ?? true)
    }

    func testTurnlessTerminalReplayDoesNotDuplicateAssistantAnswer() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let finalText = """
        Latest TestFlight inbox email says:

        Remodex version 1.4, build 124

        Subject: "Remodex - Remote AI Coding 1.4 (124) for iOS is now available to test."
        """

        service.completeAssistantMessage(
            threadId: threadID,
            turnId: nil,
            itemId: "item-final",
            text: finalText
        )
        service.completeAssistantMessage(
            threadId: threadID,
            turnId: nil,
            itemId: "item-terminal",
            text: finalText
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.text, finalText)
    }

    func testMergeAssistantDeltaKeepsLongReplayOverlapWithoutDuplication() {
        let service = makeService()
        let overlap = String(repeating: "a", count: 300)
        let existing = "prefix-" + overlap
        let incoming = overlap + "-suffix"

        let merged = service.mergeAssistantDelta(existingText: existing, incomingDelta: incoming)

        XCTAssertEqual(merged, "prefix-" + overlap + "-suffix")
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
        XCTAssertNil(service.streamingAssistantFallbackMessageByTurnID[turnStreamingKey])
        XCTAssertFalse(service.streamingAssistantMessageByItemKey.keys.contains { key in
            key.hasPrefix("\(turnStreamingKey)|item:")
        })
    }

    func testSuccessfulTurnCompletionFinalizesIncompletePlanSteps() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "item-\(UUID().uuidString)"

        service.handleNotification(
            method: "turn/plan/updated",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "explanation": .string("Finish the work in safe slices."),
                "plan": .array([
                    .object([
                        "step": .string("Inspect"),
                        "status": .string("completed"),
                    ]),
                    .object([
                        "step": .string("Implement"),
                        "status": .string("in_progress"),
                    ]),
                    .object([
                        "step": .string("Verify"),
                        "status": .string("pending"),
                    ]),
                ]),
            ])
        )

        service.handleNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "item": .object([
                    "id": .string(itemID),
                    "type": .string("plan"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("1. Inspect\n2. Implement\n3. Verify"),
                        ]),
                    ]),
                ]),
            ])
        )

        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)

        let planMessages = service.messages(for: threadID).filter { $0.kind == .plan }
        XCTAssertEqual(planMessages.count, 1)
        XCTAssertFalse(planMessages[0].isStreaming)
        XCTAssertEqual(planMessages[0].planState?.steps.map(\.status), [.completed, .completed, .completed])
        XCTAssertFalse(planMessages[0].shouldDisplayPinnedPlanAccessory)
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

    func testIncomingItemCompletionBeforeFallbackDoesNotCaptureTurnScopedDelta() {
        let service = makeService()
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"

        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message"),
                    "message_id": .string("message-1"),
                    "message": .string("Risposta precedente"),
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
                    "delta": .string("Risposta corrente"),
                ]),
            ])
        )
        service.flushPendingAssistantDeltas(for: threadID, turnId: turnID)

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages.map { $0.itemId ?? "" }, ["message-1", ""])
        XCTAssertEqual(assistantMessages.map(\.text), ["Risposta precedente", "Risposta corrente"])
        XCTAssertFalse(assistantMessages[0].isStreaming)
        XCTAssertTrue(assistantMessages[1].isStreaming)
    }

    func testLateLegacyAgentCompletionWithoutMessageIdUpdatesClosedSingleAssistantBubble() {
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

        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)

        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message"),
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

    func testLateLegacyAgentCompletionWithoutMessageIdIsIgnoredForClosedMultiAssistantTurn() {
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

        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)

        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message"),
                    "message": .string("Risposta finale ambigua"),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages[0].text, "Primo blocco")
        XCTAssertEqual(assistantMessages[1].text, "Secondo blocco")
    }

    func testLateLegacyAgentCompletionWithoutMessageIdDoesNotRegressClosedSingleAssistantBubble() {
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
                    "delta": .string("Testo finale completo"),
                ]),
            ])
        )

        sendTurnCompletedSuccess(service: service, threadID: threadID, turnID: turnID)

        service.handleNotification(
            method: "codex/event/agent_message",
            params: .object([
                "conversationId": .string(threadID),
                "id": .string(turnID),
                "msg": .object([
                    "type": .string("agent_message"),
                    "message": .string("Testo finale"),
                ]),
            ])
        )

        let assistantMessages = service.messages(for: threadID).filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages[0].text, "Testo finale completo")
        XCTAssertEqual(assistantMessages[0].itemId, "message-1")
    }

    func testLongerClosedAssistantSnapshotDoesNotAppendOtherAssistantBlocks() {
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let finalText = """
        Summary

        TLDR: risposta finale.
        """
        let flattenedText = """
        Summary

        TLDR: risposta finale.

        Uso la skill check-code perché sto controllando la repo.

        Riprendo da dove avevo lasciato.
        """
        let localMessage = CodexMessage(
            threadId: threadID,
            role: .assistant,
            text: finalText,
            turnId: turnID,
            itemId: "message-1",
            isStreaming: false
        )
        let serverMessage = CodexMessage(
            threadId: threadID,
            role: .assistant,
            text: flattenedText,
            turnId: turnID,
            itemId: "message-1",
            isStreaming: false
        )

        XCTAssertFalse(
            CodexService.shouldReplaceClosedAssistantMessage(localMessage, with: serverMessage)
        )
    }

    func testClosedAssistantSnapshotWithOlderPrefixDoesNotReplaceFinalBlock() {
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let finalText = "TLDR: risposta finale."
        let flattenedText = """
        Uso la skill check-code perché sto controllando la repo.

        TLDR: risposta finale.
        """
        let localMessage = CodexMessage(
            threadId: threadID,
            role: .assistant,
            text: finalText,
            turnId: turnID,
            itemId: "message-1",
            isStreaming: false
        )
        let serverMessage = CodexMessage(
            threadId: threadID,
            role: .assistant,
            text: flattenedText,
            turnId: turnID,
            itemId: "message-1",
            isStreaming: false
        )

        XCTAssertFalse(
            CodexService.shouldReplaceClosedAssistantMessage(localMessage, with: serverMessage)
        )
    }

    func testRunningHistorySnapshotWithoutItemDoesNotPolluteItemScopedAssistant() throws {
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let currentText = "Si, sure-sure per i processi pesanti."
        let flattenedText = """
        Si, sure-sure per i processi pesanti.

        Controllo solo i processi attivi, senza lanciare build o test.

        Si, sure-sure per i processi pesanti.
        """
        let localMessage = CodexMessage(
            id: CodexService.stableAssistantMessageID(threadId: threadID, turnId: turnID, itemId: "message-current")!,
            threadId: threadID,
            role: .assistant,
            text: currentText,
            turnId: turnID,
            itemId: "message-current",
            isStreaming: true
        )
        let serverSnapshot = CodexMessage(
            threadId: threadID,
            role: .assistant,
            text: flattenedText,
            turnId: turnID,
            itemId: nil,
            isStreaming: false
        )

        let merged = try CodexService.mergeHistoryMessages(
            [localMessage],
            [serverSnapshot],
            activeThreadIDs: [threadID],
            runningThreadIDs: []
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, currentText)
        XCTAssertEqual(merged[0].itemId, "message-current")
        XCTAssertTrue(merged[0].isStreaming)
    }

    func testRunningHistorySnapshotWithRepeatedPrefixDoesNotDuplicateAssistantText() throws {
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "message-current"
        let currentText = "Si, sure-sure per i processi pesanti."
        let flattenedText = """
        Si, sure-sure per i processi pesanti.

        Controllo solo i processi attivi, senza lanciare build o test.

        Si, sure-sure per i processi pesanti.
        """
        let localMessage = CodexMessage(
            id: CodexService.stableAssistantMessageID(threadId: threadID, turnId: turnID, itemId: itemID)!,
            threadId: threadID,
            role: .assistant,
            text: currentText,
            turnId: turnID,
            itemId: itemID,
            isStreaming: true
        )
        let serverSnapshot = CodexMessage(
            id: CodexService.stableAssistantMessageID(threadId: threadID, turnId: turnID, itemId: itemID)!,
            threadId: threadID,
            role: .assistant,
            text: flattenedText,
            turnId: turnID,
            itemId: itemID,
            isStreaming: false
        )

        let merged = try CodexService.mergeHistoryMessages(
            [localMessage],
            [serverSnapshot],
            activeThreadIDs: [threadID],
            runningThreadIDs: []
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, currentText)
        XCTAssertEqual(merged[0].itemId, itemID)
        XCTAssertTrue(merged[0].isStreaming)
    }

    func testRunningHistorySnapshotWithExtraOlderSuffixDoesNotExtendAssistantText() throws {
        let threadID = "thread-\(UUID().uuidString)"
        let turnID = "turn-\(UUID().uuidString)"
        let itemID = "message-current"
        let currentText = "Si, sure-sure per i processi pesanti."
        let flattenedText = """
        Si, sure-sure per i processi pesanti.

        Controllo solo i processi attivi, senza lanciare build o test.
        """
        let localMessage = CodexMessage(
            id: CodexService.stableAssistantMessageID(threadId: threadID, turnId: turnID, itemId: itemID)!,
            threadId: threadID,
            role: .assistant,
            text: currentText,
            turnId: turnID,
            itemId: itemID,
            isStreaming: true
        )
        let serverSnapshot = CodexMessage(
            id: CodexService.stableAssistantMessageID(threadId: threadID, turnId: turnID, itemId: itemID)!,
            threadId: threadID,
            role: .assistant,
            text: flattenedText,
            turnId: turnID,
            itemId: itemID,
            isStreaming: false
        )

        let merged = try CodexService.mergeHistoryMessages(
            [localMessage],
            [serverSnapshot],
            activeThreadIDs: [threadID],
            runningThreadIDs: []
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, currentText)
        XCTAssertEqual(merged[0].itemId, itemID)
        XCTAssertTrue(merged[0].isStreaming)
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
