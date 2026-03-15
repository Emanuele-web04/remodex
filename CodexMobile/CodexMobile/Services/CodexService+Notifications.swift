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
}

protocol CodexRemoteNotificationRegistering: AnyObject {
    func registerForRemoteNotifications()
}

final class CodexApplicationRemoteNotificationRegistrar: CodexRemoteNotificationRegistering {
    // Requests the APNs device token once alert permission is no longer denied.
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
        // The in-app timeline and run badges already explain the new state.
        []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let service,
              let payload = CodexRunCompletionNotificationPayload(from: response.notification.request.content.userInfo) else {
            return
        }

        await MainActor.run {
            service.handleNotificationOpen(threadId: payload.threadId, turnId: payload.turnId)
        }
    }
}

private struct CodexRunCompletionNotificationPayload {
    let threadId: String
    let turnId: String?

    init?(from userInfo: [AnyHashable: Any]) {
        guard let source = userInfo[CodexNotificationPayloadKeys.source] as? String,
              source == CodexNotificationSource.runCompletion,
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

        remoteNotificationRegistrar.registerForRemoteNotifications()
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

        do {
            _ = try await sendRequest(method: "notifications/push/register", params: params)
            lastPushRegistrationSignature = signature
        } catch {
            debugRuntimeLog("push registration sync failed: \(error.localizedDescription)")
        }
    }

    // Schedules a local alert only when a run finishes while the app is away from the foreground.
    func notifyRunCompletionIfNeeded(threadId: String, turnId: String?, result: CodexRunCompletionResult) {
        guard !isAppInForeground else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.scheduleRunCompletionNotificationIfNeeded(
                threadId: threadId,
                turnId: turnId,
                result: result
            )
        }
    }

    func handleNotificationOpen(threadId: String, turnId: String?) {
        let normalizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadId.isEmpty else {
            return
        }

        pendingNotificationOpenThreadID = normalizedThreadId
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
        guard let thread = threads.first(where: { $0.id == threadId }) else {
            return false
        }

        return thread.syncState != .archivedLocal
    }

    // `thread/list` can omit still-live threads, so only an explicit archived placeholder is authoritative.
    func isNotificationRouteKnownMissing(threadId: String) -> Bool {
        threads.first(where: { $0.id == threadId })?.syncState == .archivedLocal
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
        if activeThreadId == nil || activeThreadId == threadId {
            activeThreadId = threads.first(where: { $0.syncState == .live })?.id
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

            self?.handleRemoteNotificationDeviceToken(tokenData)
        }

        let didFailObserver = NotificationCenter.default.addObserver(
            forName: .codexDidFailToRegisterForRemoteNotifications,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let error = notification.userInfo?["error"] as? Error else {
                return
            }

            self?.debugRuntimeLog("remote notification registration failed: \(error.localizedDescription)")
        }

        notificationObserverTokens = [didRegisterObserver, didFailObserver]
    }

    // Keeps local alerts deduped because some runtimes emit both turn/completed and thread/status terminal signals.
    func scheduleRunCompletionNotificationIfNeeded(
        threadId: String,
        turnId: String?,
        result: CodexRunCompletionResult
    ) async {
        await refreshNotificationAuthorizationStatus()
        guard canScheduleRunCompletionNotifications else {
            return
        }

        let now = Date()
        pruneRunCompletionNotificationDedupe(now: now)
        let dedupeKey = runCompletionNotificationDedupeKey(
            threadId: threadId,
            turnId: turnId,
            result: result,
            now: now
        )

        if let previousTimestamp = runCompletionNotificationDedupedAt[dedupeKey],
           now.timeIntervalSince(previousTimestamp) <= 60 {
            return
        }

        runCompletionNotificationDedupedAt[dedupeKey] = now

        let title = threads.first(where: { $0.id == threadId })?.displayTitle ?? "Conversation"
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
            CodexNotificationPayloadKeys.turnId: turnId ?? "",
            CodexNotificationPayloadKeys.result: result.rawValue,
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

    func runCompletionNotificationDedupeKey(
        threadId: String,
        turnId: String?,
        result: CodexRunCompletionResult,
        now: Date
    ) -> String {
        if let turnId, !turnId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(threadId)|\(turnId)|\(result.rawValue)"
        }

        let timeBucket = Int(now.timeIntervalSince1970 / 30)
        return "\(threadId)|\(result.rawValue)|\(timeBucket)"
    }

    func runCompletionNotificationIdentifier(for dedupeKey: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = String(dedupeKey.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        return "codex.runCompletion.\(sanitized)"
    }

    func pruneRunCompletionNotificationDedupe(now: Date) {
        runCompletionNotificationDedupedAt = runCompletionNotificationDedupedAt.filter { _, timestamp in
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
