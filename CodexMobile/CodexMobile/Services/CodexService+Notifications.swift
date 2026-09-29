// FILE: CodexService+Notifications.swift
// Purpose: Manages local notification permission, background run-completion alerts, and tap routing.
// Layer: Service
// Exports: CodexService notification helpers
// Depends on: UserNotifications, UIKit, CodexService+Messages

import Foundation
import UIKit
import UserNotifications

private enum CodexNotificationSource {
    static let runCompletion = "codex.runCompletion"
    static let structuredUserInput = "codex.structuredUserInput"
}

protocol CodexRemoteNotificationRegistering: AnyObject {
    @MainActor
    func registerForRemoteNotifications()
}

final class CodexApplicationRemoteNotificationRegistrar: CodexRemoteNotificationRegistering {
    // Requests the APNs device token once alert permission is no longer denied.
    @MainActor
    func registerForRemoteNotifications() {
#if targetEnvironment(simulator)
        return
#else
        UIApplication.shared.registerForRemoteNotifications()
#endif
    }
}

private enum CodexPushAPNsEnvironment: String {
    case development
    case production
}

protocol CodexUserNotificationCentering: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func authorizationStatus() async -> UNAuthorizationStatus
}

extension UNUserNotificationCenter: CodexUserNotificationCentering {
    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await notificationSettings()
        return settings.authorizationStatus
    }
}

final class CodexNotificationCenterDelegateProxy: NSObject, UNUserNotificationCenterDelegate {
    weak var service: CodexService?

    init(service: CodexService) {
        self.service = service
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A completion queued while Control Center or another app covered the
        // timeline must remain visible even if iOS delivers it after reactivation.
        if (notification.request.content.userInfo[CodexNotificationPayloadKeys.presentWhenActive] as? NSNumber)?.boolValue == true {
            return [.banner, .sound]
        }
        // ScenePhase can remain `.inactive` during a lock or app switch. In that
        // transition the timeline is no longer visible, even if UIKit still
        // routes the notification through the foreground delegate.
        let isVisible = await MainActor.run {
            service?.isAppInForeground == true && service?.applicationStateProvider() == .active
        }
        return isVisible ? [] : [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let service,
              let payload = CodexThreadNotificationPayload(from: response.notification.request.content.userInfo) else {
            return
        }

        await MainActor.run {
            service.handleNotificationOpen(threadId: payload.threadId, turnId: payload.turnId)
        }
    }
}

private struct CodexThreadNotificationPayload {
    let threadId: String
    let turnId: String?

    init?(from userInfo: [AnyHashable: Any]) {
        guard let source = userInfo[CodexNotificationPayloadKeys.source] as? String,
              (source == CodexNotificationSource.runCompletion
                || source == CodexNotificationSource.structuredUserInput),
              let threadId = userInfo[CodexNotificationPayloadKeys.threadId] as? String,
              !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        self.threadId = threadId
        self.turnId = userInfo[CodexNotificationPayloadKeys.turnId] as? String
    }
}

extension CodexService {
    // Wires the UNUserNotificationCenter delegate once so taps can reopen the right thread.
    func configureNotifications() {
        guard !hasConfiguredNotifications else {
            return
        }

        if remoteNotificationRegistrar == nil {
            remoteNotificationRegistrar = CodexApplicationRemoteNotificationRegistrar()
        }
        let delegateProxy = CodexNotificationCenterDelegateProxy(service: self)
        notificationCenterDelegateProxy = delegateProxy
        userNotificationCenter.delegate = delegateProxy
        configureRemoteNotificationObservers()
        hasConfiguredNotifications = true

        Task { @MainActor [weak self] in
            await self?.refreshManagedNotificationRegistrationState()
        }
    }

