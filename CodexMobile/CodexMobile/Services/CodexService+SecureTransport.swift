// FILE: CodexService+SecureTransport.swift
// Purpose: Performs the iPhone-side E2EE handshake, wire control routing, and encrypted envelope handling.
// Layer: Service
// Exports: CodexService secure transport helpers
// Depends on: CryptoKit, Foundation, Security, Network

import CryptoKit
import Foundation
import Security

extension CodexService {
    // Completes the secure handshake before any JSON-RPC traffic is sent over the relay.
    func performSecureHandshake() async throws {
        guard let sessionId = normalizedRelaySessionId,
              let macDeviceId = normalizedRelayMacDeviceId else {
            throw CodexSecureTransportError.invalidHandshake(
                "The saved relay pairing is incomplete. Scan a fresh QR code to reconnect."
            )
        }

        let trustedMac = trustedMacRegistry.records[macDeviceId]
        let handshakeMode: CodexSecureHandshakeMode = trustedMac != nil ? .trustedReconnect : .qrBootstrap
        let expectedMacIdentityPublicKey: String
        switch handshakeMode {
        case .trustedReconnect:
            expectedMacIdentityPublicKey = trustedMac?.macIdentityPublicKey ?? ""
            secureConnectionState = .reconnecting
        case .qrBootstrap:
            guard let pairingPublicKey = normalizedRelayMacIdentityPublicKey else {
                throw CodexSecureTransportError.invalidHandshake(
                    "The initial pairing metadata is missing the Mac identity key. Scan a new QR code to reconnect."
                )
            }
            expectedMacIdentityPublicKey = pairingPublicKey
            secureConnectionState = .handshaking
        }

        let phoneEphemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientNonce = randomSecureNonce()
        let clientHello = SecureClientHello(
            protocolVersion: relayProtocolVersion,
            sessionId: sessionId,
            handshakeMode: handshakeMode,
            phoneDeviceId: phoneIdentityState.phoneDeviceId,
            phoneIdentityPublicKey: phoneIdentityState.phoneIdentityPublicKey,
            phoneEphemeralPublicKey: phoneEphemeralPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            clientNonce: clientNonce.base64EncodedString()
        )
        pendingHandshake = CodexPendingHandshake(
            mode: handshakeMode,
            transcriptBytes: Data(),
            phoneEphemeralPrivateKey: phoneEphemeralPrivateKey,
            phoneDeviceId: phoneIdentityState.phoneDeviceId
        )
        try await sendWireControlMessage(clientHello)

        let serverHelloRaw = try await waitForSecureControlMessage(kind: "serverHello")
        let serverHello = try decodeSecureControl(SecureServerHello.self, from: serverHelloRaw)
        guard serverHello.protocolVersion == codexSecureProtocolVersion else {
            throw CodexSecureTransportError.incompatibleVersion(
                "This bridge is using a different secure transport version. Update Remodex on the iPhone or Mac and try again."
            )
        }
        guard serverHello.sessionId == sessionId else {
            throw CodexSecureTransportError.invalidHandshake("The secure bridge session ID did not match the saved pairing.")
        }
        guard serverHello.macDeviceId == macDeviceId else {
            throw CodexSecureTransportError.invalidHandshake("The bridge reported a different Mac identity for this relay session.")
        }
        guard serverHello.macIdentityPublicKey == expectedMacIdentityPublicKey else {
            throw CodexSecureTransportError.invalidHandshake("The secure Mac identity key did not match the paired device.")
        }

        let serverNonce = Data(base64EncodedOrEmpty: serverHello.serverNonce)
        let transcriptBytes = codexSecureTranscriptBytes(
            sessionId: sessionId,
            protocolVersion: serverHello.protocolVersion,
            handshakeMode: serverHello.handshakeMode,
            keyEpoch: serverHello.keyEpoch,
            macDeviceId: serverHello.macDeviceId,
            phoneDeviceId: phoneIdentityState.phoneDeviceId,
            macIdentityPublicKey: serverHello.macIdentityPublicKey,
            phoneIdentityPublicKey: phoneIdentityState.phoneIdentityPublicKey,
            macEphemeralPublicKey: serverHello.macEphemeralPublicKey,
            phoneEphemeralPublicKey: clientHello.phoneEphemeralPublicKey,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            expiresAtForTranscript: serverHello.expiresAtForTranscript
        )
        let macPublicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: Data(base64EncodedOrEmpty: serverHello.macIdentityPublicKey)
        )
        let macSignature = Data(base64EncodedOrEmpty: serverHello.macSignature)
        guard macPublicKey.isValidSignature(macSignature, for: transcriptBytes) else {
            throw CodexSecureTransportError.invalidHandshake("The secure Mac signature could not be verified.")
        }

