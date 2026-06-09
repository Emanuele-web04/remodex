// FILE: secure-transport.js
// Purpose: Owns the bridge-side E2EE handshake, envelope crypto, and reconnect catch-up buffer.
// Layer: CLI helper
// Exports: createBridgeSecureTransport, SECURE_PROTOCOL_VERSION, PAIRING_QR_VERSION
// Depends on: crypto, ./secure-device-state

const {
  createCipheriv,
  createDecipheriv,
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  sign,
  verify,
} = require("crypto");
const {
  getTrustedPhonePublicKey,
  rememberTrustedPhone,
} = require("./secure-device-state");
const { safeParseJSON } = require("./safe-json");

const PAIRING_QR_VERSION = 2;
const SECURE_PROTOCOL_VERSION = 1;
const HANDSHAKE_TAG = "remodex-e2ee-v1";
const HANDSHAKE_MODE_QR_BOOTSTRAP = "qr_bootstrap";
const HANDSHAKE_MODE_TRUSTED_RECONNECT = "trusted_reconnect";
const SECURE_SENDER_MAC = "mac";
const SECURE_SENDER_IPHONE = "iphone";
const MAX_PAIRING_AGE_MS = 5 * 60 * 1000;
const MAX_BRIDGE_OUTBOUND_MESSAGES = 100;
const MAX_BRIDGE_OUTBOUND_BYTES = 10 * 1024 * 1024;
const LIFECYCLE_STREAM_BYTE_RESERVE_RATIO = 0.3;
const DEFAULT_RECENT_TURN_PROTECT_COUNT = 2;
const DEFAULT_NOTIFY_EVICTION_MAX_AGE_MS = 120_000;
const OUTBOUND_PRIORITY = {
  LIFECYCLE: 0,
  STREAM: 1,
  NOTIFY: 2,
  RPC_RESPONSE: 3,
  TOOL: 4,
};
const SYSTEM_OUTBOUND_METHODS = new Set([
  "thread/status",
  "thread/status/changed",
  "thread/tokenUsage/updated",
  "runtime/catalog/updated",
  "runtime/auth/error",
  "runtime/warning",
  "account/rateLimits/updated",
]);
const PERMISSION_PROTECTED_OUTBOUND_METHODS = new Set([
  "permission/request",
]);