    // Requests notification permission once on first launch, while still allowing manual retry from Settings.
    func requestNotificationPermissionOnFirstLaunchIfNeeded() async {
        let promptedAlready = defaults.bool(forKey: Self.notificationsPromptedDefaultsKey)
        guard !promptedAlready else {
            await refreshManagedNotificationRegistrationState()
            return
        }

        await requestNotificationPermission(markPrompted: true)
    }

    // Used by: SettingsView, CodexMobileApp
    func requestNotificationPermission(markPrompted: Bool = true) async {
        do {
            _ = try await userNotificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            debugRuntimeLog("notification permission request failed: \(error.localizedDescription)")
        }

        if markPrompted {
            defaults.set(true, forKey: Self.notificationsPromptedDefaultsKey)
        }

        await refreshManagedNotificationRegistrationState()
    }

    func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await userNotificationCenter.authorizationStatus()
    }

    // Re-checks permission, APNs token registration, and bridge sync after app launch or Settings changes.
    func refreshManagedNotificationRegistrationState() async {
        await refreshNotificationAuthorizationStatus()
        await registerForRemoteNotificationsIfAllowed()
        await syncManagedPushRegistrationIfNeeded(force: true)
    }

    // Registers with APNs only after the user has not explicitly denied alert notifications.
    func registerForRemoteNotificationsIfAllowed() async {
        guard notificationAuthorizationStatus != .denied,
              notificationAuthorizationStatus != .notDetermined else {
            await syncManagedPushRegistrationIfNeeded(force: true)
            return
        }

        remoteNotificationRegistrar?.registerForRemoteNotifications()
    }

    // Persists the APNs token and syncs it to the paired bridge when possible.
    func handleRemoteNotificationDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else {
            return
        }

        remoteNotificationDeviceToken = token
        SecureStore.writeString(token, for: CodexSecureKeys.pushDeviceToken)

