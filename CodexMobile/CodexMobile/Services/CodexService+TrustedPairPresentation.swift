// FILE: CodexService+TrustedPairPresentation.swift
// Purpose: Derives a compact UI-facing summary for the connected or remembered Mac pair.
// Layer: Service extension
// Exports: CodexTrustedPairPresentation, CodexService trusted-pair presentation helpers
// Depends on: Foundation

import Foundation

struct CodexTrustedPairPresentation: Equatable, Sendable {
    let title: String
    let name: String
    let detail: String?
}

extension CodexService {
    // Builds the minimal pair summary shown by Home and Settings so both surfaces stay in sync.
    var trustedPairPresentation: CodexTrustedPairPresentation? {
        let macName = trustedPairDisplayName
        let macFingerprint = trustedPairFingerprint
        guard macName != nil || macFingerprint != nil else {
            return nil
        }

        return CodexTrustedPairPresentation(
            title: trustedPairTitle,
            name: macName ?? "Mac \(macFingerprint ?? "")".trimmingCharacters(in: .whitespacesAndNewlines),
            detail: trustedPairDetail(displayName: macName, fingerprint: macFingerprint)
        )
    }
}

private extension CodexService {
    // Chooses the Mac identity the UI should surface first: the live relay target when available,
    // otherwise the preferred trusted Mac remembered for reconnect.
    var visibleTrustedMacRecord: CodexTrustedMacRecord? {
        if let normalizedRelayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[normalizedRelayMacDeviceId] {
            return trustedMac
        }

        return preferredTrustedMacRecord
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
            return "Pairing Mac"
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
