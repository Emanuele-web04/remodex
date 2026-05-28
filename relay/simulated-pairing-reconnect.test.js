// FILE: simulated-pairing-reconnect.test.js
// Purpose: Exercises relay pairing, trusted reconnect, and secure replay without a live app or Simulator.
// Layer: Integration test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, crypto, ws, ./server, ../phodex-bridge/src/secure-transport

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
const WebSocket = require("ws");
const {
  HANDSHAKE_MODE_QR_BOOTSTRAP,
  HANDSHAKE_MODE_TRUSTED_RECONNECT,
  createBridgeSecureTransport,
  nonceForDirection,
} = require("../phodex-bridge/src/secure-transport");
const { createRelayServer } = require("./server");

test("simulated relay harness covers QR bootstrap, trusted resolve, and reconnect replay", async () => {
  await withServer(async ({ port, wss }) => {
    const sessionId = "simulated-pairing-session";
    const macDeviceId = "simulated-mac";
    const pairingCode = "AB23CD34";
    const macIdentity = createOkpKeyPair("ed25519");
    const phoneIdentity = createPhoneIdentity("simulated-phone");
    const applicationMessages = [];

    let macSocket = null;
    const secureTransport = createBridgeSecureTransport({
      sessionId,
      relayUrl: `ws://127.0.0.1:${port}/relay`,
      displayName: "Simulated Mac",
      persistTrustedPhone: false,
      deviceState: {
        macDeviceId,
        macIdentityPrivateKey: macIdentity.privateKey,
        macIdentityPublicKey: macIdentity.publicKey,
        trustedPhones: {},
      },
      onTrustedPhoneUpdate(_deviceState, trustedPhone) {
        macSocket.send(JSON.stringify({
          kind: "relayMacRegistration",
          registration: {
            macDeviceId,
            macIdentityPublicKey: macIdentity.publicKey,
            displayName: "Simulated Mac",
            trustedPhoneDeviceId: trustedPhone.phoneDeviceId,
            trustedPhonePublicKey: trustedPhone.phoneIdentityPublicKey,
          },
        }));
      },
    });

    macSocket = new WebSocket(`ws://127.0.0.1:${port}/relay/${sessionId}`, {
      headers: {
        "x-role": "mac",
        "x-mac-device-id": macDeviceId,
        "x-mac-identity-public-key": macIdentity.publicKey,
        "x-machine-name": "Simulated Mac",
        "x-pairing-code": pairingCode,
        "x-pairing-version": "2",
        "x-pairing-expires-at": String(Date.now() + 60_000),
      },
    });
    await onceOpen(macSocket);
    bindBridgeTransportToSocket({
      applicationMessages,
      secureTransport,
      socket: macSocket,
    });

    const pairingResponse = await fetch(`http://127.0.0.1:${port}/v1/pairing/code/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code: "AB23-CD34" }),
    });
    const pairingPayload = await pairingResponse.json();
    assert.equal(pairingResponse.status, 200);
    assert.equal(pairingPayload.sessionId, sessionId);
    assert.equal(pairingPayload.macDeviceId, macDeviceId);
    assert.equal(pairingPayload.macIdentityPublicKey, macIdentity.publicKey);

    const firstPhoneSocket = new WebSocket(`ws://127.0.0.1:${port}/relay/${sessionId}`, {
      headers: { "x-role": "iphone" },
    });
    await onceOpen(firstPhoneSocket);
    const firstPhone = new SimulatedPhone({
      macDeviceId,
      macIdentityPublicKey: macIdentity.publicKey,
      phoneIdentity,
      sessionId,
      socket: firstPhoneSocket,
    });
    await firstPhone.completeHandshake({
      handshakeMode: HANDSHAKE_MODE_QR_BOOTSTRAP,
      lastAppliedBridgeOutboundSeq: 0,
    });
    await waitUntil(() => secureTransport.isSecureChannelReady());
    assert.equal(secureTransport.isSecureChannelReady(), true);

    const trustedSession = await resolveTrustedSessionEventually(port, {
      macDeviceId,
      phoneIdentity,
    });
    assert.equal(trustedSession.status, 200);
    assert.equal(trustedSession.body.sessionId, sessionId);
    assert.equal(trustedSession.body.displayName, "Simulated Mac");

    firstPhone.sendApplicationMessage(JSON.stringify({
      id: "request-1",
      method: "thread/list",
      params: {},
    }));
    await waitUntil(() => applicationMessages.length === 1);
    assert.deepEqual(applicationMessages, [
      JSON.stringify({ id: "request-1", method: "thread/list", params: {} }),
    ]);

    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ id: "response-1", result: { ok: true } }),
      failUnexpectedDirectSend
    );
    const firstOutbound = await firstPhone.nextBridgePayload();
    assert.equal(firstOutbound.bridgeOutboundSeq, 1);
    assert.equal(firstOutbound.payloadText, JSON.stringify({ id: "response-1", result: { ok: true } }));

    const firstPhoneClosed = onceClosed(firstPhoneSocket);
    firstPhoneSocket.close();
    await firstPhoneClosed;
    await waitUntil(() => countRelayClients(wss, "iphone") === 0);

    secureTransport.queueOutboundApplicationMessage(
      JSON.stringify({ id: "response-2", result: { replayed: true } }),
      failUnexpectedDirectSend
    );
    await waitUntil(() => macSocket.bufferedAmount === 0);
    await delay(25);

    const secondPhoneSocket = new WebSocket(`ws://127.0.0.1:${port}/relay/${sessionId}`, {
      headers: { "x-role": "iphone" },
    });
    await onceOpen(secondPhoneSocket);
    const secondPhone = new SimulatedPhone({
      macDeviceId,
      macIdentityPublicKey: macIdentity.publicKey,
      phoneIdentity,
      sessionId,
      socket: secondPhoneSocket,
    });
    await secondPhone.completeHandshake({
      handshakeMode: HANDSHAKE_MODE_TRUSTED_RECONNECT,
      lastAppliedBridgeOutboundSeq: firstOutbound.bridgeOutboundSeq,
    });

    const replayedPayload = await secondPhone.nextBridgePayload();
    assert.equal(replayedPayload.bridgeOutboundSeq, 2);
    assert.equal(replayedPayload.payloadText, JSON.stringify({ id: "response-2", result: { replayed: true } }));

    const secondPhoneClosed = onceClosed(secondPhoneSocket);
    const macClosed = onceClosed(macSocket);
    secondPhoneSocket.close();
    macSocket.close();
    await Promise.all([secondPhoneClosed, macClosed]);
  });
});