function createBridgeSecureTransport({
  sessionId,
  relayUrl,
  deviceState,
  displayName = "",
  onTrustedPhoneUpdate = null,
  onSecureSessionReady = null,
  persistTrustedPhone = true,
}) {
  let currentDeviceState = deviceState;
  const bridgeDisplayName = normalizeNonEmptyString(displayName);
  let pendingHandshake = null;
  let activeSession = null;
  let liveSendWireMessage = null;
  // Tracks the highest bridge seq the phone has definitely acked, so replay
  // decisions never depend on best-effort local socket writes.
  let lastRelayedBridgeOutboundSeq = 0;
  // Mutex to prevent concurrent replay operations
  let isReplaying = false;
  let currentPairingExpiresAt = Date.now() + MAX_PAIRING_AGE_MS;
  let nextKeyEpoch = 1;
  let nextBridgeOutboundSeq = 1;
  let outboundBufferBytes = 0;
  const outboundBuffer = [];
  const turnRegistrationOrder = [];
  const turnRegistrationRank = new Map();

  function createPairingPayload() {
    currentPairingExpiresAt = Date.now() + MAX_PAIRING_AGE_MS;
    return {
      v: PAIRING_QR_VERSION,
      relay: relayUrl,
      sessionId,
      macDeviceId: currentDeviceState.macDeviceId,
      macIdentityPublicKey: currentDeviceState.macIdentityPublicKey,
      expiresAt: currentPairingExpiresAt,
      displayName: bridgeDisplayName,
    };
  }

  function handleIncomingWireMessage(rawMessage, { sendControlMessage, onApplicationMessage }) {
    const parsed = safeParseJSON(rawMessage);
    if (!parsed || typeof parsed !== "object") {
      return false;
    }

    const kind = normalizeNonEmptyString(parsed.kind);
    if (!kind) {
      if (parsed.method || parsed.id != null) {
        sendControlMessage(createSecureError({
          code: "update_required",
          message: "This bridge requires the latest Remodex iPhone app for secure pairing.",
        }));
        return true;
      }
      return false;
    }

    switch (kind) {
    case "clientHello":
      handleClientHello(parsed, sendControlMessage);
      return true;
    case "clientAuth":
      handleClientAuth(parsed, sendControlMessage);
      return true;
    case "resumeState":
      handleResumeState(parsed);
      return true;
    case "encryptedEnvelope":
      return handleEncryptedEnvelope(parsed, sendControlMessage, onApplicationMessage);
    default:
      return false;
    }
  }

  function queueOutboundApplicationMessage(payloadText, sendWireMessage) {
    const normalizedPayload = normalizeNonEmptyString(payloadText);
    if (!normalizedPayload) {
      return;
    }

    const parsedPayload = safeParseJSON(normalizedPayload) || {};
    const turnContextKey = extractTurnContextKey(parsedPayload);
    if (turnContextKey && !turnRegistrationRank.has(turnContextKey)) {
      turnRegistrationRank.set(turnContextKey, turnRegistrationOrder.length);
      turnRegistrationOrder.push(turnContextKey);
    }
    const bufferEntry = {
      queuedAt: Date.now(),
      raw: normalizedPayload,
      bridgeOutboundSeq: nextBridgeOutboundSeq,
      sizeBytes: Buffer.byteLength(normalizedPayload, "utf8"),
      priority: classifyOutboundPriority(parsedPayload),
      method: normalizeNonEmptyString(parsedPayload.method) || null,
      turnPinKey: extractTurnPinKey(parsedPayload),
      turnContextKey,
    };
    nextBridgeOutboundSeq += 1;
    outboundBuffer.push(bufferEntry);
    outboundBufferBytes += bufferEntry.sizeBytes;
    trimOutboundBuffer();

    if (!activeSession?.isResumed) {
      console.log(
        JSON.stringify({
          event: "bridge_outbound_buffered",
          bridgeOutboundSeq: bufferEntry.bridgeOutboundSeq,
          payloadBytes: bufferEntry.sizeBytes,
        })
      );
    }

    const liveSessionSender = activeSession?.sendWireMessage;
    const effectiveSendWireMessage = typeof liveSessionSender === "function"
      ? liveSessionSender
      : sendWireMessage;
    if (activeSession?.isResumed && typeof effectiveSendWireMessage === "function") {
      sendBufferedEntry(bufferEntry, effectiveSendWireMessage);
    }
  }

  function isSecureChannelReady() {
    return Boolean(activeSession?.isResumed);
  }

  function handleClientHello(message, sendControlMessage) {
    const protocolVersion = Number(message.protocolVersion);
    const incomingSessionId = normalizeNonEmptyString(message.sessionId);
    const handshakeMode = normalizeNonEmptyString(message.handshakeMode);
    const phoneDeviceId = normalizeNonEmptyString(message.phoneDeviceId);
    const phoneIdentityPublicKey = normalizeNonEmptyString(message.phoneIdentityPublicKey);
    const phoneEphemeralPublicKey = normalizeNonEmptyString(message.phoneEphemeralPublicKey);
    const clientNonceBase64 = normalizeNonEmptyString(message.clientNonce);

    if (protocolVersion !== SECURE_PROTOCOL_VERSION || incomingSessionId !== sessionId) {
      sendControlMessage(createSecureError({
        code: "update_required",
        message: "The bridge and iPhone are not using the same secure transport version.",
      }));
      return;
    }

    if (!phoneDeviceId || !phoneIdentityPublicKey || !phoneEphemeralPublicKey || !clientNonceBase64) {
      sendControlMessage(createSecureError({
        code: "invalid_client_hello",
        message: "The iPhone handshake is missing required secure fields.",
      }));
      return;
    }

    if (handshakeMode !== HANDSHAKE_MODE_QR_BOOTSTRAP && handshakeMode !== HANDSHAKE_MODE_TRUSTED_RECONNECT) {
      sendControlMessage(createSecureError({
        code: "invalid_handshake_mode",
        message: "The iPhone requested an unknown secure pairing mode.",
      }));
      return;
    }

    if (handshakeMode === HANDSHAKE_MODE_QR_BOOTSTRAP && Date.now() > currentPairingExpiresAt) {
      sendControlMessage(createSecureError({
        code: "pairing_expired",
        message: "The pairing QR code has expired. Generate a new QR code from the bridge.",
      }));
      return;
    }

    const trustedPhonePublicKey = getTrustedPhonePublicKey(currentDeviceState, phoneDeviceId);
    if (handshakeMode === HANDSHAKE_MODE_TRUSTED_RECONNECT) {
      if (!trustedPhonePublicKey) {
        sendControlMessage(createSecureError({
          code: "phone_not_trusted",
          message: "This iPhone is not trusted by the current bridge session. Scan a fresh QR code to pair again.",
        }));
        return;
      }
      if (trustedPhonePublicKey !== phoneIdentityPublicKey) {
        sendControlMessage(createSecureError({
          code: "phone_identity_changed",
          message: "The trusted iPhone identity does not match this reconnect attempt.",
        }));
        return;
      }
    }

    const clientNonce = base64ToBuffer(clientNonceBase64);
    if (!clientNonce || clientNonce.length === 0) {
      sendControlMessage(createSecureError({
        code: "invalid_client_nonce",
        message: "The iPhone secure nonce could not be decoded.",
      }));
      return;
    }

    const ephemeral = generateKeyPairSync("x25519");
    const privateJwk = ephemeral.privateKey.export({ format: "jwk" });
    const publicJwk = ephemeral.publicKey.export({ format: "jwk" });
    const serverNonce = randomBytes(32);
    const keyEpoch = nextKeyEpoch;
    const expiresAtForTranscript = handshakeMode === HANDSHAKE_MODE_QR_BOOTSTRAP
      ? currentPairingExpiresAt
      : 0;
    const transcriptBytes = buildTranscriptBytes({
      sessionId,
      protocolVersion,
      handshakeMode,
      keyEpoch,
      macDeviceId: currentDeviceState.macDeviceId,
      phoneDeviceId,
      macIdentityPublicKey: currentDeviceState.macIdentityPublicKey,
      phoneIdentityPublicKey,
      macEphemeralPublicKey: base64UrlToBase64(publicJwk.x),
      phoneEphemeralPublicKey,
      clientNonce,
      serverNonce,
      expiresAtForTranscript,
    });
    const macSignature = signTranscript(
      currentDeviceState.macIdentityPrivateKey,
      currentDeviceState.macIdentityPublicKey,
      transcriptBytes
    );
    debugSecureLog(
      `serverHello mode=${handshakeMode} session=${shortId(sessionId)} keyEpoch=${keyEpoch} `
      + `mac=${shortId(currentDeviceState.macDeviceId)} phone=${shortId(phoneDeviceId)} `
      + `macKey=${shortFingerprint(currentDeviceState.macIdentityPublicKey)} `
      + `phoneKey=${shortFingerprint(phoneIdentityPublicKey)} `
      + `transcript=${transcriptDigest(transcriptBytes)}`
    );

    pendingHandshake = {
      sessionId,
      handshakeMode,
      keyEpoch,
      phoneDeviceId,
      phoneIdentityPublicKey,
      phoneEphemeralPublicKey,
      macEphemeralPrivateKey: base64UrlToBase64(privateJwk.d),
      macEphemeralPublicKey: base64UrlToBase64(publicJwk.x),
      transcriptBytes,
      expiresAtForTranscript,
    };
    activeSession = null;

    sendControlMessage({
      kind: "serverHello",
      protocolVersion: SECURE_PROTOCOL_VERSION,
      sessionId,
      handshakeMode,
      macDeviceId: currentDeviceState.macDeviceId,
      macIdentityPublicKey: currentDeviceState.macIdentityPublicKey,
      macEphemeralPublicKey: pendingHandshake.macEphemeralPublicKey,
      serverNonce: serverNonce.toString("base64"),
      keyEpoch,
      expiresAtForTranscript,
      macSignature,
      clientNonce: clientNonceBase64,
      displayName: bridgeDisplayName,
    });
  }

  function handleClientAuth(message, sendControlMessage) {
    if (!pendingHandshake) {
      sendControlMessage(createSecureError({
        code: "unexpected_client_auth",
        message: "The bridge did not have a pending secure handshake to finalize.",
      }));
      return;
    }

    const incomingSessionId = normalizeNonEmptyString(message.sessionId);
    const phoneDeviceId = normalizeNonEmptyString(message.phoneDeviceId);
    const keyEpoch = Number(message.keyEpoch);
    const phoneSignature = normalizeNonEmptyString(message.phoneSignature);
    if (
      incomingSessionId !== pendingHandshake.sessionId
      || phoneDeviceId !== pendingHandshake.phoneDeviceId
      || keyEpoch !== pendingHandshake.keyEpoch
      || !phoneSignature
    ) {
      pendingHandshake = null;
      sendControlMessage(createSecureError({
        code: "invalid_client_auth",
        message: "The secure client authentication payload was invalid.",
      }));
      return;
    }

    const clientAuthTranscript = Buffer.concat([
      pendingHandshake.transcriptBytes,
      encodeLengthPrefixedUTF8("client-auth"),
    ]);
    const phoneVerified = verifyTranscript(
      pendingHandshake.phoneIdentityPublicKey,
      clientAuthTranscript,
      phoneSignature
    );
    if (!phoneVerified) {
      pendingHandshake = null;
      sendControlMessage(createSecureError({
        code: "invalid_phone_signature",
        message: "The iPhone secure signature could not be verified.",
      }));
      return;
    }

    const sharedSecret = diffieHellman({
      privateKey: createPrivateKey({
        key: {
          crv: "X25519",
          d: base64ToBase64Url(pendingHandshake.macEphemeralPrivateKey),
          kty: "OKP",
          x: base64ToBase64Url(pendingHandshake.macEphemeralPublicKey),
        },
        format: "jwk",
      }),
      publicKey: createPublicKey({
        key: {
          crv: "X25519",
          kty: "OKP",
          x: base64ToBase64Url(pendingHandshake.phoneEphemeralPublicKey),
        },
        format: "jwk",
      }),
    });
    const salt = createHash("sha256").update(pendingHandshake.transcriptBytes).digest();
    const infoPrefix = [
      HANDSHAKE_TAG,
      pendingHandshake.sessionId,
      currentDeviceState.macDeviceId,
      pendingHandshake.phoneDeviceId,
      String(pendingHandshake.keyEpoch),
    ].join("|");

    activeSession = {
      sessionId: pendingHandshake.sessionId,
      keyEpoch: pendingHandshake.keyEpoch,
      phoneDeviceId: pendingHandshake.phoneDeviceId,
      phoneIdentityPublicKey: pendingHandshake.phoneIdentityPublicKey,
      phoneToMacKey: deriveAesKey(sharedSecret, salt, `${infoPrefix}|phoneToMac`),
      macToPhoneKey: deriveAesKey(sharedSecret, salt, `${infoPrefix}|macToPhone`),
      lastInboundCounter: -1,
      nextOutboundCounter: 0,
      isResumed: false,
      sendWireMessage: liveSendWireMessage,
      firstOutboundSeq: nextBridgeOutboundSeq,
    };

    nextKeyEpoch = pendingHandshake.keyEpoch + 1;
    if (
      pendingHandshake.handshakeMode === HANDSHAKE_MODE_QR_BOOTSTRAP
      || getTrustedPhonePublicKey(currentDeviceState, pendingHandshake.phoneDeviceId)
    ) {
      // Lock the trusted phone identity so later reconnects can be verified cleanly.
      const previousTrustedPhonePublicKey = getTrustedPhonePublicKey(
        currentDeviceState,
        pendingHandshake.phoneDeviceId
      );
      currentDeviceState = rememberTrustedPhone(
        currentDeviceState,
        pendingHandshake.phoneDeviceId,
        pendingHandshake.phoneIdentityPublicKey,
        { persist: persistTrustedPhone }
      );
      if (previousTrustedPhonePublicKey !== pendingHandshake.phoneIdentityPublicKey) {
        onTrustedPhoneUpdate?.(currentDeviceState, {
          phoneDeviceId: pendingHandshake.phoneDeviceId,
          phoneIdentityPublicKey: pendingHandshake.phoneIdentityPublicKey,
        });
      }
    }
    if (pendingHandshake.handshakeMode === HANDSHAKE_MODE_QR_BOOTSTRAP) {
      resetOutboundReplayState();
      activeSession.firstOutboundSeq = nextBridgeOutboundSeq;
    }

    const completedHandshakeMode = pendingHandshake.handshakeMode;
    pendingHandshake = null;
    onSecureSessionReady?.({
      phoneDeviceId: activeSession.phoneDeviceId,
      handshakeMode: completedHandshakeMode,
      keyEpoch: activeSession.keyEpoch,
    });
    sendControlMessage({
      kind: "secureReady",
      sessionId,
      keyEpoch: activeSession.keyEpoch,
      macDeviceId: currentDeviceState.macDeviceId,
    });
  }

  function handleResumeState(message) {
    if (!activeSession) {
      return;
    }

    const incomingSessionId = normalizeNonEmptyString(message.sessionId);
    const keyEpoch = Number(message.keyEpoch);
    if (incomingSessionId !== sessionId || keyEpoch !== activeSession.keyEpoch) {
      return;
    }

    const lastAppliedBridgeOutboundSeq = Number(message.lastAppliedBridgeOutboundSeq) || 0;
    lastRelayedBridgeOutboundSeq = lastAppliedBridgeOutboundSeq;
    const missingEntries = replayableOutboundEntries(lastAppliedBridgeOutboundSeq, {
      includeCurrentSessionEntries: true,
    });
    activeSession.isResumed = true;
    for (const entry of missingEntries) {
      if (!sendBufferedEntry(entry, activeSession.sendWireMessage)) {
        break;
      }
    }
  }

  function handleEncryptedEnvelope(message, sendControlMessage, onApplicationMessage) {
    if (!activeSession) {
      sendControlMessage(createSecureError({
        code: "secure_channel_unavailable",
        message: "The secure channel is not ready yet on the bridge.",
      }));
      return true;
    }

    const incomingSessionId = normalizeNonEmptyString(message.sessionId);
    const keyEpoch = Number(message.keyEpoch);
    const sender = normalizeNonEmptyString(message.sender);
    const counter = Number(message.counter);
    if (
      incomingSessionId !== sessionId
      || keyEpoch !== activeSession.keyEpoch
      || sender !== SECURE_SENDER_IPHONE
      || !Number.isInteger(counter)
      || counter <= activeSession.lastInboundCounter
    ) {
      sendControlMessage(createSecureError({
        code: "invalid_envelope",
        message: "The bridge rejected an invalid or replayed secure envelope.",
      }));
      return true;
    }

    const plaintextBuffer = decryptEnvelopeBuffer(message, activeSession.phoneToMacKey, SECURE_SENDER_IPHONE, counter);
    if (!plaintextBuffer) {
      sendControlMessage(createSecureError({
        code: "decrypt_failed",
        message: "The bridge could not decrypt the iPhone secure payload.",
      }));
      return true;
    }

    activeSession.lastInboundCounter = counter;
    const payloadObject = safeParseJSON(plaintextBuffer.toString("utf8"));
    const payloadText = normalizeNonEmptyString(payloadObject?.payloadText);
    if (!payloadText) {
      sendControlMessage(createSecureError({
        code: "invalid_payload",
        message: "The secure payload did not contain a usable application message.",
      }));
      return true;
    }

    onApplicationMessage(payloadText);
    return true;
  }

  function bindLiveSendWireMessage(sendWireMessage) {
    liveSendWireMessage = sendWireMessage;
    if (activeSession) {
      activeSession.sendWireMessage = sendWireMessage;
      replayBufferedOutboundMessages();
    }
  }

  function trimOutboundBuffer() {
    const messageCap = readOutboundMessageCap();
    const priorityEnabled = readEnvFlag("REMODEX_BRIDGE_PRIORITY_OUTBOUND", true);
    const legacyTrim = readEnvFlag("REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM", false);

    if (legacyTrim || !priorityEnabled) {
      trimOutboundBufferLegacy(messageCap);
      return;
    }

    trimOutboundBufferPriority(messageCap);
  }

  function trimOutboundBufferLegacy(messageCap) {
    let removeCount = 0;
    let removedBytes = 0;
    while (
      (outboundBuffer.length - removeCount) > messageCap
      || (outboundBufferBytes - removedBytes) > MAX_BRIDGE_OUTBOUND_BYTES
    ) {
      const entry = outboundBuffer[removeCount];
      if (!entry) {
        break;
      }
      removedBytes += entry.sizeBytes;
      removeCount += 1;
    }
    if (removeCount > 0) {
      const droppedEntries = outboundBuffer.slice(0, removeCount);
      logOutboundDropped(droppedEntries, removedBytes, "overflow");
      outboundBuffer.splice(0, removeCount);
      outboundBufferBytes = Math.max(0, outboundBufferBytes - removedBytes);
    }
  }

  function trimOutboundBufferPriority(messageCap) {
    const droppedEntries = [];
    let stallDropCount = 0;

    while (
      outboundBuffer.length > messageCap
      || outboundBufferBytes > MAX_BRIDGE_OUTBOUND_BYTES
    ) {
      const protectedIndices = computeProtectedEntryIndices(outboundBuffer, {
        turnRegistrationOrder,
      });
      let dropIndex = selectPriorityDropIndex(outboundBuffer, protectedIndices);
      let dropReason = "overflow";

      if (dropIndex < 0) {
        dropIndex = selectAgeBasedNotifyDropIndex(outboundBuffer);
        if (dropIndex >= 0) {
          dropReason = "notify_age_eviction";
          stallDropCount += 1;
        }
      }

      if (dropIndex < 0) {
        dropIndex = selectOldestRpcDropIndex(outboundBuffer);
        if (dropIndex >= 0) {
          dropReason = "stall_rpc_eviction";
          stallDropCount += 1;
        }
      }

      if (dropIndex < 0) {
        dropIndex = selectOldestStreamDropIndex(outboundBuffer);
        if (dropIndex >= 0) {
          dropReason = "stall_stream_eviction";
          stallDropCount += 1;
        }
      }

      if (dropIndex < 0 && outboundBuffer.length > 0) {
        dropIndex = 0;
        dropReason = "stall_fifo_eviction";
        stallDropCount += 1;
      }

      if (dropIndex < 0) {
        break;
      }

      const [entry] = outboundBuffer.splice(dropIndex, 1);
      outboundBufferBytes = Math.max(0, outboundBufferBytes - entry.sizeBytes);
      droppedEntries.push({ entry, reason: dropReason });
    }

    if (stallDropCount > 0) {
      console.log(
        JSON.stringify({
          event: "bridge_outbound_drop_stalled",
          stallDropCount,
          bufferLength: outboundBuffer.length,
          bufferBytes: outboundBufferBytes,
        })
      );
    }

    if (droppedEntries.length > 0) {
      const entriesOnly = droppedEntries.map((dropped) => dropped.entry);
      const droppedBytes = entriesOnly.reduce((total, entry) => total + entry.sizeBytes, 0);
      const reasons = new Set(droppedEntries.map((dropped) => dropped.reason));
      const reason = reasons.size === 1 ? [...reasons][0] : "overflow";
      logOutboundDropped(entriesOnly, droppedBytes, reason);
    }
  }

  function logOutboundDropped(droppedEntries, droppedBytes, reason) {
    const firstEntry = droppedEntries[0] ?? null;
    const lastEntry = droppedEntries[droppedEntries.length - 1] ?? null;
    console.log(
      JSON.stringify({
        event: "bridge_outbound_dropped",
        droppedCount: droppedEntries.length,
        droppedBytes,
        firstSeq: firstEntry?.bridgeOutboundSeq ?? null,
        lastSeq: lastEntry?.bridgeOutboundSeq ?? null,
        reason,
        priority: firstEntry?.priority ?? null,
        method: firstEntry?.method ?? null,
        bridgeOutboundSeq: firstEntry?.bridgeOutboundSeq ?? null,
        highestPriorityTierDropped: droppedEntries.reduce(
          (maxPriority, entry) => Math.max(maxPriority, entry.priority ?? OUTBOUND_PRIORITY.NOTIFY),
          OUTBOUND_PRIORITY.LIFECYCLE
        ),
      })
    );
  }

  // Starts each fresh QR bootstrap with a clean catch-up window for the single trusted phone.
  function resetOutboundReplayState() {
    outboundBuffer.length = 0;
    outboundBufferBytes = 0;
    turnRegistrationOrder.length = 0;
    turnRegistrationRank.clear();
    lastRelayedBridgeOutboundSeq = 0;
    nextBridgeOutboundSeq = 1;
  }

  function sendBufferedEntry(entry, sendWireMessage) {
    if (!activeSession?.isResumed || typeof sendWireMessage !== "function") {
      return false;
    }

    const envelope = encryptEnvelopePayload(
      {
        bridgeOutboundSeq: entry.bridgeOutboundSeq,
        payloadText: entry.raw,
      },
      activeSession.macToPhoneKey,
      SECURE_SENDER_MAC,
      activeSession.nextOutboundCounter,
      sessionId,
      activeSession.keyEpoch
    );
    activeSession.nextOutboundCounter += 1;
    return sendWireMessage(JSON.stringify(envelope)) !== false;
  }

  function replayableOutboundEntries(
    lastAppliedBridgeOutboundSeq,
    { includeCurrentSessionEntries = false } = {}
  ) {
    return outboundBuffer.filter((entry) => {
      if (entry.bridgeOutboundSeq > lastAppliedBridgeOutboundSeq) {
        return true;
      }

      // Stale cursors from a previous Mac/session must not suppress responses
      // produced after this secure channel became active, including initialize.
      return includeCurrentSessionEntries
        && activeSession
        && entry.bridgeOutboundSeq >= activeSession.firstOutboundSeq;
    });
  }

  // Replays from the last phone ack instead of local socket writes, so a relay
  // flap cannot make the bridge skip output the phone never actually received.
  // Mutex-protected to prevent concurrent replay operations.
  function replayBufferedOutboundMessages() {
    if (!activeSession?.isResumed || typeof activeSession.sendWireMessage !== "function") {
      return;
    }

    // Mutex: Prevent concurrent replay operations
    if (isReplaying) {
      debugSecureLog("Replay already in progress, skipping concurrent request");
      return;
    }

    isReplaying = true;
    try {
      for (const entry of replayableOutboundEntries(lastRelayedBridgeOutboundSeq)) {
        if (!sendBufferedEntry(entry, activeSession.sendWireMessage)) {
          break;
        }
      }
    } finally {
      isReplaying = false;
    }
  }

  return {
    PAIRING_QR_VERSION,
    SECURE_PROTOCOL_VERSION,
    bindLiveSendWireMessage,
    createPairingPayload,
    handleIncomingWireMessage,
    isSecureChannelReady,
    queueOutboundApplicationMessage,
  };
}

