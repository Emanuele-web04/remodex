// FILE: CodexService.swift
// Purpose: Central state container for Codex app-server communication.
// Layer: Service
// Exports: CodexService, CodexApprovalRequest
// Depends on: Foundation, Observation, RPCMessage, CodexThread, CodexMessage, UserNotifications

import CryptoKit
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

typealias CodexThreadTurnStateSnapshot = (
    interruptibleTurnID: String?,
    hasInterruptibleTurnWithoutID: Bool,
    latestTurnID: String?
)

typealias CodexThreadResumeResult = (
    thread: CodexThread?,
    snapshot: CodexThreadTurnStateSnapshot?
)

struct CodexThreadResumeTaskRecord {
    let token: UUID
    let task: Task<CodexThreadResumeResult, Error>
}

struct CodexThreadTurnStateSnapshotTaskRecord {
    let token: UUID
    let task: Task<CodexThreadTurnStateSnapshot?, Never>
}

struct CodexThreadListPersistenceTaskRecord {
    let token: UUID
    let task: Task<Void, Never>
}

struct CodexConvexLaneCredentials: Sendable {
    let macDeviceId: String
    let macIdentityPublicKey: String
    let sharedSecretBase64: String

    var sharedSecretData: Data? {
        let data = Data(base64EncodedOrEmpty: sharedSecretBase64)
        return data.isEmpty ? nil : data
    }
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
    let command: String
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
enum CodexTurnTerminalState: String, Equatable, Sendable {
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
    let timelineChangeToken: Int
    let activeTurnID: String?
    let isThreadRunning: Bool
    let latestTurnTerminalState: CodexTurnTerminalState?
    let stoppedTurnIDs: Set<String>
    let assistantRevertStatesByMessageID: [String: AssistantRevertPresentation]
    let repoRefreshSignal: String?

    static func empty(threadID: String) -> TurnTimelineRenderSnapshot {
        TurnTimelineRenderSnapshot(
            threadID: threadID,
            messages: [],
            timelineChangeToken: 0,
            activeTurnID: nil,
            isThreadRunning: false,
            latestTurnTerminalState: nil,
            stoppedTurnIDs: [],
            assistantRevertStatesByMessageID: [:],
            repoRefreshSignal: nil
        )
    }
}

struct ThreadTimelineState {
    let threadID: String
    var messages: [CodexMessage]
    var messageRevision: Int
    var busyRepoRevision: Int
    var revertStateRevision: Int
    var activeTurnID: String?
    var isThreadRunning: Bool
    var latestTurnTerminalState: CodexTurnTerminalState?
    var stoppedTurnIDs: Set<String>
    var repoRefreshSignal: String?
    var renderSnapshot: TurnTimelineRenderSnapshot

    init(threadID: String) {
        self.threadID = threadID
        self.messages = []
        self.messageRevision = 0
        self.busyRepoRevision = 0
        self.revertStateRevision = 0
        self.activeTurnID = nil
        self.isThreadRunning = false
        self.latestTurnTerminalState = nil
        self.stoppedTurnIDs = []
        self.repoRefreshSignal = nil
        self.renderSnapshot = TurnTimelineRenderSnapshot.empty(threadID: threadID)
    }
}

struct AssistantRevertStateCacheEntry {
    let messageRevision: Int
    let busyRepoRevision: Int
    let revertStateRevision: Int
    let statesByMessageID: [String: AssistantRevertPresentation]
}

@MainActor
@Observable
final class CodexService {
    static let minimumSupportedBridgePackageVersion = "1.3.5"