class SimulatedPhone {
  constructor({
    macDeviceId,
    macIdentityPublicKey,
    phoneIdentity,
    sessionId,
    socket,
  }) {
    this.macDeviceId = macDeviceId;
    this.macIdentityPublicKey = macIdentityPublicKey;
    this.outboundCounter = 0;
    this.phoneIdentity = phoneIdentity;
    this.sessionId = sessionId;
    this.socket = socket;
  }

  async completeHandshake({
    handshakeMode,
    lastAppliedBridgeOutboundSeq,
  }) {
    const phoneEphemeral = createOkpKeyPair("x25519");
    const clientNonce = Buffer.alloc(32, 7 + this.outboundCounter);
    this.socket.send(JSON.stringify({
      kind: "clientHello",
      protocolVersion: 1,
      sessionId: this.sessionId,
      handshakeMode,
      phoneDeviceId: this.phoneIdentity.phoneDeviceId,
      phoneIdentityPublicKey: this.phoneIdentity.phoneIdentityPublicKey,
      phoneEphemeralPublicKey: phoneEphemeral.publicKey,
      clientNonce: clientNonce.toString("base64"),
    }));

    const serverHello = JSON.parse(await onceMessage(this.socket));
    assert.equal(serverHello.kind, "serverHello");
    assert.equal(serverHello.macIdentityPublicKey, this.macIdentityPublicKey);

    const transcriptBytes = buildTranscriptBytes({
      sessionId: this.sessionId,
      protocolVersion: 1,
      handshakeMode,
      keyEpoch: serverHello.keyEpoch,
      macDeviceId: this.macDeviceId,
      phoneDeviceId: this.phoneIdentity.phoneDeviceId,
      macIdentityPublicKey: this.macIdentityPublicKey,
      phoneIdentityPublicKey: this.phoneIdentity.phoneIdentityPublicKey,
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
      {
        key: {
          crv: "Ed25519",
          d: base64ToBase64Url(this.phoneIdentity.phoneIdentityPrivateKey),
          kty: "OKP",
          x: base64ToBase64Url(this.phoneIdentity.phoneIdentityPublicKey),
        },
        format: "jwk",
      }
    );

    this.socket.send(JSON.stringify({
      kind: "clientAuth",
      sessionId: this.sessionId,
      phoneDeviceId: this.phoneIdentity.phoneDeviceId,
      keyEpoch: serverHello.keyEpoch,
      phoneSignature: phoneSignature.toString("base64"),
    }));

    const secureReady = JSON.parse(await onceMessage(this.socket));
    assert.equal(secureReady.kind, "secureReady");

    const keys = deriveSessionKeys({
      macDeviceId: this.macDeviceId,
      phoneDeviceId: this.phoneIdentity.phoneDeviceId,
      phoneEphemeral,
      serverHello,
      sessionId: this.sessionId,
      transcriptBytes,
    });
    this.keyEpoch = serverHello.keyEpoch;
    this.macToPhoneKey = keys.macToPhoneKey;
    this.phoneToMacKey = keys.phoneToMacKey;
    this.outboundCounter = 0;

    this.socket.send(JSON.stringify({
      kind: "resumeState",
      sessionId: this.sessionId,
      keyEpoch: this.keyEpoch,
      lastAppliedBridgeOutboundSeq,
    }));
  }

  async nextBridgePayload() {
    const envelope = JSON.parse(await onceMessage(this.socket));
    assert.equal(envelope.kind, "encryptedEnvelope");
    return decryptEnvelope(envelope, this.macToPhoneKey);
  }

  sendApplicationMessage(payloadText) {
    const envelope = encryptEnvelope(
      { payloadText },
      this.phoneToMacKey,
      "iphone",
      this.outboundCounter,
      this.sessionId,
      this.keyEpoch
    );
    this.outboundCounter += 1;
    this.socket.send(JSON.stringify(envelope));
  }
}

function bindBridgeTransportToSocket({
  applicationMessages,
  secureTransport,
  socket,
}) {
  secureTransport.bindLiveSendWireMessage((message) => {
    socket.send(message);
    return true;
  });
  socket.on("message", (data) => {
    secureTransport.handleIncomingWireMessage(data.toString("utf8"), {
      sendControlMessage(message) {
        socket.send(JSON.stringify(message));
      },
      onApplicationMessage(message) {
        applicationMessages.push(message);
      },
    });
  });
}

async function withServer(run) {
  const { server, wss } = createRelayServer();
  const address = await listen(server);
  try {
    return await run({ port: address.port, wss });
  } finally {
    for (const client of wss.clients) {
      client.terminate();
    }
    await close(server, wss);
  }
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      resolve(server.address());
    });
  });
}