function debugSecureLog(message) {
  console.log(`[remodex][secure] ${message}`);
}

function shortId(value) {
  const normalized = normalizeNonEmptyString(value);
  return normalized ? createHash("sha256").update(normalized).digest("hex").slice(0, 8) : "none";
}

function shortFingerprint(publicKeyBase64) {
  const bytes = base64ToBuffer(publicKeyBase64);
  if (!bytes || bytes.length === 0) {
    return "invalid";
  }
  return createHash("sha256").update(bytes).digest("hex").slice(0, 12);
}

function transcriptDigest(transcriptBytes) {
  return createHash("sha256").update(transcriptBytes).digest("hex").slice(0, 16);
}

function encryptEnvelopePayload(payloadObject, key, sender, counter, sessionId, keyEpoch) {
  const nonce = nonceForDirection(sender, counter);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([
    cipher.update(Buffer.from(JSON.stringify(payloadObject), "utf8")),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();

  return {
    kind: "encryptedEnvelope",
    v: SECURE_PROTOCOL_VERSION,
    sessionId,
    keyEpoch,
    sender,
    counter,
    ciphertext: ciphertext.toString("base64"),
    tag: tag.toString("base64"),
  };
}

function decryptEnvelopeBuffer(envelope, key, sender, counter) {
  try {
    const nonce = nonceForDirection(sender, counter);
    const decipher = createDecipheriv("aes-256-gcm", key, nonce);
    decipher.setAuthTag(base64ToBuffer(envelope.tag));
    return Buffer.concat([
      decipher.update(base64ToBuffer(envelope.ciphertext)),
      decipher.final(),
    ]);
  } catch {
    return null;
  }
}

function deriveAesKey(sharedSecret, salt, infoLabel) {
  return Buffer.from(hkdfSync("sha256", sharedSecret, salt, Buffer.from(infoLabel, "utf8"), 32));
}

function signTranscript(privateKeyBase64, publicKeyBase64, transcriptBytes) {
  const signature = sign(
    null,
    transcriptBytes,
    createPrivateKey({
      key: {
        crv: "Ed25519",
        d: base64ToBase64Url(privateKeyBase64),
        kty: "OKP",
        x: base64ToBase64Url(publicKeyBase64),
      },
      format: "jwk",
    })
  );
  return signature.toString("base64");
}

function verifyTranscript(publicKeyBase64, transcriptBytes, signatureBase64) {
  try {
    return verify(
      null,
      transcriptBytes,
      createPublicKey({
        key: {
          crv: "Ed25519",
          kty: "OKP",
          x: base64ToBase64Url(publicKeyBase64),
        },
        format: "jwk",
      }),
      base64ToBuffer(signatureBase64)
    );
  } catch {
    return false;
  }
}

function buildTranscriptBytes({
  sessionId,
  protocolVersion,
  handshakeMode,
  keyEpoch,
  macDeviceId,
  phoneDeviceId,
  macIdentityPublicKey,
  phoneIdentityPublicKey,
  macEphemeralPublicKey,
  phoneEphemeralPublicKey,
  clientNonce,
  serverNonce,
  expiresAtForTranscript,
}) {
  return Buffer.concat([
    encodeLengthPrefixedUTF8(HANDSHAKE_TAG),
    encodeLengthPrefixedUTF8(sessionId),
    encodeLengthPrefixedUTF8(String(protocolVersion)),
    encodeLengthPrefixedUTF8(handshakeMode),
    encodeLengthPrefixedUTF8(String(keyEpoch)),
    encodeLengthPrefixedUTF8(macDeviceId),
    encodeLengthPrefixedUTF8(phoneDeviceId),
    encodeLengthPrefixedBuffer(base64ToBuffer(macIdentityPublicKey)),
    encodeLengthPrefixedBuffer(base64ToBuffer(phoneIdentityPublicKey)),
    encodeLengthPrefixedBuffer(base64ToBuffer(macEphemeralPublicKey)),
    encodeLengthPrefixedBuffer(base64ToBuffer(phoneEphemeralPublicKey)),
    encodeLengthPrefixedBuffer(clientNonce),
    encodeLengthPrefixedBuffer(serverNonce),
    encodeLengthPrefixedUTF8(String(expiresAtForTranscript)),
  ]);
}

function encodeLengthPrefixedUTF8(value) {
  return encodeLengthPrefixedBuffer(Buffer.from(String(value), "utf8"));
}

function encodeLengthPrefixedBuffer(buffer) {
  const lengthBuffer = Buffer.allocUnsafe(4);
  lengthBuffer.writeUInt32BE(buffer.length, 0);
  return Buffer.concat([lengthBuffer, buffer]);
}

function nonceForDirection(sender, counter) {
  const nonce = Buffer.alloc(12, 0);
  nonce.writeUInt8(sender === SECURE_SENDER_MAC ? 1 : 2, 0);
  let value = BigInt(counter);
  for (let index = 11; index >= 1; index -= 1) {
    nonce[index] = Number(value & 0xffn);
    value >>= 8n;
  }
  return nonce;
}

function createSecureError({ code, message }) {
  return {
    kind: "secureError",
    code,
    message,
  };
}

function normalizeNonEmptyString(value) {
  if (typeof value !== "string") {
    return "";
  }
  return value.trim();
}

function readEnvFlag(name, defaultValue) {
  const value = process.env[name];
  if (value === undefined) {
    return defaultValue;
  }
  return value === "1" || value.toLowerCase() === "true";
}

function readOutboundMessageCap() {
  const raw = process.env.REMODEX_BRIDGE_OUTBOUND_CAP;
  if (!raw) {
    return MAX_BRIDGE_OUTBOUND_MESSAGES;
  }

  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return MAX_BRIDGE_OUTBOUND_MESSAGES;
  }
  return Math.floor(parsed);
}

function readString(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function readRecentTurnProtectCount() {
  const raw = process.env.REMODEX_BRIDGE_OUTBOUND_RECENT_TURNS;
  if (!raw) {
    return DEFAULT_RECENT_TURN_PROTECT_COUNT;
  }

  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return DEFAULT_RECENT_TURN_PROTECT_COUNT;
  }

  return Math.floor(parsed);
}

function readNotifyEvictionMaxAgeMs() {
  const raw = process.env.REMODEX_BRIDGE_NOTIFY_EVICTION_MAX_AGE_MS;
  if (!raw) {
    return DEFAULT_NOTIFY_EVICTION_MAX_AGE_MS;
  }

  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return DEFAULT_NOTIFY_EVICTION_MAX_AGE_MS;
  }

  return Math.floor(parsed);
}

