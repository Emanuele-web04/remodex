// FILE: bridge.test.js
// Purpose: Verifies relay watchdog helpers used to recover from stale sleep/wake sockets.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/bridge

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createHash } = require("crypto");
const {
  buildHeartbeatBridgeStatus,
  createMacOSBridgeWakeAssertion,
  disableUnsupportedReasoningSummaryForTurnStart,
  hasRelayConnectionGoneStale,
  normalizeRelayBoundJsonRpcMessage,
  persistBridgePreferences,
  redactLogIdentifier,
  resolveJsonlTurnsListRolloutPathForFallback,
} = require("../src/bridge");

function expectedGeneratedImagePath(threadId, fileName) {
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  return path.join(codexHome, "generated_images", threadId, fileName);
}

test("hasRelayConnectionGoneStale returns true once the relay silence crosses the timeout", () => {
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
      now: 26_000,
      staleAfterMs: 25_000,
    }),
    true
  );
});

test("normalizeRelayBoundJsonRpcMessage rewrites payload-only responses to result", () => {
  const normalized = normalizeRelayBoundJsonRpcMessage(JSON.stringify({
    id: "req-payload-only",
    payload: {
      data: [{ id: "turn-1" }],
      nextCursor: null,
    },
  }));

  assert.deepEqual(JSON.parse(normalized), {
    id: "req-payload-only",
    result: {
      data: [{ id: "turn-1" }],
      nextCursor: null,
    },
  });
});

test("normalizeRelayBoundJsonRpcMessage unwraps nested app-server result payloads", () => {
  const normalized = normalizeRelayBoundJsonRpcMessage(JSON.stringify({
    id: "req-nested-payload",
    result: {
      payload: {
        data: [{ id: "thread-1" }],
        nextCursor: null,
      },
    },
  }));

  assert.deepEqual(JSON.parse(normalized), {
    id: "req-nested-payload",
    result: {
      payload: {
        data: [{ id: "thread-1" }],
        nextCursor: null,
      },
      data: [{ id: "thread-1" }],
      nextCursor: null,
    },
  });
});

test("normalizeRelayBoundJsonRpcMessage drops non-RPC relay payloads before iOS decode", () => {
  assert.equal(normalizeRelayBoundJsonRpcMessage("not-json"), null);
  assert.equal(normalizeRelayBoundJsonRpcMessage(JSON.stringify({ kind: "debug" })), null);
});

test("normalizeRelayBoundJsonRpcMessage drops client-origin RPC requests before iOS handles them", () => {
  assert.equal(
    normalizeRelayBoundJsonRpcMessage(JSON.stringify({
      id: "req-thread-list",
      method: "thread/list",
      params: {},
    })),
    null
  );
});

test("resolveJsonlTurnsListRolloutPathForFallback searches JSONL for stale non-empty first pages", () => {
  const calls = [];
  const rolloutPath = resolveJsonlTurnsListRolloutPathForFallback({
    threadId: "thread-jsonl-stale",
    responseIsEmpty: false,
    readCachedPath(threadId) {
      calls.push(["cache", threadId]);
      return "";
    },
    findAndCachePath(threadId) {
      calls.push(["find", threadId]);
      return "/tmp/thread-jsonl-stale.jsonl";
    },
  });

  assert.equal(rolloutPath, "/tmp/thread-jsonl-stale.jsonl");
  assert.deepEqual(calls, [
    ["cache", "thread-jsonl-stale"],
    ["find", "thread-jsonl-stale"],
  ]);
});

test("normalizeRelayBoundJsonRpcMessage converts tracked method-bearing responses for iOS", () => {
  const pendingRequestMethodsById = new Map([
    ["req-thread-list", {
      method: "thread/list",
      createdAt: Date.now(),
    }],
    ["req-turns-list", {
      method: "thread/turns/list",
      createdAt: Date.now(),
    }],
  ]);

  const threadListResponse = normalizeRelayBoundJsonRpcMessage(JSON.stringify({
    id: "req-thread-list",
    method: "thread/list",
    payload: {
      data: [{ id: "thread-1" }],
      nextCursor: null,
    },
  }), { pendingRequestMethodsById });

  assert.deepEqual(JSON.parse(threadListResponse), {
    id: "req-thread-list",
    result: {
      data: [{ id: "thread-1" }],
      nextCursor: null,
    },
  });

  const turnsListResponse = normalizeRelayBoundJsonRpcMessage(JSON.stringify({
    id: "req-turns-list",
    method: "thread/turns/list",
    result: {
      payload: {
        data: [{ id: "turn-1" }],
        nextCursor: null,
      },
    },
  }), { pendingRequestMethodsById });

  assert.deepEqual(JSON.parse(turnsListResponse), {
    id: "req-turns-list",
    result: {
      payload: {
        data: [{ id: "turn-1" }],
        nextCursor: null,
      },
      data: [{ id: "turn-1" }],
      nextCursor: null,
    },
  });
});

