// FILE: SettingsSubscriptionCard.swift
// Purpose: Presents Remodex Pro subscription status and purchase actions.
// Layer: Settings UI component
// Exports: SettingsSubscriptionCard
// Depends on: SwiftUI, StoreKit, SubscriptionService, RevenueCatPaywallView

import StoreKit
import SwiftUI

struct SettingsSubscriptionCard: View {
    @Environment(SubscriptionService.self) private var subscriptions
    @State private var isPresentingPaywall = false
    @State private var isPresentingOfferCodeRedemption = false

    var body: some View {
        SettingsCard(title: "Remodex Pro") {
            HStack {
                Text("Status")
                Spacer()
                Text(subscriptions.hasProAccess ? "Active" : "Free")
                    .foregroundStyle(subscriptions.hasProAccess ? .green : .secondary)
            }

            if subscriptions.hasProAccess {
                Text("Your Pro access is active. You can still restore purchases or manage the purchase from Apple.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            } else {
                Text("Open the custom paywall to choose a monthly, yearly, or lifetime plan.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }

            SettingsButton(subscriptions.hasProAccess ? "View Pro" : "Upgrade to Pro") {
                isPresentingPaywall = true
            }

            SettingsButton("Redeem Code") {
                isPresentingOfferCodeRedemption = true
            }
            .disabled(subscriptions.isPurchasing || subscriptions.isRestoring)

            SettingsButton(subscriptions.isRestoring ? "Restoring..." : "Restore Purchases", isLoading: subscriptions.isRestoring) {
                Task {
                    await subscriptions.restorePurchases()
                }
            }
            .disabled(subscriptions.isPurchasing)

            if let error = subscriptions.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $isPresentingPaywall) {
            RevenueCatPaywallView()
        }
        .offerCodeRedemption(isPresented: $isPresentingOfferCodeRedemption) { result in
            Task {
                if case .failure = result {
                    await subscriptions.refreshCustomerInfoSilently()
                } else {
                    await subscriptions.syncPurchasesAfterOfferCodeRedemption()
                }
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
