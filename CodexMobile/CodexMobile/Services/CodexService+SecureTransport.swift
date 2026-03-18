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
        // Fresh QR scans must go through bootstrap once so we verify the scanned session,
        // instead of silently reusing an older trusted-reconnect path.
        let handshakeMode: CodexSecureHandshakeMode = (!shouldForceQRBootstrapOnNextHandshake && trustedMac != nil)
            ? .trustedReconnect
            : .qrBootstrap
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

        let serverHello = try await waitForMatchingServerHello(
            expectedSessionId: sessionId,
            expectedMacDeviceId: macDeviceId,
            expectedMacIdentityPublicKey: expectedMacIdentityPublicKey,
            expectedClientNonce: clientHello.clientNonce,
            clientNonce: clientNonce,
            phoneDeviceId: phoneIdentityState.phoneDeviceId,
            phoneIdentityPublicKey: phoneIdentityState.phoneIdentityPublicKey,
            phoneEphemeralPublicKey: clientHello.phoneEphemeralPublicKey
        )
        guard serverHello.protocolVersion == codexSecureProtocolVersion else {
            presentBridgeUpdatePrompt(
                message: "This bridge is using a different secure transport version. Update the Remodex package on your Mac and try again."
            )
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
        debugSecureLog(
            "verify mode=\(serverHello.handshakeMode.rawValue) session=\(shortSecureId(sessionId)) "
            + "keyEpoch=\(serverHello.keyEpoch) mac=\(shortSecureId(serverHello.macDeviceId)) "
            + "phone=\(shortSecureId(phoneIdentityState.phoneDeviceId)) "
            + "expectedMacKey=\(shortSecureFingerprint(expectedMacIdentityPublicKey)) "
            + "actualMacKey=\(shortSecureFingerprint(serverHello.macIdentityPublicKey)) "
            + "phoneKey=\(shortSecureFingerprint(phoneIdentityState.phoneIdentityPublicKey)) "
            + "transcript=\(shortTranscriptDigest(transcriptBytes))"
        )
        let macPublicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: Data(base64EncodedOrEmpty: serverHello.macIdentityPublicKey)
        )
        let macSignature = Data(base64EncodedOrEmpty: serverHello.macSignature)
        let isSignatureValid = macPublicKey.isValidSignature(macSignature, for: transcriptBytes)
        debugSecureLog(
            "verify-result mode=\(serverHello.handshakeMode.rawValue) valid=\(isSignatureValid) "
            + "signature=\(shortTranscriptDigest(macSignature))"
        )
        guard isSignatureValid else {
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

        _ = try await waitForMatchingSecureReady(
            expectedSessionId: sessionId,
            expectedKeyEpoch: serverHello.keyEpoch,
            expectedMacDeviceId: macDeviceId
        )

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
        shouldForceQRBootstrapOnNextHandshake = false
        secureConnectionState = .encrypted
        secureMacFingerprint = codexSecureFingerprint(for: serverHello.macIdentityPublicKey)
        bridgeUpdatePrompt = nil

        if handshakeMode == .qrBootstrap {
            trustMac(
                deviceId: macDeviceId,
                publicKey: serverHello.macIdentityPublicKey,
                relayURL: normalizedRelayURL,
                displayName: trustedMac?.displayName
            )
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
        shouldForceQRBootstrapOnNextHandshake = true
        trustedReconnectFailureCount = 0
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

        if secureConnectionState == .rePairRequired || secureConnectionState == .updateRequired {
            return
        }

        if shouldForceQRBootstrapOnNextHandshake, normalizedRelaySessionId != nil {
            secureConnectionState = trustedMacRegistry.records[relayMacDeviceId ?? ""] == nil ? .handshaking : .trustedMac
            secureMacFingerprint = normalizedRelayMacIdentityPublicKey.map { codexSecureFingerprint(for: $0) }
            return
        }

        if let relayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[relayMacDeviceId] {
            secureConnectionState = .trustedMac
            secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        } else if let trustedMac = preferredTrustedMacRecord {
            secureConnectionState = .liveSessionUnresolved
            secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        } else if normalizedRelaySessionId != nil {
            secureConnectionState = .notPaired
            secureMacFingerprint = nil
        } else {
            secureConnectionState = .notPaired
            secureMacFingerprint = nil
        }
    }

    // Used by: ContentViewModel trusted reconnect path.
    func resolveTrustedMacSession() async throws -> CodexTrustedSessionResolveResponse {
        if let trustedSessionResolverOverride {
            return try await trustedSessionResolverOverride()
        }
        return try await resolveTrustedMacSessionImpl()
    }

    // Persists the resolved live relay session and resets replay cursors when the live session changed.
    func applyResolvedTrustedSession(_ resolved: CodexTrustedSessionResolveResponse, relayURL: String) {
        let previousSessionId = normalizedRelaySessionId
        let shouldResetReplayCursor = previousSessionId == nil || previousSessionId != resolved.sessionId
        if shouldResetReplayCursor {
            SecureStore.writeString("0", for: CodexSecureKeys.relayLastAppliedBridgeOutboundSeq)
            lastAppliedBridgeOutboundSeq = 0
        }
        rememberResolvedTrustedSession(resolved, relayURL: relayURL)
    }
}

