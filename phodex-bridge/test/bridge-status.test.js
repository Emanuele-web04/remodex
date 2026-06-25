// FILE: bridge-status.test.js
// Purpose: Verifies bridge status publisher behavior without loading the full bridge service.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/bridge-status

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  buildOpenCodeBridgeStatusSection,
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

test("buildOpenCodeBridgeStatusSection merges observability metrics", () => {
  const opencode = buildOpenCodeBridgeStatusSection({
    id: "opencode",
    getRuntimeStatus() {
      return {
        enabled: true,
        version: "2.1.0",
        sessionCount: 2,
        authConfigured: true,
      };
    },
    getObservabilityMetrics() {
      return {
        sseReconnectCount: 3,
        permissionPendingCount: 1,
        catalogRefreshMs: 42,
      };
    },
  });

  assert.equal(opencode.enabled, true);
  assert.equal(opencode.sessionCount, 2);
  assert.equal(opencode.sseReconnectCount, 3);
  assert.equal(opencode.permissionPendingCount, 1);
  assert.equal(opencode.catalogRefreshMs, 42);
});

test("status publisher heartbeat refreshes opencode observability metrics", async () => {
  const published = [];
  let metrics = { sseReconnectCount: 0, permissionPendingCount: 0, catalogRefreshMs: null };
  const publisher = createBridgeStatusPublisher({
    heartbeatIntervalMs: 1,
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
    opencode: {
      enabled: true,
      sseReconnectCount: 0,
      permissionPendingCount: 0,
      catalogRefreshMs: null,
    },
  });

  metrics = { sseReconnectCount: 2, permissionPendingCount: 1, catalogRefreshMs: 88 };
  publisher.startHeartbeat({
    getLastRelayActivityAt: () => Date.now(),
    refreshStatus: (status) => ({
      ...status,
      opencode: {
        ...status.opencode,
        ...metrics,
      },
    }),
  });
  await new Promise((resolve) => setTimeout(resolve, 10));
  publisher.stopHeartbeat();

  assert.equal(published.at(-1).opencode.sseReconnectCount, 2);
  assert.equal(published.at(-1).opencode.permissionPendingCount, 1);
  assert.equal(published.at(-1).opencode.catalogRefreshMs, 88);
  assert.equal(publisher.latest().opencode.sseReconnectCount, 0);
});

test("bridge status publisher accepts opencode subsection on publish payload", () => {
  const published = [];
  const publisher = createBridgeStatusPublisher({
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
    pid: 99,
    lastError: "",
    opencode: {
      enabled: true,
      version: "2.1.0",
      sessionCount: 3,
      authConfigured: true,
    },
  });

  assert.equal(published[0].opencode.enabled, true);
  assert.equal(published[0].opencode.sessionCount, 3);
  assert.equal(published[0].opencode.authConfigured, true);
});