        pendingHandshake = CodexPendingHandshake(
            mode: handshakeMode,
            transcriptBytes: transcriptBytes,
            phoneEphemeralPrivateKey: phoneEphemeralPrivateKey,
            phoneDeviceId: phoneIdentityState.phoneDeviceId
        )

        let phonePrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(base64EncodedOrEmpty: phoneIdentityState.phoneIdentityPrivateKey)
        )
        let phoneSignatureData = try phonePrivateKey.signature(for: codexClientAuthTranscript(from: transcriptBytes))
        let clientAuth = SecureClientAuth(
            sessionId: sessionId,
            phoneDeviceId: phoneIdentityState.phoneDeviceId,
            keyEpoch: serverHello.keyEpoch,
            phoneSignature: phoneSignatureData.base64EncodedString()
        )
        try await sendWireControlMessage(clientAuth)

        let secureReadyRaw = try await waitForSecureControlMessage(kind: "secureReady")
        let secureReady = try decodeSecureControl(SecureReadyMessage.self, from: secureReadyRaw)
        guard secureReady.sessionId == sessionId,
              secureReady.keyEpoch == serverHello.keyEpoch,
              secureReady.macDeviceId == macDeviceId else {
            throw CodexSecureTransportError.invalidHandshake("The bridge did not confirm the expected secure session.")
        }

        let macEphemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(base64EncodedOrEmpty: serverHello.macEphemeralPublicKey)
        )
        let sharedSecret = try phoneEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: macEphemeralPublicKey)
        let salt = SHA256.hash(data: transcriptBytes)
        let infoPrefix = "\(codexSecureHandshakeTag)|\(sessionId)|\(macDeviceId)|\(phoneIdentityState.phoneDeviceId)|\(serverHello.keyEpoch)"
        let phoneToMacKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(salt),
            sharedInfo: Data("\(infoPrefix)|phoneToMac".utf8),
            outputByteCount: 32
        )
        let macToPhoneKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(salt),
            sharedInfo: Data("\(infoPrefix)|macToPhone".utf8),
            outputByteCount: 32
        )

        secureSession = CodexSecureSession(
            sessionId: sessionId,
            keyEpoch: serverHello.keyEpoch,
            macDeviceId: macDeviceId,
            macIdentityPublicKey: serverHello.macIdentityPublicKey,
            phoneToMacKey: phoneToMacKey,
            macToPhoneKey: macToPhoneKey,
            lastInboundBridgeOutboundSeq: lastAppliedBridgeOutboundSeq,
            lastInboundCounter: -1,
            nextOutboundCounter: 0
        )
        pendingHandshake = nil
        secureConnectionState = .encrypted
        secureMacFingerprint = codexSecureFingerprint(for: serverHello.macIdentityPublicKey)

        if handshakeMode == .qrBootstrap {
            trustMac(deviceId: macDeviceId, publicKey: serverHello.macIdentityPublicKey)
        }

        try await sendWireControlMessage(
            SecureResumeState(
                sessionId: sessionId,
                keyEpoch: serverHello.keyEpoch,
                lastAppliedBridgeOutboundSeq: lastAppliedBridgeOutboundSeq
            )
        )
    }

    // Handles raw relay JSON before any JSON-RPC decoding so secure controls stay separate.
    func processIncomingWireText(_ text: String) {
        if let kind = wireMessageKind(from: text) {
            switch kind {
            case "serverHello", "secureReady", "secureError":
                bufferSecureControlMessage(kind: kind, rawText: text)
                return
            case "encryptedEnvelope":
                handleEncryptedEnvelopeText(text)
                return
            default:
                break
            }
        }

        processIncomingText(text)
    }

    // Encrypts JSON-RPC requests/responses before they leave the iPhone.
    func secureWireText(for plaintext: String) throws -> String {
        guard var secureSession else {
            throw CodexSecureTransportError.invalidHandshake(
                "The secure Remodex session is not ready yet. Try reconnecting."
            )
        }

        let payload = SecureApplicationPayload(
            bridgeOutboundSeq: nil,
            payloadText: plaintext
        )
        let payloadData = try JSONEncoder().encode(payload)
        let nonceData = codexSecureNonce(sender: "iphone", counter: secureSession.nextOutboundCounter)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.seal(payloadData, using: secureSession.phoneToMacKey, nonce: nonce)
        let envelope = SecureEnvelope(
            kind: "encryptedEnvelope",
            v: codexSecureProtocolVersion,
            sessionId: secureSession.sessionId,
            keyEpoch: secureSession.keyEpoch,
            sender: "iphone",
            counter: secureSession.nextOutboundCounter,
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
        secureSession.nextOutboundCounter += 1
        self.secureSession = secureSession
        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexSecureTransportError.invalidHandshake("Unable to encode the secure Remodex envelope.")
        }
        return text
    }

    // Saves the QR-derived bridge metadata used for secure reconnects.
    func rememberRelayPairing(_ payload: CodexPairingQRPayload) {
        SecureStore.writeString(payload.sessionId, for: CodexSecureKeys.relaySessionId)
        SecureStore.writeString(payload.relay, for: CodexSecureKeys.relayUrl)
        SecureStore.writeString(payload.macDeviceId, for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.writeString(payload.macIdentityPublicKey, for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.writeString(String(codexSecureProtocolVersion), for: CodexSecureKeys.relayProtocolVersion)
        SecureStore.writeString("0", for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
        relaySessionId = payload.sessionId
        relayUrl = payload.relay
        relayMacDeviceId = payload.macDeviceId
        relayMacIdentityPublicKey = payload.macIdentityPublicKey
        relayProtocolVersion = codexSecureProtocolVersion
        lastAppliedBridgeOutboundSeq = 0
        secureConnectionState = trustedMacRegistry.records[payload.macDeviceId] == nil ? .handshaking : .trustedMac
        secureMacFingerprint = codexSecureFingerprint(for: payload.macIdentityPublicKey)
    }

    // Resets volatile secure state while preserving the trusted-device registry.
    func resetSecureTransportState() {
        secureSession = nil
        pendingHandshake = nil
        let continuations = pendingSecureControlContinuations
        pendingSecureControlContinuations.removeAll()
        bufferedSecureControlMessages.removeAll()

        for waiters in continuations.values {
            for waiter in waiters {
                waiter.continuation.resume(throwing: CodexServiceError.disconnected)
            }
        }

        if let relayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[relayMacDeviceId] {
            secureConnectionState = .trustedMac
            secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        } else if normalizedRelaySessionId != nil {
            secureConnectionState = .notPaired
            secureMacFingerprint = nil
        } else {
            secureConnectionState = .notPaired
            secureMacFingerprint = nil
        }
    }
}

private extension CodexService {
    func sendWireControlMessage<Value: Encodable>(_ value: Value) async throws {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexSecureTransportError.invalidHandshake("Unable to encode the secure Remodex control payload.")
        }
        try await sendRawText(text)
    }

    func waitForSecureControlMessage(kind: String, timeoutSeconds: TimeInterval = 12) async throws -> String {
        if let bufferedSecureError = bufferedSecureControlMessages["secureError"]?.first,
           let secureError = try? decodeSecureControl(SecureErrorMessage.self, from: bufferedSecureError) {
            bufferedSecureControlMessages["secureError"] = []
            throw CodexSecureTransportError.secureError(secureError.message)
        }

        if var buffered = bufferedSecureControlMessages[kind], !buffered.isEmpty {
            let first = buffered.removeFirst()
            bufferedSecureControlMessages[kind] = buffered
            return first
        }

        let waiterID = UUID()
        let timeoutMessage = "Timed out waiting for the secure Remodex \(kind) message."

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            pendingSecureControlContinuations[kind, default: []].append(
                CodexSecureControlWaiter(id: waiterID, continuation: continuation)
            )

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard let self else { return }
                self.resumePendingSecureControlWaiterIfNeeded(
                    kind: kind,
                    waiterID: waiterID,
                    result: .failure(CodexSecureTransportError.timedOut(timeoutMessage))
                )
            }
        }
    }

    func bufferSecureControlMessage(kind: String, rawText: String) {
        if kind == "secureError",
           let secureError = try? decodeSecureControl(SecureErrorMessage.self, from: rawText) {
            lastErrorMessage = secureError.message
            if secureError.code == "update_required" {
                secureConnectionState = .updateRequired
            } else if secureError.code == "pairing_expired"
                || secureError.code == "phone_not_trusted"
                || secureError.code == "phone_identity_changed"
                || secureError.code == "phone_replacement_required" {
                secureConnectionState = .rePairRequired
            }

            let continuations = pendingSecureControlContinuations
            pendingSecureControlContinuations.removeAll()
            bufferedSecureControlMessages.removeAll()
            for waiters in continuations.values {
                for waiter in waiters {
                    waiter.continuation.resume(throwing: CodexSecureTransportError.secureError(secureError.message))
                }
            }
            if continuations.isEmpty {
                bufferedSecureControlMessages["secureError"] = [rawText]
            }
            return
        }

        if var waiters = pendingSecureControlContinuations[kind], !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if waiters.isEmpty {
                pendingSecureControlContinuations.removeValue(forKey: kind)
            } else {
                pendingSecureControlContinuations[kind] = waiters
            }
            waiter.continuation.resume(returning: rawText)
            return
        }

        bufferedSecureControlMessages[kind, default: []].append(rawText)
    }

    // Resumes a specific secure-control waiter once, so timeout tasks cannot double-resume it.
    func resumePendingSecureControlWaiterIfNeeded(
        kind: String,
        waiterID: UUID,
        result: Result<String, Error>
    ) {
        guard var waiters = pendingSecureControlContinuations[kind],
              let waiterIndex = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }

        let waiter = waiters.remove(at: waiterIndex)
        if waiters.isEmpty {
            pendingSecureControlContinuations.removeValue(forKey: kind)
        } else {
            pendingSecureControlContinuations[kind] = waiters
        }
        waiter.continuation.resume(with: result)
    }

    func handleEncryptedEnvelopeText(_ text: String) {
        guard var secureSession,
              let envelope = try? decodeSecureControl(SecureEnvelope.self, from: text),
              envelope.sessionId == secureSession.sessionId,
              envelope.keyEpoch == secureSession.keyEpoch,
              envelope.sender == "mac",
              envelope.counter > secureSession.lastInboundCounter else {
            lastErrorMessage = "The secure Remodex payload could not be verified."
            secureConnectionState = .rePairRequired
            return
        }

        do {
            let nonce = try AES.GCM.Nonce(
                data: codexSecureNonce(sender: envelope.sender, counter: envelope.counter)
            )
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: Data(base64EncodedOrEmpty: envelope.ciphertext),
                tag: Data(base64EncodedOrEmpty: envelope.tag)
            )
            let plaintext = try AES.GCM.open(sealedBox, using: secureSession.macToPhoneKey)
            let payload = try JSONDecoder().decode(SecureApplicationPayload.self, from: plaintext)
            secureSession.lastInboundCounter = envelope.counter
            self.secureSession = secureSession

            if let bridgeOutboundSeq = payload.bridgeOutboundSeq {
                if bridgeOutboundSeq <= lastAppliedBridgeOutboundSeq {
                    return
                }
                lastAppliedBridgeOutboundSeq = bridgeOutboundSeq
                SecureStore.writeString(
                    String(bridgeOutboundSeq),
                    for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq
                )
            }

            lastRawMessage = payload.payloadText
            processIncomingText(payload.payloadText)
        } catch {
            lastErrorMessage = CodexSecureTransportError.decryptFailed.localizedDescription
            secureConnectionState = .rePairRequired
        }
    }

    func trustMac(deviceId: String, publicKey: String) {
        trustedMacRegistry.records[deviceId] = CodexTrustedMacRecord(
            macDeviceId: deviceId,
            macIdentityPublicKey: publicKey,
            lastPairedAt: Date()
        )
        SecureStore.writeCodable(trustedMacRegistry, for: CodexSecureKeys.trustedMacRegistry)
        secureMacFingerprint = codexSecureFingerprint(for: publicKey)
    }

    func wireMessageKind(from rawText: String) -> String? {
        guard let data = rawText.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = json.objectValue else {
            return nil
        }
        return object["kind"]?.stringValue
    }

    func decodeSecureControl<Value: Decodable>(_ type: Value.Type, from rawText: String) throws -> Value {
        guard let data = rawText.data(using: .utf8) else {
            throw CodexSecureTransportError.invalidHandshake("The secure control payload was not valid UTF-8.")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func randomSecureNonce() -> Data {
        var data = Data(repeating: 0, count: 32)
        _ = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        return data
    }
}