private extension CodexService {
    // Centralizes the bridge-update guidance so every mismatch shows the same Mac command.
    func presentBridgeUpdatePrompt(message: String) {
        bridgeUpdatePrompt = CodexBridgeUpdatePrompt(
            title: "Update the Remodex package on your Mac",
            message: message,
            command: "npm install -g remodex@latest"
        )
    }

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
                presentBridgeUpdatePrompt(message: secureError.message)
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
        // No active session yet (handshake in progress) — silently drop stale envelopes.
        guard var secureSession else { return }

        guard let envelope = try? decodeSecureControl(SecureEnvelope.self, from: text),
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

    func trustMac(deviceId: String, publicKey: String, relayURL: String?, displayName: String?) {
        let existing = trustedMacRegistry.records[deviceId]
        trustedMacRegistry.records[deviceId] = CodexTrustedMacRecord(
            macDeviceId: deviceId,
            macIdentityPublicKey: publicKey,
            lastPairedAt: Date(),
            relayURL: relayURL ?? existing?.relayURL,
            displayName: displayName ?? existing?.displayName,
            lastResolvedSessionId: existing?.lastResolvedSessionId,
            lastResolvedAt: existing?.lastResolvedAt,
            lastUsedAt: Date()
        )
        SecureStore.writeCodable(trustedMacRegistry, for: CodexSecureKeys.trustedMacRegistry)
        SecureStore.writeString(deviceId, for: CodexSecureKeys.lastTrustedMacDeviceId)
        lastTrustedMacDeviceId = deviceId
        secureMacFingerprint = codexSecureFingerprint(for: publicKey)
    }

    // Resolves the live relay session for the preferred trusted Mac before we reconnect the socket.
    func resolveTrustedMacSessionImpl() async throws -> CodexTrustedSessionResolveResponse {
        guard let trustedMac = preferredTrustedMacRecord else {
            throw CodexTrustedSessionResolveError.noTrustedMac
        }
        guard let relayURL = trustedMac.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayURL.isEmpty else {
            throw CodexTrustedSessionResolveError.noTrustedMac
        }
        guard let resolveURL = trustedSessionResolveURL(from: relayURL) else {
            throw CodexTrustedSessionResolveError.invalidResponse("The trusted Mac relay URL is invalid.")
        }

        let nonce = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let transcriptBytes = codexTrustedSessionResolveTranscriptBytes(
            macDeviceId: trustedMac.macDeviceId,
            phoneDeviceId: phoneIdentityState.phoneDeviceId,
            phoneIdentityPublicKey: phoneIdentityState.phoneIdentityPublicKey,
            nonce: nonce,
            timestamp: timestamp
        )
        let phonePrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(base64EncodedOrEmpty: phoneIdentityState.phoneIdentityPrivateKey)
        )
        let signature = try phonePrivateKey.signature(for: transcriptBytes).base64EncodedString()

        let requestBody = CodexTrustedSessionResolveRequest(
            macDeviceId: trustedMac.macDeviceId,
            phoneDeviceId: phoneIdentityState.phoneDeviceId,
            phoneIdentityPublicKey: phoneIdentityState.phoneIdentityPublicKey,
            nonce: nonce,
            timestamp: timestamp,
            signature: signature
        )

        var request = URLRequest(url: resolveURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CodexTrustedSessionResolveError.network("Could not reach the trusted Mac relay. Check your connection and try again.")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexTrustedSessionResolveError.invalidResponse("The trusted Mac relay returned an invalid response.")
        }