    private static let uiTestTimelineFixtureIdentity: CodexPhoneIdentityState = {
        let privateKey = Curve25519.Signing.PrivateKey()
        return CodexPhoneIdentityState(
            phoneDeviceId: "com.codexmobile.uitest.timeline",
            phoneIdentityPrivateKey: privateKey.rawRepresentation.base64EncodedString(),
            phoneIdentityPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
    }()

    // --- Public state ---------------------------------------------------------

    var threads: [CodexThread] = [] {
        didSet {
            rebuildThreadLookupCaches()
            persistThreadListSnapshot()
        }
    }
    var transportMode: CodexTransportMode = .disconnected
    var isConnected = false
    var isConnecting = false
    var isInitialized = false
    var isLoadingThreads = false
    // Hides sidebar timing labels after restoring a persisted thread snapshot until live data arrives.
    var isRestoredThreadListSnapshotAwaitingLiveSync = false
    // Tracks the non-blocking bootstrap that hydrates chats/models after the socket is ready.
    var isBootstrappingConnectionSync = false
    var currentOutput = ""
    var activeThreadId: String? {
        didSet {
            if oldValue != activeThreadId {
                persistThreadListSnapshot()
            }
        }
    }
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
    var pendingApproval: CodexApprovalRequest?
    var lastRawMessage: String?
    var lastErrorMessage: String?
    var connectionRecoveryState: CodexConnectionRecoveryState = .idle

    var hasAttemptedInitialAutoConnect = false
    let autoReconnectBackoffNanoseconds: [UInt64] = [1_000_000_000, 3_000_000_000]
    let reconnectSleepChunkNanoseconds: UInt64 = 100_000_000
    var isRunningAutoReconnect = false
    var isRunningManualReconnect = false
    var shouldCancelManualReconnect = false
    
    // Test hooks keep reconnect verification fast without changing production retry behavior.
    @ObservationIgnored var reconnectAttemptLimitOverride: Int?
    @ObservationIgnored var connectOverride: ((CodexService, String) async throws -> Void)?
    @ObservationIgnored var reconnectSleepOverride: ((UInt64) async -> Void)?
    @ObservationIgnored var reconnectSleepChunkNanosecondsOverride: UInt64?

    // Per-thread queued drafts for client-side turn queueing while a run is active.
    var queuedTurnDraftsByThread: [String: [QueuedTurnDraft]] = [:]
    // Per-thread queue pause state (active by default when absent).
    var queuePauseStateByThread: [String: QueuePauseState] = [:]
    var messagesByThread: [String: [CodexMessage]] = [:]
    // Monotonic per-thread revision so views can react to message mutations without hashing full transcripts.
    var messageRevisionByThread: [String: Int] = [:]
    var syncRealtimeEnabled = true
    var transportPreference: CodexTransportPreference = .automatic {
        didSet {
            defaults.set(transportPreference.rawValue, forKey: Self.transportPreferenceDefaultsKey)
        }
    }
    var availableModels: [CodexModelOption] = []
    var selectedModelId: String?
    var selectedReasoningEffort: String?
    var selectedServiceTier: CodexServiceTier?
    var hasExplicitModelSelection = false
    var hasExplicitReasoningEffortSelection = false
    var availableConfigProfiles: [CodexConfigProfileOption] = []
    var isLoadingConfigProfiles = false
    var configProfilesErrorMessage: String?
    var selectedConfigProfileName: String?
    static let selectedConfigProfileDefaultsKey = "codex.selectedConfigProfile"
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
    var modelsErrorMessage: String?
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    var pendingNotificationOpenThreadID: String?
    var supportsStructuredSkillInput = true
    // Runtime compatibility flag for `turn/start.collaborationMode` plan turns.
    var supportsTurnCollaborationMode = false
    // Runtime compatibility flag for `thread/start|turn/start.serviceTier` speed controls.
    var supportsServiceTier = true
    // Runtime compatibility flag for the bridge-owned `voice/resolveAuth` voice flow.
    var supportsBridgeVoiceAuth = true
    // Runtime compatibility flag for native `thread/fork` conversation branching.
    var supportsThreadFork = true
    // Remembers the runtime's accepted sandbox param shape so hot-path requests avoid repeated retries.
    var preferredSandboxRequestShape: CodexSandboxRequestShape = .sandboxPolicy
    // Remembers the accepted approvalPolicy spelling per access mode across request families.
    var preferredApprovalPolicyByAccessMode: [CodexAccessMode: String] = [:]
    // Seeds brand-new chats with one-shot composer actions like code review.
    var pendingComposerActionByThreadID: [String: CodexPendingThreadComposerAction] = [:]
    // In-memory identity directory for subagents, keyed by thread id and agent id.
    var subagentIdentityVersion: Int = 0

    // Relay session persistence
    var relaySessionId: String?
    var relayUrl: String?
    var relayMacDeviceId: String? {
        didSet {
            if normalizedIdentifier(oldValue) != normalizedIdentifier(relayMacDeviceId) {
                resetSkillsCacheForConnectionContextChange()
            }
        }
    }
    var relayMacIdentityPublicKey: String?
    var relayCloudAsyncSharedSecret: String?
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

    // --- Internal wiring ------------------------------------------------------

    var webSocketConnection: NWConnection?
    var webSocketSession: URLSession?
    var webSocketSessionDelegate: CodexURLSessionWebSocketDelegate?
    var webSocketTask: URLSessionWebSocketTask?
    // Raw frame buffer used when the relay runs over manual TCP websocket framing.
    var manualWebSocketReadBuffer = Data()
    var usesManualWebSocketTransport = false
    let webSocketQueue = DispatchQueue(label: "CodexMobile.WebSocket", qos: .userInitiated)
    var pendingRequests: [String: CheckedContinuation<RPCMessage, Error>] = [:]
    // Test hook: intercepts connect attempts without opening a real websocket.
    @ObservationIgnored var connectAttemptOverride: ((String, String, String?, Bool) async throws -> Void)?
    // Test hook: intercepts outbound RPC requests without requiring a live socket.
    @ObservationIgnored var requestTransportOverride: ((String, JSONValue?) async throws -> RPCMessage)?
    // Selected off-LAN fallback transport. This may be CloudKit or Convex depending on config.
    @ObservationIgnored var convexTransport: CodexAsyncRequestTransporting?
    // Test hook: intercepts Convex lane activation without dialing the real helper/backend.
    @ObservationIgnored var convexLaneActivationOverride: ((String, Bool) async throws -> Void)?
    // Test hook: forces lane selection decisions without depending on device network settings.
    @ObservationIgnored var preferredTransportModeOverride: ((String) -> CodexTransportMode?)?
    // Test hook: stubs trusted-session lookup without performing a real relay HTTP request.
    @ObservationIgnored var trustedSessionResolverOverride: (() async throws -> CodexTrustedSessionResolveResponse)?
    // Keeps the trusted-session HTTP lookup cancellable so manual retry can preempt a stuck resolve.
    @ObservationIgnored var trustedSessionResolveTask: Task<CodexTrustedSessionResolveResponse, Error>?
    @ObservationIgnored var trustedSessionResolveTaskID: UUID?
    // Coalesces rapid transport picker changes so only the latest preference is applied.
    @ObservationIgnored var transportPreferenceReconcileTask: Task<Void, Never>?
    var streamingAssistantMessageByTurnID: [String: String] = [:]
    var streamingSystemMessageByItemID: [String: String] = [:]
    /// Rich metadata for command execution tool calls, keyed by itemId.
    var commandExecutionDetailsByItemID: [String: CommandExecutionDetails] = [:]
    // Debounces disk writes while streaming to keep UI responsive.
    var messagePersistenceDebounceTask: Task<Void, Never>?
    var threadListPersistenceDebounceTask: CodexThreadListPersistenceTaskRecord?
    var pendingImmediateSyncTask: Task<Void, Never>?
    var pendingImmediateSyncThreadID: String?
    var pendingImmediateSyncNeedsThreadList = false
    // Coalesces multiple invalidateAssistantRevertStates() calls within the same run loop tick into one refresh.
    var coalescedRevertRefreshTask: Task<Void, Never>?
    // Dedupes completion payloads when servers omit turn/item identifiers.
    var assistantCompletionFingerprintByThread: [String: (text: String, timestamp: Date)] = [:]
    // Dedupes concise activity feed lines per thread/turn to avoid visual spam.
    var recentActivityLineByThread: [String: CodexRecentActivityLine] = [:]
    @ObservationIgnored var cachedSkillsByRoot: [String: [CodexSkillMetadata]] = [:]
    @ObservationIgnored var skillAutocompleteIndexByRoot: [String: [CodexSkillAutocompleteIndexEntry]] = [:]
    @ObservationIgnored var skillListLoadTaskByRoot: [String: CodexSkillListLoadTaskRecord] = [:]
    @ObservationIgnored var unsupportedSkillRoots: Set<String> = []
    @ObservationIgnored var persistedThreadListSnapshot: CodexThreadListSnapshot?
    @ObservationIgnored var isRestoringPersistedThreadListSnapshot = false
    @ObservationIgnored var persistedSkillsCacheSnapshot = CodexSkillsCacheSnapshot(entriesByRoot: [:])
    var contextWindowUsageByThread: [String: ContextWindowUsage] = [:]
    var rateLimitBuckets: [CodexRateLimitBucket] = []
    // Distinguishes "not loaded yet" from "loaded successfully, but no visible buckets exist".
    var hasResolvedRateLimitsSnapshot = false
    var isLoadingRateLimits = false
    var rateLimitsErrorMessage: String?
    var threadIdByTurnID: [String: String] = [:]
    var hydratedThreadIDs: Set<String> = []
    var loadingThreadIDs: Set<String> = []
    @ObservationIgnored var subagentMetadataLoadingThreadIDs: Set<String> = []
    @ObservationIgnored var inFlightThreadResumeTaskByThread: [String: CodexThreadResumeTaskRecord] = [:]
    @ObservationIgnored var inFlightTurnStateSnapshotTaskByThread: [String: CodexThreadTurnStateSnapshotTaskRecord] = [:]
    var resumedThreadIDs: Set<String> = []
    var isAppInForeground = true
    var lastArchivedThreadsSyncAt: Date?
    var threadListSyncTask: Task<Void, Never>?
    var activeThreadSyncTask: Task<Void, Never>?
    var runningThreadWatchSyncTask: Task<Void, Never>?
    var postConnectSyncTask: Task<Void, Never>?
    var deferredModelListTask: Task<Void, Never>?
    // Keeps the phone-side account UI in sync while ChatGPT login is being completed on the Mac.
    var gptAccountLoginSyncTask: Task<Void, Never>?
    var postConnectSyncToken: UUID?
    var connectedServerIdentity: String? {
        didSet {
            if normalizedIdentifier(oldValue) != normalizedIdentifier(connectedServerIdentity) {
                resetSkillsCacheForConnectionContextChange()
                restorePersistedThreadListSnapshotIfNeeded()
            }
        }
    }
    var runningThreadWatchByID: [String: CodexRunningThreadWatch] = [:]
    var mirroredRunningCatchupThreadIDs: Set<String> = []
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
    var secureSession: CodexSecureSession?
    var pendingHandshake: CodexPendingHandshake?
    var phoneIdentityState: CodexPhoneIdentityState
    var trustedMacRegistry: CodexTrustedMacRegistry
    var lastTrustedMacDeviceId: String?
    var pendingSecureControlContinuations: [String: [CodexSecureControlWaiter]] = [:]
    var bufferedSecureControlMessages: [String: [String]] = [:]
    // Assistant-scoped patch ledger used by the revert-changes flow.
    var aiChangeSetsByID: [String: AIChangeSet] = [:]
    var aiChangeSetIDByTurnID: [String: String] = [:]
    var aiChangeSetIDByAssistantMessageID: [String: String] = [:]
    // Keeps hot-path thread lookups O(1) instead of rescanning the full sidebar list.
    @ObservationIgnored var threadByID: [String: CodexThread] = [:]
    @ObservationIgnored var threadIndexByID: [String: Int] = [:]
    @ObservationIgnored var firstLiveThreadIDCache: String?
    @ObservationIgnored var subagentIdentityByThreadID: [String: CodexSubagentIdentityEntry] = [:]
    @ObservationIgnored var subagentIdentityByAgentID: [String: CodexSubagentIdentityEntry] = [:]
    @ObservationIgnored var localRelayPathMonitor: NWPathMonitor?
    @ObservationIgnored let localRelayPathMonitorQueue = DispatchQueue(
        label: "CodexMobile.LocalRelayPathMonitor",
        qos: .utility
    )
    @ObservationIgnored var localRelayPathAvailabilityOverride: (() -> Bool?)?
    @ObservationIgnored var hasResolvedLocalRelayPathAvailability = false
    var hasActiveLocalRelayPath = false
    // Canonical repo roots keyed by observed working directories from bridge git/status responses.
    var repoRootByWorkingDirectory: [String: String] = [:]
    var knownRepoRoots: Set<String> = []
    // Service-owned per-thread UI state keeps the active chat isolated from unrelated thread mutations.
    var threadTimelineStateByThread: [String: ThreadTimelineState] = [:]
    @ObservationIgnored var forkedFromThreadIDByThreadID: [String: String] = [:]
    @ObservationIgnored var renamedThreadNameByThreadID: [String: String] = [:]
    @ObservationIgnored var stoppedTurnIDsByThread: [String: Set<String>] = [:]
    // Lazily rebuilt id->index maps keep hot-path message lookups out of repeated linear scans.
    @ObservationIgnored var messageIndexCacheByThread: [String: [String: Int]] = [:]
    @ObservationIgnored var latestAssistantOutputByThread: [String: String] = [:]
    @ObservationIgnored var latestRepoAffectingMessageSignalByThread: [String: String] = [:]
    @ObservationIgnored var assistantRevertStateCacheByThread: [String: AssistantRevertStateCacheEntry] = [:]
    @ObservationIgnored var assistantRevertStateRevision: Int = 0
    @ObservationIgnored var busyRepoRoots: Set<String> = []
    @ObservationIgnored var busyRepoRootsRevision: Int = 0

    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let messagePersistence: CodexMessagePersistence
    let aiChangeSetPersistence: AIChangeSetPersistence
    let threadListPersistence: CodexThreadListPersistence
    let skillsPersistence: CodexSkillsPersistence
    let defaults: UserDefaults
    let userNotificationCenter: CodexUserNotificationCentering
    let remoteNotificationRegistrar: CodexRemoteNotificationRegistering

    static let selectedModelIdDefaultsKey = "codex.selectedModelId"
    static let selectedReasoningEffortDefaultsKey = "codex.selectedReasoningEffort"
    static let selectedServiceTierDefaultsKey = "codex.selectedServiceTier"
    static let threadRuntimeOverridesDefaultsKey = "codex.threadRuntimeOverrides"
    static let selectedAccessModeDefaultsKey = "codex.selectedAccessMode"
    static let locallyArchivedThreadIDsKey = "codex.locallyArchivedThreadIDs"
    static let forkedThreadOriginsDefaultsKey = "codex.forkedThreadOrigins"
    static let renamedThreadNamesDefaultsKey = "codex.renamedThreadNames"
    static let notificationsPromptedDefaultsKey = "codex.notifications.prompted"
    static let persistenceNamespaceDefaultsKey = "codex.persistenceNamespace"
    static let transportPreferenceDefaultsKey = "codex.transportPreference"

    func setTransportPreference(_ preference: CodexTransportPreference) {
        guard transportPreference != preference else {
            return
        }

        transportPreference = preference
        scheduleTransportPreferenceReconcile()
    }

    static func persistenceNamespace(for defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: persistenceNamespaceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: persistenceNamespaceDefaultsKey)
        return generated
    }

