// FILE: relay-watchdog.test.js
// Purpose: Guards relay liveness and heartbeat traffic while the bridge is idle.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/relay-watchdog

const test = require("node:test");
const assert = require("node:assert/strict");
const { createRelayWatchdog } = require("../src/relay-watchdog");

test("regular relay heartbeats keep an idle bridge connected without extra pings", () => {
  const harness = createHarness();
  for (let time = 1_000; time <= 3_600_000; time += 1_000) {
    // Offset the relay timer from the watchdog, as on a real connection.
    if (time % 30_000 === 5_000) harness.receiveAt(time);
    if (time % 10_000 === 0) harness.tickAt(time);
  }
  assert.equal(harness.pings, 0);
  assert.equal(harness.terminations, 0);
  assert.equal(harness.cleared, false);
  harness.watchdog.stop();
});

test("application traffic also avoids redundant probes", () => {
  const harness = createHarness();
  for (let time = 10_000; time <= 120_000; time += 10_000) {
    harness.receiveAt(time - 1_000);
    harness.tickAt(time);
  }
  assert.equal(harness.pings, 0);
  assert.equal(harness.terminations, 0);
  harness.watchdog.stop();
});

test("quiet relays still get probed and their pong keeps the connection alive", () => {
  const harness = createHarness({ replyToPing: true });
  for (let time = 10_000; time <= 120_000; time += 10_000) harness.tickAt(time);
  assert.equal(harness.pings, 4);
  assert.equal(harness.terminations, 0);
  harness.watchdog.stop();
});

test("unanswered probes do not extend the original stale connection deadline", () => {
  const harness = createHarness();
  for (let time = 10_000; time <= 40_000; time += 10_000) harness.tickAt(time);
  assert.equal(harness.pings, 2);
  assert.equal(harness.terminations, 0);
  harness.tickAt(50_000);
  assert.equal(harness.terminations, 1);
  assert.equal(harness.staleNotifications, 1);
  assert.equal(harness.cleared, true);
  harness.tickAt(60_000);
  assert.equal(harness.terminations, 1);
});

test("a sleep/wake time jump terminates a zombie socket without waiting for a probe", () => {
  const harness = createHarness();
  harness.tickAt(300_000);
  assert.equal(harness.pings, 0);
  assert.equal(harness.terminations, 1);
  assert.equal(harness.staleNotifications, 1);
});

test("shutdown and superseded sockets stop probing without closing another connection", () => {
  for (const stopExplicitly of [false, true]) {
    const harness = createHarness();
    if (stopExplicitly) harness.watchdog.stop();
    else harness.shouldRun = false;
    harness.tickAt(60_000);
    assert.equal(harness.pings, 0);
    assert.equal(harness.terminations, 0);
    assert.equal(harness.cleared, true);
  }
});

test("closing sockets are left to the transport and ping errors terminate once", () => {
  const closing = createHarness();
  closing.socket.readyState = 2;
  closing.tickAt(60_000);
  assert.equal(closing.terminations, 0);
  closing.watchdog.stop();

  const failing = createHarness({ pingThrows: true });
  failing.tickAt(30_000);
  failing.tickAt(40_000);
  assert.equal(failing.terminations, 1);
  assert.equal(failing.staleNotifications, 0);
  assert.equal(failing.cleared, true);
});

function createHarness({ replyToPing = false, pingThrows = false } = {}) {
  let now = 0;
  let lastActivityAt = 0;
  let tick;
  const harness = {
    pings: 0,
    terminations: 0,
    staleNotifications: 0,
    cleared: false,
    shouldRun: true,
    receiveAt(time) { lastActivityAt = time; },
    tickAt(time) { now = time; tick(); },
  };
  harness.socket = {
    readyState: 1,
    ping() {
      if (pingThrows) throw new Error("socket closed during ping");
      harness.pings += 1;
      if (replyToPing) lastActivityAt = now;
    },
    terminate() { harness.terminations += 1; },
  };
  harness.watchdog = createRelayWatchdog({
    socket: harness.socket,
    getLastActivityAt: () => lastActivityAt,
    shouldRun: () => harness.shouldRun,
    onStale() { harness.staleNotifications += 1; },
    now: () => now,
    setIntervalFn(callback) { tick = callback; return { unref() {} }; },
    clearIntervalFn() { harness.cleared = true; },
  });
  return harness;
}
