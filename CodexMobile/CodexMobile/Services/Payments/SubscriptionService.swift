// FILE: SubscriptionService.swift
// Purpose: Owns RevenueCat customer state, offerings, purchase/restore flows, and the local free-send gate.
// Layer: Service
// Exports: SubscriptionService, SubscriptionPackageOption
// Depends on: Foundation, Observation, RevenueCat

import Foundation
import Observation
import RevenueCat

enum SubscriptionBootstrapState: Equatable {
    case idle
    case loading
    case ready
    case failed
}

struct SubscriptionPackageOption: Identifiable {
    let id: String
    let package: Package

    var title: String {
        package.storeProduct.localizedTitle
    }

    var price: String {
        package.storeProduct.localizedPriceString
    }

    var periodLabel: String {
        package.storeProduct.subscriptionPeriod?.durationTitle ?? ""
    }

    var termsDescription: String {
        package.termsDescription()
    }
}

private struct CachedSubscriptionState: Codable, Equatable {
    let hasProAccess: Bool
    let latestPurchaseDate: Date?
    let willRenew: Bool
    let managementURLString: String?
}

@MainActor
@Observable
final class SubscriptionService {
    private static let cachedStateDefaultsKey = "codex.subscription.cachedState"
    private static let freeSendCountDefaultsKey = "codex.subscription.freeSendCount"
    private static let freeSendLimit = 5

    private let defaults: UserDefaults
    // Keep the task handle nonisolated so `deinit` can cancel it under Swift 6 isolation rules.
    nonisolated(unsafe) private var customerInfoUpdatesTask: Task<Void, Never>?
    private var isBootstrapping = false
    private var hasCachedOptimisticAccess = false

    private(set) var bootstrapState: SubscriptionBootstrapState = .idle
    private(set) var customerInfo: CustomerInfo?
    private(set) var currentOffering: Offering?
    private(set) var packageOptions: [SubscriptionPackageOption] = []
    private(set) var hasProAccess = false
    private(set) var freeSendCount = 0
    private(set) var latestPurchaseDate: Date?
    private(set) var willRenew = false
    private(set) var managementURL: URL?
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var lastErrorMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreCachedStateIfAvailable()
        startCustomerInfoObserverIfConfigured()
    }

    deinit {
        customerInfoUpdatesTask?.cancel()
    }

    var remainingFreeSendAttempts: Int {
        max(0, Self.freeSendLimit - freeSendCount)
    }

    var hasFreeSendAccess: Bool {
        freeSendCount < Self.freeSendLimit
    }

    var hasAppAccess: Bool {
        hasProAccess || hasFreeSendAccess
    }

    // Counts a valid send attempt for free users even if the turn later fails.
    func consumeFreeSendAttemptIfNeeded() {
        guard !hasProAccess, freeSendCount < Self.freeSendLimit else {
            return
        }

        freeSendCount += 1
        defaults.set(freeSendCount, forKey: Self.freeSendCountDefaultsKey)
    }

    // Bootstraps subscription state once at launch or from the recovery retry action.
    func bootstrap() async {
        guard !isBootstrapping else {
            return
        }

        isBootstrapping = true
        defer { isBootstrapping = false }
        startCustomerInfoObserverIfConfigured()
        let hadOptimisticAccess = hasCachedOptimisticAccess
        if !hadOptimisticAccess {
            bootstrapState = .loading
        }
        isLoading = true
        lastErrorMessage = nil

        guard Purchases.isConfigured else {
            if !hadOptimisticAccess {
                bootstrapState = .failed
                lastErrorMessage = "Subscriptions are unavailable right now."
            }
            isLoading = false
            return
        }

        async let offeringsTask = refreshOfferings(updatesLastError: !hadOptimisticAccess)
        await refreshCustomerInfo(updatesLastError: !hadOptimisticAccess)

        bootstrapState = (customerInfo != nil || hadOptimisticAccess) ? .ready : .failed
        await offeringsTask
        isLoading = false
    }

    // Refreshes the current subscription state without re-entering the blocking bootstrap UI.
    func refreshCustomerInfoSilently() async {
        guard !isBootstrapping, bootstrapState != .loading else {
            return
        }

        startCustomerInfoObserverIfConfigured()
        guard Purchases.isConfigured else {
            return
        }

        await refreshCustomerInfo(updatesLastError: false)

        if customerInfo != nil || bootstrapState == .ready {
            bootstrapState = .ready
        } else if bootstrapState == .idle {
            bootstrapState = .failed
        }
    }

    // Reads the current RevenueCat offerings and normalizes the package list for SwiftUI.
    func loadOfferings() async {
        startCustomerInfoObserverIfConfigured()
        isLoading = true
        lastErrorMessage = nil
        if Purchases.isConfigured {
            await refreshOfferings(updatesLastError: true)
        }
        isLoading = false
    }

    // Starts a purchase flow for the selected package and refreshes entitlements on success.
    func purchase(_ option: SubscriptionPackageOption) async {
        guard !isPurchasing else {
            return
        }

        startCustomerInfoObserverIfConfigured()
        guard Purchases.isConfigured else {
            lastErrorMessage = "Subscriptions are unavailable right now."
            return
        }

        isPurchasing = true
        lastErrorMessage = nil

        do {
            let result = try await Purchases.shared.purchase(package: option.package)
            applyCustomerInfo(result.customerInfo)
            bootstrapState = .ready
        } catch let error as RevenueCat.ErrorCode {
            if error == .purchaseCancelledError {
                lastErrorMessage = nil
            } else if error == .paymentPendingError {
                lastErrorMessage = "Purchase pending approval."
            } else {
                lastErrorMessage = error.localizedDescription
            }
        } catch {
            lastErrorMessage = userFacingMessage(for: error)
        }

        isPurchasing = false
        await refreshCustomerInfoSilently()
    }

    // Restores store purchases and then re-checks the Pro entitlement state.
    func restorePurchases() async {
        guard !isRestoring else {
            return
        }

        startCustomerInfoObserverIfConfigured()
        guard Purchases.isConfigured else {
            lastErrorMessage = "Subscriptions are unavailable right now."
            return
        }

        isRestoring = true
        lastErrorMessage = nil

        do {
            let restoredInfo = try await Purchases.shared.restorePurchases()
            applyCustomerInfo(restoredInfo)
            bootstrapState = .ready
        } catch {
            lastErrorMessage = userFacingMessage(for: error)
        }

        isRestoring = false
        await refreshCustomerInfoSilently()
    }
}