        Task { @MainActor [weak self] in
            await self?.syncManagedPushRegistrationIfNeeded(force: true)
        }
    }

    // Push token sync is best-effort so reconnects stay resilient if the managed backend is unavailable.
    func syncManagedPushRegistrationIfNeeded(force: Bool = false) async {
        guard isConnected, isInitialized else {
            return
        }

        let normalizedToken = remoteNotificationDeviceToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedToken, !normalizedToken.isEmpty else {
            completionPushSessionID = nil
            return
        }

        let alertsEnabled = canScheduleRunCompletionNotifications
        let authorizationStatus = notificationAuthorizationStatus.pushRegistrationValue
        let signature = [
            normalizedRelaySessionId ?? "",
            normalizedToken,
            alertsEnabled ? "1" : "0",
            authorizationStatus,
            pushAPNsEnvironment.rawValue,
        ].joined(separator: "|")

        guard force || lastPushRegistrationSignature != signature else {
            return
        }

        let params: JSONValue = .object([
            "deviceToken": .string(normalizedToken),
            "alertsEnabled": .bool(alertsEnabled),
            "authorizationStatus": .string(authorizationStatus),
            "appEnvironment": .string(pushAPNsEnvironment.rawValue),
        ])

        let registrationSessionID = normalizedRelaySessionId
        pushRegistrationGeneration += 1
        let registrationGeneration = pushRegistrationGeneration
        do {
            let response = try await sendRequest(method: "notifications/push/register", params: params)
            guard registrationGeneration == pushRegistrationGeneration,
                  isConnected, isInitialized,
                  normalizedRelaySessionId == registrationSessionID,
                  remoteNotificationDeviceToken?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedToken else {
                return
            }
            completionPushSessionID = response.result?.objectValue?["completionPushEnabled"]?.boolValue == true
                && response.result?.objectValue?["ok"]?.boolValue == true
                && alertsEnabled && canScheduleRunCompletionNotifications ? registrationSessionID : nil
            lastPushRegistrationSignature = signature
        } catch {
            if registrationGeneration == pushRegistrationGeneration {
                completionPushSessionID = nil
                lastPushRegistrationSignature = nil
            }
            debugRuntimeLog("push registration sync failed: \(error.localizedDescription)")
        }
    }

    func invalidateCompletionPushRegistration() {
        pushRegistrationGeneration += 1
        completionPushSessionID = nil
        lastPushRegistrationSignature = nil
    }

    // Schedules a local alert while the app is backgrounded or transitioning
    // away from the screen. iOS may suspend the app after its finite grace window;
    // reliable delivery after suspension requires configured APNs push.
    func notifyRunCompletionIfNeeded(threadId: String, turnId: String?, result: CodexRunCompletionResult) {
        // Check replay scope synchronously: it has ended by the time the Task runs.
        guard !isApplyingReplayedBridgeEvent,
              let turnId = normalizedIdentifier(turnId) else {
            return
        }
        let persistenceKey = macScopedDefaultsKey(Self.handledRunCompletionsDefaultsKey)
        guard claimRunCompletionNotification(threadId: threadId, turnId: turnId, persistenceKey: persistenceKey) else {
            return
        }
        // Foreground and remotely delivered completions are handled too. Replaying
        // them after an app switch must never turn them into a new local alert.
        guard !usesRemoteCompletionNotifications,
              !isAppInForeground || applicationStateProvider() != .active else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.scheduleRunCompletionNotificationIfNeeded(
                threadId: threadId,
                turnId: turnId,
                result: result,
                persistenceKey: persistenceKey
            )
        }
    }

    var usesRemoteCompletionNotifications: Bool {
        guard let sessionID = normalizedRelaySessionId else { return false }
        return completionPushSessionID == sessionID
    }

    // Some older runtimes omit status on turn/completed; an explicit unknown or
    // still-running status must not be advertised as a successful completion.
    func isSuccessfulCompletionNotification(_ paramsObject: IncomingParamsObject?) -> Bool {
        let eventObject = envelopeEventObject(from: paramsObject)
        let status = paramsObject?["turn"]?.objectValue?["status"]
            ?? paramsObject?["status"]
            ?? eventObject?["turn"]?.objectValue?["status"]
            ?? eventObject?["status"]
        guard let status else { return true }
        let rawStatus = status.stringValue ?? status.objectValue?["type"]?.stringValue ?? ""
        return ["completed", "done", "finished"].contains(normalizeThreadStatusType(rawStatus))
    }

    // Called before terminal handling clears running state. History and a bare
    // idle status are not evidence that a run we were following just finished.
    func trackedCompletionNotificationTurnID(
        threadId: String,
        turnId: String?,
        paramsObject: IncomingParamsObject?
    ) -> String? {
        guard !isHistoricalCompletionEvent(paramsObject) else { return nil }
        let eventObject = envelopeEventObject(from: paramsObject)
        let timestampSources = [
            paramsObject?["turn"]?.objectValue, paramsObject,
            eventObject?["turn"]?.objectValue, eventObject,
        ]
        let completedAt = timestampSources.lazy.compactMap {
            self.firstDateValue(in: $0, keys: ["completedAt", "completed_at", "completedAtMs", "completed_at_ms"])
        }.first
        guard isFreshCompletionNotification(completedAt: completedAt) else { return nil }
        if let turnId,
           supersededTurnIDsByIDLessRunByThread[threadId]?.contains(turnId) == true { return nil }

        if let activeID = activeTurnIdByThread[threadId] {
            return turnId == nil || turnId == activeID ? activeID : nil
        }
        if let provisionalID = provisionalIDLessTurnIDByThread[threadId],
           threadHasActiveOrRunningTurn(threadId) {
            return turnId ?? provisionalID
        }
        if pendingReconnectRunContinuityThreadIDs.contains(threadId),
           let startedID = lastRunStartTurnIDByThread[threadId],
           turnId == nil || turnId == startedID {
            return startedID
        }
        return nil
    }

    func isHistoricalCompletionEvent(_ paramsObject: IncomingParamsObject?) -> Bool {
        isApplyingReplayedBridgeEvent
            || isReplayedBridgeEvent(paramsObject)
            || isRolloutBootstrapBridgeEvent(paramsObject)
            || paramsObject?["remodexRolloutTerminalCatchUp"]?.boolValue == true
    }

    // A recovered terminal snapshot may be accurate but too old to wake the user.
    // Legacy live runtimes omit timestamps; their tracked lifecycle remains the gate.
    func isFreshCompletionNotification(completedAt: Date?) -> Bool {
        guard let completedAt else { return true }
        return abs(Date().timeIntervalSince(completedAt)) <= 5 * 60
    }

    // Prompts can arrive mid-turn without any terminal event, so surface them with a local alert
    // when the app is backgrounded instead of making the user rediscover them later in the timeline.
    func notifyStructuredUserInputIfNeeded(
        threadId: String,
        turnId: String?,
        requestID: JSONValue,
        questions: [CodexStructuredUserInputQuestion]
    ) {
        guard !isAppInForeground || applicationStateProvider() != .active else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.scheduleStructuredUserInputNotificationIfNeeded(
                threadId: threadId,
                turnId: turnId,
                requestID: requestID,
                questions: questions
            )
        }
    }

    func handleNotificationOpen(threadId: String, turnId: String?) {
        let normalizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadId.isEmpty else {
            return
        }

        pendingNotificationOpenThreadID = normalizedThreadId
        externalThreadOpenRequest = CodexExternalThreadOpenRequest(threadId: normalizedThreadId)
        Task { @MainActor [weak self] in
            guard let self else { return }

            let routed = await routePendingNotificationOpenIfPossible()
            if !routed,
               turnId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                debugRuntimeLog("notification target turn deferred thread=\(normalizedThreadId) turn=\(turnId ?? "")")
            }
        }
    }
}

