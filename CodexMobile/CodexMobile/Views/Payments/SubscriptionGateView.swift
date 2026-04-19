// FILE: SubscriptionGateView.swift
// Purpose: Locked shell shown before app access when Remodex Pro is required.
// Layer: View
// Exports: SubscriptionGateView
// Depends on: SwiftUI, SubscriptionService, RevenueCatPaywallView

import SwiftUI

private struct SubscriptionGateFeature: Identifiable {
    let id: Int
    let icon: String
    let title: String
    let subtitle: String
}

private let subscriptionGateFeatures: [SubscriptionGateFeature] = [
    .init(id: 0, icon: "bolt.fill", title: "Fast mode", subtitle: "Lower-latency turns for quick interactions"),
    .init(id: 1, icon: "arrow.triangle.branch", title: "Git from your phone", subtitle: "Commit, push, pull, and switch branches"),
    .init(id: 2, icon: "lock.shield.fill", title: "E2EE", subtitle: "The relay never sees your prompts or code"),
    .init(id: 3, icon: "waveform", title: "Voice mode", subtitle: "Speech-to-text transcription for your messages"),
    .init(id: 4, icon: "point.3.connected.trianglepath.dotted", title: "Subagents", subtitle: "Delegate complex tasks to specialized sub-agents"),
    .init(id: 5, icon: "at", title: "$skills /cmds @files", subtitle: "Invoke skills, run slash commands, and mention files inline"),
    .init(id: 6, icon: "server.rack", title: "Hosted relay", subtitle: "You are paying for the product and the hosted path"),
    .init(id: 7, icon: "heart", title: "Support development", subtitle: "Help keep Remodex independent and open source"),
]

struct SubscriptionGatePreviewPlan: Identifiable {
    let id: String
    let title: String
    let price: String
    let termsDescription: String
}

