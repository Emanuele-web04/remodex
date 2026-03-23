// FILE: CodexMobileApp.swift
// Purpose: App entry point and root dependency wiring for CodexService.
// Layer: App
// Exports: CodexMobileApp

import SwiftUI

@MainActor
@main
struct CodexMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate
    @State private var codexService: CodexService

    init() {
        let service = CodexService()
        service.configureNotifications()
        _codexService = State(initialValue: service)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(codexService)
                .onOpenURL { url in
                    Task { @MainActor in
                        guard CodexService.legacyGPTLoginCallbackEnabled else {
                            return
                        }
                        await codexService.handleGPTLoginCallbackURL(url)
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    TurnCacheManager.resetAll()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .background else { return }
                    TurnCacheManager.resetAll()
                }
        }
    }
}
