// FILE: SubscriptionService+LocalDevice.swift
// Purpose: Personal-team device builds skip RevenueCat/StoreKit (no IAP entitlement).
// Layer: Service
// Exports: SubscriptionService, SubscriptionPackageOption, SubscriptionBootstrapState
// Depends on: Foundation, Observation

#if REMODEX_LOCAL_DEVICE

import Foundation
import Observation

enum SubscriptionBootstrapState: Equatable {
    case idle
    case loading
    case ready
    case failed
}

struct SubscriptionPackageOption: Identifiable {
    let id: String
    var title: String { "" }
    var price: String { "" }
    var termsDescription: String { "" }
}

@MainActor
@Observable
final class SubscriptionService {
    private(set) var bootstrapState: SubscriptionBootstrapState = .ready
    private(set) var packageOptions: [SubscriptionPackageOption] = []
    private(set) var hasProAccess = true
    private(set) var freeSendCount = 0
    private(set) var latestPurchaseDate: Date?
    private(set) var willRenew = false
    private(set) var managementURL: URL?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var lastErrorMessage: String?

    var remainingFreeSendAttempts: Int { 999 }
    var hasFreeSendAccess: Bool { true }
    var hasAppAccess: Bool { true }

    init(defaults: UserDefaults = .standard) {
        _ = defaults
    }

    func consumeFreeSendAttemptIfNeeded() {}

    func bootstrap() async {
        bootstrapState = .ready
    }

    func refreshCustomerInfoSilently() async {}

    func loadOfferings() async {}

    func purchase(_ option: SubscriptionPackageOption) async {
        _ = option
    }

    func restorePurchases() async {}

    func syncPurchasesAfterOfferCodeRedemption() async {}
}

#endif