struct SubscriptionGateView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SubscriptionService.self) private var subscriptions

    @State private var isPresentingPaywall = false

    private let previewPlans: [SubscriptionGatePreviewPlan]?
    private let previewIsLoading: Bool
    private let previewErrorMessage: String?

    init(
        previewPlans: [SubscriptionGatePreviewPlan]? = nil,
        previewIsLoading: Bool = false,
        previewErrorMessage: String? = nil
    ) {
        self.previewPlans = previewPlans
        self.previewIsLoading = previewIsLoading
        self.previewErrorMessage = previewErrorMessage
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 28) {
                        hero
                            .padding(.horizontal, 20)
                        featureList
                        pricingCard
                            .padding(.horizontal, 20)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                }

                bottomBar
            }
        }
        .fullScreenCover(isPresented: $isPresentingPaywall) {
            RevenueCatPaywallView()
        }
    }

    private var hero: some View {
        VStack(spacing: 20) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(heroStrokeColor, lineWidth: 1)
                )

            VStack(spacing: 10) {
                Text("Remodex Pro Required")
                    .font(AppFont.system(size: 24, weight: .bold))
                    .foregroundStyle(primaryTextColor)
                    .multilineTextAlignment(.center)

                Text("Unlock monthly, yearly, or lifetime access to connect your iPhone to Codex running on your Mac.")
                    .font(AppFont.caption())
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What you get")
                .font(AppFont.system(size: 26, weight: .bold))
                .foregroundStyle(primaryTextColor)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(subscriptionGateFeatures) { feature in
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: feature.icon)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(accentColor)
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(iconTileFill)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.title)
                                    .font(AppFont.subheadline(weight: .semibold))
                                    .foregroundStyle(primaryTextColor)

                                Text(feature.subtitle)
                                    .font(AppFont.caption())
                                    .foregroundStyle(secondaryTextColor)
                                    .lineLimit(3)
                            }
                        }
                        .frame(width: 200, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(cardFillColor)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(cardStrokeColor, lineWidth: 1)
                                )
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var pricingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pricing")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(primaryTextColor)

            if displayedPlans.isEmpty {
                if shouldShowLoadingPricing {
                    loadingPricingCard
                } else {
                    unavailablePricingCard
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(displayedPlans.enumerated()), id: \.element.id) { index, plan in
                        HStack {
                            Text(plan.title)
                                .font(AppFont.subheadline(weight: .semibold))
                                .foregroundStyle(primaryTextColor)
                            Spacer()
                            Text(plan.termsDescription)
                                .font(AppFont.caption())
                                .foregroundStyle(secondaryTextColor)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        if index < displayedPlans.count - 1 {
                            Rectangle()
                                .fill(dividerColor)
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(cardFillColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(cardStrokeColor, lineWidth: 1)
                        )
                )
            }
        }
    }

    // Keeps first-launch loading scoped to the pricing area instead of blanking the whole paywall shell.
    private var loadingPricingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(accentColor)
            Text("Loading pricing...")
                .font(AppFont.caption(weight: .medium))
                .foregroundStyle(primaryTextColor)
            }

            Text("Monthly, yearly, and lifetime plans will appear here in a moment.")
                .font(AppFont.caption())
                .foregroundStyle(secondaryTextColor)

            VStack(spacing: 10) {
                pricingPlaceholderRow
                pricingPlaceholderRow
            }
            .redacted(reason: .placeholder)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(cardStrokeColor, lineWidth: 1)
                )
        )
    }

    private var unavailablePricingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pricing is unavailable right now.")
                .font(AppFont.caption(weight: .medium))
                .foregroundStyle(primaryTextColor)

            Text("We couldn't load the available plans yet. Try again in a moment.")
                .font(AppFont.caption())
                .foregroundStyle(secondaryTextColor)

            Button {
                Task {
                    await subscriptions.loadOfferings()
                }
            } label: {
                Text("Retry pricing")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(ctaForegroundColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(ctaBackgroundColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isPurchasing || isRestoring)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(cardStrokeColor, lineWidth: 1)
                )
        )
    }

    private var pricingPlaceholderRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Remodex Pro")
                    .font(AppFont.subheadline(weight: .semibold))
                Text("$0.00 / month")
                    .font(AppFont.caption())
                    .foregroundStyle(secondaryTextColor)
            }
            Spacer()
        }
        .foregroundStyle(primaryTextColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(backgroundColor.opacity(colorScheme == .dark ? 0.55 : 0.75))
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            Button {
                isPresentingPaywall = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Unlock Now")
                        .font(AppFont.body(weight: .semibold))
                }
                .foregroundStyle(ctaForegroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(ctaBackgroundColor, in: Capsule())
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                Button(isRestoring ? "Restoring..." : "Restore Purchase") {
                    Task {
                        await subscriptions.restorePurchases()
                    }
                }
                .disabled(isPurchasing || isRestoring)

                Text(" · ").foregroundStyle(secondaryTextColor)

                Button("Privacy") {
                    UIApplication.shared.open(AppEnvironment.privacyPolicyURL)
                }

                Text(" · ").foregroundStyle(secondaryTextColor)

                Button("Terms") {
                    UIApplication.shared.open(AppEnvironment.termsOfUseURL)
                }
            }
            .font(AppFont.caption(weight: .medium))
            .foregroundStyle(secondaryTextColor)

            if let error = errorMessage, !error.isEmpty {
                Text(error)
                    .font(AppFont.caption())
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            OpenSourceBadge(style: colorScheme == .dark ? .light : .dark)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [backgroundColor.opacity(0), backgroundColor.opacity(0.82), backgroundColor],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)
            .offset(y: -50),
            alignment: .top
        )
    }

    private var isPreviewMode: Bool {
        previewPlans != nil
    }

    private var displayedPlans: [SubscriptionGatePreviewPlan] {
        if let previewPlans {
            return previewPlans
        }

        return subscriptions.packageOptions.map { option in
            SubscriptionGatePreviewPlan(
                id: option.id,
                title: option.title,
                price: option.price,
                termsDescription: option.termsDescription
            )
        }
    }

    private var isLoading: Bool {
        isPreviewMode ? previewIsLoading : subscriptions.isLoading
    }

    private var shouldShowLoadingPricing: Bool {
        if isPreviewMode {
            return previewIsLoading
        }

        return subscriptions.isLoading || subscriptions.bootstrapState == .idle
    }

    private var errorMessage: String? {
        isPreviewMode ? previewErrorMessage : subscriptions.lastErrorMessage
    }

    private var isPurchasing: Bool {
        isPreviewMode ? false : subscriptions.isPurchasing
    }

    private var isRestoring: Bool {
        isPreviewMode ? false : subscriptions.isRestoring
    }

    private var backgroundColor: Color {
        Color(.systemBackground)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.55) : .secondary
    }

    private var heroStrokeColor: Color {
        colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08)
    }

    private var accentColor: Color {
        colorScheme == .dark ? .white.opacity(0.8) : Color(.plan)
    }

    private var iconTileFill: Color {
        colorScheme == .dark ? .white.opacity(0.08) : Color(.plan).opacity(0.12)
    }

    private var cardFillColor: Color {
        colorScheme == .dark ? .white.opacity(0.05) : Color(.secondarySystemBackground)
    }

    private var cardStrokeColor: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)
    }

    private var dividerColor: Color {
        colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.06)
    }

    private var ctaBackgroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var ctaForegroundColor: Color {
        colorScheme == .dark ? .black : .white
    }
}

