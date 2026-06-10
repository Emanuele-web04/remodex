// FILE: opencode-provider.harness.js

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  buildStaticSlashCommands,
  createOpenCodeClient,
  dispatchEvent,
} = require("../src/opencode-client");
const {
  createOpenCodeProvider,
  DEFAULT_ENSURE_STARTED_LIST_CAP_MS,
  DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS,
  DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN,
  resolveEnsureStartedListCapMs,
  resolveEnsureStartedServeWakeCapMs,
  resolveValidationRpcLimitPerMin,
} = require("../src/opencode-provider");
const { createOpenCodeSessionStore } = require("../src/opencode-session-store");
const { createThreadOwnershipStore } = require("../src/thread-ownership-store");

function testProjectPath(name) {
  return path.join(os.homedir(), `.remodex-test-${name}`);
}

const activeProviders = [];

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

function createProbeMockClient({ connected = [], auth = {} } = {}) {
  return async () =>
    createOpenCodeClient({
      baseUrl: "http://127.0.0.1:4291",
      createOpencodeClientImpl: () => () => ({
        provider: {
          list: async () => ({ connected }),
          auth: async () => auth,
        },
        app: { agents: async () => ({ data: [] }), skills: async () => [] },
        session: {
          create: async () => "ses_probe",
          get: async () => ({}),
          prompt: async () => ({}),
          setConfig: async () => ({}),
          abort: async () => ({}),
          messages: async () => ({ messages: [] }),
          fork: async () => "ses_fork",
        },
        permission: { reply: async () => ({}) },
        command: { list: async () => [] },
        event: {
          subscribe: async () => ({
            stream: (async function* empty() {})(),
            close: () => {},
          }),
        },
        tui: { selectSession: async () => ({}) },
      }),
    });
}

function fakeSessionStoreFs() {
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
    mkdirSync() {},
  };
}

const ASSISTANT_REPLY = "Hey back from OpenCode";

function assistantMessagesSnapshot(text = ASSISTANT_REPLY, foreignPartId = "opencode-part-foreign-999") {
  return {
    data: [
      {
        info: {
          id: "msg-assistant",
          role: "assistant",
          time: { created: Date.now(), completed: Date.now() },
        },
        parts: [{ id: foreignPartId, type: "text", text }],
      },
    ],
  };
}

function collectItemCompleted(messages) {
  return messages.filter((entry) => entry.method === "item/completed");
}

function captureTelemetryLogs(eventName) {
  const events = [];
  const originalLog = console.log;
  console.log = (...args) => {
    for (const arg of args) {
      if (typeof arg !== "string") {
        continue;
      }
      try {
        const payload = JSON.parse(arg);
        if (payload.event === eventName) {
          events.push(payload);
        }
      } catch {
        // ignore non-JSON log lines
      }
    }
    originalLog(...args);
  };
  return {
    events,
    restore() {
      console.log = originalLog;
    },
  };
}

async function waitForItemCompleted(messages, { min = 1, timeoutMs = 2000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (collectItemCompleted(messages).length >= min) {
      return collectItemCompleted(messages);
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  return collectItemCompleted(messages);
}

const itemCompletedIdempotencyScenarios = [
  {
    name: "sse foreign itemId then turn/completed",
    foreignItemId: "opencode-part-foreign-999",
    fireSseItemCompleted: true,
    fireTurnCompleted: true,
    promptResolves: true,
    hangPrompt: false,
  },
  {
    name: "turn/completed hydrates without prior SSE item/completed",
    foreignItemId: "opencode-part-foreign-abc",
    fireSseItemCompleted: false,
    fireTurnCompleted: true,
    promptResolves: true,
    hangPrompt: false,
  },
  {
    name: "poll hydration after hung prompt",
    foreignItemId: "opencode-part-foreign-poll",
    fireSseItemCompleted: false,
    fireTurnCompleted: false,
    promptResolves: false,
    hangPrompt: true,
  },
  {
    name: "finally hydrate when prompt resolves without turn/completed",
    foreignItemId: "opencode-part-foreign-finally",
    fireSseItemCompleted: false,
    fireTurnCompleted: false,
    promptResolves: true,
    hangPrompt: false,
  },
  {
    name: "sse foreign itemId plus poll and finally",
    foreignItemId: "opencode-part-foreign-all",
    fireSseItemCompleted: true,
    fireTurnCompleted: false,
    promptResolves: true,
    hangPrompt: false,
  },
];

function discoveredListClient(rows = []) {
  return {
    ...fakeClient(),
    listSessions: async () => ({ data: rows }),
    getMessages: async () => [
      {
        type: "user",
        text: "hello from mac",
        createdAt: new Date().toISOString(),
      },
      {
        type: "assistant",
        text: "hello from opencode",
        createdAt: new Date().toISOString(),
      },
    ],
  };
}

function externalDiscoveredRow({
  sessionId = "ses_external_mac",
  cwd = path.join(os.homedir(), "work", "mac-opencode"),
  title = "Mac OpenCode session",
} = {}) {
  return {
    id: `opencode-session-${sessionId}`,
    title,
    name: title,
    cwd,
    model: "opencode/gpt-5.5",
    modelProvider: "opencode",
    provider: "opencode",
    createdAt: "2026-06-08T10:00:00.000Z",
    updatedAt: "2026-06-08T11:00:00.000Z",
    metadata: {
      provider: "opencode",
      discoveredExternally: true,
      sessionId,
    },
  };
}
test.afterEach(async () => {
  while (activeProviders.length > 0) {
    const provider = activeProviders.pop();
    await provider.shutdown?.();
  }
});


module.exports = {
  ASSISTANT_REPLY,
  DEFAULT_ENSURE_STARTED_LIST_CAP_MS,
  DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS,
  DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN,
  activeProviders,
  assistantMessagesSnapshot,
  buildStaticSlashCommands,
  captureTelemetryLogs,
  collectItemCompleted,
  createOpenCodeClient,
  createOpenCodeProvider,
  createOpenCodeSessionStore,
  createProbeMockClient,
  createThreadOwnershipStore,
  discoveredListClient,
  dispatchEvent,
  externalDiscoveredRow,
  fakeClient,
  fakeOwnershipStore,
  fakeServer,
  fakeSessionStore,
  fakeSessionStoreFs,
  itemCompletedIdempotencyScenarios,
  makeProvider,
  resolveEnsureStartedListCapMs,
  resolveEnsureStartedServeWakeCapMs,
  resolveValidationRpcLimitPerMin,
  testProjectPath,
  waitForItemCompleted,
};