function classifyOutboundPriority(payload) {
  if (!payload || typeof payload !== "object") {
    return OUTBOUND_PRIORITY.NOTIFY;
  }

  if (payload.id != null && (payload.result !== undefined || payload.error !== undefined)) {
    return OUTBOUND_PRIORITY.RPC_RESPONSE;
  }

  const method = normalizeNonEmptyString(payload.method);
  if (!method) {
    return OUTBOUND_PRIORITY.NOTIFY;
  }

  if (SYSTEM_OUTBOUND_METHODS.has(method)) {
    return OUTBOUND_PRIORITY.LIFECYCLE;
  }

  switch (method) {
  case "turn/started":
  case "turn/completed":
  case "turn/failed":
    return OUTBOUND_PRIORITY.LIFECYCLE;
  case "item/completed":
  case "item/agentMessage/delta":
  case "item/reasoning/textDelta":
    return OUTBOUND_PRIORITY.STREAM;
  case "item/toolCall":
  case "item/toolCallUpdate":
    return OUTBOUND_PRIORITY.TOOL;
  case "permission/request":
    return OUTBOUND_PRIORITY.NOTIFY;
  default:
    return OUTBOUND_PRIORITY.NOTIFY;
  }
}

function readTurnIdsFromParams(params) {
  const normalizedParams = params && typeof params === "object" ? params : {};
  const threadId = readString(normalizedParams.threadId)
    || readString(normalizedParams.thread_id)
    || readString(normalizedParams.item?.threadId)
    || readString(normalizedParams.item?.thread_id)
    || readString(normalizedParams.item?.thread?.id);
  const turnId = readString(normalizedParams.turnId)
    || readString(normalizedParams.turn_id)
    || readString(normalizedParams.item?.turnId)
    || readString(normalizedParams.item?.turn_id)
    || readString(normalizedParams.item?.turn?.id);
  if (!threadId || !turnId) {
    return null;
  }

  return { threadId, turnId };
}