function close(server, wss) {
  return new Promise((resolve, reject) => {
    wss.close();
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

async function resolveTrustedSessionEventually(port, {
  macDeviceId,
  phoneIdentity,
}) {
  let lastResult = null;
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const response = await fetch(`http://127.0.0.1:${port}/v1/trusted/session/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(makeTrustedResolveBody({
        macDeviceId,
        phoneIdentity,
        nonce: `trusted-resolve-${attempt}`,
        timestamp: Date.now(),
      })),
    });
    lastResult = {
      body: await response.json(),
      status: response.status,
    };
    if (response.status === 200) {
      return lastResult;
    }
    await delay(10);
  }
  return lastResult;
}

function onceOpen(socket) {
  return new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
}

function onceMessage(socket) {
  return new Promise((resolve, reject) => {
    socket.once("message", (value) => resolve(value.toString("utf8")));
    socket.once("error", reject);
  });
}

function onceClosed(socket) {
  return new Promise((resolve) => {
    if (socket.readyState === WebSocket.CLOSED) {
      resolve();
      return;
    }
    socket.once("close", resolve);
  });
}

function waitUntil(predicate, { attempts = 20, delayMs = 10 } = {}) {
  return new Promise((resolve, reject) => {
    let attempt = 0;
    const tick = () => {
      if (predicate()) {
        resolve();
        return;
      }
      attempt += 1;
      if (attempt >= attempts) {
        reject(new Error("condition was not met before timeout"));
        return;
      }
      setTimeout(tick, delayMs);
    };
    tick();
  });
}

function countRelayClients(wss, role) {
  let count = 0;
  for (const client of wss.clients) {
    if (client._relayRole === role && client.readyState === WebSocket.OPEN) {
      count += 1;
    }
  }
  return count;
}

function delay(milliseconds) {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
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

function createPhoneIdentity(phoneDeviceId) {
  const identity = createOkpKeyPair("ed25519");
  return {
    phoneDeviceId,
    phoneIdentityPrivateKey: identity.privateKey,
    phoneIdentityPublicKey: identity.publicKey,
  };
}

function makeTrustedResolveBody({
  macDeviceId,
  phoneIdentity,
  nonce,
  timestamp,
}) {
  const transcript = buildTrustedResolveTranscript({
    macDeviceId,
    nonce,
    phoneDeviceId: phoneIdentity.phoneDeviceId,
    phoneIdentityPublicKey: phoneIdentity.phoneIdentityPublicKey,
    timestamp,
  });
  return {
    macDeviceId,
    nonce,
    phoneDeviceId: phoneIdentity.phoneDeviceId,
    phoneIdentityPublicKey: phoneIdentity.phoneIdentityPublicKey,
    signature: sign(
      null,
      transcript,
      {
        key: {
          crv: "Ed25519",
          d: base64ToBase64Url(phoneIdentity.phoneIdentityPrivateKey),
          kty: "OKP",
          x: base64ToBase64Url(phoneIdentity.phoneIdentityPublicKey),
        },
        format: "jwk",
      }
    ).toString("base64"),
    timestamp,
  };
}

function buildTrustedResolveTranscript({
  macDeviceId,
  nonce,
  phoneDeviceId,
  phoneIdentityPublicKey,
  timestamp,
}) {
  return Buffer.concat([
    encodeLengthPrefixedUTF8("remodex-trusted-session-resolve-v1"),
    encodeLengthPrefixedUTF8(macDeviceId),
    encodeLengthPrefixedUTF8(phoneDeviceId),
    encodeLengthPrefixedBuffer(Buffer.from(phoneIdentityPublicKey, "base64")),
    encodeLengthPrefixedUTF8(nonce),
    encodeLengthPrefixedUTF8(String(timestamp)),
  ]);
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

function deriveSessionKeys({
  macDeviceId,
  phoneDeviceId,
  phoneEphemeral,
  serverHello,
  sessionId,
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
  return {
    macToPhoneKey: Buffer.from(
      hkdfSync("sha256", sharedSecret, salt, Buffer.from(`${infoPrefix}|macToPhone`, "utf8"), 32)
    ),
    phoneToMacKey: Buffer.from(
      hkdfSync("sha256", sharedSecret, salt, Buffer.from(`${infoPrefix}|phoneToMac`, "utf8"), 32)
    ),
  };
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

function failUnexpectedDirectSend() {
  throw new Error("expected bound relay sender to handle secure transport output");
}
