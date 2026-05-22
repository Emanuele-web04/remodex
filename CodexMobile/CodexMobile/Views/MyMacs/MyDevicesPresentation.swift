// FILE: MyDevicesPresentation.swift
// Purpose: Shared device naming, status copy, and sort order for the
//          Connections sheet's active-device picker and per-device rows.
// Layer: View helper
// Exports: MyDevicesPresentation, MyDeviceRowModel, MyDeviceMenuVisibilityStore
// Depends on: CodexService, SidebarComputerNicknameStore

import Foundation

struct MyDeviceRowModel: Identifiable {
    let deviceId: String
    let primaryName: String
    let secondaryName: String?
    let status: String
    let detail: String?
    let isCurrent: Bool
    let isConnected: Bool
    let isSwitching: Bool
    let isVisibleInMenu: Bool

    var id: String { deviceId }

    var menuSubtitle: String {
        [status, detail].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        .joined(separator: " · ")
    }

    /// Short label for connection UI where full hostnames feel noisy.
    var compactDisplayName: String {
        MyDevicesPresentation.compactDisplayName(primaryName)
    }
}

enum MyDevicesPresentation {
    static let macIconSystemName = "desktopcomputer"

    static func compactDisplayName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Device" }

        if trimmed.lowercased().hasSuffix(".local") {
            return String(trimmed.dropLast(6))
        }
        return trimmed
    }

    static func sortedRecords(from codex: CodexService) -> [CodexTrustedMacRecord] {
        codex.presentationTrustedMacRecords().sorted { lhs, rhs in
            shouldSortBefore(lhs, rhs, codex: codex)
        }
    }

    static func rowModels(from codex: CodexService, switchingDeviceId: String?) -> [MyDeviceRowModel] {
        sortedRecords(from: codex).map { record in
            rowModel(for: record, codex: codex, switchingDeviceId: switchingDeviceId)
        }
    }

    static func rowModel(
        for trustedMac: CodexTrustedMacRecord,
        codex: CodexService,
        switchingDeviceId: String?
    ) -> MyDeviceRowModel {
        let identity = displayIdentity(for: trustedMac)
        return MyDeviceRowModel(
            deviceId: trustedMac.macDeviceId,
            primaryName: identity.primaryName,
            secondaryName: identity.secondaryName,
            status: statusLabel(for: trustedMac, codex: codex, switchingDeviceId: switchingDeviceId),
            detail: detailLabel(for: trustedMac, switchingDeviceId: switchingDeviceId),
            isCurrent: trustedMac.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId,
            isConnected: trustedMac.macDeviceId == codex.normalizedRelayMacDeviceId && codex.isConnected,
            isSwitching: trustedMac.macDeviceId == switchingDeviceId,
            isVisibleInMenu: MyDeviceMenuVisibilityStore.isVisible(trustedMac.macDeviceId)
        )
    }

    private static func displayIdentity(for trustedMac: CodexTrustedMacRecord) -> (primaryName: String, secondaryName: String?) {
        let nickname = SidebarComputerNicknameStore.nickname(for: trustedMac.macDeviceId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let systemName = trustedMac.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if !nickname.isEmpty, let systemName, !systemName.isEmpty {
            return (nickname, systemName)
        }

        if !nickname.isEmpty {
            return (nickname, nil)
        }

        if let systemName, !systemName.isEmpty {
            return (systemName, nil)
        }

        return ("Device", nil)
    }

    private static func statusLabel(
        for trustedMac: CodexTrustedMacRecord,
        codex: CodexService,
        switchingDeviceId: String?
    ) -> String {
        if trustedMac.macDeviceId == switchingDeviceId {
            return "Switching"
        }
        if trustedMac.macDeviceId == codex.normalizedRelayMacDeviceId && codex.isConnected {
            return "Connected"
        }
        if trustedMac.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId {
            return "Selected"
        }
        if trustedMac.macDeviceId == codex.normalizedPreviousTrustedMacDeviceId {
            return "Previous"
        }
        return "Saved"
    }

    private static func detailLabel(
        for trustedMac: CodexTrustedMacRecord,
        switchingDeviceId: String?
    ) -> String? {
        if trustedMac.macDeviceId == switchingDeviceId {
            return "Reloading chats"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let referenceDate = trustedMac.lastUsedAt ?? trustedMac.lastPairedAt
        return formatter.localizedString(for: referenceDate, relativeTo: Date())
    }

    private static func shouldSortBefore(
        _ lhs: CodexTrustedMacRecord,
        _ rhs: CodexTrustedMacRecord,
        codex: CodexService
    ) -> Bool {
        let lhsIsCurrent = lhs.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId
        let rhsIsCurrent = rhs.macDeviceId == codex.normalizedCurrentTrustedMacDeviceId
        if lhsIsCurrent != rhsIsCurrent {
            return lhsIsCurrent
        }

        let lhsIsRelay = lhs.macDeviceId == codex.normalizedRelayMacDeviceId
        let rhsIsRelay = rhs.macDeviceId == codex.normalizedRelayMacDeviceId
        if lhsIsRelay != rhsIsRelay {
            return lhsIsRelay
        }

        let lhsIsPrevious = lhs.macDeviceId == codex.normalizedPreviousTrustedMacDeviceId
        let rhsIsPrevious = rhs.macDeviceId == codex.normalizedPreviousTrustedMacDeviceId
        if lhsIsPrevious != rhsIsPrevious {
            return lhsIsPrevious
        }

        let lhsHasResolvedSession = hasResolvedTrustedSession(lhs)
        let rhsHasResolvedSession = hasResolvedTrustedSession(rhs)
        if lhsHasResolvedSession != rhsHasResolvedSession {
            return lhsHasResolvedSession
        }

        return trustedMacActivityDate(lhs) > trustedMacActivityDate(rhs)
    }

    private static func hasResolvedTrustedSession(_ trustedMac: CodexTrustedMacRecord) -> Bool {
        if trustedMac.lastResolvedAt != nil {
            return true
        }
        return trustedMac.lastResolvedSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
    }

    private static func trustedMacActivityDate(_ trustedMac: CodexTrustedMacRecord) -> Date {
        trustedMac.lastResolvedAt ?? trustedMac.lastUsedAt ?? trustedMac.lastPairedAt
    }
}

enum MyDeviceMenuVisibilityStore {
    private static let keyPrefix = "codex.myDevices.visibleInMenu."

    static func isVisible(_ deviceId: String?) -> Bool {
        guard let storageKey = storageKey(for: deviceId) else {
            return true
        }
        guard UserDefaults.standard.object(forKey: storageKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: storageKey)
    }

    static func setVisible(_ isVisible: Bool, for deviceId: String?) {
        guard let storageKey = storageKey(for: deviceId) else {
            return
        }
        UserDefaults.standard.set(isVisible, forKey: storageKey)
    }

    static func removePreference(for deviceId: String?) {
        guard let storageKey = storageKey(for: deviceId) else {
            return
        }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func storageKey(for deviceId: String?) -> String? {
        guard let deviceId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceId.isEmpty else {
            return nil
        }
        return keyPrefix + deviceId
    }
}
