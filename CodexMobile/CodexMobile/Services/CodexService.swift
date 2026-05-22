// FILE: CodexService.swift
// Purpose: Central state container for Codex app-server communication.
// Layer: Service
// Exports: CodexService, CodexApprovalRequest
// Depends on: Foundation, Observation, RPCMessage, CodexThread, CodexMessage, UserNotifications

import Foundation
import Network
import Observation
import UIKit
import UserNotifications

struct CodexApprovalRequest: Identifiable, Sendable {
    let id: String
    let requestID: JSONValue
    let method: String
    let command: String?
    let reason: String?
    let threadId: String?
    let turnId: String?
    let params: JSONValue?
}

struct CodexRecentActivityLine {
    let line: String
    let timestamp: Date
}

struct CodexRunningThreadWatch: Equatable, Sendable {
    let threadId: String
    let expiresAt: Date
}

struct CodexThreadResumeRequestSignature: Equatable, Sendable {
    let projectPath: String?
    let modelIdentifier: String?
}

struct CodexThreadHistoryPaginationState: Codable, Equatable, Sendable {
    var olderCursor: JSONValue?
    var exhaustedOlderCursor: JSONValue?
    var hasAuthoritativeLocalHistoryStart: Bool
}

struct CodexSubagentIdentityEntry: Equatable, Sendable {
    var threadId: String?
    var agentId: String?
    var nickname: String?
    var role: String?

    var hasMetadata: Bool {
        threadId != nil || agentId != nil || nickname != nil || role != nil
    }
}

struct CodexSecureControlWaiter {
    let id: UUID
    let continuation: CheckedContinuation<String, Error>
}

enum CodexWebSocketTransport {
    case network(NWConnection)
    case manualTCP(NWConnection)
    case urlSession(URLSession, URLSessionWebSocketTask)
}

final class CodexURLSessionWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openResult: Result<Void, Error>?

    // Waits for URLSession to confirm the websocket handshake before connect() continues.
    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            if let openResult {
                continuation.resume(with: openResult)
                return
            }
            openContinuation = continuation
        }
    }

    // Resolves the initial websocket open exactly once from any delegate callback.
    func resolveOpen(with result: Result<Void, Error>) {
        lock.lock()
        guard openResult == nil else {
            lock.unlock()
            return
        }
        openResult = result
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        resolveOpen(with: .success(()))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        if closeCode == .invalid {
            resolveOpen(with: .failure(CodexServiceError.disconnected))
            return
        }

        resolveOpen(
            with: .failure(
                CodexServiceError.invalidInput("WebSocket closed during connect (\(closeCode.rawValue))")
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            resolveOpen(with: .failure(error))
        }
    }
}

struct CodexBridgeUpdatePrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let command: String?

    init(
        title: String,
        message: String,
        command: String?
    ) {
        self.title = title
        self.message = message
        self.command = command
    }
}

struct CodexThreadRuntimeOverride: Codable, Equatable, Sendable {
    var reasoningEffort: String?
    var serviceTierRawValue: String?
    var overridesReasoning: Bool
    var overridesServiceTier: Bool

    var serviceTier: CodexServiceTier? {
        guard let serviceTierRawValue else {
            return nil
        }
        return CodexServiceTier(rawValue: serviceTierRawValue)
    }

    var isEmpty: Bool {
        !overridesReasoning && !overridesServiceTier
    }
}

struct CodexThreadCompletionBanner: Identifiable, Equatable, Sendable {
    let id = UUID()
    let threadId: String
    let title: String
}

struct CodexMissingNotificationThreadPrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    let threadId: String
}

enum CodexThreadRunBadgeState: Hashable, Sendable {
    case running
    case ready
    case failed
}

enum CodexRunCompletionResult: String, Equatable, Sendable {
    case completed
    case failed
}

enum CodexNotificationPayloadKeys {
    static let source = "source"
    static let threadId = "threadId"
    static let turnId = "turnId"
    static let result = "result"
    static let requestId = "requestId"
}

// Tracks the real terminal outcome of a run, including user interruption.
enum CodexTurnTerminalState: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case stopped
}

enum CodexConnectionRecoveryState: Equatable, Sendable {
    case idle
    case retrying(attempt: Int, message: String)
}

enum CodexConnectionPhase: Equatable, Sendable {
    case offline
    case connecting
    case loadingChats
    case syncing
    case connected
}

enum CodexPendingThreadComposerAction: Equatable, Sendable {
    case codeReview(target: CodexPendingCodeReviewTarget)
}

enum CodexThreadForkTarget: Equatable, Sendable {
    case currentProject
    case projectPath(String)
}

enum CodexPendingCodeReviewTarget: Equatable, Sendable {
    case uncommittedChanges
    case baseBranch
}

struct TurnTimelineRenderSnapshot: Equatable {
    let threadID: String
    let messages: [CodexMessage]
    let messageIndexByID: [String: Int]
    let planMatchingMessages: [CodexMessage]
    let timelineChangeToken: Int
    let activeTurnID: String?
    let isThreadRunning: Bool
    let latestTurnTerminalState: CodexTurnTerminalState?
    let completedTurnIDs: Set<String>
    let stoppedTurnIDs: Set<String>
    let assistantRevertStatesByMessageID: [String: AssistantRevertPresentation]
    let repoRefreshSignal: String?
    let hasOlderHistory: Bool
    let hasRemoteOlderHistory: Bool
    let hasLocallyProjectedOlderHistory: Bool
    let usesPaginatedHistory: Bool
    let isLoadingOlderHistory: Bool
    let initialTurnsLoaded: Bool
    let olderHistoryLoadErrorMessage: String?