function extractTurnContextKey(payload) {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const turnIds = readTurnIdsFromParams(payload.params);
  if (!turnIds) {
    return null;
  }

  return turnPinKeyString(turnIds);
}

function extractTurnPinKey(payload) {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const method = normalizeNonEmptyString(payload.method);
  if (!method) {
    return null;
  }

  const pinMethods = new Set([
    "item/completed",
    "turn/completed",
  ]);
  if (!pinMethods.has(method)) {
    return null;
  }

  return readTurnIdsFromParams(payload.params);
}

function turnPinKeyString(pinKey) {
  return `${pinKey.threadId}\0${pinKey.turnId}`;
}

function computePinnedEntryIndices(entries) {
  const pinnedIndices = new Set();
  const latestItemCompletedByTurn = new Map();
  const latestTurnCompletedByTurn = new Map();

  entries.forEach((entry, index) => {
    if (!entry.turnPinKey) {
      return;
    }

    const key = turnPinKeyString(entry.turnPinKey);
    if (entry.method === "item/completed") {
      const existing = latestItemCompletedByTurn.get(key);
      if (!existing || entry.bridgeOutboundSeq > existing.entry.bridgeOutboundSeq) {
        latestItemCompletedByTurn.set(key, { index, entry });
      }
    }
    if (entry.method === "turn/completed") {
      const existing = latestTurnCompletedByTurn.get(key);
      if (!existing || entry.bridgeOutboundSeq > existing.entry.bridgeOutboundSeq) {
        latestTurnCompletedByTurn.set(key, { index, entry });
      }
    }
  });

  for (const { index } of latestItemCompletedByTurn.values()) {
    pinnedIndices.add(index);
  }
  for (const { index } of latestTurnCompletedByTurn.values()) {
    pinnedIndices.add(index);
  }

  return pinnedIndices;
}

