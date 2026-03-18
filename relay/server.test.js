// FILE: server.test.js
// Purpose: Verifies relay HTTP protections, health output, and websocket session routing.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, crypto, ws, ./server

const test = require("node:test");
const assert = require("node:assert/strict");
const { generateKeyPairSync, sign } = require("crypto");
const WebSocket = require("ws");
const {
  createRelayServer,
  createFixedWindowRateLimiter,
  clientAddressKey,
  redactRelayPathname,
} = require("./server");

test("health is minimal by default and detailed only when enabled", async () => {
  const minimal = await withServer(async ({ port }) => {
    const response = await fetch(`http://127.0.0.1:${port}/health`);
    return response.json();
  });
  assert.deepEqual(minimal, { ok: true });

  const detailed = await withServer(async ({ port }) => {
    const response = await fetch(`http://127.0.0.1:${port}/health`);
    return response.json();
  }, { exposeDetailedHealth: true });
  assert.equal(detailed.ok, true);
  assert.ok(detailed.relay);
  assert.ok(detailed.push);
  assert.equal(detailed.push.enabled, false);
});

test("push routes stay disabled until explicitly enabled", async () => {
  const { body, status } = await withServer(async ({ port }) => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/push/session/register-device`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    return {
      body: await response.json(),
      status: response.status,
    };
  });

  assert.equal(status, 404);
  assert.equal(body.error, "Not found");
});

test("push routes are rate limited", async () => {
  const { body, status } = await withServer(async ({ port }) => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/push/session/register-device`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    return {
      body: await response.json(),
      status: response.status,
    };
  }, {
    enablePushService: true,
    pushRateLimiter: {
      allow() {
        return false;
      },
    },
  });

  assert.equal(status, 429);
  assert.equal(body.code, "rate_limited");
});

test("push registration requires the live mac notification secret", async () => {
  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/session-push`, {
      headers: {
        "x-role": "mac",
        "x-notification-secret": "bridge-secret",
      },
    });
    await onceOpen(mac);

    const rejected = await fetch(`http://127.0.0.1:${port}/v1/push/session/register-device`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sessionId: "session-push",
        notificationSecret: "wrong-secret",
        deviceToken: "aabbcc",
        alertsEnabled: true,
      }),
    });
    assert.equal(rejected.status, 403);

    const accepted = await fetch(`http://127.0.0.1:${port}/v1/push/session/register-device`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sessionId: "session-push",
        notificationSecret: "bridge-secret",
        deviceToken: "aabbcc",
        alertsEnabled: true,
      }),
    });
    assert.equal(accepted.status, 200);

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;
  }, {
    enablePushService: true,
  });
});

test("completion pushes are rejected after the mac relay session disconnects", async () => {
  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/session-push-completion`, {
      headers: {
        "x-role": "mac",
        "x-notification-secret": "bridge-secret",
      },
    });
    await onceOpen(mac);

    const accepted = await fetch(`http://127.0.0.1:${port}/v1/push/session/register-device`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sessionId: "session-push-completion",
        notificationSecret: "bridge-secret",
        deviceToken: "aabbcc",
        alertsEnabled: true,
      }),
    });
    assert.equal(accepted.status, 200);

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;

    const rejected = await fetch(`http://127.0.0.1:${port}/v1/push/session/notify-completion`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sessionId: "session-push-completion",
        notificationSecret: "bridge-secret",
        threadId: "thread-1",
        dedupeKey: "done-after-disconnect",
      }),
    });
    assert.equal(rejected.status, 403);
  }, {
    enablePushService: true,
  });
});

