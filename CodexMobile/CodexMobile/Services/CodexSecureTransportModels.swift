// FILE: CodexSecureTransportModels.swift
// Purpose: Defines the wire payloads, device trust records, and crypto helpers for Remodex E2EE.
// Layer: Service support
// Exports: Pairing/session models plus transcript, nonce, and key utility helpers
// Depends on: Foundation, CryptoKit

import CryptoKit
import Foundation

let codexSecureProtocolVersion = 1
let codexPairingQRVersion = 2
let codexSecureHandshakeTag = "remodex-e2ee-v1"
let codexSecureHandshakeLabel = "client-auth"
let codexSecureClockSkewToleranceSeconds: TimeInterval = 60
let codexTrustedSessionResolveTag = "remodex-trusted-session-resolve-v1"
let codexTrustedSessionResolveClockSkewToleranceSeconds: TimeInterval = 90

enum CodexSecureHandshakeMode: String, Codable, Sendable {
    case qrBootstrap = "qr_bootstrap"
    case trustedReconnect = "trusted_reconnect"
}

enum CodexSecureConnectionState: Equatable, Sendable {
    case notPaired
    case trustedMac
    case liveSessionUnresolved
    case handshaking
    case encrypted
    case reconnecting
    case rePairRequired
    case updateRequired
}

struct CodexPairingQRPayload: Codable, Sendable {
    let v: Int
    let relay: String
    let sessionId: String
    let macDeviceId: String
    let macIdentityPublicKey: String
    let expiresAt: Int64
}

struct CodexPhoneIdentityState: Codable, Sendable {
    let phoneDeviceId: String
    let phoneIdentityPrivateKey: String
    let phoneIdentityPublicKey: String
}

struct CodexTrustedMacRecord: Codable, Sendable {
    let macDeviceId: String
    let macIdentityPublicKey: String
    let lastPairedAt: Date
    var relayURL: String? = nil
    var displayName: String? = nil
    var lastResolvedSessionId: String? = nil
    var lastResolvedAt: Date? = nil
    var lastUsedAt: Date? = nil
}

struct CodexTrustedMacRegistry: Codable, Sendable {
    var records: [String: CodexTrustedMacRecord]

    static let empty = CodexTrustedMacRegistry(records: [:])
}

struct SecureClientHello: Codable, Sendable {
    let kind = "clientHello"
    let protocolVersion: Int
    let sessionId: String
    let handshakeMode: CodexSecureHandshakeMode
    let phoneDeviceId: String
    let phoneIdentityPublicKey: String
    let phoneEphemeralPublicKey: String
    let clientNonce: String
}

struct SecureServerHello: Codable, Sendable {
    let kind: String
    let protocolVersion: Int
    let sessionId: String
    let handshakeMode: CodexSecureHandshakeMode
    let macDeviceId: String
    let macIdentityPublicKey: String
    let macEphemeralPublicKey: String
    let serverNonce: String
    let keyEpoch: Int
    let expiresAtForTranscript: Int64
    let macSignature: String
    let clientNonce: String?
}

struct SecureClientAuth: Codable, Sendable {
    let kind = "clientAuth"
    let sessionId: String
    let phoneDeviceId: String
    let keyEpoch: Int
    let phoneSignature: String
}

struct SecureReadyMessage: Codable, Sendable {
    let kind: String
    let sessionId: String
    let keyEpoch: Int
    let macDeviceId: String
}

struct SecureResumeState: Codable, Sendable {
    let kind = "resumeState"
    let sessionId: String
    let keyEpoch: Int
    let lastAppliedBridgeOutboundSeq: Int
}

struct SecureErrorMessage: Codable, Sendable {
    let kind: String
    let code: String
    let message: String
}

struct SecureEnvelope: Codable, Sendable {
    let kind: String
    let v: Int
    let sessionId: String
    let keyEpoch: Int
    let sender: String
    let counter: Int
    let ciphertext: String
    let tag: String
}

