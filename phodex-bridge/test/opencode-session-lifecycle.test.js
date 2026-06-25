// FILE: opencode-session-lifecycle.test.js
// Purpose: Verifies session store CRUD, durability, and provider session persistence
//          on turn start.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-session-store,
//             ../src/opencode-provider

const test = require("node:test");
const assert = require("node:assert/strict");
const { createOpenCodeSessionStore } = require("../src/opencode-session-store");
const { createOpenCodeProvider } = require("../src/opencode-provider");

// --- Session store tests ---

function fakeFs() {
  const files = new Map();
  return {
    readFileSync(path) {
      if (files.has(path)) {
        return files.get(path);
      }
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
    mkdirSync(dir, opts) {},
  };
}

function makeSessionStore(opts = {}) {
  return createOpenCodeSessionStore({
    storagePath: opts.storagePath || "/tmp/test-sessions.json",
    fsImpl: opts.fs || fakeFs(),
    nowMs: opts.nowMs || (() => 1000000),
  });
}

test("set and get session ID", () => {
  const store = makeSessionStore();
  const ok = store.set("thread-1", "ses_abc123");
  assert.equal(ok, true);
  assert.equal(store.get("thread-1"), "ses_abc123");
});

test("remove session ID", () => {
  const store = makeSessionStore();
  store.set("thread-2", "ses_def456");
  assert.equal(store.get("thread-2"), "ses_def456");

  const removed = store.remove("thread-2");
  assert.equal(removed, true);
  assert.equal(store.get("thread-2"), null);
});

test("entries returns all stored sessions", () => {
  const store = makeSessionStore();
  store.set("t-a", "ses_a");
  store.set("t-b", "ses_b");

  const entries = store.entries();
  assert.equal(entries.length, 2);
  const byId = new Map(entries.map(([threadId, entry]) => [threadId, entry.sessionId]));
  assert.equal(byId.get("t-a"), "ses_a");
  assert.equal(byId.get("t-b"), "ses_b");
});

test("set persists cwd model agent metadata", () => {
  const store = makeSessionStore();
  store.set("t-meta", "ses_meta", {
    cwd: "/tmp/project",
    model: "anthropic/claude-sonnet-4-5",
    agent: "plan",
    title: "My chat",
  });
  const entry = store.getEntry("t-meta");
  assert.equal(entry.sessionId, "ses_meta");
  assert.equal(entry.cwd, "/tmp/project");
  assert.equal(entry.model, "anthropic/claude-sonnet-4-5");
  assert.equal(entry.agent, "plan");
  assert.equal(entry.title, "My chat");
});

test("durable across store instances", () => {
  const fs = fakeFs();
  const store1 = makeSessionStore({ fs });
  store1.set("thread-dur", "ses_durable");
  assert.equal(store1.get("thread-dur"), "ses_durable");

  const store2 = makeSessionStore({ fs });
  assert.equal(store2.get("thread-dur"), "ses_durable");
});

test("handles missing session", () => {
  const store = makeSessionStore();
  assert.equal(store.get("no-such-thread"), null);
});

test("handles empty thread ID", () => {
  const store = makeSessionStore();
  const ok = store.set("", "ses_empty");
  assert.equal(ok, false);
});

test("getBySessionId returns owned thread mapping", () => {
  const store = makeSessionStore();
  store.set("opencode-thread-owned", "ses_owned", { cwd: "/tmp/project" });
  const entry = store.getBySessionId("ses_owned");
  assert.equal(entry.threadId, "opencode-thread-owned");
  assert.equal(entry.sessionId, "ses_owned");
  assert.equal(entry.cwd, "/tmp/project");
});

test("discovered index persists metadata until adopt", () => {
  const fs = fakeFs();
  const store = makeSessionStore({ fs });
  store.setDiscovered("ses_discovered", {
    threadId: "opencode-session-ses_discovered",
    cwd: "/tmp/mac",
    title: "Mac session",
    model: "opencode/gpt-5.5",
    agent: "build",
  });
  const entry = store.getDiscovered("ses_discovered");
  assert.equal(entry.threadId, "opencode-session-ses_discovered");
  assert.equal(entry.adopted, false);

  store.markAdopted("ses_discovered");
  const store2 = makeSessionStore({ fs });
  const adopted = store2.getDiscovered("ses_discovered");
  assert.equal(adopted.adopted, true);
});

// --- Provider session lifecycle tests ---

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

function fakeSessionStore() {
  const state = new Map();
  return {
    set(threadId, sessionId, metadata = {}) {
      state.set(threadId, {
        sessionId,
        cwd: metadata.cwd || "",
        model: metadata.model || "",
        agent: metadata.agent || "",
        title: metadata.title || "",
        updatedAt: new Date().toISOString(),
      });
      return true;
    },
    get(threadId) {
      return state.get(threadId)?.sessionId || null;
    },
    getEntry(threadId) {
      const entry = state.get(threadId);
      return entry ? { ...entry } : null;
    },
    remove(threadId) {
      return state.delete(threadId);
    },
    entries() {
      return Array.from(state.entries());
    },
  };
}

function fakeClient() {
  return {
    listModels: async () => [],
    listAgents: async () => [],
    createSession: async () => "ses_lifecycle_001",
    getSession: async () => ({}),
    prompt: async () => Promise.resolve(),

    abort: async () => {},
    fork: async () => "ses_forked",
    getMessages: async () => [],
    replyToPermission: async () => {},
    subscribeToEvents: () => () => {},
  };
}

test("session persisted on turn start", async () => {
  const sessionStore = fakeSessionStore();
  const provider = createOpenCodeProvider({
    sendApplicationMessage: () => {},
    serverFactory: () => fakeServer(),
    clientFactory: () => fakeClient(),
    ownershipStore: fakeOwnershipStore(),
    sessionStore,
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { title: "Session lifecycle test" },
  });

  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test session persistence" },
  });

  // Wait for executeTurn to run (Promise.resolve().then() chain)
  await new Promise((resolve) => setImmediate(resolve));

  const stored = sessionStore.get(start.thread.id);
  assert.equal(stored, "ses_lifecycle_001");

  await provider.shutdown();
});