    static func empty(threadID: String) -> TurnTimelineRenderSnapshot {
        TurnTimelineRenderSnapshot(
            threadID: threadID,
            messages: [],
            messageIndexByID: [:],
            planMatchingMessages: [],
            timelineChangeToken: 0,
            activeTurnID: nil,
            isThreadRunning: false,
            latestTurnTerminalState: nil,
            completedTurnIDs: [],
            stoppedTurnIDs: [],
            assistantRevertStatesByMessageID: [:],
            repoRefreshSignal: nil,
            hasOlderHistory: false,
            hasRemoteOlderHistory: false,
            hasLocallyProjectedOlderHistory: false,
            usesPaginatedHistory: false,
            isLoadingOlderHistory: false,
            initialTurnsLoaded: false,
            olderHistoryLoadErrorMessage: nil
        )
    }
}

struct PendingSystemStreamingDeltas {
    let threadId: String
    let turnId: String?
    let itemId: String
    let kind: CodexMessageKind
    var deltas: [String]
}

@MainActor
@Observable
final class ThreadTimelineState {
    let threadID: String
    var messages: [CodexMessage]
    var messageRevision: Int
    var activeTurnID: String?
    var isThreadRunning: Bool
    var latestTurnTerminalState: CodexTurnTerminalState?
    var completedTurnIDs: Set<String>
    var stoppedTurnIDs: Set<String>
    var repoRefreshSignal: String?
    var hasOlderHistory: Bool
    var hasRemoteOlderHistory: Bool
    var hasLocallyProjectedOlderHistory: Bool
    var usesPaginatedHistory: Bool
    var isLoadingOlderHistory: Bool
    var initialTurnsLoaded: Bool
    var olderHistoryLoadErrorMessage: String?
    var renderSnapshot: TurnTimelineRenderSnapshot

    init(threadID: String) {
        self.threadID = threadID
        self.messages = []
        self.messageRevision = 0
        self.activeTurnID = nil
        self.isThreadRunning = false
        self.latestTurnTerminalState = nil
        self.completedTurnIDs = []
        self.stoppedTurnIDs = []
        self.repoRefreshSignal = nil
        self.hasOlderHistory = false
        self.hasRemoteOlderHistory = false
        self.hasLocallyProjectedOlderHistory = false
        self.usesPaginatedHistory = false
        self.isLoadingOlderHistory = false
        self.initialTurnsLoaded = false
        self.olderHistoryLoadErrorMessage = nil
        self.renderSnapshot = TurnTimelineRenderSnapshot.empty(threadID: threadID)
    }
}

struct AssistantRevertStateCacheEntry {
    let messageRevision: Int
    let busyRepoRevision: Int
    let revertStateRevision: Int
    let workingDirectory: String?
    let statesByMessageID: [String: AssistantRevertPresentation]
}

@MainActor
@Observable
final class CodexService {
    static let minimumSupportedBridgePackageVersion = "1.3.9"

    // --- Public state ---------------------------------------------------------

    var threads: [CodexThread] = [] {
        didSet {
            rebuildThreadLookupCaches()
            refreshPinnedThreadSnapshots()
        }
    }
    var isConnected = false
    var isConnecting = false
    var isInitialized = false
    var isLoadingThreads = false
    // Tracks the non-blocking bootstrap that hydrates chats/models after the socket is ready.
    var isBootstrappingConnectionSync = false
    var currentOutput = ""
    var activeThreadId: String?
    var activeTurnId: String?
    var activeTurnIdByThread: [String: String] = [:]

    var runningThreadIDs: Set<String> = []
    // Protects active runs that are real but have not yielded a stable turnId yet.
    var protectedRunningFallbackThreadIDs: Set<String> = []
    var readyThreadIDs: Set<String> = []
    var failedThreadIDs: Set<String> = []
    // Threads that started a real run and haven't completed yet; survives sync-poll clearing.
    @ObservationIgnored var threadsPendingCompletionHaptic: Set<String> = []
    // Keeps the latest terminal outcome per thread so UI can react to real run completion.
    var latestTurnTerminalStateByThread: [String: CodexTurnTerminalState] = [:]
    // Preserves terminal outcome per turn so completed/stopped blocks stay distinguishable.
    var terminalStateByTurnID: [String: CodexTurnTerminalState] = [:]
    // Ordered pending runtime approvals keyed by request id so concurrent prompts do not overwrite each other.
    var pendingApprovals: [CodexApprovalRequest] = []
    var lastRawMessage: String?
    var lastErrorMessage: String?
    var keepMacAwakeWhileBridgeRuns = false
    var runtimeDebugLogEntries: [String] = []
    var connectionRecoveryState: CodexConnectionRecoveryState = .idle
    // Per-thread queued drafts for client-side turn queueing while a run is active.
    var queuedTurnDraftsByThread: [String: [QueuedTurnDraft]] = [:]
    // Per-thread queue pause state (active by default when absent).
    var queuePauseStateByThread: [String: QueuePauseState] = [:]
    // Per-thread unsent composer drafts that survive chat switches and app restarts.
    var composerDraftsByThreadID: [String: TurnComposerLocalDraft] = [:]
    var messagesByThread: [String: [CodexMessage]] = [:]
    // Monotonic per-thread revision so views can react to message mutations without hashing full transcripts.
    var messageRevisionByThread: [String: Int] = [:]
    var syncRealtimeEnabled = true
    var availableModels: [CodexModelOption] = []
    var selectedModelId: String?
    var hasPersistedSelectedModelId = false
    var selectedGitWriterModelId: String?
    var selectedReasoningEffort: String?
    var selectedServiceTier: CodexServiceTier?
    // Per-chat runtime overrides let the composer diverge from app-wide defaults.
    var threadRuntimeOverridesByThreadID: [String: CodexThreadRuntimeOverride] = [:]
    var selectedAccessMode: CodexAccessMode = .onRequest
    // Bridge-owned ChatGPT auth snapshot used by Settings and voice gating.
    var gptAccountSnapshot: CodexGPTAccountSnapshot = codexGPTAccountInitialSnapshot() {
        didSet {
            persistGPTAccountSnapshot(gptAccountSnapshot)
        }
    }
    // Holds the most recent account-specific error without colliding with transport-level failures.
    var gptAccountErrorMessage: String?
    var isLoadingModels = false
    // Coalesces post-connect model refreshes behind thread hydration so composer metadata cannot be skipped.
    @ObservationIgnored var pendingRuntimeOptionRefresh = false
    @ObservationIgnored var runtimeOptionRefreshTask: Task<Void, Never>?
    @ObservationIgnored var runtimeOptionRefreshToken: UUID?
    var modelsErrorMessage: String?
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    var pendingNotificationOpenThreadID: String?
    var supportsStructuredSkillInput = true
    var supportsStructuredMentionInput = true
    // Runtime compatibility flag for `turn/start.collaborationMode` plan turns.
    var supportsTurnCollaborationMode = false
    // Runtime compatibility flag for `thread/start|turn/start.serviceTier` speed controls.
    var supportsServiceTier = true
    // Runtime compatibility flag for the bridge-owned voice transcription flow.
    var supportsBridgeVoiceTranscription = true
    // Runtime compatibility flag for native `thread/fork` conversation branching.
    var supportsThreadFork = true
    // Runtime compatibility flag for `thread/turns/list` and `excludeTurns`.
    var supportsTurnPagination = true
    // Seeds brand-new chats with one-shot composer actions like code review.
    var pendingComposerActionByThreadID: [String: CodexPendingThreadComposerAction] = [:]
    // In-memory identity directory for subagents, keyed by thread id and agent id.
    var subagentIdentityVersion: Int = 0

