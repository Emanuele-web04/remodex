// FILE: CodexMobileApp.swift
// Purpose: App entry point, RevenueCat setup, and root dependency wiring.
// Layer: App
// Exports: CodexMobileApp

import Foundation
import RevenueCat
import SwiftUI

private struct CodexUITestLaunchConfiguration {
    let isEnabled: Bool
    let messageCount: Int
    let autoStream: Bool

    static let current = Self(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        isEnabled = arguments.contains("-CodexUITestsFixture")
        messageCount = max(Self.intValue(after: "-CodexUITestsMessageCount", in: arguments) ?? 400, 1)
        autoStream = arguments.contains("-CodexUITestsAutoStream")
    }

    private static func intValue(after flag: String, in arguments: [String]) -> Int? {
        guard let flagIndex = arguments.firstIndex(of: flag) else {
            return nil
        }

        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        return Int(arguments[valueIndex])
    }
}

private struct CodexDebugLaunchConfiguration {
    private static let forceProAccessDefaultsKey = "codex.subscription.debugForceProAccess"

    let forceProAccess: Bool

    static let current = Self(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        forceProAccess = arguments.contains("-CodexDebugForceProAccess")
    }

    func apply() {
#if DEBUG
        UserDefaults.standard.set(forceProAccess, forKey: Self.forceProAccessDefaultsKey)
#endif
    }
}

private struct CodexUITestTimelineFixtureView: View {
    private static let fixtureThreadID = "codex-ui-tests-thread"

    let configuration: CodexUITestLaunchConfiguration

    @State private var messages: [CodexMessage]
    @State private var timelineChangeToken = 0
    @State private var shouldAnchorToAssistantResponse = false
    @State private var isScrolledToBottom = true
    @State private var streamTick = 0

    init(configuration: CodexUITestLaunchConfiguration) {
        self.configuration = configuration
        _messages = State(
            initialValue: Self.buildMessages(
                threadID: Self.fixtureThreadID,
                count: configuration.messageCount,
                includesStreamingTail: configuration.autoStream
            )
        )
    }

    var body: some View {
        NavigationStack {
            TurnConversationContainerView(
                threadID: Self.fixtureThreadID,
                messages: messages,
                timelineChangeToken: timelineChangeToken,
                activeTurnID: configuration.autoStream ? "fixture-turn" : nil,
                isThreadRunning: configuration.autoStream,
                latestTurnTerminalState: nil,
                stoppedTurnIDs: [],
                assistantRevertStatesByMessageID: [:],
                errorMessage: nil,
                connectionRecoveryAccessory: nil,
                shouldAnchorToAssistantResponse: $shouldAnchorToAssistantResponse,
                isScrolledToBottom: $isScrolledToBottom,
                isComposerFocused: false,
                isComposerAutocompletePresented: false,
                emptyState: AnyView(Color.clear),
                composer: AnyView(fixtureComposer),
                repositoryLoadingToastOverlay: AnyView(EmptyView()),
                usageToastOverlay: AnyView(EmptyView()),
                isRepositoryLoadingToastVisible: false,
                onRetryUserMessage: { _ in },
                onTapAssistantRevert: { _ in },
                onTapSubagent: { _ in },
                onTapOutsideComposer: {}
            )
            .navigationTitle("UI Test Fixture")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: configuration.autoStream) {
            guard configuration.autoStream else {
                return
            }
            await runStreamingFixture()
        }
    }

