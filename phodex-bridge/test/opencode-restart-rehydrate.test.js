// FILE: opencode-restart-rehydrate.test.js
// Purpose: Verifies OpenCode threads rehydrate from persisted session store after a new provider instance.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-provider, ../src/opencode-session-store

if (process.env.REMODEX_TEST !== "1") {
  throw new Error(
    "opencode-restart-rehydrate.test.js must run with the test harness preload.\n" +
      "  npm test\n" +
      "  node -r ./test/test-env.js --test ./test/opencode-restart-rehydrate.test.js",
  );
}

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { createOpenCodeProvider } = require("../src/opencode-provider");
const { createOpenCodeSessionStore } = require("../src/opencode-session-store");
const { createThreadOwnershipStore } = require("../src/thread-ownership-store");

function testProjectPath(name) {
  return path.join(os.homedir(), `.remodex-test-${name}`);
}

const REHYDRATE_PROJECT = testProjectPath("rehydrate-project");
const TEST_PROJ = testProjectPath("proj");
const REHYDRATE_TURN_START = testProjectPath("rehydrate-turn-start");

function fakeFs() {
  const files = new Map();
  return {
    readFileSync(path) {
      if (files.has(path)) return files.get(path);
      throw new Error("ENOENT");
    },
    writeFileSync(path, data) {
      files.set(path, data);
    },
    renameSync(oldPath, newPath) {
      if (files.has(oldPath)) {
        files.set(newPath, files.get(oldPath));
        files.delete(oldPath);
      }
    },
    mkdirSync() {},
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
    getAllOwnedBy(providerId) {
      return Array.from(store.entries())
        .filter(([, entry]) => entry.providerId === providerId)
        .map(([threadId, entry]) => ({ threadId, ...entry }));
    },
  };
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
    start() {
      running = true;
      return Promise.resolve();
    },
    stop() {
      running = false;
      return Promise.resolve();
    },
  };
}

function fakeClient({ getSessionImpl, getMessagesImpl, createSessionImpl } = {}) {
  return {
    listModels: async () => [],
    listAgents: async () => [{ id: "build", label: "Build" }],
    createSession: createSessionImpl || (async () => "ses_new"),
    getSession:
      getSessionImpl ||
      (async (sessionId) => ({
        sessionID: sessionId,
        directory: REHYDRATE_PROJECT,
      })),
    getMessages: getMessagesImpl || (async () => []),
    prompt: async () => {},

    abort: async () => {},
    fork: async () => "ses_forked",
    replyToPermission: async () => {},
    subscribeToEvents: () => () => {},
  };
}

function makeProvider({ sessionStore, ownershipStore, clientFactory }) {
  delete process.env.REMODEX_DISABLE_OPENCODE;
  return createOpenCodeProvider({
    sendApplicationMessage: () => {},
    env: { REMODEX_ENABLE_OPENCODE: "1" },
    serverFactory: () => fakeServer(),
    clientFactory: clientFactory || (() => fakeClient()),
    ownershipStore: ownershipStore || fakeOwnershipStore(),
    sessionStore,
  });
}

test("thread/read rehydrates from persisted session after provider restart", async () => {
  const fs = fakeFs();
  const sessionStore = createOpenCodeSessionStore({
    storagePath: "/tmp/rehydrate-sessions.json",
    fsImpl: fs,
  });
  const ownershipStore = fakeOwnershipStore();

  const provider1 = makeProvider({ sessionStore, ownershipStore });
  const started = await provider1.handleRequest({
    id: 1,
    method: "thread/start",
    params: { title: "Rehydrate me", cwd: REHYDRATE_PROJECT, model: "openai/gpt-5.5" },
  });
  const threadId = started.thread.id;

  await provider1.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId, input: "hello" },
  });
  await new Promise((resolve) => setImmediate(resolve));
  await provider1.shutdown();

  const provider2 = makeProvider({ sessionStore, ownershipStore });
  const read = await provider2.handleRequest({
    id: 3,
    method: "thread/read",
    params: { threadId },
  });

  assert.equal(read.thread.id, threadId);
  assert.equal(read.thread.model, "openai/gpt-5.5");
  const entry = sessionStore.getEntry(threadId);
  assert.equal(entry.sessionId, "ses_new");
  assert.equal(entry.cwd, REHYDRATE_PROJECT);

  await provider2.shutdown();
});