    // Relay session persistence
    var relaySessionId: String?
    var relayUrl: String?
    var relayMacDeviceId: String?
    var relayMacIdentityPublicKey: String?
    var relayProtocolVersion: Int = codexSecureProtocolVersion
    var lastAppliedBridgeOutboundSeq = 0
    // Mirrors the bridge package version currently running on the Mac, if the bridge reports it.
    var bridgeInstalledVersion: String?
    // Mirrors the latest published bridge package version, when the bridge can resolve it.
    var latestBridgePackageVersion: String?
    // Fresh QR scans must use bootstrap once, even if this Mac was already trusted before.
    var shouldForceQRBootstrapOnNextHandshake = false
    // Stops infinite trusted-reconnect loops by escalating back to QR after repeated handshake failures.
    var trustedReconnectFailureCount = 0
    var secureConnectionState: CodexSecureConnectionState = .notPaired
    var secureMacFingerprint: String?
    // Keeps the bridge-update UX visible even if connection cleanup resets secure transport state.
    var bridgeUpdatePrompt: CodexBridgeUpdatePrompt?
    var hasPresentedServiceTierBridgeUpdatePrompt = false
    var hasPresentedThreadForkBridgeUpdatePrompt = false
    var hasPresentedMinimumBridgePackageUpdatePrompt = false
    // Remembers the latest optional npm update we already surfaced so foreground refreshes stay non-spammy.
    var lastPresentedAvailableBridgePackageVersion: String?
    // Mirrors the sidebar ready-dot with a tappable in-app banner when another chat finishes.
    var threadCompletionBanner: CodexThreadCompletionBanner?
    // Explains why a push-opened chat could not be restored and offers a recovery path.
    var missingNotificationThreadPrompt: CodexMissingNotificationThreadPrompt?
    // Interactive SSH terminal state is owned on-device so it can bootstrap a Mac before the bridge runs.
    var terminalSnapshot: RemodexTerminalSnapshot = .idle
    var terminalSnapshotsById: [String: RemodexTerminalSnapshot] = [:]
    var terminalProfile: RemodexTerminalProfile = RemodexTerminalProfileStore.load()
    @ObservationIgnored let nativeSSHTerminal = RemodexNativeSSHTerminal()
    @ObservationIgnored var nativeSSHTerminalsById: [String: RemodexNativeSSHTerminal] = [:]

    // --- Internal wiring ------------------------------------------------------

