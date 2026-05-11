// FILE: TurnGitActionToastOverlay.swift
// Purpose: Shows git action progress and success toast banners above the turn timeline.
// Layer: View Component
// Exports: TurnGitActionToastOverlay
// Depends on: SwiftUI, UIKit, InAppToastBannerView

import SwiftUI
import UIKit

struct TurnGitActionToastOverlay: View {
    let success: TurnGitActionSuccess?
    let progress: TurnGitActionProgress?
    let onDismissSuccess: () -> Void

    var body: some View {
        if let success {
            successToast(success)
        } else if let progress {
            progressToast(progress)
        }
    }

    private func successToast(_ success: TurnGitActionSuccess) -> some View {
        InAppToastBannerView(
            title: success.title,
            subtitle: successSubtitle(for: success),
            accessibilityHint: successAccessibilityHint(for: success),
            isDismissable: true,
            onTap: nil,
            onDismiss: onDismissSuccess,
            trailingAction: successAction(for: success)
        ) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white, Color.green)
                .symbolRenderingMode(.palette)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
        .id(success.id)
    }

    private func progressToast(_ progress: TurnGitActionProgress) -> some View {
        InAppToastBannerView(
            title: progress.activeTitle,
            subtitle: nil,
            detailLines: progressDetailLines(progress),
            accessibilityHint: nil,
            isDismissable: false,
            onTap: nil,
            onDismiss: nil
        ) {
            ProgressView()
                .controlSize(.regular)
                .tint(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func progressDetailLines(_ progress: TurnGitActionProgress) -> [String] {
        guard progress.plannedPhases.count > 1 else { return [] }
        return progress.plannedPhases.map { phase in
            switch progress.status(for: phase) {
            case .completed:
                return "✓ \(phase.completedTitle)"
            case .skipped:
                return "– \(phase.completedTitle)"
            case .active:
                return "• \(phase.activeTitle)"
            case .pending:
                return "○ \(phase.pendingTitle)"
            }
        }
    }

    private func successSubtitle(for success: TurnGitActionSuccess) -> String? {
        guard let subtitle = success.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty else {
            return nil
        }
        return subtitle
    }

    private func successAccessibilityHint(for success: TurnGitActionSuccess) -> String? {
        switch success.kind {
        case .pullRequest where success.pullRequestURL != nil:
            return "Tap View PR to open the pull request."
        default:
            return nil
        }
    }

    private func successAction(for success: TurnGitActionSuccess) -> InAppToastBannerAction? {
        switch success.kind {
        case .pullRequest:
            guard let url = success.pullRequestURL else { return nil }
            return InAppToastBannerAction(title: "View PR") {
                UIApplication.shared.open(url)
                onDismissSuccess()
            }
        case .commit, .push:
            return nil
        }
    }
}
