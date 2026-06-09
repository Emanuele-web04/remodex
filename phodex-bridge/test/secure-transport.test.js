// FILE: secure-transport.test.js
// Purpose: Verifies the bridge-side E2EE handshake rejects plaintext and round-trips encrypted payloads.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, crypto, ../src/secure-transport

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  createCipheriv,
  createDecipheriv,
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  sign,
} = require("crypto");
const {
  HANDSHAKE_MODE_QR_BOOTSTRAP,
  HANDSHAKE_MODE_TRUSTED_RECONNECT,
  MAX_BRIDGE_OUTBOUND_BYTES,
  MAX_BRIDGE_OUTBOUND_MESSAGES,
  OUTBOUND_PRIORITY,
  classifyOutboundPriority,
  computePermissionProtectedIndices,
  createBridgeSecureTransport,
  extractTurnPinKey,
  nonceForDirection,
} = require("../src/secure-transport");

// Keeps unit handshakes from mutating the real Mac pairing trust store.
function createTestBridgeSecureTransport(options) {
  return createBridgeSecureTransport({
    ...options,
    persistTrustedPhone: false,
  });
}

test("secure transport rejects plaintext JSON-RPC before the secure handshake", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const privateJwk = privateKey.export({ format: "jwk" });
  const publicJwk = publicKey.export({ format: "jwk" });
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-1",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-1",
      macIdentityPrivateKey: base64UrlToBase64(privateJwk.d),
      macIdentityPublicKey: base64UrlToBase64(publicJwk.x),
      trustedPhones: {},
    },
  });

  const controlMessages = [];
  const handled = secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      id: "1",
      method: "initialize",
      params: {},
    }),
    {
      sendControlMessage(message) {
        controlMessages.push(message);
      },
      onApplicationMessage() {
        throw new Error("plaintext application payload should not be forwarded");
      },
    }
  );

  assert.equal(handled, true);
  assert.equal(controlMessages[0]?.kind, "secureError");
  assert.equal(controlMessages[0]?.code, "update_required");
});

test("secure transport round-trips encrypted payloads after a trusted reconnect handshake", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-2",
    relayUrl: "wss://relay.example/relay",
    displayName: "Desk Mac",
    deviceState: {
      macDeviceId: "mac-2",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-2": phoneIdentity.publicKey,
      },
    },
  });

  const controlMessages = [];
  const applicationMessages = [];
  const wireMessages = [];
  secureTransport.bindLiveSendWireMessage((message) => {
    wireMessages.push(message);
  });

  const clientNonce = Buffer.alloc(32, 7);
  secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      kind: "clientHello",
      protocolVersion: 1,
      sessionId: "session-2",
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      phoneDeviceId: "phone-2",
      phoneIdentityPublicKey: phoneIdentity.publicKey,
      phoneEphemeralPublicKey: phoneEphemeral.publicKey,
      clientNonce: clientNonce.toString("base64"),
    }),
    {
      sendControlMessage(message) {
        controlMessages.push(message);
      },
      onApplicationMessage(message) {
        applicationMessages.push(message);
      },
    }
  );

  const serverHello = controlMessages.find((message) => message.kind === "serverHello");
  assert.ok(serverHello, "expected serverHello");
  assert.equal(serverHello.displayName, "Desk Mac");

  const transcriptBytes = buildTranscriptBytes({
    sessionId: "session-2",
    protocolVersion: 1,
    handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
    keyEpoch: serverHello.keyEpoch,
    macDeviceId: "mac-2",
    phoneDeviceId: "phone-2",
    macIdentityPublicKey: macIdentity.publicKey,
    phoneIdentityPublicKey: phoneIdentity.publicKey,
    macEphemeralPublicKey: serverHello.macEphemeralPublicKey,
    phoneEphemeralPublicKey: phoneEphemeral.publicKey,
    clientNonce,
    serverNonce: Buffer.from(serverHello.serverNonce, "base64"),
    expiresAtForTranscript: 0,
  });
  const phoneAuthTranscript = Buffer.concat([
    transcriptBytes,
    encodeLengthPrefixedUTF8("client-auth"),
  ]);
  const phoneSignature = sign(
    null,
    phoneAuthTranscript,
    createPrivateKey({
      key: {
        crv: "Ed25519",
        d: base64ToBase64Url(phoneIdentity.privateKey),
        kty: "OKP",
        x: base64ToBase64Url(phoneIdentity.publicKey),
      },
      format: "jwk",
    })
  );

  secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      kind: "clientAuth",
      sessionId: "session-2",
      phoneDeviceId: "phone-2",
      keyEpoch: serverHello.keyEpoch,
      phoneSignature: phoneSignature.toString("base64"),
    }),
    {
      sendControlMessage(message) {
        controlMessages.push(message);
      },
      onApplicationMessage(message) {
        applicationMessages.push(message);
      },
    }
  );

  const secureReady = controlMessages.find((message) => message.kind === "secureReady");
  assert.ok(secureReady, "expected secureReady");

  const sharedSecret = diffieHellman({
    privateKey: createPrivateKey({
      key: {
        crv: "X25519",
        d: base64ToBase64Url(phoneEphemeral.privateKey),
        kty: "OKP",
        x: base64ToBase64Url(phoneEphemeral.publicKey),
      },
      format: "jwk",
    }),
    publicKey: createPublicKey({
      key: {
        crv: "X25519",
        kty: "OKP",
        x: base64ToBase64Url(serverHello.macEphemeralPublicKey),
      },
      format: "jwk",
    }),
  });
  const salt = createHash("sha256").update(transcriptBytes).digest();
  const infoPrefix = `remodex-e2ee-v1|session-2|mac-2|phone-2|${serverHello.keyEpoch}`;
  const phoneToMacKey = Buffer.from(
    hkdfSync("sha256", sharedSecret, salt, Buffer.from(`${infoPrefix}|phoneToMac`, "utf8"), 32)
  );
  const macToPhoneKey = Buffer.from(
    hkdfSync("sha256", sharedSecret, salt, Buffer.from(`${infoPrefix}|macToPhone`, "utf8"), 32)
  );

  secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      kind: "resumeState",
      sessionId: "session-2",
      keyEpoch: serverHello.keyEpoch,
      lastAppliedBridgeOutboundSeq: 0,
    }),
    {
      sendControlMessage(message) {
        controlMessages.push(message);
      },
      onApplicationMessage(message) {
        applicationMessages.push(message);
      },
    }
  );

  secureTransport.queueOutboundApplicationMessage(
    JSON.stringify({ id: "response-1", result: { ok: true } }),
    (message) => {
      wireMessages.push(message);
    }
  );
  assert.equal(wireMessages.length, 1);

  const outboundEnvelope = JSON.parse(wireMessages[0]);
  const outboundPayload = decryptEnvelope(outboundEnvelope, macToPhoneKey);
  assert.equal(outboundPayload.bridgeOutboundSeq, 1);
  assert.equal(outboundPayload.payloadText, JSON.stringify({ id: "response-1", result: { ok: true } }));

  const inboundEnvelope = encryptEnvelope(
    {
      payloadText: JSON.stringify({ id: "request-1", method: "thread/list", params: {} }),
    },
    phoneToMacKey,
    "iphone",
    0,
    "session-2",
    serverHello.keyEpoch
  );
  secureTransport.handleIncomingWireMessage(
    JSON.stringify(inboundEnvelope),
    {
      sendControlMessage(message) {
        controlMessages.push(message);
      },
      onApplicationMessage(message) {
        applicationMessages.push(message);
      },
    }
  );

  assert.deepEqual(applicationMessages, [
    JSON.stringify({ id: "request-1", method: "thread/list", params: {} }),
  ]);
});