test("trusted session resolve returns the current live session for a trusted iphone", async () => {
  const phoneIdentity = makePhoneIdentity();

  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/live-session-1`, {
      headers: {
        "x-role": "mac",
        "x-mac-device-id": "mac-1",
        "x-mac-identity-public-key": "mac-public-key-1",
        "x-machine-name": "Emanuele-Mac",
        "x-trusted-phone-device-id": phoneIdentity.phoneDeviceId,
        "x-trusted-phone-public-key": phoneIdentity.phoneIdentityPublicKey,
      },
    });
    await onceOpen(mac);

    const body = makeTrustedResolveBody({
      macDeviceId: "mac-1",
      phoneIdentity,
      nonce: "nonce-1",
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
      macDeviceId: "mac-1",
      macIdentityPublicKey: "mac-public-key-1",
      displayName: "Emanuele-Mac",
      sessionId: "live-session-1",
    });

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;
  });
});

test("trusted session resolve rejects iphones that are not trusted for the live mac", async () => {
  const trustedPhone = makePhoneIdentity();
  const otherPhone = makePhoneIdentity();

  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/live-session-2`, {
      headers: {
        "x-role": "mac",
        "x-mac-device-id": "mac-2",
        "x-mac-identity-public-key": "mac-public-key-2",
        "x-trusted-phone-device-id": trustedPhone.phoneDeviceId,
        "x-trusted-phone-public-key": trustedPhone.phoneIdentityPublicKey,
      },
    });
    await onceOpen(mac);

    const response = await fetch(`http://127.0.0.1:${port}/v1/trusted/session/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(makeTrustedResolveBody({
        macDeviceId: "mac-2",
        phoneIdentity: otherPhone,
        nonce: "nonce-2",
        timestamp: Date.now(),
      })),
    });
    const body = await response.json();

    assert.equal(response.status, 403);
    assert.equal(body.code, "phone_not_trusted");

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;
  });
});

test("trusted session resolve rejects replayed nonces", async () => {
  const phoneIdentity = makePhoneIdentity();

  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/live-session-3`, {
      headers: {
        "x-role": "mac",
        "x-mac-device-id": "mac-3",
        "x-mac-identity-public-key": "mac-public-key-3",
        "x-trusted-phone-device-id": phoneIdentity.phoneDeviceId,
        "x-trusted-phone-public-key": phoneIdentity.phoneIdentityPublicKey,
      },
    });
    await onceOpen(mac);

    const body = makeTrustedResolveBody({
      macDeviceId: "mac-3",
      phoneIdentity,
      nonce: "reused-nonce",
      timestamp: Date.now(),
    });
    const firstResponse = await fetch(`http://127.0.0.1:${port}/v1/trusted/session/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    assert.equal(firstResponse.status, 200);

    const replayResponse = await fetch(`http://127.0.0.1:${port}/v1/trusted/session/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const replayBody = await replayResponse.json();

    assert.equal(replayResponse.status, 409);
    assert.equal(replayBody.code, "resolve_request_replayed");

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;
  });
});

test("trusted session resolve reports an offline mac without pretending the endpoint is missing", async () => {
  const phoneIdentity = makePhoneIdentity();

  await withServer(async ({ port }) => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/trusted/session/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(makeTrustedResolveBody({
        macDeviceId: "mac-offline",
        phoneIdentity,
        nonce: "nonce-offline",
        timestamp: Date.now(),
      })),
    });
    const body = await response.json();

    assert.equal(response.status, 404);
    assert.equal(body.code, "session_unavailable");
  });
});

test("trusted session resolve starts working immediately after a mac updates its trusted-phone registration", async () => {
  const phoneIdentity = makePhoneIdentity();

  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/live-session-4`, {
      headers: {
        "x-role": "mac",
        "x-mac-device-id": "mac-4",
        "x-mac-identity-public-key": "mac-public-key-4",
      },
    });
    await onceOpen(mac);

    mac.send(JSON.stringify({
      kind: "relayMacRegistration",
      registration: {
        macDeviceId: "mac-4",
        macIdentityPublicKey: "mac-public-key-4",
        displayName: "Updated-Mac",
        trustedPhoneDeviceId: phoneIdentity.phoneDeviceId,
        trustedPhonePublicKey: phoneIdentity.phoneIdentityPublicKey,
      },
    }));

    const response = await fetch(`http://127.0.0.1:${port}/v1/trusted/session/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(makeTrustedResolveBody({
        macDeviceId: "mac-4",
        phoneIdentity,
        nonce: "nonce-live-update",
        timestamp: Date.now(),
      })),
    });

    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.displayName, "Updated-Mac");
    assert.equal(body.sessionId, "live-session-4");

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;
  });
});