    init(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        defaults injectedDefaults: UserDefaults = .standard,
        userNotificationCenter: CodexUserNotificationCentering = UNUserNotificationCenter.current(),
        remoteNotificationRegistrar: CodexRemoteNotificationRegistering = CodexApplicationRemoteNotificationRegistrar.shared,
        persistenceNamespaceOverride: String? = nil,
        /// Unit tests that construct many short-lived services should disable this to avoid NWPathMonitor churn.
        startsLocalRelayPathMonitor: Bool = true
    ) {
        let uiTestFixture = ProcessInfo.processInfo.arguments.contains("-CodexUITestsFixture")
        let defaults = uiTestFixture
            ? (UserDefaults(suiteName: "com.codexmobile.uitest.timelineFixture") ?? injectedDefaults)
            : injectedDefaults

        let persistenceNamespace: String
        if let trimmed = persistenceNamespaceOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            // Tests can pin the on-disk namespace when UserDefaults cannot persist `codex.persistenceNamespace`
            // (simulator “Path not accessible” for arbitrary suite names).
            persistenceNamespace = trimmed
        } else {
            persistenceNamespace = Self.persistenceNamespace(for: defaults)
        }
        self.encoder = encoder
        self.decoder = decoder
        self.defaults = defaults
        self.messagePersistence = CodexMessagePersistence(namespace: persistenceNamespace)
        self.threadListPersistence = CodexThreadListPersistence(namespace: persistenceNamespace)
        self.skillsPersistence = CodexSkillsPersistence(namespace: persistenceNamespace)
        self.aiChangeSetPersistence = AIChangeSetPersistence(namespace: persistenceNamespace)
        self.userNotificationCenter = userNotificationCenter
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
        self.convexTransport = uiTestFixture ? nil : CodexAsyncTransportFactory.make()
        self.phoneIdentityState = uiTestFixture ? Self.uiTestTimelineFixtureIdentity : codexPhoneIdentityStateFromSecureStore()
        self.trustedMacRegistry = uiTestFixture ? .empty : codexTrustedMacRegistryFromSecureStore()
        self.lastTrustedMacDeviceId = uiTestFixture ? nil : SecureStore.readString(for: CodexSecureKeys.lastTrustedMacDeviceId)
        let loadedMessages: [String: [CodexMessage]]
        if uiTestFixture {
            loadedMessages = [:]
        } else {
            loadedMessages = messagePersistence.load().mapValues { messages in
                messages.map { message in
                    var value = message
                    // Streaming cannot survive app relaunch; clear stale flags loaded from disk.
                    value.isStreaming = false
                    return value
                }
            }
        }
        CodexMessageOrderCounter.seed(from: loadedMessages)
        self.messagesByThread = loadedMessages
        rebuildSubagentIdentityDirectory()