    var webSocketConnection: NWConnection?
    var webSocketSession: URLSession?
    var webSocketSessionDelegate: CodexURLSessionWebSocketDelegate?
    var webSocketTask: URLSessionWebSocketTask?
    var webSocketKeepAliveTask: Task<Void, Never>?
    // Raw frame buffer used when the relay runs over manual TCP websocket framing.
    var manualWebSocketReadBuffer = Data()
    var usesManualWebSocketTransport = false
    let webSocketQueue = DispatchQueue(label: "CodexMobile.WebSocket", qos: .userInitiated)
    var pendingRequests: [String: CheckedContinuation<RPCMessage, Error>] = [:]
    // Test hook: intercepts outbound RPC requests without requiring a live socket.
    @ObservationIgnored var requestTransportOverride: ((String, JSONValue?) async throws -> RPCMessage)?
    // Test hook: stubs trusted-session lookup without performing a real relay HTTP request.
    @ObservationIgnored var trustedSessionResolverOverride: (() async throws -> CodexTrustedSessionResolveResponse)?
    // Test hooks: exercise keepalive lifecycle without waiting 25s or opening a real socket.
    @ObservationIgnored var webSocketKeepAliveIntervalOverrideNanoseconds: UInt64?
    @ObservationIgnored var webSocketForegroundProbeTimeoutOverrideNanoseconds: UInt64?
    @ObservationIgnored var webSocketKeepAlivePingOverride: (() async throws -> Void)?
    // Keeps the trusted-session HTTP lookup cancellable so manual retry can preempt a stuck resolve.
    @ObservationIgnored var trustedSessionResolveTask: Task<CodexTrustedSessionResolveResponse, Error>?
    @ObservationIgnored var trustedSessionResolveTaskID: UUID?
    // Assistant streams keep turn fallback separate from item-specific identity to avoid cross-item overlap.
    @ObservationIgnored var streamingAssistantFallbackMessageByTurnID: [String: String] = [:]
    @ObservationIgnored var streamingAssistantMessageByItemKey: [String: String] = [:]
    @ObservationIgnored var streamingSystemMessageByItemID: [String: String] = [:]
    /// Rich metadata for command execution tool calls, keyed by itemId.
    var commandExecutionDetailsByItemID: [String: CommandExecutionDetails] = [:]
    // Debounces disk writes while streaming to keep UI responsive.
    @ObservationIgnored var messagePersistenceDebounceTask: Task<Void, Never>?
    // Coalesces high-frequency assistant deltas before they mutate observed timeline state.
    @ObservationIgnored var pendingAssistantDeltaByStreamID: [String: String] = [:]
    @ObservationIgnored var pendingAssistantDeltaContextByStreamID: [String: (threadId: String, turnId: String, itemId: String?, assistantPhase: String?)] = [:]
    @ObservationIgnored var pendingAssistantDeltaStreamOrder: [String] = []
    @ObservationIgnored var pendingAssistantDeltaFlushTask: Task<Void, Never>?
    let assistantDeltaBatchIntervalNanoseconds: UInt64 = 50_000_000
    // Coalesces multiple invalidateAssistantRevertStates() calls within the same run loop tick into one refresh.
    var coalescedRevertRefreshTask: Task<Void, Never>?
    // Dedupes completion payloads when servers omit turn/item identifiers.
    var assistantCompletionFingerprintByThread: [String: (text: String, timestamp: Date)] = [:]
    // Dedupes concise activity feed lines per thread/turn to avoid visual spam.
    var recentActivityLineByThread: [String: CodexRecentActivityLine] = [:]
    var contextWindowUsageByThread: [String: ContextWindowUsage] = [:]
    var rateLimitBuckets: [CodexRateLimitBucket] = []
    // Distinguishes "not loaded yet" from "loaded successfully, but no visible buckets exist".
    var hasResolvedRateLimitsSnapshot = false
    var isLoadingRateLimits = false
    var rateLimitsErrorMessage: String?
    var threadIdByTurnID: [String: String] = [:]
    var hydratedThreadIDs: Set<String> = []
    var loadingThreadIDs: Set<String> = []
    // Cursor-backed history pages let large chats open from the recent tail first.
    var olderThreadHistoryCursorByThreadID: [String: JSONValue] = [:]
    var exhaustedOlderThreadHistoryCursorByThreadID: [String: JSONValue] = [:]
    var loadingOlderThreadHistoryIDs: Set<String> = []
    var threadTimelineProjectionLimitByThreadID: [String: Int] = [:]
    var initialTurnsLoadedByThreadID: Set<String> = []
    var threadsWithAuthoritativeLocalHistoryStart: Set<String> = []
    var olderHistoryLoadErrorByThreadID: [String: String] = [:]
    @ObservationIgnored var subagentMetadataLoadingThreadIDs: Set<String> = []
    var resumedThreadIDs: Set<String> = []
    // Coalesces per-thread thread/read history fetches so reconcile work can await the same RPC.
    @ObservationIgnored var threadHistoryLoadTaskByThreadID: [String: Task<ThreadHistoryLoadOutcome, Error>] = [:]
    // Lets a late force caller upgrade an in-flight history load without spawning another thread/read.
    @ObservationIgnored var forcedHistoryLoadThreadIDs: Set<String> = []
    // Preserves callers that need "not materialized" reads to keep retrying instead of marking hydrated.
    @ObservationIgnored var deferHydratedMarkForNotMaterializedThreadIDs: Set<String> = []
    // Coalesces per-thread resume work so rapid thread switches reuse the same in-flight refresh.
    @ObservationIgnored var threadResumeTaskByThreadID: [String: Task<CodexThread?, Error>] = [:]
    // Remembers which cwd/model pair an in-flight resume is actually targeting.
    @ObservationIgnored var threadResumeRequestSignatureByThreadID: [String: CodexThreadResumeRequestSignature] = [:]
    // Lets a late force caller upgrade an in-flight resume without spawning another RPC.
    @ObservationIgnored var forcedResumeEscalationThreadIDs: Set<String> = []
    // Coalesces running-state refreshes so foreground recovery cannot stampede the same thread.
    @ObservationIgnored var turnStateRefreshTaskByThreadID: [String: Task<Bool, Never>] = [:]
    // Coalesces the full running-thread catch-up pipeline so open/foreground/reconnect share one path.
    @ObservationIgnored var runningThreadCatchupTaskByThreadID: [String: Task<RunningThreadCatchupOutcome, Never>] = [:]
    // Lets a late foreground/open caller upgrade an in-flight running catch-up into a forced resume.
    @ObservationIgnored var forcedRunningCatchupEscalationThreadIDs: Set<String> = []
    // Invalidates stale async completions after archive/delete/reconnect tears refresh work down.
    @ObservationIgnored var threadRefreshGenerationByThreadID: [String: UInt64] = [:]
    // Throttles expensive forced resumes while the user bounces between running chats.
    @ObservationIgnored var lastForcedRunningResumeAtByThread: [String: Date] = [:]
    // Marks threads that used a lightweight running catch-up and still need one canonical history pass later.
    @ObservationIgnored var threadsNeedingCanonicalHistoryReconcile: Set<String> = []
    // Remembers which large closed chats already completed the one required canonical refresh after local-first paint.
    @ObservationIgnored var threadsWithSatisfiedDeferredHistoryHydration: Set<String> = []
    // Keeps post-run canonical reconcile work coalesced to one task per thread.
    @ObservationIgnored var canonicalHistoryReconcileTaskByThreadID: [String: Task<Void, Never>] = [:]
    // Tracks delayed retry timers for canonical reconcile so teardown can cancel the backoff too.
    @ObservationIgnored var canonicalHistoryReconcileRetryTaskByThreadID: [String: Task<Void, Never>] = [:]
    // Coalesces sidebar/bootstrap thread/list refreshes so launch paths do not duplicate the same fetch.
    @ObservationIgnored var threadListFetchTaskByLimit: [Int: (id: UUID, task: Task<[CodexThread], Error>)] = [:]
    var isAppInForeground = true
    var threadListSyncTask: Task<Void, Never>?
    var activeThreadSyncTask: Task<Void, Never>?
    var runningThreadWatchSyncTask: Task<Void, Never>?
    var postConnectSyncTask: Task<Void, Never>?
    // Keeps the phone-side account UI in sync while ChatGPT login is being completed on the Mac.
    var gptAccountLoginSyncTask: Task<Void, Never>?
    var postConnectSyncToken: UUID?
    var connectedServerIdentity: String?
    // Tracks whether the bridge is proxying a real Codex endpoint or a spawned local app-server.
    var codexTransportMode: CodexRuntimeTransportMode = .unknown
    var bridgeHostPlatform: CodexBridgeHostPlatform {
        if let hostPlatform = gptAccountSnapshot.hostPlatform {
            return hostPlatform
        }
        return preferredTrustedMacRecord == nil ? .unknown : .macOS
    }
    var bridgeHostCapabilities: CodexBridgeHostCapabilities {
        if let hostCapabilities = gptAccountSnapshot.hostCapabilities {
            return hostCapabilities
        }
        // Older bridges did not report capabilities; only apply that compatibility
        // fallback when the remembered host is known to be macOS.
        guard preferredTrustedMacRecord != nil,
              bridgeHostPlatform == .macOS else {
            return CodexBridgeHostCapabilities()
        }
        return .legacyMacOS
    }
    var supportsDesktopAppHandoff: Bool {
        bridgeHostCapabilities.desktopHandoff
    }
    var supportsDisplayWake: Bool {
        bridgeHostCapabilities.displayWake
    }
    var supportsKeepAwakeWhileBridgeRuns: Bool {
        bridgeHostCapabilities.keepAwake
    }
    var supportsBridgePackageUpdate: Bool {
        bridgeHostCapabilities.bridgeUpdate
    }
    var hostComputerLabel: String {
        bridgeHostPlatform.displayName
    }
    // Remembers whether the current plan flow is staying native or has fallen back to inferred UI.
    var planSessionSourceByThread: [String: CodexPlanSessionSource] = [:] {
        didSet {
            persistPlanSessionSources()
        }
    }
    var runningThreadWatchByID: [String: CodexRunningThreadWatch] = [:]
    var mirroredRunningCatchupThreadIDs: Set<String> = []
    var desktopMirroredRunningThreadIDs: Set<String> = []
    var desktopMirroredRunningStaleSnapshotCountsByThread: [String: Int] = [:]
    var desktopMirroredRunningLastActivityAtByThread: [String: Date] = [:]
    var lastMirroredRunningCatchupAtByThread: [String: Date] = [:]
    var localNetworkAuthorizationStatus: LocalNetworkAuthorizationStatus = .unknown
    var backgroundTurnGraceTaskID: UIBackgroundTaskIdentifier = .invalid
    var hasConfiguredNotifications = false
    var runCompletionNotificationDedupedAt: [String: Date] = [:]
    var structuredUserInputNotificationDedupedAt: [String: Date] = [:]
    var notificationCenterDelegateProxy: CodexNotificationCenterDelegateProxy?
    var notificationObserverTokens: [NSObjectProtocol] = []
    var remoteNotificationDeviceToken: String?
    var lastPushRegistrationSignature: String?
    var shouldAutoReconnectOnForeground = false
    // Test hook so connection handling can model `.inactive` without waiting for real app lifecycle changes.
    @ObservationIgnored var applicationStateProvider: () -> UIApplication.State = { UIApplication.shared.applicationState }
    var backgroundTurnGraceExpiredUntilForeground = false
    var secureSession: CodexSecureSession?
    var pendingHandshake: CodexPendingHandshake?
    var phoneIdentityState: CodexPhoneIdentityState
    var trustedMacRegistry: CodexTrustedMacRegistry
    var currentTrustedMacDeviceId: String?
    var lastTrustedMacDeviceId: String?
    var previousTrustedMacDeviceId: String?
    @ObservationIgnored var macScopedContextOverrideDeviceId: String?
    @ObservationIgnored var suspendAutomaticMacScopedPersistence = false
    @ObservationIgnored var isApplyingMacScopedState = false
    var pendingSecureControlContinuations: [String: [CodexSecureControlWaiter]] = [:]
    var bufferedSecureControlMessages: [String: [String]] = [:]
    // Assistant-scoped patch ledger used by the revert-changes flow.
    var aiChangeSetsByID: [String: AIChangeSet] = [:]
    var aiChangeSetIDByTurnID: [String: String] = [:]
    var aiChangeSetIDByAssistantMessageID: [String: String] = [:]
    @ObservationIgnored var workspaceCheckpointCopyTaskByTurnID: [String: Task<Void, Never>] = [:]
    // Keeps hot-path thread lookups O(1) instead of rescanning the full sidebar list.
    @ObservationIgnored var threadByID: [String: CodexThread] = [:]
    @ObservationIgnored var threadIndexByID: [String: Int] = [:]
    @ObservationIgnored var firstLiveThreadIDCache: String?
    @ObservationIgnored var subagentIdentityByThreadID: [String: CodexSubagentIdentityEntry] = [:]
    @ObservationIgnored var subagentIdentityByAgentID: [String: CodexSubagentIdentityEntry] = [:]
    // Canonical repo roots keyed by observed working directories from bridge git/status responses.
    var repoRootByWorkingDirectory: [String: String] = [:]
    var knownRepoRoots: Set<String> = []
    // Phase callbacks for in-flight `git/runStackedAction` calls keyed by progressId.
    @ObservationIgnored var gitStackedActionProgressHandlers: [String: (TurnGitActionPhase, TurnGitActionPhaseStatus) -> Void] = [:]
    // Service-owned per-thread UI state keeps the active chat isolated from unrelated thread mutations.
    @ObservationIgnored var threadTimelineStateByThread: [String: ThreadTimelineState] = [:]
    @ObservationIgnored var forkedFromThreadIDByThreadID: [String: String] = [:]
    @ObservationIgnored var renamedThreadNameByThreadID: [String: String] = [:]
    @ObservationIgnored var associatedManagedWorktreePathByThreadID: [String: String] = [:]
    @ObservationIgnored var authoritativeProjectPathByThreadID: [String: String] = [:]
    var pinnedThreadIDs: [String] = []
    @ObservationIgnored var pinnedThreadSnapshotsByRootID: [String: [CodexThread]] = [:]
    @ObservationIgnored var snapshotOnlyPinnedThreadIDs: Set<String> = []
    @ObservationIgnored var stoppedTurnIDsByThread: [String: Set<String>] = [:]
    // Lazily rebuilt id->index maps keep hot-path message lookups out of repeated linear scans.
    @ObservationIgnored var messageIndexCacheByThread: [String: [String: Int]] = [:]
    @ObservationIgnored var latestAssistantOutputByThread: [String: String] = [:]
    @ObservationIgnored var latestAssistantMessageIDByThread: [String: String] = [:]
    @ObservationIgnored var latestRepoAffectingMessageSignalByThread: [String: String] = [:]
    @ObservationIgnored var assistantRevertStateCacheByThread: [String: AssistantRevertStateCacheEntry] = [:]
    @ObservationIgnored var assistantRevertStateRevision: Int = 0
    @ObservationIgnored var busyRepoRoots: Set<String> = []
    @ObservationIgnored var busyRepoRootsRevision: Int = 0
    @ObservationIgnored var pendingSystemDeltasByKey: [String: PendingSystemStreamingDeltas] = [:]
    @ObservationIgnored var systemDeltaFlushTasksByKey: [String: Task<Void, Never>] = [:]

    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let messagePersistence = CodexMessagePersistence()
    let composerDraftPersistence = CodexComposerDraftPersistence()
    let aiChangeSetPersistence = AIChangeSetPersistence()
    let defaults: UserDefaults
    let userNotificationCenter: CodexUserNotificationCentering
    var remoteNotificationRegistrar: CodexRemoteNotificationRegistering?

