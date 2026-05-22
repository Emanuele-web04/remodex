// FILE: SidebarConnectionEmptyStateFooter.swift
// Purpose: Footer rendered above the sidebar's bottom action bar when the
//          connect/reconnect card is on screen. Hosts the long status message
//          and the destructive Forget Pair affordance so the centered panel
//          stays focused on the primary reconnect CTA.
// Layer: View Component
// Exports: SidebarConnectionEmptyStateFooter
// Depends on: SwiftUI, AppFont

import SwiftUI

struct SidebarConnectionEmptyStateFooter: View {
    let statusMessage: String?
    let canForgetPair: Bool
    let onForgetPair: () -> Void

    var body: some View {
        if hasContent {
            VStack(spacing: 10) {
                if let statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                if canForgetPair {
                    Button("Forget Pair") {
                        onForgetPair()
                    }
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private var hasContent: Bool {
        let hasMessage = (statusMessage?.isEmpty == false)
        return hasMessage || canForgetPair
    }
}

#if DEBUG
#Preview("Message + Forget Pair") {
    SidebarConnectionEmptyStateFooter(
        statusMessage: "This iPhone is no longer trusted by the paired device. Scan a new QR code to reconnect.",
        canForgetPair: true,
        onForgetPair: {}
    )
}

#Preview("Forget Pair only") {
    SidebarConnectionEmptyStateFooter(
        statusMessage: nil,
        canForgetPair: true,
        onForgetPair: {}
    )
}
#endif
