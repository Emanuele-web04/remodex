// FILE: CodexMobileApp.swift
// Purpose: App entry point and root dependency wiring for CodexService.
// Layer: App
// Exports: CodexMobileApp

import SwiftUI

@MainActor
@main
struct CodexMobileApp: App {
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
                .task {
                    await codexService.requestNotificationPermissionOnFirstLaunchIfNeeded()
                }
        }
    }
}
