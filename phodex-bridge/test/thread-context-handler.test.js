// FILE: thread-context-handler.test.js
// Purpose: Verifies thread/contextWindow/read routing between OpenCode usage and Codex rollout paths.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/thread-context-handler, ../src/thread-ownership-store

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { handleThreadContextRequest } = require("../src/thread-context-handler");
const { createThreadOwnershipStore } = require("../src/thread-ownership-store");

function makeTempDir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

async function withOpenCodeEnabled(run) {
  const previousDisable = process.env.REMODEX_DISABLE_OPENCODE;
  delete process.env.REMODEX_DISABLE_OPENCODE;
  try {
    return await run();
  } finally {
    if (previousDisable === undefined) {
      delete process.env.REMODEX_DISABLE_OPENCODE;
    } else {
      process.env.REMODEX_DISABLE_OPENCODE = previousDisable;
    }
  }
}

async function withEmptyCodexHome(run) {
  const previousCodexHome = process.env.CODEX_HOME;
  const codexHome = makeTempDir("remodex-thread-context-codex-");
  process.env.CODEX_HOME = codexHome;
  try {
    return await run();
  } finally {
    if (previousCodexHome === undefined) {
      delete process.env.CODEX_HOME;
    } else {
      process.env.CODEX_HOME = previousCodexHome;
    }
    fs.rmSync(codexHome, { recursive: true });
  }
}

function makeOwnershipStore(tempDir) {
  const store = createThreadOwnershipStore({
    storagePath: path.join(tempDir, "thread-ownership.json"),
    fsImpl: fs,
  });
  store.setOwnership("thread-oc", "opencode");
  store.setOwnership("thread-codex", "codex");
  return store;
}

function callHandler(message, dependencies = {}) {
  return new Promise((resolve, reject) => {
    let handled;
    try {
      handled = handleThreadContextRequest(
        message,
        (payload) => resolve({ handled, response: JSON.parse(payload) }),
        dependencies,
      );
    } catch (err) {
      reject(err);
      return;
    }
    if (!handled) {
      resolve({ handled, response: null });
    }
  });
}

test("handleThreadContextRequest ignores non-matching methods", async () => {
  const result = await callHandler(
    JSON.stringify({ id: 1, method: "thread/read", params: { threadId: "t" } }),
  );
  assert.equal(result.handled, false);
  assert.equal(result.response, null);
});

test("handleThreadContextRequest ignores invalid JSON", async () => {
  const result = await callHandler("{not json at all");
  assert.equal(result.handled, false);
});

test("handleThreadContextRequest ignores messages with no method", async () => {
  const result = await callHandler(JSON.stringify({ id: 4, params: {} }));
  assert.equal(result.handled, false);
});

test("thread/contextWindow/read routes OpenCode-owned threads through provider usage", async () => {
  await withOpenCodeEnabled(async () => {
    const tempDir = makeTempDir("remodex-thread-context-oc-");
    try {
      const ownershipStore = makeOwnershipStore(tempDir);
      const seenThreadIds = [];
      const opencodeProvider = {
        getUsageStatsForThread: async (threadId) => {
          seenThreadIds.push(threadId);
          return {
            sessionId: "sess-9",
            usage: { tokensUsed: 1234, tokenLimit: 200000 },
          };
        },
      };

      const { handled, response } = await callHandler(
        JSON.stringify({
          id: 11,
          method: "thread/contextWindow/read",
          params: { threadId: "thread-oc" },
        }),
        { ownershipStore, opencodeProvider },
      );

      assert.equal(handled, true);
      assert.equal(response.id, 11);
      assert.equal(response.error, undefined);
      assert.equal(response.result.threadId, "thread-oc");
      assert.equal(response.result.source, "opencode");
      assert.equal(response.result.sessionId, "sess-9");
      assert.deepEqual(response.result.usage, { tokensUsed: 1234, tokenLimit: 200000 });
      assert.deepEqual(seenThreadIds, ["thread-oc"]);
    } finally {
      fs.rmSync(tempDir, { recursive: true });
    }
  });
});