test("qr bootstrap allows a fresh QR scan to replace the trusted iPhone", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const firstPhoneIdentity = createOkpKeyPair("ed25519");
  const firstPhoneEphemeral = createOkpKeyPair("x25519");
  const secondPhoneIdentity = createOkpKeyPair("ed25519");
  const secondPhoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-3",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-3",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {},
    },
  });

  finishHandshake({
    secureTransport,
    sessionId: "session-3",
    macDeviceId: "mac-3",
    phoneDeviceId: "phone-3a",
    macIdentity,
    phoneIdentity: firstPhoneIdentity,
    phoneEphemeral: firstPhoneEphemeral,
    handshakeMode: HANDSHAKE_MODE_QR_BOOTSTRAP,
    lastAppliedBridgeOutboundSeq: 0,
  });

  finishHandshake({
    secureTransport,
    sessionId: "session-3",
    macDeviceId: "mac-3",
    phoneDeviceId: "phone-3b",
    macIdentity,
    phoneIdentity: secondPhoneIdentity,
    phoneEphemeral: secondPhoneEphemeral,
    handshakeMode: HANDSHAKE_MODE_QR_BOOTSTRAP,
    lastAppliedBridgeOutboundSeq: 0,
  });
});

test("qr bootstrap starts a fresh replay window instead of leaking buffered messages", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const firstEphemeral = createOkpKeyPair("x25519");
  const secondEphemeral = createOkpKeyPair("x25519");
  const wireMessages = [];
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-4",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-4",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {},
    },
  });
  secureTransport.bindLiveSendWireMessage((message) => {
    wireMessages.push(message);
  });

  finishHandshake({
    secureTransport,
    sessionId: "session-4",
    macDeviceId: "mac-4",
    phoneDeviceId: "phone-4",
    macIdentity,
    phoneIdentity,
    phoneEphemeral: firstEphemeral,
    handshakeMode: HANDSHAKE_MODE_QR_BOOTSTRAP,
    lastAppliedBridgeOutboundSeq: 0,
  });

  secureTransport.queueOutboundApplicationMessage(
    JSON.stringify({ id: "stale-response", result: { ok: true } }),
    (message) => {
      wireMessages.push(message);
    }
  );
  assert.equal(wireMessages.length, 1);

  finishHandshake({
    secureTransport,
    sessionId: "session-4",
    macDeviceId: "mac-4",
    phoneDeviceId: "phone-4",
    macIdentity,
    phoneIdentity,
    phoneEphemeral: secondEphemeral,
    handshakeMode: HANDSHAKE_MODE_QR_BOOTSTRAP,
    lastAppliedBridgeOutboundSeq: 0,
  });

  assert.equal(wireMessages.length, 1);
});

test("rebinding the relay socket replays bridge output from the last phone ack", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-5",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-5",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {},
    },
  });

  const { serverHello, transcriptBytes } = finishHandshake({
    secureTransport,
    sessionId: "session-5",
    macDeviceId: "mac-5",
    phoneDeviceId: "phone-5",
    macIdentity,
    phoneIdentity,
    phoneEphemeral,
    handshakeMode: HANDSHAKE_MODE_QR_BOOTSTRAP,
    lastAppliedBridgeOutboundSeq: 0,
  });

  const sharedSecret = diffieHellman({
    privateKey: createPrivateKey({
      key: {
        crv: "X25519",
        d: base64ToBase64Url(phoneEphemeral.privateKey),
        kty: "OKP",
        x: base64ToBase64Url(phoneEphemeral.publicKey),
      },
      format: "jwk",
    }),
    publicKey: createPublicKey({
      key: {
        crv: "X25519",
        kty: "OKP",
        x: base64ToBase64Url(serverHello.macEphemeralPublicKey),
      },
      format: "jwk",
    }),
  });
  const salt = createHash("sha256").update(transcriptBytes).digest();
  const infoPrefix = `remodex-e2ee-v1|session-5|mac-5|phone-5|${serverHello.keyEpoch}`;
  const macToPhoneKey = Buffer.from(
    hkdfSync("sha256", sharedSecret, salt, Buffer.from(`${infoPrefix}|macToPhone`, "utf8"), 32)
  );

  secureTransport.bindLiveSendWireMessage(() => false);
  secureTransport.queueOutboundApplicationMessage(
    JSON.stringify({ id: "response-5", result: { ok: true } }),
    () => false
  );

  const firstRecoveryWireMessages = [];
  secureTransport.bindLiveSendWireMessage((message) => {
    firstRecoveryWireMessages.push(message);
    return true;
  });

  assert.equal(firstRecoveryWireMessages.length, 1);
  const outboundEnvelope = JSON.parse(firstRecoveryWireMessages[0]);
  const outboundPayload = decryptEnvelope(outboundEnvelope, macToPhoneKey);
  assert.equal(outboundPayload.bridgeOutboundSeq, 1);
  assert.equal(outboundPayload.payloadText, JSON.stringify({ id: "response-5", result: { ok: true } }));

  const liveWireMessages = [];
  secureTransport.queueOutboundApplicationMessage(
    JSON.stringify({ id: "response-6", result: { ok: true } }),
    () => {
      throw new Error("expected active relay sender to handle resumed output");
    }
  );

  secureTransport.bindLiveSendWireMessage((message) => {
    liveWireMessages.push(message);
    return true;
  });

  assert.equal(liveWireMessages.length, 2);
  const replayedPayloads = liveWireMessages.map((message) => {
    const envelope = JSON.parse(message);
    return decryptEnvelope(envelope, macToPhoneKey);
  });
  assert.deepEqual(
    replayedPayloads.map((payload) => payload.bridgeOutboundSeq),
    [1, 2]
  );
});

test("resume replay does not advance the replay watermark before a phone ack", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-6",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-6",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {},
    },
  });

  const initialReplayWireMessages = [];
  secureTransport.bindLiveSendWireMessage((message) => {
    initialReplayWireMessages.push(message);
    return true;
  });

  const { serverHello, transcriptBytes } = finishHandshake({
    secureTransport,
    sessionId: "session-6",
    macDeviceId: "mac-6",
    phoneDeviceId: "phone-6",
    macIdentity,
    phoneIdentity,
    phoneEphemeral,
    handshakeMode: HANDSHAKE_MODE_QR_BOOTSTRAP,
    lastAppliedBridgeOutboundSeq: 0,
    skipResumeState: true,
  });

  secureTransport.queueOutboundApplicationMessage(
    JSON.stringify({ id: "response-6", result: { ok: true } }),
    () => {
      throw new Error("expected bound sender to stay attached after secureReady");
    }
  );

  secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      kind: "resumeState",
      sessionId: "session-6",
      keyEpoch: serverHello.keyEpoch,
      lastAppliedBridgeOutboundSeq: 0,
    }),
    {
      sendControlMessage() {},
      onApplicationMessage() {},
    }
  );

  const sharedSecret = diffieHellman({
    privateKey: createPrivateKey({
      key: {
        crv: "X25519",
        d: base64ToBase64Url(phoneEphemeral.privateKey),
        kty: "OKP",
        x: base64ToBase64Url(phoneEphemeral.publicKey),
      },
      format: "jwk",
    }),
    publicKey: createPublicKey({
      key: {
        crv: "X25519",
        kty: "OKP",
        x: base64ToBase64Url(serverHello.macEphemeralPublicKey),
      },
      format: "jwk",
    }),
  });
  const salt = createHash("sha256").update(transcriptBytes).digest();
  const infoPrefix = `remodex-e2ee-v1|session-6|mac-6|phone-6|${serverHello.keyEpoch}`;
  const macToPhoneKey = Buffer.from(
    hkdfSync("sha256", sharedSecret, salt, Buffer.from(`${infoPrefix}|macToPhone`, "utf8"), 32)
  );

  assert.equal(initialReplayWireMessages.length, 1);

  const reboundWireMessages = [];
  secureTransport.bindLiveSendWireMessage((message) => {
    reboundWireMessages.push(message);
    return true;
  });

  assert.equal(reboundWireMessages.length, 1);
  const reboundEnvelope = JSON.parse(reboundWireMessages[0]);
  const reboundPayload = decryptEnvelope(reboundEnvelope, macToPhoneKey);
  assert.equal(reboundPayload.bridgeOutboundSeq, 1);
  assert.equal(reboundPayload.payloadText, JSON.stringify({ id: "response-6", result: { ok: true } }));
});

