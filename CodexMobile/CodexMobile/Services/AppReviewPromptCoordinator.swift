// FILE: AppReviewPromptCoordinator.swift
// Purpose: Applies a simple App Store rating prompt policy around successful Remodex usage.
// Layer: Service
// Exports: AppReviewPromptCoordinator
// Depends on: Foundation, StoreKit, UIKit

import Foundation
import StoreKit
import UIKit

private struct AppReviewPromptState: Codable, Equatable {
    var firstSuccessfulRunAt: Date?
    var successfulRunCount: Int
    var lastAttemptedAt: Date?
    var lastCompletedTurnID: String?
    var attemptCount: Int?

    static let empty = AppReviewPromptState(
        firstSuccessfulRunAt: nil,
        successfulRunCount: 0,
        lastAttemptedAt: nil,
        lastCompletedTurnID: nil,
        attemptCount: 0
    )
}

@MainActor
final class AppReviewPromptCoordinator {
    private enum Policy {
        static let storageKey = "remodex.appReviewPromptState.v1"
        static let minimumSuccessfulRuns = 6
        static let minimumDaysSinceFirstSuccess: TimeInterval = 2 * 24 * 60 * 60
        static let maximumAttempts = 3
        static let daysBeforeSecondAttempt: TimeInterval = 15 * 24 * 60 * 60
        static let daysBeforeLaterAttempts: TimeInterval = 30 * 24 * 60 * 60
    }

    private let defaults: UserDefaults
    private var state: AppReviewPromptState

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.state = Self.loadState(from: defaults)
    }

    // Records only clear, visible successful runs so review prompting stays away from turn recovery paths.
    func noteSuccessfulRun(threadId: String, turnId: String?, isCurrentThreadVisible: Bool, now: Date = Date()) {
        let normalizedThreadID = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty,
              isCurrentThreadVisible,
              let turnId,
              !turnId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        if state.lastCompletedTurnID == turnId {
            return
        }

        if state.firstSuccessfulRunAt == nil {
            state.firstSuccessfulRunAt = now
        }
        state.successfulRunCount += 1
        state.lastCompletedTurnID = turnId

        guard shouldRequestReview(now: now) else {
            persistState()
            return
        }

        requestReview(now: now)
    }

    // Keeps StoreKit calls scarce and lets iOS decide whether to display the system prompt.
    private func shouldRequestReview(now: Date) -> Bool {
        guard UIApplication.shared.applicationState == .active,
              let firstSuccessfulRunAt = state.firstSuccessfulRunAt,
              now.timeIntervalSince(firstSuccessfulRunAt) >= Policy.minimumDaysSinceFirstSuccess,
              state.successfulRunCount >= Policy.minimumSuccessfulRuns,
              (state.attemptCount ?? 0) < Policy.maximumAttempts else {
            return false
        }

        if let lastAttempt = state.lastAttemptedAt,
           now.timeIntervalSince(lastAttempt) < minimumTimeBeforeNextAttempt {
            return false
        }

        return true
    }

    // Asks the active foreground scene to present Apple's standard rating sheet.
    private func requestReview(now: Date) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            persistState()
            return
        }

        state.lastAttemptedAt = now
        state.attemptCount = (state.attemptCount ?? 0) + 1
        persistState()
        AppStore.requestReview(in: scene)
    }

    private var minimumTimeBeforeNextAttempt: TimeInterval {
        (state.attemptCount ?? 0) <= 1
            ? Policy.daysBeforeSecondAttempt
            : Policy.daysBeforeLaterAttempts
    }

    private func persistState() {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: Policy.storageKey)
    }

    private static func loadState(from defaults: UserDefaults) -> AppReviewPromptState {
        guard let data = defaults.data(forKey: Policy.storageKey),
              let state = try? JSONDecoder().decode(AppReviewPromptState.self, from: data) else {
            return .empty
        }
        return state
    }

}
