// FILE: relay-server.test.js
// Purpose: Verifies the self-hosted Remodex relay server exposes health endpoints and forwards frames correctly.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, node:events, ws, ../src/relay-server

const test = require("node:test");
const assert = require("node:assert/strict");
const { once } = require("node:events");
const { WebSocket } = require("ws");

const {
  DEFAULT_RELAY_PATH,
  listReachableRelayUrls,
  startRelayServer,
} = require("../src/relay-server");

test("relay server exposes health and stats endpoints", async (t) => {
  const relay = await startRelayServer({ host: "127.0.0.1", port: 0 });
  t.after(async () => {
    await relay.close();
  });

  const healthResponse = await fetch(`http://127.0.0.1:${relay.port}/healthz`);
  assert.equal(healthResponse.status, 200);
  const healthPayload = await healthResponse.json();
  assert.equal(healthPayload.ok, true);
  assert.equal(healthPayload.relayPath, DEFAULT_RELAY_PATH);
  assert.deepEqual(healthPayload.stats, {
    activeSessions: 0,
    sessionsWithMac: 0,
    totalClients: 0,
  });

  const statsResponse = await fetch(`http://127.0.0.1:${relay.port}/stats`);
  assert.equal(statsResponse.status, 200);
  assert.deepEqual(await statsResponse.json(), {
    activeSessions: 0,
    sessionsWithMac: 0,
    totalClients: 0,
  });
});

test("relay server forwards messages between mac and iphone peers", async (t) => {
  const relay = await startRelayServer({ host: "127.0.0.1", port: 0 });
  const sessionId = "session-forwarding";
  const mac = new WebSocket(`ws://127.0.0.1:${relay.port}/relay/${sessionId}`, {
    headers: { "x-role": "mac" },
  });
  const iphone = new WebSocket(`ws://127.0.0.1:${relay.port}/relay/${sessionId}`, {
    headers: { "x-role": "iphone" },
  });

  t.after(async () => {
    mac.terminate();
    iphone.terminate();
    await relay.close();
  });

  await once(mac, "open");
  await once(iphone, "open");

  const iphoneMessage = once(iphone, "message");
  mac.send("hello-from-mac");
  const [fromMac] = await iphoneMessage;
  assert.equal(fromMac.toString(), "hello-from-mac");

  const macMessage = once(mac, "message");
  iphone.send("hello-from-iphone");
  const [fromPhone] = await macMessage;
  assert.equal(fromPhone.toString(), "hello-from-iphone");
});

test("relay server rejects iphone connections when no mac session exists", async (t) => {
  const relay = await startRelayServer({ host: "127.0.0.1", port: 0 });
  t.after(async () => {
    iphone.terminate();
    await relay.close();
  });

  const iphone = new WebSocket(`ws://127.0.0.1:${relay.port}/relay/missing-session`, {
    headers: { "x-role": "iphone" },
  });

  const [code] = await once(iphone, "close");
  assert.equal(code, 4002);
});

test("listReachableRelayUrls includes localhost for wildcard listeners", () => {
  const urls = listReachableRelayUrls({ host: "0.0.0.0", port: 9000 });
  assert.ok(urls.includes("ws://127.0.0.1:9000/relay"));
});

test("listReachableRelayUrls brackets IPv6 hosts", () => {
  const urls = listReachableRelayUrls({ host: "::1", port: 9000 });
  assert.deepEqual(urls, ["ws://[::1]:9000/relay"]);
});
