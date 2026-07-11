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
const {
  buildThreadTurnsListRelaySanitizeContext,
  buildHeartbeatBridgeStatus,
  canonicalThreadTurnsListRequest,
  createMacOSBridgeWakeAssertion,
  createThreadTurnsListFastPageCoordinator,
  disableUnsupportedReasoningSummaryForTurnStart,
  fetchAdaptiveThreadTurnsListForRelay,
  hasRelayConnectionGoneStale,
  maybeMergeLatestJsonlTurnIntoTurnsListResponse,
  normalizeRelayBoundJsonRpcMessage,
  persistBridgePreferences,
  resolveJsonlTurnsListRolloutPathForFallback,
  sanitizeLiveGeneratedImageMessageForRelay,
  sanitizeLiveUserNotification,
  isContextualUserItemNotification,
  sanitizeThreadHistoryImagesForRelay,
  shouldSuppressRolloutMirrorForThread,
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

test("rollout suppression follows the follower's current ownership signal", () => {
  let liveStateChecks = 0;
  const desktopIpcActionFollower = {
    hasLiveThreadState(threadId) {
      liveStateChecks += 1;
      return threadId === "thread-desktop-owned";
    },
  };

  assert.equal(shouldSuppressRolloutMirrorForThread(
    "thread-desktop-owned",
    { desktopIpcActionFollower }
  ), true);
  assert.equal(shouldSuppressRolloutMirrorForThread(
    "thread-unowned",
    { desktopIpcActionFollower }
  ), false);
  assert.equal(liveStateChecks, 2);
});

test("rollout suppression releases a stale Desktop owner so a growing rollout can mirror", () => {
  let receivedFallbackActivityAt = 0;
  const desktopIpcActionFollower = {
    hasLiveThreadState() {
      return true;
    },
    hasFreshLiveThreadState(_threadId, { fallbackActivityAt = 0 } = {}) {
      receivedFallbackActivityAt = fallbackActivityAt;
      return false;
    },
  };
  const desktopIpcLiveOwner = {
    isThreadOwned() {
      return true;
    },
    isFreshThreadOwned() {
      return false;
    },
  };

  assert.equal(shouldSuppressRolloutMirrorForThread(
    "thread-stale-desktop",
    { desktopIpcActionFollower, desktopIpcLiveOwner },
    { fallbackActivityAt: 1234 }
  ), false);
  assert.equal(receivedFallbackActivityAt, 1234);

  desktopIpcLiveOwner.isFreshThreadOwned = () => true;
  assert.equal(shouldSuppressRolloutMirrorForThread(
    "thread-fresh-desktop",
    { desktopIpcActionFollower, desktopIpcLiveOwner }
  ), true);
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

test("resolveJsonlTurnsListRolloutPathForFallback rescans after empty canonical responses", () => {
  const calls = [];
  const rolloutPath = resolveJsonlTurnsListRolloutPathForFallback({
    threadId: "thread-jsonl-cached-empty",
    responseIsEmpty: true,
    readCachedPath(threadId) {
      calls.push(["cache", threadId]);
      return "/tmp/thread-jsonl-cached-empty.jsonl";
    },
    findAndCachePath(threadId) {
      calls.push(["find", threadId]);
      return "/tmp/thread-jsonl-fresh-empty.jsonl";
    },
  });

  assert.equal(rolloutPath, "/tmp/thread-jsonl-fresh-empty.jsonl");
  assert.deepEqual(calls, [["find", "thread-jsonl-cached-empty"]]);
});

test("thread turns-list fast page returns JSONL once and reuses the late canonical page", async () => {
  let releaseDeadline = null;
  let resolveCanonical = null;
  let canonicalFetches = 0;
  const canonicalResponse = new Promise((resolve) => {
    resolveCanonical = resolve;
  });
  const coordinator = createThreadTurnsListFastPageCoordinator({
    createToken: () => "handoff-token",
    setTimeoutImpl(callback) {
      releaseDeadline = callback;
      return 1;
    },
    clearTimeoutImpl() {},
  });
  const request = {
    id: "req-fast-jsonl",
    method: "thread/turns/list",
    params: { threadId: "thread-fast-jsonl", limit: 1 },
  };
  const resolveOptions = {
    fetchCanonical: async () => {
      canonicalFetches += 1;
      return canonicalResponse;
    },
    readJsonl: async () => ({
      response: {
        id: request.id,
        result: {
          data: [{ id: "turn-jsonl", items: [{ id: "item-jsonl", type: "user_message", role: "user" }] }],
          nextCursor: "remodex-jsonl-fallback-older-unavailable",
          remodexJsonlFallback: true,
        },
      },
      usesJsonl: true,
    }),
  };

  const fastSelectionPromise = coordinator.resolve(request, resolveOptions);
  for (let attempt = 0; attempt < 10 && !releaseDeadline; attempt += 1) {
    await Promise.resolve();
  }
  assert.ok(releaseDeadline);
  releaseDeadline();
  const fastSelection = await fastSelectionPromise;

  assert.equal(fastSelection.source, "jsonl");
  assert.equal(fastSelection.usesJsonl, true);
  assert.equal(fastSelection.response.result.data[0].id, "turn-jsonl");
  assert.equal(
    fastSelection.response.result.nextCursor,
    "remodex-jsonl-handoff-v1:turn-jsonl:handoff-token"
  );
  assert.equal(fastSelection.response.result.remodexCanonicalHandoff, true);

  const canonicalSelectionPromise = coordinator.resolve({
    ...request,
    id: "req-canonical-reconcile",
    params: {
      ...request.params,
      remodexRequireCanonical: true,
    },
  }, resolveOptions);
  resolveCanonical({
    id: "bridge-internal-request",
    result: {
      data: [{ id: "turn-jsonl", items: [{ id: "item-canonical" }] }],
      nextCursor: "canonical-cursor",
    },
  });
  const canonicalSelection = await canonicalSelectionPromise;

  assert.equal(canonicalFetches, 1);
  assert.equal(canonicalSelection.source, "canonical");
  assert.equal(canonicalSelection.response.id, "req-canonical-reconcile");
  assert.equal(canonicalSelection.response.result.data[0].id, "turn-jsonl");
  assert.equal(canonicalSelection.response.result.nextCursor, "canonical-cursor");

  await coordinator.resolve({
    ...request,
    id: "req-consumed-handoff",
    params: {
      ...request.params,
      cursor: fastSelection.response.result.nextCursor,
    },
  }, resolveOptions);
  assert.equal(canonicalFetches, 2);
});

test("thread turns-list first-page singleflight isolates request shapes and rebinds response ids", async () => {
  const coordinator = createThreadTurnsListFastPageCoordinator();
  const canonicalFetches = [];
  const canonicalResolversByLimit = new Map();
  const options = {
    fetchCanonical: (canonicalRequest) => new Promise((resolve) => {
      const limit = canonicalRequest.params.limit;
      canonicalFetches.push({ id: canonicalRequest.id, limit });
      canonicalResolversByLimit.set(limit, resolve);
    }),
    readJsonl: async () => null,
  };
  const request = {
    id: "req-shape-limit-1-a",
    method: "thread/turns/list",
    params: { threadId: "thread-shared-shape", limit: 1 },
  };

  const limitOneFirst = coordinator.resolve(request, options);
  const limitEight = coordinator.resolve({
    ...request,
    id: "req-shape-limit-8",
    params: { ...request.params, limit: 8 },
  }, options);
  const limitOneSecond = coordinator.resolve({
    ...request,
    id: "req-shape-limit-1-b",
  }, options);

  assert.deepEqual(canonicalFetches, [
    { id: "req-shape-limit-1-a", limit: 1 },
    { id: "req-shape-limit-8", limit: 8 },
  ]);

  canonicalResolversByLimit.get(1)({
    id: "canonical-limit-1",
    result: {
      data: [{ id: "turn-limit-1", items: [] }],
      nextCursor: "cursor-after-limit-1",
    },
  });
  canonicalResolversByLimit.get(8)({
    id: "canonical-limit-8",
    result: {
      data: [
        { id: "turn-limit-8-a", items: [] },
        { id: "turn-limit-8-b", items: [] },
      ],
      nextCursor: "cursor-after-limit-8",
    },
  });

  const [firstSelection, eightSelection, secondSelection] = await Promise.all([
    limitOneFirst,
    limitEight,
    limitOneSecond,
  ]);
  assert.equal(firstSelection.response.id, "req-shape-limit-1-a");
  assert.equal(eightSelection.response.id, "req-shape-limit-8");
  assert.equal(secondSelection.response.id, "req-shape-limit-1-b");
  assert.equal(firstSelection.response.result.data.length, 1);
  assert.equal(secondSelection.response.result.data.length, 1);
  assert.equal(eightSelection.response.result.data.length, 2);
});

test("thread turns-list fast page keeps an immediate canonical response authoritative", async () => {
  let deadlineWasScheduled = false;
  const coordinator = createThreadTurnsListFastPageCoordinator({
    setTimeoutImpl() {
      deadlineWasScheduled = true;
      return 1;
    },
    clearTimeoutImpl() {},
  });
  const selection = await coordinator.resolve({
    id: "req-fast-canonical",
    method: "thread/turns/list",
    params: { threadId: "thread-fast-canonical", limit: 1 },
  }, {
    fetchCanonical: async () => ({
      id: "req-fast-canonical",
      result: {
        data: [{ id: "turn-canonical", items: [] }],
        nextCursor: null,
      },
    }),
    readJsonl: async () => ({
      response: {
        id: "req-fast-canonical",
        result: {
          data: [{ id: "turn-jsonl", items: [{ id: "jsonl-item", type: "user_message", role: "user" }] }],
          nextCursor: "remodex-jsonl-fallback-older-unavailable",
        },
      },
      usesJsonl: true,
    }),
  });

  assert.equal(deadlineWasScheduled, true);
  assert.equal(selection.source, "canonical");
  assert.equal(selection.response.result.data[0].id, "turn-canonical");
});

test("thread turns-list refuses an empty JSONL tail as a history baseline", async () => {
  const coordinator = createThreadTurnsListFastPageCoordinator();
  const selection = await coordinator.resolve({
    id: "req-empty-jsonl-tail",
    method: "thread/turns/list",
    params: { threadId: "thread-empty-jsonl-tail", limit: 5 },
  }, {
    fetchCanonical: async () => ({
      id: "canonical-empty-jsonl-tail",
      result: {
        data: [{ id: "turn-canonical", items: [{ id: "canonical-opener" }] }],
        nextCursor: null,
      },
    }),
    readJsonl: async () => ({
      response: {
        id: "req-empty-jsonl-tail",
        result: {
          data: [{ id: "turn-jsonl-tail", status: "running", items: [] }],
          nextCursor: "remodex-jsonl-fallback-older-unavailable",
        },
      },
      usesJsonl: true,
    }),
  });

  assert.equal(selection.source, "canonical");
  assert.equal(selection.response.result.data[0].id, "turn-canonical");
});

test("thread turns-list refuses an assistant and file-change-only running JSONL tail", async () => {
  const coordinator = createThreadTurnsListFastPageCoordinator();
  const selection = await coordinator.resolve({
    id: "req-artifact-jsonl-tail",
    method: "thread/turns/list",
    params: { threadId: "thread-artifact-jsonl-tail", limit: 5 },
  }, {
    fetchCanonical: async () => ({
      id: "canonical-artifact-jsonl-tail",
      result: {
        data: [{ id: "turn-canonical", items: [{ id: "canonical-user", type: "user_message", role: "user" }] }],
        nextCursor: null,
      },
    }),
    readJsonl: async () => ({
      response: {
        id: "req-artifact-jsonl-tail",
        result: {
          data: [{
            id: "turn-jsonl-tail",
            status: "running",
            items: [
              { id: "orphan-file-change", type: "file_change" },
              { id: "assistant-tail", type: "message", role: "assistant", text: "tail only" },
            ],
          }],
          nextCursor: "remodex-jsonl-fallback-older-unavailable",
        },
      },
      usesJsonl: true,
    }),
  });

  assert.equal(selection.source, "canonical");
  assert.equal(selection.response.result.data[0].id, "turn-canonical");
});

test("thread turns-list fast page prefers a newer running JSONL turn over stale canonical history", async () => {
  const coordinator = createThreadTurnsListFastPageCoordinator({
    createToken: () => "newer-jsonl-token",
    setTimeoutImpl: () => 1,
    clearTimeoutImpl() {},
  });
  const selection = await coordinator.resolve({
    id: "req-newer-jsonl",
    method: "thread/turns/list",
    params: { threadId: "thread-newer-jsonl", limit: 1 },
  }, {
    fetchCanonical: async () => ({
      id: "req-newer-jsonl",
      result: {
        data: [{ id: "turn-canonical-older", status: "completed", items: [] }],
        nextCursor: "cursor-after-canonical-older",
      },
    }),
    readJsonl: async () => ({
      response: {
        id: "req-newer-jsonl",
        result: {
          data: [{ id: "turn-jsonl-running", status: "running", items: [{ id: "jsonl-running-item", type: "user_message", role: "user" }] }],
          nextCursor: "remodex-jsonl-fallback-older-unavailable",
        },
      },
      usesJsonl: true,
    }),
  });

  assert.equal(selection.source, "jsonl");
  assert.equal(selection.response.result.data[0].id, "turn-jsonl-running");
  assert.equal(selection.response.result.remodexCanonicalHandoff, true);
});

test("thread turns-list handoff never returns newer canonical turns as older history", async () => {
  let releaseDeadline = null;
  let resolveCanonical = null;
  const canonicalResponse = new Promise((resolve) => {
    resolveCanonical = resolve;
  });
  const coordinator = createThreadTurnsListFastPageCoordinator({
    createToken: () => "anchor-token",
    setTimeoutImpl(callback) {
      releaseDeadline = callback;
      return 1;
    },
    clearTimeoutImpl() {},
  });
  const request = {
    id: "req-anchor-fast",
    method: "thread/turns/list",
    params: { threadId: "thread-anchor", limit: 1 },
  };
  const options = {
    fetchCanonical: async () => canonicalResponse,
    readJsonl: async () => ({
      response: {
        id: request.id,
        result: {
          data: [{ id: "turn-anchor", items: [{ id: "anchor-item", type: "user_message", role: "user" }] }],
          nextCursor: "remodex-jsonl-fallback-older-unavailable",
        },
      },
      usesJsonl: true,
    }),
  };

  const firstSelectionPromise = coordinator.resolve(request, options);
  for (let attempt = 0; attempt < 10 && !releaseDeadline; attempt += 1) {
    await Promise.resolve();
  }
  releaseDeadline();
  const firstSelection = await firstSelectionPromise;
  const handoffCursor = firstSelection.response.result.nextCursor;
  const olderSelectionPromise = coordinator.resolve({
    ...request,
    id: "req-anchor-older",
    params: { ...request.params, cursor: handoffCursor },
  }, options);

  resolveCanonical({
    id: "bridge-internal-anchor",
    result: {
      data: [
        { id: "turn-newer", items: [] },
        { id: "turn-anchor", items: [{ id: "canonical-anchor-item" }] },
        { id: "turn-older", items: [] },
      ],
      nextCursor: "cursor-after-older",
    },
  });
  const olderSelection = await olderSelectionPromise;

  assert.deepEqual(
    olderSelection.response.result.data.map((turn) => turn.id),
    ["turn-anchor", "turn-older"]
  );
  assert.equal(olderSelection.response.id, "req-anchor-older");
});

test("canonical reconciliation follows the canonical cursor until it reaches the JSONL anchor", async () => {
  let releaseDeadline = null;
  let resolveParkedCanonical = null;
  let canonicalFetches = 0;
  const parkedCanonical = new Promise((resolve) => {
    resolveParkedCanonical = resolve;
  });
  const coordinator = createThreadTurnsListFastPageCoordinator({
    createToken: () => "stale-anchor-token",
    setTimeoutImpl(callback) {
      releaseDeadline = callback;
      return 1;
    },
    clearTimeoutImpl() {},
  });
  const request = {
    id: "req-stale-anchor-fast",
    method: "thread/turns/list",
    params: { threadId: "thread-stale-anchor", limit: 1 },
  };
  const options = {
    fetchCanonical: async (canonicalRequest) => {
      canonicalFetches += 1;
      if (canonicalFetches === 1) {
        return parkedCanonical;
      }
      assert.equal(canonicalRequest.params.cursor, "cursor-to-jsonl-anchor");
      return {
        id: "fresh-canonical",
        result: {
          data: [{ id: "turn-jsonl-anchor", items: [{ id: "canonical-anchor" }] }],
          nextCursor: "cursor-after-jsonl-anchor",
        },
      };
    },
    readJsonl: async () => ({
      response: {
        id: request.id,
        result: {
          data: [{ id: "turn-jsonl-anchor", items: [{ id: "jsonl-anchor", type: "user_message", role: "user" }] }],
          nextCursor: "remodex-jsonl-fallback-older-unavailable",
        },
      },
      usesJsonl: true,
    }),
  };

  const firstSelectionPromise = coordinator.resolve(request, options);
  for (let attempt = 0; attempt < 10 && !releaseDeadline; attempt += 1) {
    await Promise.resolve();
  }
  releaseDeadline();
  await firstSelectionPromise;

  const reconcilePromise = coordinator.resolve({
    ...request,
    id: "req-stale-anchor-reconcile",
    params: { ...request.params, remodexRequireCanonical: true },
  }, options);
  resolveParkedCanonical({
    id: "stale-canonical",
    result: {
      data: [{ id: "turn-newer-than-jsonl-anchor", items: [] }],
      nextCursor: "cursor-to-jsonl-anchor",
    },
  });
  const reconciled = await reconcilePromise;

  assert.equal(canonicalFetches, 2);
  assert.equal(reconciled.response.id, "req-stale-anchor-reconcile");
  assert.deepEqual(
    reconciled.response.result.data.map((turn) => turn.id),
    ["turn-newer-than-jsonl-anchor", "turn-jsonl-anchor"]
  );
  assert.equal(reconciled.response.result.nextCursor, "cursor-after-jsonl-anchor");
});

test("canonical reconciliation compacts every turn through the anchor under the relay budget", async () => {
  let releaseDeadline = null;
  let resolveParkedCanonical = null;
  let canonicalFetches = 0;
  const payloadSoftLimitBytes = 1_200;
  const parkedCanonical = new Promise((resolve) => {
    resolveParkedCanonical = resolve;
  });
  const coordinator = createThreadTurnsListFastPageCoordinator({
    createToken: () => "oversized-anchor-token",
    payloadSoftLimitBytes,
    sanitizeForRelay: (rawMessage) => rawMessage,
    setTimeoutImpl(callback) {
      releaseDeadline = callback;
      return 1;
    },
    clearTimeoutImpl() {},
  });
  const request = {
    id: "req-oversized-anchor-fast",
    method: "thread/turns/list",
    params: { threadId: "thread-oversized-anchor", limit: 1 },
  };
  const largeText = "x".repeat(900);
  const options = {
    fetchCanonical: async (canonicalRequest) => {
      canonicalFetches += 1;
      if (canonicalFetches === 1) {
        return parkedCanonical;
      }
      assert.equal(canonicalRequest.params.cursor, "cursor-to-oversized-anchor");
      return {
        id: "oversized-anchor-page",
        result: {
          data: [{
            id: "turn-oversized-anchor",
            items: [{ id: "item-anchor", type: "agentMessage", text: largeText }],
          }],
          nextCursor: "cursor-after-oversized-anchor",
        },
      };
    },
    readJsonl: async () => ({
      response: {
        id: request.id,
        result: {
          data: [{ id: "turn-oversized-anchor", items: [{ id: "jsonl-anchor", type: "user_message", role: "user" }] }],
          nextCursor: "remodex-jsonl-fallback-older-unavailable",
        },
      },
      usesJsonl: true,
    }),
  };

  const firstSelectionPromise = coordinator.resolve(request, options);
  for (let attempt = 0; attempt < 10 && !releaseDeadline; attempt += 1) {
    await Promise.resolve();
  }
  releaseDeadline();
  await firstSelectionPromise;

  const reconcilePromise = coordinator.resolve({
    ...request,
    id: "req-oversized-anchor-reconcile",
    params: { ...request.params, remodexRequireCanonical: true },
  }, options);
  resolveParkedCanonical({
    id: "oversized-newer-page",
    result: {
      data: [{
        id: "turn-newer-than-oversized-anchor",
        items: [{ id: "item-newer", type: "agentMessage", text: largeText }],
      }],
      nextCursor: "cursor-to-oversized-anchor",
    },
  });
  const reconciled = await reconcilePromise;

  assert.equal(canonicalFetches, 2);
  assert.deepEqual(
    reconciled.response.result.data.map((turn) => turn.id),
    ["turn-newer-than-oversized-anchor", "turn-oversized-anchor"]
  );
  assert.equal(reconciled.response.result.nextCursor, "cursor-after-oversized-anchor");
  assert.equal(reconciled.response.result.remodexPageCompactedForRelay, true);
  assert.ok(Buffer.byteLength(JSON.stringify(reconciled.response), "utf8") < payloadSoftLimitBytes);
});

test("canonical reconciliation does not search forever for a synthetic JSONL anchor", async () => {
  let releaseDeadline = null;
  let resolveCanonical = null;
  let canonicalFetches = 0;
  const parkedCanonical = new Promise((resolve) => {
    resolveCanonical = resolve;
  });
  const coordinator = createThreadTurnsListFastPageCoordinator({
    createToken: () => "synthetic-anchor-token",
    setTimeoutImpl(callback) {
      releaseDeadline = callback;
      return 1;
    },
    clearTimeoutImpl() {},
  });
  const request = {
    id: "req-synthetic-anchor-fast",
    method: "thread/turns/list",
    params: { threadId: "thread-synthetic-anchor", limit: 1 },
  };
  const options = {
    fetchCanonical: async () => {
      canonicalFetches += 1;
      return parkedCanonical;
    },
    readJsonl: async () => ({
      response: {
        id: request.id,
        result: {
          data: [{ id: "turn-line-2048", items: [{ id: "jsonl-synthetic-item", type: "user_message", role: "user" }] }],
          nextCursor: "remodex-jsonl-fallback-older-unavailable",
        },
      },
      usesJsonl: true,
    }),
  };

  const firstSelectionPromise = coordinator.resolve(request, options);
  for (let attempt = 0; attempt < 10 && !releaseDeadline; attempt += 1) {
    await Promise.resolve();
  }
  releaseDeadline();
  const firstSelection = await firstSelectionPromise;
  const reconcilePromise = coordinator.resolve({
    ...request,
    id: "req-synthetic-anchor-reconcile",
    params: {
      ...request.params,
      cursor: firstSelection.response.result.nextCursor,
    },
  }, options);
  resolveCanonical({
    id: "canonical-synthetic-anchor-replacement",
    result: {
      data: [
        { id: "turn-real-latest", items: [{ id: "canonical-latest-item" }] },
        { id: "turn-real-older", items: [{ id: "canonical-older-item" }] },
      ],
      nextCursor: "cursor-after-real-older",
    },
  });
  const reconciled = await reconcilePromise;

  assert.equal(canonicalFetches, 1);
  assert.deepEqual(
    reconciled.response.result.data.map((turn) => turn.id),
    ["turn-real-latest", "turn-real-older"]
  );
  assert.equal(reconciled.response.result.nextCursor, "cursor-after-real-older");
});

test("canonical turns-list requests strip bridge-only handoff state", () => {
  const request = {
    id: "req-handoff-strip",
    method: "thread/turns/list",
    params: {
      threadId: "thread-handoff-strip",
      limit: 1,
      cursor: "remodex-jsonl-handoff-v1:token",
      remodexRequireCanonical: true,
      remodexTurnStateOnly: true,
    },
  };

  assert.deepEqual(canonicalThreadTurnsListRequest(request), {
    ...request,
    params: {
      threadId: "thread-handoff-strip",
      limit: 1,
    },
  });
  assert.equal(request.params.cursor, "remodex-jsonl-handoff-v1:token");
});

test("newer JSONL turns never displace the canonical cursor anchor at limit one", () => {
  const request = {
    id: "req-jsonl-newer-limit-one",
    method: "thread/turns/list",
    params: { threadId: "thread-jsonl-newer-limit-one", limit: 1 },
  };
  const merged = maybeMergeLatestJsonlTurnIntoTurnsListResponse(
    request,
    {
      id: request.id,
      result: {
        data: [{ id: "turn-canonical-anchor", status: "completed", items: [] }],
        nextCursor: "cursor-after-canonical-anchor",
      },
    },
    {
      data: [{ id: "turn-jsonl-newer", status: "running", items: [] }],
      nextCursor: "remodex-jsonl-fallback-older-unavailable",
    }
  );

  assert.deepEqual(
    merged.result.data.map((turn) => turn.id),
    ["turn-jsonl-newer", "turn-canonical-anchor"]
  );
  assert.equal(merged.result.nextCursor, "cursor-after-canonical-anchor");
  assert.equal(merged.result.remodexJsonlFallback, true);
  assert.equal(merged.result.remodexJsonlMergedLatest, true);
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

test("normalizeRelayBoundJsonRpcMessage accepts a pre-parsed passthrough envelope", () => {
  const parsedMessage = {
    method: "turn/completed",
    params: {
      threadId: "thread-preparsed",
      turnId: "turn-preparsed",
    },
  };
  const raw = JSON.stringify(parsedMessage);

  assert.equal(
    normalizeRelayBoundJsonRpcMessage(raw, { parsedMessage }),
    raw
  );
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

test("fetchAdaptiveThreadTurnsListForRelay caps initial mobile pages to five turns", async () => {
  const request = {
    id: "req-turns-list",
    method: "thread/turns/list",
    params: {
      threadId: "thread-small",
      limit: 20,
      sortDirection: "desc",
    },
  };
  const fetches = [];
  const pages = [
    {
      data: makeTurns(1, 1),
      nextCursor: "cursor-after-1",
      prevCursor: "cursor-before-1",
      stableMeta: "first-page",
    },
    {
      data: makeTurns(2, 4),
      nextCursor: "cursor-after-5",
      prevCursor: "cursor-before-2",
      stableMeta: "second-page",
    },
    { data: makeTurns(6, 15), nextCursor: "cursor-after-20", stableMeta: "third-page" },
  ];

  const response = await fetchAdaptiveThreadTurnsListForRelay(request, {
    fetchPage: async (params) => {
      fetches.push(params);
      return pages.shift();
    },
  });

  assert.equal(response.id, "req-turns-list");
  assert.equal(response.result.data.length, 5);
  assert.deepEqual(
    response.result.data.map((turn) => turn.id),
    makeTurns(1, 5).map((turn) => turn.id)
  );
  assert.equal(
    response.result.data.some((turn) => turn.id.startsWith("remodex-history-compacted-")),
    false
  );
  assert.equal(response.result.stableMeta, undefined);
  assert.equal(response.result.nextCursor, "cursor-after-5");
  assert.equal(response.result.prevCursor, "cursor-before-1");
  assert.deepEqual(
    fetches.map((params) => ({ limit: params.limit, cursor: params.cursor })),
    [
      { limit: 1, cursor: undefined },
      { limit: 4, cursor: "cursor-after-1" },
    ]
  );
});

test("fetchAdaptiveThreadTurnsListForRelay skips JSONL augmentation while sizing relay pages", async () => {
  const request = {
    id: "req-turns-list-sizing-context",
    method: "thread/turns/list",
    params: {
      threadId: "thread-sizing-context",
      limit: 1,
    },
  };
  const sanitizeContexts = [];

  const response = await fetchAdaptiveThreadTurnsListForRelay(request, {
    fetchPage: async () => ({ data: makeTurns(1, 1), nextCursor: null }),
    sanitizeForRelay: (rawMessage, requestMethod, requestContext) => {
      sanitizeContexts.push({ requestMethod, requestContext });
      return rawMessage;
    },
  });

  assert.equal(response.result.data.length, 1);
  assert.ok(sanitizeContexts.length > 0);
  assert.equal(sanitizeContexts.every(({ requestMethod }) => requestMethod === "thread/turns/list"), true);
  assert.equal(sanitizeContexts.every(({ requestContext }) => (
    requestContext.threadId === "thread-sizing-context"
      && requestContext.skipJsonlArtifactAugmentation === true
  )), true);
});

test("final thread turns-list relay sanitize context keeps JSONL artifact augmentation enabled", () => {
  const request = {
    id: "req-turns-list-final-context",
    method: "thread/turns/list",
    params: {
      threadId: "thread-final-context",
      limit: 1,
    },
  };

  assert.deepEqual(buildThreadTurnsListRelaySanitizeContext(request), {
    threadId: "thread-final-context",
    skipJsonlArtifactAugmentation: false,
  });
  assert.deepEqual(buildThreadTurnsListRelaySanitizeContext(request, {
    skipJsonlArtifactAugmentation: true,
  }), {
    threadId: "thread-final-context",
    skipJsonlArtifactAugmentation: true,
  });
});

test("fetchAdaptiveThreadTurnsListForRelay returns a compacted single turn when one huge first turn is still too large", async () => {
  const request = {
    id: "req-turns-list-large-first",
    method: "thread/turns/list",
    params: {
      threadId: "thread-large",
      limit: 20,
      sortDirection: "desc",
    },
  };
  const fetches = [];

  const response = await fetchAdaptiveThreadTurnsListForRelay(request, {
    fetchPage: async (params) => {
      fetches.push(params);
      return {
        data: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-1",
                type: "function_call_output",
                text: "A".repeat(4 * 1024 * 1024),
              },
            ],
          },
        ],
        nextCursor: "cursor-after-1",
      };
    },
    sanitizeForRelay: (raw) => raw,
    payloadSoftLimitBytes: 1_000,
  });

  assert.deepEqual(
    response.result.data.map((turn) => turn.id),
    ["turn-1"]
  );
  assert.equal(response.result.data[0].remodexEmergencySingleTurnForRelay, true);
  assert.equal(response.result.data[0].items.length, 1);
  assert.equal(response.result.data[0].items[0].relayPayloadTruncated, true);
  assert.equal(response.result.nextCursor, "cursor-after-1");
  assert.equal(Buffer.byteLength(JSON.stringify(response), "utf8") < 1_000, true);
  assert.equal(fetches.length, 1);
});

test("fetchAdaptiveThreadTurnsListForRelay stops after a huge second turns-list batch", async () => {
  const request = {
    id: "req-turns-list-large-second",
    method: "thread/turns/list",
    params: {
      threadId: "thread-mixed",
      limit: 20,
      sortDirection: "desc",
    },
  };
  const fetches = [];
  const pages = [
    { data: makeTurns(1, 1), nextCursor: "cursor-after-1" },
    {
      data: makeTurns(2, 4).map((turn) => ({
        ...turn,
        items: [
          {
            id: `${turn.id}-item`,
            type: "function_call_output",
            text: "B".repeat(1024 * 1024),
          },
        ],
      })),
      nextCursor: "cursor-after-5",
    },
  ];

  const response = await fetchAdaptiveThreadTurnsListForRelay(request, {
    fetchPage: async (params) => {
      fetches.push(params);
      return pages.shift();
    },
  });

  assert.deepEqual(
    response.result.data.map((turn) => turn.id),
    makeTurns(1, 5).map((turn) => turn.id)
  );
  assert.equal(response.result.nextCursor, "cursor-after-5");
  assert.deepEqual(
    fetches.map((params) => params.limit),
    [1, 4]
  );
});

test("fetchAdaptiveThreadTurnsListForRelay forwards input and returned cursors", async () => {
  const request = {
    id: "req-turns-list-older",
    method: "thread/turns/list",
    params: {
      threadId: "thread-large",
      limit: 6,
      sortDirection: "desc",
      cursor: "cursor-before-page",
    },
  };
  const fetches = [];
  const pages = [
    { items: makeTurns(1, 1), nextCursor: "cursor-after-first" },
    { items: makeTurns(2, 4), nextCursor: "cursor-after-second" },
    { items: makeTurns(6, 1), nextCursor: "cursor-after-third" },
  ];

  const response = await fetchAdaptiveThreadTurnsListForRelay(request, {
    fetchPage: async (params) => {
      fetches.push(params);
      return pages.shift();
    },
  });

  assert.equal(response.result.items.length, 5);
  assert.equal(response.result.nextCursor, "cursor-after-second");
  assert.deepEqual(
    fetches.map((params) => ({ limit: params.limit, cursor: params.cursor })),
    [
      { limit: 1, cursor: "cursor-before-page" },
      { limit: 4, cursor: "cursor-after-first" },
    ]
  );
});

test("fetchAdaptiveThreadTurnsListForRelay reads nested result payload pages", async () => {
  const response = await fetchAdaptiveThreadTurnsListForRelay({
    id: "req-turns-list-nested-payload",
    method: "thread/turns/list",
    params: {
      threadId: "thread-nested-payload",
      limit: 5,
    },
  }, {
    fetchPage: async () => ({
      payload: {
        data: makeTurns(1, 1),
        nextCursor: null,
      },
    }),
  });

  assert.deepEqual(
    response.result.data.map((turn) => turn.id),
    ["turn-1"]
  );
  assert.equal(response.result.nextCursor, null);
});

test("fetchAdaptiveThreadTurnsListForRelay preserves turns-list response array shapes", async () => {
  for (const turnsKey of ["data", "items", "turns"]) {
    const response = await fetchAdaptiveThreadTurnsListForRelay({
      id: `req-${turnsKey}`,
      method: "thread/turns/list",
      params: {
        threadId: `thread-${turnsKey}`,
        limit: 1,
      },
    }, {
      fetchPage: async () => ({
        [turnsKey]: makeTurns(1, 1),
        nextCursor: `cursor-${turnsKey}`,
      }),
    });

    assert.equal(Array.isArray(response.result[turnsKey]), true);
    assert.equal(response.result[turnsKey][0].id, "turn-1");
    for (const otherKey of ["data", "items", "turns"].filter((key) => key !== turnsKey)) {
      assert.equal(response.result[otherKey], undefined);
    }
    assert.equal(response.result.nextCursor, `cursor-${turnsKey}`);
  }
});

test("fetchAdaptiveThreadTurnsListForRelay returns fetched turns when a later batch fails", async () => {
  const response = await fetchAdaptiveThreadTurnsListForRelay({
    id: "req-turns-list-later-error",
    method: "thread/turns/list",
    params: {
      threadId: "thread-later-error",
      limit: 5,
    },
  }, {
    fetchPage: async (params) => {
      if (params.cursor === "cursor-after-first") {
        throw new Error("app-server failed");
      }
      return {
        data: makeTurns(1, 1),
        nextCursor: "cursor-after-first",
      };
    },
  });

  assert.deepEqual(
    response.result.data.map((turn) => turn.id),
    ["turn-1"]
  );
  assert.equal(response.result.nextCursor, "cursor-after-first");
});

test("fetchAdaptiveThreadTurnsListForRelay retries the first page with a safe limit after an error", async () => {
  const fetches = [];
  const response = await fetchAdaptiveThreadTurnsListForRelay({
    id: "req-turns-list-first-error",
    method: "thread/turns/list",
    params: {
      threadId: "thread-first-error",
      limit: 20,
      sortDirection: "desc",
    },
  }, {
    fetchPage: async (params) => {
      fetches.push(params);
      if (fetches.length === 1) {
        throw new Error("missing payload");
      }
      return {
        data: makeTurns(1, 5),
        nextCursor: "cursor-after-safe",
      };
    },
  });

  assert.deepEqual(
    response.result.data.map((turn) => turn.id),
    ["turn-1", "turn-2", "turn-3", "turn-4", "turn-5"]
  );
  assert.equal(response.result.nextCursor, "cursor-after-safe");
  assert.deepEqual(
    fetches.map((params) => ({ limit: params.limit, cursor: params.cursor })),
    [
      { limit: 1, cursor: undefined },
      { limit: 5, cursor: undefined },
    ]
  );
});

test("fetchAdaptiveThreadTurnsListForRelay retries malformed first pages with a safe limit", async () => {
  const fetches = [];
  const response = await fetchAdaptiveThreadTurnsListForRelay({
    id: "req-turns-list-first-malformed",
    method: "thread/turns/list",
    params: {
      threadId: "thread-first-malformed",
      limit: 20,
      sortDirection: "desc",
    },
  }, {
    fetchPage: async (params) => {
      fetches.push(params);
      if (fetches.length === 1) {
        return {
          unexpected: "server-shape",
          nextCursor: "cursor-that-should-not-survive",
        };
      }
      return {
        data: makeTurns(1, 5),
        nextCursor: "cursor-after-safe",
      };
    },
  });

  assert.deepEqual(
    response.result.data.map((turn) => turn.id),
    ["turn-1", "turn-2", "turn-3", "turn-4", "turn-5"]
  );
  assert.equal(response.result.nextCursor, "cursor-after-safe");
  assert.deepEqual(
    fetches.map((params) => ({ limit: params.limit, cursor: params.cursor })),
    [
      { limit: 1, cursor: undefined },
      { limit: 5, cursor: undefined },
    ]
  );
});

test("fetchAdaptiveThreadTurnsListForRelay stops at the previous cursor boundary when the next batch is too large", async () => {
  const response = await fetchAdaptiveThreadTurnsListForRelay({
    id: "req-turns-list-large-combined",
    method: "thread/turns/list",
    params: {
      threadId: "thread-large-combined",
      limit: 20,
    },
  }, {
    fetchPage: async (params) => {
      if (params.cursor !== "cursor-after-first") {
        return {
          data: makeTurns(1, 1),
          nextCursor: "cursor-after-first",
        };
      }
      return {
        data: makeTurns(2, 10).map((turn, index) => ({
          ...turn,
          items: turn.items.map((item) => ({
            ...item,
            text: index < 4 ? "small-enough" : "X".repeat(1024 * 1024),
          })),
        })),
        nextCursor: "cursor-after-large",
      };
    },
    sanitizeForRelay: (raw) => raw,
    payloadSoftLimitBytes: 10_000,
  });

  assert.deepEqual(
    response.result.data.map((turn) => turn.id),
    ["turn-1"]
  );
  assert.equal(response.result.nextCursor, "cursor-after-first");
});

test("fetchAdaptiveThreadTurnsListForRelay falls back to one turn when five are still too large", async () => {
  const response = await fetchAdaptiveThreadTurnsListForRelay({
    id: "req-turns-list-large-five",
    method: "thread/turns/list",
    params: {
      threadId: "thread-large-five",
      limit: 20,
    },
  }, {
    fetchPage: async (params) => {
      if (params.cursor !== "cursor-after-first") {
        return {
          data: makeTurns(1, 1),
          nextCursor: "cursor-after-first",
        };
      }
      return {
        data: makeTurns(2, 10).map((turn) => ({
          ...turn,
          items: turn.items.map((item) => ({
            ...item,
            text: "X".repeat(1024 * 1024),
          })),
        })),
        nextCursor: "cursor-after-large",
      };
    },
    sanitizeForRelay: (raw) => raw,
    payloadSoftLimitBytes: 2_000,
  });

  assert.deepEqual(
    response.result.data.map((turn) => turn.id),
    ["turn-1"]
  );
  assert.equal(response.result.nextCursor, "cursor-after-first");
});

test("fetchAdaptiveThreadTurnsListForRelay rejects when the first page has no payload", async () => {
  await assert.rejects(
    fetchAdaptiveThreadTurnsListForRelay({
      id: "req-turns-list-missing-payload",
      method: "thread/turns/list",
      params: {
        threadId: "thread-missing-payload",
        limit: 2,
        sortDirection: "desc",
      },
    }, {
      fetchPage: async () => null,
    }),
    /returned no turns array/
  );
});

test("fetchAdaptiveThreadTurnsListForRelay preserves a genuinely empty server page", async () => {
  const response = await fetchAdaptiveThreadTurnsListForRelay({
    id: "req-turns-list-genuinely-empty",
    method: "thread/turns/list",
    params: {
      threadId: "thread-genuinely-empty",
      limit: 10,
    },
  }, {
    fetchPage: async () => ({ data: [], nextCursor: null }),
  });

  assert.deepEqual(response, {
    id: "req-turns-list-genuinely-empty",
    result: {
      data: [],
      nextCursor: null,
    },
  });
});

test("fetchAdaptiveThreadTurnsListForRelay rejects a malformed page instead of fabricating empty history", async () => {
  await assert.rejects(
    fetchAdaptiveThreadTurnsListForRelay({
      id: "req-turns-list-malformed-object",
      method: "thread/turns/list",
      params: {
        threadId: "thread-malformed-object",
        limit: 10,
      },
    }, {
      fetchPage: async () => ({
        unexpected: { nested: ["server-shape"] },
        next_cursor: "cursor-that-should-not-survive",
      }),
    }),
    /returned no turns array/
  );
});

test("isContextualUserItemNotification drops only contextual live user items", () => {
  const contextualItem = {
    id: "ctx-item",
    type: "userMessage",
    content: [{
      type: "input_text",
      text: "# AGENTS.md instructions for /Users/me/proj\n<INSTRUCTIONS>rules</INSTRUCTIONS>",
    }],
  };
  const skillContextItem = {
    id: "skill-context-item",
    type: "userMessage",
    content: [{
      type: "input_text",
      text: [
        "<skill>",
        "<name>check-code</name>",
        "<path>$check-code</path>",
        "---",
        "name: check-code",
        "description: Review recent code changes across a repository.",
        "</skill>",
      ].join("\n"),
    }],
  };

  assert.equal(isContextualUserItemNotification({
    method: "item/started",
    params: { threadId: "t", item: contextualItem },
  }), true);
  assert.equal(isContextualUserItemNotification({
    method: "item/completed",
    params: { threadId: "t", item: contextualItem },
  }), true);
  assert.equal(isContextualUserItemNotification({
    method: "item/completed",
    params: { threadId: "t", item: skillContextItem },
  }), true);

  // Real prompts, assistant items, and other methods must pass through.
  assert.equal(isContextualUserItemNotification({
    method: "item/started",
    params: {
      threadId: "t",
      item: { id: "real", type: "userMessage", content: [{ type: "input_text", text: "ciao" }] },
    },
  }), false);
  assert.equal(isContextualUserItemNotification({
    method: "item/started",
    params: { threadId: "t", item: { id: "a", type: "agentMessage", text: "hi" } },
  }), false);
  assert.equal(isContextualUserItemNotification({
    method: "turn/started",
    params: { threadId: "t", item: contextualItem },
  }), false);
});

test("sanitizeLiveUserNotification filters fallback context and rewrites visible envelopes", () => {
  assert.equal(sanitizeLiveUserNotification({
    method: "codex/event/user_message",
    params: {
      threadId: "t",
      message: "<codex_internal_context source=\"goal\">secret</codex_internal_context>",
    },
  }), null);

  const heartbeat = sanitizeLiveUserNotification({
    method: "codex/event/user_message",
    params: {
      threadId: "t",
      message: "<heartbeat><automation_id>private</automation_id><instructions>Check CI.</instructions></heartbeat>",
    },
  });
  assert.equal(heartbeat.params.message, "Check CI.");

  const mixedItem = sanitizeLiveUserNotification({
    method: "item/completed",
    params: {
      threadId: "t",
      item: {
        id: "mixed",
        type: "userMessage",
        content: [
          { type: "input_text", text: "<environment_context>secret</environment_context>" },
          { type: "input_text", text: "keep me" },
          { type: "input_image", image_url: "data:image/png;base64,AAAA" },
        ],
      },
    },
  });
  assert.deepEqual(mixedItem.params.item.content, [
    { type: "input_text", text: "keep me" },
    { type: "input_image", image_url: "data:image/png;base64,AAAA" },
  ]);
});

test("sanitizeThreadHistoryImagesForRelay drops injected context user items from history", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-context",
    result: {
      thread: {
        id: "thread-context",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-agents",
                type: "message",
                role: "user",
                content: [{
                  type: "input_text",
                  text: "# AGENTS.md instructions for /Users/me/proj\n\n<INSTRUCTIONS>\nrules\n</INSTRUCTIONS>",
                }],
              },
              {
                id: "item-env",
                type: "message",
                role: "user",
                content: [{
                  type: "input_text",
                  text: "<environment_context>\n  <cwd>/Users/me/proj</cwd>\n</environment_context>",
                }],
              },
              {
                id: "item-skill",
                type: "message",
                role: "user",
                content: [{
                  type: "input_text",
                  text: [
                    "<skill>",
                    "<name>check-code</name>",
                    "<path>$check-code</path>",
                    "---",
                    "name: check-code",
                    "description: Review recent code changes across a repository.",
                    "</skill>",
                  ].join("\n"),
                }],
              },
              {
                id: "item-internal-goal",
                type: "message",
                role: "user",
                content: [{
                  type: "input_text",
                  text: "<codex_internal_context source=\"goal\">\nhidden goal state\n</codex_internal_context>",
                }],
              },
              {
                id: "item-real",
                type: "user_message",
                content: [{ type: "input_text", text: "minchia compa" }],
              },
              {
                id: "item-reply",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "Dimmi tutto" }],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const itemIds = sanitized.result.thread.turns[0].items.map((item) => item.id);
  assert.deepEqual(itemIds, ["item-real", "item-reply"]);
});

test("sanitizeThreadHistoryImagesForRelay sanitizes mixed user content entry-by-entry", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-mixed-context",
    result: {
      thread: {
        id: "thread-mixed-context",
        turns: [{
          id: "turn-1",
          items: [{
            id: "item-mixed",
            type: "user_message",
            content: [
              { type: "input_text", text: "<environment_context>secret</environment_context>" },
              {
                type: "input_text",
                text: "## Code review guidelines:\ninternal review text\n## My request for Codex:\nReview this file",
              },
              { type: "input_text", text: "<image name=[Image #1] path=\"/tmp/private.png\">" },
              { type: "input_image", image_url: "data:image/png;base64,AAAA" },
              { type: "input_text", text: "</image>" },
            ],
          }],
        }],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  assert.deepEqual(sanitized.result.thread.turns[0].items[0].content, [
    { type: "input_text", text: "Review this file" },
    { type: "input_image", url: "remodex://history-image-elided" },
  ]);
});

test("sanitizeThreadHistoryImagesForRelay replaces inline history images with lightweight references", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-read",
    result: {
      thread: {
        id: "thread-images",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-user",
                type: "user_message",
                content: [
                  {
                    type: "input_text",
                    text: "Look at this screenshot",
                  },
                  {
                    type: "image",
                    image_url: "data:image/png;base64,AAAA",
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const content = sanitized.result.thread.turns[0].items[0].content;

  assert.deepEqual(content[0], {
    type: "input_text",
    text: "Look at this screenshot",
  });
  assert.deepEqual(content[1], {
    type: "image",
    url: "remodex://history-image-elided",
  });
});

test("sanitizeThreadHistoryImagesForRelay replaces input_image history data URLs", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-input-image",
    result: {
      thread: {
        id: "thread-input-image",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-user",
                type: "user_message",
                content: [
                  {
                    type: "input_image",
                    image_url: {
                      url: "data:image/png;base64,AAAA",
                    },
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const content = sanitized.result.thread.turns[0].items[0].content;

  assert.deepEqual(content[0], {
    type: "input_image",
    url: "remodex://history-image-elided",
  });
});

test("sanitizeThreadHistoryImagesForRelay converts desktop apply_patch history to fileChange", () => {
  const patch = [
    "*** Begin Patch",
    "*** Update File: Sources/App.swift",
    "@@",
    "-let title = \"Old\"",
    "+let title = \"New\"",
    "*** End Patch",
    "",
  ].join("\n");
  const rawMessage = JSON.stringify({
    id: "req-thread-patch",
    result: {
      thread: {
        id: "thread-patch",
        turns: [
          {
            id: "turn-patch",
            items: [
              {
                id: "call-patch",
                type: "custom_tool_call",
                status: "completed",
                name: "apply_patch",
                call_id: "call-patch",
                input: patch,
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(item.type, "fileChange");
  assert.equal(item.id, "call-patch");
  assert.deepEqual(item.changes.map((change) => ({
    path: change.path,
    kind: change.kind,
    additions: change.additions,
    deletions: change.deletions,
  })), [{
    path: "Sources/App.swift",
    kind: "update",
    additions: 1,
    deletions: 1,
  }]);
});

test("sanitizeThreadHistoryImagesForRelay restores JSONL context without moving server-only findings", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-context-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-context";
  const turnId = "turn-jsonl-context";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "07", "05");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-07-05T17-40-00-${threadId}.jsonl`),
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "task_started",
          turn_id: turnId,
        },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "user_message",
          turn_id: turnId,
          message: "fix the completed-open history",
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "exec_command",
          call_id: "call-jsonl-context-command",
          arguments: JSON.stringify({ cmd: "git diff --check" }),
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          id: "server-final-context",
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "Done." }],
        },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "task_complete",
          turn_id: turnId,
        },
      }),
    ].join("\n"),
    "utf8"
  );

  const sanitized = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-thread-jsonl-context",
    result: {
      thread: {
        id: threadId,
        turns: [
          {
            id: turnId,
            items: [
              {
                id: "server-finding-context",
                type: "reviewFinding",
                text: "Keep this finding in its server position.",
              },
              {
                id: "server-final-context",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "Done." }],
              },
            ],
          },
        ],
      },
    },
  }), "thread/read"));

  const items = sanitized.result.thread.turns[0].items;
  assert.deepEqual(items.map((item) => item.type), [
    "user_message",
    "commandExecution",
    "reviewFinding",
    "message",
  ]);
  assert.equal(items[0].text, "fix the completed-open history");
  assert.equal(items[1].command, "git diff --check");
  assert.equal(items[2].id, "server-finding-context");
  assert.equal(items[3].id, "server-final-context");
});

test("sanitizeThreadHistoryImagesForRelay reconciles fallback ids without collapsing repeated occurrences", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-fallback-ids-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-fallback-identities";
  const turnId = "turn-jsonl-fallback-identities";
  const repeatedAssistantText = "Still checking the same operation.";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "07", "08");
  fs.mkdirSync(sessionsDir, { recursive: true });
  const rolloutPath = path.join(
    sessionsDir,
    `rollout-2026-07-08T20-00-00-${threadId}.jsonl`
  );
  fs.writeFileSync(
    rolloutPath,
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "task_started", turn_id: turnId },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "user_message",
          turn_id: turnId,
          message: "same prompt",
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "custom_tool_call",
          name: "apply_patch",
          input: [
            "*** Begin Patch",
            "*** Update File: Sources/App.swift",
            "@@",
            "-old",
            "+new",
            "*** End Patch",
          ].join("\n"),
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "exec_command",
          call_id: "server-command-real",
          arguments: JSON.stringify({ cmd: "git status" }),
        },
      }),
      ...Array.from({ length: 3 }, () => JSON.stringify({
        type: "response_item",
        payload: {
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: repeatedAssistantText }],
        },
      })),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "task_complete", turn_id: turnId },
      }),
    ].join("\n"),
    "utf8"
  );
  const rolloutContent = fs.readFileSync(rolloutPath, "utf8");
  const repeatedTextMarker = JSON.stringify(repeatedAssistantText);
  let repeatedTextOffset = -1;
  let repeatedTextSearchStart = 0;
  for (let occurrence = 0; occurrence < 3; occurrence += 1) {
    repeatedTextOffset = rolloutContent.indexOf(repeatedTextMarker, repeatedTextSearchStart);
    repeatedTextSearchStart = repeatedTextOffset + repeatedTextMarker.length;
  }
  const thirdAssistantLineStart = rolloutContent.lastIndexOf("\n", repeatedTextOffset) + 1;
  const thirdAssistantByteOffset = Buffer.byteLength(
    rolloutContent.slice(0, thirdAssistantLineStart),
    "utf8"
  );

  const sanitized = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-thread-jsonl-fallback-identities",
    result: {
      thread: {
        id: threadId,
        turns: [{
          id: turnId,
          items: [
            {
              id: "server-user-real",
              type: "user_message",
              role: "user",
              text: "same prompt",
            },
            {
              id: "server-patch-real",
              type: "fileChange",
              status: "completed",
              changes: [{
                path: "Sources/App.swift",
                kind: "update",
                additions: 1,
                deletions: 1,
              }],
            },
            {
              id: "server-assistant-one",
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: repeatedAssistantText }],
            },
            {
              id: "server-command-real",
              type: "commandExecution",
              command: "git status",
            },
            {
              id: "server-assistant-two",
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: repeatedAssistantText }],
            },
          ],
        }],
      },
    },
  }), "thread/read"));

  const items = sanitized.result.thread.turns[0].items;
  assert.deepEqual(items.map((item) => item.id), [
    "server-user-real",
    "server-patch-real",
    "server-assistant-one",
    "server-command-real",
    "server-assistant-two",
    `response-item-line-${thirdAssistantByteOffset}`,
  ]);
  assert.equal(items.filter((item) => item.role === "assistant").length, 3);
  assert.equal(items.some((item) => item.id?.startsWith("user-message-line-")), false);
  assert.equal(items.some((item) => item.id?.startsWith("apply-patch-line-")), false);
});

// A live-owned turn keys assistant replies by app-server event id (item_N)
// while the rollout records the provider id (msg_...). The augment pass must
// fold the two stable identities into one row and carry the JSONL source
// alias onto it so the phone can join later cross-source representations.
test("sanitizeThreadHistoryImagesForRelay folds live-owner assistant ids into JSONL provider rows", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-live-owner-ids-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-live-owner-identities";
  const turnId = "turn-live-owner-identities";
  const assistantText = "The change set is substantial: tracing the new contracts.";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "07", "11");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-07-11T15-55-04-${threadId}.jsonl`),
    [
      JSON.stringify({ type: "session_meta", payload: { id: threadId } }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "task_started", turn_id: turnId },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "user_message", turn_id: turnId, message: "review my changes" },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          id: "msg_rollout_provider_identity",
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: assistantText }],
        },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: { type: "task_complete", turn_id: turnId },
      }),
    ].join("\n"),
    "utf8"
  );

  const sanitized = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-thread-live-owner-identities",
    result: {
      thread: {
        id: threadId,
        turns: [{
          id: turnId,
          status: "inProgress",
          items: [
            {
              id: `${turnId}:input`,
              type: "userMessage",
              content: [{ type: "text", text: "review my changes" }],
            },
            { id: "item_0", type: "agentMessage", text: assistantText },
          ],
        }],
      },
    },
  }), "thread/read"));

  const items = sanitized.result.thread.turns[0].items;
  const assistantItems = items.filter((item) => (
    (item.role || "").toLowerCase() === "assistant"
      || (item.type || "").toLowerCase().replace(/[_-]/g, "") === "agentmessage"
  ));
  assert.equal(assistantItems.length, 1);
  assert.equal(assistantItems[0].id, "item_0");
  assert.equal(
    typeof assistantItems[0].remodexSourceItemKey,
    "string",
    "the folded row must adopt the JSONL turn+text source alias"
  );
  assert.equal(assistantItems[0].remodexSourceItemKey.startsWith(`${turnId}:`), true);
});

test("sanitizeThreadHistoryImagesForRelay augments app-server history with JSONL fileChange blocks", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-filechange";
  const turnId = "turn-jsonl-filechange";
  const cwd = "/Users/test/Project";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-05-19T19-40-00-${threadId}.jsonl`),
    [
      JSON.stringify({
        type: "session_meta",
        payload: {
          id: threadId,
          cwd,
        },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "task_started",
          turn_id: turnId,
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "custom_tool_call",
          status: "completed",
          name: "apply_patch",
          call_id: "call-jsonl-patch",
          input: [
            "*** Begin Patch",
            `*** Update File: ${cwd}/Sources/App.swift`,
            "@@",
            "-let title = \"Old\"",
            "+let title = \"New\"",
            "*** End Patch",
            "",
          ].join("\n"),
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          id: "assistant-jsonl",
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "Done." }],
        },
      }),
    ].join("\n"),
    "utf8"
  );

  const rawMessage = JSON.stringify({
    id: "req-thread-jsonl",
    result: {
      thread: {
        id: threadId,
        turns: [
          {
            id: turnId,
            items: [
              {
                id: "assistant-jsonl",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "Done." }],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const items = sanitized.result.thread.turns[0].items;

  assert.equal(sanitized.result.thread.cwd, cwd);
  assert.equal(sanitized.result.thread.current_working_directory, cwd);
  assert.equal(items.length, 2);
  assert.equal(items[0].type, "fileChange");
  assert.equal(items[1].id, "assistant-jsonl");
  assert.deepEqual(items[0].changes.map((change) => ({
    path: change.path,
    kind: change.kind,
    additions: change.additions,
    deletions: change.deletions,
  })), [{
    path: "Sources/App.swift",
    kind: "update",
    additions: 1,
    deletions: 1,
  }]);

  const turnsPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-turns-jsonl",
    result: {
      threadId,
      data: [
        {
          id: turnId,
          items: [
            {
              id: "assistant-jsonl-page",
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: "Done." }],
            },
          ],
        },
      ],
    },
  }), "thread/turns/list"));

  assert.equal(turnsPage.result.data[0].items.length, 2);
  assert.equal(turnsPage.result.data[0].items[0].type, "fileChange");

  const hintedTurnsPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-turns-jsonl-hinted",
    result: {
      data: [
        {
          id: turnId,
          items: [
            {
              id: "assistant-jsonl-page-hinted",
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: "Done." }],
            },
          ],
        },
      ],
    },
  }), "thread/turns/list", { threadId }));

  assert.equal(hintedTurnsPage.result.data[0].items.length, 2);
  assert.equal(hintedTurnsPage.result.data[0].items[0].type, "fileChange");

  const interruptedTurn = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-thread-jsonl-interrupted",
    result: {
      thread: {
        id: threadId,
        turns: [{
          id: turnId,
          status: "aborted",
          items: [{
            id: "interrupted-finding",
            type: "reviewFinding",
            text: "The run stopped before a final answer.",
          }],
        }],
      },
    },
  }), "thread/read"));
  assert.deepEqual(
    interruptedTurn.result.thread.turns[0].items.map((item) => item.type),
    ["reviewFinding", "fileChange"]
  );

  const invertedServerOrder = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-thread-jsonl-inverted",
    result: {
      thread: {
        id: threadId,
        turns: [{
          id: turnId,
          items: [
            {
              id: "assistant-jsonl",
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: "Done." }],
            },
            {
              id: "call-jsonl-patch",
              type: "fileChange",
              changes: [{ path: "Sources/App.swift", kind: "update" }],
            },
          ],
        }],
      },
    },
  }), "thread/read"));
  assert.deepEqual(
    invertedServerOrder.result.thread.turns[0].items.map((item) => item.id),
    ["assistant-jsonl", "call-jsonl-patch"]
  );

  const skippedTurnsPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-turns-jsonl-skip",
    result: {
      data: [
        {
          id: turnId,
          items: [
            {
              id: "assistant-jsonl-page-skip",
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: "Done." }],
            },
          ],
        },
      ],
    },
  }), "thread/turns/list", {
    threadId,
    skipJsonlArtifactAugmentation: true,
  }));

  assert.equal(skippedTurnsPage.result.data[0].items.length, 1);
});

test("sanitizeThreadHistoryImagesForRelay caches JSONL artifact scans until the rollout changes", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-cache-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  const originalOpenSync = fs.openSync;
  t.after(() => {
    fs.openSync = originalOpenSync;
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-cache";
  const firstTurnId = "turn-jsonl-cache-one";
  const secondTurnId = "turn-jsonl-cache-two";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  const rolloutPath = path.join(sessionsDir, `rollout-2026-05-19T19-40-00-${threadId}.jsonl`);
  fs.mkdirSync(sessionsDir, { recursive: true });

  const buildPatchCall = (turnId, callId, fileName) => [
    JSON.stringify({
      type: "event_msg",
      payload: {
        type: "task_started",
        turn_id: turnId,
      },
    }),
    JSON.stringify({
      type: "response_item",
      payload: {
        type: "custom_tool_call",
        status: "completed",
        name: "apply_patch",
        call_id: callId,
        input: [
          "*** Begin Patch",
          `*** Update File: Sources/${fileName}`,
          "@@",
          "-let title = \"Old\"",
          "+let title = \"New\"",
          "*** End Patch",
          "",
        ].join("\n"),
      },
    }),
    JSON.stringify({
      type: "response_item",
      payload: {
        id: `${turnId}-final`,
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "Done." }],
      },
    }),
  ].join("\n");

  fs.writeFileSync(
    rolloutPath,
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId },
      }),
      buildPatchCall(firstTurnId, "call-jsonl-cache-one", "One.swift"),
    ].join("\n"),
    "utf8"
  );

  let rolloutReads = 0;
  fs.openSync = function openSyncWithRolloutCounter(filePath, ...args) {
    if (path.resolve(String(filePath)) === rolloutPath) {
      rolloutReads += 1;
    }
    return originalOpenSync.call(this, filePath, ...args);
  };

  const makeTurnsPage = (turnId, requestId) => JSON.stringify({
    id: requestId,
    result: {
      threadId,
      data: [
        {
          id: turnId,
          items: [
            {
              id: `${turnId}-final`,
              type: "message",
              role: "assistant",
              content: [{ type: "output_text", text: "Done." }],
            },
          ],
        },
      ],
    },
  });

  const firstPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(
    makeTurnsPage(firstTurnId, "req-jsonl-cache-one"),
    "thread/turns/list"
  ));
  const secondPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(
    makeTurnsPage(firstTurnId, "req-jsonl-cache-two"),
    "thread/turns/list"
  ));

  assert.equal(firstPage.result.data[0].items[0].type, "fileChange");
  assert.equal(secondPage.result.data[0].items[0].type, "fileChange");
  assert.equal(rolloutReads, 1);

  fs.appendFileSync(
    rolloutPath,
    `\n${buildPatchCall(secondTurnId, "call-jsonl-cache-two", "Two.swift")}`,
    "utf8"
  );

  const changedPage = JSON.parse(sanitizeThreadHistoryImagesForRelay(
    makeTurnsPage(secondTurnId, "req-jsonl-cache-three"),
    "thread/turns/list"
  ));

  assert.equal(changedPage.result.data[0].items[0].type, "fileChange");
  assert.equal(changedPage.result.data[0].items[0].changes[0].path, "Sources/Two.swift");
  assert.equal(rolloutReads, 2);
});

test("sanitizeThreadHistoryImagesForRelay lazily restores artifacts for an older cursor turn", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-older-artifact-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-older-artifact";
  const oldTurnId = "turn-jsonl-oldest";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "07", "09");
  fs.mkdirSync(sessionsDir, { recursive: true });
  const lines = [
    JSON.stringify({ type: "session_meta", payload: { id: threadId } }),
    JSON.stringify({ type: "event_msg", payload: { type: "task_started", turn_id: oldTurnId } }),
    JSON.stringify({ type: "event_msg", payload: { type: "user_message", message: "Keep the old plan" } }),
    JSON.stringify({
      type: "response_item",
      payload: {
        type: "function_call",
        name: "update_plan",
        call_id: "call-old-plan",
        arguments: JSON.stringify({
          explanation: "Old exact plan",
          plan: [{ step: "Preserve this old row", status: "completed" }],
        }),
      },
    }),
    JSON.stringify({
      type: "response_item",
      payload: {
        type: "function_call_output",
        call_id: "huge-old-output",
        output: "Z".repeat(4_500_000),
      },
    }),
    JSON.stringify({ type: "event_msg", payload: { type: "task_complete", turn_id: oldTurnId } }),
  ];
  for (let index = 1; index <= 5; index += 1) {
    lines.push(
      JSON.stringify({ type: "event_msg", payload: { type: "task_started", turn_id: `turn-recent-${index}` } }),
      JSON.stringify({ type: "event_msg", payload: { type: "user_message", message: `Recent ${index}` } }),
      JSON.stringify({
        type: "response_item",
        payload: {
          id: `assistant-recent-${index}`,
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: `Done ${index}` }],
        },
      }),
      JSON.stringify({ type: "event_msg", payload: { type: "task_complete", turn_id: `turn-recent-${index}` } })
    );
  }
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-07-09T00-00-00-${threadId}.jsonl`),
    lines.join("\n"),
    "utf8"
  );

  const sanitized = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-old-artifact-page",
    result: {
      data: [{
        id: oldTurnId,
        items: [{
          id: "assistant-old-server",
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "Old answer" }],
        }],
      }],
      nextCursor: null,
    },
  }), "thread/turns/list", { threadId }));

  assert.equal(sanitized.result.data[0].items[0].type, "plan");
  assert.equal(sanitized.result.data[0].items[0].remodexJsonlProgressPlan, true);
  assert.equal(sanitized.result.data[0].items.at(-1).id, "assistant-old-server");
});