test("resume replay keeps current handshake output when the phone cursor is stale", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-7",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-7",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-7": phoneIdentity.publicKey,
      },
    },
  });

  const replayWireMessages = [];
  secureTransport.bindLiveSendWireMessage((message) => {
    replayWireMessages.push(message);
    return true;
  });

  const { serverHello, transcriptBytes } = finishHandshake({
    secureTransport,
    sessionId: "session-7",
    macDeviceId: "mac-7",
    phoneDeviceId: "phone-7",
    macIdentity,
    phoneIdentity,
    phoneEphemeral,
    handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
    lastAppliedBridgeOutboundSeq: 0,
    skipResumeState: true,
  });

  secureTransport.queueOutboundApplicationMessage(
    JSON.stringify({ id: "initialize", result: { ok: true } }),
    () => {
      throw new Error("expected buffered initialize response to wait for resumeState");
    }
  );

  secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      kind: "resumeState",
      sessionId: "session-7",
      keyEpoch: serverHello.keyEpoch,
      lastAppliedBridgeOutboundSeq: 999,
    }),
    {
      sendControlMessage() {},
      onApplicationMessage() {},
    }
  );

  const macToPhoneKey = deriveMacToPhoneKey({
    sessionId: "session-7",
    macDeviceId: "mac-7",
    phoneDeviceId: "phone-7",
    phoneEphemeral,
    serverHello,
    transcriptBytes,
  });
  assert.equal(replayWireMessages.length, 1);
  const outboundEnvelope = JSON.parse(replayWireMessages[0]);
  const outboundPayload = decryptEnvelope(outboundEnvelope, macToPhoneKey);
  assert.equal(outboundPayload.bridgeOutboundSeq, 1);
  assert.equal(outboundPayload.payloadText, JSON.stringify({ id: "initialize", result: { ok: true } }));
});

test("queueOutboundApplicationMessage logs bridge_outbound_buffered before resumeState", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-buffer-log",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-buffer-log",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-buffer-log": phoneIdentity.publicKey,
      },
    },
  });

  const structuredLogs = captureStructuredLogs();
  try {
    finishHandshake({
      secureTransport,
      sessionId: "session-buffer-log",
      macDeviceId: "mac-buffer-log",
      phoneDeviceId: "phone-buffer-log",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ method: "turn/started", params: { threadId: "thread-1" } }),
      () => {
        throw new Error("expected outbound turn/started to buffer before resumeState");
      }
    );

    const bufferedLogs = structuredLogs.filter((entry) => entry.event === "bridge_outbound_buffered");
    assert.equal(bufferedLogs.length, 1);
    assert.equal(bufferedLogs[0].bridgeOutboundSeq, 1);
    assert.ok(bufferedLogs[0].payloadBytes > 0);
  } finally {
    structuredLogs.restore();
  }
});

test("trimOutboundBuffer retains turn/completed under buffer caps", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-trim-keep",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-trim-keep",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-trim-keep": phoneIdentity.publicKey,
      },
    },
  });

  const structuredLogs = captureStructuredLogs();
  const replayWireMessages = [];
  try {
    const { serverHello } = finishHandshake({
      secureTransport,
      sessionId: "session-trim-keep",
      macDeviceId: "mac-trim-keep",
      phoneDeviceId: "phone-trim-keep",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    const turnCompletedPayload = JSON.stringify({
      method: "turn/completed",
      params: { threadId: "thread-1", turnId: "turn-1", status: "completed" },
    });
    secureTransport.queueOutboundApplicationMessage(turnCompletedPayload, () => false);

    assert.equal(structuredLogs.filter((entry) => entry.event === "bridge_outbound_dropped").length, 0);

    secureTransport.bindLiveSendWireMessage((message) => {
      replayWireMessages.push(message);
      return true;
    });
    secureTransport.handleIncomingWireMessage(
      JSON.stringify({
        kind: "resumeState",
        sessionId: "session-trim-keep",
        keyEpoch: serverHello.keyEpoch,
        lastAppliedBridgeOutboundSeq: 999,
      }),
      {
        sendControlMessage() {},
        onApplicationMessage() {},
      }
    );

    assert.equal(replayWireMessages.length, 1);
    assert.equal(
      structuredLogs.filter((entry) => entry.event === "bridge_outbound_trim_dropped").length,
      0
    );
  } finally {
    structuredLogs.restore();
  }
});

test("trimOutboundBuffer emits bridge_outbound_dropped when caps are exceeded (buffer overflow)", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-trim-drop",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-trim-drop",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-trim-drop": phoneIdentity.publicKey,
      },
    },
  });

  const structuredLogs = captureStructuredLogs();
  try {
    const { serverHello, transcriptBytes } = finishHandshake({
      secureTransport,
      sessionId: "session-trim-drop",
      macDeviceId: "mac-trim-drop",
      phoneDeviceId: "phone-trim-drop",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    const fillerPayload = JSON.stringify({ method: "thread/updated", params: { threadId: "thread-filler" } });
    for (let index = 0; index < MAX_BRIDGE_OUTBOUND_MESSAGES; index += 1) {
      secureTransport.queueOutboundApplicationMessage(fillerPayload, () => false);
    }

    const turnCompletedPayload = JSON.stringify({
      method: "turn/completed",
      params: { threadId: "thread-1", turnId: "turn-1", status: "completed" },
    });
    secureTransport.queueOutboundApplicationMessage(turnCompletedPayload, () => false);

    const trimLogs = structuredLogs.filter((entry) => entry.event === "bridge_outbound_dropped");
    assert.equal(trimLogs.length, 1);
    assert.equal(trimLogs[0].droppedCount, 1);
    assert.ok(trimLogs[0].droppedBytes > 0);
    assert.equal(trimLogs[0].firstSeq, 1);
    assert.equal(trimLogs[0].lastSeq, 1);
    assert.equal(trimLogs[0].reason, "overflow");
    assert.equal(trimLogs[0].method, "thread/updated");
    assert.equal(trimLogs[0].priority, OUTBOUND_PRIORITY.NOTIFY);

    const replayWireMessages = [];
    secureTransport.bindLiveSendWireMessage((message) => {
      replayWireMessages.push(message);
      return true;
    });
    secureTransport.handleIncomingWireMessage(
      JSON.stringify({
        kind: "resumeState",
        sessionId: "session-trim-drop",
        keyEpoch: serverHello.keyEpoch,
        lastAppliedBridgeOutboundSeq: 0,
      }),
      {
        sendControlMessage() {},
        onApplicationMessage() {},
      }
    );

    assert.equal(replayWireMessages.length, MAX_BRIDGE_OUTBOUND_MESSAGES);
    const replayedPayloads = replayWireMessages.map((message) => {
      const envelope = JSON.parse(message);
      const macToPhoneKey = deriveMacToPhoneKey({
        sessionId: "session-trim-drop",
        macDeviceId: "mac-trim-drop",
        phoneDeviceId: "phone-trim-drop",
        phoneEphemeral,
        serverHello,
        transcriptBytes,
      });
      return JSON.parse(decryptEnvelope(envelope, macToPhoneKey).payloadText);
    });
    assert.ok(
      replayedPayloads.some(
        (payload) => payload.method === "turn/completed" && payload.params?.turnId === "turn-1"
      ),
      "expected turn/completed to survive overflow trim while oldest notify filler was dropped"
    );
  } finally {
    structuredLogs.restore();
  }
});