function computeSystemProtectedIndices(entries) {
  const protectedIndices = new Set();
  entries.forEach((entry, index) => {
    if (entry.method && SYSTEM_OUTBOUND_METHODS.has(entry.method)) {
      protectedIndices.add(index);
    }
  });
  return protectedIndices;
}

function computePermissionProtectedIndices(entries) {
  const protectedIndices = new Set();
  entries.forEach((entry, index) => {
    if (entry.method && PERMISSION_PROTECTED_OUTBOUND_METHODS.has(entry.method)) {
      protectedIndices.add(index);
    }
  });
  return protectedIndices;
}

function computeRecentTurnProtectedIndices(
  entries,
  recentCount = readRecentTurnProtectCount(),
  options = {},
) {
  if (recentCount <= 0) {
    return new Set();
  }

  const registrationOrder = Array.isArray(options.turnRegistrationOrder)
    ? options.turnRegistrationOrder
    : null;
  let recentTurnKeySet;
  if (registrationOrder && registrationOrder.length > 0) {
    recentTurnKeySet = new Set(registrationOrder.slice(-recentCount));
  } else {
    const turnOrder = [];
    const seenTurnKeys = new Set();
    entries.forEach((entry) => {
      const turnContextKey = entry.turnContextKey;
      if (!turnContextKey || seenTurnKeys.has(turnContextKey)) {
        return;
      }
      seenTurnKeys.add(turnContextKey);
      turnOrder.push(turnContextKey);
    });
    recentTurnKeySet = new Set(turnOrder.slice(-recentCount));
  }

  const protectedIndices = new Set();

  entries.forEach((entry, index) => {
    if (entry.turnContextKey && recentTurnKeySet.has(entry.turnContextKey)) {
      protectedIndices.add(index);
    }
  });

  return protectedIndices;
}

