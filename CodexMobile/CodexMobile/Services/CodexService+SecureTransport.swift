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
                    "The initial pairing metadata is missing the device identity key. Scan a new QR code to reconnect."
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
                message: "This bridge is using a different secure transport version. Update the Remodex package on your device and try again."
            )
            throw CodexSecureTransportError.incompatibleVersion(
                "This bridge is using a different secure transport version. Update Remodex on the iPhone or paired device and try again."
            )
        }
        guard serverHello.sessionId == sessionId else {
            throw CodexSecureTransportError.invalidHandshake("The secure bridge session ID did not match the saved pairing.")
        }
        guard serverHello.macDeviceId == macDeviceId else {
            throw CodexSecureTransportError.invalidHandshake("The bridge reported a different device identity for this relay session.")
        }
        guard serverHello.macIdentityPublicKey == expectedMacIdentityPublicKey else {
            throw CodexSecureTransportError.invalidHandshake("The secure device identity key did not match the paired device.")
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
            throw CodexSecureTransportError.invalidHandshake("The secure device signature could not be verified.")
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
                displayName: serverHello.displayName ?? trustedMac?.displayName,
                liveSessionId: sessionId
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
    func resetSecureTransportState(preservePendingQRBootstrapState: Bool = false) {
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
            // Fresh scans should stay visually "in progress" while the connect path is spinning up,
            // but real disconnects still fall back to a stable saved-pair/not-paired presentation.
            if preservePendingQRBootstrapState {
                secureConnectionState = trustedMacRegistry.records[relayMacDeviceId ?? ""] == nil ? .handshaking : .trustedMac
            } else {
                secureConnectionState = trustedMacRegistry.records[relayMacDeviceId ?? ""] == nil ? .notPaired : .trustedMac
            }
            secureMacFingerprint = normalizedRelayMacIdentityPublicKey.map { codexSecureFingerprint(for: $0) }
            return
        }

        restoreTrustedPairPresentationState()
    }

    // Rebuilds the saved-pair UI state from persisted trust without touching sockets or keys.
    func restoreTrustedPairPresentationState() {
        if let relayMacDeviceId,
           let trustedMac = trustedMacRegistry.records[relayMacDeviceId] {
            secureConnectionState = .trustedMac
            secureMacFingerprint = codexSecureFingerprint(for: trustedMac.macIdentityPublicKey)
        } else if let trustedMac = currentTrustedMacRecord {
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
    func resolveTrustedMacSession(deviceId: String? = nil) async throws -> CodexTrustedSessionResolveResponse {
        let resolver = trustedSessionResolverOverride ?? { [weak self] in
            guard let self else {
                throw CancellationError()
            }
            return try await self.resolveTrustedMacSessionImpl(deviceId: deviceId)
        }
        let resolveTaskID = UUID()
        let task = Task {
            try await resolver()
        }

        trustedSessionResolveTask = task
        trustedSessionResolveTaskID = resolveTaskID
        defer {
            if trustedSessionResolveTaskID == resolveTaskID {
                trustedSessionResolveTask = nil
                trustedSessionResolveTaskID = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // Lets manual reconnect / fresh QR pairing preempt a stuck trusted-session HTTP lookup.
    func cancelTrustedSessionResolve() {
        trustedSessionResolveTask?.cancel()
        trustedSessionResolveTask = nil
        trustedSessionResolveTaskID = nil
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

    // Resolves a short manual pairing code through the best-known relay for this app instance.
    func resolvePairingCode(_ code: String) async throws -> CodexPairingQRPayload {
        let normalizedCode = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !normalizedCode.isEmpty else {
            throw CodexSecureTransportError.invalidQR("Enter a valid pairing code.")
        }

        guard let relayURL = preferredPairingCodeRelayURL,
              let resolveURL = pairingCodeResolveURL(from: relayURL) else {
            throw CodexSecureTransportError.invalidQR(
                "This iPhone does not know which relay to ask for that pairing code yet. Scan the QR code instead."
            )
        }

        var request = URLRequest(url: resolveURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": normalizedCode])

        let session = trustedSessionResolveURLSession(for: resolveURL)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexSecureTransportError.invalidQR("Could not reach the relay for this pairing code. Try again or scan the QR code.")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexSecureTransportError.invalidQR("The relay returned an invalid response for this pairing code.")
        }

        if (200..<300).contains(httpResponse.statusCode),
           let resolved = try? JSONDecoder().decode(CodexPairingCodeResolveResponse.self, from: data),
           resolved.ok {
            return CodexPairingQRPayload(
                v: resolved.v,
                relay: relayURL,
                sessionId: resolved.sessionId,
                macDeviceId: resolved.macDeviceId,
                macIdentityPublicKey: resolved.macIdentityPublicKey,
                expiresAt: resolved.expiresAt,
                displayName: resolved.displayName
            )
        }

        let errorResponse = try? JSONDecoder().decode(CodexRelayErrorResponse.self, from: data)
        switch errorResponse?.code {
        case "pairing_code_expired":
            throw CodexSecureTransportError.invalidQR("This pairing code has expired. Generate a new one from the device bridge.")
        case "pairing_code_unavailable":
            throw CodexSecureTransportError.invalidQR("That pairing code is not available right now. Make sure your device bridge is running and try again.")
        default:
            if httpResponse.statusCode == 404 {
                throw CodexSecureTransportError.invalidQR("This relay does not support pairing codes yet. Scan the QR code instead.")
            }
            throw CodexSecureTransportError.invalidQR(
                errorResponse?.error ?? "The relay could not resolve that pairing code."
            )
        }
    }
}

extension CodexService {
    func trustMac(
        deviceId: String,
        publicKey: String,
        relayURL: String?,
        displayName: String?,
        liveSessionId: String? = nil
    ) {
        let normalizedPublicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = trimmedDisplayName?.isEmpty == false ? trimmedDisplayName : nil
        let trimmedLiveSessionId = liveSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLiveSessionId = trimmedLiveSessionId?.isEmpty == false ? trimmedLiveSessionId : nil
        let now = Date()
        let incomingDisplayNameKey = trustedMacDisplayNameCompactionKey(normalizedDisplayName)
        let staleDuplicateRecords = trustedMacRegistry.records.values
            .filter { trustedMac in
                guard trustedMac.macDeviceId != deviceId else {
                    return false
                }

                if hasSameTrustedMacIdentity(trustedMac, asPublicKey: normalizedPublicKey) {
                    return true
                }

                guard let incomingDisplayNameKey,
                      trustedMacDisplayNameCompactionKey(trustedMac.displayName) == incomingDisplayNameKey else {
                    return false
                }
                return shouldCoalesceTrustedMacRecordByDisplayName(
                    trustedMac,
                    incomingPublicKey: normalizedPublicKey,
                    now: now
                )
            }
            .sorted { shouldPreferTrustedMacRecord($0, over: $1) }
        let existing = preferredExistingTrustedMacRecord(
            current: trustedMacRegistry.records[deviceId],
            duplicates: staleDuplicateRecords
        )
        let existingHasSameIdentity = existing.map {
            hasSameTrustedMacIdentity($0, asPublicKey: normalizedPublicKey)
        } ?? false

        // Old bridge resets could rotate ids; collapse those historical records when a fresh QR proves the current one.
        let migratedScopedState = migrateMacScopedState(
            from: staleDuplicateRecords.map(\.macDeviceId),
            to: deviceId
        )
        for staleRecord in staleDuplicateRecords {
            trustedMacRegistry.records.removeValue(forKey: staleRecord.macDeviceId)
        }
        if let normalizedPreviousTrustedMacDeviceId,
           staleDuplicateRecords.contains(where: { $0.macDeviceId == normalizedPreviousTrustedMacDeviceId }) {
            clearPreviousTrustedMacDeviceId()
        }

        trustedMacRegistry.records[deviceId] = CodexTrustedMacRecord(
            macDeviceId: deviceId,
            macIdentityPublicKey: normalizedPublicKey,
            lastPairedAt: now,
            relayURL: relayURL ?? existing?.relayURL,
            displayName: preferredTrustedMacDisplayName(
                incoming: normalizedDisplayName,
                existing: existing?.displayName
            ),
            lastResolvedSessionId: normalizedLiveSessionId
                ?? (existingHasSameIdentity ? existing?.lastResolvedSessionId : nil),
            lastResolvedAt: normalizedLiveSessionId == nil
                ? (existingHasSameIdentity ? existing?.lastResolvedAt : nil)
                : now,
            lastUsedAt: now
        )
        SecureStore.writeCodable(trustedMacRegistry, for: CodexSecureKeys.trustedMacRegistry)
        setCurrentTrustedMacDeviceId(deviceId)
        if migratedScopedState {
            loadMacScopedDefaultsState(for: deviceId)
        }
        SecureStore.writeString(deviceId, for: CodexSecureKeys.lastTrustedMacDeviceId)
        lastTrustedMacDeviceId = deviceId
        secureMacFingerprint = codexSecureFingerprint(for: normalizedPublicKey)
    }

    @discardableResult
    func pruneOfflineTrustedMacRecords(matching trustedMac: CodexTrustedMacRecord) -> Int {
        let targetPublicKey = trustedMac.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let protectedDeviceIds = Set([
            normalizedCurrentTrustedMacDeviceId,
            normalizedRelayMacDeviceId,
        ].compactMap { $0 })
        let now = Date()

        let removableDeviceIds = trustedMacRegistry.records.values
            .filter { record in
                guard !protectedDeviceIds.contains(record.macDeviceId) else {
                    return false
                }
                guard isStaleTrustedMacDisplayDuplicate(record, now: now) else {
                    return false
                }

                if record.macDeviceId == trustedMac.macDeviceId {
                    return true
                }

                guard !targetPublicKey.isEmpty else {
                    return false
                }
                return record.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines) == targetPublicKey
            }
            .map(\.macDeviceId)

        guard !removableDeviceIds.isEmpty else {
            return 0
        }

        for deviceId in removableDeviceIds {
            trustedMacRegistry.records.removeValue(forKey: deviceId)
        }
        if let normalizedPreviousTrustedMacDeviceId,
           removableDeviceIds.contains(normalizedPreviousTrustedMacDeviceId) {
            clearPreviousTrustedMacDeviceId()
        }
        SecureStore.writeCodable(trustedMacRegistry, for: CodexSecureKeys.trustedMacRegistry)
        return removableDeviceIds.count
    }

    func presentationTrustedMacRecords() -> [CodexTrustedMacRecord] {
        let records = compactedTrustedMacRecords(Array(trustedMacRegistry.records.values))
        return hidingStaleGenericPresentationRecords(records)
    }

    private func preferredTrustedMacDisplayName(incoming: String?, existing: String?) -> String? {
        let normalizedIncoming = normalizedTrustedMacDisplayName(incoming)
        let normalizedExisting = normalizedTrustedMacDisplayName(existing)
        if let normalizedIncoming,
           isGenericTrustedMacDisplayName(normalizedIncoming),
           let normalizedExisting,
           !isGenericTrustedMacDisplayName(normalizedExisting) {
            return normalizedExisting
        }
        return normalizedIncoming ?? normalizedExisting
    }

    private func preferredExistingTrustedMacRecord(
        current: CodexTrustedMacRecord?,
        duplicates: [CodexTrustedMacRecord]
    ) -> CodexTrustedMacRecord? {
        guard let current else {
            return duplicates.first
        }

        let candidates = ([current] + duplicates).sorted { shouldPreferTrustedMacRecord($0, over: $1) }
        if isGenericOrMissingTrustedMacDisplayName(current.displayName),
           let specificCandidate = candidates.first(where: { !isGenericOrMissingTrustedMacDisplayName($0.displayName) }) {
            return specificCandidate
        }

        return candidates.first ?? current
    }

    private func normalizedTrustedMacDisplayName(_ displayName: String?) -> String? {
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDisplayName?.isEmpty == false ? trimmedDisplayName : nil
    }

    private func isGenericTrustedMacDisplayName(_ displayName: String) -> Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Mac") == .orderedSame
    }

    private func isGenericOrMissingTrustedMacDisplayName(_ displayName: String?) -> Bool {
        guard let displayName = normalizedTrustedMacDisplayName(displayName) else {
            return true
        }
        return isGenericTrustedMacDisplayName(displayName)
    }

    // Keeps old bridge-era "Mac" placeholders out of the picker without deleting trust records.
    private func hidingStaleGenericPresentationRecords(_ records: [CodexTrustedMacRecord]) -> [CodexTrustedMacRecord] {
        let now = Date()
        guard records.contains(where: { !isStaleGenericPresentationRecord($0, now: now) }) else {
            return records
        }
        return records.filter { !isStaleGenericPresentationRecord($0, now: now) }
    }

    private func isStaleGenericPresentationRecord(_ trustedMac: CodexTrustedMacRecord, now: Date) -> Bool {
        let protectedDeviceIds = Set([
            normalizedCurrentTrustedMacDeviceId,
            normalizedRelayMacDeviceId,
        ].compactMap { $0 })
        guard !protectedDeviceIds.contains(trustedMac.macDeviceId),
              isGenericOrMissingTrustedMacDisplayName(trustedMac.displayName),
              isStaleTrustedMacDisplayDuplicate(trustedMac, now: now) else {
            return false
        }

        return true
    }

    private func compactedTrustedMacRecords(_ records: [CodexTrustedMacRecord]) -> [CodexTrustedMacRecord] {
        var keyedRecords: [String: [CodexTrustedMacRecord]] = [:]
        var unkeyedRecords: [CodexTrustedMacRecord] = []

        for record in records {
            guard let key = trustedMacIdentityCompactionKey(for: record) else {
                unkeyedRecords.append(record)
                continue
            }
            keyedRecords[key, default: []].append(record)
        }

        let identityCompactedRecords = unkeyedRecords + keyedRecords.values.compactMap { records in
            records.sorted { shouldPreferTrustedMacRecord($0, over: $1) }.first
        }
        let sortedRecords = identityCompactedRecords.sorted { shouldPreferTrustedMacRecord($0, over: $1) }
        var selectedRecords: [CodexTrustedMacRecord] = []
        var selectedDisplayNameKeys = Set<String>()
        let now = Date()

        for record in sortedRecords {
            let displayNameKey = trustedMacDisplayNameCompactionKey(record.displayName)
            if let displayNameKey,
               selectedDisplayNameKeys.contains(displayNameKey),
               isStaleTrustedMacDisplayDuplicate(record, now: now) {
                continue
            }

            selectedRecords.append(record)
            if let displayNameKey {
                selectedDisplayNameKeys.insert(displayNameKey)
            }
        }

        return selectedRecords
    }

    private func shouldPreferTrustedMacRecord(
        _ lhs: CodexTrustedMacRecord,
        over rhs: CodexTrustedMacRecord
    ) -> Bool {
        let lhsRank = trustedMacCompactionRank(lhs)
        let rhsRank = trustedMacCompactionRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank > rhsRank
        }

        let lhsDate = trustedMacActivityDate(lhs)
        let rhsDate = trustedMacActivityDate(rhs)
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        let lhsHasResolvedSession = hasResolvedTrustedMacSession(lhs)
        let rhsHasResolvedSession = hasResolvedTrustedMacSession(rhs)
        if lhsHasResolvedSession != rhsHasResolvedSession {
            return lhsHasResolvedSession
        }

        return lhs.macDeviceId < rhs.macDeviceId
    }

    private func trustedMacCompactionRank(_ trustedMac: CodexTrustedMacRecord) -> Int {
        if trustedMac.macDeviceId == normalizedCurrentTrustedMacDeviceId {
            return 500
        }
        if trustedMac.macDeviceId == normalizedRelayMacDeviceId {
            return 450
        }
        if trustedMac.macDeviceId == normalizedPreviousTrustedMacDeviceId {
            return 400
        }
        return 0
    }

    private func hasResolvedTrustedMacSession(_ trustedMac: CodexTrustedMacRecord) -> Bool {
        if trustedMac.lastResolvedAt != nil {
            return true
        }
        return trustedMac.lastResolvedSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func trustedMacActivityDate(_ trustedMac: CodexTrustedMacRecord) -> Date {
        trustedMac.lastResolvedAt ?? trustedMac.lastUsedAt ?? trustedMac.lastPairedAt
    }

    private func trustedMacIdentityCompactionKey(for trustedMac: CodexTrustedMacRecord) -> String? {
        let normalizedPublicKey = trustedMac.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPublicKey.isEmpty else {
            return nil
        }
        return "key:\(normalizedPublicKey)"
    }

    private func trustedMacDisplayNameCompactionKey(_ displayName: String?) -> String? {
        if let displayName = normalizedTrustedMacDisplayName(displayName),
           !isGenericTrustedMacDisplayName(displayName) {
            return "name:\(displayName.lowercased())"
        }

        return nil
    }

    private func hasSameTrustedMacIdentity(_ trustedMac: CodexTrustedMacRecord, asPublicKey publicKey: String) -> Bool {
        let normalizedPublicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPublicKey.isEmpty else {
            return false
        }

        return trustedMac.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedPublicKey
    }

    private func shouldCoalesceTrustedMacRecordByDisplayName(
        _ trustedMac: CodexTrustedMacRecord,
        incomingPublicKey: String,
        now: Date
    ) -> Bool {
        guard !incomingPublicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return isStaleTrustedMacDisplayDuplicate(trustedMac, now: now)
    }

    private func isStaleTrustedMacDisplayDuplicate(_ trustedMac: CodexTrustedMacRecord, now: Date) -> Bool {
        guard !isProtectedTrustedMacRecord(trustedMac) else {
            return false
        }

        return now.timeIntervalSince(trustedMacActivityDate(trustedMac)) > TimeInterval(24 * 60 * 60)
    }

    private func isProtectedTrustedMacRecord(_ trustedMac: CodexTrustedMacRecord) -> Bool {
        let protectedDeviceIds = Set([
            normalizedCurrentTrustedMacDeviceId,
            normalizedRelayMacDeviceId,
            normalizedPreviousTrustedMacDeviceId,
        ].compactMap { $0 })
        return protectedDeviceIds.contains(trustedMac.macDeviceId)
    }
}

enum CodexTrustedSessionResolveURLBuilder {
    // Builds both proxy-relative and root HTTP resolve routes from the remembered WebSocket relay URL.
    static func candidates(from relayURL: String) -> [URL] {
        guard var components = URLComponents(string: relayURL) else {
            return []
        }

        normalizeRelayResolveComponents(&components)

        var candidates: [URL] = []
        let pathComponents = components.path.split(separator: "/").map(String.init)
        if pathComponents.last == "relay" {
            let prefix = pathComponents.dropLast()
            components.path = "/" + (prefix + ["v1", "trusted", "session", "resolve"]).joined(separator: "/")
        } else {
            components.path = "/v1/trusted/session/resolve"
        }
        if let url = components.url {
            candidates.append(url)
        }

        if var rootComponents = URLComponents(string: relayURL) {
            normalizeRelayResolveComponents(&rootComponents)
            rootComponents.path = "/v1/trusted/session/resolve"
            if let rootURL = rootComponents.url,
               !candidates.contains(where: { $0.absoluteString == rootURL.absoluteString }) {
                candidates.append(rootURL)
            }
        }

        return candidates
    }

    private static func normalizeRelayResolveComponents(_ components: inout URLComponents) {
        if components.scheme == "wss" {
            components.scheme = "https"
        } else if components.scheme == "ws" {
            components.scheme = "http"
        }
        components.query = nil
        components.fragment = nil
    }
}

private extension CodexService {
    // Centralizes the bridge-update guidance so every mismatch shows the same Mac command.
    func presentBridgeUpdatePrompt(message: String) {
        bridgeUpdatePrompt = CodexBridgeUpdatePrompt(
            title: "Update the Remodex package on your device",
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

    // Resolves the live relay session for the preferred trusted Mac before we reconnect the socket.
    func resolveTrustedMacSessionImpl(deviceId: String? = nil) async throws -> CodexTrustedSessionResolveResponse {
        guard let trustedMac = trustedMacRecord(for: deviceId) ?? currentTrustedMacRecord else {
            throw CodexTrustedSessionResolveError.noTrustedMac
        }
        guard let relayURL = trustedMac.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayURL.isEmpty else {
            throw CodexTrustedSessionResolveError.noTrustedMac
        }
        let resolveURLs = CodexTrustedSessionResolveURLBuilder.candidates(from: relayURL)
        guard !resolveURLs.isEmpty else {
            throw CodexTrustedSessionResolveError.invalidResponse("The trusted device relay URL is invalid.")
        }

        var lastRetriableResolveError: CodexTrustedSessionResolveError?
        for (index, resolveURL) in resolveURLs.enumerated() {
            do {
                return try await sendTrustedSessionResolveRequest(
                    makeTrustedSessionResolveRequestBody(for: trustedMac),
                    trustedMac: trustedMac,
                    resolveURL: resolveURL,
                    relayURL: relayURL
                )
            } catch let error as CodexTrustedSessionResolveError {
                guard shouldTryNextTrustedResolveCandidate(after: error),
                      index < resolveURLs.count - 1 else {
                    throw error
                }
                lastRetriableResolveError = error
                continue
            }
        }

        throw lastRetriableResolveError ?? CodexTrustedSessionResolveError.unsupportedRelay
    }

    private func makeTrustedSessionResolveRequestBody(
        for trustedMac: CodexTrustedMacRecord
    ) throws -> CodexTrustedSessionResolveRequest {
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

        return CodexTrustedSessionResolveRequest(
            macDeviceId: trustedMac.macDeviceId,
            phoneDeviceId: phoneIdentityState.phoneDeviceId,
            phoneIdentityPublicKey: phoneIdentityState.phoneIdentityPublicKey,
            nonce: nonce,
            timestamp: timestamp,
            signature: signature
        )
    }

    private func shouldTryNextTrustedResolveCandidate(after error: CodexTrustedSessionResolveError) -> Bool {
        switch error {
        case .unsupportedRelay, .invalidResponse, .network:
            return true
        case .macOffline, .rePairRequired, .noTrustedMac:
            return false
        }
    }

    private func sendTrustedSessionResolveRequest(
        _ requestBody: CodexTrustedSessionResolveRequest,
        trustedMac: CodexTrustedMacRecord,
        resolveURL: URL,
        relayURL: String
    ) async throws -> CodexTrustedSessionResolveResponse {
        var request = URLRequest(url: resolveURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let session = trustedSessionResolveURLSession(for: resolveURL)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            if Task.isCancelled
                || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                throw CancellationError()
            }
            throw CodexTrustedSessionResolveError.network("Could not reach the trusted device relay. Check your connection and try again.")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexTrustedSessionResolveError.invalidResponse("The trusted device relay returned an invalid response.")
        }

        if (200..<300).contains(httpResponse.statusCode) {
            guard let resolved = try? JSONDecoder().decode(CodexTrustedSessionResolveResponse.self, from: data),
                  resolved.ok else {
                throw CodexTrustedSessionResolveError.invalidResponse("The trusted device relay returned malformed session data.")
            }
            try validateResolvedTrustedSession(resolved, for: trustedMac)
            applyResolvedTrustedSession(resolved, relayURL: relayURL)
            return resolved
        }

        let errorResponse = try? JSONDecoder().decode(CodexRelayErrorResponse.self, from: data)
        switch errorResponse?.code {
        case "session_unavailable":
            secureConnectionState = .liveSessionUnresolved
            throw CodexTrustedSessionResolveError.macOffline("Your trusted device is offline right now.")
        case "phone_not_trusted", "invalid_signature":
            secureConnectionState = .rePairRequired
            throw CodexTrustedSessionResolveError.rePairRequired(
                "This iPhone is no longer trusted by the paired device. Scan a new QR code to reconnect."
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
                ?? "The trusted device relay could not resolve the current bridge session."
            )
        }
    }

    // Refuses relay bugs or stale indexes that point a switch at a different Mac than requested.
    private func validateResolvedTrustedSession(
        _ resolved: CodexTrustedSessionResolveResponse,
        for trustedMac: CodexTrustedMacRecord
    ) throws {
        guard resolved.macDeviceId == trustedMac.macDeviceId else {
            throw CodexTrustedSessionResolveError.invalidResponse(
                "The trusted device relay returned a session for a different device."
            )
        }

        let resolvedPublicKey = resolved.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trustedPublicKey = trustedMac.macIdentityPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedPublicKey.isEmpty, resolvedPublicKey == trustedPublicKey else {
            throw CodexTrustedSessionResolveError.invalidResponse(
                "The trusted device relay returned a different device identity key."
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
        if normalizedCurrentTrustedMacDeviceId == nil
            || normalizedCurrentTrustedMacDeviceId == resolved.macDeviceId {
            setCurrentTrustedMacDeviceId(resolved.macDeviceId)
        }
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

    private var preferredPairingCodeRelayURL: String? {
        if let normalizedRelayURL {
            return normalizedRelayURL
        }
        if let trustedRelayURL = preferredTrustedMacRecord?.relayURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trustedRelayURL.isEmpty {
            return trustedRelayURL
        }
        let defaultRelayURL = AppEnvironment.relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return defaultRelayURL.isEmpty ? nil : defaultRelayURL
    }

    private func pairingCodeResolveURL(from relayURL: String) -> URL? {
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
            components.path = "/" + (prefix + ["v1", "pairing", "code", "resolve"]).joined(separator: "/")
        } else {
            components.path = "/v1/pairing/code/resolve"
        }

        return components.url
    }

    // Uses a non-proxying URLSession for local/private-overlay relays so trusted reconnect
    // avoids the same iOS proxy path that can break direct websocket pairing.
    private func trustedSessionResolveURLSession(for url: URL) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true

        if prefersDirectRelayTransport(for: url) {
            configuration.connectionProxyDictionary = [:]
        }

        return URLSession(configuration: configuration)
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
        guard !normalized.isEmpty else {
            return "none"
        }
        return shortTranscriptDigest(Data(normalized.utf8)).prefix(8).description
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
