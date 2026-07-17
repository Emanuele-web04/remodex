// FILE: AutoApprovalReviewRow.swift
// Purpose: Presents Codex automatic approval-review decisions and narrow retry approval.
// Layer: View Component
// Exports: AutoApprovalReviewRow
// Depends on: SwiftUI, CodexService, CodexAutoApprovalReview

import SwiftUI

// Tool-call style row: collapsed it reads "Auto-review · <state>" like the
// command group rows; expanding reveals the reviewed action, risk context, and
// the one-shot retry control for denied reviews.
struct AutoApprovalReviewRow: View {
    @Environment(CodexService.self) private var codex

    let threadId: String
    let review: CodexAutoApprovalReview

    @State private var isExpanded = false
    @State private var isApprovingRetry = false
    @State private var retryErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if review.status == .inProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        RemodexIcon.image(systemName: statusIconSystemName, size: 17, relativeTo: .body)
                            .foregroundStyle(statusColor)
                    }
                    Text(rowTitle)
                        .font(AppFont.body(weight: .regular))
                        .foregroundStyle(.secondary)
                    RemodexIcon.image(systemName: "chevron.right", size: 13, relativeTo: .body)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auto-review, \(statusLabel)")
            .accessibilityHint(isExpanded ? "Collapse review details" : "Expand review details")

            if isExpanded {
                details
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var rowTitle: String {
        "Auto-review · \(statusLabel)"
    }

    private var statusLabel: String {
        switch review.status {
        case .inProgress:
            return "Reviewing"
        case .approved:
            return "Approved"
        case .denied:
            return "Denied"
        case .timedOut:
            return "Timed out"
        case .aborted:
            return "Stopped"
        case .unknown:
            return "Updated"
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(review.actionSummary)
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            if let riskLabel {
                Text(riskLabel)
                    .font(AppFont.caption())
                    .foregroundStyle(statusColor)
            }

            if let authorization = normalizedAuthorization {
                Text("Authorization: \(authorization)")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            if let rationale = normalizedRationale {
                Text(rationale)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if review.status == .denied {
                retryControl
            }

            if let retryErrorMessage {
                Text(retryErrorMessage)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
            }
        }
        .padding(.leading, 25)
    }

    @ViewBuilder
    private var retryControl: some View {
        if review.retryApproved {
            Label("Approval recorded; the retry will still be reviewed", systemImage: "checkmark")
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(.secondary)
        } else if let retryUnavailableReason = review.retryUnavailableReason {
            Text(retryUnavailableReason)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        } else {
            Button {
                approveOneRetry()
            } label: {
                HStack(spacing: 7) {
                    if isApprovingRetry {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Approve one retry")
                }
                .font(AppFont.footnote(weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.blue)
            .disabled(isApprovingRetry)
        }
    }

    private var normalizedRationale: String? {
        guard let rationale = review.rationale?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rationale.isEmpty else {
            return nil
        }
        return rationale
    }

    private var riskLabel: String? {
        guard let risk = review.riskLevel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !risk.isEmpty else {
            return nil
        }
        return "\(risk.capitalized) risk"
    }

    private var normalizedAuthorization: String? {
        guard let authorization = review.userAuthorization?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !authorization.isEmpty else {
            return nil
        }
        return authorization
    }

    // Every status name resolves to a bundled Central asset in RemodexIcon
    // so the row matches the app's icon language instead of raw SF Symbols.
    private var statusIconSystemName: String {
        switch review.status {
        case .inProgress, .approved:
            return "remodex.auto-review"
        case .denied:
            return "exclamationmark.triangle.fill"
        case .timedOut:
            return "hourglass"
        case .aborted:
            return "xmark.circle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch review.status {
        case .inProgress:
            return .secondary
        case .approved:
            return .green
        case .denied:
            return .orange
        case .timedOut, .aborted:
            return .secondary
        case .unknown:
            return .secondary
        }
    }

    private func approveOneRetry() {
        guard !isApprovingRetry else {
            return
        }

        HapticFeedback.shared.triggerImpactFeedback(style: .light)
        isApprovingRetry = true
        retryErrorMessage = nil

        Task { @MainActor in
            defer { isApprovingRetry = false }
            do {
                try await codex.approveAutoApprovalRetry(
                    threadId: threadId,
                    reviewId: review.reviewId
                )
            } catch {
                retryErrorMessage = error.localizedDescription
            }
        }
    }
}
