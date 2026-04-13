// FILE: RevenueCatDisplayExtensions.swift
// Purpose: Shared RevenueCat and StoreKit display helpers for paywall and subscription copy.
// Layer: Service
// Exports: Package termsDescription, SubscriptionPeriod display titles
// Depends on: Foundation, RevenueCat, StoreKit

import Foundation
import RevenueCat
import StoreKit

extension Package {
    // Formats subscription terms using the same style RevenueCat sample apps use.
    func termsDescription() -> String {
        if let intro = storeProduct.introductoryDiscount {
            if intro.price == 0 {
                return "\(intro.subscriptionPeriod.periodTitle) free trial"
            } else {
                let introPrice = localizedIntroductoryPriceString ?? storeProduct.localizedPriceString
                return "\(introPrice) for \(intro.subscriptionPeriod.periodTitle)"
            }
        }

        if let subscriptionPeriod = storeProduct.subscriptionPeriod {
            return "\(storeProduct.localizedPriceString) / \(subscriptionPeriod.durationTitle)"
        }

        return "\(storeProduct.localizedPriceString) one-time"
    }
}

extension RevenueCat.SubscriptionPeriod {
    var durationTitle: String {
        switch unit {
        case .day:
            return "day"
        case .week:
            return "week"
        case .month:
            return "month"
        case .year:
            return "year"
        @unknown default:
            return "period"
        }
    }

    var periodTitle: String {
        let periodString = "\(value) \(durationTitle)"
        return value > 1 ? "\(periodString)s" : periodString
    }
}
