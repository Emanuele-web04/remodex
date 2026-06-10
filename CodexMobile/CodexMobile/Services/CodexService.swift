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

struct OutgoingSendDedupeSnapshot: Equatable, Sendable {
    let threadId: String
    let normalizedBody: String
    let sentAt: Date
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
    var modelId: String?
    var modelProvider: String?
    var reasoningEffort: String?
    var serviceTierRawValue: String?
    var opencodeAgentId: String?
    var overridesModel: Bool
    var overridesReasoning: Bool
    var overridesServiceTier: Bool
    var overridesAgent: Bool

    init(
        modelId: String? = nil,
        modelProvider: String? = nil,
        reasoningEffort: String? = nil,
        serviceTierRawValue: String? = nil,
        opencodeAgentId: String? = nil,
        overridesModel: Bool = false,
        overridesReasoning: Bool = false,
        overridesServiceTier: Bool = false,
        overridesAgent: Bool = false
    ) {
        self.modelId = modelId
        self.modelProvider = modelProvider
        self.reasoningEffort = reasoningEffort
        self.serviceTierRawValue = serviceTierRawValue
        self.opencodeAgentId = opencodeAgentId
        self.overridesModel = overridesModel
        self.overridesReasoning = overridesReasoning
        self.overridesServiceTier = overridesServiceTier
        self.overridesAgent = overridesAgent
    }

    private enum CodingKeys: String, CodingKey {
        case modelId
        case modelProvider
        case reasoningEffort
        case serviceTierRawValue
        case opencodeAgentId
        case overridesModel
        case overridesReasoning
        case overridesServiceTier
        case overridesAgent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        modelProvider = try container.decodeIfPresent(String.self, forKey: .modelProvider)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        serviceTierRawValue = try container.decodeIfPresent(String.self, forKey: .serviceTierRawValue)
        opencodeAgentId = try container.decodeIfPresent(String.self, forKey: .opencodeAgentId)
        overridesModel = try container.decodeIfPresent(Bool.self, forKey: .overridesModel) ?? false
        overridesReasoning = try container.decodeIfPresent(Bool.self, forKey: .overridesReasoning) ?? false
        overridesServiceTier = try container.decodeIfPresent(Bool.self, forKey: .overridesServiceTier) ?? false
        overridesAgent = try container.decodeIfPresent(Bool.self, forKey: .overridesAgent) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(modelId, forKey: .modelId)
        try container.encodeIfPresent(modelProvider, forKey: .modelProvider)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(serviceTierRawValue, forKey: .serviceTierRawValue)
        try container.encodeIfPresent(opencodeAgentId, forKey: .opencodeAgentId)
        try container.encode(overridesModel, forKey: .overridesModel)
        try container.encode(overridesReasoning, forKey: .overridesReasoning)
        try container.encode(overridesServiceTier, forKey: .overridesServiceTier)
        try container.encode(overridesAgent, forKey: .overridesAgent)
    }

    var serviceTier: CodexServiceTier? {
        guard let serviceTierRawValue else {
            return nil
        }
        return CodexServiceTier(rawValue: serviceTierRawValue)
    }

