// FILE: bridge-status.test.js
// Purpose: Verifies bridge status publisher behavior without loading the full bridge service.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/bridge-status

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  createBridgeStatusPublisher,
} = require("../src/bridge-status");

test("status publisher appends current Codex launch state to snapshots", () => {
  const published = [];
  let codexLaunchState = "starting";
  const publisher = createBridgeStatusPublisher({
    onBridgeStatus(status) {
      published.push(status);
    },
    getCodexLaunchState() {
      return codexLaunchState;
    },
  });

  publisher.publish({
    state: "running",
    connectionStatus: "connecting",
    pid: 123,
    lastError: "",
  });
  codexLaunchState = "connected";
  publisher.publish(publisher.latest());

  assert.deepEqual(published.map((status) => status.codexLaunchState), [
    "starting",
    "connected",
  ]);
});

test("status publisher heartbeat emits stale relay downgrade without mutating latest snapshot", async () => {
  const published = [];
  let now = 100_000;
  const publisher = createBridgeStatusPublisher({
    heartbeatIntervalMs: 1,
    now: () => now,
    onBridgeStatus(status) {
      published.push(status);
    },
    getCodexLaunchState() {
      return "connected";
    },
  });

  publisher.publish({
    state: "running",
    connectionStatus: "connected",
    pid: 123,
    lastError: "",
  });
  publisher.startHeartbeat({
    getLastRelayActivityAt: () => 1_000,
  });
  await new Promise((resolve) => setTimeout(resolve, 10));
  publisher.stopHeartbeat();

  assert.equal(published.at(-1).connectionStatus, "disconnected");
  assert.equal(publisher.latest().connectionStatus, "connected");
});