extension CodexService {
    // Keeps push-tap intent alive across reconnect so cold-launch opens can resolve later.
    @discardableResult
    func routePendingNotificationOpenIfPossible(refreshIfNeeded: Bool = true) async -> Bool {
        guard let pendingThreadId = pendingNotificationOpenThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !pendingThreadId.isEmpty else {
            return false
        }

        if hasNotificationRoutingCandidate(threadId: pendingThreadId) {
            missingNotificationThreadPrompt = nil
            if await prepareThreadForDisplay(threadId: pendingThreadId) {
                if pendingNotificationOpenThreadID == pendingThreadId {
                    pendingNotificationOpenThreadID = nil
                }
                return true
            }
            if hasNotificationRoutingCandidate(threadId: pendingThreadId) {
                return false
            }
        }

        guard isConnected else {
            return false
        }

        let didRefreshThreads: Bool
        if refreshIfNeeded {
            didRefreshThreads = await refreshThreadsForNotificationRouting()
        } else {
            didRefreshThreads = true
        }

        guard hasNotificationRoutingCandidate(threadId: pendingThreadId) else {
            guard didRefreshThreads else {
                return false
            }
            return finalizeMissingNotificationRouteIfNeeded(
                threadId: pendingThreadId,
                isAuthoritativeMissingResult: isNotificationRouteKnownMissing(threadId: pendingThreadId)
            )
        }

        missingNotificationThreadPrompt = nil
        if await prepareThreadForDisplay(threadId: pendingThreadId) {
            if pendingNotificationOpenThreadID == pendingThreadId {
                pendingNotificationOpenThreadID = nil
            }
            return true
        }

        if !hasNotificationRoutingCandidate(threadId: pendingThreadId), didRefreshThreads {
            return finalizeMissingNotificationRouteIfNeeded(
                threadId: pendingThreadId,
                isAuthoritativeMissingResult: isNotificationRouteKnownMissing(threadId: pendingThreadId)
            )
        }

        return false
    }
}