struct SecureApplicationPayload: Codable, Sendable {
    let bridgeOutboundSeq: Int?
    let payloadText: String
}

struct CodexSecureSession {
    let sessionId: String
    let keyEpoch: Int
    let macDeviceId: String
    let macIdentityPublicKey: String
    let phoneToMacKey: SymmetricKey
    let macToPhoneKey: SymmetricKey
    var lastInboundBridgeOutboundSeq: Int
    var lastInboundCounter: Int
    var nextOutboundCounter: Int
}

struct CodexTrustedSessionResolveRequest: Codable, Sendable {
    let macDeviceId: String
    let phoneDeviceId: String
    let phoneIdentityPublicKey: String
    let nonce: String
    let timestamp: Int64
    let signature: String
}

struct CodexTrustedSessionResolveResponse: Codable, Sendable {
    let ok: Bool
    let macDeviceId: String
    let macIdentityPublicKey: String
    let displayName: String?
    let sessionId: String
}

struct CodexPairingCodeResolveResponse: Codable, Sendable {
    let ok: Bool
    let v: Int
    let sessionId: String
    let macDeviceId: String
    let macIdentityPublicKey: String
    let expiresAt: Int64
}

struct CodexRelayErrorResponse: Codable, Sendable {
    let ok: Bool?
    let error: String?
    let code: String?
}

struct CodexPendingHandshake {
    let mode: CodexSecureHandshakeMode
    let transcriptBytes: Data
    let phoneEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let phoneDeviceId: String
}

enum CodexSecureTransportError: LocalizedError {
    case invalidQR(String)
    case secureError(String)
    case incompatibleVersion(String)
    case invalidHandshake(String)
    case decryptFailed
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .invalidQR(let message),
             .secureError(let message),
             .incompatibleVersion(let message),
             .invalidHandshake(let message),
             .timedOut(let message):
            return message
        case .decryptFailed:
            return "Unable to decrypt the secure Remodex payload."
        }
    }
}

enum CodexTrustedSessionResolveError: LocalizedError {
    case noTrustedMac
    case unsupportedRelay
    case macOffline(String)
    case rePairRequired(String)
    case invalidResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noTrustedMac:
            return "No trusted Mac is available to reconnect."
        case .unsupportedRelay:
            return "This relay does not support trusted reconnect yet."
        case .macOffline(let message),
             .rePairRequired(let message),
             .invalidResponse(let message),
             .network(let message):
            return message
        }
    }
}

extension CodexSecureConnectionState {
    var statusLabel: String {
        switch self {
        case .notPaired:
            return "Not paired"
        case .trustedMac:
            return "Trusted Mac"
        case .liveSessionUnresolved:
            return "Trusted Mac ready"
        case .handshaking:
            return "Secure handshake in progress"
        case .encrypted:
            return "End-to-end encrypted"
        case .reconnecting:
            return "Reconnecting securely"
        case .rePairRequired:
            return "Re-pair required"
        case .updateRequired:
            return "Update required"
        }
    }
}

func codexTrustedSessionResolveTranscriptBytes(
    macDeviceId: String,
    phoneDeviceId: String,
    phoneIdentityPublicKey: String,
    nonce: String,
    timestamp: Int64
) -> Data {
    var data = Data()
    data.appendLengthPrefixedUTF8(codexTrustedSessionResolveTag)
    data.appendLengthPrefixedUTF8(macDeviceId)
    data.appendLengthPrefixedUTF8(phoneDeviceId)
    data.appendLengthPrefixedData(Data(base64EncodedOrEmpty: phoneIdentityPublicKey))
    data.appendLengthPrefixedUTF8(nonce)
    data.appendLengthPrefixedUTF8(String(timestamp))
    return data
}