test("classifyOutboundPriority maps lifecycle, stream, notify, and rpc tiers", () => {
  assert.equal(
    classifyOutboundPriority({ method: "turn/started", params: {} }),
    OUTBOUND_PRIORITY.LIFECYCLE
  );
  assert.equal(
    classifyOutboundPriority({ method: "turn/completed", params: {} }),
    OUTBOUND_PRIORITY.LIFECYCLE
  );
  assert.equal(
    classifyOutboundPriority({ method: "turn/failed", params: {} }),
    OUTBOUND_PRIORITY.LIFECYCLE
  );
  assert.equal(
    classifyOutboundPriority({ method: "item/agentMessage/delta", params: {} }),
    OUTBOUND_PRIORITY.STREAM
  );
  assert.equal(
    classifyOutboundPriority({ method: "item/completed", params: {} }),
    OUTBOUND_PRIORITY.STREAM
  );
  assert.equal(
    classifyOutboundPriority({ method: "thread/status", params: {} }),
    OUTBOUND_PRIORITY.LIFECYCLE
  );
  assert.equal(
    classifyOutboundPriority({ method: "item/toolCallUpdate", params: {} }),
    OUTBOUND_PRIORITY.TOOL
  );
  assert.equal(
    classifyOutboundPriority({ id: "rpc-1", result: { ok: true } }),
    OUTBOUND_PRIORITY.RPC_RESPONSE
  );
  assert.equal(
    classifyOutboundPriority({
      method: "permission/request",
      params: { permissionId: "perm-1", threadId: "thread-1" },
    }),
    OUTBOUND_PRIORITY.NOTIFY
  );
});

test("computePermissionProtectedIndices protects permission/request from trim", () => {
  const entries = [
    { method: "thread/updated", bridgeOutboundSeq: 1 },
    {
      method: "permission/request",
      bridgeOutboundSeq: 2,
      params: { permissionId: "perm-1", threadId: "thread-1" },
    },
    { method: "thread/updated", bridgeOutboundSeq: 3 },
  ];
  const protectedIndices = computePermissionProtectedIndices(entries);
  assert.deepEqual([...protectedIndices], [1]);
});

test("priority trim keeps permission/request while dropping oldest notify filler", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-permission-protected",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-permission-protected",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-permission-protected": phoneIdentity.publicKey,
      },
    },
  });

  const structuredLogs = captureStructuredLogs();
  try {
    const { serverHello, transcriptBytes } = finishHandshake({
      secureTransport,
      sessionId: "session-permission-protected",
      macDeviceId: "mac-permission-protected",
      phoneDeviceId: "phone-permission-protected",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    const fillerPayload = JSON.stringify({ method: "thread/updated", params: { threadId: "thread-filler" } });
    for (let index = 0; index < MAX_BRIDGE_OUTBOUND_MESSAGES; index += 1) {
      secureTransport.queueOutboundApplicationMessage(fillerPayload, () => false);
    }

    const permissionPayload = JSON.stringify({
      method: "permission/request",
      params: {
        permissionId: "perm-protected",
        threadId: "thread-1",
        turnId: "turn-1",
        tool: "bash",
      },
    });
    secureTransport.queueOutboundApplicationMessage(permissionPayload, () => false);

    const trimLogs = structuredLogs.filter((entry) => entry.event === "bridge_outbound_dropped");
    assert.equal(trimLogs.length, 1);
    assert.equal(trimLogs[0].method, "thread/updated");
    assert.equal(trimLogs[0].priority, OUTBOUND_PRIORITY.NOTIFY);

    const replayedPayloads = replayBufferedPayloads({
      secureTransport,
      serverHello,
      transcriptBytes,
      phoneEphemeral,
      sessionId: "session-permission-protected",
      macDeviceId: "mac-permission-protected",
      phoneDeviceId: "phone-permission-protected",
    });
    assert.ok(
      replayedPayloads.some((payload) => {
        const parsed = JSON.parse(payload.payloadText);
        return parsed.method === "permission/request"
          && parsed.params?.permissionId === "perm-protected";
      }),
      "expected permission/request to survive overflow trim"
    );
  } finally {
    structuredLogs.restore();
  }
});

test("extractTurnPinKey parses flat and nested thread/turn ids", () => {
  assert.deepEqual(
    extractTurnPinKey({
      method: "turn/completed",
      params: { threadId: "thread-flat", turnId: "turn-flat" },
    }),
    { threadId: "thread-flat", turnId: "turn-flat" }
  );
  assert.deepEqual(
    extractTurnPinKey({
      method: "item/completed",
      params: {
        item: {
          threadId: "thread-nested",
          turnId: "turn-nested",
        },
      },
    }),
    { threadId: "thread-nested", turnId: "turn-nested" }
  );
  assert.deepEqual(
    extractTurnPinKey({
      method: "turn/completed",
      params: {
        item: {
          thread: { id: "thread-deep" },
          turn: { id: "turn-deep" },
        },
      },
    }),
    { threadId: "thread-deep", turnId: "turn-deep" }
  );
  assert.equal(extractTurnPinKey({ method: "thread/list", params: {} }), null);
  assert.equal(
    extractTurnPinKey({ method: "item/completed", params: { message: "no ids" } }),
    null
  );
  assert.equal(
    extractTurnPinKey({ method: "turn/failed", params: { threadId: "thread-1", turnId: "turn-1" } }),
    null
  );
});

test("priority trim drops rpc responses before lifecycle and stream under cap pressure", () => {
  const previousCap = process.env.REMODEX_BRIDGE_OUTBOUND_CAP;
  const previousPriority = process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND;
  const previousLegacy = process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM;
  process.env.REMODEX_BRIDGE_OUTBOUND_CAP = "4";
  process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND = "1";
  process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM = "0";

  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-priority-rpc",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-priority-rpc",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-priority-rpc": phoneIdentity.publicKey,
      },
    },
  });

  const structuredLogs = captureStructuredLogs();
  try {
    const { serverHello, transcriptBytes } = finishHandshake({
      secureTransport,
      sessionId: "session-priority-rpc",
      macDeviceId: "mac-priority-rpc",
      phoneDeviceId: "phone-priority-rpc",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ id: "rpc-1", result: { ok: true } }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ id: "rpc-2", result: { ok: true } }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ method: "turn/started", params: { threadId: "thread-1", turnId: "turn-1" } }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "item/agentMessage/delta",
        params: { threadId: "thread-1", turnId: "turn-1", delta: "hello" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "turn/completed",
        params: { threadId: "thread-1", turnId: "turn-1", status: "completed" },
      }),
      () => false
    );

    const trimLogs = structuredLogs.filter((entry) => entry.event === "bridge_outbound_dropped");
    assert.equal(trimLogs.length, 1);
    assert.equal(trimLogs[0].highestPriorityTierDropped, OUTBOUND_PRIORITY.RPC_RESPONSE);
    assert.equal(trimLogs[0].priority, OUTBOUND_PRIORITY.RPC_RESPONSE);

    const replayedPayloads = replayBufferedPayloads({
      secureTransport,
      serverHello,
      transcriptBytes,
      phoneEphemeral,
      sessionId: "session-priority-rpc",
      macDeviceId: "mac-priority-rpc",
      phoneDeviceId: "phone-priority-rpc",
    });
    assert.deepEqual(
      replayedPayloads.map((payload) => JSON.parse(payload.payloadText)),
      [
        { id: "rpc-2", result: { ok: true } },
        { method: "turn/started", params: { threadId: "thread-1", turnId: "turn-1" } },
        {
          method: "item/agentMessage/delta",
          params: { threadId: "thread-1", turnId: "turn-1", delta: "hello" },
        },
        {
          method: "turn/completed",
          params: { threadId: "thread-1", turnId: "turn-1", status: "completed" },
        },
      ]
    );
  } finally {
    structuredLogs.restore();
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_CAP", previousCap);
    restoreEnvValue("REMODEX_BRIDGE_PRIORITY_OUTBOUND", previousPriority);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM", previousLegacy);
  }
});