private extension CodexService {
    // Only live threads can satisfy a notification open; archived placeholders mean the server rejected it.
    func hasNotificationRoutingCandidate(threadId: String) -> Bool {
        guard let thread = thread(for: threadId) else {
            return false
        }

        return thread.syncState != .archivedLocal
    }

    // `thread/list` can omit still-live threads, so only an explicit archived placeholder is authoritative.
    func isNotificationRouteKnownMissing(threadId: String) -> Bool {
        thread(for: threadId)?.syncState == .archivedLocal
    }

    // Consumes the pending deep-link only after a fresh thread refresh confirms the target is gone.
    func finalizeMissingNotificationRouteIfNeeded(
        threadId: String,
        isAuthoritativeMissingResult: Bool
    ) -> Bool {
        guard isAuthoritativeMissingResult else {
            return false
        }

        if pendingNotificationOpenThreadID == threadId {
            pendingNotificationOpenThreadID = nil
        }
        if externalThreadOpenRequest?.threadId == threadId {
            externalThreadOpenRequest = nil
        }
        if activeThreadId == nil || activeThreadId == threadId {
            activeThreadId = firstLiveThreadID()
        }
        missingNotificationThreadPrompt = CodexMissingNotificationThreadPrompt(threadId: threadId)
        return false
    }

    // Keeps APNs callbacks wired even though SwiftUI owns the UIApplication lifecycle.
    func configureRemoteNotificationObservers() {
        guard notificationObserverTokens.isEmpty else {
            return
        }

        let didRegisterObserver = NotificationCenter.default.addObserver(
            forName: .codexDidRegisterForRemoteNotifications,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let tokenData = notification.userInfo?["deviceToken"] as? Data else {
                return
            }

            Task { @MainActor [weak self] in
                self?.handleRemoteNotificationDeviceToken(tokenData)
            }
        }

        let didFailObserver = NotificationCenter.default.addObserver(
            forName: .codexDidFailToRegisterForRemoteNotifications,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let error = notification.userInfo?["error"] as? Error else {
                return
            }

            Task { @MainActor [weak self] in
                self?.debugRuntimeLog("remote notification registration failed: \(error.localizedDescription)")
            }
        }

        notificationObserverTokens = [didRegisterObserver, didFailObserver]
    }

    // Admission and durable dedupe happen synchronously before scheduling this task.
    func scheduleRunCompletionNotificationIfNeeded(
        threadId: String,
        turnId: String,
        result: CodexRunCompletionResult,
        persistenceKey: String
    ) async {
        await refreshNotificationAuthorizationStatus()
        guard canScheduleRunCompletionNotifications,
              !usesRemoteCompletionNotifications,
              persistenceKey == macScopedDefaultsKey(Self.handledRunCompletionsDefaultsKey) else {
            return
        }
        let dedupeKey = "\(persistenceKey)|\(threadId)|\(turnId)"

        let title = thread(for: threadId)?.displayTitle ?? CodexThread.defaultDisplayTitle
        let body: String = {
            switch result {
            case .completed:
                "Response ready"
            case .failed:
                "Run failed"
            }
        }()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadId
        content.userInfo = [
            CodexNotificationPayloadKeys.source: CodexNotificationSource.runCompletion,
            CodexNotificationPayloadKeys.threadId: threadId,
            CodexNotificationPayloadKeys.turnId: turnId,
            CodexNotificationPayloadKeys.result: result.rawValue,
            CodexNotificationPayloadKeys.presentWhenActive: true,
        ]

        let request = UNNotificationRequest(
            identifier: runCompletionNotificationIdentifier(for: dedupeKey),
            content: content,
            trigger: nil
        )

        do {
            try await userNotificationCenter.add(request)
        } catch {
            debugRuntimeLog("failed to schedule local notification: \(error.localizedDescription)")
        }
    }