test("sanitizeThreadHistoryImagesForRelay restores JSONL update_plan as progress plan history", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-plan-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-plan";
  const turnId = "turn-jsonl-plan";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-05-19T19-41-00-${threadId}.jsonl`),
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "task_started",
          turn_id: turnId,
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "update_plan",
          call_id: "call-jsonl-plan-old",
          arguments: JSON.stringify({
            explanation: "Initial plan.",
            plan: [
              { step: "Inspect plan rendering", status: "in_progress" },
              { step: "Patch the bridge", status: "pending" },
            ],
          }),
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "update_plan",
          call_id: "call-jsonl-plan",
          arguments: JSON.stringify({
            explanation: "Keep the plan visible.",
            plan: [
              { step: "Inspect plan rendering", status: "completed" },
              { step: "Patch the bridge", status: "in_progress" },
            ],
          }),
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          id: "assistant-jsonl-plan",
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "Done." }],
        },
      }),
    ].join("\n"),
    "utf8"
  );

  const rawMessage = JSON.stringify({
    id: "req-thread-jsonl-plan",
    result: {
      thread: {
        id: threadId,
        turns: [
          {
            id: turnId,
            items: [
              {
                id: `todo-list-${turnId}`,
                type: "todo-list",
                text: "Initial plan.",
                explanation: "Initial plan.",
                plan: [
                  { step: "Inspect plan rendering", status: "in_progress" },
                  { step: "Patch the bridge", status: "pending" },
                ],
                remodexProgressPlan: true,
              },
              {
                id: "assistant-jsonl-plan",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "Done." }],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const items = sanitized.result.thread.turns[0].items;

  assert.equal(items.length, 2);
  assert.equal(items[0].type, "todo-list");
  assert.equal(items[0].id, `todo-list-${turnId}`);
  assert.equal(items[0].remodexJsonlProgressPlan, true);
  assert.equal(items[0].remodexProgressPlan, true);
  assert.equal(items[0].explanation, "Keep the plan visible.");
  assert.deepEqual(items[0].plan, [
    { step: "Inspect plan rendering", status: "completed" },
    { step: "Patch the bridge", status: "in_progress" },
  ]);
  assert.equal(items[1].id, "assistant-jsonl-plan");
});

test("sanitizeThreadHistoryImagesForRelay restores JSONL view_image output previews", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-jsonl-image-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-image";
  const turnId = "turn-jsonl-image";
  const imagePath = "/Users/test/Library/Application Support/CleanShot/media/screenshot.png";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-05-19T19-42-00-${threadId}.jsonl`),
    [
      JSON.stringify({
        type: "session_meta",
        payload: { id: threadId },
      }),
      JSON.stringify({
        type: "event_msg",
        payload: {
          type: "task_started",
          turn_id: turnId,
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call",
          name: "view_image",
          call_id: "call-jsonl-image",
          arguments: JSON.stringify({ path: imagePath }),
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          type: "function_call_output",
          call_id: "call-jsonl-image",
          output: [
            {
              type: "input_image",
              image_url: "data:image/png;base64,AAAA",
            },
          ],
        },
      }),
      JSON.stringify({
        type: "response_item",
        payload: {
          id: "assistant-jsonl-image",
          type: "message",
          role: "assistant",
          content: [{ type: "output_text", text: "I opened it." }],
        },
      }),
    ].join("\n"),
    "utf8"
  );

  const rawMessage = JSON.stringify({
    id: "req-thread-jsonl-image",
    result: {
      thread: {
        id: threadId,
        turns: [
          {
            id: turnId,
            items: [
              {
                id: "assistant-jsonl-image",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "I opened it." }],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const items = sanitized.result.thread.turns[0].items;

  assert.equal(items.length, 3);
  assert.equal(items[0].type, "tool_call");
  assert.equal(items[0].message, "Open image …/media/screenshot.png");
  assert.equal(items[1].type, "imageView");
  assert.equal(items[1].path, imagePath);
  assert.equal(items[1].remodexJsonlToolOutputImage, true);
  assert.equal(Object.hasOwn(items[1], "output"), false);
  assert.equal(items[2].type, "message");
});

test("sanitizeThreadHistoryImagesForRelay restores JSONL cwd without file changes", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-cwd-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-cwd";
  const cwd = "/Users/test/Project";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  fs.mkdirSync(sessionsDir, { recursive: true });
  fs.writeFileSync(
    path.join(sessionsDir, `rollout-2026-05-19T19-45-00-${threadId}.jsonl`),
    JSON.stringify({
      type: "session_meta",
      payload: {
        id: threadId,
        cwd,
      },
    }),
    "utf8"
  );

  const sanitized = JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-thread-cwd",
    result: {
      thread: {
        id: threadId,
        cwd: "/tmp/stale",
        turns: [
          {
            id: "turn-cwd",
            items: [
              {
                id: "assistant-cwd",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "Done." }],
              },
            ],
          },
        ],
      },
    },
  }), "thread/read"));

  assert.equal(sanitized.result.thread.cwd, cwd);
  assert.equal(sanitized.result.thread.current_working_directory, cwd);
  assert.equal(sanitized.result.thread.turns[0].items.length, 1);
});

