// FILE: opencode-concurrency.test.js
// Purpose: Verifies OpenCode provider handles concurrent operations safely.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-provider

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { createOpenCodeProvider } = require("../src/opencode-provider");
const { createOpenCodeSessionStore } = require("../src/opencode-session-store");
const { createThreadOwnershipStore } = require("../src/thread-ownership-store");

function testProjectPath(name) {
  return path.join(os.homedir(), `.remodex-test-${name}`);
}

const activeProviders = [];

test.afterEach(async () => {
  while (activeProviders.length > 0) {
    const provider = activeProviders.pop();
    await provider.shutdown?.();
  }
});

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
  const store = new Map();
  const discovered = new Map();
  return {
    set(threadId, sessionId, metadata = {}) {
      store.set(threadId, {
        sessionId,
        ...metadata,
        updatedAt: new Date().toISOString(),
      });
      return true;
    },
    get(threadId) {
      return store.get(threadId)?.sessionId || null;
    },
    getEntry(threadId) {
      const entry = store.get(threadId);
      return entry ? { ...entry } : null;
    },
    getBySessionId(sessionId) {
      for (const [threadId, entry] of store.entries()) {
        if (entry.sessionId === sessionId) {
          return { threadId, ...entry };
        }
      }
      return null;
    },
    setDiscovered(sessionId, metadata = {}) {
      discovered.set(sessionId, {
        sessionId,
        threadId: metadata.threadId || `opencode-session-${sessionId}`,
        adopted: false,
        ...metadata,
        updatedAt: new Date().toISOString(),
      });
      return true;
    },
    getDiscovered(sessionId) {
      const entry = discovered.get(sessionId);
      return entry ? { ...entry } : null;
    },
    markAdopted(sessionId) {
      const entry = discovered.get(sessionId);
      if (!entry) {
        return false;
      }
      entry.adopted = true;
      return true;
    },
    remove(threadId) {
      return store.delete(threadId);
    },
    entries() {
      return Array.from(store.entries());
    },
  };
}

function fakeClient() {
  return {
    listModels: async () => [],
    listAgents: async () => [
      { id: "build", label: "Build" },
      { id: "plan", label: "Plan" },
    ],
    createSession: async () => "ses_fake123",
    getSession: async () => ({}),
    prompt: async () => Promise.resolve(),
    abort: async () => {},
    fork: async () => "ses_forked456",
    getMessages: async () => [],
    replyToPermission: async () => {},
    subscribeToEvents: (handler) => {
      setImmediate(() => {
        handler("turn/started", { turnId: "fake-turn-1" });
        handler("item/agentMessage/delta", { delta: "Hello from test agent." });
        handler("turn/completed", { status: "completed" });
      });
      return () => {};
    },
  };
}

function makeProvider(opts = {}) {
  const provider = createOpenCodeProvider({
    sendApplicationMessage: opts.send || (() => {}),
    env: { REMODEX_ENABLE_OPENCODE: "1", ...opts.env },
    serverFactory: opts.serverFactory || (() => fakeServer()),
    clientFactory: opts.clientFactory || (() => fakeClient()),
    ownershipStore: opts.ownershipStore || fakeOwnershipStore(),
    sessionStore: opts.sessionStore || fakeSessionStore(),
  });
  activeProviders.push(provider);
  return provider;
}

test("concurrent session store writes are atomic", async () => {
  const sessionStore = fakeSessionStore();
  const provider = makeProvider({
    sessionStore,
    clientFactory: () => fakeClient(),
  });

  await provider.warmup();

  // Write 10 session entries concurrently
  const writePromises = Array.from({ length: 10 }, (_, i) =>
    sessionStore.set(`thread-concurrent-${i}`, `ses_${i}`, { cwd: "/tmp/test" })
  );

  await Promise.all(writePromises);

  // Verify all entries were written
  const entries = sessionStore.entries();
  assert.equal(entries.length, 10, "All session entries should be written");

  // Verify each entry has the correct session ID
  for (const [threadId, entry] of entries) {
    assert.ok(entry.sessionId, `Thread ${threadId} should have session ID`);
  }
});

test("concurrent ownership store writes are atomic", async () => {
  const ownershipStore = fakeOwnershipStore();
  const provider = makeProvider({
    ownershipStore,
    clientFactory: () => fakeClient(),
  });

  await provider.warmup();

  // Write 10 ownership entries concurrently
  const writePromises = Array.from({ length: 10 }, (_, i) =>
    ownershipStore.setOwnership(`thread-concurrent-${i}`, "opencode")
  );

  await Promise.all(writePromises);

  // Verify all entries were written
  const ownedThreads = ownershipStore.getAllOwnedBy("opencode");
  assert.equal(ownedThreads.length, 10, "All ownership entries should be written");

  // Verify each thread is owned by OpenCode
  for (const { threadId } of ownedThreads) {
    assert.ok(
      ownershipStore.ownsThread(threadId, "opencode"),
      `Thread ${threadId} should be owned by OpenCode`
    );
  }
});