// Builds the exact transcript bytes used by both signatures and HKDF salt.
func codexSecureTranscriptBytes(
    sessionId: String,
    protocolVersion: Int,
    handshakeMode: CodexSecureHandshakeMode,
    keyEpoch: Int,
    macDeviceId: String,
    phoneDeviceId: String,
    macIdentityPublicKey: String,
    phoneIdentityPublicKey: String,
    macEphemeralPublicKey: String,
    phoneEphemeralPublicKey: String,
    clientNonce: Data,
    serverNonce: Data,
    expiresAtForTranscript: Int64
) -> Data {
    var data = Data()
    data.appendLengthPrefixedUTF8(codexSecureHandshakeTag)
    data.appendLengthPrefixedUTF8(sessionId)
    data.appendLengthPrefixedUTF8(String(protocolVersion))
    data.appendLengthPrefixedUTF8(handshakeMode.rawValue)
    data.appendLengthPrefixedUTF8(String(keyEpoch))
    data.appendLengthPrefixedUTF8(macDeviceId)
    data.appendLengthPrefixedUTF8(phoneDeviceId)
    data.appendLengthPrefixedData(Data(base64EncodedOrEmpty: macIdentityPublicKey))
    data.appendLengthPrefixedData(Data(base64EncodedOrEmpty: phoneIdentityPublicKey))
    data.appendLengthPrefixedData(Data(base64EncodedOrEmpty: macEphemeralPublicKey))
    data.appendLengthPrefixedData(Data(base64EncodedOrEmpty: phoneEphemeralPublicKey))
    data.appendLengthPrefixedData(clientNonce)
    data.appendLengthPrefixedData(serverNonce)
    data.appendLengthPrefixedUTF8(String(expiresAtForTranscript))
    return data
}

// Keeps the client-auth signature domain-separated from the shared transcript signature.
func codexClientAuthTranscript(from transcriptBytes: Data) -> Data {
    var data = transcriptBytes
    data.appendLengthPrefixedUTF8(codexSecureHandshakeLabel)
    return data
}

// Derives the deterministic AES-GCM nonce from direction + counter.
func codexSecureNonce(sender: String, counter: Int) -> Data {
    var nonce = Data(repeating: 0, count: 12)
    nonce[0] = (sender == "mac") ? 1 : 2
    var remaining = UInt64(counter)
    for index in stride(from: 11, through: 1, by: -1) {
        nonce[index] = UInt8(remaining & 0xff)
        remaining >>= 8
    }
    return nonce
}

func codexSecureFingerprint(for publicKeyBase64: String) -> String {
    let digest = SHA256.hash(data: Data(base64EncodedOrEmpty: publicKeyBase64))
    return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12).uppercased()
}

func codexPhoneIdentityStateFromSecureStore() -> CodexPhoneIdentityState {
    if let existing: CodexPhoneIdentityState = SecureStore.readCodable(
        CodexPhoneIdentityState.self,
        for: CodexSecureKeys.phoneIdentityState
    ) {
        return existing
    }

    let privateKey = Curve25519.Signing.PrivateKey()
    let next = CodexPhoneIdentityState(
        phoneDeviceId: UUID().uuidString,
        phoneIdentityPrivateKey: privateKey.rawRepresentation.base64EncodedString(),
        phoneIdentityPublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
    )
    SecureStore.writeCodable(next, for: CodexSecureKeys.phoneIdentityState)
    return next
}

func codexTrustedMacRegistryFromSecureStore() -> CodexTrustedMacRegistry {
    SecureStore.readCodable(CodexTrustedMacRegistry.self, for: CodexSecureKeys.trustedMacRegistry)
    ?? .empty
}

extension Data {
    init(base64EncodedOrEmpty value: String) {
        self = Data(base64Encoded: value) ?? Data()
    }

    mutating func appendLengthPrefixedUTF8(_ value: String) {
        appendLengthPrefixedData(Data(value.utf8))
    }

    mutating func appendLengthPrefixedData(_ value: Data) {
        var length = UInt32(value.count).bigEndian
        append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        append(value)
    }
}
