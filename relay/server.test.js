// FILE: server.test.js
// Purpose: Verifies relay HTTP protections, health output, and websocket session routing.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ws, ./server

const test = require("node:test");
const assert = require("node:assert/strict");
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


function onceClosed(socket) {
  return new Promise((resolve) => {
    if (socket.readyState === WebSocket.CLOSED) {
      resolve();
      return;
    }

    socket.once("close", resolve);
  });
}