test("sanitizeThreadHistoryImagesForRelay refreshes JSONL cwd when a newer same-thread rollout appears", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-history-cwd-newer-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const threadId = "thread-jsonl-cwd-newer";
  const sessionsDir = path.join(codexHome, "sessions", "2026", "05", "19");
  fs.mkdirSync(sessionsDir, { recursive: true });

  const writeRollout = (fileName, cwd, mtime) => {
    const rolloutPath = path.join(sessionsDir, fileName);
    fs.writeFileSync(
      rolloutPath,
      JSON.stringify({
        type: "session_meta",
        payload: {
          id: threadId,
          cwd,
        },
      }),
      "utf8"
    );
    const timestamp = new Date(mtime);
    fs.utimesSync(rolloutPath, timestamp, timestamp);
  };

  const readThreadCwd = () => JSON.parse(sanitizeThreadHistoryImagesForRelay(JSON.stringify({
    id: "req-thread-cwd-newer",
    result: {
      thread: {
        id: threadId,
        cwd: "/tmp/stale",
        turns: [
          {
            id: "turn-cwd-newer",
            items: [
              {
                id: "assistant-cwd-newer",
                type: "message",
                role: "assistant",
                content: [{ type: "output_text", text: "Done." }],
              },
            ],
          },
        ],
      },
    },
  }), "thread/read")).result.thread.cwd;

  const firstCwd = "/Users/test/FirstProject";
  const secondCwd = "/Users/test/SecondProject";
  assert.equal(readThreadCwd(), "/tmp/stale");

  writeRollout(
    `rollout-2026-05-19T19-45-00-${threadId}.jsonl`,
    firstCwd,
    "2026-05-19T19:45:00.000Z"
  );
  assert.equal(readThreadCwd(), firstCwd);

  writeRollout(
    `rollout-2026-05-19T19-46-00-${threadId}.jsonl`,
    secondCwd,
    "2026-05-19T19:46:00.000Z"
  );
  assert.equal(readThreadCwd(), secondCwd);
});