private extension SubscriptionService {
    func startCustomerInfoObserverIfConfigured() {
        guard customerInfoUpdatesTask == nil, Purchases.isConfigured else {
            return
        }

        customerInfoUpdatesTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                guard let self else {
                    break
                }

                await self.handleCustomerInfoStreamUpdate(info)
            }
        }
    }

    func handleCustomerInfoStreamUpdate(_ info: CustomerInfo) {
        applyCustomerInfo(info)
        bootstrapState = .ready
    }

    func refreshOfferings(updatesLastError: Bool) async {
        do {
            let offerings = try await Purchases.shared.offerings()
            let preferredOffering = offerings.current
                ?? offerings.offering(identifier: AppEnvironment.revenueCatDefaultOfferingID)
            currentOffering = preferredOffering
            packageOptions = normalizedPackageOptions(from: preferredOffering)
            lastErrorMessage = nil
        } catch {
            if updatesLastError {
                lastErrorMessage = userFacingMessage(for: error)
            }
        }
    }

    func refreshCustomerInfo(updatesLastError: Bool) async {
        do {
            let info = try await Purchases.shared.customerInfo()
            applyCustomerInfo(info)
        } catch {
            if updatesLastError {
                lastErrorMessage = userFacingMessage(for: error)
            }
        }
    }

    func applyCustomerInfo(_ info: CustomerInfo) {
        customerInfo = info
        let entitlement = info.entitlements.all[AppEnvironment.revenueCatEntitlementName]
        hasProAccess = entitlement?.isActive == true
        hasCachedOptimisticAccess = hasProAccess
        latestPurchaseDate = entitlement?.latestPurchaseDate
        willRenew = entitlement?.willRenew == true
        managementURL = info.managementURL
        lastErrorMessage = nil
        persistCachedState()
    }

    // Rehydrates the last known subscription snapshot so launch and foreground recovery are local-first.
    func restoreCachedStateIfAvailable() {
        freeSendCount = defaults.integer(forKey: Self.freeSendCountDefaultsKey)
        guard let data = defaults.data(forKey: Self.cachedStateDefaultsKey),
              let cachedState = try? JSONDecoder().decode(CachedSubscriptionState.self, from: data) else {
            return
        }

        hasProAccess = cachedState.hasProAccess
        hasCachedOptimisticAccess = cachedState.hasProAccess
        latestPurchaseDate = cachedState.latestPurchaseDate
        willRenew = cachedState.willRenew
        managementURL = cachedState.managementURLString.flatMap(URL.init(string:))
        bootstrapState = cachedState.hasProAccess ? .ready : .idle
    }

    func persistCachedState() {
        let cachedState = CachedSubscriptionState(
            hasProAccess: hasProAccess,
            latestPurchaseDate: latestPurchaseDate,
            willRenew: willRenew,
            managementURLString: managementURL?.absoluteString
        )

        guard let encodedState = try? JSONEncoder().encode(cachedState) else {
            return
        }

        defaults.set(encodedState, forKey: Self.cachedStateDefaultsKey)
    }

    func normalizedPackageOptions(from offering: Offering?) -> [SubscriptionPackageOption] {
        guard let offering else {
            return []
        }

        return offering.availablePackages
            .sorted { lhs, rhs in
                packageSortKey(for: lhs) < packageSortKey(for: rhs)
            }
            .map { package in
                SubscriptionPackageOption(
                    id: package.identifier,
                    package: package
                )
            }
    }

    func packageSortKey(for package: Package) -> Int {
        switch package.packageType {
        case .monthly:
            return 0
        case .annual:
            return 1
        default:
            return 2
        }
    }

    func userFacingMessage(for error: Error) -> String {
        if let errorCode = error as? RevenueCat.ErrorCode {
            return errorCode.localizedDescription
        }
        return error.localizedDescription
    }
}
