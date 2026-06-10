// FILE: opencode-regression-fixes.test.js
// Purpose: Regression tests for PR review fixes (pagination, dedupe, timeout, ownership routing).

if (process.env.REMODEX_TEST !== "1") {
  throw new Error(
    "opencode-regression-fixes.test.js must run with the test harness preload.\n" +
      "  npm run test:opencode",
  );
}

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createOpenCodeProvider, paginateTurnList } = require("../src/opencode-provider");
const { createOpenCodeSessionStore } = require("../src/opencode-session-store");
const { createThreadOwnershipStore } = require("../src/thread-ownership-store");
const { createOpenCodeClient, buildStaticSlashCommands } = require("../src/opencode-client");
const { providerForRequest } = require("../src/runtime-provider-router");
const { resolveTimeoutMs, MAX_START_TIMEOUT_MS } = require("../src/opencode-server");

function testProjectPath(name) {
  return path.join(os.homedir(), `.remodex-test-${name}`);
}

function fakeServer() {
  let running = false;
  return {
    get baseUrl() {
      return running ? "http://127.0.0.1:4291" : "";
    },
    get isRunning() {
      return running;
    },
    start: async () => {
      running = true;
    },
    stop: async () => {
      running = false;
    },
  };
}

function fakeOwnershipStore() {
  const store = new Map();
  return {
    setOwnership(threadId, providerId) {
      store.set(threadId, { providerId, assignedAt: new Date().toISOString() });
      return true;
    },
    ownsThread(threadId, providerId) {
      const entry = store.get(threadId);
      return entry ? entry.providerId === providerId : false;
    },
    removeOwnership(threadId) {
      return store.delete(threadId);
    },
    getOwnership(threadId) {
      return store.get(threadId)?.providerId || null;
    },
    setRetainThreadIdPredicate(predicate) {
      this._retain = predicate;
    },
  };
}

function fakeSessionStore() {
  const entries = new Map();
  return {
    set(threadId, sessionId, meta = {}) {
      entries.set(threadId, { sessionId, ...meta });
      return true;
    },
    get(threadId) {
      return entries.get(threadId)?.sessionId || null;
    },
    getEntry(threadId) {
      return entries.get(threadId) ? { ...entries.get(threadId) } : null;
    },
    remove() {},
  };
}

function makeProvider(opts = {}) {
  return createOpenCodeProvider({
    sendApplicationMessage: opts.send || (() => {}),
    env: { REMODEX_ENABLE_OPENCODE: "1", ...opts.env },
    serverFactory: opts.serverFactory || (() => fakeServer()),
    clientFactory: opts.clientFactory,
    ownershipStore: opts.ownershipStore || fakeOwnershipStore(),
    sessionStore: opts.sessionStore || fakeSessionStore(),
  });
}

test("resolveTimeoutMs allows values above default up to max cap", () => {
  const previous = process.env.REMODEX_OPENCODE_START_TIMEOUT_MS;
  try {
    process.env.REMODEX_OPENCODE_START_TIMEOUT_MS = "60000";
    assert.equal(
      resolveTimeoutMs("REMODEX_OPENCODE_START_TIMEOUT_MS", 15_000, MAX_START_TIMEOUT_MS),
      60_000,
    );
    process.env.REMODEX_OPENCODE_START_TIMEOUT_MS = "200000";
    assert.equal(
      resolveTimeoutMs("REMODEX_OPENCODE_START_TIMEOUT_MS", 15_000, MAX_START_TIMEOUT_MS),
      MAX_START_TIMEOUT_MS,
    );
  } finally {
    if (previous === undefined) {
      delete process.env.REMODEX_OPENCODE_START_TIMEOUT_MS;
    } else {
      process.env.REMODEX_OPENCODE_START_TIMEOUT_MS = previous;
    }
  }
});

function fakeClient() {
  return {
    listModels: async () => [],
    listAgents: async () => [{ id: "build", label: "Build" }],
    createSession: async () => "ses_pagination",
    getSession: async () => ({}),
    prompt: async () => {},
    abort: async () => {},
    fork: async () => "ses_fork",
    getMessages: async () => [],
    replyToPermission: async () => {},
    subscribeToEvents: (handler) => {
      setImmediate(() => {
        handler("turn/completed", { status: "completed" });
      });
      return () => {};
    },
  };
}

test("paginateTurnList returns newest page for sortDirection desc", () => {
  const turns = Array.from({ length: 6 }, (_, index) => ({
    id: `turn-${index}`,
    items: [{ type: "userMessage", text: `message-${index}` }],
  }));

  const listed = paginateTurnList(turns, { limit: 3, sortDirection: "desc", cursor: null });

  assert.equal(listed.data.length, 3);
  assert.equal(listed.nextCursor, "3");
  assert.equal(listed.data[0].id, "turn-5");
});

test("command/execute retries after transient SDK failure within dedupe TTL", async () => {
  let commandCalls = 0;
  const provider = makeProvider({
    clientFactory: ({ baseUrl, logPrefix }) =>
      createOpenCodeClient({
        baseUrl,
        logPrefix,
        createOpencodeClientImpl: () => ({
          session: {
            create: async () => ({ sessionID: "ses_dedupe_retry" }),
            command: async () => {
              commandCalls += 1;
              if (commandCalls === 1) {
                throw new Error("transient network failure");
              }
              return { info: {}, parts: [] };
            },
          },
          command: {
            list: async () => buildStaticSlashCommands(),
          },
        }),
      }),
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { cwd: testProjectPath("dedupe-retry") },
  });

  const request = {
    id: 2,
    method: "command/execute",
    params: {
      threadId: start.thread.id,
      command: "/undo",
      clientCommandId: "client-cmd-retry-1",
      directory: testProjectPath("dedupe-retry"),
    },
  };

  await assert.rejects(
    () => provider.commandExecute(request),
    /transient network failure/,
  );

  const retry = await provider.commandExecute(request);
  assert.equal(retry.ok, true);
  assert.notEqual(retry.deduped, true);
  assert.equal(commandCalls, 2);
});

test("providerForRequest routes to OpenCode when session mapping exists without ownership", () => {
  const provider = {
    id: "opencode",
    ownsThread(threadId) {
      return threadId === "opencode-thread-stale";
    },
    handleRequest: async () => ({}),
  };

  const resolved = providerForRequest(
    { method: "turn/start", params: { threadId: "opencode-thread-stale" } },
    [provider],
    { getOwnership: () => null },
  );

  assert.equal(resolved?.id, "opencode");
});

test("ownership prune retains threads with persisted session mappings", () => {
  const fsImpl = {
    readFileSync() {
      throw new Error("ENOENT");
    },
    writeFileSync() {},
    renameSync() {},
    mkdirSync() {},
    chmodSync() {},
  };
  const sessionStore = createOpenCodeSessionStore({ fsImpl, homeDir: os.tmpdir() });
  const ownership = createThreadOwnershipStore({
    fsImpl,
    homeDir: os.tmpdir(),
    nowMs: () => 0,
    writeDebounceMs: 0,
  });
  ownership.setRetainThreadIdPredicate((threadId) => Boolean(sessionStore.get(threadId)));

  const threadId = "opencode-thread-retain";
  ownership.setOwnership(threadId, "opencode");
  sessionStore.set(threadId, "ses_retain", { cwd: "/tmp/proj" });

  ownership.pruneStaleEntries(1);

  assert.equal(ownership.getOwnership(threadId), "opencode");
});