test("thread/turns/list rehydrates before listing turns", async () => {
  const fs = fakeFs();
  const sessionStore = createOpenCodeSessionStore({
    storagePath: "/tmp/rehydrate-turns.json",
    fsImpl: fs,
  });
  const ownershipStore = fakeOwnershipStore();

  const provider1 = makeProvider({ sessionStore, ownershipStore });
  const started = await provider1.handleRequest({
    method: "thread/start",
    params: { cwd: TEST_PROJ },
  });
  await provider1.handleRequest({
    method: "turn/start",
    params: { threadId: started.thread.id, input: "ping" },
  });
  await new Promise((resolve) => setImmediate(resolve));
  await provider1.shutdown();

  const provider2 = makeProvider({
    sessionStore,
    ownershipStore,
    clientFactory: () =>
      fakeClient({
        getMessagesImpl: async () => [
          {
            id: "msg-1",
            role: "user",
            content: [{ type: "text", text: "ping" }],
          },
        ],
      }),
  });

  const listed = await provider2.handleRequest({
    method: "thread/turns/list",
    params: { threadId: started.thread.id, limit: 10 },
  });

  assert.ok(Array.isArray(listed.data));
  assert.ok(listed.data.length >= 1);
  await provider2.shutdown();
});

test("expired SDK session removes store entry and returns opencode_session_expired", async () => {
  const fs = fakeFs();
  const sessionStore = createOpenCodeSessionStore({
    storagePath: "/tmp/rehydrate-expired.json",
    fsImpl: fs,
  });
  const ownershipStore = fakeOwnershipStore();

  sessionStore.set("opencode-thread-stale", "ses_gone", {
    cwd: TEST_PROJ,
    model: "openai/gpt-5.5",
    agent: "build",
  });
  ownershipStore.setOwnership("opencode-thread-stale", "opencode");

  const provider = makeProvider({
    sessionStore,
    ownershipStore,
    clientFactory: () =>
      fakeClient({
        getSessionImpl: async () => {
          const error = new Error("session not found");
          error.status = 404;
          throw error;
        },
      }),
  });

  await assert.rejects(
    () =>
      provider.handleRequest({
        method: "thread/read",
        params: { threadId: "opencode-thread-stale" },
      }),
    (error) => error.errorCode === "opencode_session_expired",
  );
  assert.equal(sessionStore.get("opencode-thread-stale"), null);
  assert.equal(ownershipStore.ownsThread("opencode-thread-stale", "opencode"), false);
  await provider.shutdown();
});

test("transient getSession failure keeps store entry and propagates error", async () => {
  const fs = fakeFs();
  const sessionStore = createOpenCodeSessionStore({
    storagePath: "/tmp/rehydrate-transient.json",
    fsImpl: fs,
  });
  const ownershipStore = fakeOwnershipStore();

  sessionStore.set("opencode-thread-transient", "ses_ok", {
    cwd: TEST_PROJ,
    model: "openai/gpt-5.5",
    agent: "build",
  });
  ownershipStore.setOwnership("opencode-thread-transient", "opencode");

  const provider = makeProvider({
    sessionStore,
    ownershipStore,
    clientFactory: () =>
      fakeClient({
        getSessionImpl: async () => {
          throw new Error("OpenCode SDK request timed out after 90000ms");
        },
      }),
  });

  await assert.rejects(
    () =>
      provider.handleRequest({
        method: "thread/read",
        params: { threadId: "opencode-thread-transient" },
      }),
    (error) =>
      error.message.includes("timed out") && error.errorCode !== "opencode_session_expired",
  );
  assert.equal(sessionStore.get("opencode-thread-transient"), "ses_ok");
  await provider.shutdown();
});