function computeProtectedEntryIndices(entries, options = {}) {
  const protectedIndices = new Set([
    ...computePinnedEntryIndices(entries),
    ...computeSystemProtectedIndices(entries),
    ...computePermissionProtectedIndices(entries),
    ...computeRecentTurnProtectedIndices(entries, readRecentTurnProtectCount(), options),
  ]);
  return protectedIndices;
}

function sumEntryBytesByPriority(entries, maxPriorityInclusive) {
  return entries.reduce((total, entry) => {
    if ((entry.priority ?? OUTBOUND_PRIORITY.NOTIFY) <= maxPriorityInclusive) {
      return total + entry.sizeBytes;
    }
    return total;
  }, 0);
}

function selectPriorityDropIndex(entries, protectedIndices) {
  const lifecycleStreamBytes = sumEntryBytesByPriority(entries, OUTBOUND_PRIORITY.STREAM);
  const totalBytes = entries.reduce((total, entry) => total + entry.sizeBytes, 0);
  const nonLifecycleStreamBytes = totalBytes - lifecycleStreamBytes;
  const maxNonLifecycleStreamBytes = Math.floor(
    MAX_BRIDGE_OUTBOUND_BYTES * (1 - LIFECYCLE_STREAM_BYTE_RESERVE_RATIO)
  );
  const protectLifecycleStream = nonLifecycleStreamBytes > maxNonLifecycleStreamBytes;

  const candidateIndices = [];
  entries.forEach((entry, index) => {
    if (protectedIndices.has(index)) {
      return;
    }
    if (
      protectLifecycleStream
      && (entry.priority ?? OUTBOUND_PRIORITY.NOTIFY) <= OUTBOUND_PRIORITY.STREAM
    ) {
      return;
    }
    candidateIndices.push(index);
  });

  if (candidateIndices.length === 0) {
    entries.forEach((entry, index) => {
      if (protectedIndices.has(index)) {
        return;
      }
      candidateIndices.push(index);
    });
  }

  if (candidateIndices.length === 0) {
    return selectOldestPinnedTurnDropIndex(entries, protectedIndices);
  }

  let selectedIndex = candidateIndices[0];
  for (const index of candidateIndices.slice(1)) {
    const candidate = entries[index];
    const selected = entries[selectedIndex];
    const candidatePriority = candidate.priority ?? OUTBOUND_PRIORITY.NOTIFY;
    const selectedPriority = selected.priority ?? OUTBOUND_PRIORITY.NOTIFY;
    if (candidatePriority > selectedPriority) {
      selectedIndex = index;
      continue;
    }
    if (
      candidatePriority === selectedPriority
      && candidate.bridgeOutboundSeq < selected.bridgeOutboundSeq
    ) {
      selectedIndex = index;
    }
  }

  return selectedIndex;
}