test("priority trim retains pinned item/completed and turn/completed pair per turn", () => {
  const previousCap = process.env.REMODEX_BRIDGE_OUTBOUND_CAP;
  const previousPriority = process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND;
  const previousLegacy = process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM;
  process.env.REMODEX_BRIDGE_OUTBOUND_CAP = "4";
  process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND = "1";
  process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM = "0";

  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-priority-pin",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-priority-pin",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-priority-pin": phoneIdentity.publicKey,
      },
    },
  });

  try {
    const { serverHello, transcriptBytes } = finishHandshake({
      secureTransport,
      sessionId: "session-priority-pin",
      macDeviceId: "mac-priority-pin",
      phoneDeviceId: "phone-priority-pin",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ method: "thread/status", params: { status: "running" } }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "item/completed",
        params: {
          threadId: "thread-pin",
          turnId: "turn-pin",
          message: "final answer",
        },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "turn/completed",
        params: { threadId: "thread-pin", turnId: "turn-pin", status: "completed" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ id: "rpc-pin", result: { ok: true } }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ method: "thread/status", params: { status: "idle" } }),
      () => false
    );

    const replayedPayloads = replayBufferedPayloads({
      secureTransport,
      serverHello,
      transcriptBytes,
      phoneEphemeral,
      sessionId: "session-priority-pin",
      macDeviceId: "mac-priority-pin",
      phoneDeviceId: "phone-priority-pin",
    });
    const replayedObjects = replayedPayloads.map((payload) => JSON.parse(payload.payloadText));
    assert.ok(
      replayedObjects.some((payload) => payload.method === "item/completed"),
      "expected pinned item/completed to survive cap pressure"
    );
    assert.ok(
      replayedObjects.some((payload) => payload.method === "turn/completed"),
      "expected pinned turn/completed to survive cap pressure"
    );
    assert.ok(
      !replayedObjects.some((payload) => payload.id === "rpc-pin"),
      "expected rpc response to be dropped before pinned lifecycle pair"
    );
  } finally {
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_CAP", previousCap);
    restoreEnvValue("REMODEX_BRIDGE_PRIORITY_OUTBOUND", previousPriority);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM", previousLegacy);
  }
});

test("priority trim drops old tool outputs before system and recent turn traffic", () => {
  const previousCap = process.env.REMODEX_BRIDGE_OUTBOUND_CAP;
  const previousPriority = process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND;
  const previousLegacy = process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM;
  const previousRecentTurns = process.env.REMODEX_BRIDGE_OUTBOUND_RECENT_TURNS;
  process.env.REMODEX_BRIDGE_OUTBOUND_CAP = "3";
  process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND = "1";
  process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM = "0";
  process.env.REMODEX_BRIDGE_OUTBOUND_RECENT_TURNS = "1";

  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-priority-tool-prune",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-priority-tool-prune",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-priority-tool-prune": phoneIdentity.publicKey,
      },
    },
  });

  try {
    const { serverHello, transcriptBytes } = finishHandshake({
      secureTransport,
      sessionId: "session-priority-tool-prune",
      macDeviceId: "mac-priority-tool-prune",
      phoneDeviceId: "phone-priority-tool-prune",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "item/toolCallUpdate",
        params: { threadId: "thread-a", turnId: "turn-old", status: "completed", output: "old output" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ method: "thread/status/changed", params: { threadId: "thread-a", status: "running" } }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "item/agentMessage/delta",
        params: { threadId: "thread-a", turnId: "turn-new", delta: "streaming now" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "item/toolCallUpdate",
        params: { threadId: "thread-a", turnId: "turn-old", status: "completed", output: "older output" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ method: "thread/tokenUsage/updated", params: { threadId: "thread-a", usage: { tokensUsed: 1, tokenLimit: 10 } } }),
      () => false
    );

    const replayedPayloads = replayBufferedPayloads({
      secureTransport,
      serverHello,
      transcriptBytes,
      phoneEphemeral,
      sessionId: "session-priority-tool-prune",
      macDeviceId: "mac-priority-tool-prune",
      phoneDeviceId: "phone-priority-tool-prune",
    });
    const replayedObjects = replayedPayloads.map((payload) => JSON.parse(payload.payloadText));

    assert.ok(
      replayedObjects.some((payload) => payload.method === "thread/status/changed"),
      "expected system status to survive trim pressure"
    );
    assert.ok(
      replayedObjects.some(
        (payload) => payload.method === "item/agentMessage/delta" && payload.params?.turnId === "turn-new"
      ),
      "expected recent turn stream delta to survive trim pressure"
    );
    assert.ok(
      replayedObjects.some((payload) => payload.method === "thread/tokenUsage/updated"),
      "expected system token usage update to survive trim pressure"
    );
    assert.ok(
      !replayedObjects.some((payload) => payload.method === "item/toolCallUpdate"),
      "expected old tool outputs to be dropped first"
    );
  } finally {
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_CAP", previousCap);
    restoreEnvValue("REMODEX_BRIDGE_PRIORITY_OUTBOUND", previousPriority);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM", previousLegacy);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_RECENT_TURNS", previousRecentTurns);
  }
});

test("priority trim sacrifices older turn completion pair under saturated pin pressure", () => {
  const previousCap = process.env.REMODEX_BRIDGE_OUTBOUND_CAP;
  const previousPriority = process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND;
  const previousLegacy = process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM;
  process.env.REMODEX_BRIDGE_OUTBOUND_CAP = "2";
  process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND = "1";
  process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM = "0";

  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-priority-multi-turn",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-priority-multi-turn",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-priority-multi-turn": phoneIdentity.publicKey,
      },
    },
  });

  try {
    const { serverHello, transcriptBytes } = finishHandshake({
      secureTransport,
      sessionId: "session-priority-multi-turn",
      macDeviceId: "mac-priority-multi-turn",
      phoneDeviceId: "phone-priority-multi-turn",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "item/completed",
        params: { threadId: "thread-multi", turnId: "turn-a", message: "answer-a" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "turn/completed",
        params: { threadId: "thread-multi", turnId: "turn-a", status: "completed" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "item/completed",
        params: { threadId: "thread-multi", turnId: "turn-b", message: "answer-b" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "turn/completed",
        params: { threadId: "thread-multi", turnId: "turn-b", status: "completed" },
      }),
      () => false
    );

    const replayedPayloads = replayBufferedPayloads({
      secureTransport,
      serverHello,
      transcriptBytes,
      phoneEphemeral,
      sessionId: "session-priority-multi-turn",
      macDeviceId: "mac-priority-multi-turn",
      phoneDeviceId: "phone-priority-multi-turn",
    });
    const replayedObjects = replayedPayloads.map((payload) => JSON.parse(payload.payloadText));
    assert.equal(replayedObjects.length, 2);
    assert.ok(
      replayedObjects.some(
        (payload) => payload.method === "item/completed" && payload.params?.turnId === "turn-b"
      ),
      "expected newer turn item/completed to survive saturated pin pressure"
    );
    assert.ok(
      replayedObjects.some(
        (payload) => payload.method === "turn/completed" && payload.params?.turnId === "turn-b"
      ),
      "expected newer turn turn/completed to survive saturated pin pressure"
    );
    assert.ok(
      !replayedObjects.some(
        (payload) => payload.method === "item/completed" && payload.params?.turnId === "turn-a"
      ),
      "expected older turn item/completed to be evicted"
    );
    assert.ok(
      !replayedObjects.some(
        (payload) => payload.method === "turn/completed" && payload.params?.turnId === "turn-a"
      ),
      "expected older turn turn/completed to be evicted"
    );
  } finally {
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_CAP", previousCap);
    restoreEnvValue("REMODEX_BRIDGE_PRIORITY_OUTBOUND", previousPriority);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM", previousLegacy);
  }
});

