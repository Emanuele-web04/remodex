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
  createMacOSBridgeWakeAssertion,
  disableUnsupportedReasoningSummaryForTurnStart,
  fetchAdaptiveThreadTurnsListForRelay,
  hasRelayConnectionGoneStale,
  normalizeRelayBoundJsonRpcMessage,
  persistBridgePreferences,
  resolveJsonlTurnsListRolloutPathForFallback,
  sanitizeLiveGeneratedImageMessageForRelay,
  sanitizeThreadHistoryImagesForRelay,
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
    { data: makeTurns(1, 1), nextCursor: "cursor-after-1", stableMeta: "first-page" },
    { data: makeTurns(2, 4), nextCursor: "cursor-after-5", stableMeta: "second-page" },
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

test("fetchAdaptiveThreadTurnsListForRelay keeps only a safe slice when the combined page stays too large", async () => {
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
    ["turn-1", "turn-2", "turn-3", "turn-4", "turn-5"]
  );
  assert.equal(response.result.nextCursor, "cursor-after-large");
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
  assert.equal(response.result.nextCursor, "cursor-after-large");
});

test("fetchAdaptiveThreadTurnsListForRelay returns an empty page when the first page has no payload", async () => {
  const response = await fetchAdaptiveThreadTurnsListForRelay({
    id: "req-turns-list-missing-payload",
    method: "thread/turns/list",
    params: {
      threadId: "thread-missing-payload",
      limit: 2,
      sortDirection: "desc",
    },
  }, {
    fetchPage: async () => null,
  });

  assert.equal(response.id, "req-turns-list-missing-payload");
  assert.deepEqual(response.result.data, []);
  assert.equal(response.result.nextCursor, null);
});

test("fetchAdaptiveThreadTurnsListForRelay returns an empty page when no fallback is available", async () => {
  const response = await fetchAdaptiveThreadTurnsListForRelay({
    id: "req-turns-list-empty-fallback",
    method: "thread/turns/list",
    params: {
      threadId: "thread-empty-fallback",
      limit: 10,
    },
  }, {
    fetchPage: async () => null,
  });

  assert.deepEqual(response, {
    id: "req-turns-list-empty-fallback",
    result: {
      data: [],
      nextCursor: null,
    },
  });
});

test("fetchAdaptiveThreadTurnsListForRelay does not copy malformed page fields into empty fallback", async () => {
  const response = await fetchAdaptiveThreadTurnsListForRelay({
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
  });

  assert.deepEqual(response, {
    id: "req-turns-list-malformed-object",
    result: {
      data: [],
      nextCursor: null,
    },
  });
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
  assert.equal(items[1].type, "fileChange");
  assert.equal(items[1].remodexJsonlFileChangeAggregate, true);
  assert.deepEqual(items[1].changes.map((change) => ({
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
  assert.equal(turnsPage.result.data[0].items[1].type, "fileChange");

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
  assert.equal(hintedTurnsPage.result.data[0].items[1].type, "fileChange");

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
  const originalReadFileSync = fs.readFileSync;
  t.after(() => {
    fs.readFileSync = originalReadFileSync;
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
  fs.readFileSync = function readFileSyncWithRolloutCounter(filePath, ...args) {
    if (path.resolve(String(filePath)) === rolloutPath) {
      rolloutReads += 1;
    }
    return originalReadFileSync.call(this, filePath, ...args);
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
              id: `${requestId}-assistant`,
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

  assert.equal(firstPage.result.data[0].items[1].type, "fileChange");
  assert.equal(secondPage.result.data[0].items[1].type, "fileChange");
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

  assert.equal(changedPage.result.data[0].items[1].type, "fileChange");
  assert.equal(changedPage.result.data[0].items[1].changes[0].path, "Sources/Two.swift");
  assert.equal(rolloutReads, 2);
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
  assert.equal(items[0].id, "assistant-jsonl-plan");
  assert.equal(items[1].type, "plan");
  assert.equal(items[1].id, "call-jsonl-plan");
  assert.equal(items[1].remodexJsonlProgressPlan, true);
  assert.equal(items[1].explanation, "Keep the plan visible.");
  assert.deepEqual(items[1].plan, [
    { step: "Inspect plan rendering", status: "completed" },
    { step: "Patch the bridge", status: "in_progress" },
  ]);
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

  assert.equal(items.length, 2);
  assert.equal(items[1].type, "imageView");
  assert.equal(items[1].path, imagePath);
  assert.equal(items[1].remodexJsonlToolOutputImage, true);
  assert.equal(Object.hasOwn(items[1], "output"), false);
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

test("sanitizeThreadHistoryImagesForRelay keeps the newest forty turns when compacting", () => {
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
  assert.equal(sanitized.result.thread.remodexOmittedTurnCount, 5);
  assert.equal(sanitized.result.thread.remodexKeptTurnCount, 40);
  assert.deepEqual(
    sanitized.result.thread.turns.map((turn) => turn.id),
    [
      "remodex-history-compacted-turn-1",
      ...turns.slice(5).map((turn) => turn.id),
    ]
  );
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
