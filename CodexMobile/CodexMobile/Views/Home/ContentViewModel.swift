// FILE: ContentViewModel.swift
// Purpose: Owns non-visual orchestration logic for the root screen.
// Layer: ViewModel
// Exports: ContentViewModel
// Depends on: Foundation, Observation

import Foundation
import Observation

@MainActor
@Observable
final class ContentViewModel {
    private var lastSidebarOpenSyncAt: Date = .distantPast

    // Throttles sidebar-open sync requests to avoid redundant thread refresh churn.
    func shouldRequestSidebarFreshSync(
        isConnected: Bool,
        isBootstrappingConnectionSync: Bool,
        isLoadingThreads: Bool,
        hasThreads: Bool
    ) -> Bool {
        guard isConnected,
              !isBootstrappingConnectionSync,
              !isLoadingThreads else {
            return false
        }

        // A populated sidebar stays reasonably fresh from the background sync loop,
        // so reopening it should not force another full thread/list burst.
        guard !hasThreads else {
            return false
        }

        let now = Date()
        guard now.timeIntervalSince(lastSidebarOpenSyncAt) >= 0.8 else {
            return false
        }

        lastSidebarOpenSyncAt = now
        return true
    }
}