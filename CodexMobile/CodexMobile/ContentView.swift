// FILE: ContentView.swift
// Purpose: Root layout orchestrator — navigation shell, sidebar drawer, and top-level state wiring.
// Layer: View
// Exports: ContentView
// Depends on: SidebarView, TurnView, SettingsView, CodexService, ContentViewModel

import SwiftUI

struct ContentView: View {
    @Environment(CodexService.self) private var codex
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var viewModel = ContentViewModel()
    @State private var isSidebarOpen = false
    @State private var sidebarDragOffset: CGFloat = 0
    @State private var selectedThread: CodexThread?
    @State private var navigationPath = NavigationPath()
    @State private var showSettings = false
    @State private var isShowingManualScanner = false
    @State private var isSearchActive = false
    @State private var isRetryingBridgeUpdate = false
    @State private var isPreparingManualScanner = false
    @State private var threadCompletionBannerDismissTask: Task<Void, Never>?
    @AppStorage("codex.hasSeenOnboarding") private var hasSeenOnboarding = false

    private let sidebarWidth: CGFloat = 330
    private static let sidebarSpring = Animation.spring(response: 0.35, dampingFraction: 0.85)

    var body: some View {
        rootContent
            // Keep launch/foreground reconnect observers alive even while the QR scanner is visible.
            .task {
                await viewModel.attemptAutoConnectOnLaunchIfNeeded(codex: codex)
            }
            .onChange(of: showSettings) { _, show in
                if show {
                    navigationPath.append("settings")
                    showSettings = false
                }
            }
            .onChange(of: isSidebarOpen) { wasOpen, isOpen in
                guard !wasOpen, isOpen else {
                    return
                }
                if viewModel.shouldRequestSidebarFreshSync(isConnected: codex.isConnected) {
                    codex.requestImmediateSync(threadId: codex.activeThreadId)
                }
            }
            .onChange(of: navigationPath) { _, _ in
                if isSidebarOpen {
                    closeSidebar()
                }
            }
            .onChange(of: selectedThread) { previousThread, thread in
                codex.handleDisplayedThreadChange(
                    from: previousThread?.id,
                    to: thread?.id
                )
                codex.activeThreadId = thread?.id
            }
            .onChange(of: codex.activeThreadId) { _, activeThreadId in
                guard let activeThreadId,
                      let matchingThread = codex.threads.first(where: { $0.id == activeThreadId }),
                      selectedThread?.id != matchingThread.id else {
                    return
                }
                selectedThread = matchingThread
            }
            .onChange(of: codex.threads) { _, threads in
                syncSelectedThread(with: threads)
            }
            .onChange(of: scenePhase) { _, phase in
                codex.setForegroundState(phase != .background)
                if phase == .active {
                    Task {
                        await viewModel.attemptAutoReconnectOnForegroundIfNeeded(codex: codex)
                    }
                }
            }
            .onChange(of: codex.shouldAutoReconnectOnForeground) { _, shouldReconnect in
                guard shouldReconnect, scenePhase == .active else {
                    return
                }
                Task {
                    await viewModel.attemptAutoReconnectOnForegroundIfNeeded(codex: codex)
                }
            }
            .onChange(of: codex.threadCompletionBanner) { _, banner in
                scheduleThreadCompletionBannerDismiss(for: banner)
            }
            // Presents actionable recovery when the saved bridge package is too old/new for this app build.
            .sheet(item: bridgeUpdatePromptBinding, onDismiss: {
                codex.bridgeUpdatePrompt = nil
                isRetryingBridgeUpdate = false
            }) { prompt in
                BridgeUpdateSheet(
                    prompt: prompt,
                    isRetrying: isRetryingBridgeUpdate,
                    onRetry: {
                        retryBridgeConnectionAfterUpdate()
                    },
                    onScanNewQR: {
                        presentManualScannerForBridgeRecovery()
                    },
                    onDismiss: {
                        codex.bridgeUpdatePrompt = nil
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .alert(
                "Chat Deleted",
                isPresented: missingNotificationThreadAlertIsPresented,
                presenting: codex.missingNotificationThreadPrompt
            ) { _ in
                Button("Not Now", role: .cancel) {
                    codex.missingNotificationThreadPrompt = nil
                }
                Button("Start New Chat") {
                    codex.missingNotificationThreadPrompt = nil
                    Task {
                        await startNewThreadFromMissingNotificationAlert()
                    }
                }
            } message: { _ in
                Text("This chat is no longer available. Start a new chat instead?")
            }
            .overlay(alignment: .top) {
                if let banner = codex.threadCompletionBanner {
                    ThreadCompletionBannerView(
                        banner: banner,
                        onTap: {
                            openCompletedThreadFromBanner(banner)
                        },
                        onDismiss: {
                            dismissThreadCompletionBanner()
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.88), value: codex.threadCompletionBanner?.id)
    }

    @ViewBuilder
    private var rootContent: some View {
        if !hasSeenOnboarding {
            OnboardingView {
                withAnimation { hasSeenOnboarding = true }
            }
        } else if isShowingManualScanner && !codex.isConnected {
            qrScannerBody
        } else if codex.isConnected
            || viewModel.isAttemptingAutoReconnect
            || shouldShowReconnectShell
            || isPreparingManualScanner {
            mainAppBody
        } else {
            qrScannerBody
        }
    }

    private var qrScannerBody: some View {
        QRScannerView { pairingPayload in
            Task {
                isShowingManualScanner = false
                await viewModel.connectToRelay(
                    pairingPayload: pairingPayload,
                    codex: codex
                )
            }
        }
    }

    private var effectiveSidebarWidth: CGFloat {
        isSearchActive ? UIScreen.main.bounds.width : sidebarWidth
    }

    private var mainAppBody: some View {
        ZStack(alignment: .leading) {
            if sidebarVisible {
                SidebarView(
                    selectedThread: $selectedThread,
                    showSettings: $showSettings,
                    isSearchActive: $isSearchActive,
                    onClose: { closeSidebar() }
                )
                .frame(width: effectiveSidebarWidth)
                .animation(.easeInOut(duration: 0.25), value: isSearchActive)
            }

            mainNavigationLayer
                .offset(x: contentOffset)

            if sidebarVisible {
                (colorScheme == .dark ? Color.white : Color.black)
                    .opacity(contentDimOpacity)
                    .ignoresSafeArea()
                    .offset(x: contentOffset)
                    .allowsHitTesting(isSidebarOpen)
                    .onTapGesture { closeSidebar() }
            }
        }
        .gesture(edgeDragGesture)
    }

    // MARK: - Layers

    private var mainNavigationLayer: some View {
        NavigationStack(path: $navigationPath) {
            mainContent
                .adaptiveNavigationBar()
                .navigationDestination(for: String.self) { destination in
                    if destination == "settings" {
                        SettingsView()
                            .adaptiveNavigationBar()
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var mainContent: some View {
        if let thread = selectedThread {
            TurnView(thread: thread)
                .id(thread.id)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        hamburgerButton
                    }
                }
        } else {
            HomeEmptyStateView(
                connectionPhase: homeConnectionPhase,
                securityLabel: codex.secureConnectionState.statusLabel,
                onToggleConnection: {
                    Task {
                        await viewModel.toggleConnection(codex: codex)
                    }
                }
            ) {
                if homeConnectionPhase == .connecting || (codex.hasSavedRelaySession && !codex.isConnected) {
                    Button("Scan New QR Code") {
                        presentManualScannerAfterStoppingReconnect()
                    }
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(.primary)
                    .buttonStyle(.plain)
                    .disabled(isPreparingManualScanner)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    hamburgerButton
                }
            }
        }
    }

    private var hamburgerButton: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            toggleSidebar()
        } label: {
            TwoLineHamburgerIcon()
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .padding(8)
                .contentShape(Circle())
                .adaptiveToolbarItem(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Menu")
    }

    // MARK: - Sidebar Geometry

    private var sidebarVisible: Bool {
        isSidebarOpen || sidebarDragOffset > 0
    }

    private var contentOffset: CGFloat {
        if isSidebarOpen {
            return max(0, effectiveSidebarWidth + sidebarDragOffset)
        } else {
            return max(0, sidebarDragOffset)
        }
    }

    private var contentDimOpacity: Double {
        let progress = min(1, contentOffset / effectiveSidebarWidth)
        return 0.08 * progress
    }

    // MARK: - Gestures

    private var edgeDragGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard navigationPath.isEmpty else { return }

                if !isSidebarOpen {
                    guard value.startLocation.x < 30 else { return }
                    sidebarDragOffset = max(0, value.translation.width)
                } else {
                    sidebarDragOffset = min(0, value.translation.width)
                }
            }
            .onEnded { value in
                guard navigationPath.isEmpty else { return }

                let currentWidth = effectiveSidebarWidth
                let threshold = currentWidth * 0.4

                if !isSidebarOpen {
                    guard value.startLocation.x < 30 else {
                        sidebarDragOffset = 0
                        return
                    }
                    let shouldOpen = value.translation.width > threshold
                        || value.predictedEndTranslation.width > currentWidth * 0.5
                    finishGesture(open: shouldOpen)
                } else {
                    let shouldClose = -value.translation.width > threshold
                        || -value.predictedEndTranslation.width > currentWidth * 0.5
                    finishGesture(open: !shouldClose)
                }
            }
    }

    // MARK: - Sidebar Actions

    private func toggleSidebar() {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        withAnimation(Self.sidebarSpring) {
            isSidebarOpen.toggle()
            sidebarDragOffset = 0
        }
    }

    private func closeSidebar() {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        withAnimation(Self.sidebarSpring) {
            isSidebarOpen = false
            sidebarDragOffset = 0
        }
    }

    // Shows the remembered pairing shell while a saved pairing can still be retried.
    private var shouldShowReconnectShell: Bool {
        codex.hasSavedRelaySession
            && !isShowingManualScanner
            && (codex.isConnecting
                || viewModel.isAttemptingAutoReconnect
                || codex.shouldAutoReconnectOnForeground
                || isRetryingSavedPairing
                || hasIdleSavedPairingRecovery)
    }

    // Keeps home status honest during reconnect loops while letting post-connect sync show separately.
    private var homeConnectionPhase: CodexConnectionPhase {
        if viewModel.isAttemptingAutoReconnect && !codex.isConnected {
            return .connecting
        }
        return codex.connectionPhase
    }

    private var isRetryingSavedPairing: Bool {
        if case .retrying = codex.connectionRecoveryState {
            return true
        }
        return false
    }

    // Keeps the reconnect CTA visible after retries stop, unless the pairing must be replaced.
    private var hasIdleSavedPairingRecovery: Bool {
        guard codex.hasSavedRelaySession,
              !codex.isConnected,
              codex.secureConnectionState != .rePairRequired else {
            return false
        }

        return !codex.isConnecting
            && !viewModel.isAttemptingAutoReconnect
            && !codex.shouldAutoReconnectOnForeground
            && !isRetryingSavedPairing
    }

    private func finishGesture(open: Bool) {
        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        withAnimation(Self.sidebarSpring) {
            isSidebarOpen = open
            sidebarDragOffset = 0
        }
    }

    private var bridgeUpdatePromptBinding: Binding<CodexBridgeUpdatePrompt?> {
        Binding(
            get: { codex.bridgeUpdatePrompt },
            set: { codex.bridgeUpdatePrompt = $0 }
        )
    }

    private var missingNotificationThreadAlertIsPresented: Binding<Bool> {
        Binding(
            get: { codex.missingNotificationThreadPrompt != nil },
            set: { isPresented in
                if !isPresented {
                    codex.missingNotificationThreadPrompt = nil
                }
            }
        )
    }

    // Re-tries the saved relay session after the user updates the Mac package.
    private func retryBridgeConnectionAfterUpdate() {
        guard !isRetryingBridgeUpdate else {
            return
        }

        isRetryingBridgeUpdate = true

        Task {
            await viewModel.toggleConnection(codex: codex)
            await MainActor.run {
                isRetryingBridgeUpdate = false
            }
        }
    }

    // Switches the user back to the QR path when the old relay session is no longer useful.
    private func presentManualScannerForBridgeRecovery() {
        codex.bridgeUpdatePrompt = nil
        isRetryingBridgeUpdate = false
        presentManualScannerAfterStoppingReconnect()
    }

    // Waits for reconnect teardown before showing the scanner so stale retries cannot race the new QR flow.
    private func presentManualScannerAfterStoppingReconnect() {
        guard !isPreparingManualScanner, !isShowingManualScanner else {
            return
        }

        isPreparingManualScanner = true

        Task {
            await viewModel.stopAutoReconnectForManualScan(codex: codex)
            await MainActor.run {
                isPreparingManualScanner = false
                if !codex.isConnected {
                    isShowingManualScanner = true
                }
            }
        }
    }

    private func startNewThreadFromMissingNotificationAlert() async {
        do {
            let thread = try await codex.startThread()
            selectedThread = thread
        } catch {
            codex.lastErrorMessage = codex.userFacingTurnErrorMessage(from: error)
        }
    }

    // Auto-hides the banner unless the user taps through to the finished chat first.
    private func scheduleThreadCompletionBannerDismiss(for banner: CodexThreadCompletionBanner?) {
        threadCompletionBannerDismissTask?.cancel()

        guard let banner else {
            threadCompletionBannerDismissTask = nil
            return
        }

        threadCompletionBannerDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if codex.threadCompletionBanner?.id == banner.id {
                    codex.threadCompletionBanner = nil
                }
            }
        }
    }

    // Lets the user jump straight to the chat that produced the ready sidebar badge.
    private func openCompletedThreadFromBanner(_ banner: CodexThreadCompletionBanner) {
        threadCompletionBannerDismissTask?.cancel()
        codex.threadCompletionBanner = nil

        guard let thread = codex.threads.first(where: { $0.id == banner.threadId }) else {
            return
        }

        if isSidebarOpen {
            closeSidebar()
        }
        selectedThread = thread
        codex.activeThreadId = thread.id
        codex.markThreadAsViewed(thread.id)
    }

    private func dismissThreadCompletionBanner() {
        threadCompletionBannerDismissTask?.cancel()
        codex.threadCompletionBanner = nil
    }

    // Keeps selected thread coherent with server list updates.
    private func syncSelectedThread(with threads: [CodexThread]) {
        if let selected = selectedThread,
           !threads.contains(where: { $0.id == selected.id }) {
            if codex.activeThreadId == selected.id {
                return
            }
            selectedThread = codex.pendingNotificationOpenThreadID == nil ? threads.first : nil
            return
        }

        if let selected = selectedThread,
           let refreshed = threads.first(where: { $0.id == selected.id }) {
            selectedThread = refreshed
            return
        }

        if selectedThread == nil,
           codex.activeThreadId == nil,
           codex.pendingNotificationOpenThreadID == nil,
           let first = threads.first {
            selectedThread = first
        }
    }
}

private struct TwoLineHamburgerIcon: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 20, height: 2)

            RoundedRectangle(cornerRadius: 1)
                .frame(width: 10, height: 2)
        }
        .frame(width: 20, height: 14, alignment: .leading)
    }
}

#Preview {
    ContentView()
        .environment(CodexService())
}