    // Keeps repeated request replays from spamming duplicate alerts while a prompt is still pending.
    func scheduleStructuredUserInputNotificationIfNeeded(
        threadId: String,
        turnId: String?,
        requestID: JSONValue,
        questions: [CodexStructuredUserInputQuestion]
    ) async {
        await refreshNotificationAuthorizationStatus()
        guard canScheduleRunCompletionNotifications else {
            return
        }

        let now = Date()
        pruneStructuredUserInputNotificationDedupe(now: now)
        let dedupeKey = structuredUserInputNotificationDedupeKey(
            threadId: threadId,
            requestID: requestID
        )

        if let previousTimestamp = structuredUserInputNotificationDedupedAt[dedupeKey],
           now.timeIntervalSince(previousTimestamp) <= 60 {
            return
        }

        structuredUserInputNotificationDedupedAt[dedupeKey] = now

        let title = thread(for: threadId)?.displayTitle ?? CodexThread.defaultDisplayTitle
        let promptCount = questions.count
        let body = promptCount == 1
            ? "Codex needs one answer to continue."
            : "Codex needs \(promptCount) answers to continue."

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadId
        content.userInfo = [
            CodexNotificationPayloadKeys.source: CodexNotificationSource.structuredUserInput,
            CodexNotificationPayloadKeys.threadId: threadId,
            CodexNotificationPayloadKeys.turnId: turnId ?? "",
            CodexNotificationPayloadKeys.requestId: idKey(from: requestID),
        ]

        let request = UNNotificationRequest(
            identifier: structuredUserInputNotificationIdentifier(for: dedupeKey),
            content: content,
            trigger: nil
        )

        do {
            try await userNotificationCenter.add(request)
        } catch {
            debugRuntimeLog("failed to schedule structured user input notification: \(error.localizedDescription)")
        }
    }

    var canScheduleRunCompletionNotifications: Bool {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            true
        case .denied, .notDetermined:
            false
        @unknown default:
            false
        }
    }

    var pushAPNsEnvironment: CodexPushAPNsEnvironment {
#if DEBUG
        .development
#else
        .production
#endif
    }

    // Bounded per-Mac receipts survive relaunch. A result change or elapsed time
    // does not make the same turn eligible for another completion notification.
    func claimRunCompletionNotification(
        threadId: String,
        turnId: String,
        persistenceKey: String
    ) -> Bool {
        let key = "\(threadId)|\(turnId)"
        var receipts = defaults.dictionary(forKey: persistenceKey) as? [String: Double] ?? [:]
        guard receipts[key] == nil else { return false }
        receipts[key] = Date().timeIntervalSince1970
        if receipts.count > 512 {
            receipts = Dictionary(uniqueKeysWithValues: receipts.sorted { $0.value > $1.value }.prefix(512).map { ($0.key, $0.value) })
        }
        defaults.set(receipts, forKey: persistenceKey)
        return true
    }

    func runCompletionNotificationIdentifier(for dedupeKey: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = String(dedupeKey.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        return "codex.runCompletion.\(sanitized)"
    }

    func structuredUserInputNotificationDedupeKey(
        threadId: String,
        requestID: JSONValue
    ) -> String {
        "\(threadId)|\(idKey(from: requestID))"
    }

    func structuredUserInputNotificationIdentifier(for dedupeKey: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = String(dedupeKey.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        return "codex.structuredUserInput.\(sanitized)"
    }

    func pruneStructuredUserInputNotificationDedupe(now: Date) {
        structuredUserInputNotificationDedupedAt = structuredUserInputNotificationDedupedAt.filter { _, timestamp in
            now.timeIntervalSince(timestamp) <= 60
        }
    }

    // Refreshes the thread list before routing a notification tap to a thread created on another client.
    func refreshThreadsForNotificationRouting() async -> Bool {
        guard isConnected else {
            return false
        }

        do {
            try await listThreads()
            return true
        } catch {
            debugRuntimeLog("thread refresh for notification routing failed: \(error.localizedDescription)")
            return false
        }
    }
}

private extension UNAuthorizationStatus {
    var pushRegistrationValue: String {
        switch self {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }
}
