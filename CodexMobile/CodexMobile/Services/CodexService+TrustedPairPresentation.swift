// FILE: CodexService+TrustedPairPresentation.swift
// Purpose: Derives a compact UI-facing summary for the connected or remembered host pair.
// Layer: Service extension
// Exports: CodexTrustedPairPresentation, CodexService trusted-pair presentation helpers
// Depends on: Foundation

import Foundation

struct CodexTrustedPairPresentation: Equatable, Sendable {
    let deviceId: String?
    let title: String
    let name: String
    let systemName: String?
    let detail: String?
}

enum SidebarComputerNicknameStore {
    private static let keyPrefix = "codex.sidebarComputerNickname."

    // Keeps sidebar aliases scoped to a stable host id instead of a single global setting.
    static func nickname(for deviceId: String?) -> String {
        guard let storageKey = storageKey(for: deviceId) else {
            return ""
        }

        return UserDefaults.standard.string(forKey: storageKey) ?? ""
    }

    // Clears blank aliases so stale names do not survive after users switch back to the system name.
    static func setNickname(_ nickname: String, for deviceId: String?) {
        guard let storageKey = storageKey(for: deviceId) else {
            return
        }

        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }

        UserDefaults.standard.set(trimmed, forKey: storageKey)
    }

    private static func storageKey(for deviceId: String?) -> String? {
        guard let deviceId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceId.isEmpty else {
            return nil
        }

        return keyPrefix + deviceId
    }
}

extension CodexService {
    // Builds the minimal pair summary shown by Home and Settings so both surfaces stay in sync.
    var trustedPairPresentation: CodexTrustedPairPresentation? {
        let hostName = trustedPairDisplayName
        let hostFingerprint = trustedPairFingerprint
        guard hostName != nil || hostFingerprint != nil else {
            return nil
        }

        let fallbackName = "\(hostComputerLabel.capitalized) \(hostFingerprint ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
        let systemName = hostName ?? fallbackName
        let nickname = SidebarComputerNicknameStore.nickname(for: trustedPairDeviceId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = nickname.isEmpty ? systemName : nickname

        return CodexTrustedPairPresentation(
            deviceId: trustedPairDeviceId,
            title: trustedPairTitle,
            name: effectiveName,
            systemName: nickname.isEmpty ? nil : systemName,
            detail: trustedPairDetail(displayName: hostName, fingerprint: hostFingerprint)
        )
    }
}

private extension CodexService {
    // Chooses the host identity the UI should surface first: the live relay target when available,
    // otherwise the preferred trusted computer remembered for reconnect.
    var visibleTrustedMacRecord: CodexTrustedMacRecord? {
        if let normalizedRelayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[normalizedRelayMacDeviceId] {
            return trustedMac
        }

        return preferredTrustedMacRecord
    }

    // Reuses the connected device id when available, otherwise falls back to the saved preferred host.
    var trustedPairDeviceId: String? {
        normalizedRelayMacDeviceId ?? visibleTrustedMacRecord?.macDeviceId
    }

    var trustedPairDisplayName: String? {
        nonEmptyTrimmedString(visibleTrustedMacRecord?.displayName)
    }

    var trustedPairFingerprint: String? {
        nonEmptyTrimmedString(secureMacFingerprint)
            ?? normalizedRelayMacIdentityPublicKey.map { codexSecureFingerprint(for: $0) }
            ?? visibleTrustedMacRecord.map { codexSecureFingerprint(for: $0.macIdentityPublicKey) }
    }

    var trustedPairTitle: String {
        if isConnected || secureConnectionState == .encrypted {
            return "Connected Pair"
        }

        switch secureConnectionState {
        case .handshaking:
            return "Pairing Computer"
        case .liveSessionUnresolved, .reconnecting, .trustedMac:
            return "Saved Pair"
        case .rePairRequired:
            return "Previous Pair"
        case .updateRequired, .notPaired:
            return "Trusted Pair"
        case .encrypted:
            return "Connected Pair"
        }
    }

    // Shows both the human name and stable fingerprint when we have them, but keeps the summary compact.
    func trustedPairDetail(displayName: String?, fingerprint: String?) -> String? {
        var parts: [String] = [secureConnectionState.statusLabel]
        if displayName != nil, let fingerprint {
            parts.append(fingerprint)
        }
        let joined = parts.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    func nonEmptyTrimmedString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
