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

@MainActor
@Observable
final class ThreadTimelineState {
    let threadID: String
    var messages: [CodexMessage]
    var messageRevision: Int
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

    // --- Public state ---------------------------------------------------------

    var threads: [CodexThread] = [] {
        didSet {
            rebuildThreadLookupCaches()
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
    var pendingApproval: CodexApprovalRequest?
    var lastRawMessage: String?
    var lastErrorMessage: String?
    var runtimeDebugLogEntries: [String] = []
    var connectionRecoveryState: CodexConnectionRecoveryState = .idle
    // Per-thread queued drafts for client-side turn queueing while a run is active.
    var queuedTurnDraftsByThread: [String: [QueuedTurnDraft]] = [:]
    // Per-thread queue pause state (active by default when absent).
    var queuePauseStateByThread: [String: QueuePauseState] = [:]
    var messagesByThread: [String: [CodexMessage]] = [:]
    // Monotonic per-thread revision so views can react to message mutations without hashing full transcripts.
    var messageRevisionByThread: [String: Int] = [:]
    var syncRealtimeEnabled = true
    var availableModels: [CodexModelOption] = []
    var selectedModelId: String?
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
    var modelsErrorMessage: String?
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    var pendingNotificationOpenThreadID: String?
    var supportsStructuredSkillInput = true
    // Runtime compatibility flag for `turn/start.collaborationMode` plan turns.
    var supportsTurnCollaborationMode = false
    // Runtime compatibility flag for `thread/start|turn/start.serviceTier` speed controls.
    var supportsServiceTier = true
    // Runtime compatibility flag for the bridge-owned voice transcription flow.
    var supportsBridgeVoiceAuth = true
    // Runtime compatibility flag for native `thread/fork` conversation branching.
    var supportsThreadFork = true
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
    // Test hook: intercepts outbound RPC requests without requiring a live socket.
    @ObservationIgnored var requestTransportOverride: ((String, JSONValue?) async throws -> RPCMessage)?
    // Test hook: stubs trusted-session lookup without performing a real relay HTTP request.
    @ObservationIgnored var trustedSessionResolverOverride: (() async throws -> CodexTrustedSessionResolveResponse)?
    // Keeps the trusted-session HTTP lookup cancellable so manual retry can preempt a stuck resolve.
    @ObservationIgnored var trustedSessionResolveTask: Task<CodexTrustedSessionResolveResponse, Error>?
    @ObservationIgnored var trustedSessionResolveTaskID: UUID?
    var streamingAssistantMessageByTurnID: [String: String] = [:]
    var streamingSystemMessageByItemID: [String: String] = [:]
    /// Rich metadata for command execution tool calls, keyed by itemId.
    var commandExecutionDetailsByItemID: [String: CommandExecutionDetails] = [:]
    // Debounces disk writes while streaming to keep UI responsive.
    var messagePersistenceDebounceTask: Task<Void, Never>?
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
    @ObservationIgnored var subagentMetadataLoadingThreadIDs: Set<String> = []
    var resumedThreadIDs: Set<String> = []
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
    // Remembers whether the current plan flow is staying native or has fallen back to inferred UI.
    var planSessionSourceByThread: [String: CodexPlanSessionSource] = [:] {
        didSet {
            persistPlanSessionSources()
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
    // Canonical repo roots keyed by observed working directories from bridge git/status responses.
    var repoRootByWorkingDirectory: [String: String] = [:]
    var knownRepoRoots: Set<String> = []
    // Service-owned per-thread UI state keeps the active chat isolated from unrelated thread mutations.
    @ObservationIgnored var threadTimelineStateByThread: [String: ThreadTimelineState] = [:]
    @ObservationIgnored var forkedFromThreadIDByThreadID: [String: String] = [:]
    @ObservationIgnored var renamedThreadNameByThreadID: [String: String] = [:]
    @ObservationIgnored var associatedManagedWorktreePathByThreadID: [String: String] = [:]
    @ObservationIgnored var authoritativeProjectPathByThreadID: [String: String] = [:]
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
    let messagePersistence = CodexMessagePersistence()
    let aiChangeSetPersistence = AIChangeSetPersistence()
    let defaults: UserDefaults
    let userNotificationCenter: CodexUserNotificationCentering
    let remoteNotificationRegistrar: CodexRemoteNotificationRegistering

    static let selectedModelIdDefaultsKey = "codex.selectedModelId"
    static let selectedReasoningEffortDefaultsKey = "codex.selectedReasoningEffort"
    static let selectedServiceTierDefaultsKey = "codex.selectedServiceTier"
    static let threadRuntimeOverridesDefaultsKey = "codex.threadRuntimeOverrides"
    static let planSessionSourcesDefaultsKey = "codex.planSessionSources"
    static let selectedAccessModeDefaultsKey = "codex.selectedAccessMode"
    static let locallyArchivedThreadIDsKey = "codex.locallyArchivedThreadIDs"
    static let forkedThreadOriginsDefaultsKey = "codex.forkedThreadOrigins"
    static let renamedThreadNamesDefaultsKey = "codex.renamedThreadNames"
    static let associatedManagedWorktreePathsDefaultsKey = "codex.associatedManagedWorktreePaths"
    static let notificationsPromptedDefaultsKey = "codex.notifications.prompted"

    init(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        defaults: UserDefaults = .standard,
        userNotificationCenter: CodexUserNotificationCentering = UNUserNotificationCenter.current(),
        remoteNotificationRegistrar: CodexRemoteNotificationRegistering = CodexApplicationRemoteNotificationRegistrar()
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.defaults = defaults
        self.userNotificationCenter = userNotificationCenter
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
        self.phoneIdentityState = codexPhoneIdentityStateFromSecureStore()
        self.trustedMacRegistry = codexTrustedMacRegistryFromSecureStore()
        self.lastTrustedMacDeviceId = SecureStore.readString(for: CodexSecureKeys.lastTrustedMacDeviceId)
        let loadedMessages = messagePersistence.load().mapValues { messages in
            messages.map { message in
                var value = message
                // Streaming cannot survive app relaunch; clear stale flags loaded from disk.
                value.isStreaming = false
                return value
            }
        }
        CodexMessageOrderCounter.seed(from: loadedMessages)
        self.messagesByThread = loadedMessages
        rebuildSubagentIdentityDirectory()

        let loadedChangeSets = aiChangeSetPersistence.load()
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

        if let savedPlanSessionSources = defaults.data(forKey: Self.planSessionSourcesDefaultsKey),
           let decodedPlanSessionSources = try? decoder.decode(
               [String: CodexPlanSessionSource].self,
               from: savedPlanSessionSources
           ) {
            self.planSessionSourceByThread = decodedPlanSessionSources
        } else {
            self.planSessionSourceByThread = [:]
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

        if let savedAssociatedManagedWorktreePaths = defaults.data(forKey: Self.associatedManagedWorktreePathsDefaultsKey),
           let decodedAssociatedManagedWorktreePaths = try? decoder.decode(
               [String: String].self,
               from: savedAssociatedManagedWorktreePaths
           ) {
            self.associatedManagedWorktreePathByThreadID = decodedAssociatedManagedWorktreePaths
        } else {
            self.associatedManagedWorktreePathByThreadID = [:]
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
        self.remoteNotificationDeviceToken = SecureStore.readString(for: CodexSecureKeys.pushDeviceToken)
        if let relayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[relayMacDeviceId] {
            self.secureConnectionState = .trustedMac
            self.secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        } else if let trustedMac = preferredTrustedMacRecord {
            self.secureConnectionState = .liveSessionUnresolved
            self.secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        }
        rebuildThreadLookupCaches()
    }

    // Persists per-thread plan-mode provenance so reconnect/relaunch keeps native vs fallback behavior stable.
    private func persistPlanSessionSources() {
        guard !planSessionSourceByThread.isEmpty else {
            defaults.removeObject(forKey: Self.planSessionSourcesDefaultsKey)
            return
        }

        guard let data = try? encoder.encode(planSessionSourceByThread) else {
            defaults.removeObject(forKey: Self.planSessionSourcesDefaultsKey)
            return
        }

        defaults.set(data, forKey: Self.planSessionSourcesDefaultsKey)
    }

    // Remembers whether we can offer reconnect without forcing a fresh QR scan.
    var hasSavedRelaySession: Bool {
        normalizedRelaySessionId != nil && normalizedRelayURL != nil
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