test("sanitizeThreadHistoryImagesForRelay annotates generated image calls with local paths", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-generated-image",
    result: {
      thread: {
        id: "thread-generated-image",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "ig_123",
                type: "image_generation_call",
                status: "generating",
                result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(
    item.saved_path,
    expectedGeneratedImagePath("thread-generated-image", "ig_123.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay annotates image generation items with local paths", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-image-generation",
    result: {
      thread: {
        id: "thread-image-generation",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "ig_generation",
                type: "image_generation",
                result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(
    item.saved_path,
    expectedGeneratedImagePath("thread-image-generation", "ig_generation.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay annotates image end history with local paths", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-generated-image-end",
    result: {
      thread: {
        id: "thread-generated-image-end",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "turn-1",
                type: "image_generation_end",
                call_id: "ig_end",
                result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(
    item.saved_path,
    expectedGeneratedImagePath("thread-generated-image-end", "ig_end.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay uses CODEX_HOME for generated image fallbacks", (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-home-"));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = codexHome;
  t.after(() => {
    if (previousCodexHome == null) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true, force: true });
  });

  const rawMessage = JSON.stringify({
    id: "req-thread-generated-image-codex-home",
    result: {
      thread: {
        id: "thread-generated-image-home",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "ig_home",
                type: "imageView",
                result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(
    item.saved_path,
    path.join(codexHome, "generated_images", "thread-generated-image-home", "ig_home.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay preserves generated image file_path without saved_path", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-generated-image-file-path",
    result: {
      thread: {
        id: "thread-generated-image",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "ig_123",
                type: "image_generation_call",
                file_path: "/tmp/real-generated-image.png",
                status: "completed",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(item.file_path, "/tmp/real-generated-image.png");
  assert.equal(item.saved_path, undefined);
});

test("sanitizeLiveGeneratedImageMessageForRelay annotates completed image items", () => {
  const rawMessage = JSON.stringify({
    method: "item/completed",
    params: {
      threadId: "thread-live-image",
      turnId: "turn-1",
      item: {
        id: "ig_live",
        type: "image_generation_call",
        result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
      },
    },
  });

  const sanitized = JSON.parse(sanitizeLiveGeneratedImageMessageForRelay(rawMessage));
  const item = sanitized.params.item;

  assert.equal(
    item.saved_path,
    expectedGeneratedImagePath("thread-live-image", "ig_live.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeLiveGeneratedImageMessageForRelay elides nested completed image items", () => {
  const rawMessage = JSON.stringify({
    method: "item/completed",
    params: {
      threadId: "thread-live-nested-image",
      turnId: "turn-1",
      event: {
        type: "item_completed",
        item: {
          id: "ig_nested",
          type: "image_generation",
          result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
        },
      },
    },
  });

  const sanitized = JSON.parse(sanitizeLiveGeneratedImageMessageForRelay(rawMessage));
  const item = sanitized.params.event.item;

  assert.equal(
    item.saved_path,
    expectedGeneratedImagePath("thread-live-nested-image", "ig_nested.png")
  );
  assert.equal(item.result, undefined);
  assert.equal(item.result_elided_for_relay, true);
});

test("sanitizeLiveGeneratedImageMessageForRelay uses call id for image end events", () => {
  const rawMessage = JSON.stringify({
    method: "image_generation_end",
    params: {
      type: "image_generation_end",
      threadId: "thread-live-event",
      id: "turn-1",
      call_id: "ig_event",
      result: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB",
    },
  });

  const sanitized = JSON.parse(sanitizeLiveGeneratedImageMessageForRelay(rawMessage));

  assert.equal(
    sanitized.params.saved_path,
    expectedGeneratedImagePath("thread-live-event", "ig_event.png")
  );
  assert.equal(sanitized.params.result, undefined);
  assert.equal(sanitized.params.result_elided_for_relay, true);
});

test("sanitizeThreadHistoryImagesForRelay leaves unrelated RPC payloads unchanged", () => {
  const rawMessage = JSON.stringify({
    id: "req-other",
    result: {
      ok: true,
    },
  });

  assert.equal(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "turn/start"),
    rawMessage
  );
});

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

test("sanitizeThreadHistoryImagesForRelay strips bulky compaction replacement history", () => {
  const rawMessage = JSON.stringify({
    id: "req-thread-resume",
    result: {
      thread: {
        id: "thread-compaction",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-compaction",
                type: "context_compaction",
                payload: {
                  message: "",
                  replacement_history: [
                    {
                      type: "message",
                      role: "assistant",
                      content: [{ type: "output_text", text: "very old transcript" }],
                    },
                  ],
                },
              },
              {
                id: "item-compaction-camel",
                type: "contextCompaction",
                replacementHistory: [
                  {
                    type: "message",
                    role: "user",
                    content: [{ type: "input_text", text: "older prompt" }],
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/resume")
  );
  const items = sanitized.result.thread.turns[0].items;

  assert.deepEqual(items[0], {
    id: "item-compaction",
    type: "context_compaction",
    payload: {
      message: "",
    },
  });
  assert.deepEqual(items[1], {
    id: "item-compaction-camel",
    type: "contextCompaction",
  });
});

test("sanitizeThreadHistoryImagesForRelay strips bulky compaction history from turns pages", () => {
  const rawMessage = JSON.stringify({
    id: "req-turns-list",
    result: {
      data: [
        {
          id: "turn-1",
          items: [
            {
              id: "item-compacted",
              type: "compacted",
              message: "",
              replacement_history: [
                {
                  type: "message",
                  role: "assistant",
                  content: [{ type: "output_text", text: "A".repeat(2 * 1024 * 1024) }],
                },
              ],
            },
          ],
        },
      ],
      nextCursor: "cursor-2",
    },
  });

  const sanitizedRaw = sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/turns/list");
  const sanitized = JSON.parse(sanitizedRaw);

  assert.equal(Buffer.byteLength(sanitizedRaw, "utf8") < 16 * 1024, true);
  assert.deepEqual(sanitized.result.data[0].items[0], {
    id: "item-compacted",
    type: "compacted",
    message: "",
  });
  assert.equal(sanitized.result.nextCursor, "cursor-2");
});

test("sanitizeThreadHistoryImagesForRelay compacts oversized turns pages", () => {
  const rawMessage = JSON.stringify({
    id: "req-turns-list-large",
    result: {
      items: [
        {
          id: "turn-1",
          items: [
            {
              id: "item-1",
              type: "assistant_message",
              turnId: "turn-1",
              createdAt: "2026-05-24T19:43:11.933Z",
              timestamp: "2026-05-24T19:43:11.933Z",
              text: "B".repeat(4 * 1024 * 1024),
            },
          ],
        },
      ],
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/turns/list")
  );
  const item = sanitized.result.items[0].items[0];

  assert.equal(sanitized.result.remodexPageCompactedForRelay, true);
  assert.deepEqual(
    sanitized.result.items.map((turn) => turn.id),
    ["turn-1"]
  );
  assert.equal(
    sanitized.result.items.some((turn) => turn.id.startsWith("remodex-history-compacted-")),
    false
  );
  assert.equal(sanitized.result.items[0].remodexPageCompactedForRelay, true);
  assert.equal(item.relayPayloadTruncated, true);
  assert.equal(item.turnId, "turn-1");
  assert.equal(item.createdAt, "2026-05-24T19:43:11.933Z");
  assert.equal(item.timestamp, "2026-05-24T19:43:11.933Z");
  assert.equal(item.text.startsWith("…\n"), true);
  assert.equal(item.text.length < 120_000, true);
});

test("sanitizeThreadHistoryImagesForRelay preserves oversized turns pages instead of replacing them with a marker", () => {
  const turns = Array.from({ length: 5 }, (_, turnIndex) => ({
    id: `turn-${turnIndex + 1}`,
    items: Array.from({ length: 900 }, (_, itemIndex) => ({
      id: `item-${turnIndex + 1}-${itemIndex + 1}`,
      type: "function_call_output",
      role: "tool",
      itemId: `call-${turnIndex + 1}-${itemIndex + 1}`,
      text: "C".repeat(1_500),
      payload: {
        blob: "D".repeat(1_200),
      },
    })),
  }));
  const rawMessage = JSON.stringify({
    id: "req-turns-list-impossible",
    result: {
      data: turns,
      nextCursor: "cursor-after-huge-page",
    },
  });

  const sanitizedRaw = sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/turns/list");
  const sanitized = JSON.parse(sanitizedRaw);

  assert.equal(Buffer.byteLength(sanitizedRaw, "utf8") <= 4 * 1024 * 1024, true);
  assert.deepEqual(
    sanitized.result.data.map((turn) => turn.id),
    turns.map((turn) => turn.id)
  );
  assert.equal(
    sanitized.result.data.some((turn) => turn.id.startsWith("remodex-history-compacted-")),
    false
  );
  assert.equal(sanitized.result.nextCursor, "cursor-after-huge-page");
  assert.equal(sanitized.result.data.every((turn) => turn.items.length === 900), true);
  assert.equal(
    sanitized.result.data.every((turn) => turn.items.every((item) => item.relayPayloadTruncated === true)),
    true
  );
});

test("sanitizeThreadHistoryImagesForRelay bounds an extreme provisional JSONL turn", () => {
  const fillerItems = Array.from({ length: 50_000 }, (_, index) => ({
    id: `tool-item-${index}-${"x".repeat(48)}`,
    type: "commandExecution",
    role: "tool",
    itemId: `tool-call-${index}-${"y".repeat(48)}`,
    text: "done",
  }));
  const rawMessage = JSON.stringify({
    id: "req-extreme-jsonl-page",
    result: {
      data: [{
        id: "turn-line-4096",
        items: [
          { id: "critical-user", type: "user_message", role: "user", text: "Keep the prompt" },
          { id: "critical-plan", type: "plan", text: "Keep the latest plan" },
          { id: "critical-file-change", type: "fileChange", text: "Keep the file change" },
          ...fillerItems,
        ],
      }],
      nextCursor: "remodex-jsonl-handoff-v1:turn-line-4096:extreme-token",
      remodexJsonlFallback: true,
      remodexCanonicalHandoff: true,
    },
  });

  const sanitizedRaw = sanitizeThreadHistoryImagesForRelay(
    rawMessage,
    "thread/turns/list",
    { skipJsonlArtifactAugmentation: true }
  );
  const sanitized = JSON.parse(sanitizedRaw);
  const keptItems = sanitized.result.data[0].items;
  const itemIds = keptItems.map((item) => item.id);
  const itemById = new Map(keptItems.map((item) => [item.id, item]));

  assert.ok(Buffer.byteLength(sanitizedRaw, "utf8") <= 4 * 1024 * 1024);
  assert.equal(sanitized.result.remodexEmergencyJsonlPageForRelay, true);
  assert.equal(sanitized.result.remodexJsonlFallback, true);
  assert.equal(sanitized.result.remodexCanonicalHandoff, true);
  assert.equal(
    sanitized.result.nextCursor,
    "remodex-jsonl-handoff-v1:turn-line-4096:extreme-token"
  );
  assert.equal(sanitized.result.data[0].id, "turn-line-4096");
  assert.ok(sanitized.result.data[0].items.length <= 64);
  assert.equal(itemIds.includes("critical-user"), true);
  assert.equal(itemIds.includes("critical-plan"), true);
  assert.equal(itemIds.includes("critical-file-change"), true);
  assert.equal(itemIds.includes(fillerItems.at(-1).id), true);
  assert.equal(itemById.get("critical-user")?.text, "Keep the prompt");
  assert.equal(itemById.get("critical-plan")?.text, "Keep the latest plan");
  assert.equal(itemById.get("critical-file-change")?.text, "Keep the file change");
  assert.equal(itemById.get(fillerItems.at(-1).id)?.text, "done");
});

test("sanitizeThreadHistoryImagesForRelay compacts oversized history before the newest turn tail", () => {
  const largeText = "A".repeat(4 * 1024 * 1024);
  const rawMessage = JSON.stringify({
    id: "req-thread-tail",
    result: {
      thread: {
        id: "thread-large-history",
        turns: [
          {
            id: "turn-old",
            items: [
              {
                id: "item-old",
                type: "assistant_message",
                text: largeText,
              },
            ],
          },
          {
            id: "turn-new",
            items: [
              {
                id: "item-new",
                type: "assistant_message",
                text: "latest reply",
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );

  assert.equal(sanitized.result.thread.historyTailTruncatedForRelay, true);
  assert.equal(sanitized.result.thread.remodexHistoryCompacted, true);
  assert.equal(sanitized.result.thread.remodexOmittedTurnCount, 1);
  assert.equal(sanitized.result.thread.remodexKeptTurnCount, 1);
  assert.deepEqual(
    sanitized.result.thread.turns.map((turn) => turn.id),
    ["remodex-history-compacted-turn-old", "turn-new"]
  );
  assert.equal(
    sanitized.result.thread.turns[0].items[0].text.includes("Older turns omitted: 1"),
    true
  );
});

test("sanitizeThreadHistoryImagesForRelay keeps the newest sixteen turns when compacting", () => {
  const largeText = "A".repeat(900 * 1024);
  const turns = Array.from({ length: 45 }, (_, index) => ({
    id: `turn-${index + 1}`,
    items: [
      {
        id: `item-${index + 1}`,
        type: "assistant_message",
        text: index < 5 ? largeText : `reply ${index + 1}`,
      },
    ],
  }));
  const rawMessage = JSON.stringify({
    id: "req-thread-recent-window",
    result: {
      thread: {
        id: "thread-recent-window",
        turns,
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );

  assert.equal(sanitized.result.thread.remodexHistoryCompacted, true);
  assert.equal(sanitized.result.thread.remodexOmittedTurnCount, 29);
  assert.equal(sanitized.result.thread.remodexKeptTurnCount, 16);
  assert.deepEqual(
    sanitized.result.thread.turns.map((turn) => turn.id),
    [
      "remodex-history-compacted-turn-1",
      ...turns.slice(29).map((turn) => turn.id),
    ]
  );
  // A status-less marker turn reads as interruptible on the phone and flags
  // idle heavy threads as running.
  assert.equal(sanitized.result.thread.turns[0].status, "completed");
});

test("sanitizeThreadHistoryImagesForRelay compacts oversized raw histories before sanitizing turns", () => {
  const imageData = `data:image/png;base64,${"A".repeat(100 * 1024)}`;
  const turns = Array.from({ length: 50 }, (_, index) => ({
    id: `turn-${index + 1}`,
    items: [
      {
        id: `item-${index + 1}`,
        type: "user_message",
        content: [
          { type: "input_text", text: `prompt ${index + 1}` },
          { type: "image", image_url: imageData },
        ],
      },
    ],
  }));
  const rawMessage = JSON.stringify({
    id: "req-thread-pretrim",
    result: {
      thread: {
        id: "thread-pretrim",
        turns,
      },
    },
  });

  assert.equal(Buffer.byteLength(rawMessage, "utf8") > 4 * 1024 * 1024, true);

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );

  assert.equal(sanitized.result.thread.historyTailTruncatedForRelay, true);
  assert.equal(sanitized.result.thread.remodexHistoryCompacted, true);
  assert.equal(sanitized.result.thread.remodexOmittedTurnCount, 34);
  assert.equal(sanitized.result.thread.remodexKeptTurnCount, 16);
  assert.deepEqual(
    sanitized.result.thread.turns.map((turn) => turn.id),
    [
      "remodex-history-compacted-turn-1",
      ...turns.slice(34).map((turn) => turn.id),
    ]
  );
  assert.deepEqual(sanitized.result.thread.turns[1].items[0].content[1], {
    type: "image",
    url: "remodex://history-image-elided",
  });
});

test("sanitizeThreadHistoryImagesForRelay truncates the newest oversized text item to its tail", () => {
  const largeText = `header\n${"B".repeat(4 * 1024 * 1024)}`;
  const rawMessage = JSON.stringify({
    id: "req-thread-text-tail",
    result: {
      thread: {
        id: "thread-large-item",
        turns: [
          {
            id: "turn-1",
            items: [
              {
                id: "item-1",
                type: "assistant_message",
                text: largeText,
              },
            ],
          },
        ],
      },
    },
  });

  const sanitized = JSON.parse(
    sanitizeThreadHistoryImagesForRelay(rawMessage, "thread/read")
  );
  const item = sanitized.result.thread.turns[0].items[0];

  assert.equal(sanitized.result.thread.historyTailTruncatedForRelay, true);
  assert.equal(item.relayTextTailTruncated, true);
  assert.equal(item.text.startsWith("…\n"), true);
  assert.equal(item.text.includes("header"), false);
});
