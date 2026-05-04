// FILE: AppEnvironment.swift
// Purpose: Centralizes local runtime endpoint and public app config lookups.
// Layer: Service
// Exports: AppEnvironment
// Depends on: Foundation

import Foundation

enum AppEnvironment {
    private static let defaultRelayURLInfoPlistKey = "PHODEX_DEFAULT_RELAY_URL"
    private static let revenueCatPublicAPIKeyInfoPlistKey = "REVENUECAT_PUBLIC_API_KEY"
    private static let revenueCatEntitlementNameInfoPlistKey = "REVENUECAT_ENTITLEMENT_NAME"
    private static let revenueCatDefaultOfferingIDInfoPlistKey = "REVENUECAT_DEFAULT_OFFERING_ID"
    private static let supportEmailAddress = "emandipietro@gmail.com"

    // Open-source builds should provide an explicit relay instead of silently
    // pointing at a hosted service the user does not control.
    static let defaultRelayURLString = ""

    static var relayBaseURL: String {
        if let infoURL = resolvedString(forInfoPlistKey: defaultRelayURLInfoPlistKey) {
            return infoURL
        }
        return defaultRelayURLString
    }

    // Reads the public RevenueCat key shipped with the client build.
    static var revenueCatPublicAPIKey: String? {
        resolvedString(forInfoPlistKey: revenueCatPublicAPIKeyInfoPlistKey)
    }

    // Keeps entitlement naming centralized so purchase checks stay consistent.
    static var revenueCatEntitlementName: String {
        resolvedString(forInfoPlistKey: revenueCatEntitlementNameInfoPlistKey) ?? "Pro"
    }

    // Mirrors the RevenueCat default offering ID used in the dashboard.
    static var revenueCatDefaultOfferingID: String {
        resolvedString(forInfoPlistKey: revenueCatDefaultOfferingIDInfoPlistKey) ?? "default"
    }

    // Legal links shown in the paywall footer and Settings.
    // Keep these pointed at a public source-of-truth until the website serves dedicated legal routes.
    static let privacyPolicyURL = URL(
        string: "https://github.com/Emanuele-web04/remodex/blob/main/Legal/PRIVACY_POLICY.md"
    )!
    static let termsOfUseURL = URL(
        string: "https://github.com/Emanuele-web04/remodex/blob/main/Legal/TERMS_OF_USE.md"
    )!

    // Powers in-app feedback actions so every entry point targets the same inbox.
    static var feedbackMailtoURL: URL {
        feedbackMailtoURL()
    }

    static func feedbackMailtoURL(
        errorMessage: String? = nil,
        threadId: String? = nil,
        isConnected: Bool? = nil,
        cliVersion: String? = nil
    ) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmailAddress
        var queryItems = [
            URLQueryItem(name: "subject", value: "Share Feedback on Remodex with the Developer")
        ]
        if let body = feedbackBody(
            errorMessage: errorMessage,
            threadId: threadId,
            isConnected: isConnected,
            cliVersion: cliVersion
        ) {
            queryItems.append(URLQueryItem(name: "body", value: body))
        }
        components.queryItems = queryItems
        return components.url!
    }
}

private extension AppEnvironment {
    static func resolvedString(forInfoPlistKey key: String) -> String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        if trimmedValue.hasPrefix("$("), trimmedValue.hasSuffix(")") {
            return nil
        }

        return trimmedValue
    }

    static func feedbackBody(
        errorMessage: String?,
        threadId: String?,
        isConnected: Bool?,
        cliVersion: String?
    ) -> String? {
        guard let errorMessage = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !errorMessage.isEmpty else {
            return nil
        }

        var lines = [
            "I hit this Remodex error:",
            "",
            "Error:",
            sanitizedFeedbackError(errorMessage),
            "",
            "Context:",
            "- Time: \(ISO8601DateFormatter().string(from: Date()))"
        ]

        if let threadId = redactedThreadId(threadId) {
            lines.append("- Thread: \(threadId)")
        }
        if let isConnected {
            lines.append("- Connected: \(isConnected ? "yes" : "no")")
        }
        lines.append("- App: \(appVersionSummary())")
        if let cliVersion = sanitizedCLIVersion(cliVersion) {
            lines.append("- Remodex CLI: \(cliVersion)")
        }
        lines.append("")
        lines.append("Notes:")
        lines.append("Write what caused this issue for a better understanding of the bug:")
        return lines.joined(separator: "\n")
    }

    static func sanitizedCLIVersion(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(40))
    }

    static func sanitizedFeedbackError(_ message: String) -> String {
        let singleLineMessage = message
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let redactedHome = NSHomeDirectory()
        let withoutHome = singleLineMessage.replacingOccurrences(of: redactedHome, with: "~")
        return String(withoutHome.prefix(600))
    }

    static func redactedThreadId(_ threadId: String?) -> String? {
        guard let threadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              threadId.count > 12 else {
            return nil
        }

        return "\(threadId.prefix(8))...\(threadId.suffix(4))"
    }

    static func appVersionSummary() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?):
            return "\(version) (\(build))"
        case let (version?, nil):
            return version
        case let (nil, build?):
            return "build \(build)"
        default:
            return "unknown"
        }
    }
}
