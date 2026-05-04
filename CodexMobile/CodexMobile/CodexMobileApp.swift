// FILE: CodexMobileApp.swift
// Purpose: App entry point and root dependency wiring for CodexService.
// Layer: App
// Exports: CodexMobileApp

import SwiftUI

@MainActor
@main
struct CodexMobileApp: App {
    @State private var codexService: CodexService

    init() {
        _codexService = State(initialValue: CodexService())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(codexService)
        }
    }
}