    static let selectedModelIdDefaultsKey = "codex.selectedModelId"
    static let selectedGitWriterModelIdDefaultsKey = "codex.selectedGitWriterModelId"
    static let selectedReasoningEffortDefaultsKey = "codex.selectedReasoningEffort"
    static let selectedServiceTierDefaultsKey = "codex.selectedServiceTier"
    static let threadRuntimeOverridesDefaultsKey = "codex.threadRuntimeOverrides"
    static let planSessionSourcesDefaultsKey = "codex.planSessionSources"
    static let selectedAccessModeDefaultsKey = "codex.selectedAccessMode"
    static let locallyArchivedThreadIDsKey = "codex.locallyArchivedThreadIDs"
    static let locallyDeletedThreadIDsKey = "codex.locallyDeletedThreadIDs"
    static let forkedThreadOriginsDefaultsKey = "codex.forkedThreadOrigins"
    static let renamedThreadNamesDefaultsKey = "codex.renamedThreadNames"
    static let pinnedThreadIDsDefaultsKey = "codex.pinnedThreadIDs"
    static let pinnedThreadSnapshotsDefaultsKey = "codex.pinnedThreadSnapshots"
    static let associatedManagedWorktreePathsDefaultsKey = "codex.associatedManagedWorktreePaths"
    static let turnTerminalStatesDefaultsKey = "codex.turnTerminalStates"
    static let threadHistoryPaginationStateDefaultsKey = "codex.threadHistoryPaginationState"
    static let notificationsPromptedDefaultsKey = "codex.notifications.prompted"
    static let keepMacAwakeWhileBridgeRunsDefaultsKey = "codex.keepMacAwakeWhileBridgeRuns"

