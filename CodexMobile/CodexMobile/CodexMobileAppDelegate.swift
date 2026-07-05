// FILE: CodexMobileAppDelegate.swift
// Purpose: Bridges APNs registration callbacks into the service layer without coupling SwiftUI views to UIApplicationDelegate.
// Layer: App
// Exports: CodexMobileAppDelegate, Notification.Name push-registration helpers
// Depends on: Foundation, UIKit

import Foundation
import UIKit

extension Notification.Name {
    static let codexDidRegisterForRemoteNotifications = Notification.Name("codex.didRegisterForRemoteNotifications")
    static let codexDidFailToRegisterForRemoteNotifications = Notification.Name("codex.didFailToRegisterForRemoteNotifications")
}

final class CodexMobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = CodexMobileSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            Task { @MainActor in
                RemodexQuickActionCenter.handleShortcutItem(shortcutItem)
            }
        }

        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            completionHandler(RemodexQuickActionCenter.handleShortcutItem(shortcutItem))
        }
    }

    // Forwards the APNs token so CodexService can persist and sync it to the paired Mac bridge.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationCenter.default.post(
            name: .codexDidRegisterForRemoteNotifications,
            object: nil,
            userInfo: [
                "deviceToken": deviceToken,
            ]
        )
    }

    // Keeps registration failures observable in debug builds without surfacing noisy UI errors.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationCenter.default.post(
            name: .codexDidFailToRegisterForRemoteNotifications,
            object: nil,
            userInfo: [
                "error": error,
            ]
        )
    }
}

final class CodexMobileSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let shortcutItem = connectionOptions.shortcutItem else {
            return
        }

        Task { @MainActor in
            RemodexQuickActionCenter.handleShortcutItem(shortcutItem)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            completionHandler(RemodexQuickActionCenter.handleShortcutItem(shortcutItem))
        }
    }
}
