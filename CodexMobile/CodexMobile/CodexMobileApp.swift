// FILE: CodexMobileApp.swift
// Purpose: App entry point, RevenueCat setup, and root dependency wiring.
// Layer: App
// Exports: CodexMobileApp

import RevenueCat
import SwiftUI

@MainActor
@main
struct CodexMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate
    @State private var codexService: CodexService
    @State private var petCompanionStore: PetCompanionStore
    @State private var petCompanionStatusStore: PetCompanionStatusStore
    @State private var subscriptionService: SubscriptionService

    init() {
        Self.configureRevenueCatIfAvailable()
        let service = CodexService()
        service.configureNotifications()
        _codexService = State(initialValue: service)
        _petCompanionStore = State(initialValue: PetCompanionStore())
        _petCompanionStatusStore = State(initialValue: PetCompanionStatusStore())
        _subscriptionService = State(initialValue: SubscriptionService())
    }

    var body: some Scene {
        WindowGroup {
            if CodexUITestFixtureConfiguration.current.isEnabled {
                CodexUITestTimelineFixtureView(configuration: .current)
            } else {
                ContentView()
                    .environment(codexService)
                    .environment(petCompanionStore)
                    .environment(petCompanionStatusStore)
                    .environment(subscriptionService)
                    .task {
                        await subscriptionService.bootstrap()
                    }
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

    // Configures RevenueCat once at launch using the client-safe public SDK key.
    private static func configureRevenueCatIfAvailable() {
        guard let apiKey = AppEnvironment.revenueCatPublicAPIKey else {
            assertionFailure("Missing RevenueCat public API key in Info.plist")
            return
        }

        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        Purchases.configure(withAPIKey: apiKey)
    }
}

private struct CodexUITestFixtureConfiguration {
    let isEnabled: Bool
    let messageCount: Int
    let autoStream: Bool

    static var current: CodexUITestFixtureConfiguration {
        let arguments = ProcessInfo.processInfo.arguments
        let messageCount: Int = {
            guard let index = arguments.firstIndex(of: "-CodexUITestsMessageCount"),
                  arguments.indices.contains(arguments.index(after: index)),
                  let value = Int(arguments[arguments.index(after: index)]) else {
                return 500
            }
            return max(1, value)
        }()
        return CodexUITestFixtureConfiguration(
            isEnabled: arguments.contains("-CodexUITestsFixture"),
            messageCount: messageCount,
            autoStream: arguments.contains("-CodexUITestsAutoStream")
        )
    }
}

private struct CodexUITestTimelineFixtureView: View {
    let configuration: CodexUITestFixtureConfiguration
    @State private var streamedLineCount = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(0..<configuration.messageCount, id: \.self) { index in
                    fixtureRow(index: index)
                }

                if configuration.autoStream {
                    Text(streamingText)
                        .font(AppFont.body())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .padding(.vertical, 16)
        }
        .accessibilityIdentifier("turn.timeline.scrollview")
        .background(Color(.systemBackground))
        .task {
            guard configuration.autoStream else { return }
            for value in 1...80 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                streamedLineCount = value
            }
        }
    }

    private func fixtureRow(index: Int) -> some View {
        Text("Fixture message \(index): streamed timeline performance sample for Remodex.")
            .font(AppFont.body())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    private var streamingText: String {
        guard streamedLineCount > 0 else {
            return "Streaming fixture is ready."
        }
        return (1...streamedLineCount)
            .map { "Streaming chunk \($0)" }
            .joined(separator: " ")
    }
}