test("thread/read rehydrates when ownership JSON was corrupt but salvageable", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-rehydrate-corrupt-"));
  const ownershipPath = path.join(tempDir, "thread-ownership.json");
  const sessionPath = path.join(tempDir, "opencode-sessions.json");
  const threadId = "opencode-thread-corrupt-rehydrate";
  try {
    fs.writeFileSync(
      ownershipPath,
      `{
  "ownership": {
    "${threadId}": {
      "providerId": "opencode",
      "assignedAt": "2026-05-30T12:00:00.000Z"
    `,
      "utf8",
    );
    fs.writeFileSync(
      sessionPath,
      JSON.stringify({
        sessions: {
          [threadId]: {
            sessionId: "ses_salvaged",
            cwd: "/tmp/rehydrate-corrupt",
            model: "openai/gpt-5.5",
            agent: "build",
            updatedAt: "2026-05-30T12:00:00.000Z",
          },
        },
        discovered: {},
      }),
      "utf8",
    );

    const ownershipStore = createThreadOwnershipStore({
      storagePath: ownershipPath,
      fsImpl: fs,
      writeDebounceMs: 0,
    });
    const sessionStore = createOpenCodeSessionStore({
      storagePath: sessionPath,
      fsImpl: fs,
    });

    assert.equal(ownershipStore.getOwnership(threadId), "opencode");
    assert.equal(sessionStore.get(threadId), "ses_salvaged");

    const provider = makeProvider({
      sessionStore,
      ownershipStore,
      clientFactory: () =>
        fakeClient({
          getSessionImpl: async (sessionId) => ({
            sessionID: sessionId,
            directory: "/tmp/rehydrate-corrupt",
          }),
        }),
    });

    const read = await provider.handleRequest({
      method: "thread/read",
      params: { threadId },
    });

    assert.equal(read.thread.id, threadId);
    assert.equal(read.thread.model, "openai/gpt-5.5");
    await provider.shutdown();
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("turn/start rehydrates from persisted session after provider restart", async () => {
  const fs = fakeFs();
  const sessionStore = createOpenCodeSessionStore({
    storagePath: "/tmp/rehydrate-turn-start.json",
    fsImpl: fs,
  });
  const ownershipStore = fakeOwnershipStore();
  let createSessionCalls = 0;

  const provider1 = makeProvider({
    sessionStore,
    ownershipStore,
    clientFactory: () =>
      fakeClient({
        createSessionImpl: async () => {
          createSessionCalls += 1;
          return "ses_persisted";
        },
      }),
  });

  const started = await provider1.handleRequest({
    method: "thread/start",
    params: { cwd: REHYDRATE_TURN_START, model: "openai/gpt-5.5" },
  });
  const threadId = started.thread.id;

  await provider1.handleRequest({
    method: "turn/start",
    params: { threadId, input: "first message" },
  });
  await new Promise((resolve) => setImmediate(resolve));
  await provider1.shutdown();

  assert.equal(createSessionCalls, 1);
  assert.equal(sessionStore.get(threadId), "ses_persisted");

  const provider2 = makeProvider({
    sessionStore,
    ownershipStore,
    clientFactory: () =>
      fakeClient({
        createSessionImpl: async () => {
          createSessionCalls += 1;
          return "ses_should_not_happen";
        },
      }),
  });

  const turn = await provider2.handleRequest({
    method: "turn/start",
    params: { threadId, input: "after restart" },
  });

  assert.ok(turn.turnId);
  assert.equal(turn.turn.threadId, threadId);
  assert.equal(createSessionCalls, 1, "rehydrated turn should reuse persisted session");
  await new Promise((resolve) => setImmediate(resolve));
  await provider2.shutdown();
});

test("archived OpenCode thread stays archived after provider restart", async () => {
  const fs = fakeFs();
  const sessionStore = createOpenCodeSessionStore({
    storagePath: "/tmp/rehydrate-archived.json",
    fsImpl: fs,
  });
  const ownershipStore = fakeOwnershipStore();

  const provider1 = makeProvider({
    sessionStore,
    ownershipStore,
    clientFactory: () => ({
      ...fakeClient(),
      subscribeToEvents: (handler) => {
        setImmediate(() => {
          handler("turn/completed", { status: "completed" });
        });
        return () => {};
      },
    }),
  });
  const started = await provider1.handleRequest({
    method: "thread/start",
    params: { cwd: REHYDRATE_PROJECT },
  });
  await provider1.handleRequest({
    method: "turn/start",
    params: { threadId: started.thread.id, input: "archive me" },
  });
  await new Promise((resolve) => setTimeout(resolve, 20));
  await provider1.handleRequest({
    method: "thread/archive",
    params: { threadId: started.thread.id },
  });
  await provider1.shutdown();

  const archivedEntry = sessionStore.getEntry(started.thread.id);
  assert.equal(archivedEntry?.archived, true);

  const provider2 = makeProvider({
    sessionStore,
    ownershipStore,
    clientFactory: () =>
      fakeClient({
        getMessagesImpl: async () => [
          {
            id: "msg-archive",
            role: "user",
            content: [{ type: "text", text: "archive me" }],
          },
        ],
      }),
  });
  const listed = await provider2.listThreads();
  const ids = (listed.data || []).map((thread) => thread.id);
  assert.ok(!ids.includes(started.thread.id));

  const archivedList = await provider2.listThreads({ includeArchived: true });
  const archivedThread = (archivedList.data || []).find((thread) => thread.id === started.thread.id);
  assert.equal(archivedThread?.archived, true);
  await provider2.shutdown();
});