    init(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        defaults: UserDefaults = .standard,
        userNotificationCenter: CodexUserNotificationCentering? = nil,
        remoteNotificationRegistrar: CodexRemoteNotificationRegistering? = nil
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.defaults = defaults
        self.userNotificationCenter = userNotificationCenter ?? UNUserNotificationCenter.current()
        self.remoteNotificationRegistrar = remoteNotificationRegistrar ?? CodexApplicationRemoteNotificationRegistrar()
        self.phoneIdentityState = codexPhoneIdentityStateFromSecureStore()
        self.trustedMacRegistry = codexTrustedMacRegistryFromSecureStore()
        self.currentTrustedMacDeviceId = SecureStore.readString(for: CodexSecureKeys.currentTrustedMacDeviceId)
        self.lastTrustedMacDeviceId = SecureStore.readString(for: CodexSecureKeys.lastTrustedMacDeviceId)
        self.messagesByThread = [:]
        self.composerDraftsByThreadID = [:]
        rebuildSubagentIdentityDirectory()
        self.aiChangeSetsByID = [:]
        self.aiChangeSetIDByTurnID = [:]
        self.aiChangeSetIDByAssistantMessageID = [:]

        let savedModelId = defaults.string(forKey: Self.selectedModelIdDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSavedModelId = savedModelId?.isEmpty == false
        self.hasPersistedSelectedModelId = hasSavedModelId
        self.selectedModelId = hasSavedModelId ? savedModelId : nil

        let savedGitWriterModelId = defaults.string(forKey: Self.selectedGitWriterModelIdDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedGitWriterModelId = (savedGitWriterModelId?.isEmpty == false) ? savedGitWriterModelId : nil

        let savedReasoning = defaults.string(forKey: Self.selectedReasoningEffortDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedReasoningEffort = (hasSavedModelId && savedReasoning?.isEmpty == false)
            ? savedReasoning
            : nil

        if defaults.object(forKey: Self.keepMacAwakeWhileBridgeRunsDefaultsKey) != nil {
            self.keepMacAwakeWhileBridgeRuns = defaults.bool(forKey: Self.keepMacAwakeWhileBridgeRunsDefaultsKey)
        } else {
            self.keepMacAwakeWhileBridgeRuns = false
        }
        self.threadRuntimeOverridesByThreadID = [:]

        self.planSessionSourceByThread = [:]

        self.forkedFromThreadIDByThreadID = [:]

        self.renamedThreadNameByThreadID = [:]

        self.associatedManagedWorktreePathByThreadID = [:]
        self.pinnedThreadIDs = []
        self.pinnedThreadSnapshotsByRootID = [:]

        self.terminalStateByTurnID = [:]

        let savedServiceTier = defaults.string(forKey: Self.selectedServiceTierDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if savedServiceTier == "flex" {
            self.selectedServiceTier = nil
        } else if let savedServiceTier,
           let parsedServiceTier = CodexServiceTier(rawValue: savedServiceTier) {
            self.selectedServiceTier = parsedServiceTier
        } else {
            self.selectedServiceTier = nil
        }

        if let savedAccessMode = defaults.string(forKey: Self.selectedAccessModeDefaultsKey),
           let parsedAccessMode = CodexAccessMode(rawValue: savedAccessMode) {
            self.selectedAccessMode = parsedAccessMode
        } else {
            self.selectedAccessMode = .onRequest
        }

        self.gptAccountSnapshot = codexGPTAccountInitialSnapshot()

        // Restore relay session from Keychain
        self.relaySessionId = SecureStore.readString(for: CodexSecureKeys.relaySessionId)
        self.relayUrl = SecureStore.readString(for: CodexSecureKeys.relayUrl)
        self.relayMacDeviceId = SecureStore.readString(for: CodexSecureKeys.relayMacDeviceId)
        self.relayMacIdentityPublicKey = SecureStore.readString(for: CodexSecureKeys.relayMacIdentityPublicKey)
        if let rawProtocolVersion = SecureStore.readString(for: CodexSecureKeys.relayProtocolVersion),
           let parsedProtocolVersion = Int(rawProtocolVersion) {
            self.relayProtocolVersion = parsedProtocolVersion
        } else {
            self.relayProtocolVersion = codexSecureProtocolVersion
        }
        if let rawLastAppliedSeq = SecureStore.readString(for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq),
           let parsedLastAppliedSeq = Int(rawLastAppliedSeq) {
            self.lastAppliedBridgeOutboundSeq = parsedLastAppliedSeq
        }
        migrateCurrentTrustedMacDeviceIdIfNeeded()
        migrateLegacyMacScopedDefaultsIfNeeded()
        loadCurrentMacScopedDefaultsState()
        loadCurrentMacScopedLocalState()
        self.remoteNotificationDeviceToken = SecureStore.readString(for: CodexSecureKeys.pushDeviceToken)
        if let relayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[relayMacDeviceId] {
            self.secureConnectionState = .trustedMac
            self.secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        } else if let trustedMac = currentTrustedMacRecord {
            self.secureConnectionState = .liveSessionUnresolved
            self.secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        }
        rebuildThreadLookupCaches()
    }

    // Persists per-thread plan-mode provenance so reconnect/relaunch keeps native vs fallback behavior stable.
    private func persistPlanSessionSources() {
        guard !suspendAutomaticMacScopedPersistence, !isApplyingMacScopedState else {
            return
        }

        guard !planSessionSourceByThread.isEmpty else {
            defaults.removeObject(forKey: macScopedDefaultsKey(Self.planSessionSourcesDefaultsKey))
            return
        }

        guard let data = try? encoder.encode(planSessionSourceByThread) else {
            defaults.removeObject(forKey: macScopedDefaultsKey(Self.planSessionSourcesDefaultsKey))
            return
        }

        defaults.set(data, forKey: macScopedDefaultsKey(Self.planSessionSourcesDefaultsKey))
    }

    // Remembers whether we can offer reconnect without forcing a fresh QR scan.
    var hasSavedRelaySession: Bool {
        guard normalizedRelaySessionId != nil,
              normalizedRelayURL != nil else {
            return false
        }

        guard let normalizedCurrentTrustedMacDeviceId else {
            return true
        }

        return normalizedRelayMacDeviceId == normalizedCurrentTrustedMacDeviceId
    }

    // Normalizes the persisted relay session id before reuse in reconnect flows.
    var normalizedRelaySessionId: String? {
        relaySessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
    }

    // Normalizes the persisted relay base URL before reuse in reconnect flows.
    var normalizedRelayURL: String? {
        relayUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
    }

    var normalizedRelayMacDeviceId: String? {
        relayMacDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
    }

    var normalizedRelayMacIdentityPublicKey: String? {
        relayMacIdentityPublicKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
    }

    var normalizedLastTrustedMacDeviceId: String? {
        lastTrustedMacDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
    }

    var normalizedCurrentTrustedMacDeviceId: String? {
        currentTrustedMacDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
    }

    var preferredTrustedMacDeviceId: String? {
        normalizedCurrentTrustedMacDeviceId
    }

    var preferredTrustedMacRecord: CodexTrustedMacRecord? {
        guard let preferredTrustedMacDeviceId else {
            return nil
        }
        return trustedMacRegistry.records[preferredTrustedMacDeviceId]
    }

    var currentTrustedMacRecord: CodexTrustedMacRecord? {
        guard let normalizedCurrentTrustedMacDeviceId else {
            return nil
        }

        return trustedMacRegistry.records[normalizedCurrentTrustedMacDeviceId]
    }

    var normalizedPreviousTrustedMacDeviceId: String? {
        previousTrustedMacDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
    }

    func trustedMacRecord(for deviceId: String?) -> CodexTrustedMacRecord? {
        guard let normalizedDeviceId = deviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty else {
            return nil
        }

        return trustedMacRegistry.records[normalizedDeviceId]
    }

    var hasTrustedMacReconnectCandidate: Bool {
        currentTrustedMacRecord?.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasReconnectCandidate: Bool {
        hasSavedRelaySession || hasTrustedMacReconnectCandidate
    }

    // Chooses the best relay base URL for a one-shot display wake before reconnecting.
    var preferredWakeRelayURL: String? {
        guard !isConnected else {
            return nil
        }

        if hasTrustedReconnectContext {
            return normalizedRelayURL
        }

        return currentTrustedMacRecord?.relayURL?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
    }

    // Wake can use either a saved live session or a freshly resolved trusted session.
    var canWakePreferredMacDisplay: Bool {
        guard !isConnected else {
            return false
        }

        return preferredWakeRelayURL != nil
    }

    // Separates transport readiness from post-connect hydration so the UI can explain delays honestly.
    var connectionPhase: CodexConnectionPhase {
        if isConnecting {
            return .connecting
        }

        guard isConnected else {
            return .offline
        }

        if threads.isEmpty && (isBootstrappingConnectionSync || isLoadingThreads) {
            return .loadingChats
        }

        if isBootstrappingConnectionSync || isLoadingThreads {
            return .syncing
        }

        return .connected
    }

    var connectionPhaseDisplayLabel: String {
        switch connectionPhase {
        case .offline:
            return "Offline"
        case .connecting:
            return "Connecting"
        case .loadingChats:
            return "Loading chats"
        case .syncing:
            return "Syncing"
        case .connected:
            return "Connected"
        }
    }

    var secureConnectionDisplayLabel: String? {
        let label = secureConnectionState.statusLabel
        return label.isEmpty || secureConnectionState == .notPaired ? nil : label
    }

    func setCurrentTrustedMacDeviceId(_ deviceId: String?) {
        let normalizedDeviceId = deviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
        currentTrustedMacDeviceId = normalizedDeviceId
        if let normalizedDeviceId {
            SecureStore.writeString(normalizedDeviceId, for: CodexSecureKeys.currentTrustedMacDeviceId)
        } else {
            SecureStore.deleteValue(for: CodexSecureKeys.currentTrustedMacDeviceId)
        }
    }

    func setPreviousTrustedMacDeviceId(_ deviceId: String?) {
        previousTrustedMacDeviceId = deviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .codexNilIfEmpty
    }

    func clearPreviousTrustedMacDeviceId() {
        previousTrustedMacDeviceId = nil
    }

    func migrateCurrentTrustedMacDeviceIdIfNeeded() {
        if let normalizedCurrentTrustedMacDeviceId,
           trustedMacRegistry.records[normalizedCurrentTrustedMacDeviceId] != nil {
            return
        }

        let bootstrapDeviceId = [
            normalizedRelayMacDeviceId,
            normalizedLastTrustedMacDeviceId,
        ]
        .compactMap { $0 }
        .first { trustedMacRegistry.records[$0] != nil }

        setCurrentTrustedMacDeviceId(bootstrapDeviceId)
    }

    deinit {
        MainActor.assumeIsolated {
            trustedSessionResolveTask?.cancel()
            messagePersistenceDebounceTask?.cancel()
            coalescedRevertRefreshTask?.cancel()
            threadListSyncTask?.cancel()
            activeThreadSyncTask?.cancel()
            runningThreadWatchSyncTask?.cancel()
            postConnectSyncTask?.cancel()
            gptAccountLoginSyncTask?.cancel()

            notificationObserverTokens.forEach { NotificationCenter.default.removeObserver($0) }
            notificationObserverTokens.removeAll()
            notificationCenterDelegateProxy = nil
        }
    }
}

private extension String {
    var codexNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