        if (200..<300).contains(httpResponse.statusCode) {
            guard let resolved = try? JSONDecoder().decode(CodexTrustedSessionResolveResponse.self, from: data),
                  resolved.ok else {
                throw CodexTrustedSessionResolveError.invalidResponse("The trusted Mac relay returned malformed session data.")
            }
            applyResolvedTrustedSession(resolved, relayURL: relayURL)
            return resolved
        }

        let errorResponse = try? JSONDecoder().decode(CodexRelayErrorResponse.self, from: data)
        switch errorResponse?.code {
        case "session_unavailable":
            secureConnectionState = .liveSessionUnresolved
            throw CodexTrustedSessionResolveError.macOffline("Your trusted Mac is offline right now.")
        case "phone_not_trusted", "invalid_signature":
            secureConnectionState = .rePairRequired
            throw CodexTrustedSessionResolveError.rePairRequired(
                "This iPhone is no longer trusted by the Mac. Scan a new QR code to reconnect."
            )
        case "resolve_request_replayed", "resolve_request_expired":
            throw CodexTrustedSessionResolveError.network(
                "The trusted reconnect request expired. Try reconnecting again."
            )
        default:
            if httpResponse.statusCode == 404 {
                throw CodexTrustedSessionResolveError.unsupportedRelay
            }
            throw CodexTrustedSessionResolveError.network(
                errorResponse?.error
                ?? "The trusted Mac relay could not resolve the current bridge session."
            )
        }
    }

    private func rememberResolvedTrustedSession(_ resolved: CodexTrustedSessionResolveResponse, relayURL: String) {
        SecureStore.writeString(resolved.sessionId, for: CodexSecureKeys.relaySessionId)
        SecureStore.writeString(relayURL, for: CodexSecureKeys.relayUrl)
        SecureStore.writeString(resolved.macDeviceId, for: CodexSecureKeys.relayMacDeviceId)
        SecureStore.writeString(resolved.macIdentityPublicKey, for: CodexSecureKeys.relayMacIdentityPublicKey)
        SecureStore.writeString(String(codexSecureProtocolVersion), for: CodexSecureKeys.relayProtocolVersion)
        relaySessionId = resolved.sessionId
        relayUrl = relayURL
        relayMacDeviceId = resolved.macDeviceId
        relayMacIdentityPublicKey = resolved.macIdentityPublicKey
        relayProtocolVersion = codexSecureProtocolVersion
        shouldForceQRBootstrapOnNextHandshake = false
        trustedReconnectFailureCount = 0
        secureConnectionState = .trustedMac
        secureMacFingerprint = codexSecureFingerprint(for: resolved.macIdentityPublicKey)
        SecureStore.writeString(resolved.macDeviceId, for: CodexSecureKeys.lastTrustedMacDeviceId)
        lastTrustedMacDeviceId = resolved.macDeviceId

        if var trustedMac = trustedMacRegistry.records[resolved.macDeviceId] {
            trustedMac.relayURL = relayURL
            trustedMac.displayName = resolved.displayName ?? trustedMac.displayName
            trustedMac.lastResolvedSessionId = resolved.sessionId
            trustedMac.lastResolvedAt = Date()
            trustedMac.lastUsedAt = Date()
            trustedMacRegistry.records[resolved.macDeviceId] = trustedMac
            SecureStore.writeCodable(trustedMacRegistry, for: CodexSecureKeys.trustedMacRegistry)
        }
    }

    private func trustedSessionResolveURL(from relayURL: String) -> URL? {
        guard var components = URLComponents(string: relayURL) else {
            return nil
        }

        if components.scheme == "wss" {
            components.scheme = "https"
        } else if components.scheme == "ws" {
            components.scheme = "http"
        }

        let pathComponents = components.path.split(separator: "/").map(String.init)
        if pathComponents.last == "relay" {
            let prefix = pathComponents.dropLast()
            components.path = "/" + (prefix + ["v1", "trusted", "session", "resolve"]).joined(separator: "/")
        } else {
            components.path = "/v1/trusted/session/resolve"
        }

        return components.url
    }

    /// Waits for a serverHello whose echoed clientNonce matches the one we sent.
    /// Stale serverHellos from a previous handshake attempt (e.g. buffered by the relay
    /// across a phone disconnect/reconnect) are silently discarded until the correct one
    /// arrives or the per-message 12-second timeout fires.
    func waitForMatchingServerHello(
        expectedSessionId: String,
        expectedMacDeviceId: String,
        expectedMacIdentityPublicKey: String,
        expectedClientNonce: String,
        clientNonce: Data,
        phoneDeviceId: String,
        phoneIdentityPublicKey: String,
        phoneEphemeralPublicKey: String
    ) async throws -> SecureServerHello {
        while true {
            let raw = try await waitForSecureControlMessage(kind: "serverHello")
            let hello = try decodeSecureControl(SecureServerHello.self, from: raw)
            if let echoedNonce = hello.clientNonce, echoedNonce != expectedClientNonce {
                debugSecureLog("discarding stale serverHello (clientNonce mismatch)")
                continue
            }
            if hello.clientNonce == nil,
               !isMatchingLegacyServerHello(
                    hello,
                    expectedSessionId: expectedSessionId,
                    expectedMacDeviceId: expectedMacDeviceId,
                    expectedMacIdentityPublicKey: expectedMacIdentityPublicKey,
                    clientNonce: clientNonce,
                    phoneDeviceId: phoneDeviceId,
                    phoneIdentityPublicKey: phoneIdentityPublicKey,
                    phoneEphemeralPublicKey: phoneEphemeralPublicKey
               ) {
                debugSecureLog("discarding stale serverHello (legacy signature mismatch)")
                continue
            }
            return hello
        }
    }

    // Falls back to transcript-signature matching for pre-echo serverHello payloads.
    func isMatchingLegacyServerHello(
        _ hello: SecureServerHello,
        expectedSessionId: String,
        expectedMacDeviceId: String,
        expectedMacIdentityPublicKey: String,
        clientNonce: Data,
        phoneDeviceId: String,
        phoneIdentityPublicKey: String,
        phoneEphemeralPublicKey: String
    ) -> Bool {
        guard hello.protocolVersion == codexSecureProtocolVersion,
              hello.sessionId == expectedSessionId,
              hello.macDeviceId == expectedMacDeviceId,
              hello.macIdentityPublicKey == expectedMacIdentityPublicKey,
              let macPublicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: Data(base64EncodedOrEmpty: hello.macIdentityPublicKey)
              ) else {
            return false
        }

        let transcriptBytes = codexSecureTranscriptBytes(
            sessionId: expectedSessionId,
            protocolVersion: hello.protocolVersion,
            handshakeMode: hello.handshakeMode,
            keyEpoch: hello.keyEpoch,
            macDeviceId: hello.macDeviceId,
            phoneDeviceId: phoneDeviceId,
            macIdentityPublicKey: hello.macIdentityPublicKey,
            phoneIdentityPublicKey: phoneIdentityPublicKey,
            macEphemeralPublicKey: hello.macEphemeralPublicKey,
            phoneEphemeralPublicKey: phoneEphemeralPublicKey,
            clientNonce: clientNonce,
            serverNonce: Data(base64EncodedOrEmpty: hello.serverNonce),
            expiresAtForTranscript: hello.expiresAtForTranscript
        )
        return macPublicKey.isValidSignature(
            Data(base64EncodedOrEmpty: hello.macSignature),
            for: transcriptBytes
        )
    }

    /// Waits for a secureReady whose keyEpoch matches the current handshake.
    /// Stale secureReady messages from previous sessions are discarded until the
    /// correct one arrives or the per-message 12-second timeout fires.
    func waitForMatchingSecureReady(
        expectedSessionId: String,
        expectedKeyEpoch: Int,
        expectedMacDeviceId: String
    ) async throws -> SecureReadyMessage {
        while true {
            let raw = try await waitForSecureControlMessage(kind: "secureReady")
            let ready = try decodeSecureControl(SecureReadyMessage.self, from: raw)
            if ready.sessionId == expectedSessionId,
               ready.keyEpoch == expectedKeyEpoch,
               ready.macDeviceId == expectedMacDeviceId {
                return ready
            }
            debugSecureLog("discarding stale secureReady (keyEpoch=\(ready.keyEpoch) expected=\(expectedKeyEpoch))")
        }
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

    func debugSecureLog(_ message: String) {
        print("[CodexSecure] \(message)")
    }

    func shortSecureId(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "none" : String(normalized.prefix(8))
    }

    func shortSecureFingerprint(_ publicKeyBase64: String) -> String {
        let bytes = Data(base64EncodedOrEmpty: publicKeyBase64)
        guard !bytes.isEmpty else {
            return "invalid"
        }
        return shortTranscriptDigest(bytes)
    }

    func shortTranscriptDigest(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
