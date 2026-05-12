const test = require("node:test");
const assert = require("node:assert/strict");
const { generateKeyPairSync, sign } = require("node:crypto");
const WebSocket = require("ws");
const { createRelayServer } = require("../src/local-relay");

test("bundled local relay resolves pairing codes for a live mac session", async () => {
  await withServer(async ({ port }) => {
    const expiresAt = Date.now() + 60_000;
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/pairing-local-1`, {
      headers: {
        "x-role": "mac",
        "x-mac-device-id": "mac-pairing-local-1",
        "x-mac-identity-public-key": "mac-public-key-pairing-local-1",
        "x-pairing-code": "AB23CD34EF",
        "x-pairing-version": "2",
        "x-pairing-expires-at": String(expiresAt),
      },
    });
    await onceOpen(mac);

    const response = await fetch(`http://127.0.0.1:${port}/v1/pairing/code/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code: "AB23-CD34EF" }),
    });

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      ok: true,
      v: 2,
      sessionId: "pairing-local-1",
      macDeviceId: "mac-pairing-local-1",
      macIdentityPublicKey: "mac-public-key-pairing-local-1",
      expiresAt,
    });

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;
  });
});

test("bundled local relay resolves trusted sessions for a live trusted iphone", async () => {
  const phoneIdentity = makePhoneIdentity();

  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/live-local-1`, {
      headers: {
        "x-role": "mac",
        "x-mac-device-id": "mac-local-1",
        "x-mac-identity-public-key": "mac-public-key-local-1",
        "x-machine-name": "Developer-Mac",
        "x-trusted-phone-device-id": phoneIdentity.phoneDeviceId,
        "x-trusted-phone-public-key": phoneIdentity.phoneIdentityPublicKey,
      },
    });
    await onceOpen(mac);

    const body = makeTrustedResolveBody({
      macDeviceId: "mac-local-1",
      phoneIdentity,
      nonce: "nonce-local-1",
      timestamp: Date.now(),
    });
    const response = await fetch(`http://127.0.0.1:${port}/v1/trusted/session/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      ok: true,
      macDeviceId: "mac-local-1",
      macIdentityPublicKey: "mac-public-key-local-1",
      displayName: "Developer-Mac",
      sessionId: "live-local-1",
    });

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;
  });
});

async function withServer(run) {
  const { server, wss } = createRelayServer();
  try {
    const address = await listen(server);
    await run({
      port: address.port,
      server,
      wss,
    });
  } finally {
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

function onceOpen(socket) {
  return new Promise((resolve, reject) => {
    socket.once("open", resolve);
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

function makePhoneIdentity() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicJwk = publicKey.export({ format: "jwk" });
  const privateJwk = privateKey.export({ format: "jwk" });
  return {
    phoneDeviceId: `phone-${Math.random().toString(16).slice(2)}`,
    phoneIdentityPublicKey: base64UrlToBase64(publicJwk.x),
    phoneIdentityPrivateKey: base64UrlToBase64(privateJwk.d),
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
    phoneDeviceId: phoneIdentity.phoneDeviceId,
    phoneIdentityPublicKey: phoneIdentity.phoneIdentityPublicKey,
    nonce,
    timestamp,
  });
  return {
    macDeviceId,
    phoneDeviceId: phoneIdentity.phoneDeviceId,
    phoneIdentityPublicKey: phoneIdentity.phoneIdentityPublicKey,
    nonce,
    timestamp,
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
  };
}

function buildTrustedResolveTranscript({
  macDeviceId,
  phoneDeviceId,
  phoneIdentityPublicKey,
  nonce,
  timestamp,
}) {
  return Buffer.concat([
    encodeLengthPrefixedUTF8("remodex-trusted-session-resolve-v1"),
    encodeLengthPrefixedUTF8(macDeviceId),
    encodeLengthPrefixedUTF8(phoneDeviceId),
    encodeLengthPrefixedData(Buffer.from(phoneIdentityPublicKey, "base64")),
    encodeLengthPrefixedUTF8(nonce),
    encodeLengthPrefixedUTF8(String(timestamp)),
  ]);
}

function encodeLengthPrefixedUTF8(value) {
  return encodeLengthPrefixedData(Buffer.from(value, "utf8"));
}

function encodeLengthPrefixedData(value) {
  const length = Buffer.allocUnsafe(4);
  length.writeUInt32BE(value.length, 0);
  return Buffer.concat([length, value]);
}

function base64UrlToBase64(value) {
  const normalized = String(value || "")
    .replaceAll("-", "+")
    .replaceAll("_", "/");
  const remainder = normalized.length % 4;
  return remainder === 0 ? normalized : normalized + "=".repeat(4 - remainder);
}

function base64ToBase64Url(value) {
  return String(value || "")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
}