        let loadedChangeSets: [AIChangeSet]
        if uiTestFixture {
            loadedChangeSets = []
        } else {
            loadedChangeSets = aiChangeSetPersistence.load()
        }
        self.aiChangeSetsByID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
            partialResult[changeSet.id] = changeSet
        }
        self.aiChangeSetIDByTurnID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
            partialResult[changeSet.turnId] = changeSet.id
        }
        self.aiChangeSetIDByAssistantMessageID = loadedChangeSets.reduce(into: [:]) { partialResult, changeSet in
            if let assistantMessageId = changeSet.assistantMessageId {
                partialResult[assistantMessageId] = changeSet.id
            }
        }

        let savedModelId = defaults.string(forKey: Self.selectedModelIdDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedModelId = (savedModelId?.isEmpty == false) ? savedModelId : nil

        let savedReasoning = defaults.string(forKey: Self.selectedReasoningEffortDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedReasoningEffort = (savedReasoning?.isEmpty == false) ? savedReasoning : nil

        if let savedThreadRuntimeOverrides = defaults.data(forKey: Self.threadRuntimeOverridesDefaultsKey),
           let decodedThreadRuntimeOverrides = try? decoder.decode(
               [String: CodexThreadRuntimeOverride].self,
               from: savedThreadRuntimeOverrides
           ) {
            self.threadRuntimeOverridesByThreadID = decodedThreadRuntimeOverrides
        } else {
            self.threadRuntimeOverridesByThreadID = [:]
        }

        if let savedForkOrigins = defaults.data(forKey: Self.forkedThreadOriginsDefaultsKey),
           let decodedForkOrigins = try? decoder.decode([String: String].self, from: savedForkOrigins) {
            self.forkedFromThreadIDByThreadID = decodedForkOrigins
        } else {
            self.forkedFromThreadIDByThreadID = [:]
        }

        if let savedRenamedThreadNames = defaults.data(forKey: Self.renamedThreadNamesDefaultsKey),
           let decodedRenamedThreadNames = try? decoder.decode([String: String].self, from: savedRenamedThreadNames) {
            self.renamedThreadNameByThreadID = decodedRenamedThreadNames
        } else {
            self.renamedThreadNameByThreadID = [:]
        }

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

        if let savedTransportPreference = defaults.string(forKey: Self.transportPreferenceDefaultsKey),
           let parsedTransportPreference = CodexTransportPreference(rawValue: savedTransportPreference) {
            self.transportPreference = parsedTransportPreference
        } else {
            self.transportPreference = .automatic
        }

        if let persistedGPTAccountSnapshot = loadPersistedGPTAccountSnapshot() {
            self.gptAccountSnapshot = persistedGPTAccountSnapshot
        } else {
            self.gptAccountSnapshot = codexGPTAccountInitialSnapshot()
        }

        if let pendingLogin = gptPendingLoginState,
           !self.gptAccountSnapshot.isAuthenticated,
           self.gptAccountSnapshot.status != .loginPending {
            self.gptAccountSnapshot = CodexGPTAccountSnapshot(
                status: .loginPending,
                authMethod: .chatgpt,
                email: nil,
                displayName: nil,
                planType: nil,
                loginInFlight: true,
                needsReauth: false,
                expiresAt: pendingLogin.expiresAt,
                tokenReady: false,
                tokenUnavailableSince: nil,
                updatedAt: .now
            )
        }

        // Restore relay session from Keychain
        if uiTestFixture {
            self.relaySessionId = nil
            self.relayUrl = nil
            self.relayMacDeviceId = nil
            self.relayMacIdentityPublicKey = nil
            self.relayCloudAsyncSharedSecret = nil
            self.relayProtocolVersion = codexSecureProtocolVersion
            self.remoteNotificationDeviceToken = nil
        } else {
            self.relaySessionId = SecureStore.readString(for: CodexSecureKeys.relaySessionId)
            self.relayUrl = SecureStore.readString(for: CodexSecureKeys.relayUrl)
            self.relayMacDeviceId = SecureStore.readString(for: CodexSecureKeys.relayMacDeviceId)
            self.relayMacIdentityPublicKey = SecureStore.readString(for: CodexSecureKeys.relayMacIdentityPublicKey)
            self.relayCloudAsyncSharedSecret = SecureStore.readString(for: CodexSecureKeys.relayCloudAsyncSharedSecret)
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
            self.remoteNotificationDeviceToken = SecureStore.readString(for: CodexSecureKeys.pushDeviceToken)
            if let relayMacDeviceId,
               let trustedMac = trustedMacRegistry.records[relayMacDeviceId] {
                self.secureConnectionState = .trustedMac
                self.secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
            } else if let trustedMac = preferredTrustedMacRecord {
                self.secureConnectionState = .liveSessionUnresolved
                self.secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
            }
        }
        if uiTestFixture {
            persistedThreadListSnapshot = nil
        } else {
            persistedThreadListSnapshot = threadListPersistence.load()
        }
        let persistedArchivedThreadIDs = defaults.stringArray(forKey: Self.locallyArchivedThreadIDsKey) ?? []
        if persistedThreadListSnapshot?.threads.contains(where: { $0.syncState == .archivedLocal }) == true
            || !persistedArchivedThreadIDs.isEmpty {
            lastArchivedThreadsSyncAt = persistedThreadListSnapshot?.savedAt
        }
        if uiTestFixture {
            persistedSkillsCacheSnapshot = CodexSkillsCacheSnapshot(entriesByRoot: [:])
        } else {
            persistedSkillsCacheSnapshot = skillsPersistence.load() ?? CodexSkillsCacheSnapshot(entriesByRoot: [:])
        }
        restorePersistedConnectionContextIfNeeded()
        restorePersistedThreadListSnapshotIfNeeded()
        rebuildThreadLookupCaches()
        if !uiTestFixture, startsLocalRelayPathMonitor {
            startLocalRelayPathMonitor()
        }
    }

    @MainActor deinit {
        localRelayPathMonitor?.cancel()
        localRelayPathMonitor = nil
        trustedSessionResolveTask?.cancel()
        trustedSessionResolveTask = nil
        messagePersistenceDebounceTask?.cancel()
        messagePersistenceDebounceTask = nil
        threadListPersistenceDebounceTask?.task.cancel()
        threadListPersistenceDebounceTask = nil
        pendingImmediateSyncTask?.cancel()
        pendingImmediateSyncTask = nil
        coalescedRevertRefreshTask?.cancel()
        coalescedRevertRefreshTask = nil
        threadListSyncTask?.cancel()
        threadListSyncTask = nil
        activeThreadSyncTask?.cancel()
        activeThreadSyncTask = nil
        runningThreadWatchSyncTask?.cancel()
        runningThreadWatchSyncTask = nil
        postConnectSyncTask?.cancel()
        postConnectSyncTask = nil
        deferredModelListTask?.cancel()
        deferredModelListTask = nil
        gptAccountLoginSyncTask?.cancel()
        gptAccountLoginSyncTask = nil
        notificationObserverTokens.forEach(NotificationCenter.default.removeObserver)
        notificationObserverTokens.removeAll()
        if let delegateProxy = notificationCenterDelegateProxy,
           userNotificationCenter.delegate === delegateProxy {
            userNotificationCenter.delegate = nil
        }
        notificationCenterDelegateProxy = nil
        endBackgroundRunGraceTask(reason: "deinit")
    }

    // Remembers whether we can offer reconnect without forcing a fresh QR scan.
    var hasSavedRelaySession: Bool {
        normalizedRelaySessionId != nil && normalizedRelayURL != nil
    }

    var isConvexLaneActive: Bool {
        transportMode == .convexRemote
    }

    var hasConvexLaneCredentials: Bool {
        convexLaneCredentials?.sharedSecretData != nil
    }

    /// Legacy name for tests and cloud async transport: relay- or trusted-mac–scoped Convex lane credentials.
    var cloudAsyncFallbackCredentials: CodexConvexLaneCredentials? {
        convexLaneCredentials
    }

    var hasCloudAsyncFallbackCredentials: Bool {
        hasConvexLaneCredentials
    }

    // Normalizes the persisted relay session id before reuse in reconnect flows.
    var normalizedRelaySessionId: String? {
        relaySessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    // Normalizes the persisted relay base URL before reuse in reconnect flows.
    var normalizedRelayURL: String? {
        relayUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var normalizedRelayMacDeviceId: String? {
        relayMacDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var normalizedRelayMacIdentityPublicKey: String? {
        relayMacIdentityPublicKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var normalizedRelayCloudAsyncSharedSecret: String? {
        relayCloudAsyncSharedSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var convexLaneCredentials: CodexConvexLaneCredentials? {
        if normalizedRelayMacDeviceId != nil || normalizedRelayMacIdentityPublicKey != nil {
            if let relayCredentials = relayScopedConvexLaneCredentials,
               relayCredentials.sharedSecretData != nil {
                return relayCredentials
            }
            return nil
        }
        if let trustedCredentials = preferredTrustedMacConvexLaneCredentials,
           trustedCredentials.sharedSecretData != nil {
            return trustedCredentials
        }
        return nil
    }

    var cloudAsyncSharedSecretData: Data? {
        convexLaneCredentials?.sharedSecretData
    }

    var normalizedLastTrustedMacDeviceId: String? {
        lastTrustedMacDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var preferredTrustedMacDeviceId: String? {
        if let normalizedLastTrustedMacDeviceId,
           trustedMacRegistry.records[normalizedLastTrustedMacDeviceId] != nil {
            return normalizedLastTrustedMacDeviceId
        }

        return trustedMacRegistry.records.values
            .sorted { lhs, rhs in
                (lhs.lastUsedAt ?? lhs.lastPairedAt) > (rhs.lastUsedAt ?? rhs.lastPairedAt)
            }
            .first?
            .macDeviceId
    }

    var preferredTrustedMacRecord: CodexTrustedMacRecord? {
        guard let preferredTrustedMacDeviceId else {
            return nil
        }
        return trustedMacRegistry.records[preferredTrustedMacDeviceId]
    }

    var hasTrustedMacReconnectCandidate: Bool {
        preferredTrustedMacRecord?.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasReconnectCandidate: Bool {
        hasSavedRelaySession || hasTrustedMacReconnectCandidate
    }

    var hasAvailableRequestTransport: Bool {
        requestTransportOverride != nil
            || (isConnected && (webSocketConnection != nil || webSocketTask != nil))
            || isConvexLaneActive
    }

    private var relayScopedConvexLaneCredentials: CodexConvexLaneCredentials? {
        guard let macDeviceId = normalizedRelayMacDeviceId,
              let macIdentityPublicKey = normalizedRelayMacIdentityPublicKey else {
            return nil
        }

        let matchingTrustedMac = trustedMacRegistry.records[macDeviceId]
        let sharedSecret = normalizedRelayCloudAsyncSharedSecret
            ?? matchingTrustedMac?.cloudAsyncSharedSecret?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        guard let sharedSecret else {
            return nil
        }

        return CodexConvexLaneCredentials(
            macDeviceId: macDeviceId,
            macIdentityPublicKey: macIdentityPublicKey,
            sharedSecretBase64: sharedSecret
        )
    }

    private var preferredTrustedMacConvexLaneCredentials: CodexConvexLaneCredentials? {
        guard let trustedMac = preferredTrustedMacRecord,
              let sharedSecret = trustedMac.cloudAsyncSharedSecret?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
            return nil
        }

        return CodexConvexLaneCredentials(
            macDeviceId: trustedMac.macDeviceId,
            macIdentityPublicKey: trustedMac.macIdentityPublicKey,
            sharedSecretBase64: sharedSecret
        )
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

        if isBootstrappingConnectionSync || isLoadingModels || isLoadingThreads {
            return .syncing
        }

        return .connected
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