test("fixed-window limiter prunes expired buckets", () => {
  let currentTime = 0;
  const limiter = createFixedWindowRateLimiter({
    windowMs: 100,
    maxRequests: 2,
    now: () => currentTime,
  });

  assert.equal(limiter.allow("client-a"), true);
  assert.equal(limiter.allow("client-b"), true);
  assert.equal(limiter.bucketCount(), 2);

  currentTime = 150;

  assert.equal(limiter.allow("client-c"), true);
  assert.equal(limiter.bucketCount(), 1);
});

test("clientAddressKey prefers the original client hop from forwarded proxy headers", () => {
  assert.equal(
    clientAddressKey({
      headers: {
        "x-forwarded-for": "198.51.100.24, 203.0.113.10",
      },
      socket: {
        remoteAddress: "10.0.0.1",
      },
    }, { trustProxy: true }),
    "198.51.100.24"
  );

  assert.equal(
    clientAddressKey({
      headers: {
        "x-real-ip": "203.0.113.8",
      },
      socket: {
        remoteAddress: "10.0.0.1",
      },
    }, { trustProxy: true }),
    "203.0.113.8"
  );
});

test("clientAddressKey prefers x-real-ip over forwarded hops when trustProxy is enabled", () => {
  assert.equal(
    clientAddressKey({
      headers: {
        "x-forwarded-for": "198.51.100.24, 203.0.113.10",
        "x-real-ip": "203.0.113.8",
      },
      socket: {
        remoteAddress: "10.0.0.1",
      },
    }, { trustProxy: true }),
    "203.0.113.8"
  );
});

test("clientAddressKey ignores forwarded headers until trustProxy is enabled", () => {
  assert.equal(
    clientAddressKey({
      headers: {
        "x-forwarded-for": "198.51.100.24",
        "x-real-ip": "203.0.113.8",
      },
      socket: {
        remoteAddress: "10.0.0.1",
      },
    }),
    "10.0.0.1"
  );
});

test("relay logs redact live session identifiers", async () => {
  const capturedLogs = [];
  const originalLog = console.log;
  console.log = (...args) => {
    capturedLogs.push(args.join(" "));
  };

  try {
    await withServer(async ({ port }) => {
      const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/session-sensitive`, {
        headers: { "x-role": "mac" },
      });
      const iphone = new WebSocket(`ws://127.0.0.1:${port}/relay/session-sensitive`, {
        headers: { "x-role": "iphone" },
      });

      await Promise.all([onceOpen(mac), onceOpen(iphone)]);

      const macClosed = onceClosed(mac);
      const iphoneClosed = onceClosed(iphone);
      mac.close();
      iphone.close();
      await Promise.all([macClosed, iphoneClosed]);
    });
  } finally {
    console.log = originalLog;
  }

  assert.ok(capturedLogs.some((line) => line.includes("/relay/[session]")));
  assert.ok(capturedLogs.some((line) => line.includes("session#")));
  assert.ok(capturedLogs.every((line) => !line.includes("session-sensitive")));
});

test("redactRelayPathname hides the session path segment", () => {
  assert.equal(redactRelayPathname("/relay/session-123"), "/relay/[session]");
  assert.equal(redactRelayPathname("/relay/session-123/extra"), "/relay/[session]/extra");
  assert.equal(redactRelayPathname("/health"), "/health");
});

test("websocket relay forwards between mac and iphone on the base relay path", async () => {
  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/session-1`, {
      headers: { "x-role": "mac" },
    });
    const iphone = new WebSocket(`ws://127.0.0.1:${port}/relay/session-1`, {
      headers: { "x-role": "iphone" },
    });

    await Promise.all([onceOpen(mac), onceOpen(iphone)]);

    const received = new Promise((resolve) => {
      iphone.once("message", (value) => resolve(value.toString("utf8")));
    });
    mac.send(JSON.stringify({ ok: true }));
    assert.equal(await received, "{\"ok\":true}");

    const macClosed = onceClosed(mac);
    const iphoneClosed = onceClosed(iphone);
    mac.close();
    iphone.close();
    await Promise.all([macClosed, iphoneClosed]);
  });
});

