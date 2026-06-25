// FILE: relay-heartbeat.test.js
// Purpose: Verifies bidirectional message liveness for mobile relay sockets (PR2).
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ws, ./server

const test = require("node:test");
const assert = require("node:assert/strict");
const WebSocket = require("ws");
const { createRelayServer } = require("./server");

const MESSAGE_LIVENESS_ENV = "REMODEX_RELAY_MESSAGE_LIVENESS";
const HEARTBEAT_INTERVAL_MS = 1_000;
// Production heartbeat is 30s; 35s ≈ one missed pong window, 70s+ ≈ two.
const ONE_HEARTBEAT_WINDOW_MS = Math.ceil((35_000 / 30_000) * HEARTBEAT_INTERVAL_MS);
const TWO_HEARTBEAT_WINDOWS_MS = Math.ceil((70_000 / 30_000) * HEARTBEAT_INTERVAL_MS);

test("mobile inbound without pong stays alive when message liveness is enabled", async () => {
  await withMessageLiveness(async () => {
    await withRelaySession(async ({ mac, iphone }) => {
      suppressClientPong(iphone);
      iphone.send(JSON.stringify({ kind: "mobilePing" }));

      await delay(ONE_HEARTBEAT_WINDOW_MS);
      assert.equal(iphone.readyState, WebSocket.OPEN, "mobile socket should stay open after inbound-only activity");
    });
  });
});

test("mobile outbound relay without inbound or pong stays alive when message liveness is enabled", async () => {
  await withMessageLiveness(async () => {
    await withRelaySession(async ({ mac, iphone }) => {
      suppressClientPong(iphone);
      mac.send(JSON.stringify({ kind: "macStream", chunk: 1 }));

      await delay(ONE_HEARTBEAT_WINDOW_MS);
      assert.equal(iphone.readyState, WebSocket.OPEN, "mobile socket should stay open after Mac→mobile relay only");
    });
  });
});

test("mobile with no inbound, outbound, or pong is terminated after two heartbeat windows", async () => {
  await withMessageLiveness(async () => {
    await withRelaySession(async ({ mac, iphone }) => {
      suppressClientPong(iphone);

      await delay(TWO_HEARTBEAT_WINDOWS_MS);
      assert.notEqual(iphone.readyState, WebSocket.OPEN, "idle mobile socket should be terminated");
    });
  });
});

async function withMessageLiveness(run) {
  const previous = process.env[MESSAGE_LIVENESS_ENV];
  process.env[MESSAGE_LIVENESS_ENV] = "1";
  try {
    await run();
  } finally {
    if (previous === undefined) {
      delete process.env[MESSAGE_LIVENESS_ENV];
    } else {
      process.env[MESSAGE_LIVENESS_ENV] = previous;
    }
  }
}

async function withRelaySession(run) {
  await withServer(async ({ port }) => {
    const mac = new WebSocket(`ws://127.0.0.1:${port}/relay/session-heartbeat`, {
      headers: { "x-role": "mac" },
    });
    await onceOpen(mac);

    const iphone = new WebSocket(`ws://127.0.0.1:${port}/relay/session-heartbeat`, {
      headers: { "x-role": "iphone" },
    });
    await onceOpen(iphone);

    try {
      await run({ mac, iphone, port });
    } finally {
      const macClosed = onceClosed(mac);
      const iphoneClosed = onceClosed(iphone);
      if (mac.readyState === WebSocket.OPEN) {
        mac.close();
      }
      if (iphone.readyState === WebSocket.OPEN) {
        iphone.close();
      }
      await Promise.allSettled([macClosed, iphoneClosed]);
    }
  });
}

function suppressClientPong(socket) {
  socket._receiver.removeAllListeners("ping");
  socket.on("ping", () => {});
}

async function withServer(run, serverOptions = {}) {
  const { server, wss } = createRelayServer({
    relayOptions: {
      heartbeatIntervalMs: HEARTBEAT_INTERVAL_MS,
      ...serverOptions.relayOptions,
    },
    ...serverOptions,
  });
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

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}