test("priority trim reserves byte budget for lifecycle and stream under byte pressure", () => {
  const previousCap = process.env.REMODEX_BRIDGE_OUTBOUND_CAP;
  const previousPriority = process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND;
  const previousLegacy = process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM;
  process.env.REMODEX_BRIDGE_OUTBOUND_CAP = "1000";
  process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND = "1";
  process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM = "0";

  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-priority-byte-reserve",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-priority-byte-reserve",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-priority-byte-reserve": phoneIdentity.publicKey,
      },
    },
  });

  const structuredLogs = captureStructuredLogs();
  try {
    const { serverHello, transcriptBytes } = finishHandshake({
      secureTransport,
      sessionId: "session-priority-byte-reserve",
      macDeviceId: "mac-priority-byte-reserve",
      phoneDeviceId: "phone-priority-byte-reserve",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    const rpcPaddingBytes = Math.floor(MAX_BRIDGE_OUTBOUND_BYTES * 0.13);
    for (let index = 0; index < 8; index += 1) {
      secureTransport.queueOutboundApplicationMessage(
        JSON.stringify({ id: `rpc-byte-${index}`, result: { padding: "x".repeat(rpcPaddingBytes) } }),
        () => false
      );
    }
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "item/agentMessage/delta",
        params: { threadId: "thread-byte", turnId: "turn-byte", delta: "stream" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "turn/completed",
        params: { threadId: "thread-byte", turnId: "turn-byte", status: "completed" },
      }),
      () => false
    );

    const trimLogs = structuredLogs.filter((entry) => entry.event === "bridge_outbound_dropped");
    assert.ok(trimLogs.length > 0, "expected rpc payloads to be dropped under byte pressure");
    assert.ok(
      trimLogs.every((entry) => entry.highestPriorityTierDropped === OUTBOUND_PRIORITY.RPC_RESPONSE),
      "expected only rpc responses to be dropped while lifecycle/stream byte reserve is active"
    );

    const replayedPayloads = replayBufferedPayloads({
      secureTransport,
      serverHello,
      transcriptBytes,
      phoneEphemeral,
      sessionId: "session-priority-byte-reserve",
      macDeviceId: "mac-priority-byte-reserve",
      phoneDeviceId: "phone-priority-byte-reserve",
    });
    const replayedObjects = replayedPayloads.map((payload) => JSON.parse(payload.payloadText));
    assert.ok(
      replayedObjects.some((payload) => payload.method === "item/agentMessage/delta"),
      "expected stream delta to survive byte reserve trim"
    );
    assert.ok(
      replayedObjects.some((payload) => payload.method === "turn/completed"),
      "expected turn/completed to survive byte reserve trim"
    );
    const replayedRpcCount = replayedObjects.filter((payload) => payload.id?.startsWith("rpc-byte-")).length;
    assert.ok(
      replayedRpcCount < 8,
      "expected some large rpc payloads to be dropped before lifecycle/stream"
    );
  } finally {
    structuredLogs.restore();
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_CAP", previousCap);
    restoreEnvValue("REMODEX_BRIDGE_PRIORITY_OUTBOUND", previousPriority);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM", previousLegacy);
  }
});

test("legacy fifo trim drops oldest entry when rollback env is enabled", () => {
  const previousCap = process.env.REMODEX_BRIDGE_OUTBOUND_CAP;
  const previousPriority = process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND;
  const previousLegacy = process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM;
  process.env.REMODEX_BRIDGE_OUTBOUND_CAP = String(MAX_BRIDGE_OUTBOUND_MESSAGES);
  process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND = "1";
  process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM = "1";

  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-legacy-trim",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-legacy-trim",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-legacy-trim": phoneIdentity.publicKey,
      },
    },
  });

  const structuredLogs = captureStructuredLogs();
  try {
    const { serverHello, transcriptBytes } = finishHandshake({
      secureTransport,
      sessionId: "session-legacy-trim",
      macDeviceId: "mac-legacy-trim",
      phoneDeviceId: "phone-legacy-trim",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    const fillerPayload = JSON.stringify({ method: "thread/status", params: { status: "running" } });
    for (let index = 0; index < MAX_BRIDGE_OUTBOUND_MESSAGES; index += 1) {
      secureTransport.queueOutboundApplicationMessage(fillerPayload, () => false);
    }
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "turn/completed",
        params: { threadId: "thread-legacy", turnId: "turn-legacy", status: "completed" },
      }),
      () => false
    );

    const trimLogs = structuredLogs.filter((entry) => entry.event === "bridge_outbound_dropped");
    assert.equal(trimLogs.length, 1);
    assert.equal(trimLogs[0].firstSeq, 1);
    assert.equal(trimLogs[0].method, "thread/status");

    const replayedPayloads = replayBufferedPayloads({
      secureTransport,
      serverHello,
      transcriptBytes,
      phoneEphemeral,
      sessionId: "session-legacy-trim",
      macDeviceId: "mac-legacy-trim",
      phoneDeviceId: "phone-legacy-trim",
    });
    const replayedObjects = replayedPayloads.map((payload) => JSON.parse(payload.payloadText));
    assert.equal(replayedObjects.length, MAX_BRIDGE_OUTBOUND_MESSAGES);
    assert.ok(
      replayedObjects.some(
        (payload) => payload.method === "turn/completed" && payload.params?.turnId === "turn-legacy"
      ),
      "expected turn/completed to survive legacy fifo trim"
    );
  } finally {
    structuredLogs.restore();
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_CAP", previousCap);
    restoreEnvValue("REMODEX_BRIDGE_PRIORITY_OUTBOUND", previousPriority);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM", previousLegacy);
  }
});