test("thread/contextWindow/read routes Codex-owned threads to the rollout path", async () => {
  await withEmptyCodexHome(async () => {
    const tempDir = makeTempDir("remodex-thread-context-codex-store-");
    try {
      const ownershipStore = makeOwnershipStore(tempDir);
      let opencodeCalled = false;
      const opencodeProvider = {
        getUsageStatsForThread: async () => {
          opencodeCalled = true;
          return {};
        },
      };

      const { handled, response } = await callHandler(
        JSON.stringify({
          id: 12,
          method: "thread/contextWindow/read",
          params: { threadId: "thread-codex" },
        }),
        { ownershipStore, opencodeProvider },
      );

      assert.equal(handled, true);
      assert.equal(response.id, 12);
      assert.equal(response.error, undefined);
      assert.equal(response.result.threadId, "thread-codex");
      assert.equal(response.result.source, "codex_rollout");
      assert.equal(response.result.usage, null);
      assert.equal(response.result.rolloutPath, null);
      assert.equal(opencodeCalled, false);
    } finally {
      fs.rmSync(tempDir, { recursive: true });
    }
  });
});

test("thread/contextWindow/read treats unowned threads as Codex rollout reads", async () => {
  await withEmptyCodexHome(async () => {
    const tempDir = makeTempDir("remodex-thread-context-unowned-");
    try {
      const ownershipStore = makeOwnershipStore(tempDir);
      const { handled, response } = await callHandler(
        JSON.stringify({
          id: 13,
          method: "thread/contextWindow/read",
          params: { thread_id: "thread-unknown" },
        }),
        { ownershipStore },
      );

      assert.equal(handled, true);
      assert.equal(response.result.threadId, "thread-unknown");
      assert.equal(response.result.source, "codex_rollout");
      assert.equal(response.result.usage, null);
    } finally {
      fs.rmSync(tempDir, { recursive: true });
    }
  });
});

test("thread/contextWindow/read works with no ownership store (codex fallback)", async () => {
  await withEmptyCodexHome(async () => {
    const { handled, response } = await callHandler(
      JSON.stringify({
        id: 14,
        method: "thread/contextWindow/read",
        params: { threadId: "thread-anything" },
      }),
      {},
    );

    assert.equal(handled, true);
    assert.equal(response.result.source, "codex_rollout");
  });
});

test("thread/contextWindow/read returns structured missing_thread_id error", async () => {
  const { handled, response } = await callHandler(
    JSON.stringify({ id: 15, method: "thread/contextWindow/read", params: {} }),
    {},
  );

  assert.equal(handled, true);
  assert.equal(response.id, 15);
  assert.equal(response.result, undefined);
  assert.equal(response.error.code, -32000);
  assert.equal(response.error.data.errorCode, "missing_thread_id");
  assert.equal(typeof response.error.message, "string");
  assert.ok(!response.error.message.includes("\n    at "), "must not leak stack traces");
  assert.equal(response.error.stack, undefined);
});

test("thread/contextWindow/read treats blank threadId as missing", async () => {
  const { response } = await callHandler(
    JSON.stringify({
      id: 16,
      method: "thread/contextWindow/read",
      params: { threadId: "   " },
    }),
    {},
  );

  assert.equal(response.error.data.errorCode, "missing_thread_id");
});

test("thread/contextWindow/read surfaces OpenCode provider failures as structured errors", async () => {
  await withOpenCodeEnabled(async () => {
    const tempDir = makeTempDir("remodex-thread-context-err-");
    try {
      const ownershipStore = makeOwnershipStore(tempDir);
      const opencodeProvider = {
        getUsageStatsForThread: async () => {
          const error = new Error("boom internal");
          error.errorCode = "opencode_session_read_failed";
          error.userMessage = "Could not read OpenCode session usage.";
          throw error;
        },
      };

      const { response } = await callHandler(
        JSON.stringify({
          id: 17,
          method: "thread/contextWindow/read",
          params: { threadId: "thread-oc" },
        }),
        { ownershipStore, opencodeProvider },
      );

      assert.equal(response.id, 17);
      assert.equal(response.error.code, -32000);
      assert.equal(response.error.data.errorCode, "opencode_session_read_failed");
      assert.equal(response.error.message, "Could not read OpenCode session usage.");
      assert.ok(!JSON.stringify(response).includes("at Object"), "no raw stack traces in response");
    } finally {
      fs.rmSync(tempDir, { recursive: true });
    }
  });
});

test("thread/contextWindow/read on OpenCode thread without provider yields opencode_unavailable", async () => {
  await withOpenCodeEnabled(async () => {
    const tempDir = makeTempDir("remodex-thread-context-noprov-");
    try {
      const ownershipStore = makeOwnershipStore(tempDir);
      const { response } = await callHandler(
        JSON.stringify({
          id: 18,
          method: "thread/contextWindow/read",
          params: { threadId: "thread-oc" },
        }),
        { ownershipStore },
      );

      assert.equal(response.error.data.errorCode, "opencode_unavailable");
    } finally {
      fs.rmSync(tempDir, { recursive: true });
    }
  });
});
