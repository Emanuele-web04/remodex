// FILE: SidebarActivityDiffStore.swift
// Purpose: Shares on-demand Git totals between visible Activity rows in the same checkout.
// Layer: Service

import Foundation
import Observation

@MainActor
@Observable
final class SidebarActivityDiffStore {
    private(set) var totalsByPath: [String: GitDiffTotals] = [:]
    @ObservationIgnored private var refreshedAtByPath: [String: Date] = [:]
    @ObservationIgnored private var refreshedRevisionByPath: [String: Int] = [:]
    @ObservationIgnored private var requestsByPath: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingRefreshPaths: Set<String> = []
    @ObservationIgnored private var generation = 0

    func refresh(path: String?, codex: CodexService, revision: Int = 0, force: Bool = false, maxAge: TimeInterval = 30) async {
        guard !Task.isCancelled, codex.isConnected, codex.isInitialized,
              let path, !path.isEmpty else { return }
        let requestGeneration = generation
        if let pending = requestsByPath[path] {
            if force { pendingRefreshPaths.insert(path) }
            await pending.value
            if !Task.isCancelled, generation == requestGeneration,
               (refreshedRevisionByPath[path] ?? -1) < revision {
                await refresh(path: path, codex: codex, revision: revision, maxAge: maxAge)
            }
            return
        }
        if !force, let refreshedAt = refreshedAtByPath[path],
           (refreshedRevisionByPath[path] ?? -1) >= revision,
           Date().timeIntervalSince(refreshedAt) < maxAge { return }

        let macID = codex.currentMacScopedPersistenceDeviceId
        let request = Task { [weak self] in
            defer {
                if self?.generation == requestGeneration {
                    self?.requestsByPath[path] = nil
                }
            }
            repeat {
                self?.pendingRefreshPaths.remove(path)
                let result = try? await GitActionsService(codex: codex, workingDirectory: path).status()
                guard let self, !Task.isCancelled, self.generation == requestGeneration,
                      codex.isConnected, codex.currentMacScopedPersistenceDeviceId == macID else { return }
                // Failure or a non-repository means unknown, rather than a fabricated zero.
                self.totalsByPath[path] = result?.isGitRepository == true ? result?.repoDiffTotals : nil
                self.refreshedAtByPath[path] = Date()
                self.refreshedRevisionByPath[path] = max(revision, self.refreshedRevisionByPath[path] ?? -1)
            } while self?.pendingRefreshPaths.contains(path) == true
        }
        requestsByPath[path] = request
        await request.value
    }

    func cancelPendingRequests() {
        generation += 1
        for request in requestsByPath.values { request.cancel() }
        requestsByPath.removeAll()
        pendingRefreshPaths.removeAll()
    }
}
