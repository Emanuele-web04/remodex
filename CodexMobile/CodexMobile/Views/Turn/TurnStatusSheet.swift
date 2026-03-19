// FILE: TurnStatusSheet.swift
// Purpose: Presents the local session status summary for the `/status` composer command.
// Layer: View Component
// Exports: TurnStatusSheet
// Depends on: SwiftUI, UsageStatusSummaryContent

import SwiftUI

struct TurnStatusSheet: View {
    let contextWindowUsage: ContextWindowUsage?
    let rateLimitBuckets: [CodexRateLimitBucket]
    let isLoadingRateLimits: Bool
    let rateLimitsErrorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                statusCard
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .adaptiveNavigationBar()
        }
        .presentationDetents([.fraction(0.4), .medium, .large])
    }

    private var statusCard: some View {
        UsageStatusSummaryContent(
            contextWindowUsage: contextWindowUsage,
            rateLimitBuckets: rateLimitBuckets,
            isLoadingRateLimits: isLoadingRateLimits,
            rateLimitsErrorMessage: rateLimitsErrorMessage
        )
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