test("priority outbound disabled delegates to legacy fifo trim", () => {
  const previousCap = process.env.REMODEX_BRIDGE_OUTBOUND_CAP;
  const previousPriority = process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND;
  const previousLegacy = process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM;
  process.env.REMODEX_BRIDGE_OUTBOUND_CAP = String(MAX_BRIDGE_OUTBOUND_MESSAGES);
  process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND = "0";
  process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM = "0";

  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-priority-off",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-priority-off",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-priority-off": phoneIdentity.publicKey,
      },
    },
  });

  const structuredLogs = captureStructuredLogs();
  try {
    const { serverHello, transcriptBytes } = finishHandshake({
      secureTransport,
      sessionId: "session-priority-off",
      macDeviceId: "mac-priority-off",
      phoneDeviceId: "phone-priority-off",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    const fillerPayload = JSON.stringify({ method: "thread/status", params: { status: "running" } });
    for (let index = 0; index < MAX_BRIDGE_OUTBOUND_MESSAGES; index += 1) {
      secureTransport.queueOutboundApplicationMessage(fillerPayload, () => false);
    }
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "turn/completed",
        params: { threadId: "thread-off", turnId: "turn-off", status: "completed" },
      }),
      () => false
    );

    const trimLogs = structuredLogs.filter((entry) => entry.event === "bridge_outbound_dropped");
    assert.equal(trimLogs.length, 1);
    assert.equal(trimLogs[0].firstSeq, 1);
    assert.equal(trimLogs[0].method, "thread/status");

    const replayedPayloads = replayBufferedPayloads({
      secureTransport,
      serverHello,
      transcriptBytes,
      phoneEphemeral,
      sessionId: "session-priority-off",
      macDeviceId: "mac-priority-off",
      phoneDeviceId: "phone-priority-off",
    });
    const replayedObjects = replayedPayloads.map((payload) => JSON.parse(payload.payloadText));
    assert.equal(replayedObjects.length, MAX_BRIDGE_OUTBOUND_MESSAGES);
    assert.ok(replayedObjects.some((payload) => payload.method === "turn/completed"));
  } finally {
    structuredLogs.restore();
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_CAP", previousCap);
    restoreEnvValue("REMODEX_BRIDGE_PRIORITY_OUTBOUND", previousPriority);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM", previousLegacy);
  }
});

test("outbound buffer drain on reconnect", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-drain-reconnect",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-drain",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-drain": phoneIdentity.publicKey,
      },
    },
  });

  const replayWireMessages = [];
  try {
    const { serverHello } = finishHandshake({
      secureTransport,
      sessionId: "session-drain-reconnect",
      macDeviceId: "mac-drain",
      phoneDeviceId: "phone-drain",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    // queue while !resumed (simulates messages during disconnect)
    const started = JSON.stringify({ method: "turn/started", params: { threadId: "t-drain", turnId: "turn-drain-1" } });
    secureTransport.queueOutboundApplicationMessage(started, () => {
      throw new Error("should buffer, not send live while !resumed");
    });
    const delta = JSON.stringify({ method: "item/agentMessage/delta", params: { threadId: "t-drain", turnId: "turn-drain-1", delta: "hi" } });
    secureTransport.queueOutboundApplicationMessage(delta, () => false);

    // now reconnect + resumeState triggers drain of buffered
    secureTransport.bindLiveSendWireMessage((message) => {
      replayWireMessages.push(message);
      return true;
    });
    secureTransport.handleIncomingWireMessage(
      JSON.stringify({
        kind: "resumeState",
        sessionId: "session-drain-reconnect",
        keyEpoch: serverHello.keyEpoch,
        lastAppliedBridgeOutboundSeq: 0,
      }),
      {
        sendControlMessage() {},
        onApplicationMessage() {},
      }
    );

    // the 2 queued should have been drained on resume (via replay)
    assert.equal(replayWireMessages.length, 2);
    // also verify entries had queuedAt (via behavior, not direct internal)
  } finally {
    // no structured here
  }
});

test("priority trim uses age-based notify eviction when all entries are protected", () => {
  const previousCap = process.env.REMODEX_BRIDGE_OUTBOUND_CAP;
  const previousPriority = process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND;
  const previousLegacy = process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM;
  const previousRecentTurns = process.env.REMODEX_BRIDGE_OUTBOUND_RECENT_TURNS;
  const previousNotifyAge = process.env.REMODEX_BRIDGE_NOTIFY_EVICTION_MAX_AGE_MS;
  process.env.REMODEX_BRIDGE_OUTBOUND_CAP = "3";
  process.env.REMODEX_BRIDGE_PRIORITY_OUTBOUND = "1";
  process.env.REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM = "0";
  process.env.REMODEX_BRIDGE_OUTBOUND_RECENT_TURNS = "1";
  process.env.REMODEX_BRIDGE_NOTIFY_EVICTION_MAX_AGE_MS = "0";

  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const phoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createTestBridgeSecureTransport({
    sessionId: "session-notify-age-eviction",
    relayUrl: "wss://relay.example/relay",
    deviceState: {
      macDeviceId: "mac-notify-age-eviction",
      macIdentityPrivateKey: macIdentity.privateKey,
      macIdentityPublicKey: macIdentity.publicKey,
      trustedPhones: {
        "phone-notify-age-eviction": phoneIdentity.publicKey,
      },
    },
  });

  const structuredLogs = captureStructuredLogs();
  try {
    finishHandshake({
      secureTransport,
      sessionId: "session-notify-age-eviction",
      macDeviceId: "mac-notify-age-eviction",
      phoneDeviceId: "phone-notify-age-eviction",
      macIdentity,
      phoneIdentity,
      phoneEphemeral,
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: 0,
      skipResumeState: true,
    });

    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "turn/started",
        params: { threadId: "thread-live", turnId: "turn-live" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "item/agentMessage/delta",
        params: { threadId: "thread-live", turnId: "turn-live", delta: "live stream" },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ method: "thread/status/changed", params: { threadId: "thread-live", status: "running" } }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "permission/request",
        params: {
          threadId: "thread-live",
          turnId: "turn-live",
          permissionId: "perm-1",
        },
      }),
      () => false
    );
    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({
        method: "permission/request",
        params: {
          threadId: "thread-live",
          turnId: "turn-live",
          permissionId: "perm-2",
        },
      }),
      () => false
    );

    const trimLogs = structuredLogs.filter((entry) => entry.event === "bridge_outbound_dropped");
    const stallLogs = structuredLogs.filter((entry) => entry.event === "bridge_outbound_drop_stalled");
    assert.ok(trimLogs.length > 0, "expected protected-buffer stall to drop entries");
    assert.equal(trimLogs[0].reason, "notify_age_eviction");
    assert.ok(stallLogs.length > 0, "expected stall metric when notify age eviction runs");
    assert.equal(
      trimLogs[0].highestPriorityTierDropped,
      OUTBOUND_PRIORITY.NOTIFY,
      "expected notify-tier payload to be evicted first"
    );
  } finally {
    structuredLogs.restore();
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_CAP", previousCap);
    restoreEnvValue("REMODEX_BRIDGE_PRIORITY_OUTBOUND", previousPriority);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_LEGACY_TRIM", previousLegacy);
    restoreEnvValue("REMODEX_BRIDGE_OUTBOUND_RECENT_TURNS", previousRecentTurns);
    restoreEnvValue("REMODEX_BRIDGE_NOTIFY_EVICTION_MAX_AGE_MS", previousNotifyAge);
  }
});

function restoreEnvValue(name, previousValue) {
  if (previousValue === undefined) {
    delete process.env[name];
    return;
  }
  process.env[name] = previousValue;
}

function replayBufferedPayloads({
  secureTransport,
  serverHello,
  transcriptBytes,
  phoneEphemeral,
  sessionId,
  macDeviceId,
  phoneDeviceId,
}) {
  const replayWireMessages = [];
  secureTransport.bindLiveSendWireMessage((message) => {
    replayWireMessages.push(message);
    return true;
  });
  secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      kind: "resumeState",
      sessionId,
      keyEpoch: serverHello.keyEpoch,
      lastAppliedBridgeOutboundSeq: 0,
    }),
    {
      sendControlMessage() {},
      onApplicationMessage() {},
    }
  );

  const macToPhoneKey = deriveMacToPhoneKey({
    sessionId,
    macDeviceId,
    phoneDeviceId,
    phoneEphemeral,
    serverHello,
    transcriptBytes,
  });

  return replayWireMessages.map((message) => decryptEnvelope(JSON.parse(message), macToPhoneKey));
}