    private var fixtureComposer: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 44, height: 5)
                .padding(.top, 8)

            HStack(spacing: 12) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(configuration.autoStream ? "Streaming fixture active" : "Timeline fixture ready")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
    }

    @MainActor
    private func runStreamingFixture() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 120_000_000)
            appendStreamingChunk()
        }
    }

    @MainActor
    private func appendStreamingChunk() {
        streamTick += 1
        let chunkText = Self.streamingChunkText(for: streamTick)

        guard let lastIndex = messages.indices.last else {
            return
        }

        if messages[lastIndex].role == .assistant, messages[lastIndex].isStreaming {
            messages[lastIndex].text += chunkText
            if streamTick.isMultiple(of: 12) {
                messages[lastIndex].isStreaming = false
                messages[lastIndex].deliveryState = .confirmed
                messages.append(Self.fixtureUserMessage(threadID: Self.fixtureThreadID, index: messages.count))
                messages.append(Self.fixtureAssistantMessage(
                    threadID: Self.fixtureThreadID,
                    index: messages.count + 1,
                    isStreaming: true,
                    extraText: "Synthesizing the next batch of streamed output"
                ))
            }
        } else {
            messages.append(Self.fixtureAssistantMessage(
                threadID: Self.fixtureThreadID,
                index: messages.count,
                isStreaming: true,
                extraText: "Continuing streamed output"
            ))
        }

        timelineChangeToken += 1
    }

    private static func buildMessages(threadID: String, count: Int, includesStreamingTail: Bool) -> [CodexMessage] {
        var built: [CodexMessage] = []
        built.reserveCapacity(count + (includesStreamingTail ? 1 : 0))

        for index in 0..<count {
            if index.isMultiple(of: 2) {
                built.append(fixtureUserMessage(threadID: threadID, index: index))
            } else {
                built.append(fixtureAssistantMessage(threadID: threadID, index: index))
            }
        }

        if includesStreamingTail {
            built.append(
                fixtureAssistantMessage(
                    threadID: threadID,
                    index: built.count,
                    isStreaming: true,
                    extraText: "Bootstrapping the streaming append performance fixture"
                )
            )
        }

        return built
    }

    private static func fixtureUserMessage(threadID: String, index: Int) -> CodexMessage {
        CodexMessage(
            id: "fixture-user-\(index)",
            threadId: threadID,
            role: .user,
            kind: .chat,
            text: "User request \(index + 1): summarize the current project state and call out the next actionable step.",
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            orderIndex: index
        )
    }

    private static func fixtureAssistantMessage(
        threadID: String,
        index: Int,
        isStreaming: Bool = false,
        extraText: String? = nil
    ) -> CodexMessage {
        let body = extraText ?? "Status update \(index + 1): the local-first sync cache is warm, timeline rendering is stable, and pending work is isolated to explicit refresh paths."
        let text = """
        \(body)

        - Validate the current cache snapshot.
        - Reconcile changed rows without rebuilding the whole thread list.
        - Keep the active thread responsive while background sync completes.
        """

        return CodexMessage(
            id: "fixture-assistant-\(index)",
            threadId: threadID,
            role: .assistant,
            kind: .chat,
            text: text,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            turnId: isStreaming ? "fixture-turn" : nil,
            isStreaming: isStreaming,
            deliveryState: .confirmed,
            orderIndex: index
        )
    }

    private static func streamingChunkText(for tick: Int) -> String {
        let suffix = (tick % 3) + 1
        return "\n\nStreaming chunk \(tick): appended delta segment \(suffix)."
    }
}

@MainActor
@main
struct CodexMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(CodexMobileAppDelegate.self) private var appDelegate
    @State private var codexService: CodexService
    @State private var subscriptionService: SubscriptionService
    private let uiTestLaunchConfiguration: CodexUITestLaunchConfiguration
    private let shouldSkipRevenueCatBootstrap: Bool

    init() {
        let uiTestLaunchConfiguration = CodexUITestLaunchConfiguration.current
        self.uiTestLaunchConfiguration = uiTestLaunchConfiguration
        let shouldSkipRevenueCatBootstrap = SubscriptionService.usesLocalDevelopmentBypassForCurrentBuild
        self.shouldSkipRevenueCatBootstrap = shouldSkipRevenueCatBootstrap
        CodexDebugLaunchConfiguration.current.apply()

        if !uiTestLaunchConfiguration.isEnabled, !shouldSkipRevenueCatBootstrap {
            Self.configureRevenueCatIfAvailable()
        }

        let service = CodexService()
        if !uiTestLaunchConfiguration.isEnabled {
            service.configureNotifications()
        }
        _codexService = State(initialValue: service)
        _subscriptionService = State(initialValue: SubscriptionService())
    }

    var body: some Scene {
        WindowGroup {
            if uiTestLaunchConfiguration.isEnabled {
                CodexUITestTimelineFixtureView(configuration: uiTestLaunchConfiguration)
            } else {
                ContentView()
                    .environment(codexService)
                    .environment(subscriptionService)
                    .task {
                        guard !shouldSkipRevenueCatBootstrap else {
                            return
                        }
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
