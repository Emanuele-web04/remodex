// FILE: SettingsSubscriptionCard.swift
// Purpose: Presents Remodex Pro subscription status and purchase actions.
// Layer: Settings UI component
// Exports: SettingsSubscriptionCard
// Depends on: SwiftUI, StoreKit, SubscriptionService, RevenueCatPaywallView

import StoreKit
import SwiftUI

struct SettingsSubscriptionCard: View {
    @Environment(SubscriptionService.self) private var subscriptions
    let onShowPaywall: () -> Void
    let onRedeemCode: () -> Void

    var body: some View {
        SettingsCard(
            title: "Remodex Pro",
            footer: subscriptions.hasProAccess
                ? "Manage billing through your Apple ID subscription settings."
                : "Unlock voice mode, unlimited threads, and more."
        ) {
            SettingsValueRow(
                title: "Plan",
                value: subscriptions.hasProAccess ? "Active" : "Free",
                valueColor: subscriptions.hasProAccess ? .green : .secondary
            )

            SettingsButton(subscriptions.hasProAccess ? "View Pro Benefits" : "Upgrade to Pro") {
                onShowPaywall()
            }

            SettingsButton("Redeem Code") {
                onRedeemCode()
            }
            .disabled(subscriptions.isPurchasing || subscriptions.isRestoring)

            SettingsButton(
                subscriptions.isRestoring ? "Restoring…" : "Restore Purchases",
                isLoading: subscriptions.isRestoring
            ) {
                Task {
                    await subscriptions.restorePurchases()
                }
            }
            .disabled(subscriptions.isPurchasing)

            if let error = subscriptions.lastErrorMessage, !error.isEmpty {
                SettingsInlineMessage(text: error, tint: .red)
            }
        }
        .task {
            guard subscriptions.bootstrapState == .idle else {
                return
            }
            await subscriptions.bootstrap()
        }
    }
}
