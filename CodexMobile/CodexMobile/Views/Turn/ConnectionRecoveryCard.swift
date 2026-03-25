// FILE: ConnectionRecoveryCard.swift
// Purpose: Shows a compact reconnect card above the composer using the shared glass accessory style.
// Layer: View Component
// Exports: ConnectionRecoveryCard, ConnectionRecoverySnapshot, ConnectionRecoveryStatus
// Depends on: SwiftUI, PlanAccessoryCard, AppFont

import SwiftUI

enum ConnectionRecoveryStatus: Equatable {
    case interrupted
    case reconnecting

    var label: String {
        switch self {
        case .interrupted:
            return "Interrupted"
        case .reconnecting:
            return "Reconnecting"
        }
    }

    var tint: Color {
        switch self {
        case .interrupted:
            return .orange
        case .reconnecting:
            return Color(.plan)
        }
    }
}

struct ConnectionRecoverySnapshot: Equatable {
    let title: String
    let summary: String
    let status: ConnectionRecoveryStatus
    let actionTitle: String?

    init(
        title: String = "Connection",
        summary: String,
        status: ConnectionRecoveryStatus,
        actionTitle: String?
    ) {
        self.title = title
        self.summary = summary
        self.status = status
        self.actionTitle = actionTitle
    }

    var isActionable: Bool {
        actionTitle != nil
    }
}

struct ConnectionRecoveryCard: View {
    let snapshot: ConnectionRecoverySnapshot
    let onTap: () -> Void

    var body: some View {
        GlassAccessoryCard(onTap: {
            guard snapshot.isActionable else { return }
            onTap()
        }) {
            leadingMarker
        } header: {
            headerRow
        } summary: {
            summaryRow
        } trailing: {
            trailingContent
        }
        .opacity(snapshot.isActionable ? 1 : 0.94)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.status.label)
        .accessibilityHint(snapshot.isActionable ? "Reconnects the bridge session" : "Reconnect is already in progress")
    }

    private var leadingMarker: some View {
        ZStack {
            Circle()
                .fill(snapshot.status.tint.opacity(0.1))
                .frame(width: 22, height: 22)

            Circle()
                .fill(snapshot.status.tint)
                .frame(width: 7, height: 7)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(snapshot.title)
                .font(AppFont.mono(.caption2))
                .foregroundStyle(.secondary)

            Circle()
                .fill(Color(.separator).opacity(0.6))
                .frame(width: 3, height: 3)

            Text(snapshot.status.label)
                .font(AppFont.caption(weight: .regular))
                .foregroundStyle(snapshot.status.tint)
        }
    }

    private var summaryRow: some View {
        Text(snapshot.summary)
            .font(AppFont.subheadline(weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }

    private var trailingContent: some View {
        Group {
            if let actionTitle = snapshot.actionTitle {
                Text(actionTitle)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(snapshot.status.tint)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(snapshot.status.tint)
            }
        }
        .frame(minWidth: 58, alignment: .trailing)
    }
}