function captureStructuredLogs() {
  const entries = [];
  const originalLog = console.log;
  console.log = (value) => {
    if (typeof value !== "string") {
      return;
    }
    try {
      const parsed = JSON.parse(value);
      if (parsed && typeof parsed === "object" && typeof parsed.event === "string") {
        entries.push(parsed);
      }
    } catch {
      // Ignore non-JSON console output from secure transport debug logs.
    }
  };
  entries.restore = () => {
    console.log = originalLog;
  };
  return entries;
}

function finishHandshake({
  secureTransport,
  sessionId,
  macDeviceId,
  phoneDeviceId,
  macIdentity,
  phoneIdentity,
  phoneEphemeral,
  handshakeMode,
  lastAppliedBridgeOutboundSeq,
  skipResumeState = false,
}) {
  const controlMessages = [];
  const applicationMessages = [];
  const clientNonce = Buffer.alloc(32, 7);

  secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      kind: "clientHello",
      protocolVersion: 1,
      sessionId,
      handshakeMode,
      phoneDeviceId,
      phoneIdentityPublicKey: phoneIdentity.publicKey,
      phoneEphemeralPublicKey: phoneEphemeral.publicKey,
      clientNonce: clientNonce.toString("base64"),
    }),
    {
      sendControlMessage(message) {
        controlMessages.push(message);
      },
      onApplicationMessage(message) {
        applicationMessages.push(message);
      },
    }
  );

  const serverHello = controlMessages.find((message) => message.kind === "serverHello");
  assert.ok(serverHello, "expected serverHello");

  const transcriptBytes = buildTranscriptBytes({
    sessionId,
    protocolVersion: 1,
    handshakeMode,
    keyEpoch: serverHello.keyEpoch,
    macDeviceId,
    phoneDeviceId,
    macIdentityPublicKey: macIdentity.publicKey,
    phoneIdentityPublicKey: phoneIdentity.publicKey,
    macEphemeralPublicKey: serverHello.macEphemeralPublicKey,
    phoneEphemeralPublicKey: phoneEphemeral.publicKey,
    clientNonce,
    serverNonce: Buffer.from(serverHello.serverNonce, "base64"),
    expiresAtForTranscript: serverHello.expiresAtForTranscript,
  });
  const phoneAuthTranscript = Buffer.concat([
    transcriptBytes,
    encodeLengthPrefixedUTF8("client-auth"),
  ]);
  const phoneSignature = sign(
    null,
    phoneAuthTranscript,
    createPrivateKey({
      key: {
        crv: "Ed25519",
        d: base64ToBase64Url(phoneIdentity.privateKey),
        kty: "OKP",
        x: base64ToBase64Url(phoneIdentity.publicKey),
      },
      format: "jwk",
    })
  );

  secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      kind: "clientAuth",
      sessionId,
      phoneDeviceId,
      keyEpoch: serverHello.keyEpoch,
      phoneSignature: phoneSignature.toString("base64"),
    }),
    {
      sendControlMessage(message) {
        controlMessages.push(message);
      },
      onApplicationMessage(message) {
        applicationMessages.push(message);
      },
    }
  );

  const secureReady = controlMessages.find((message) => message.kind === "secureReady");
  assert.ok(secureReady, "expected secureReady");

  if (!skipResumeState) {
    secureTransport.handleIncomingWireMessage(
      JSON.stringify({
        kind: "resumeState",
        sessionId,
        keyEpoch: serverHello.keyEpoch,
        lastAppliedBridgeOutboundSeq,
      }),
      {
        sendControlMessage(message) {
          controlMessages.push(message);
        },
        onApplicationMessage(message) {
          applicationMessages.push(message);
        },
      }
    );
  }

  return { applicationMessages, controlMessages, serverHello, transcriptBytes };
}

function createOkpKeyPair(type) {
  const { privateKey, publicKey } = generateKeyPairSync(type);
  const privateJwk = privateKey.export({ format: "jwk" });
  const publicJwk = publicKey.export({ format: "jwk" });
  return {
    privateKey: base64UrlToBase64(privateJwk.d),
    publicKey: base64UrlToBase64(publicJwk.x),
  };
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
    encodeLengthPrefixedUTF8("remodex-e2ee-v1"),
    encodeLengthPrefixedUTF8(sessionId),
    encodeLengthPrefixedUTF8(String(protocolVersion)),
    encodeLengthPrefixedUTF8(handshakeMode),
    encodeLengthPrefixedUTF8(String(keyEpoch)),
    encodeLengthPrefixedUTF8(macDeviceId),
    encodeLengthPrefixedUTF8(phoneDeviceId),
    encodeLengthPrefixedBuffer(Buffer.from(macIdentityPublicKey, "base64")),
    encodeLengthPrefixedBuffer(Buffer.from(phoneIdentityPublicKey, "base64")),
    encodeLengthPrefixedBuffer(Buffer.from(macEphemeralPublicKey, "base64")),
    encodeLengthPrefixedBuffer(Buffer.from(phoneEphemeralPublicKey, "base64")),
    encodeLengthPrefixedBuffer(clientNonce),
    encodeLengthPrefixedBuffer(serverNonce),
    encodeLengthPrefixedUTF8(String(expiresAtForTranscript)),
  ]);
}

function encodeLengthPrefixedUTF8(value) {
  return encodeLengthPrefixedBuffer(Buffer.from(value, "utf8"));
}

function encodeLengthPrefixedBuffer(buffer) {
  const length = Buffer.allocUnsafe(4);
  length.writeUInt32BE(buffer.length, 0);
  return Buffer.concat([length, buffer]);
}

function encryptEnvelope(payloadObject, key, sender, counter, sessionId, keyEpoch) {
  const nonce = nonceForDirection(sender, counter);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([
    cipher.update(Buffer.from(JSON.stringify(payloadObject), "utf8")),
    cipher.final(),
  ]);
  return {
    kind: "encryptedEnvelope",
    v: 1,
    sessionId,
    keyEpoch,
    sender,
    counter,
    ciphertext: ciphertext.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
  };
}

function decryptEnvelope(envelope, key) {
  const nonce = nonceForDirection(envelope.sender, envelope.counter);
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAuthTag(Buffer.from(envelope.tag, "base64"));
  const plaintext = Buffer.concat([
    decipher.update(Buffer.from(envelope.ciphertext, "base64")),
    decipher.final(),
  ]);
  return JSON.parse(plaintext.toString("utf8"));
}

function deriveMacToPhoneKey({
  sessionId,
  macDeviceId,
  phoneDeviceId,
  phoneEphemeral,
  serverHello,
  transcriptBytes,
}) {
  const sharedSecret = diffieHellman({
    privateKey: createPrivateKey({
      key: {
        crv: "X25519",
        d: base64ToBase64Url(phoneEphemeral.privateKey),
        kty: "OKP",
        x: base64ToBase64Url(phoneEphemeral.publicKey),
      },
      format: "jwk",
    }),
    publicKey: createPublicKey({
      key: {
        crv: "X25519",
        kty: "OKP",
        x: base64ToBase64Url(serverHello.macEphemeralPublicKey),
      },
      format: "jwk",
    }),
  });
  const salt = createHash("sha256").update(transcriptBytes).digest();
  const infoPrefix = `remodex-e2ee-v1|${sessionId}|${macDeviceId}|${phoneDeviceId}|${serverHello.keyEpoch}`;
  return Buffer.from(
    hkdfSync("sha256", sharedSecret, salt, Buffer.from(`${infoPrefix}|macToPhone`, "utf8"), 32)
  );
}

function base64UrlToBase64(value) {
  const padded = `${value}${"=".repeat((4 - (value.length % 4 || 4)) % 4)}`;
  return padded.replace(/-/g, "+").replace(/_/g, "/");
}

function base64ToBase64Url(value) {
  return value.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