test("relay keeps the iPhone connected briefly but rejects new sends while the mac is absent", async () => {
  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/session-grace`, {
      headers: { "x-role": "mac" },
    });
    const iphone = new WebSocket(`ws://127.0.0.1:${port}/relay/session-grace`, {
      headers: { "x-role": "iphone" },
    });

    await Promise.all([onceOpen(mac), onceOpen(iphone)]);

    let iphoneClosed = false;
    iphone.once("close", () => {
      iphoneClosed = true;
    });

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;

    await delay(40);
    assert.equal(iphoneClosed, false);

    const closeDetails = onceCloseDetails(iphone);
    iphone.send(JSON.stringify({ buffered: true }));

    const { code, reason } = await closeDetails;
    assert.equal(code, 4004);
    assert.equal(reason, "Mac temporarily unavailable");
  }, {
    relayOptions: {
      macAbsenceGraceMs: 250,
    },
  });
});

test("relay lets the iPhone reconnect during the mac absence grace window", async () => {
  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/session-grace-rejoin`, {
      headers: { "x-role": "mac" },
    });
    const iphone = new WebSocket(`ws://127.0.0.1:${port}/relay/session-grace-rejoin`, {
      headers: { "x-role": "iphone" },
    });

    await Promise.all([onceOpen(mac), onceOpen(iphone)]);

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;

    const iphoneClosed = onceClosed(iphone);
    iphone.close();
    await iphoneClosed;

    const rejoinedIphone = new WebSocket(`ws://127.0.0.1:${port}/relay/session-grace-rejoin`, {
      headers: { "x-role": "iphone" },
    });
    await onceOpen(rejoinedIphone);

    const reconnectedMac = new WebSocket(`ws://127.0.0.1:${port}/relay/session-grace-rejoin`, {
      headers: { "x-role": "mac" },
    });
    await onceOpen(reconnectedMac);

    const received = onceMessage(reconnectedMac);
    rejoinedIphone.send(JSON.stringify({ liveAfterRejoin: true }));

    assert.equal(await received, "{\"liveAfterRejoin\":true}");

    const rejoinedIphoneClosed = onceClosed(rejoinedIphone);
    const reconnectedMacClosed = onceClosed(reconnectedMac);
    rejoinedIphone.close();
    reconnectedMac.close();
    await Promise.all([rejoinedIphoneClosed, reconnectedMacClosed]);
  }, {
    relayOptions: {
      macAbsenceGraceMs: 250,
    },
  });
});

test("relay closes with a dedicated code when the iphone sends during mac absence", async () => {
  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/session-buffer-full`, {
      headers: { "x-role": "mac" },
    });
    const iphone = new WebSocket(`ws://127.0.0.1:${port}/relay/session-buffer-full`, {
      headers: { "x-role": "iphone" },
    });

    await Promise.all([onceOpen(mac), onceOpen(iphone)]);

    const macClosed = onceClosed(mac);
    mac.close();
    await macClosed;

    const closeDetails = onceCloseDetails(iphone);
    iphone.send(JSON.stringify({ buffered: 1 }));

    const { code, reason } = await closeDetails;
    assert.equal(code, 4004);
    assert.equal(reason, "Mac temporarily unavailable");
  }, {
    relayOptions: {
      macAbsenceGraceMs: 250,
    },
  });
});

async function withServer(run, serverOptions = {}) {
  const { server, wss } = createRelayServer(serverOptions);
  const address = await listen(server);
  try {
    return await run({
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

function onceCloseDetails(socket) {
  return new Promise((resolve) => {
    if (socket.readyState === WebSocket.CLOSED) {
      resolve({ code: 1005, reason: "" });
      return;
    }

    socket.once("close", (code, reasonBuffer) => {
      resolve({
        code,
        reason: reasonBuffer.toString("utf8"),
      });
    });
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
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
  return remainder === 0
    ? normalized
    : normalized + "=".repeat(4 - remainder);
}

function base64ToBase64Url(value) {
  return String(value || "")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
}