test("normalizeRelayBoundJsonRpcMessage keeps server-origin approval requests", () => {
  const raw = JSON.stringify({
    id: "approval-1",
    method: "item/fileChange/requestApproval",
    params: {
      threadId: "thread-1",
    },
  });

  assert.equal(normalizeRelayBoundJsonRpcMessage(raw), raw);
});

test("disableUnsupportedReasoningSummaryForTurnStart disables summaries for Codex Spark", () => {
  const raw = JSON.stringify({
    id: "req-turn-start",
    method: "turn/start",
    params: {
      threadId: "thread-1",
      model: "gpt-5.3-codex-spark",
      effort: "medium",
      input: [{ type: "text", text: "Ship it" }],
    },
  });

  const normalized = JSON.parse(disableUnsupportedReasoningSummaryForTurnStart(raw));

  assert.equal(normalized.params.model, "gpt-5.3-codex-spark");
  assert.equal(normalized.params.summary, "none");
});

test("disableUnsupportedReasoningSummaryForTurnStart detects plan-mode Codex Spark model", () => {
  const raw = JSON.stringify({
    id: "req-turn-start-plan",
    method: "turn/start",
    params: {
      threadId: "thread-1",
      input: [{ type: "text", text: "Plan it" }],
      collaborationMode: {
        mode: "plan",
        settings: {
          model: "gpt-5.3-codex-spark",
          reasoning_effort: "medium",
        },
      },
    },
  });

  const normalized = JSON.parse(disableUnsupportedReasoningSummaryForTurnStart(raw));

  assert.equal(normalized.params.summary, "none");
  assert.equal(normalized.params.collaborationMode.settings.model, "gpt-5.3-codex-spark");
});

test("disableUnsupportedReasoningSummaryForTurnStart leaves other models untouched", () => {
  const raw = JSON.stringify({
    id: "req-turn-start-gpt55",
    method: "turn/start",
    params: {
      threadId: "thread-1",
      model: "gpt-5.5",
      input: [{ type: "text", text: "Ship it" }],
    },
  });

  assert.equal(disableUnsupportedReasoningSummaryForTurnStart(raw), raw);
});

test("hasRelayConnectionGoneStale returns false for fresh or missing activity timestamps", () => {
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
      now: 25_999,
      staleAfterMs: 25_000,
    }),
    false
  );
  assert.equal(hasRelayConnectionGoneStale(Number.NaN), false);
});

test("hasRelayConnectionGoneStale default threshold waits 45 seconds", () => {
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
            now: 45_999,
    }),
    false
  );
  assert.equal(
    hasRelayConnectionGoneStale(1_000, {
            now: 46_000,
    }),
    true
  );
});

test("buildHeartbeatBridgeStatus downgrades stale connected snapshots", () => {
  assert.deepEqual(
    buildHeartbeatBridgeStatus(
      {
        state: "running",
        connectionStatus: "connected",
        pid: 123,
        lastError: "",
      },
      1_000,
      {
        now: 26_500,
        staleAfterMs: 25_000,
        staleMessage: "Relay heartbeat stalled; reconnect pending.",
      }
    ),
    {
      state: "running",
      connectionStatus: "disconnected",
      pid: 123,
      lastError: "Relay heartbeat stalled; reconnect pending.",
    }
  );
});

test("buildHeartbeatBridgeStatus leaves fresh or already-disconnected snapshots unchanged", () => {
  const freshStatus = {
    state: "running",
    connectionStatus: "connected",
    pid: 123,
    lastError: "",
  };
  assert.deepEqual(
    buildHeartbeatBridgeStatus(freshStatus, 1_000, {
      now: 20_000,
      staleAfterMs: 25_000,
    }),
    freshStatus
  );

  const disconnectedStatus = {
    state: "running",
    connectionStatus: "disconnected",
    pid: 123,
    lastError: "",
  };
  assert.deepEqual(buildHeartbeatBridgeStatus(disconnectedStatus, 1_000), disconnectedStatus);
});

