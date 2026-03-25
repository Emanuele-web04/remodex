// FILE: RevenueCatPaywallView.swift
// Purpose: Custom RevenueCat paywall flow for selecting a plan and purchasing Pro access.
// Layer: View
// Exports: RevenueCatPaywallView
// Depends on: SwiftUI, SubscriptionService

import RevenueCat
import SwiftUI

struct RevenueCatPaywallPreviewPlan: Identifiable, Equatable {
    let id: String
    let title: String
    let price: String
    let periodLabel: String
    let termsDescription: String
    let isBestValue: Bool
}

// MARK: - Feature data

private struct PaywallFeature: Identifiable {
    let id: Int
    let icon: String
    let title: String
}

private let paywallFeatures: [PaywallFeature] = [
    .init(id: 0, icon: "bolt", title: "Fast mode"),
    .init(id: 1, icon: "arrow.triangle.branch", title: "Git from your phone"),
    .init(id: 2, icon: "lock.shield", title: "End-to-end encrypted"),
    .init(id: 3, icon: "waveform", title: "Voice mode with speech-to-text"),
    .init(id: 4, icon: "point.3.connected.trianglepath.dotted", title: "Subagents"),
    .init(id: 5, icon: "at", title: "$skills, /commands & @file mentions"),
    .init(id: 6, icon: "server.rack", title: "Hosted relay included"),
    .init(id: 7, icon: "heart", title: "Support development"),
]

// MARK: - Main paywall