    var isEmpty: Bool {
        !overridesModel && !overridesReasoning && !overridesServiceTier && !overridesAgent
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

struct CodexExternalThreadOpenRequest: Identifiable, Equatable, Sendable {
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

// MARK: - CodexService State Groups (Issue #9)
// These structs group related state to reduce the ~130 flat properties
// to ~10 top-level grouped properties, improving readability and maintainability.

struct CodexConnectionState {
    var isConnected = false
    var isConnecting = false
    var isInitialized = false
    var isBootstrappingConnectionSync = false
    var isLoadingThreads = false
    var connectionRecoveryState: CodexConnectionRecoveryState = .idle
    var shouldAutoReconnectOnForeground = false
    var backgroundTurnGraceExpiredUntilForeground = false
    var connectedServerIdentity: String?
    var codexTransportMode: CodexRuntimeTransportMode = .unknown
    var postConnectSyncToken: UUID?
    var isAppInForeground = true

    // WebSocket
    var webSocketConnection: NWConnection?
    var webSocketSession: URLSession?
    var webSocketSessionDelegate: CodexURLSessionWebSocketDelegate?
    var webSocketTask: URLSessionWebSocketTask?
    var webSocketKeepAliveTask: Task<Void, Never>?
    var manualWebSocketReadBuffer = Data()
    var usesManualWebSocketTransport = false
    var pendingRequests: [String: CheckedContinuation<RPCMessage, Error>] = [:]

    // Overrides for testing
    var requestTransportOverride: ((String, JSONValue?) async throws -> RPCMessage)?
    var trustedSessionResolverOverride: (() async throws -> CodexTrustedSessionResolveResponse)?
    var webSocketKeepAliveIntervalOverrideNanoseconds: UInt64?
    var webSocketForegroundProbeTimeoutOverrideNanoseconds: UInt64?
    var webSocketKeepAlivePingOverride: (() async throws -> Void)?
    var manualWebSocketDrainSequenceProbe: ((String) -> Void)?
    var trustedSessionResolveTask: Task<CodexTrustedSessionResolveResponse, Error>?
    var trustedSessionResolveTaskID: UUID?
    var threadListSyncTask: Task<Void, Never>?
    var activeThreadSyncTask: Task<Void, Never>?
    var runningThreadWatchSyncTask: Task<Void, Never>?
    var postConnectSyncTask: Task<Void, Never>?
    var gptAccountLoginSyncTask: Task<Void, Never>?
    @ObservationIgnored var applicationStateProvider: () -> UIApplication.State = { UIApplication.shared.applicationState }
}

struct CodexThreadRegistry {
    var threads: [CodexThread] = []
    var activeThreadId: String?
    var activeTurnId: String?
    var activeTurnIdByThread: [String: String] = [:]
    var runningThreadIDs: Set<String> = []
    var protectedRunningFallbackThreadIDs: Set<String> = []
    var readyThreadIDs: Set<String> = []
    var failedThreadIDs: Set<String> = []
    var latestTurnTerminalStateByThread: [String: CodexTurnTerminalState] = [:]
    var terminalStateByTurnID: [String: CodexTurnTerminalState] = [:]
    var hydratedThreadIDs: Set<String> = []
    var loadingThreadIDs: Set<String> = []
    var resumedThreadIDs: Set<String> = []
    var threadIdByTurnID: [String: String] = [:]

    // Thread metadata
    var planSessionSourceByThread: [String: CodexPlanSessionSource] = [:]
    var runningThreadWatchByID: [String: CodexRunningThreadWatch] = [:]
    var mirroredRunningCatchupThreadIDs: Set<String> = []
    var desktopMirroredRunningThreadIDs: Set<String> = []
    var mirroredRunningSuppressedAfterTurnStartFailureThreadIDs: Set<String> = []
    var lastIncomingNotificationMethodByThread: [String: String] = [:]
    var desktopMirroredRunningStaleSnapshotCountsByThread: [String: Int] = [:]
    var desktopMirroredRunningLastActivityAtByThread: [String: Date] = [:]
    var lastMirroredRunningCatchupAtByThread: [String: Date] = [:]
    @ObservationIgnored var subagentMetadataLoadingThreadIDs: Set<String> = []

    // Thread lifecycle tasks
    var threadResumeTaskByThreadID: [String: Task<CodexThread?, Error>] = [:]
    var threadResumeRequestSignatureByThreadID: [String: CodexThreadResumeRequestSignature] = [:]
    var threadHistoryLoadTaskByThreadID: [String: Task<CodexService.ThreadHistoryLoadOutcome, Error>] = [:]
    var forcedHistoryLoadThreadIDs: Set<String> = []
    var deferHydratedMarkForNotMaterializedThreadIDs: Set<String> = []
    var threadRefreshGenerationByThreadID: [String: UInt64] = [:]
    var lastForcedRunningResumeAtByThread: [String: Date] = [:]
    var threadsNeedingCanonicalHistoryReconcile: Set<String> = []
    var threadsWithSatisfiedDeferredHistoryHydration: Set<String> = []
    var canonicalHistoryReconcileTaskByThreadID: [String: Task<Void, Never>] = [:]
    var canonicalHistoryReconcileRetryTaskByThreadID: [String: Task<Void, Never>] = [:]
    var forcedResumeEscalationThreadIDs: Set<String> = []
    var forcedRunningCatchupEscalationThreadIDs: Set<String> = []
    var threadListFetchTaskByLimit: [Int: (id: UUID, task: Task<[CodexThread], Error>)] = [:]
    @ObservationIgnored var turnStateRefreshTaskByThreadID: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored var runningThreadCatchupTaskByThreadID: [String: Task<CodexService.RunningThreadCatchupOutcome, Never>] = [:]

    // Thread identity and lookup
    var threadByID: [String: CodexThread] = [:]
    var threadIndexByID: [String: Int] = [:]
    var firstLiveThreadIDCache: String?
    var subagentIdentityByThreadID: [String: CodexSubagentIdentityEntry] = [:]
    var subagentIdentityByAgentID: [String: CodexSubagentIdentityEntry] = [:]
    var subagentIdentityVersion: Int = 0

    // Thread UI state
    var threadTimelineStateByThread: [String: ThreadTimelineState] = [:]
    var forkedFromThreadIDByThreadID: [String: String] = [:]
    var renamedThreadNameByThreadID: [String: String] = [:]
    var associatedManagedWorktreePathByThreadID: [String: String] = [:]
    var authoritativeProjectPathByThreadID: [String: String] = [:]
    var pinnedThreadIDs: [String] = []
    var pinnedThreadSnapshotsByRootID: [String: [CodexThread]] = [:]
    var snapshotOnlyPinnedThreadIDs: Set<String> = []
    var stoppedTurnIDsByThread: [String: Set<String>] = [:]
}

struct CodexMessageCache {
    var messagesByThread: [String: [CodexMessage]] = [:]
    var messageRevisionByThread: [String: Int] = [:]
    var threadTimelineStateByThread: [String: ThreadTimelineState] = [:]
    var messageIndexCacheByThread: [String: [String: Int]] = [:]
    var latestAssistantOutputByThread: [String: String] = [:]
    var latestAssistantMessageIDByThread: [String: String] = [:]
    var latestRepoAffectingMessageSignalByThread: [String: String] = [:]
    var assistantRevertStateCacheByThread: [String: AssistantRevertStateCacheEntry] = [:]
    var assistantRevertStateRevision: Int = 0
    var stoppedTurnIDsByThread: [String: Set<String>] = [:]
    var pendingSystemDeltasByKey: [String: PendingSystemStreamingDeltas] = [:]
    var systemDeltaFlushTasksByKey: [String: Task<Void, Never>] = [:]
    var recentActivityLineByThread: [String: CodexRecentActivityLine] = [:]
    var contextWindowUsageByThread: [String: ContextWindowUsage] = [:]
    var rateLimitBuckets: [CodexRateLimitBucket] = []
    var hasResolvedRateLimitsSnapshot = false
    var isLoadingRateLimits = false
    var rateLimitsErrorMessage: String?
}

struct CodexTurnQueueState {
    var queuedTurnDraftsByThread: [String: [QueuedTurnDraft]] = [:]
    var queuePauseStateByThread: [String: QueuePauseState] = [:]
    var composerDraftsByThreadID: [String: TurnComposerLocalDraft] = [:]
    var pendingComposerActionByThreadID: [String: CodexPendingThreadComposerAction] = [:]
    var threadsPendingCompletionHaptic: Set<String> = []
    var threadCompletionBanner: CodexThreadCompletionBanner?
    var missingNotificationThreadPrompt: CodexMissingNotificationThreadPrompt?
    var lastOutgoingSendDedupeSnapshot: OutgoingSendDedupeSnapshot?
    var lastRawMessage: String?
    var lastErrorMessage: String?
}

struct CodexModelSelectionState {
    var availableModels: [CodexModelOption] = []
    var selectedModelId: String?
    var hasPersistedSelectedModelId = false
    var selectedGitWriterModelId: String?
    var selectedReasoningEffort: String?
    var selectedServiceTier: CodexServiceTier?
    var threadRuntimeOverridesByThreadID: [String: CodexThreadRuntimeOverride] = [:]
    var selectedAccessMode: CodexAccessMode = .onRequest
    var defaultOpenCodeAgentId: String?
    var availableAgents: [AgentOption] = []
    var availableRuntimes: [RuntimeInfo] = []
    var slashCommandCacheByDirectory: [String: SlashCommandCacheEntry] = [:]
    var isLoadingModels = false
    var pendingRuntimeOptionRefresh = false
    var runtimeOptionRefreshTask: Task<Void, Never>?
    var runtimeOptionRefreshToken: UUID?
    var lastOpenCodeCatalogRevision: String?
    var catalogRefetchDebounceTask: Task<Void, Never>?
    var modelsErrorMessageByProvider: [String: String] = [:]
    var lastModelListOpenCodeMeta: OpenCodeModelListMeta?
    var openCodeModelRetryCount = 0
    var openCodeModelsRetryTask: Task<Void, Never>?
    var lastThreadListMaterializationBlocked: Int = 0
}

struct CodexStreamingState {
    var streamingAssistantFallbackMessageByTurnID: [String: String] = [:]
    var streamingAssistantMessageByItemKey: [String: String] = [:]
    var streamingSystemMessageByItemID: [String: String] = [:]
    var commandExecutionDetailsByItemID: [String: CommandExecutionDetails] = [:]
    var messagePersistenceDebounceTask: Task<Void, Never>?
    var pendingAssistantDeltaByStreamID: [String: String] = [:]
    var pendingAssistantDeltaContextByStreamID: [String: (threadId: String, turnId: String, itemId: String?, assistantPhase: String?)] = [:]
    var pendingAssistantDeltaStreamOrder: [String] = []
    var pendingAssistantDeltaFlushTask: Task<Void, Never>?
    var coalescedRevertRefreshTask: Task<Void, Never>?
    var assistantCompletionFingerprintByThread: [String: (text: String, timestamp: Date)] = [:]
    var assistantCompletionFingerprintByTurn: [String: (textHash: String, itemId: String?, timestamp: Date)] = [:]
    var deferredSyncTasks: [String: Task<Void, Never>] = [:]
    var currentOutput = ""
}

struct CodexPermissionState {
    var pendingApprovals: [CodexApprovalRequest] = []
    var pendingOpenCodePermissions: [OpenCodePermissionRequest] = []
    var sessionGrantedOpenCodeTools: Set<String> = []
    var openCodePermissionsUIEnabledOverride: Bool?
}

struct CodexNotificationState {
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    var pendingNotificationOpenThreadID: String?
    var hasConfiguredNotifications = false
    var runCompletionNotificationDedupedAt: [String: Date] = [:]
    var structuredUserInputNotificationDedupedAt: [String: Date] = [:]
    var notificationCenterDelegateProxy: CodexNotificationCenterDelegateProxy?
    var notificationObserverTokens: [NSObjectProtocol] = []
    var remoteNotificationDeviceToken: String?
    var lastPushRegistrationSignature: String?
    var pushRegistrationFailureMessage: String?
    var backgroundTurnGraceTaskID: UIBackgroundTaskIdentifier = .invalid
    var remoteNotificationRegistrar: CodexRemoteNotificationRegistering?
}

struct CodexTerminalState {
    var terminalSnapshot: RemodexTerminalSnapshot = .idle
    var terminalSnapshotsById: [String: RemodexTerminalSnapshot] = [:]
    var terminalProfile: RemodexTerminalProfile = RemodexTerminalProfileStore.load()
    var nativeSSHTerminal = RemodexNativeSSHTerminal()
    var nativeSSHTerminalsById: [String: RemodexNativeSSHTerminal] = [:]
}

struct CodexSecurityState {
    var relaySessionId: String?
    var relayUrl: String?
    var relayMacDeviceId: String?
    var relayMacIdentityPublicKey: String?
    var relayProtocolVersion: Int = codexSecureProtocolVersion
    var lastAppliedBridgeOutboundSeq = 0
    var secureConnectionState: CodexSecureConnectionState = .notPaired
    var secureMacFingerprint: String?
    var shouldForceQRBootstrapOnNextHandshake = false
    var trustedReconnectFailureCount = 0
    var secureSession: CodexSecureSession?
    var pendingHandshake: CodexPendingHandshake?
    var lastCompletedSecureHandshakeMode: CodexSecureHandshakeMode?
    var pendingSecureControlContinuations: [String: [CodexSecureControlWaiter]] = [:]
    var bufferedSecureControlMessages: [String: [String]] = [:]
    var localNetworkAuthorizationStatus: LocalNetworkAuthorizationStatus = .unknown
    var phoneIdentityState: CodexPhoneIdentityState = codexPhoneIdentityStateFromSecureStore()
    var trustedMacRegistry: CodexTrustedMacRegistry = codexTrustedMacRegistryFromSecureStore()
    var currentTrustedMacDeviceId: String?
    var lastTrustedMacDeviceId: String?
    var previousTrustedMacDeviceId: String?
    @ObservationIgnored var macScopedContextOverrideDeviceId: String?
    @ObservationIgnored var suspendAutomaticMacScopedPersistence = false
    @ObservationIgnored var isApplyingMacScopedState = false
}

struct CodexGitRepoState {
    var repoRootByWorkingDirectory: [String: String] = [:]
    var knownRepoRoots: Set<String> = []
    var gitStackedActionProgressHandlers: [String: (TurnGitActionPhase, TurnGitActionPhaseStatus) -> Void] = [:]
    var aiChangeSetsByID: [String: AIChangeSet] = [:]
    var aiChangeSetIDByTurnID: [String: String] = [:]
    var aiChangeSetIDByAssistantMessageID: [String: String] = [:]
    var workspaceCheckpointCopyTaskByTurnID: [String: Task<Void, Never>] = [:]
    var busyRepoRoots: Set<String> = []
    var busyRepoRootsRevision: Int = 0
}

struct CodexAccountBridgeState {
    var gptAccountSnapshot: CodexGPTAccountSnapshot = codexGPTAccountInitialSnapshot()
    var gptAccountErrorMessage: String?
    var bridgeInstalledVersion: String?
    var latestBridgePackageVersion: String?
    var bridgeUpdatePrompt: CodexBridgeUpdatePrompt?
    var lastPresentedAvailableBridgePackageVersion: String?
    var hasPresentedServiceTierBridgeUpdatePrompt = false
    var hasPresentedThreadForkBridgeUpdatePrompt = false
    var hasPresentedMinimumBridgePackageUpdatePrompt = false
    var keepMacAwakeWhileBridgeRuns = false
    var runtimeDebugLogEntries: [String] = []

    // Bridge capabilities
    var supportsStructuredSkillInput = true
    var supportsStructuredMentionInput = true
    var supportsTurnCollaborationMode = false
    var supportsServiceTier = true
    var supportsBridgeVoiceTranscription = true
    var supportsThreadFork = true
    var supportsTurnPagination = true
    var syncRealtimeEnabled = true
}

struct CodexHistoryPaginationState {
    var olderThreadHistoryCursorByThreadID: [String: JSONValue] = [:]
    var exhaustedOlderThreadHistoryCursorByThreadID: [String: JSONValue] = [:]
    var loadingOlderThreadHistoryIDs: Set<String> = []
    var threadTimelineProjectionLimitByThreadID: [String: Int] = [:]
    var initialTurnsLoadedByThreadID: Set<String> = []
    var threadsWithAuthoritativeLocalHistoryStart: Set<String> = []
    var olderHistoryLoadErrorByThreadID: [String: String] = [:]
}

@MainActor
@Observable
final class CodexService {
    static let minimumSupportedBridgePackageVersion = "2.0.0"

    // --- Public state ---------------------------------------------------------

    var threads: [CodexThread] = [] {
        didSet {
            rebuildThreadLookupCaches()
            refreshPinnedThreadSnapshots()
        }
    }
    var isConnected = false {
        didSet { connection.isConnected = isConnected }
    }
    var isConnecting = false {
        didSet { connection.isConnecting = isConnecting }
    }
    var isInitialized = false {
        didSet { connection.isInitialized = isInitialized }
    }
    var isLoadingThreads = false {
        didSet { connection.isLoadingThreads = isLoadingThreads }
    }
    // Tracks the non-blocking bootstrap that hydrates chats/models after the socket is ready.
    var isBootstrappingConnectionSync = false {
        didSet { connection.isBootstrappingConnectionSync = isBootstrappingConnectionSync }
    }
    var currentOutput = "" {
        didSet { streaming.currentOutput = currentOutput }
    }
    var activeThreadId: String? {
        didSet { threadRegistry.activeThreadId = activeThreadId }
    }
    var activeTurnId: String? {
        didSet { threadRegistry.activeTurnId = activeTurnId }
    }
    var activeTurnIdByThread: [String: String] = [:] {
        didSet { threadRegistry.activeTurnIdByThread = activeTurnIdByThread }
    }

    var runningThreadIDs: Set<String> = [] {
        didSet { threadRegistry.runningThreadIDs = runningThreadIDs }
    }
    // Protects active runs that are real but have not yielded a stable turnId yet.
    var protectedRunningFallbackThreadIDs: Set<String> = [] {
        didSet { threadRegistry.protectedRunningFallbackThreadIDs = protectedRunningFallbackThreadIDs }
    }
    var readyThreadIDs: Set<String> = [] {
        didSet { threadRegistry.readyThreadIDs = readyThreadIDs }
    }
    var failedThreadIDs: Set<String> = [] {
        didSet { threadRegistry.failedThreadIDs = failedThreadIDs }
    }
    // Threads that started a real run and haven't completed yet; survives sync-poll clearing.
    @ObservationIgnored var threadsPendingCompletionHaptic: Set<String> = [] {
        didSet { turnQueue.threadsPendingCompletionHaptic = threadsPendingCompletionHaptic }
    }
    // Keeps the latest terminal outcome per thread so UI can react to real run completion.
    var latestTurnTerminalStateByThread: [String: CodexTurnTerminalState] = [:] {
        didSet { threadRegistry.latestTurnTerminalStateByThread = latestTurnTerminalStateByThread }
    }
    // Preserves terminal outcome per turn so completed/stopped blocks stay distinguishable.
    var terminalStateByTurnID: [String: CodexTurnTerminalState] = [:] {
        didSet { threadRegistry.terminalStateByTurnID = terminalStateByTurnID }
    }
    // Ordered pending runtime approvals keyed by request id so concurrent prompts do not overwrite each other.
    var pendingApprovals: [CodexApprovalRequest] = [] {
        didSet { permissions.pendingApprovals = pendingApprovals }
    }
    // OpenCode SDK permission queue — separate from Codex pendingApprovals (D16).
    var pendingOpenCodePermissions: [OpenCodePermissionRequest] = [] {
        didSet { permissions.pendingOpenCodePermissions = pendingOpenCodePermissions }
    }
    var sessionGrantedOpenCodeTools: Set<String> = [] {
        didSet { permissions.sessionGrantedOpenCodeTools = sessionGrantedOpenCodeTools }
    }
    @ObservationIgnored var openCodePermissionsUIEnabledOverride: Bool? {
        didSet { permissions.openCodePermissionsUIEnabledOverride = openCodePermissionsUIEnabledOverride }
    }
    var lastRawMessage: String? {
        didSet { turnQueue.lastRawMessage = lastRawMessage }
    }
    var lastErrorMessage: String? {
        didSet { turnQueue.lastErrorMessage = lastErrorMessage }
    }
    var keepMacAwakeWhileBridgeRuns = false {
        didSet { accountBridge.keepMacAwakeWhileBridgeRuns = keepMacAwakeWhileBridgeRuns }
    }
    var runtimeDebugLogEntries: [String] = [] {
        didSet { accountBridge.runtimeDebugLogEntries = runtimeDebugLogEntries }
    }
    var connectionRecoveryState: CodexConnectionRecoveryState = .idle {
        didSet { connection.connectionRecoveryState = connectionRecoveryState }
    }
    // Per-thread queued drafts for client-side turn queueing while a run is active.
    var queuedTurnDraftsByThread: [String: [QueuedTurnDraft]] = [:] {
        didSet { turnQueue.queuedTurnDraftsByThread = queuedTurnDraftsByThread }
    }
    // Per-thread queue pause state (active by default when absent).
    var queuePauseStateByThread: [String: QueuePauseState] = [:] {
        didSet { turnQueue.queuePauseStateByThread = queuePauseStateByThread }
    }
    // Per-thread unsent composer drafts that survive chat switches and app restarts.
    var composerDraftsByThreadID: [String: TurnComposerLocalDraft] = [:] {
        didSet { turnQueue.composerDraftsByThreadID = composerDraftsByThreadID }
    }
    var messagesByThread: [String: [CodexMessage]] = [:] {
        didSet { messageCache.messagesByThread = messagesByThread }
    }
    // Monotonic per-thread revision so views can react to message mutations without hashing full transcripts.
    var messageRevisionByThread: [String: Int] = [:] {
        didSet { messageCache.messageRevisionByThread = messageRevisionByThread }
    }
    var syncRealtimeEnabled = true {
        didSet { accountBridge.syncRealtimeEnabled = syncRealtimeEnabled }
    }
    var availableModels: [CodexModelOption] = [] {
        didSet { modelSelection.availableModels = availableModels }
    }
    var selectedModelId: String? {
        didSet { modelSelection.selectedModelId = selectedModelId }
    }
    var hasPersistedSelectedModelId = false {
        didSet { modelSelection.hasPersistedSelectedModelId = hasPersistedSelectedModelId }
    }
    var selectedGitWriterModelId: String? {
        didSet { modelSelection.selectedGitWriterModelId = selectedGitWriterModelId }
    }
    var selectedReasoningEffort: String? {
        didSet { modelSelection.selectedReasoningEffort = selectedReasoningEffort }
    }
    var selectedServiceTier: CodexServiceTier? {
        didSet { modelSelection.selectedServiceTier = selectedServiceTier }
    }
    // Per-chat runtime overrides let the composer diverge from app-wide defaults.
    var threadRuntimeOverridesByThreadID: [String: CodexThreadRuntimeOverride] = [:] {
        didSet { modelSelection.threadRuntimeOverridesByThreadID = threadRuntimeOverridesByThreadID }
    }
    var selectedAccessMode: CodexAccessMode = .onRequest {
        didSet { modelSelection.selectedAccessMode = selectedAccessMode }
    }
    var defaultOpenCodeAgentId: String? {
        didSet { modelSelection.defaultOpenCodeAgentId = defaultOpenCodeAgentId }
    }
    var availableAgents: [AgentOption] = [] {
        didSet { modelSelection.availableAgents = availableAgents }
    }
    var availableRuntimes: [RuntimeInfo] = [] {
        didSet { modelSelection.availableRuntimes = availableRuntimes }
    }
    @ObservationIgnored var slashCommandCacheByDirectory: [String: SlashCommandCacheEntry] = [:] {
        didSet { modelSelection.slashCommandCacheByDirectory = slashCommandCacheByDirectory }
    }
    // Bridge-owned ChatGPT auth snapshot used by Settings and voice gating.
    var gptAccountSnapshot: CodexGPTAccountSnapshot = codexGPTAccountInitialSnapshot() {
        didSet {
            persistGPTAccountSnapshot(gptAccountSnapshot)
            accountBridge.gptAccountSnapshot = gptAccountSnapshot
        }
    }
    // Holds the most recent account-specific error without colliding with transport-level failures.
    var gptAccountErrorMessage: String? {
        didSet { accountBridge.gptAccountErrorMessage = gptAccountErrorMessage }
    }
    var isLoadingModels = false {
        didSet { modelSelection.isLoadingModels = isLoadingModels }
    }
    // Coalesces post-connect model refreshes behind thread hydration so composer metadata cannot be skipped.
    @ObservationIgnored var pendingRuntimeOptionRefresh = false {
        didSet { modelSelection.pendingRuntimeOptionRefresh = pendingRuntimeOptionRefresh }
    }
    @ObservationIgnored var runtimeOptionRefreshTask: Task<Void, Never>? {
        didSet { modelSelection.runtimeOptionRefreshTask = runtimeOptionRefreshTask }
    }
    @ObservationIgnored var runtimeOptionRefreshToken: UUID? {
        didSet { modelSelection.runtimeOptionRefreshToken = runtimeOptionRefreshToken }
    }
    // Tracks the last observed OpenCode catalog fingerprint for push-driven refresh dedupe.
    @ObservationIgnored var lastOpenCodeCatalogRevision: String? {
        didSet { modelSelection.lastOpenCodeCatalogRevision = lastOpenCodeCatalogRevision }
    }
    @ObservationIgnored var catalogRefetchDebounceTask: Task<Void, Never>? {
        didSet { modelSelection.catalogRefetchDebounceTask = catalogRefetchDebounceTask }
    }
    @ObservationIgnored var modelsErrorMessageByProvider: [String: String] = [:] {
        didSet { modelSelection.modelsErrorMessageByProvider = modelsErrorMessageByProvider }
    }
    var lastModelListOpenCodeMeta: OpenCodeModelListMeta? {
        didSet { modelSelection.lastModelListOpenCodeMeta = lastModelListOpenCodeMeta }
    }
    @ObservationIgnored var openCodeModelRetryCount = 0 {
        didSet { modelSelection.openCodeModelRetryCount = openCodeModelRetryCount }
    }
    @ObservationIgnored var openCodeModelsRetryTask: Task<Void, Never>? {
        didSet { modelSelection.openCodeModelsRetryTask = openCodeModelsRetryTask }
    }
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined {
        didSet { notifications.notificationAuthorizationStatus = notificationAuthorizationStatus }
    }
    var pendingNotificationOpenThreadID: String? {
        didSet { notifications.pendingNotificationOpenThreadID = pendingNotificationOpenThreadID }
    }
    var externalThreadOpenRequest: CodexExternalThreadOpenRequest?
    var supportsStructuredSkillInput = true {
        didSet { accountBridge.supportsStructuredSkillInput = supportsStructuredSkillInput }
    }
    var supportsStructuredMentionInput = true {
        didSet { accountBridge.supportsStructuredMentionInput = supportsStructuredMentionInput }
    }
    // Runtime compatibility flag for `turn/start.collaborationMode` plan turns.
    var supportsTurnCollaborationMode = false {
        didSet { accountBridge.supportsTurnCollaborationMode = supportsTurnCollaborationMode }
    }
    // Runtime compatibility flag for `thread/start|turn/start.serviceTier` speed controls.
    var supportsServiceTier = true {
        didSet { accountBridge.supportsServiceTier = supportsServiceTier }
    }
    // Runtime compatibility flag for the bridge-owned voice transcription flow.
    var supportsBridgeVoiceTranscription = true {
        didSet { accountBridge.supportsBridgeVoiceTranscription = supportsBridgeVoiceTranscription }
    }
    // Runtime compatibility flag for native `thread/fork` conversation branching.
    var supportsThreadFork = true {
        didSet { accountBridge.supportsThreadFork = supportsThreadFork }
    }
    // Runtime compatibility flag for `thread/turns/list` and `excludeTurns`.
    var supportsTurnPagination = true {
        didSet { accountBridge.supportsTurnPagination = supportsTurnPagination }
    }
    // Seeds brand-new chats with one-shot composer actions like code review.
    var pendingComposerActionByThreadID: [String: CodexPendingThreadComposerAction] = [:] {
        didSet { turnQueue.pendingComposerActionByThreadID = pendingComposerActionByThreadID }
    }
    // In-memory identity directory for subagents, keyed by thread id and agent id.
    var subagentIdentityVersion: Int = 0 {
        didSet { threadRegistry.subagentIdentityVersion = subagentIdentityVersion }
    }
    // Suppresses accidental double-tap / duplicate turn/start within a short window.
    @ObservationIgnored var lastOutgoingSendDedupeSnapshot: OutgoingSendDedupeSnapshot? {
        didSet { turnQueue.lastOutgoingSendDedupeSnapshot = lastOutgoingSendDedupeSnapshot }
    }

    // Relay session persistence
    var relaySessionId: String? {
        didSet { security.relaySessionId = relaySessionId }
    }
    var relayUrl: String? {
        didSet { security.relayUrl = relayUrl }
    }
    var relayMacDeviceId: String? {
        didSet { security.relayMacDeviceId = relayMacDeviceId }
    }
    var relayMacIdentityPublicKey: String? {
        didSet { security.relayMacIdentityPublicKey = relayMacIdentityPublicKey }
    }
    var relayProtocolVersion: Int = codexSecureProtocolVersion {
        didSet { security.relayProtocolVersion = relayProtocolVersion }
    }
    var lastAppliedBridgeOutboundSeq = 0 {
        didSet { security.lastAppliedBridgeOutboundSeq = lastAppliedBridgeOutboundSeq }
    }
    // Mirrors the bridge package version currently running on the Mac, if the bridge reports it.
    var bridgeInstalledVersion: String? {
        didSet { accountBridge.bridgeInstalledVersion = bridgeInstalledVersion }
    }
    // Mirrors the latest published bridge package version, when the bridge can resolve it.
    var latestBridgePackageVersion: String? {
        didSet { accountBridge.latestBridgePackageVersion = latestBridgePackageVersion }
    }
    // Fresh QR scans must use bootstrap once, even if this Mac was already trusted before.
    var shouldForceQRBootstrapOnNextHandshake = false {
        didSet { security.shouldForceQRBootstrapOnNextHandshake = shouldForceQRBootstrapOnNextHandshake }
    }
    // Stops infinite trusted-reconnect loops by escalating back to QR after repeated handshake failures.
    var trustedReconnectFailureCount = 0 {
        didSet { security.trustedReconnectFailureCount = trustedReconnectFailureCount }
    }
    var secureConnectionState: CodexSecureConnectionState = .notPaired {
        didSet { security.secureConnectionState = secureConnectionState }
    }
    var secureMacFingerprint: String? {
        didSet { security.secureMacFingerprint = secureMacFingerprint }
    }
    // Keeps the bridge-update UX visible even if connection cleanup resets secure transport state.
    var bridgeUpdatePrompt: CodexBridgeUpdatePrompt? {
        didSet { accountBridge.bridgeUpdatePrompt = bridgeUpdatePrompt }
    }
    var hasPresentedServiceTierBridgeUpdatePrompt = false {
        didSet { accountBridge.hasPresentedServiceTierBridgeUpdatePrompt = hasPresentedServiceTierBridgeUpdatePrompt }
    }
    var hasPresentedThreadForkBridgeUpdatePrompt = false {
        didSet { accountBridge.hasPresentedThreadForkBridgeUpdatePrompt = hasPresentedThreadForkBridgeUpdatePrompt }
    }
    var hasPresentedMinimumBridgePackageUpdatePrompt = false {
        didSet { accountBridge.hasPresentedMinimumBridgePackageUpdatePrompt = hasPresentedMinimumBridgePackageUpdatePrompt }
    }
    // Remembers the latest optional npm update we already surfaced so foreground refreshes stay non-spammy.
    var lastPresentedAvailableBridgePackageVersion: String? {
        didSet { accountBridge.lastPresentedAvailableBridgePackageVersion = lastPresentedAvailableBridgePackageVersion }
    }
    // Mirrors the sidebar ready-dot with a tappable in-app banner when another chat finishes.
    var threadCompletionBanner: CodexThreadCompletionBanner? {
        didSet { turnQueue.threadCompletionBanner = threadCompletionBanner }
    }
    // Explains why a push-opened chat could not be restored and offers a recovery path.
    var missingNotificationThreadPrompt: CodexMissingNotificationThreadPrompt? {
        didSet { turnQueue.missingNotificationThreadPrompt = missingNotificationThreadPrompt }
    }
    // Owns the scarce App Store review prompt budget for successful in-app runs.
    @ObservationIgnored let appReviewPromptCoordinator = AppReviewPromptCoordinator()
    // Owns runtime catalog fetch, model/list loading, retry state, and provider capability lookups.
    @ObservationIgnored lazy var runtimeCoordinator = RuntimeCoordinator(codex: self)
    // Interactive SSH terminal state is owned on-device so it can bootstrap a Mac before the bridge runs.
    var terminalSnapshot: RemodexTerminalSnapshot = .idle {
        didSet { terminalState.terminalSnapshot = terminalSnapshot }
    }
    var terminalSnapshotsById: [String: RemodexTerminalSnapshot] = [:] {
        didSet { terminalState.terminalSnapshotsById = terminalSnapshotsById }
    }
    var terminalProfile: RemodexTerminalProfile = RemodexTerminalProfileStore.load() {
        didSet { terminalState.terminalProfile = terminalProfile }
    }
    @ObservationIgnored let nativeSSHTerminal = RemodexNativeSSHTerminal()
    @ObservationIgnored var nativeSSHTerminalsById: [String: RemodexNativeSSHTerminal] = [:] {
        didSet { terminalState.nativeSSHTerminalsById = nativeSSHTerminalsById }
    }

    // --- Internal wiring (grouped state) --------------------------------------
    // These properties are stored in the grouped state structs and accessed
    // through computed shims during migration. Callers should migrate to
    // `connection.prop`, `threadRegistry.prop`, etc. for new code.

    let webSocketQueue = DispatchQueue(label: "CodexMobile.WebSocket", qos: .userInitiated)

    // MARK: Connection shims (migrate to `connection.*`)
    var webSocketConnection: NWConnection? {
        get { connection.webSocketConnection }
        set { connection.webSocketConnection = newValue }
    }
    var webSocketSession: URLSession? {
        get { connection.webSocketSession }
        set { connection.webSocketSession = newValue }
    }
    var webSocketSessionDelegate: CodexURLSessionWebSocketDelegate? {
        get { connection.webSocketSessionDelegate }
        set { connection.webSocketSessionDelegate = newValue }
    }
    var webSocketTask: URLSessionWebSocketTask? {
        get { connection.webSocketTask }
        set { connection.webSocketTask = newValue }
    }
    var webSocketKeepAliveTask: Task<Void, Never>? {
        get { connection.webSocketKeepAliveTask }
        set { connection.webSocketKeepAliveTask = newValue }
    }
    var manualWebSocketReadBuffer: Data {
        get { connection.manualWebSocketReadBuffer }
        set { connection.manualWebSocketReadBuffer = newValue }
    }
    var usesManualWebSocketTransport: Bool {
        get { connection.usesManualWebSocketTransport }
        set { connection.usesManualWebSocketTransport = newValue }
    }
    var pendingRequests: [String: CheckedContinuation<RPCMessage, Error>] {
        get { connection.pendingRequests }
        set { connection.pendingRequests = newValue }
    }
    var requestTransportOverride: ((String, JSONValue?) async throws -> RPCMessage)? {
        get { connection.requestTransportOverride }
        set { connection.requestTransportOverride = newValue }
    }
    var trustedSessionResolverOverride: (() async throws -> CodexTrustedSessionResolveResponse)? {
        get { connection.trustedSessionResolverOverride }
        set { connection.trustedSessionResolverOverride = newValue }
    }
    var webSocketKeepAliveIntervalOverrideNanoseconds: UInt64? {
        get { connection.webSocketKeepAliveIntervalOverrideNanoseconds }
        set { connection.webSocketKeepAliveIntervalOverrideNanoseconds = newValue }
    }
    var webSocketForegroundProbeTimeoutOverrideNanoseconds: UInt64? {
        get { connection.webSocketForegroundProbeTimeoutOverrideNanoseconds }
        set { connection.webSocketForegroundProbeTimeoutOverrideNanoseconds = newValue }
    }
    var webSocketKeepAlivePingOverride: (() async throws -> Void)? {
        get { connection.webSocketKeepAlivePingOverride }
        set { connection.webSocketKeepAlivePingOverride = newValue }
    }
    var manualWebSocketDrainSequenceProbe: ((String) -> Void)? {
        get { connection.manualWebSocketDrainSequenceProbe }
        set { connection.manualWebSocketDrainSequenceProbe = newValue }
    }
    var shouldAutoReconnectOnForeground: Bool {
        get { connection.shouldAutoReconnectOnForeground }
        set { connection.shouldAutoReconnectOnForeground = newValue }
    }
    var backgroundTurnGraceExpiredUntilForeground: Bool {
        get { connection.backgroundTurnGraceExpiredUntilForeground }
        set { connection.backgroundTurnGraceExpiredUntilForeground = newValue }
    }
    var connectedServerIdentity: String? {
        get { connection.connectedServerIdentity }
        set { connection.connectedServerIdentity = newValue }
    }
    var codexTransportMode: CodexRuntimeTransportMode {
        get { connection.codexTransportMode }
        set { connection.codexTransportMode = newValue }
    }
    var postConnectSyncToken: UUID? {
        get { connection.postConnectSyncToken }
        set { connection.postConnectSyncToken = newValue }
    }
    // Keeps the trusted-session HTTP lookup cancellable so manual retry can preempt a stuck resolve.
    @ObservationIgnored var trustedSessionResolveTask: Task<CodexTrustedSessionResolveResponse, Error>? {
        didSet { connection.trustedSessionResolveTask = trustedSessionResolveTask }
    }
    @ObservationIgnored var trustedSessionResolveTaskID: UUID? {
        didSet { connection.trustedSessionResolveTaskID = trustedSessionResolveTaskID }
    }
    // Assistant streams keep turn fallback separate from item-specific identity to avoid cross-item overlap.
    @ObservationIgnored var streamingAssistantFallbackMessageByTurnID: [String: String] = [:] {
        didSet { streaming.streamingAssistantFallbackMessageByTurnID = streamingAssistantFallbackMessageByTurnID }
    }
    @ObservationIgnored var streamingAssistantMessageByItemKey: [String: String] = [:] {
        didSet { streaming.streamingAssistantMessageByItemKey = streamingAssistantMessageByItemKey }
    }
    @ObservationIgnored var streamingSystemMessageByItemID: [String: String] = [:] {
        didSet { streaming.streamingSystemMessageByItemID = streamingSystemMessageByItemID }
    }
    /// Rich metadata for command execution tool calls, keyed by itemId.
    var commandExecutionDetailsByItemID: [String: CommandExecutionDetails] = [:] {
        didSet { streaming.commandExecutionDetailsByItemID = commandExecutionDetailsByItemID }
    }
    // Debounces disk writes while streaming to keep UI responsive.
    @ObservationIgnored var messagePersistenceDebounceTask: Task<Void, Never>? {
        didSet { streaming.messagePersistenceDebounceTask = messagePersistenceDebounceTask }
    }
    // Coalesces high-frequency assistant deltas before they mutate observed timeline state.
    @ObservationIgnored var pendingAssistantDeltaByStreamID: [String: String] = [:] {
        didSet { streaming.pendingAssistantDeltaByStreamID = pendingAssistantDeltaByStreamID }
    }
    @ObservationIgnored var pendingAssistantDeltaContextByStreamID: [String: (threadId: String, turnId: String, itemId: String?, assistantPhase: String?)] = [:] {
        didSet { streaming.pendingAssistantDeltaContextByStreamID = pendingAssistantDeltaContextByStreamID }
    }
    @ObservationIgnored var pendingAssistantDeltaStreamOrder: [String] = [] {
        didSet { streaming.pendingAssistantDeltaStreamOrder = pendingAssistantDeltaStreamOrder }
    }
    @ObservationIgnored var pendingAssistantDeltaFlushTask: Task<Void, Never>? {
        didSet { streaming.pendingAssistantDeltaFlushTask = pendingAssistantDeltaFlushTask }
    }
    let assistantDeltaBatchIntervalNanoseconds: UInt64 = 50_000_000
    // Coalesces multiple invalidateAssistantRevertStates() calls within the same run loop tick into one refresh.
    var coalescedRevertRefreshTask: Task<Void, Never>? {
        didSet { streaming.coalescedRevertRefreshTask = coalescedRevertRefreshTask }
    }
    // Dedupes completion payloads when servers omit turn/item identifiers.
    var assistantCompletionFingerprintByThread: [String: (text: String, timestamp: Date)] = [:] {
        didSet { streaming.assistantCompletionFingerprintByThread = assistantCompletionFingerprintByThread }
    }
    // Dedupes duplicate item/completed races within a single turn (30s TTL).
    @ObservationIgnored var assistantCompletionFingerprintByTurn: [String: (textHash: String, itemId: String?, timestamp: Date)] = [:] {
        didSet { streaming.assistantCompletionFingerprintByTurn = assistantCompletionFingerprintByTurn }
    }
    // Coalesces turn/started history sync so live pending rows are not raced by thread/read.
    @ObservationIgnored var deferredSyncTasks: [String: Task<Void, Never>] = [:] {
        didSet { streaming.deferredSyncTasks = deferredSyncTasks }
    }
    // Dedupes concise activity feed lines per thread/turn to avoid visual spam.
    var recentActivityLineByThread: [String: CodexRecentActivityLine] = [:] {
        didSet { messageCache.recentActivityLineByThread = recentActivityLineByThread }
    }
    var contextWindowUsageByThread: [String: ContextWindowUsage] = [:] {
        didSet { messageCache.contextWindowUsageByThread = contextWindowUsageByThread }
    }
    var rateLimitBuckets: [CodexRateLimitBucket] = [] {
        didSet { messageCache.rateLimitBuckets = rateLimitBuckets }
    }
    // Distinguishes "not loaded yet" from "loaded successfully, but no visible buckets exist".
    var hasResolvedRateLimitsSnapshot = false {
        didSet { messageCache.hasResolvedRateLimitsSnapshot = hasResolvedRateLimitsSnapshot }
    }
    var isLoadingRateLimits = false {
        didSet { messageCache.isLoadingRateLimits = isLoadingRateLimits }
    }
    var rateLimitsErrorMessage: String? {
        didSet { messageCache.rateLimitsErrorMessage = rateLimitsErrorMessage }
    }
    var threadIdByTurnID: [String: String] = [:] {
        didSet { threadRegistry.threadIdByTurnID = threadIdByTurnID }
    }
    var hydratedThreadIDs: Set<String> = [] {
        didSet { threadRegistry.hydratedThreadIDs = hydratedThreadIDs }
    }
    var loadingThreadIDs: Set<String> = [] {
        didSet { threadRegistry.loadingThreadIDs = loadingThreadIDs }
    }
    // Cursor-backed history pages let large chats open from the recent tail first.
    var olderThreadHistoryCursorByThreadID: [String: JSONValue] = [:] {
        didSet { historyPagination.olderThreadHistoryCursorByThreadID = olderThreadHistoryCursorByThreadID }
    }
    var exhaustedOlderThreadHistoryCursorByThreadID: [String: JSONValue] = [:] {
        didSet { historyPagination.exhaustedOlderThreadHistoryCursorByThreadID = exhaustedOlderThreadHistoryCursorByThreadID }
    }
    var loadingOlderThreadHistoryIDs: Set<String> = [] {
        didSet { historyPagination.loadingOlderThreadHistoryIDs = loadingOlderThreadHistoryIDs }
    }
    var threadTimelineProjectionLimitByThreadID: [String: Int] = [:] {
        didSet { historyPagination.threadTimelineProjectionLimitByThreadID = threadTimelineProjectionLimitByThreadID }
    }
    var initialTurnsLoadedByThreadID: Set<String> = [] {
        didSet { historyPagination.initialTurnsLoadedByThreadID = initialTurnsLoadedByThreadID }
    }
    var threadsWithAuthoritativeLocalHistoryStart: Set<String> = [] {
        didSet { historyPagination.threadsWithAuthoritativeLocalHistoryStart = threadsWithAuthoritativeLocalHistoryStart }
    }
    var olderHistoryLoadErrorByThreadID: [String: String] = [:] {
        didSet { historyPagination.olderHistoryLoadErrorByThreadID = olderHistoryLoadErrorByThreadID }
    }
    @ObservationIgnored var subagentMetadataLoadingThreadIDs: Set<String> = [] {
        didSet { threadRegistry.subagentMetadataLoadingThreadIDs = subagentMetadataLoadingThreadIDs }
    }
    var resumedThreadIDs: Set<String> = [] {
        didSet { threadRegistry.resumedThreadIDs = resumedThreadIDs }
    }
    // Coalesces per-thread thread/read history fetches so reconcile work can await the same RPC.
    @ObservationIgnored var threadHistoryLoadTaskByThreadID: [String: Task<ThreadHistoryLoadOutcome, Error>] = [:] {
        didSet { threadRegistry.threadHistoryLoadTaskByThreadID = threadHistoryLoadTaskByThreadID }
    }
    // Lets a late force caller upgrade an in-flight history load without spawning another thread/read.
    @ObservationIgnored var forcedHistoryLoadThreadIDs: Set<String> = [] {
        didSet { threadRegistry.forcedHistoryLoadThreadIDs = forcedHistoryLoadThreadIDs }
    }
    // Preserves callers that need "not materialized" reads to keep retrying instead of marking hydrated.
    @ObservationIgnored var deferHydratedMarkForNotMaterializedThreadIDs: Set<String> = [] {
        didSet { threadRegistry.deferHydratedMarkForNotMaterializedThreadIDs = deferHydratedMarkForNotMaterializedThreadIDs }
    }
    // Coalesces per-thread resume work so rapid thread switches reuse the same in-flight refresh.
    @ObservationIgnored var threadResumeTaskByThreadID: [String: Task<CodexThread?, Error>] = [:] {
        didSet { threadRegistry.threadResumeTaskByThreadID = threadResumeTaskByThreadID }
    }
    // Remembers which cwd/model pair an in-flight resume is actually targeting.
    @ObservationIgnored var threadResumeRequestSignatureByThreadID: [String: CodexThreadResumeRequestSignature] = [:] {
        didSet { threadRegistry.threadResumeRequestSignatureByThreadID = threadResumeRequestSignatureByThreadID }
    }
    // Lets a late force caller upgrade an in-flight resume without spawning another RPC.
    @ObservationIgnored var forcedResumeEscalationThreadIDs: Set<String> = [] {
        didSet { threadRegistry.forcedResumeEscalationThreadIDs = forcedResumeEscalationThreadIDs }
    }
    // Coalesces running-state refreshes so foreground recovery cannot stampede the same thread.
    @ObservationIgnored var turnStateRefreshTaskByThreadID: [String: Task<Bool, Never>] = [:] {
        didSet { threadRegistry.turnStateRefreshTaskByThreadID = turnStateRefreshTaskByThreadID }
    }
    // Coalesces the full running-thread catch-up pipeline so open/foreground/reconnect share one path.
    @ObservationIgnored var runningThreadCatchupTaskByThreadID: [String: Task<RunningThreadCatchupOutcome, Never>] = [:] {
        didSet { threadRegistry.runningThreadCatchupTaskByThreadID = runningThreadCatchupTaskByThreadID }
    }
    // Lets a late foreground/open caller upgrade an in-flight running catch-up into a forced resume.
    @ObservationIgnored var forcedRunningCatchupEscalationThreadIDs: Set<String> = [] {
        didSet { threadRegistry.forcedRunningCatchupEscalationThreadIDs = forcedRunningCatchupEscalationThreadIDs }
    }
    // Invalidates stale async completions after archive/delete/reconnect tears refresh work down.
    @ObservationIgnored var threadRefreshGenerationByThreadID: [String: UInt64] = [:] {
        didSet { threadRegistry.threadRefreshGenerationByThreadID = threadRefreshGenerationByThreadID }
    }
    // Throttles expensive forced resumes while the user bounces between running chats.
    @ObservationIgnored var lastForcedRunningResumeAtByThread: [String: Date] = [:] {
        didSet { threadRegistry.lastForcedRunningResumeAtByThread = lastForcedRunningResumeAtByThread }
    }
    // Marks threads that used a lightweight running catch-up and still need one canonical history pass later.
    @ObservationIgnored var threadsNeedingCanonicalHistoryReconcile: Set<String> = [] {
        didSet { threadRegistry.threadsNeedingCanonicalHistoryReconcile = threadsNeedingCanonicalHistoryReconcile }
    }
    // Remembers which large closed chats already completed the one required canonical refresh after local-first paint.
    @ObservationIgnored var threadsWithSatisfiedDeferredHistoryHydration: Set<String> = [] {
        didSet { threadRegistry.threadsWithSatisfiedDeferredHistoryHydration = threadsWithSatisfiedDeferredHistoryHydration }
    }
    // Keeps post-run canonical reconcile work coalesced to one task per thread.
    @ObservationIgnored var canonicalHistoryReconcileTaskByThreadID: [String: Task<Void, Never>] = [:] {
        didSet { threadRegistry.canonicalHistoryReconcileTaskByThreadID = canonicalHistoryReconcileTaskByThreadID }
    }
    // Tracks delayed retry timers for canonical reconcile so teardown can cancel the backoff too.
    @ObservationIgnored var canonicalHistoryReconcileRetryTaskByThreadID: [String: Task<Void, Never>] = [:] {
        didSet { threadRegistry.canonicalHistoryReconcileRetryTaskByThreadID = canonicalHistoryReconcileRetryTaskByThreadID }
    }
    // Coalesces sidebar/bootstrap thread/list refreshes so launch paths do not duplicate the same fetch.
    @ObservationIgnored var threadListFetchTaskByLimit: [Int: (id: UUID, task: Task<[CodexThread], Error>)] = [:] {
        didSet { threadRegistry.threadListFetchTaskByLimit = threadListFetchTaskByLimit }
    }
    // Last OpenCode listThreads materialization cap overflow count surfaced by bridge meta.
    @ObservationIgnored var lastThreadListMaterializationBlocked: Int = 0 {
        didSet { modelSelection.lastThreadListMaterializationBlocked = lastThreadListMaterializationBlocked }
    }
    var isAppInForeground = true {
        didSet { connection.isAppInForeground = isAppInForeground }
    }
    // Network quality flag: when true, sync and keepalive intervals are stretched to reduce
    // bandwidth usage on constrained connections (Low Data Mode, hotspot tethering).
    var isConstrainedNetwork = false
    @ObservationIgnored var networkPathMonitor: NWPathMonitor?
    var threadListSyncTask: Task<Void, Never>? {
        didSet { connection.threadListSyncTask = threadListSyncTask }
    }
    var activeThreadSyncTask: Task<Void, Never>? {
        didSet { connection.activeThreadSyncTask = activeThreadSyncTask }
    }
    var runningThreadWatchSyncTask: Task<Void, Never>? {
        didSet { connection.runningThreadWatchSyncTask = runningThreadWatchSyncTask }
    }
    var postConnectSyncTask: Task<Void, Never>? {
        didSet { connection.postConnectSyncTask = postConnectSyncTask }
    }
    // Keeps the phone-side account UI in sync while ChatGPT login is being completed on the Mac.
    var gptAccountLoginSyncTask: Task<Void, Never>? {
        didSet { connection.gptAccountLoginSyncTask = gptAccountLoginSyncTask }
    }
    // Tracks whether the bridge is proxying a real Codex endpoint or a spawned local app-server.
    // (NOTE: postConnectSyncToken, connectedServerIdentity, codexTransportMode are now
    //  accessed through `connection.*` grouped state.)
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
    var runningThreadWatchByID: [String: CodexRunningThreadWatch] = [:] {
        didSet { threadRegistry.runningThreadWatchByID = runningThreadWatchByID }
    }
    var mirroredRunningCatchupThreadIDs: Set<String> = [] {
        didSet { threadRegistry.mirroredRunningCatchupThreadIDs = mirroredRunningCatchupThreadIDs }
    }
    var desktopMirroredRunningThreadIDs: Set<String> = [] {
        didSet { threadRegistry.desktopMirroredRunningThreadIDs = desktopMirroredRunningThreadIDs }
    }
    // Blocks desktop mirror/delta from re-marking a thread running after a local turn/start failure.
    var mirroredRunningSuppressedAfterTurnStartFailureThreadIDs: Set<String> = [] {
        didSet { threadRegistry.mirroredRunningSuppressedAfterTurnStartFailureThreadIDs = mirroredRunningSuppressedAfterTurnStartFailureThreadIDs }
    }
    var lastIncomingNotificationMethodByThread: [String: String] = [:] {
        didSet { threadRegistry.lastIncomingNotificationMethodByThread = lastIncomingNotificationMethodByThread }
    }
    var desktopMirroredRunningStaleSnapshotCountsByThread: [String: Int] = [:] {
        didSet { threadRegistry.desktopMirroredRunningStaleSnapshotCountsByThread = desktopMirroredRunningStaleSnapshotCountsByThread }
    }
    var desktopMirroredRunningLastActivityAtByThread: [String: Date] = [:] {
        didSet { threadRegistry.desktopMirroredRunningLastActivityAtByThread = desktopMirroredRunningLastActivityAtByThread }
    }
    var lastMirroredRunningCatchupAtByThread: [String: Date] = [:] {
        didSet { threadRegistry.lastMirroredRunningCatchupAtByThread = lastMirroredRunningCatchupAtByThread }
    }
    var localNetworkAuthorizationStatus: LocalNetworkAuthorizationStatus = .unknown {
        didSet { security.localNetworkAuthorizationStatus = localNetworkAuthorizationStatus }
    }
    var backgroundTurnGraceTaskID: UIBackgroundTaskIdentifier = .invalid {
        didSet { notifications.backgroundTurnGraceTaskID = backgroundTurnGraceTaskID }
    }
    var hasConfiguredNotifications = false {
        didSet { notifications.hasConfiguredNotifications = hasConfiguredNotifications }
    }
    var runCompletionNotificationDedupedAt: [String: Date] = [:] {
        didSet { notifications.runCompletionNotificationDedupedAt = runCompletionNotificationDedupedAt }
    }
    var structuredUserInputNotificationDedupedAt: [String: Date] = [:] {
        didSet { notifications.structuredUserInputNotificationDedupedAt = structuredUserInputNotificationDedupedAt }
    }
    var notificationCenterDelegateProxy: CodexNotificationCenterDelegateProxy? {
        didSet { notifications.notificationCenterDelegateProxy = notificationCenterDelegateProxy }
    }
    var notificationObserverTokens: [NSObjectProtocol] = [] {
        didSet { notifications.notificationObserverTokens = notificationObserverTokens }
    }
    var remoteNotificationDeviceToken: String? {
        didSet { notifications.remoteNotificationDeviceToken = remoteNotificationDeviceToken }
    }
    var lastPushRegistrationSignature: String? {
        didSet { notifications.lastPushRegistrationSignature = lastPushRegistrationSignature }
    }
    /// Set when APNs or relay push registration fails; surfaced in Settings notifications card.
    var pushRegistrationFailureMessage: String? {
        didSet { notifications.pushRegistrationFailureMessage = pushRegistrationFailureMessage }
    }
    // Test hook so connection handling can model `.inactive` without waiting for real app lifecycle changes.
    @ObservationIgnored var applicationStateProvider: () -> UIApplication.State = { UIApplication.shared.applicationState }
    var secureSession: CodexSecureSession? {
        didSet { security.secureSession = secureSession }
    }
    var pendingHandshake: CodexPendingHandshake? {
        didSet { security.pendingHandshake = pendingHandshake }
    }
    // Records the most recent successful secure handshake so post-init recovery can
    // distinguish trusted reconnects from fresh QR bootstrap.
    var lastCompletedSecureHandshakeMode: CodexSecureHandshakeMode? {
        didSet { security.lastCompletedSecureHandshakeMode = lastCompletedSecureHandshakeMode }
    }
    var phoneIdentityState: CodexPhoneIdentityState {
        didSet { security.phoneIdentityState = phoneIdentityState }
    }
    var trustedMacRegistry: CodexTrustedMacRegistry {
        didSet { security.trustedMacRegistry = trustedMacRegistry }
    }
    var currentTrustedMacDeviceId: String? {
        didSet { security.currentTrustedMacDeviceId = currentTrustedMacDeviceId }
    }
    var lastTrustedMacDeviceId: String? {
        didSet { security.lastTrustedMacDeviceId = lastTrustedMacDeviceId }
    }
    var previousTrustedMacDeviceId: String? {
        didSet { security.previousTrustedMacDeviceId = previousTrustedMacDeviceId }
    }
    @ObservationIgnored var macScopedContextOverrideDeviceId: String? {
        didSet { security.macScopedContextOverrideDeviceId = macScopedContextOverrideDeviceId }
    }
    @ObservationIgnored var suspendAutomaticMacScopedPersistence = false {
        didSet { security.suspendAutomaticMacScopedPersistence = suspendAutomaticMacScopedPersistence }
    }
    @ObservationIgnored var isApplyingMacScopedState = false {
        didSet { security.isApplyingMacScopedState = isApplyingMacScopedState }
    }
    var pendingSecureControlContinuations: [String: [CodexSecureControlWaiter]] = [:] {
        didSet { security.pendingSecureControlContinuations = pendingSecureControlContinuations }
    }
    var bufferedSecureControlMessages: [String: [String]] = [:] {
        didSet { security.bufferedSecureControlMessages = bufferedSecureControlMessages }
    }
    // Assistant-scoped patch ledger used by the revert-changes flow.
    var aiChangeSetsByID: [String: AIChangeSet] = [:] {
        didSet { gitRepo.aiChangeSetsByID = aiChangeSetsByID }
    }
    var aiChangeSetIDByTurnID: [String: String] = [:] {
        didSet { gitRepo.aiChangeSetIDByTurnID = aiChangeSetIDByTurnID }
    }
    var aiChangeSetIDByAssistantMessageID: [String: String] = [:] {
        didSet { gitRepo.aiChangeSetIDByAssistantMessageID = aiChangeSetIDByAssistantMessageID }
    }
    @ObservationIgnored var workspaceCheckpointCopyTaskByTurnID: [String: Task<Void, Never>] = [:] {
        didSet { gitRepo.workspaceCheckpointCopyTaskByTurnID = workspaceCheckpointCopyTaskByTurnID }
    }
    // Keeps hot-path thread lookups O(1) instead of rescanning the full sidebar list.
    @ObservationIgnored var threadByID: [String: CodexThread] = [:] {
        didSet { threadRegistry.threadByID = threadByID }
    }
    @ObservationIgnored var threadIndexByID: [String: Int] = [:] {
        didSet { threadRegistry.threadIndexByID = threadIndexByID }
    }
    @ObservationIgnored var firstLiveThreadIDCache: String? {
        didSet { threadRegistry.firstLiveThreadIDCache = firstLiveThreadIDCache }
    }
    @ObservationIgnored var subagentIdentityByThreadID: [String: CodexSubagentIdentityEntry] = [:] {
        didSet { threadRegistry.subagentIdentityByThreadID = subagentIdentityByThreadID }
    }
    @ObservationIgnored var subagentIdentityByAgentID: [String: CodexSubagentIdentityEntry] = [:] {
        didSet { threadRegistry.subagentIdentityByAgentID = subagentIdentityByAgentID }
    }
    // Canonical repo roots keyed by observed working directories from bridge git/status responses.
    var repoRootByWorkingDirectory: [String: String] = [:] {
        didSet { gitRepo.repoRootByWorkingDirectory = repoRootByWorkingDirectory }
    }
    var knownRepoRoots: Set<String> = [] {
        didSet { gitRepo.knownRepoRoots = knownRepoRoots }
    }
    // Phase callbacks for in-flight `git/runStackedAction` calls keyed by progressId.
    @ObservationIgnored var gitStackedActionProgressHandlers: [String: (TurnGitActionPhase, TurnGitActionPhaseStatus) -> Void] = [:] {
        didSet { gitRepo.gitStackedActionProgressHandlers = gitStackedActionProgressHandlers }
    }
    // Service-owned per-thread UI state keeps the active chat isolated from unrelated thread mutations.
    @ObservationIgnored var threadTimelineStateByThread: [String: ThreadTimelineState] = [:] {
        didSet { messageCache.threadTimelineStateByThread = threadTimelineStateByThread }
    }
    @ObservationIgnored var forkedFromThreadIDByThreadID: [String: String] = [:] {
        didSet { threadRegistry.forkedFromThreadIDByThreadID = forkedFromThreadIDByThreadID }
    }
    @ObservationIgnored var renamedThreadNameByThreadID: [String: String] = [:] {
        didSet { threadRegistry.renamedThreadNameByThreadID = renamedThreadNameByThreadID }
    }
    @ObservationIgnored var associatedManagedWorktreePathByThreadID: [String: String] = [:] {
        didSet { threadRegistry.associatedManagedWorktreePathByThreadID = associatedManagedWorktreePathByThreadID }
    }
    @ObservationIgnored var authoritativeProjectPathByThreadID: [String: String] = [:] {
        didSet { threadRegistry.authoritativeProjectPathByThreadID = authoritativeProjectPathByThreadID }
    }
    var pinnedThreadIDs: [String] = [] {
        didSet { threadRegistry.pinnedThreadIDs = pinnedThreadIDs }
    }
    @ObservationIgnored var pinnedThreadSnapshotsByRootID: [String: [CodexThread]] = [:] {
        didSet { threadRegistry.pinnedThreadSnapshotsByRootID = pinnedThreadSnapshotsByRootID }
    }
    @ObservationIgnored var snapshotOnlyPinnedThreadIDs: Set<String> = [] {
        didSet { threadRegistry.snapshotOnlyPinnedThreadIDs = snapshotOnlyPinnedThreadIDs }
    }
    @ObservationIgnored var stoppedTurnIDsByThread: [String: Set<String>] = [:] {
        didSet { messageCache.stoppedTurnIDsByThread = stoppedTurnIDsByThread }
    }
    // Lazily rebuilt id->index maps keep hot-path message lookups out of repeated linear scans.
    @ObservationIgnored var messageIndexCacheByThread: [String: [String: Int]] = [:] {
        didSet { messageCache.messageIndexCacheByThread = messageIndexCacheByThread }
    }
    @ObservationIgnored var latestAssistantOutputByThread: [String: String] = [:] {
        didSet { messageCache.latestAssistantOutputByThread = latestAssistantOutputByThread }
    }
    @ObservationIgnored var latestAssistantMessageIDByThread: [String: String] = [:] {
        didSet { messageCache.latestAssistantMessageIDByThread = latestAssistantMessageIDByThread }
    }
    @ObservationIgnored var latestRepoAffectingMessageSignalByThread: [String: String] = [:] {
        didSet { messageCache.latestRepoAffectingMessageSignalByThread = latestRepoAffectingMessageSignalByThread }
    }
    @ObservationIgnored var assistantRevertStateCacheByThread: [String: AssistantRevertStateCacheEntry] = [:] {
        didSet { messageCache.assistantRevertStateCacheByThread = assistantRevertStateCacheByThread }
    }
    @ObservationIgnored var assistantRevertStateRevision: Int = 0 {
        didSet { messageCache.assistantRevertStateRevision = assistantRevertStateRevision }
    }
    @ObservationIgnored var busyRepoRoots: Set<String> = [] {
        didSet { gitRepo.busyRepoRoots = busyRepoRoots }
    }
    @ObservationIgnored var busyRepoRootsRevision: Int = 0 {
        didSet { gitRepo.busyRepoRootsRevision = busyRepoRootsRevision }
    }
    @ObservationIgnored var pendingSystemDeltasByKey: [String: PendingSystemStreamingDeltas] = [:] {
        didSet { messageCache.pendingSystemDeltasByKey = pendingSystemDeltasByKey }
    }
    @ObservationIgnored var systemDeltaFlushTasksByKey: [String: Task<Void, Never>] = [:] {
        didSet { messageCache.systemDeltaFlushTasksByKey = systemDeltaFlushTasksByKey }
    }

    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let messagePersistence = CodexMessagePersistence()
    let composerDraftPersistence = CodexComposerDraftPersistence()
    let aiChangeSetPersistence = AIChangeSetPersistence()
    let defaults: UserDefaults
    let userNotificationCenter: CodexUserNotificationCentering
    var remoteNotificationRegistrar: CodexRemoteNotificationRegistering? {
        didSet { notifications.remoteNotificationRegistrar = remoteNotificationRegistrar }
    }

    static let selectedModelIdDefaultsKey = "codex.selectedModelId"
    static let selectedGitWriterModelIdDefaultsKey = "codex.selectedGitWriterModelId"
    static let selectedReasoningEffortDefaultsKey = "codex.selectedReasoningEffort"
    static let selectedServiceTierDefaultsKey = "codex.selectedServiceTier"
    static let threadRuntimeOverridesDefaultsKey = "codex.threadRuntimeOverrides"
    static let planSessionSourcesDefaultsKey = "codex.planSessionSources"
    static let selectedAccessModeDefaultsKey = "codex.selectedAccessMode"
    static let defaultOpenCodeAgentDefaultsKey = "codex.defaultOpenCodeAgent"
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
    static let openCodeExternalDiscoveryDefaultsKey = "codex.openCodeExternalDiscoveryEnabled"
    static let modelsErrorMessageByProviderDefaultsKey = "codex.modelsErrorMessageByProvider"

    // MARK: - Grouped State (Issue #9)
    // These struct instances group the ~130 flat properties into ~10 logical domains,
    // improving readability and making the state model navigable. Flat properties
    // remain the source of truth for @Observable; structs are seeded in init and
    // then kept in sync via property observers so new code can read from the grouped view.
    var connection = CodexConnectionState()
    var threadRegistry = CodexThreadRegistry()
    var messageCache = CodexMessageCache()
    var turnQueue = CodexTurnQueueState()
    var modelSelection = CodexModelSelectionState()
    var streaming = CodexStreamingState()
    var permissions = CodexPermissionState()
    var notifications = CodexNotificationState()
    var terminalState = CodexTerminalState()
    var security = CodexSecurityState()
    var gitRepo = CodexGitRepoState()
    var accountBridge = CodexAccountBridgeState()
    var historyPagination = CodexHistoryPaginationState()

    /// Seeds grouped structs from the flat state during initialization.
    /// After init, property observers keep the grouped copies in sync.
    private func seedGroupedState() {
        // ConnectionState
        connection.isConnected = isConnected
        connection.isConnecting = isConnecting
        connection.isInitialized = isInitialized
        connection.isBootstrappingConnectionSync = isBootstrappingConnectionSync
        connection.isLoadingThreads = isLoadingThreads
        connection.connectionRecoveryState = connectionRecoveryState
        connection.shouldAutoReconnectOnForeground = shouldAutoReconnectOnForeground
        connection.backgroundTurnGraceExpiredUntilForeground = backgroundTurnGraceExpiredUntilForeground
        connection.connectedServerIdentity = connectedServerIdentity
        connection.codexTransportMode = codexTransportMode
        connection.postConnectSyncToken = postConnectSyncToken
        connection.isAppInForeground = isAppInForeground
        connection.webSocketConnection = webSocketConnection
        connection.webSocketSession = webSocketSession
        connection.webSocketSessionDelegate = webSocketSessionDelegate
        connection.webSocketTask = webSocketTask
        connection.webSocketKeepAliveTask = webSocketKeepAliveTask
        connection.manualWebSocketReadBuffer = manualWebSocketReadBuffer
        connection.usesManualWebSocketTransport = usesManualWebSocketTransport
        connection.pendingRequests = pendingRequests
        connection.requestTransportOverride = requestTransportOverride
        connection.trustedSessionResolverOverride = trustedSessionResolverOverride
        connection.webSocketKeepAliveIntervalOverrideNanoseconds = webSocketKeepAliveIntervalOverrideNanoseconds
        connection.webSocketForegroundProbeTimeoutOverrideNanoseconds = webSocketForegroundProbeTimeoutOverrideNanoseconds
        connection.webSocketKeepAlivePingOverride = webSocketKeepAlivePingOverride
        connection.manualWebSocketDrainSequenceProbe = manualWebSocketDrainSequenceProbe
        connection.trustedSessionResolveTask = trustedSessionResolveTask
        connection.trustedSessionResolveTaskID = trustedSessionResolveTaskID
        connection.threadListSyncTask = threadListSyncTask
        connection.activeThreadSyncTask = activeThreadSyncTask
        connection.runningThreadWatchSyncTask = runningThreadWatchSyncTask
        connection.postConnectSyncTask = postConnectSyncTask
        connection.gptAccountLoginSyncTask = gptAccountLoginSyncTask

        // ThreadRegistry
        threadRegistry.threads = threads
        threadRegistry.activeThreadId = activeThreadId
        threadRegistry.activeTurnId = activeTurnId
        threadRegistry.activeTurnIdByThread = activeTurnIdByThread
        threadRegistry.runningThreadIDs = runningThreadIDs
        threadRegistry.protectedRunningFallbackThreadIDs = protectedRunningFallbackThreadIDs
        threadRegistry.readyThreadIDs = readyThreadIDs
        threadRegistry.failedThreadIDs = failedThreadIDs
        threadRegistry.latestTurnTerminalStateByThread = latestTurnTerminalStateByThread
        threadRegistry.terminalStateByTurnID = terminalStateByTurnID
        threadRegistry.hydratedThreadIDs = hydratedThreadIDs
        threadRegistry.loadingThreadIDs = loadingThreadIDs
        threadRegistry.resumedThreadIDs = resumedThreadIDs
        threadRegistry.threadIdByTurnID = threadIdByTurnID
        threadRegistry.planSessionSourceByThread = planSessionSourceByThread
        threadRegistry.runningThreadWatchByID = runningThreadWatchByID
        threadRegistry.mirroredRunningCatchupThreadIDs = mirroredRunningCatchupThreadIDs
        threadRegistry.desktopMirroredRunningThreadIDs = desktopMirroredRunningThreadIDs
        threadRegistry.mirroredRunningSuppressedAfterTurnStartFailureThreadIDs = mirroredRunningSuppressedAfterTurnStartFailureThreadIDs
        threadRegistry.lastIncomingNotificationMethodByThread = lastIncomingNotificationMethodByThread
        threadRegistry.desktopMirroredRunningStaleSnapshotCountsByThread = desktopMirroredRunningStaleSnapshotCountsByThread
        threadRegistry.desktopMirroredRunningLastActivityAtByThread = desktopMirroredRunningLastActivityAtByThread
        threadRegistry.lastMirroredRunningCatchupAtByThread = lastMirroredRunningCatchupAtByThread
        threadRegistry.subagentMetadataLoadingThreadIDs = subagentMetadataLoadingThreadIDs
        threadRegistry.threadResumeTaskByThreadID = threadResumeTaskByThreadID
        threadRegistry.threadResumeRequestSignatureByThreadID = threadResumeRequestSignatureByThreadID
        threadRegistry.threadHistoryLoadTaskByThreadID = threadHistoryLoadTaskByThreadID
        threadRegistry.forcedHistoryLoadThreadIDs = forcedHistoryLoadThreadIDs
        threadRegistry.deferHydratedMarkForNotMaterializedThreadIDs = deferHydratedMarkForNotMaterializedThreadIDs
        threadRegistry.threadRefreshGenerationByThreadID = threadRefreshGenerationByThreadID
        threadRegistry.lastForcedRunningResumeAtByThread = lastForcedRunningResumeAtByThread
        threadRegistry.threadsNeedingCanonicalHistoryReconcile = threadsNeedingCanonicalHistoryReconcile
        threadRegistry.threadsWithSatisfiedDeferredHistoryHydration = threadsWithSatisfiedDeferredHistoryHydration
        threadRegistry.canonicalHistoryReconcileTaskByThreadID = canonicalHistoryReconcileTaskByThreadID
        threadRegistry.canonicalHistoryReconcileRetryTaskByThreadID = canonicalHistoryReconcileRetryTaskByThreadID
        threadRegistry.forcedResumeEscalationThreadIDs = forcedResumeEscalationThreadIDs
        threadRegistry.forcedRunningCatchupEscalationThreadIDs = forcedRunningCatchupEscalationThreadIDs
        threadRegistry.threadListFetchTaskByLimit = threadListFetchTaskByLimit
        threadRegistry.threadByID = threadByID
        threadRegistry.threadIndexByID = threadIndexByID
        threadRegistry.firstLiveThreadIDCache = firstLiveThreadIDCache
        threadRegistry.subagentIdentityByThreadID = subagentIdentityByThreadID
        threadRegistry.subagentIdentityByAgentID = subagentIdentityByAgentID
        threadRegistry.subagentIdentityVersion = subagentIdentityVersion
        threadRegistry.turnStateRefreshTaskByThreadID = turnStateRefreshTaskByThreadID
        threadRegistry.runningThreadCatchupTaskByThreadID = runningThreadCatchupTaskByThreadID
        threadRegistry.threadTimelineStateByThread = threadTimelineStateByThread
        threadRegistry.forkedFromThreadIDByThreadID = forkedFromThreadIDByThreadID
        threadRegistry.renamedThreadNameByThreadID = renamedThreadNameByThreadID
        threadRegistry.associatedManagedWorktreePathByThreadID = associatedManagedWorktreePathByThreadID
        threadRegistry.authoritativeProjectPathByThreadID = authoritativeProjectPathByThreadID
        threadRegistry.pinnedThreadIDs = pinnedThreadIDs
        threadRegistry.pinnedThreadSnapshotsByRootID = pinnedThreadSnapshotsByRootID
        threadRegistry.snapshotOnlyPinnedThreadIDs = snapshotOnlyPinnedThreadIDs
        threadRegistry.stoppedTurnIDsByThread = stoppedTurnIDsByThread

        // MessageCache
        messageCache.messagesByThread = messagesByThread
        messageCache.messageRevisionByThread = messageRevisionByThread
        messageCache.threadTimelineStateByThread = threadTimelineStateByThread
        messageCache.messageIndexCacheByThread = messageIndexCacheByThread
        messageCache.latestAssistantOutputByThread = latestAssistantOutputByThread
        messageCache.latestAssistantMessageIDByThread = latestAssistantMessageIDByThread
        messageCache.latestRepoAffectingMessageSignalByThread = latestRepoAffectingMessageSignalByThread
        messageCache.assistantRevertStateCacheByThread = assistantRevertStateCacheByThread
        messageCache.assistantRevertStateRevision = assistantRevertStateRevision
        messageCache.stoppedTurnIDsByThread = stoppedTurnIDsByThread
        messageCache.pendingSystemDeltasByKey = pendingSystemDeltasByKey
        messageCache.systemDeltaFlushTasksByKey = systemDeltaFlushTasksByKey
        messageCache.recentActivityLineByThread = recentActivityLineByThread
        messageCache.contextWindowUsageByThread = contextWindowUsageByThread
        messageCache.rateLimitBuckets = rateLimitBuckets
        messageCache.hasResolvedRateLimitsSnapshot = hasResolvedRateLimitsSnapshot
        messageCache.isLoadingRateLimits = isLoadingRateLimits
        messageCache.rateLimitsErrorMessage = rateLimitsErrorMessage

        // TurnQueue
        turnQueue.queuedTurnDraftsByThread = queuedTurnDraftsByThread
        turnQueue.queuePauseStateByThread = queuePauseStateByThread
        turnQueue.composerDraftsByThreadID = composerDraftsByThreadID
        turnQueue.pendingComposerActionByThreadID = pendingComposerActionByThreadID
        turnQueue.threadsPendingCompletionHaptic = threadsPendingCompletionHaptic
        turnQueue.threadCompletionBanner = threadCompletionBanner
        turnQueue.missingNotificationThreadPrompt = missingNotificationThreadPrompt
        turnQueue.lastOutgoingSendDedupeSnapshot = lastOutgoingSendDedupeSnapshot
        turnQueue.lastRawMessage = lastRawMessage
        turnQueue.lastErrorMessage = lastErrorMessage

        // ModelSelection
        modelSelection.availableModels = availableModels
        modelSelection.selectedModelId = selectedModelId
        modelSelection.hasPersistedSelectedModelId = hasPersistedSelectedModelId
        modelSelection.selectedGitWriterModelId = selectedGitWriterModelId
        modelSelection.selectedReasoningEffort = selectedReasoningEffort
        modelSelection.selectedServiceTier = selectedServiceTier
        modelSelection.threadRuntimeOverridesByThreadID = threadRuntimeOverridesByThreadID
        modelSelection.selectedAccessMode = selectedAccessMode
        modelSelection.defaultOpenCodeAgentId = defaultOpenCodeAgentId
        modelSelection.availableAgents = availableAgents
        modelSelection.availableRuntimes = availableRuntimes
        modelSelection.slashCommandCacheByDirectory = slashCommandCacheByDirectory
        modelSelection.isLoadingModels = isLoadingModels
        modelSelection.pendingRuntimeOptionRefresh = pendingRuntimeOptionRefresh
        modelSelection.runtimeOptionRefreshTask = runtimeOptionRefreshTask
        modelSelection.runtimeOptionRefreshToken = runtimeOptionRefreshToken
        modelSelection.lastOpenCodeCatalogRevision = lastOpenCodeCatalogRevision
        modelSelection.catalogRefetchDebounceTask = catalogRefetchDebounceTask
        modelSelection.modelsErrorMessageByProvider = modelsErrorMessageByProvider
        modelSelection.lastModelListOpenCodeMeta = lastModelListOpenCodeMeta
        modelSelection.openCodeModelRetryCount = openCodeModelRetryCount
        modelSelection.openCodeModelsRetryTask = openCodeModelsRetryTask
        modelSelection.lastThreadListMaterializationBlocked = lastThreadListMaterializationBlocked

        // Streaming
        streaming.streamingAssistantFallbackMessageByTurnID = streamingAssistantFallbackMessageByTurnID
        streaming.streamingAssistantMessageByItemKey = streamingAssistantMessageByItemKey
        streaming.streamingSystemMessageByItemID = streamingSystemMessageByItemID
        streaming.commandExecutionDetailsByItemID = commandExecutionDetailsByItemID
        streaming.messagePersistenceDebounceTask = messagePersistenceDebounceTask
        streaming.pendingAssistantDeltaByStreamID = pendingAssistantDeltaByStreamID
        streaming.pendingAssistantDeltaContextByStreamID = pendingAssistantDeltaContextByStreamID
        streaming.pendingAssistantDeltaStreamOrder = pendingAssistantDeltaStreamOrder
        streaming.pendingAssistantDeltaFlushTask = pendingAssistantDeltaFlushTask
        streaming.coalescedRevertRefreshTask = coalescedRevertRefreshTask
        streaming.assistantCompletionFingerprintByThread = assistantCompletionFingerprintByThread
        streaming.assistantCompletionFingerprintByTurn = assistantCompletionFingerprintByTurn
        streaming.deferredSyncTasks = deferredSyncTasks
        streaming.currentOutput = currentOutput

        // Permissions
        permissions.pendingApprovals = pendingApprovals
        permissions.pendingOpenCodePermissions = pendingOpenCodePermissions
        permissions.sessionGrantedOpenCodeTools = sessionGrantedOpenCodeTools
        permissions.openCodePermissionsUIEnabledOverride = openCodePermissionsUIEnabledOverride

        // Notifications
        notifications.notificationAuthorizationStatus = notificationAuthorizationStatus
        notifications.pendingNotificationOpenThreadID = pendingNotificationOpenThreadID
        notifications.hasConfiguredNotifications = hasConfiguredNotifications
        notifications.runCompletionNotificationDedupedAt = runCompletionNotificationDedupedAt
        notifications.structuredUserInputNotificationDedupedAt = structuredUserInputNotificationDedupedAt
        notifications.notificationCenterDelegateProxy = notificationCenterDelegateProxy
        notifications.notificationObserverTokens = notificationObserverTokens
        notifications.remoteNotificationDeviceToken = remoteNotificationDeviceToken
        notifications.lastPushRegistrationSignature = lastPushRegistrationSignature
        notifications.pushRegistrationFailureMessage = pushRegistrationFailureMessage
        notifications.backgroundTurnGraceTaskID = backgroundTurnGraceTaskID
        notifications.remoteNotificationRegistrar = remoteNotificationRegistrar

        // TerminalState
        terminalState.terminalSnapshot = terminalSnapshot
        terminalState.terminalSnapshotsById = terminalSnapshotsById
        terminalState.terminalProfile = terminalProfile
        terminalState.nativeSSHTerminalsById = nativeSSHTerminalsById

        // Security
        security.relaySessionId = relaySessionId
        security.relayUrl = relayUrl
        security.relayMacDeviceId = relayMacDeviceId
        security.relayMacIdentityPublicKey = relayMacIdentityPublicKey
        security.relayProtocolVersion = relayProtocolVersion
        security.lastAppliedBridgeOutboundSeq = lastAppliedBridgeOutboundSeq
        security.secureConnectionState = secureConnectionState
        security.secureMacFingerprint = secureMacFingerprint
        security.shouldForceQRBootstrapOnNextHandshake = shouldForceQRBootstrapOnNextHandshake
        security.trustedReconnectFailureCount = trustedReconnectFailureCount
        security.secureSession = secureSession
        security.pendingHandshake = pendingHandshake
        security.lastCompletedSecureHandshakeMode = lastCompletedSecureHandshakeMode
        security.pendingSecureControlContinuations = pendingSecureControlContinuations
        security.bufferedSecureControlMessages = bufferedSecureControlMessages
        security.localNetworkAuthorizationStatus = localNetworkAuthorizationStatus
        security.phoneIdentityState = phoneIdentityState
        security.trustedMacRegistry = trustedMacRegistry
        security.currentTrustedMacDeviceId = currentTrustedMacDeviceId
        security.lastTrustedMacDeviceId = lastTrustedMacDeviceId
        security.previousTrustedMacDeviceId = previousTrustedMacDeviceId
        security.macScopedContextOverrideDeviceId = macScopedContextOverrideDeviceId
        security.suspendAutomaticMacScopedPersistence = suspendAutomaticMacScopedPersistence
        security.isApplyingMacScopedState = isApplyingMacScopedState

        // GitRepo
        gitRepo.repoRootByWorkingDirectory = repoRootByWorkingDirectory
        gitRepo.knownRepoRoots = knownRepoRoots
        gitRepo.gitStackedActionProgressHandlers = gitStackedActionProgressHandlers
        gitRepo.aiChangeSetsByID = aiChangeSetsByID
        gitRepo.aiChangeSetIDByTurnID = aiChangeSetIDByTurnID
        gitRepo.aiChangeSetIDByAssistantMessageID = aiChangeSetIDByAssistantMessageID
        gitRepo.workspaceCheckpointCopyTaskByTurnID = workspaceCheckpointCopyTaskByTurnID
        gitRepo.busyRepoRoots = busyRepoRoots
        gitRepo.busyRepoRootsRevision = busyRepoRootsRevision

        // AccountBridge
        accountBridge.gptAccountSnapshot = gptAccountSnapshot
        accountBridge.gptAccountErrorMessage = gptAccountErrorMessage
        accountBridge.bridgeInstalledVersion = bridgeInstalledVersion
        accountBridge.latestBridgePackageVersion = latestBridgePackageVersion
        accountBridge.bridgeUpdatePrompt = bridgeUpdatePrompt
        accountBridge.lastPresentedAvailableBridgePackageVersion = lastPresentedAvailableBridgePackageVersion
        accountBridge.hasPresentedServiceTierBridgeUpdatePrompt = hasPresentedServiceTierBridgeUpdatePrompt
        accountBridge.hasPresentedThreadForkBridgeUpdatePrompt = hasPresentedThreadForkBridgeUpdatePrompt
        accountBridge.hasPresentedMinimumBridgePackageUpdatePrompt = hasPresentedMinimumBridgePackageUpdatePrompt
        accountBridge.keepMacAwakeWhileBridgeRuns = keepMacAwakeWhileBridgeRuns
        accountBridge.runtimeDebugLogEntries = runtimeDebugLogEntries
        accountBridge.supportsStructuredSkillInput = supportsStructuredSkillInput
        accountBridge.supportsStructuredMentionInput = supportsStructuredMentionInput
        accountBridge.supportsTurnCollaborationMode = supportsTurnCollaborationMode
        accountBridge.supportsServiceTier = supportsServiceTier
        accountBridge.supportsBridgeVoiceTranscription = supportsBridgeVoiceTranscription
        accountBridge.supportsThreadFork = supportsThreadFork
        accountBridge.supportsTurnPagination = supportsTurnPagination
        accountBridge.syncRealtimeEnabled = syncRealtimeEnabled

        // HistoryPagination
        historyPagination.olderThreadHistoryCursorByThreadID = olderThreadHistoryCursorByThreadID
        historyPagination.exhaustedOlderThreadHistoryCursorByThreadID = exhaustedOlderThreadHistoryCursorByThreadID
        historyPagination.loadingOlderThreadHistoryIDs = loadingOlderThreadHistoryIDs
        historyPagination.threadTimelineProjectionLimitByThreadID = threadTimelineProjectionLimitByThreadID
        historyPagination.initialTurnsLoadedByThreadID = initialTurnsLoadedByThreadID
        historyPagination.threadsWithAuthoritativeLocalHistoryStart = threadsWithAuthoritativeLocalHistoryStart
        historyPagination.olderHistoryLoadErrorByThreadID = olderHistoryLoadErrorByThreadID
    }

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

        let savedDefaultAgent = defaults.string(forKey: Self.defaultOpenCodeAgentDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultOpenCodeAgentId = (savedDefaultAgent?.isEmpty == false) ? savedDefaultAgent : nil

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
        loadPersistedSlashCommandCache()
        loadPersistedModelsErrorMessages()
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
        seedGroupedState()
        startNetworkPathMonitor()
    }

    func startNetworkPathMonitor() {
        networkPathMonitor?.cancel()
        let monitor = NWPathMonitor()
        networkPathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isConstrainedNetwork != constrained {
                    self.isConstrainedNetwork = constrained
                    if self.isConnected, self.isInitialized {
                        self.startSyncLoop()
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "CodexMobile.NetworkPathMonitor", qos: .utility))
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

    deinit {
        MainActor.assumeIsolated {
            networkPathMonitor?.cancel()
            trustedSessionResolveTask?.cancel()
            messagePersistenceDebounceTask?.cancel()
            coalescedRevertRefreshTask?.cancel()
            threadListSyncTask?.cancel()
            activeThreadSyncTask?.cancel()
            runningThreadWatchSyncTask?.cancel()
            postConnectSyncTask?.cancel()
            gptAccountLoginSyncTask?.cancel()
            runtimeOptionRefreshTask?.cancel()
            catalogRefetchDebounceTask?.cancel()
            openCodeModelsRetryTask?.cancel()
            webSocketKeepAliveTask?.cancel()
            pendingAssistantDeltaFlushTask?.cancel()

            deferredSyncTasks.values.forEach { $0.cancel() }
            deferredSyncTasks.removeAll()

            threadHistoryLoadTaskByThreadID.values.forEach { $0.cancel() }
            threadHistoryLoadTaskByThreadID.removeAll()

            threadResumeTaskByThreadID.values.forEach { $0.cancel() }
            threadResumeTaskByThreadID.removeAll()

            turnStateRefreshTaskByThreadID.values.forEach { $0.cancel() }
            turnStateRefreshTaskByThreadID.removeAll()

            runningThreadCatchupTaskByThreadID.values.forEach { $0.cancel() }
            runningThreadCatchupTaskByThreadID.removeAll()

            canonicalHistoryReconcileTaskByThreadID.values.forEach { $0.cancel() }
            canonicalHistoryReconcileTaskByThreadID.removeAll()

            canonicalHistoryReconcileRetryTaskByThreadID.values.forEach { $0.cancel() }
            canonicalHistoryReconcileRetryTaskByThreadID.removeAll()

            threadListFetchTaskByLimit.values.forEach { $0.task.cancel() }
            threadListFetchTaskByLimit.removeAll()

            workspaceCheckpointCopyTaskByTurnID.values.forEach { $0.cancel() }
            workspaceCheckpointCopyTaskByTurnID.removeAll()

            systemDeltaFlushTasksByKey.values.forEach { $0.cancel() }
            systemDeltaFlushTasksByKey.removeAll()

            // Also cancel tasks referenced from grouped state structs (Issue #9).
            // These reference the same Task objects as the flat properties above,
            // so cancellation is idempotent and ensures no leaks through either path.
            modelSelection.runtimeOptionRefreshTask?.cancel()
            modelSelection.catalogRefetchDebounceTask?.cancel()
            modelSelection.openCodeModelsRetryTask?.cancel()
            connection.webSocketKeepAliveTask?.cancel()
            streaming.pendingAssistantDeltaFlushTask?.cancel()
            streaming.deferredSyncTasks.values.forEach { $0.cancel() }
            streaming.deferredSyncTasks.removeAll()

            threadRegistry.threadHistoryLoadTaskByThreadID.values.forEach { $0.cancel() }
            threadRegistry.threadHistoryLoadTaskByThreadID.removeAll()
            threadRegistry.threadResumeTaskByThreadID.values.forEach { $0.cancel() }
            threadRegistry.threadResumeTaskByThreadID.removeAll()
            threadRegistry.canonicalHistoryReconcileTaskByThreadID.values.forEach { $0.cancel() }
            threadRegistry.canonicalHistoryReconcileTaskByThreadID.removeAll()
            threadRegistry.canonicalHistoryReconcileRetryTaskByThreadID.values.forEach { $0.cancel() }
            threadRegistry.canonicalHistoryReconcileRetryTaskByThreadID.removeAll()
            threadRegistry.threadListFetchTaskByLimit.values.forEach { $0.task.cancel() }
            threadRegistry.threadListFetchTaskByLimit.removeAll()

            streaming.messagePersistenceDebounceTask?.cancel()
            streaming.coalescedRevertRefreshTask?.cancel()
            streaming.pendingAssistantDeltaFlushTask?.cancel()
            streaming.deferredSyncTasks.values.forEach { $0.cancel() }
            streaming.deferredSyncTasks.removeAll()

            gitRepo.workspaceCheckpointCopyTaskByTurnID.values.forEach { $0.cancel() }
            gitRepo.workspaceCheckpointCopyTaskByTurnID.removeAll()

            messageCache.systemDeltaFlushTasksByKey.values.forEach { $0.cancel() }
            messageCache.systemDeltaFlushTasksByKey.removeAll()

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