function makeTurns(start, count) {
  return Array.from({ length: count }, (_, index) => ({
    id: `turn-${start + index}`,
    items: [
      {
        id: `item-${start + index}`,
        type: "assistant_message",
        text: `message ${start + index}`,
      },
    ],
  }));
}

test("createMacOSBridgeWakeAssertion spawns a macOS caffeinate idle-sleep assertion tied to the bridge pid", () => {
  const spawnCalls = [];
  const fakeChild = {
    killed: false,
    on() {},
    unref() {},
    kill() {
      this.killed = true;
    },
  };

  const assertion = createMacOSBridgeWakeAssertion({
    platform: "darwin",
    pid: 4242,
    spawnImpl(command, args, options) {
      spawnCalls.push({ command, args, options });
      return fakeChild;
    },
  });

  assert.equal(assertion.active, true);
  assert.deepEqual(spawnCalls, [{
    command: "/usr/bin/caffeinate",
    args: ["-i", "-w", "4242"],
    options: { stdio: "ignore" },
  }]);

  assertion.stop();
  assert.equal(fakeChild.killed, true);
});

test("createMacOSBridgeWakeAssertion can toggle the caffeinate assertion on and off live", () => {
  const spawnCalls = [];
  const children = [];

  const assertion = createMacOSBridgeWakeAssertion({
    platform: "darwin",
    pid: 9001,
    enabled: false,
    spawnImpl(command, args, options) {
      const child = {
        killed: false,
        on() {},
        unref() {},
        kill() {
          this.killed = true;
        },
      };
      children.push(child);
      spawnCalls.push({ command, args, options });
      return child;
    },
  });

  assert.equal(assertion.active, false);
  assert.equal(assertion.enabled, false);
  assert.deepEqual(spawnCalls, []);

  assertion.setEnabled(true);
  assert.equal(assertion.enabled, true);
  assert.equal(assertion.active, true);
  assert.equal(spawnCalls.length, 1);

  assertion.setEnabled(false);
  assert.equal(assertion.enabled, false);
  assert.equal(assertion.active, false);
  assert.equal(children[0].killed, true);
});

test("createMacOSBridgeWakeAssertion is a no-op outside macOS", () => {
  let didSpawn = false;
  const assertion = createMacOSBridgeWakeAssertion({
    platform: "linux",
    spawnImpl() {
      didSpawn = true;
      throw new Error("should not spawn");
    },
  });

  assert.equal(assertion.active, false);
  assertion.stop();
  assert.equal(didSpawn, false);
});

test("persistBridgePreferences only saves the daemon preference field", () => {
  const writes = [];

  persistBridgePreferences(
    { keepMacAwakeEnabled: false },
    {
      readDaemonConfigImpl() {
        return {
          relayUrl: "ws://127.0.0.1:9000/relay",
          refreshEnabled: true,
        };
      },
      writeDaemonConfigImpl(config) {
        writes.push(config);
      },
    }
  );

  assert.deepEqual(writes, [{
    relayUrl: "ws://127.0.0.1:9000/relay",
    refreshEnabled: true,
    keepMacAwakeEnabled: false,
  }]);
});

test("redactLogIdentifier hashes thread and turn ids unless verbose logging is enabled", () => {
  const previousVerbose = process.env.REMODEX_VERBOSE_LOGS;
  delete process.env.REMODEX_VERBOSE_LOGS;

  const threadId = "opencode-thread-1780887827406-786vaj";
  const expectedDigest = createHash("sha256").update(threadId).digest("hex").slice(0, 8);

  assert.equal(redactLogIdentifier(threadId, "thread"), `thread#${expectedDigest}`);
  assert.equal(redactLogIdentifier(null, "thread"), null);

  process.env.REMODEX_VERBOSE_LOGS = "1";
  assert.equal(redactLogIdentifier(threadId, "thread"), threadId);

  restoreEnvValue("REMODEX_VERBOSE_LOGS", previousVerbose);
});

function restoreEnvValue(name, previousValue) {
  if (previousValue === undefined) {
    delete process.env[name];
    return;
  }
  process.env[name] = previousValue;
}