struct RevenueCatPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SubscriptionService.self) private var subscriptions

    @State private var selectedPackageID: String?
    @State private var appeared = false
    @State private var showCloseButton = false

    private let dismissable: Bool
    private let previewPlans: [RevenueCatPaywallPreviewPlan]?
    private let previewLatestPurchaseDate: Date?
    private let previewHasProAccess: Bool
    private let previewErrorMessage: String?
    private let previewIsLoading: Bool

    // Accent tint for the paywall — black in light, white in dark.
    private var accent: Color { colorScheme == .dark ? .white : .black }
    private var accentForeground: Color { colorScheme == .dark ? .black : .white }

    init(
        dismissable: Bool = true,
        previewPlans: [RevenueCatPaywallPreviewPlan]? = nil,
        previewLatestPurchaseDate: Date? = nil,
        previewHasProAccess: Bool = false,
        previewErrorMessage: String? = nil,
        previewIsLoading: Bool = false
    ) {
        self.dismissable = dismissable
        self.previewPlans = previewPlans
        self.previewLatestPurchaseDate = previewLatestPurchaseDate
        self.previewHasProAccess = previewHasProAccess
        self.previewErrorMessage = previewErrorMessage
        self.previewIsLoading = previewIsLoading
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        header
                        
                        featureCard
                    }
                    .padding(.horizontal, 20)
             
                    .padding(.bottom, 16)
                }

                Spacer(minLength: 0)

                bottomSection
                    
            }
            .opacity(appeared ? 1 : 0)
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if dismissable, showCloseButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(!dismissable)
            .task {
                guard !isPreviewMode else {
                    seedDefaultSelectionIfNeeded()
                    return
                }

                await subscriptions.loadOfferings()
                seedDefaultSelectionIfNeeded()
            }
            .onChange(of: subscriptions.packageOptions.map(\.id)) { _, _ in
                seedDefaultSelectionIfNeeded()
            }
            .onChange(of: subscriptions.hasProAccess) { _, hasAccess in
                if hasAccess, dismissable {
                    dismiss()
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.4)) {
                    appeared = true
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeInOut(duration: 0.3)) {
                    showCloseButton = true
                }
            }
        }
    }

    // MARK: - Header (logo + title + subtitle)

    private var header: some View {
        VStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                

            Text("Unlock Remodex Pro")
                .font(AppFont.system(size: 24, weight: .bold))

            Text("Everything runs on your Mac. Your phone is the remote.")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Promo banner

   

    // MARK: - Feature card

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Here's what you'll get")
                .font(AppFont.body(weight: .semibold))
                .padding(.bottom, 2)

            ForEach(paywallFeatures) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                    
                    Text(feature.title)
                        .font(AppFont.subheadline())
                    
                    Spacer(minLength: 0)
                    
                }
            }
        }

        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
        )
    }

    // MARK: - Bottom section (plans + CTA + links)

    private var bottomSection: some View {
        VStack(spacing: 10) {
            planSelection

            // CTA
            if selectedPlan != nil {
                Button {
                    guard let selectedOption else { return }
                    Task {
                        await subscriptions.purchase(selectedOption)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if subscriptions.isPurchasing {
                            ProgressView()
                                .tint(colorScheme == .dark ? .black : .white)
                        } else {
                       
                            Text("Unlock Remodex Pro")
                                .font(AppFont.body(weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .clipShape(Capsule())
                   
                }
                .disabled(subscriptions.isPurchasing || subscriptions.isRestoring)
            }

            // Footer
            VStack(spacing: 4) {
                Text("Recurring Billing. Cancel anytime.")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    Button(subscriptions.isRestoring ? "Restoring..." : "Restore Purchase") {
                        Task {
                            await subscriptions.restorePurchases()
                        }
                    }
                    .disabled(subscriptions.isPurchasing || subscriptions.isRestoring)

                    if let managementURL {
                        Text(" · ").foregroundStyle(.secondary)
                        Button("Manage") {
                            UIApplication.shared.open(managementURL)
                        }
                    }

                    Text(" · ").foregroundStyle(.secondary)
                    Button("Privacy") {
                        UIApplication.shared.open(AppEnvironment.privacyPolicyURL)
                    }

                    Text(" · ").foregroundStyle(.secondary)
                    Button("Terms") {
                        UIApplication.shared.open(AppEnvironment.termsOfUseURL)
                    }
                }
                .font(AppFont.caption(weight: .medium))
                .foregroundStyle(.secondary)
            }

            if hasProAccess {
                Text("Pro is already active on this account.")
                    .font(AppFont.caption())
                    .foregroundStyle(.green)
            }

            if let error = errorMessage, !error.isEmpty {
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Color.secondary.opacity(0.1), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 8)
            .offset(y: -8)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Plan selection (side-by-side cards like Khrona)

    private var planSelection: some View {
        HStack(spacing: 10) {
            if isLoading && displayedPlans.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ForEach(displayedPlans) { plan in
                    planCard(for: plan)
                }
            }
        }
    }

    private func planCard(for plan: RevenueCatPaywallPreviewPlan) -> some View {
        let isSelected = selectedPackageID == plan.id

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedPackageID = plan.id
            }
            HapticFeedback.shared.triggerImpactFeedback()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Top row: radio + badge
                HStack {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? (colorScheme == .dark ? .black : .white) : .secondary.opacity(0.4))

                    Spacer()

                    if plan.isBestValue {
                        Text("37% OFF")
                            .font(AppFont.caption2(weight: .semibold))
                            .foregroundStyle(isSelected ? accentForeground.opacity(0.9) : accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? accentForeground.opacity(0.2) : accent.opacity(0.12))
                            )
                    } else {
                        Text("")
                            .font(AppFont.caption2(weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .opacity(0)
                    }
                }

                Spacer(minLength: 0)

                // Bottom: title + price
                HStack(alignment: .center, spacing: 4) {
                    Text(plan.title)
                        .font(AppFont.subheadline(weight: .semibold))
Spacer()
                    Text(plan.price)
                        .font(AppFont.caption(weight: .medium))
                        .opacity(0.75)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 100)
            
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected ? accent : Color(.systemBackground))
            )
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                }
            }
            .foregroundStyle(isSelected ? accentForeground : .primary)
            
        }
        .buttonStyle(.plain)
    }

    // MARK: - State helpers

    private var isPreviewMode: Bool {
        previewPlans != nil
    }

    private var displayedPlans: [RevenueCatPaywallPreviewPlan] {
        if let previewPlans {
            return previewPlans
        }

        return subscriptions.packageOptions.map { option in
            RevenueCatPaywallPreviewPlan(
                id: option.id,
                title: option.title,
                price: option.price,
                periodLabel: option.periodLabel,
                termsDescription: option.termsDescription,
                isBestValue: option.package.packageType == .annual
            )
        }
    }

    private var selectedOption: SubscriptionPackageOption? {
        subscriptions.packageOptions.first(where: { $0.id == selectedPackageID })
    }

    private var selectedPlan: RevenueCatPaywallPreviewPlan? {
        displayedPlans.first(where: { $0.id == selectedPackageID })
    }

    private var hasProAccess: Bool {
        isPreviewMode ? previewHasProAccess : subscriptions.hasProAccess
    }

    private var willRenew: Bool {
        isPreviewMode ? false : subscriptions.willRenew
    }

    private var managementURL: URL? {
        isPreviewMode ? nil : subscriptions.managementURL
    }

    private var latestPurchaseDate: Date? {
        isPreviewMode ? previewLatestPurchaseDate : subscriptions.latestPurchaseDate
    }

    private var errorMessage: String? {
        isPreviewMode ? previewErrorMessage : subscriptions.lastErrorMessage
    }

    private var isLoading: Bool {
        isPreviewMode ? previewIsLoading : subscriptions.isLoading
    }

    private func seedDefaultSelectionIfNeeded() {
        guard selectedPackageID == nil else {
            return
        }

        if let annual = displayedPlans.first(where: { $0.isBestValue }) {
            selectedPackageID = annual.id
            return
        }

        selectedPackageID = displayedPlans.first?.id
    }
}

#Preview {
    RevenueCatPaywallView(
        previewPlans: [
            RevenueCatPaywallPreviewPlan(
                id: "monthly",
                title: "Monthly",
                price: "$3.99",
                periodLabel: "month",
                termsDescription: "$3.99 / month",
                isBestValue: false
            ),
            RevenueCatPaywallPreviewPlan(
                id: "yearly",
                title: "Annual",
                price: "$29.99",
                periodLabel: "year",
                termsDescription: "$29.99 for 1 year",
                isBestValue: true
            ),
        ],
        previewLatestPurchaseDate: Date().addingTimeInterval(-86_400 * 12)
    )
    .environment(SubscriptionService())
}
