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

struct CodexSecureControlWaiter {
    let id: UUID
    let continuation: CheckedContinuation<String, Error>
}


enum CodexThreadRunBadgeState: Equatable, Sendable {
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

@MainActor
@Observable
final class CodexService {
    // --- Public state ---------------------------------------------------------

    var threads: [CodexThread] = []
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

    var compactingThreadIDs: Set<String> = []
    var runningThreadIDs: Set<String> = []
    // Protects active runs that are real but have not yielded a stable turnId yet.
    var protectedRunningFallbackThreadIDs: Set<String> = []
    var readyThreadIDs: Set<String> = []
    var failedThreadIDs: Set<String> = []
    // Keeps the latest terminal outcome per thread so UI can react to real run completion.
    var latestTurnTerminalStateByThread: [String: CodexTurnTerminalState] = [:]
    // Preserves terminal outcome per turn so completed/stopped blocks stay distinguishable.
    var terminalStateByTurnID: [String: CodexTurnTerminalState] = [:]
    var pendingApproval: CodexApprovalRequest?
    var lastRawMessage: String?
    var lastErrorMessage: String?
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
    var selectedAccessMode: CodexAccessMode = .onRequest
    var isLoadingModels = false
    var modelsErrorMessage: String?
    var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    var pendingNotificationOpenThreadID: String?
    var supportsStructuredSkillInput = true
    // Runtime compatibility flag for `turn/start.collaborationMode` plan turns.
    var supportsTurnCollaborationMode = false

    // Relay session persistence
    var relaySessionId: String?
    var relayUrl: String?
    var relayMacDeviceId: String?
    var relayMacIdentityPublicKey: String?
    var relayProtocolVersion: Int = codexSecureProtocolVersion
    var lastAppliedBridgeOutboundSeq = 0
    var secureConnectionState: CodexSecureConnectionState = .notPaired
    var secureMacFingerprint: String?

    // --- Internal wiring ------------------------------------------------------

    var webSocketConnection: NWConnection?
    let webSocketQueue = DispatchQueue(label: "CodexMobile.WebSocket", qos: .userInitiated)
    var pendingRequests: [String: CheckedContinuation<RPCMessage, Error>] = [:]
    // Test hook: intercepts outbound RPC requests without requiring a live socket.
    @ObservationIgnored var requestTransportOverride: ((String, JSONValue?) async throws -> RPCMessage)?
    var streamingAssistantMessageByTurnID: [String: String] = [:]
    var streamingSystemMessageByItemID: [String: String] = [:]
    /// Rich metadata for command execution tool calls, keyed by itemId.
    var commandExecutionDetailsByItemID: [String: CommandExecutionDetails] = [:]
    // Debounces disk writes while streaming to keep UI responsive.
    var messagePersistenceDebounceTask: Task<Void, Never>?
    // Dedupes completion payloads when servers omit turn/item identifiers.
    var assistantCompletionFingerprintByThread: [String: (text: String, timestamp: Date)] = [:]
    // Dedupes concise activity feed lines per thread/turn to avoid visual spam.
    var recentActivityLineByThread: [String: CodexRecentActivityLine] = [:]
    var contextWindowUsageByThread: [String: ContextWindowUsage] = [:]
    var threadIdByTurnID: [String: String] = [:]
    var hydratedThreadIDs: Set<String> = []
    var loadingThreadIDs: Set<String> = []
    var resumedThreadIDs: Set<String> = []
    var isAppInForeground = true
    var threadListSyncTask: Task<Void, Never>?
    var activeThreadSyncTask: Task<Void, Never>?
    var runningThreadWatchSyncTask: Task<Void, Never>?
    var postConnectSyncTask: Task<Void, Never>?
    var postConnectSyncToken: UUID?
    var connectedServerIdentity: String?
    var runningThreadWatchByID: [String: CodexRunningThreadWatch] = [:]
    var backgroundTurnGraceTaskID: UIBackgroundTaskIdentifier = .invalid
    var hasConfiguredNotifications = false
    var runCompletionNotificationDedupedAt: [String: Date] = [:]
    var notificationCenterDelegateProxy: CodexNotificationCenterDelegateProxy?
    var shouldAutoReconnectOnForeground = false
    var secureSession: CodexSecureSession?
    var pendingHandshake: CodexPendingHandshake?
    var phoneIdentityState: CodexPhoneIdentityState
    var trustedMacRegistry: CodexTrustedMacRegistry
    var pendingSecureControlContinuations: [String: [CodexSecureControlWaiter]] = [:]
    var bufferedSecureControlMessages: [String: [String]] = [:]
    // Assistant-scoped patch ledger used by the revert-changes flow.
    var aiChangeSetsByID: [String: AIChangeSet] = [:]
    var aiChangeSetIDByTurnID: [String: String] = [:]
    var aiChangeSetIDByAssistantMessageID: [String: String] = [:]
    // Canonical repo roots keyed by observed working directories from bridge git/status responses.
    var repoRootByWorkingDirectory: [String: String] = [:]
    var knownRepoRoots: Set<String> = []

    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let messagePersistence = CodexMessagePersistence()
    let aiChangeSetPersistence = AIChangeSetPersistence()
    let defaults: UserDefaults
    let userNotificationCenter: CodexUserNotificationCentering

    static let selectedModelIdDefaultsKey = "codex.selectedModelId"
    static let selectedReasoningEffortDefaultsKey = "codex.selectedReasoningEffort"
    static let selectedAccessModeDefaultsKey = "codex.selectedAccessMode"
    static let locallyArchivedThreadIDsKey = "codex.locallyArchivedThreadIDs"
    static let notificationsPromptedDefaultsKey = "codex.notifications.prompted"

    init(
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        defaults: UserDefaults = .standard,
        userNotificationCenter: CodexUserNotificationCentering = UNUserNotificationCenter.current()
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.defaults = defaults
        self.userNotificationCenter = userNotificationCenter
        self.phoneIdentityState = codexPhoneIdentityStateFromSecureStore()
        self.trustedMacRegistry = codexTrustedMacRegistryFromSecureStore()
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

        if let savedAccessMode = defaults.string(forKey: Self.selectedAccessModeDefaultsKey),
           let parsedAccessMode = CodexAccessMode(rawValue: savedAccessMode) {
            self.selectedAccessMode = parsedAccessMode
        } else {
            self.selectedAccessMode = .onRequest
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
        if let relayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[relayMacDeviceId] {
            self.secureConnectionState = .trustedMac
            self.secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        }
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
