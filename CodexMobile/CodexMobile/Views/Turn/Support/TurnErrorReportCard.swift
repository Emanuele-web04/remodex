// FILE: TurnErrorReportCard.swift
// Purpose: Shows composer-adjacent errors as dismissible report cards instead of raw red footer text.
// Layer: View Component
// Exports: TurnErrorReportCard
// Depends on: SwiftUI, PlanAccessoryCard, AppFont

import SwiftUI

struct TurnErrorReportCard: View {
    let message: String
    let onReport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(Color(.systemRed))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(message)
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            reportButton
            dismissButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.clear)
                .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .accessibilityElement(children: .contain)
    }

    private var reportButton: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onReport()
        } label: {
            Text("Report")
                .font(AppFont.caption(weight: .medium))
                .foregroundStyle(Color(.systemRed))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Report issue")
    }

    private var dismissButton: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(AppFont.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss issue")
    }
}
