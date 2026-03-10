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
  createBridgeSecureTransport,
  nonceForDirection,
} = require("../src/secure-transport");

test("secure transport rejects plaintext JSON-RPC before the secure handshake", () => {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const privateJwk = privateKey.export({ format: "jwk" });
  const publicJwk = publicKey.export({ format: "jwk" });
  const secureTransport = createBridgeSecureTransport({
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
  const secureTransport = createBridgeSecureTransport({
    sessionId: "session-2",
    relayUrl: "wss://relay.example/relay",
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

test("qr bootstrap rejects pairing a different iPhone after one phone is trusted", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const firstPhoneIdentity = createOkpKeyPair("ed25519");
  const firstPhoneEphemeral = createOkpKeyPair("x25519");
  const secondPhoneIdentity = createOkpKeyPair("ed25519");
  const secondPhoneEphemeral = createOkpKeyPair("x25519");
  const secureTransport = createBridgeSecureTransport({
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

  const controlMessages = [];
  secureTransport.handleIncomingWireMessage(
    JSON.stringify({
      kind: "clientHello",
      protocolVersion: 1,
      sessionId: "session-3",
      handshakeMode: HANDSHAKE_MODE_QR_BOOTSTRAP,
      phoneDeviceId: "phone-3b",
      phoneIdentityPublicKey: secondPhoneIdentity.publicKey,
      phoneEphemeralPublicKey: secondPhoneEphemeral.publicKey,
      clientNonce: Buffer.alloc(32, 9).toString("base64"),
    }),
    {
      sendControlMessage(message) {
        controlMessages.push(message);
      },
      onApplicationMessage() {
        throw new Error("second phone bootstrap should be rejected before app traffic");
      },
    }
  );

  assert.equal(controlMessages[0]?.kind, "secureError");
  assert.equal(controlMessages[0]?.code, "phone_replacement_required");
});

test("qr bootstrap starts a fresh replay window instead of leaking buffered messages", () => {
  const macIdentity = createOkpKeyPair("ed25519");
  const phoneIdentity = createOkpKeyPair("ed25519");
  const firstEphemeral = createOkpKeyPair("x25519");
  const secondEphemeral = createOkpKeyPair("x25519");
  const wireMessages = [];
  const secureTransport = createBridgeSecureTransport({
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

function base64UrlToBase64(value) {
  const padded = `${value}${"=".repeat((4 - (value.length % 4 || 4)) % 4)}`;
  return padded.replace(/-/g, "+").replace(/_/g, "/");
}

function base64ToBase64Url(value) {
  return value.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
