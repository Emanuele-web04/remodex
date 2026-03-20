// FILE: BridgeMenuBarStore.swift
// Purpose: Owns CLI gating, bridge polling, command execution, and local relay override persistence for the menu bar control center.
// Layer: Companion app state
// Exports: BridgeMenuBarStore
// Depends on: AppKit, Combine, Foundation, BridgeControlService, BridgeControlModels

import AppKit
import Combine
import Foundation

enum BridgeMenuBarActionError: LocalizedError {
    case missingCLI
    case brokenCLI(String)
    case pairingTimeout

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            return "Install the global `remodex` CLI before using this companion."
        case .brokenCLI(let message):
            return message
        case .pairingTimeout:
            return "The bridge did not publish a fresh pairing session in time. Check the daemon logs and try again."
        }
    }
}

@MainActor
final class BridgeMenuBarStore: ObservableObject {
    @Published var snapshot: BridgeSnapshot?
    @Published var updateState = BridgePackageUpdateState.empty
    @Published var cliAvailability: BridgeCLIAvailability = .checking
    @Published var relayOverride: String
    @Published var isRefreshing = false
    @Published var isPerformingAction = false
    @Published var transientMessage = ""
    @Published var errorMessage = ""

    private static let relayOverrideKey = "remodex.menuBar.relayOverride"
    private let service: BridgeControlService
    private var refreshLoopTask: Task<Void, Never>?

    init(service: BridgeControlService = BridgeControlService()) {
        self.service = service
        self.relayOverride = UserDefaults.standard.string(forKey: Self.relayOverrideKey) ?? ""
        startRefreshLoop()

        Task {
            await bootstrap()
        }
    }

    deinit {
        refreshLoopTask?.cancel()
    }

    // Refreshes the bridge snapshot plus npm update metadata so the menu bar is the new control surface.
    func refresh(showSpinner: Bool = false) async {
        if showSpinner {
            isRefreshing = true
        }

        defer {
            isRefreshing = false
        }

        let cliAvailability = await refreshCLIAvailability()
        guard cliAvailability.isAvailable else {
            snapshot = nil
            updateState = .empty
            transientMessage = ""
            errorMessage = ""
            return
        }

        do {
            let snapshot = try await service.loadSnapshot(relayOverride: effectiveRelayOverride)
            self.snapshot = snapshot
            self.errorMessage = ""
            self.updateState = await resolveUpdateState(installedVersion: snapshot.currentVersion)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func saveRelayOverride(_ value: String) {
        relayOverride = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(relayOverride, forKey: Self.relayOverrideKey)
        Task {
            await refresh(showSpinner: true)
        }
    }

    func clearRelayOverride() {
        relayOverride = ""
        UserDefaults.standard.removeObject(forKey: Self.relayOverrideKey)
        Task {
            await refresh(showSpinner: true)
        }
    }

    func startBridge() {
        let previousPairingDate = snapshot?.pairingSession?.createdDate
        runAction(successMessage: "Bridge avviato.") {
            try await requireCLIAvailability()
            try await service.startBridge(relayOverride: effectiveRelayOverride)
            try await waitForFreshPairing(after: previousPairingDate)
        }
    }

    func stopBridge() {
        runAction(successMessage: "Bridge fermato.") {
            try await requireCLIAvailability()
            try await service.stopBridge(relayOverride: effectiveRelayOverride)
            await refresh(showSpinner: false)
        }
    }

    func resumeLastThread() {
        runAction(successMessage: "Ultimo thread riaperto in Codex.") {
            try await requireCLIAvailability()
            try await service.resumeLastThread(relayOverride: effectiveRelayOverride)
            await refresh(showSpinner: false)
        }
    }

    func resetPairing() {
        runAction(successMessage: "Pairing resettato.") {
            try await requireCLIAvailability()
            try await service.resetPairing(relayOverride: effectiveRelayOverride)
            await refresh(showSpinner: false)
        }
    }

    func updateBridgePackage() {
        runAction(successMessage: "Bridge aggiornato all’ultima release.") {
            try await requireCLIAvailability()
            try await service.updateBridgePackage()
            if snapshot?.launchdLoaded == true {
                try await service.startBridge(relayOverride: effectiveRelayOverride)
            }
            await refresh(showSpinner: false)
        }
    }

    func retryCLISetup() {
        Task {
            await refresh(showSpinner: true)
        }
    }

    func openLogsFolder() {
        let path = snapshot?.stateDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath = (path?.isEmpty == false) ? path! : "\(NSHomeDirectory())/.remodex"
        NSWorkspace.shared.open(URL(fileURLWithPath: targetPath))
    }

    func openStdoutLog() {
        guard let snapshot else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: snapshot.stdoutLogPath))
    }

    func openStderrLog() {
        guard let snapshot else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: snapshot.stderrLogPath))
    }

    private var effectiveRelayOverride: String? {
        relayOverride.isEmpty ? nil : relayOverride
    }

    var isCLIAvailable: Bool {
        cliAvailability.isAvailable
    }

    private func startRefreshLoop() {
        refreshLoopTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .minutes(8))
                guard !Task.isCancelled else { return }
                await refresh(showSpinner: false)
            }
        }
    }

    // Performs the first load in two stages so the UI can show a dedicated "install the CLI" blocker.
    private func bootstrap() async {
        let cliAvailability = await refreshCLIAvailability()
        guard cliAvailability.isAvailable else {
            snapshot = nil
            updateState = .empty
            return
        }

        await refresh(showSpinner: true)
    }

    @discardableResult
    private func refreshCLIAvailability() async -> BridgeCLIAvailability {
        let availability = await service.detectCLIAvailability()
        cliAvailability = availability
        return availability
    }

    private func requireCLIAvailability() async throws {
        switch await refreshCLIAvailability() {
        case .available:
            return
        case .missing:
            throw BridgeMenuBarActionError.missingCLI
        case .broken(let message):
            throw BridgeMenuBarActionError.brokenCLI(message)
        case .checking:
            throw BridgeMenuBarActionError.missingCLI
        }
    }

    private func resolveUpdateState(installedVersion: String) async -> BridgePackageUpdateState {
        let latestVersionResult = await service.fetchLatestPackageVersion()
        switch latestVersionResult {
        case .success(let latestVersion):
            return BridgePackageUpdateState(
                installedVersion: installedVersion,
                latestVersion: latestVersion,
                errorMessage: nil
            )
        case .failure(let error):
            return BridgePackageUpdateState(
                installedVersion: installedVersion,
                latestVersion: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    // Treats a missing fresh QR as a real start failure so the menu bar never reports a false success.
    private func waitForFreshPairing(after previousPairingDate: Date?) async throws {
        for _ in 0..<20 {
            do {
                let nextSnapshot = try await service.loadSnapshot(relayOverride: effectiveRelayOverride)
                let nextPairingDate = nextSnapshot.pairingSession?.createdDate
                self.snapshot = nextSnapshot
                self.updateState = await resolveUpdateState(installedVersion: nextSnapshot.currentVersion)
                if previousPairingDate == nil {
                    if nextSnapshot.pairingSession?.pairingPayload != nil {
                        return
                    }
                } else if let nextPairingDate,
                          let previousPairingDate,
                          nextPairingDate > previousPairingDate {
                    return
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        throw BridgeMenuBarActionError.pairingTimeout
    }

    private func runAction(
        successMessage: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isPerformingAction else {
            return
        }

        isPerformingAction = true
        transientMessage = ""
        errorMessage = ""

        Task {
            defer {
                isPerformingAction = false
            }

            do {
                try await operation()
                transientMessage = successMessage
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