struct SubscriptionBootstrapFailureView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SubscriptionService.self) private var subscriptions

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 20) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(primaryTextColor)
                        .frame(width: 72, height: 72)
                        .background(
                            Circle()
                                .fill(cardFillColor)
                        )

                    VStack(spacing: 10) {
                        Text("Couldn’t load subscription status")
                            .font(AppFont.system(size: 24, weight: .bold))
                            .foregroundStyle(primaryTextColor)
                            .multilineTextAlignment(.center)

                        Text("Remodex couldn’t confirm your Pro access yet. Check your connection, retry, or restore your App Store purchases.")
                            .font(AppFont.caption())
                            .foregroundStyle(secondaryTextColor)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }

                    if let error = subscriptions.lastErrorMessage, !error.isEmpty {
                        Text(error)
                            .font(AppFont.caption())
                            .foregroundStyle(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        Button {
                            Task {
                                await subscriptions.bootstrap()
                            }
                        } label: {
                            Text("Retry")
                                .font(AppFont.body(weight: .semibold))
                                .foregroundStyle(ctaForegroundColor)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(ctaBackgroundColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(subscriptions.bootstrapState == .loading || subscriptions.isRestoring)

                        Button(subscriptions.isRestoring ? "Restoring..." : "Restore Purchases") {
                            Task {
                                await subscriptions.restorePurchases()
                            }
                        }
                        .font(AppFont.body(weight: .medium))
                        .disabled(subscriptions.bootstrapState == .loading || subscriptions.isRestoring)
                    }
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 32)

                VStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Button("Privacy") {
                            UIApplication.shared.open(AppEnvironment.privacyPolicyURL)
                        }

                        Text(" · ").foregroundStyle(secondaryTextColor)

                        Button("Terms") {
                            UIApplication.shared.open(AppEnvironment.termsOfUseURL)
                        }
                    }
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(secondaryTextColor)

                    OpenSourceBadge(style: colorScheme == .dark ? .light : .dark)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }

    private var backgroundColor: Color {
        Color(.systemBackground)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .primary
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? .white.opacity(0.55) : .secondary
    }

    private var cardFillColor: Color {
        colorScheme == .dark ? .white.opacity(0.05) : Color(.secondarySystemBackground)
    }

    private var ctaBackgroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var ctaForegroundColor: Color {
        colorScheme == .dark ? .black : .white
    }
}

private struct SubscriptionMacLoginInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Remodex connects to Codex running on your Mac. Buying Pro unlocks the app, but you still need Codex already logged in on the Mac side.")
                        .font(AppFont.body())

                    infoStep(
                        number: 1,
                        title: "Open Codex on your Mac",
                        body: "Use the Codex desktop app or the Codex CLI on the Mac you want to pair."
                    )

                    infoStep(
                        number: 2,
                        title: "Log in there first",
                        body: "Finish the account login flow on the Mac before pairing from iPhone."
                    )

                    infoStep(
                        number: 3,
                        title: "Run remodex up",
                        body: "The bridge prints a QR code. Scan that QR from the iPhone app after you have Pro access."
                    )
                }
                .padding(20)
            }
            .navigationTitle("Use with Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func infoStep(number: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color(.plan))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                Text(body)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    SubscriptionGateView(
        previewPlans: [
            SubscriptionGatePreviewPlan(
                id: "monthly",
                title: "Monthly",
                price: "$3.99",
                termsDescription: "$3.99 / month"
            ),
            SubscriptionGatePreviewPlan(
                id: "yearly",
                title: "Annual",
                price: "$29.99",
                termsDescription: "$29.99 / year"
            )
        ]
    )
    .environment(SubscriptionService())
}

#Preview("Light") {
    SubscriptionGateView(
        previewPlans: [
            SubscriptionGatePreviewPlan(
                id: "monthly",
                title: "Monthly",
                price: "$3.99",
                termsDescription: "$3.99 / month"
            ),
            SubscriptionGatePreviewPlan(
                id: "yearly",
                title: "Annual",
                price: "$29.99",
                termsDescription: "$29.99 / year"
            )
        ]
    )
    .environment(SubscriptionService())
    .preferredColorScheme(.light)
}

#Preview("Loading") {
    SubscriptionGateView(
        previewPlans: [],
        previewIsLoading: true
    )
    .environment(SubscriptionService())
}

#Preview("With Error") {
    SubscriptionGateView(
        previewPlans: [
            SubscriptionGatePreviewPlan(
                id: "monthly",
                title: "Monthly",
                price: "$3.99",
                termsDescription: "$3.99 / month"
            ),
            SubscriptionGatePreviewPlan(
                id: "yearly",
                title: "Annual",
                price: "$29.99",
                termsDescription: "$29.99 / year"
            )
        ],
        previewErrorMessage: "Could not restore purchases right now."
    )
    .environment(SubscriptionService())
}