function selectAgeBasedNotifyDropIndex(entries, now = Date.now()) {
  const maxAgeMs = readNotifyEvictionMaxAgeMs();
  let selectedIndex = -1;
  let selectedSeq = Infinity;

  entries.forEach((entry, index) => {
    const priority = entry.priority ?? OUTBOUND_PRIORITY.NOTIFY;
    if (priority !== OUTBOUND_PRIORITY.NOTIFY && priority !== OUTBOUND_PRIORITY.TOOL) {
      return;
    }

    const ageMs = now - (entry.queuedAt ?? 0);
    if (ageMs < maxAgeMs) {
      return;
    }

    if (entry.bridgeOutboundSeq < selectedSeq) {
      selectedSeq = entry.bridgeOutboundSeq;
      selectedIndex = index;
    }
  });

  if (selectedIndex >= 0) {
    return selectedIndex;
  }

  entries.forEach((entry, index) => {
    const priority = entry.priority ?? OUTBOUND_PRIORITY.NOTIFY;
    if (priority !== OUTBOUND_PRIORITY.NOTIFY && priority !== OUTBOUND_PRIORITY.TOOL) {
      return;
    }

    if (entry.bridgeOutboundSeq < selectedSeq) {
      selectedSeq = entry.bridgeOutboundSeq;
      selectedIndex = index;
    }
  });

  return selectedIndex;
}

function selectOldestRpcDropIndex(entries) {
  let selectedIndex = -1;
  let selectedSeq = Infinity;

  entries.forEach((entry, index) => {
    if ((entry.priority ?? OUTBOUND_PRIORITY.NOTIFY) !== OUTBOUND_PRIORITY.RPC_RESPONSE) {
      return;
    }

    if (entry.bridgeOutboundSeq < selectedSeq) {
      selectedSeq = entry.bridgeOutboundSeq;
      selectedIndex = index;
    }
  });

  return selectedIndex;
}

function selectOldestStreamDropIndex(entries) {
  let selectedIndex = -1;
  let selectedSeq = Infinity;

  entries.forEach((entry, index) => {
    const priority = entry.priority ?? OUTBOUND_PRIORITY.NOTIFY;
    if (priority !== OUTBOUND_PRIORITY.STREAM && priority !== OUTBOUND_PRIORITY.TOOL) {
      return;
    }

    if (entry.bridgeOutboundSeq < selectedSeq) {
      selectedSeq = entry.bridgeOutboundSeq;
      selectedIndex = index;
    }
  });

  return selectedIndex;
}

function selectOldestPinnedTurnDropIndex(entries, pinnedIndices) {
  const turnsByKey = new Map();

  for (const index of pinnedIndices) {
    const entry = entries[index];
    if (!entry.turnPinKey) {
      continue;
    }

    const key = turnPinKeyString(entry.turnPinKey);
    const turnState = turnsByKey.get(key) ?? {
      turnCompletedIndex: -1,
      turnCompletedSeq: Infinity,
      itemCompletedIndex: -1,
      itemCompletedSeq: Infinity,
    };

    if (entry.method === "turn/completed") {
      turnState.turnCompletedIndex = index;
      turnState.turnCompletedSeq = entry.bridgeOutboundSeq;
    }
    if (entry.method === "item/completed") {
      turnState.itemCompletedIndex = index;
      turnState.itemCompletedSeq = entry.bridgeOutboundSeq;
    }

    turnsByKey.set(key, turnState);
  }

  let oldestTurn = null;
  for (const turnState of turnsByKey.values()) {
    const turnAge = turnState.turnCompletedSeq !== Infinity
      ? turnState.turnCompletedSeq
      : turnState.itemCompletedSeq;
    if (
      oldestTurn === null
      || turnAge < oldestTurn.turnAge
      || (
        turnAge === oldestTurn.turnAge
        && turnState.itemCompletedSeq < oldestTurn.itemCompletedSeq
      )
    ) {
      oldestTurn = { ...turnState, turnAge };
    }
  }

  if (!oldestTurn) {
    return -1;
  }

  if (oldestTurn.turnCompletedIndex >= 0) {
    return oldestTurn.turnCompletedIndex;
  }

  return oldestTurn.itemCompletedIndex;
}

function base64ToBuffer(value) {
  try {
    return Buffer.from(value, "base64");
  } catch {
    return null;
  }
}

function base64UrlToBase64(value) {
  const padded = `${value}${"=".repeat((4 - (value.length % 4 || 4)) % 4)}`;
  return padded.replace(/-/g, "+").replace(/_/g, "/");
}

function base64ToBase64Url(value) {
  return value.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

module.exports = {
  HANDSHAKE_MODE_QR_BOOTSTRAP,
  HANDSHAKE_MODE_TRUSTED_RECONNECT,
  MAX_BRIDGE_OUTBOUND_BYTES,
  MAX_BRIDGE_OUTBOUND_MESSAGES,
  OUTBOUND_PRIORITY,
  PAIRING_QR_VERSION,
  SECURE_PROTOCOL_VERSION,
  classifyOutboundPriority,
  computePermissionProtectedIndices,
  computeProtectedEntryIndices,
  computeRecentTurnProtectedIndices,
  computeSystemProtectedIndices,
  createBridgeSecureTransport,
  extractTurnContextKey,
  extractTurnPinKey,
  nonceForDirection,
  readNotifyEvictionMaxAgeMs,
  selectAgeBasedNotifyDropIndex,
  selectOldestRpcDropIndex,
  selectOldestStreamDropIndex,
};
