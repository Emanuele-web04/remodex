// FILE: opencode-provider.test.js
// Purpose: Verifies OpenCode provider thread/turn lifecycle, streaming, and error cases.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-provider

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

test("provider has expected API surface", () => {
  const provider = makeProvider();
  assert.equal(provider.id, "opencode");
  assert.equal(typeof provider.ownsThread, "function");
  assert.equal(typeof provider.listModels, "function");
  assert.equal(typeof provider.listAgents, "function");
  assert.equal(typeof provider.listCommands, "function");
  assert.equal(typeof provider.commandExecute, "function");
  assert.equal(typeof provider.listThreads, "function");
  assert.equal(typeof provider.handleRequest, "function");
  assert.equal(typeof provider.shutdown, "function");
  assert.equal(typeof provider.getHandoffContext, "function");
});

test("listCommands returns static builtins when server factory throws on start", async () => {
  const provider = makeProvider({
    serverFactory: () => ({
      get baseUrl() {
        return "";
      },
      get isRunning() {
        return false;
      },
      start: async () => {
        throw new Error("server start failed");
      },
      stop: async () => {},
    }),
  });

  const commands = await provider.listCommands("/tmp/degraded-project");
  assert.equal(commands.length, buildStaticSlashCommands().length);
  const tokens = commands.map((command) => command.token);
  assert.ok(tokens.includes("/undo"));
  assert.ok(tokens.includes("/help"));
  assert.deepEqual(
    tokens.slice(0, buildStaticSlashCommands().length),
    buildStaticSlashCommands().map((command) => command.token),
  );
});

test("commandExecute forwards /skills to session.command command skills", async () => {
  const sdkCommandCalls = [];
  const provider = makeProvider({
    clientFactory: ({ baseUrl, logPrefix }) =>
      createOpenCodeClient({
        baseUrl,
        logPrefix,
        createOpencodeClientImpl: () => ({
          session: {
            create: async () => ({ sessionID: "ses_skills123" }),
            command: async (body) => {
              sdkCommandCalls.push(body);
              return { info: {}, parts: [] };
            },
          },
          command: {
            list: async () => [],
          },
        }),
      }),
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { cwd: testProjectPath("skills-project") },
  });

  const result = await provider.commandExecute({
    id: 2,
    method: "command/execute",
    params: {
      threadId: start.thread.id,
      command: "/skills",
      arguments: "",
      directory: testProjectPath("skills-project"),
    },
  });

  assert.equal(result.ok, true);
  assert.equal(result.sessionId, "ses_skills123");
  assert.equal(sdkCommandCalls.length, 1);
  assert.equal(sdkCommandCalls[0].command, "skills");
  assert.equal(sdkCommandCalls[0].arguments, "");
});

test("commandExecute dedupes duplicate clientCommandId within 5s", async () => {
  const sdkCommandCalls = [];
  const provider = makeProvider({
    clientFactory: ({ baseUrl, logPrefix }) =>
      createOpenCodeClient({
        baseUrl,
        logPrefix,
        createOpencodeClientImpl: () => ({
          session: {
            create: async () => ({ sessionID: "ses_dedupe123" }),
            command: async (body) => {
              sdkCommandCalls.push(body);
              return { info: {}, parts: [] };
            },
          },
          command: {
            list: async () => [],
          },
        }),
      }),
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { cwd: testProjectPath("dedupe-project") },
  });

  const sharedParams = {
    threadId: start.thread.id,
    command: "/skills",
    arguments: "",
    directory: testProjectPath("dedupe-project"),
    clientCommandId: "550e8400-e29b-41d4-a716-446655440000",
  };

  const first = await provider.commandExecute({
    id: 2,
    method: "command/execute",
    params: sharedParams,
  });
  const second = await provider.commandExecute({
    id: 3,
    method: "command/execute",
    params: sharedParams,
  });

  assert.equal(first.ok, true);
  assert.equal(second.ok, true);
  assert.equal(second.deduped, true);
  assert.equal(sdkCommandCalls.length, 1);
});

test("commandExecute serializes argumentFields before session.command", async () => {
  const sdkCommandCalls = [];
  const provider = makeProvider({
    clientFactory: ({ baseUrl, logPrefix }) =>
      createOpenCodeClient({
        baseUrl,
        logPrefix,
        createOpencodeClientImpl: () => ({
          session: {
            create: async () => ({ sessionID: "ses_args123" }),
            command: async (body) => {
              sdkCommandCalls.push(body);
              return { info: {}, parts: [] };
            },
          },
          command: {
            list: async () => [
              {
                name: "plan",
                title: "Plan",
                description: "Plan work",
                template: "Plan for $1 with notes $2",
                hints: ["$1", "$2"],
              },
            ],
          },
        }),
      }),
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { cwd: testProjectPath("args-project") },
  });

  const result = await provider.commandExecute({
    id: 2,
    method: "command/execute",
    params: {
      threadId: start.thread.id,
      command: "/plan",
      directory: testProjectPath("args-project"),
      template: "Plan for $1 with notes $2",
      hints: ["$1", "$2"],
      argumentFields: [
        { key: "$1", value: "auth" },
        { key: "$2", value: "edge cases" },
      ],
    },
  });

  assert.equal(result.ok, true);
  assert.equal(sdkCommandCalls.length, 1);
  assert.equal(sdkCommandCalls[0].command, "plan");
  assert.equal(sdkCommandCalls[0].arguments, 'auth "edge cases"');
});

test("commandExecute rejects requiresArguments commands without argumentFields", async () => {
  const provider = makeProvider({
    clientFactory: ({ baseUrl, logPrefix }) =>
      createOpenCodeClient({
        baseUrl,
        logPrefix,
        createOpencodeClientImpl: () => ({
          session: {
            create: async () => ({ sessionID: "ses_reject123" }),
            command: async () => ({}),
          },
          command: {
            list: async () => [
              {
                name: "review",
                title: "Review",
                description: "Review changes",
                template: "Input: $ARGUMENTS",
                hints: ["$ARGUMENTS"],
              },
            ],
          },
        }),
      }),
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { cwd: testProjectPath("reject-project") },
  });

  await assert.rejects(
    () =>
      provider.commandExecute({
        id: 2,
        method: "command/execute",
        params: {
          threadId: start.thread.id,
          command: "/review",
          directory: testProjectPath("reject-project"),
        },
      }),
    (error) => error?.errorCode === "command_arguments_required",
  );
});

test("commandExecute rejects commands not in allowlist", async () => {
  const provider = makeProvider({
    clientFactory: async () => ({
      ...fakeClient(),
      listCommands: async () => [{ token: "/build", title: "Build", description: "" }],
      sessionCommand: async () => ({}),
    }),
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: {},
  });

  await assert.rejects(
    () =>
      provider.commandExecute({
        id: 2,
        method: "command/execute",
        params: { threadId: start.thread.id, command: "/skills" },
      }),
    { errorCode: "command_not_allowed" },
  );
});

test("listCommands returns static builtins when client listCommands throws after start", async () => {
  const provider = makeProvider({
    clientFactory: async () => ({
      ...fakeClient(),
      listCommands: async () => {
        throw new Error("command.list failed");
      },
    }),
  });

  const commands = await provider.listCommands("/tmp/client-throw-project");
  assert.equal(commands.length, buildStaticSlashCommands().length);
  assert.deepEqual(
    commands.map((command) => command.token),
    buildStaticSlashCommands().map((command) => command.token),
  );
});

test("ownsThread returns false for unknown thread", () => {
  const provider = makeProvider();
  assert.equal(provider.ownsThread("unknown-thread"), false);
});

test("threadStart creates thread and records ownership", async () => {
  const provider = makeProvider();
  const result = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { model: "openai/gpt-5.5", title: "Test thread", cwd: testProjectPath("test") },
  });

  assert.ok(result.thread);
  assert.ok(result.thread.id.startsWith("opencode-thread-"));
  assert.equal(result.thread.title, "Test thread");
  assert.equal(result.thread.modelProvider, "opencode");
  assert.equal(provider.ownsThread(result.thread.id), true);
});

test("threadRead returns thread data", async () => {
  const provider = makeProvider();
  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { title: "Read test" },
  });
  const read = await provider.handleRequest({
    id: 2,
    method: "thread/read",
    params: { threadId: start.thread.id },
  });
  assert.ok(read.thread);
  assert.equal(read.thread.id, start.thread.id);
});

test("threadRead throws for unknown thread", async () => {
  const provider = makeProvider();
  await assert.rejects(
    () => provider.handleRequest({ id: 1, method: "thread/read", params: { threadId: "nope" } }),
    { errorCode: "thread_not_found" },
  );
});

test("threadArchive toggles archived flag", async () => {
  const provider = makeProvider();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "thread/archive",
    params: { threadId: start.thread.id },
  });
  const list = await provider.listThreads({ includeArchived: true });
  const found = list.data.find((t) => t.id === start.thread.id);
  assert.ok(found);
});

test("threadNameSet updates title", async () => {
  const messages = [];
  const provider = makeProvider({ send: (msg) => messages.push(JSON.parse(msg)) });
  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { title: "Old name" },
  });
  const result = await provider.handleRequest({
    id: 2,
    method: "thread/name/set",
    params: { threadId: start.thread.id, name: "New name" },
  });
  assert.equal(result.thread.title, "New name");
  assert.ok(messages.some((m) => m.method === "thread/name/updated"));
});

test("turnStart requires text input", async () => {
  const provider = makeProvider();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 2,
        method: "turn/start",
        params: { threadId: start.thread.id },
      }),
    { errorCode: "opencode_input_required" },
  );
});

test("threadStart honors REMODEX_OPENCODE_DEFAULT_AGENT when no agent is supplied", async () => {
  const provider = makeProvider({ env: { REMODEX_OPENCODE_DEFAULT_AGENT: "plan" } });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  assert.equal(start.thread.agent, "plan");
});

test("turnStart rejects an agent that is missing from the cached catalog", async () => {
  const provider = makeProvider();
  await provider.listAgents();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 2,
        method: "turn/start",
        params: {
          threadId: start.thread.id,
          agent: "ghost-agent",
          input: [{ type: "text", text: "hello" }],
        },
      }),
    { errorCode: "opencode_agent_unavailable" },
  );
});

test("turnStart accepts an agent present in the cached catalog", async () => {
  const provider = makeProvider();
  await provider.listAgents();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const result = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: {
      threadId: start.thread.id,
      agent: "plan",
      input: [{ type: "text", text: "hello" }],
    },
  });
  assert.ok(result.turn);
});

test("turnStart with collaborationMode plan maps the turn to the plan agent without touching thread agent", async () => {
  const promptCalls = [];
  let resolvePrompted;
  const prompted = new Promise((resolve) => {
    resolvePrompted = resolve;
  });
  const provider = makeProvider({
    clientFactory: () => ({
      ...fakeClient(),
      prompt: async (body) => {
        promptCalls.push(body);
        resolvePrompted();
      },
    }),
  });
  await provider.listAgents();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: {
      threadId: start.thread.id,
      agent: "build",
      collaborationMode: { mode: "plan", settings: { model: "openai/gpt-5.5" } },
      input: [{ type: "text", text: "plan this" }],
    },
  });
  await prompted;
  assert.equal(promptCalls.length, 1);
  assert.equal(promptCalls[0].agent, "plan");
  const read = await provider.handleRequest({
    id: 3,
    method: "thread/read",
    params: { threadId: start.thread.id },
  });
  assert.equal(read.thread.agent, "build");
});

test("turnStart with snake_case collaboration_mode plan also maps to the plan agent", async () => {
  const promptCalls = [];
  let resolvePrompted;
  const prompted = new Promise((resolve) => {
    resolvePrompted = resolve;
  });
  const provider = makeProvider({
    clientFactory: () => ({
      ...fakeClient(),
      prompt: async (body) => {
        promptCalls.push(body);
        resolvePrompted();
      },
    }),
  });
  await provider.listAgents();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: {
      threadId: start.thread.id,
      agent: "build",
      collaboration_mode: { mode: "plan" },
      input: [{ type: "text", text: "plan this" }],
    },
  });
  await prompted;
  assert.equal(promptCalls[0].agent, "plan");
});

test("turnStart keeps the requested agent when plan agent is missing from the catalog", async () => {
  const promptCalls = [];
  let resolvePrompted;
  const prompted = new Promise((resolve) => {
    resolvePrompted = resolve;
  });
  const provider = makeProvider({
    clientFactory: () => ({
      ...fakeClient(),
      listAgents: async () => [{ id: "build", label: "Build" }],
      prompt: async (body) => {
        promptCalls.push(body);
        resolvePrompted();
      },
    }),
  });
  await provider.listAgents();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: {
      threadId: start.thread.id,
      agent: "build",
      collaborationMode: { mode: "plan" },
      input: [{ type: "text", text: "plan this" }],
    },
  });
  await prompted;
  assert.equal(promptCalls[0].agent, "build");
});

test("turnStart with collaborationMode default does not override the agent", async () => {
  const promptCalls = [];
  let resolvePrompted;
  const prompted = new Promise((resolve) => {
    resolvePrompted = resolve;
  });
  const provider = makeProvider({
    clientFactory: () => ({
      ...fakeClient(),
      prompt: async (body) => {
        promptCalls.push(body);
        resolvePrompted();
      },
    }),
  });
  await provider.listAgents();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: {
      threadId: start.thread.id,
      agent: "build",
      collaborationMode: { mode: "default" },
      input: [{ type: "text", text: "hello" }],
    },
  });
  await prompted;
  assert.equal(promptCalls[0].agent, "build");
});

test("turnStart on already-running thread throws", async () => {
  const provider = makeProvider();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });
  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 3,
        method: "turn/start",
        params: { threadId: start.thread.id, input: "test2" },
      }),
    { errorCode: "thread_turn_active" },
  );
});

test("turnInterrupt aborts session while prompt is in flight", async () => {
  let abortSessionId = null;
  let promptEntered = false;
  let resolvePrompt;
  const promptGate = new Promise((resolve) => {
    resolvePrompt = resolve;
  });
  const provider = makeProvider({
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      prompt: () => {
        promptEntered = true;
        return promptGate;
      },
      abort: async (sessionId) => {
        abortSessionId = sessionId;
      },
    }),
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turn = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });
  const deadline = Date.now() + 2000;
  while (Date.now() < deadline && !promptEntered) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.equal(promptEntered, true);
  const result = await provider.handleRequest({
    id: 3,
    method: "turn/interrupt",
    params: { threadId: start.thread.id, turnId: turn.turnId },
  });
  assert.equal(result.interrupted, true);
  assert.equal(abortSessionId, "ses_fake123");
  resolvePrompt();
  await provider.shutdown();
});

test("turnStart rejects while prior turn prompt is still in flight after interrupt", async () => {
  let promptEntered = false;
  let resolvePrompt;
  const promptGate = new Promise((resolve) => {
    resolvePrompt = resolve;
  });
  const provider = makeProvider({
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      prompt: () => {
        promptEntered = true;
        return promptGate;
      },
      abort: async () => {},
    }),
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "first" },
  });
  const deadline = Date.now() + 2000;
  while (Date.now() < deadline && !promptEntered) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.equal(promptEntered, true);
  await provider.handleRequest({
    id: 3,
    method: "turn/interrupt",
    params: { threadId: start.thread.id },
  });
  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 4,
        method: "turn/start",
        params: { threadId: start.thread.id, input: "second" },
      }),
    { errorCode: "thread_turn_active" },
  );
  resolvePrompt();
  await provider.shutdown();
});

test("restoreSessions during ensureStarted does not drop active turn tracking", async () => {
  let promptEntered = false;
  let resolvePrompt;
  const promptGate = new Promise((resolve) => {
    resolvePrompt = resolve;
  });
  const provider = makeProvider({
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      prompt: () => {
        promptEntered = true;
        return promptGate;
      },
    }),
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turn = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hold" },
  });
  const deadline = Date.now() + 2000;
  while (Date.now() < deadline && !promptEntered) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.equal(promptEntered, true);
  const result = await provider.handleRequest({
    id: 3,
    method: "turn/interrupt",
    params: { threadId: start.thread.id, turnId: turn.turnId },
  });
  assert.equal(result.interrupted, true);
  resolvePrompt();
  await provider.shutdown();
});

test("turnInterrupt completes running turn", async () => {
  let completed = false;
  const provider = makeProvider({
    send: (msg) => {
      const p = JSON.parse(msg);
      if (p.method === "turn/completed" && p.params.status === "stopped") completed = true;
    },
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });
  const result = await provider.handleRequest({
    id: 3,
    method: "turn/interrupt",
    params: { threadId: start.thread.id },
  });
  assert.equal(result.success, true);
  assert.equal(result.interrupted, true);
  assert.equal(completed, true);
});

test("listThreads returns created threads", async () => {
  const provider = makeProvider();
  await provider.handleRequest({ id: 1, method: "thread/start", params: { title: "First" } });
  await provider.handleRequest({ id: 2, method: "thread/start", params: { title: "Second" } });
  const list = await provider.listThreads();
  assert.ok(list.data.length >= 2);
});

test("unsupported method throws error", async () => {
  const provider = makeProvider();
  await assert.rejects(() => provider.handleRequest({ id: 1, method: "turn/steer", params: {} }), {
    errorCode: "unsupported_opencode_method",
  });
});

test("shutdown cleans up state", async () => {
  const provider = makeProvider();
  await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.shutdown();
});

test("listAgents returns agents from client", async () => {
  const provider = makeProvider();
  const agents = await provider.listAgents();
  assert.ok(Array.isArray(agents));
  assert.ok(agents.some((a) => a.id === "build"));
});

test("turnStart emits turn/started notification", async () => {
  const messages = [];
  const provider = makeProvider({ send: (msg) => messages.push(JSON.parse(msg)) });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hello world" },
  });
  const deadline = Date.now() + 500;
  while (!messages.some((m) => m.method === "turn/started") && Date.now() < deadline) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.ok(messages.some((m) => m.method === "turn/started"));
});

test("turnStart returns turnId and status running", async () => {
  const provider = makeProvider();
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const result = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });
  assert.ok(result.turnId);
  assert.ok(result.turnId.startsWith("opencode-turn-"));
  assert.equal(result.turn.status, "running");
});

test("thread/turns/list prefers in-memory bridge turn ids over SDK synthetic ids", async () => {
  const provider = makeProvider({
    clientFactory: () => ({
      ...fakeClient(),
      getMessages: async () => [
        {
          id: "msg-user-1",
          role: "user",
          content: [{ type: "text", text: "Hey" }],
        },
        {
          id: "msg-assistant-1",
          role: "assistant",
          content: [{ type: "text", text: "Hello back" }],
        },
      ],
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turn = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "Hey" },
  });
  await new Promise((resolve) => setImmediate(resolve));

  const listed = await provider.handleRequest({
    id: 3,
    method: "thread/turns/list",
    params: { threadId: start.thread.id, limit: 10 },
  });

  assert.ok(Array.isArray(listed.data));
  assert.equal(listed.data.length, 1);
  assert.equal(listed.data[0].id, turn.turnId);
  assert.notEqual(listed.data[0].id, "turn-0");
  const userItem = listed.data[0].items.find((item) => item.type === "userMessage");
  assert.equal(userItem?.text, "Hey");
});

test("threadFork creates new thread with forked session", async () => {
  const provider = makeProvider();
  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { title: "Source thread" },
  });

  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test fork" },
  });

  // Wait for executeTurn to set sessionId
  await new Promise((resolve) => setImmediate(resolve));

  const forkResult = await provider.handleRequest({
    id: 3,
    method: "thread/fork",
    params: { threadId: start.thread.id },
  });

  assert.ok(forkResult.thread);
  assert.ok(forkResult.thread.id.startsWith("opencode-thread-"));
  assert.notEqual(forkResult.thread.id, start.thread.id);
  assert.equal(provider.ownsThread(forkResult.thread.id), true);
});

test("threadFork without session returns error", async () => {
  const provider = makeProvider();
  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { title: "No session thread" },
  });

  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 2,
        method: "thread/fork",
        params: { threadId: start.thread.id },
      }),
    { errorCode: "opencode_fork_requires_session" },
  );
});

test("threadFork on unknown thread returns error", async () => {
  const provider = makeProvider();
  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 1,
        method: "thread/fork",
        params: { threadId: "nonexistent" },
      }),
    { errorCode: "thread_not_found" },
  );
});

test("duplicate turn/completed from session.idle is ignored after first completion", async () => {
  const emitted = [];
  const provider = makeProvider({
    send: (raw) => {
      const message = JSON.parse(raw);
      emitted.push(message);
    },
    clientFactory: () => ({
      ...fakeClient(),
      getMessages: async () => [
        {
          info: { id: "msg-1", role: "assistant", time: { created: Date.now(), completed: Date.now() } },
          parts: [{ id: "part-1", type: "text", text: "done" }],
        },
      ],
      subscribeToEvents: (handler) => {
        setImmediate(() => {
          dispatchEvent({ type: "turn/completed", status: "completed" }, handler);
          dispatchEvent(
            { type: "session.idle", properties: { sessionID: "ses_fake123" } },
            handler,
          );
        });
        return () => {};
      },
    }),
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { title: "Idle dedupe" },
  });
  const turn = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hello" },
  });

  const bridgeItemId = `opencode-agent-${turn.turnId}`;
  const deadline = Date.now() + 2000;
  let turnCompletedCount = 0;
  let itemCompletedCount = 0;
  while (Date.now() < deadline) {
    turnCompletedCount = emitted.filter((message) => message.method === "turn/completed").length;
    itemCompletedCount = emitted.filter((message) => message.method === "item/completed").length;
    if (turnCompletedCount >= 1 && itemCompletedCount >= 1) {
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.equal(turnCompletedCount, 1);
  assert.equal(itemCompletedCount, 1);
  const itemCompleted = emitted.find((message) => message.method === "item/completed");
  assert.equal(itemCompleted.params.itemId, bridgeItemId);
  assert.equal(itemCompleted.params.item.id, bridgeItemId);
});

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

test("listModels with unknown meta sets authConfigured null", async () => {
  const client = {
    ...fakeClient(),
    listModels: async () => ({
      models: [],
      meta: {
        reasonCode: "unknown",
        connectedProviderIds: ["orphan-id"],
        fetchedAt: "2026-06-03T12:00:00.000Z",
        stale: false,
        modelCountBeforeCap: 0,
        modelCountAfterCap: 0,
      },
      connectedProviders: [],
    }),
    listProviderInventory: async () => ({
      inventory: { all: [], connected: ["orphan-id"], default: {} },
      models: [],
      meta: {
        reasonCode: "unknown",
        connectedProviderIds: ["orphan-id"],
        fetchedAt: "2026-06-03T12:00:00.000Z",
        stale: false,
        modelCountBeforeCap: 0,
        modelCountAfterCap: 0,
      },
      connectedProviders: [],
    }),
  };
  const provider = makeProvider({ clientFactory: async () => client });
  const result = await provider.listModels();
  assert.equal(result.meta.reasonCode, "unknown");
  assert.equal(provider.getRuntimeStatus().authConfigured, null);
});

test("forced listModels keeps live meta as source of truth", async () => {
  const liveMeta = {
    reasonCode: "ok",
    connectedProviderIds: ["anthropic"],
    fetchedAt: "2026-06-03T12:00:00.000Z",
    stale: false,
    modelCountBeforeCap: 1,
    modelCountAfterCap: 1,
  };
  const client = {
    ...fakeClient(),
    listModels: async ({ force }) => ({
      models: force
        ? [
            {
              id: "anthropic/claude",
              model: "anthropic/claude",
              modelProvider: "opencode",
              provider: "opencode",
            },
          ]
        : [],
      meta: liveMeta,
      connectedProviders: [{ id: "anthropic", displayName: "Anthropic", modelCount: 1 }],
    }),
    listProviderInventory: async ({ force }) => ({
      inventory: {
        all: [
          {
            id: "anthropic",
            name: "Anthropic",
            source: "api",
            models: { claude: { id: "claude", name: "Claude" } },
          },
        ],
        connected: ["anthropic"],
        default: {},
      },
      models: force
        ? [
            {
              id: "anthropic/claude",
              model: "anthropic/claude",
              modelProvider: "opencode",
            },
          ]
        : [],
      meta: liveMeta,
      connectedProviders: [{ id: "anthropic", displayName: "Anthropic", modelCount: 1 }],
    }),
  };
  const provider = makeProvider({ clientFactory: async () => client });
  await provider.listModels({ force: true, refreshProviders: true });
  assert.equal(provider.getLastModelListMeta()?.reasonCode, "ok");
  assert.equal(provider.getRuntimeStatus().authConfigured, true);
});

test("forced listModels does not adopt stale inventory meta over live listModels meta", async () => {
  const liveMeta = {
    reasonCode: "unknown",
    connectedProviderIds: ["orphan-id"],
    fetchedAt: "2026-06-03T12:00:00.000Z",
    stale: false,
    modelCountBeforeCap: 0,
    modelCountAfterCap: 0,
  };
  const staleInventoryMeta = {
    reasonCode: "ok",
    connectedProviderIds: ["anthropic"],
    fetchedAt: "2026-06-02T00:00:00.000Z",
    stale: true,
    modelCountBeforeCap: 5,
    modelCountAfterCap: 5,
  };
  const client = {
    ...fakeClient(),
    listModels: async () => ({
      models: [],
      meta: liveMeta,
      connectedProviders: [],
    }),
    listProviderInventory: async () => ({
      inventory: { all: [], connected: ["orphan-id"], default: {} },
      models: [
        {
          id: "anthropic/claude",
          model: "anthropic/claude",
          modelProvider: "opencode",
        },
      ],
      meta: staleInventoryMeta,
      connectedProviders: [{ id: "anthropic", displayName: "Anthropic", modelCount: 1 }],
    }),
  };
  const provider = makeProvider({ clientFactory: async () => client });
  await provider.listModels({ force: true, refreshProviders: true });
  assert.equal(provider.getLastModelListMeta()?.reasonCode, "unknown");
  assert.equal(provider.getLastModelListMeta()?.stale, false);
  assert.equal(provider.getRuntimeStatus().authConfigured, null);
});

test("getRuntimeStatus exposes authConfigured after connected provider probe", async () => {
  const probeClient = {
    ...fakeClient(),
    probeConnectedProviders: async () => true,
    probeProviderAuthState: async () => null,
  };
  const provider = makeProvider({
    clientFactory: async () => probeClient,
  });

  await provider.warmup();

  const status = provider.getRuntimeStatus();
  assert.equal(status.authConfigured, true);
});

test("listThreads drops ownership without session", async () => {
  const ownershipStore = fakeOwnershipStore();
  ownershipStore.setOwnership("opencode-thread-orphan", "opencode");
  const provider = makeProvider({
    ownershipStore,
    sessionStore: fakeSessionStore(),
  });
  const list = await provider.listThreads();
  assert.equal(
    list.data.find((thread) => thread.id === "opencode-thread-orphan"),
    undefined,
  );
  assert.equal(ownershipStore.ownsThread("opencode-thread-orphan", "opencode"), false);
});

test("listThreads removes invalid session and ownership", async () => {
  let getSessionCalls = 0;
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  sessionStore.set("opencode-thread-bad", "ses_gone", { title: "Bad" });
  ownershipStore.setOwnership("opencode-thread-bad", "opencode");
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    clientFactory: async () => ({
      ...fakeClient(),
      getSession: async () => {
        getSessionCalls += 1;
        const error = new Error("session not found");
        error.status = 404;
        throw error;
      },
    }),
  });
  await provider.warmup();
  const list = await provider.listThreads();
  assert.equal(
    list.data.find((thread) => thread.id === "opencode-thread-bad"),
    undefined,
  );
  assert.equal(ownershipStore.ownsThread("opencode-thread-bad", "opencode"), false);
  assert.equal(sessionStore.get("opencode-thread-bad"), null);
  assert.ok(getSessionCalls >= 1);
});

test("listThreads respects SDK validation cap per call", async () => {
  let getSessionCalls = 0;
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: { REMODEX_ENABLE_OPENCODE: "1", REMODEX_LIST_THREADS_VALIDATE_CAP: "5" },
    clientFactory: async () => ({
      ...fakeClient(),
      getSession: async () => {
        getSessionCalls += 1;
        return {};
      },
      getMessages: async () => [{ role: "assistant", text: "activity" }],
    }),
  });
  await provider.warmup();
  for (let index = 0; index < 10; index += 1) {
    const threadId = `opencode-thread-cap-${index}`;
    sessionStore.set(threadId, `ses_${index}`);
    ownershipStore.setOwnership(threadId, "opencode");
  }
  getSessionCalls = 0;
  const list = await provider.listThreads();
  assert.equal(getSessionCalls, 5);
  assert.equal(list.data.length, 5);
});

test("listThreads omits ownership stub with valid session but no activity", async () => {
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  sessionStore.set("opencode-thread-ghost", "ses_empty", { title: "OpenCode chat" });
  ownershipStore.setOwnership("opencode-thread-ghost", "opencode");
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    clientFactory: async () => ({
      ...fakeClient(),
      getSession: async () => ({}),
      getMessages: async () => [],
    }),
  });
  await provider.warmup();
  const list = await provider.listThreads();
  assert.equal(
    list.data.find((thread) => thread.id === "opencode-thread-ghost"),
    undefined,
  );
});

test("restoreSessions on startup does not call getMessages for store entries", async () => {
  let getMessagesCalls = 0;
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  sessionStore.set("opencode-thread-lazy", "ses_lazy", { title: "Lazy store" });
  ownershipStore.setOwnership("opencode-thread-lazy", "opencode");
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    clientFactory: async () => ({
      ...fakeClient(),
      getMessages: async () => {
        getMessagesCalls += 1;
        return [];
      },
    }),
  });
  await provider.warmup();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(getMessagesCalls, 0);
});

test("turn/failed from subscribe completes turn and clears activeTurns", async () => {
  let completed = false;
  const provider = makeProvider({
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "turn/completed" && payload.params.status === "failed") {
        completed = true;
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: (handler) => {
        setImmediate(() => {
          handler("turn/failed", { message: "boom" });
        });
        return () => {};
      },
      prompt: () => new Promise(() => {}),
    }),
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "x" },
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(completed, true);
});

test("prompt resolves without turn/completed still completes via getMessages", async () => {
  let completed = false;
  const provider = makeProvider({
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "turn/completed" && payload.params.status === "completed") {
        completed = true;
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      getMessages: async () => [{ role: "assistant", text: "Hello" }],
      prompt: async () => {},
    }),
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hey" },
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(completed, true);
});

test("hydrate after streamed assistant text does not emit duplicate delta", async () => {
  const streamedText = "Hey back from OpenCode";
  let deltas = 0;
  const provider = makeProvider({
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "item/agentMessage/delta") {
        deltas += 1;
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: (handler) => {
        handler("item/agentMessage/delta", { delta: streamedText });
        return () => {};
      },
      getMessages: async () => ({
        data: [
          {
            info: {
              id: "msg-assistant",
              role: "assistant",
              time: { created: Date.now(), completed: Date.now() },
            },
            parts: [{ id: "part-text", type: "text", text: streamedText }],
          },
        ],
      }),
      prompt: () => new Promise(() => {}),
    }),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "200",
    },
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hey" },
  });
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert.equal(deltas, 1, "hydrate must not re-emit delta when assistant text already streamed");
});

test("sse item/completed finalizes assistant and emits turn/completed without session.idle", async () => {
  const assistantText = "Hey! What can I help you with?";
  let turnCompleted = false;
  const provider = makeProvider({
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "turn/completed" && payload.params.status === "completed") {
        turnCompleted = true;
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: (handler) => {
        setImmediate(() => {
          handler("item/completed", {
            message: assistantText,
            assistantPhase: "final_answer",
            item: {
              type: "agentMessage",
              phase: "final",
              text: assistantText,
            },
          });
        });
        return () => {};
      },
      getMessages: async () => [],
      prompt: () => new Promise(() => {}),
    }),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "500",
    },
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hey" },
  });
  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && !turnCompleted) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.equal(turnCompleted, true, "expected turn/completed after SSE item/completed finalizes assistant");
});

test("poll hydration completes via getMessages info/parts snapshots", async () => {
  let completed = false;
  let deltas = 0;
  const provider = makeProvider({
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "item/agentMessage/delta") {
        deltas += 1;
      }
      if (payload.method === "turn/completed" && payload.params.status === "completed") {
        completed = true;
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      getMessages: async () => ({
        data: [
          {
            info: {
              id: "msg-assistant",
              role: "assistant",
              time: { created: Date.now(), completed: Date.now() },
            },
            parts: [{ id: "part-text", type: "text", text: "Hey back from OpenCode" }],
          },
        ],
      }),
      prompt: () => new Promise(() => {}),
    }),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "200",
    },
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hey" },
  });
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert.ok(deltas >= 1, "expected assistant delta from hydration");
  assert.equal(completed, true);
});

test("poll hydration uses assistant after current user prompt", async () => {
  const currentAnswer = "I am the assistant responding to the second turn.";
  const deltas = [];
  const provider = makeProvider({
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "item/agentMessage/delta") {
        deltas.push(payload.params.delta);
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      getMessages: async () => ({
        data: [
          {
            info: { id: "msg-user-1", role: "user" },
            parts: [{ type: "text", text: "Hey" }],
          },
          {
            info: { id: "msg-assistant-1", role: "assistant" },
            parts: [{ type: "text", text: "Hey" }],
          },
          {
            info: { id: "msg-user-2", role: "user" },
            parts: [{ type: "text", text: "Who are you" }],
          },
          {
            info: { id: "msg-assistant-2", role: "assistant" },
            parts: [{ type: "text", text: currentAnswer }],
          },
        ],
      }),
      prompt: () => new Promise(() => {}),
    }),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "200",
    },
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "Who are you" },
  });
  await new Promise((resolve) => setTimeout(resolve, 350));

  assert.deepEqual(deltas, [currentAnswer]);
});

test("poll hydration does not reuse prior assistant before current reply exists", async () => {
  const priorAnswer = "Hey. What can I help you with?";
  const deltas = [];
  let completed = false;
  const provider = makeProvider({
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "item/agentMessage/delta") {
        deltas.push(payload.params.delta);
      }
      if (payload.method === "turn/completed" && payload.params.status === "completed") {
        completed = true;
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      getMessages: async () => ({
        data: [
          {
            info: { id: "msg-user-1", role: "user" },
            parts: [{ type: "text", text: "Hey" }],
          },
          {
            info: { id: "msg-assistant-1", role: "assistant" },
            parts: [{ type: "text", text: priorAnswer }],
          },
          {
            info: { id: "msg-user-2", role: "user" },
            parts: [{ type: "text", text: "Who are you" }],
          },
        ],
      }),
      prompt: () => new Promise(() => {}),
    }),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "200",
    },
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "Who are you" },
  });
  await new Promise((resolve) => setTimeout(resolve, 350));

  assert.deepEqual(deltas, [], "must not hydrate with a prior assistant answer");
  assert.equal(completed, false, "turn must stay open until the current reply exists");
});

test("poll hydration waits when current prompt is not in session yet", async () => {
  const priorAnswer = "Hey. What can I help you with?";
  const deltas = [];
  let completed = false;
  const provider = makeProvider({
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "item/agentMessage/delta") {
        deltas.push(payload.params.delta);
      }
      if (payload.method === "turn/completed" && payload.params.status === "completed") {
        completed = true;
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      getMessages: async () => ({
        data: [
          {
            info: { id: "msg-user-1", role: "user" },
            parts: [{ type: "text", text: "Hey" }],
          },
          {
            info: { id: "msg-assistant-1", role: "assistant" },
            parts: [{ type: "text", text: priorAnswer }],
          },
        ],
      }),
      prompt: () => new Promise(() => {}),
    }),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "200",
    },
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "Who are you" },
  });
  await new Promise((resolve) => setTimeout(resolve, 350));

  assert.deepEqual(deltas, [], "must not reuse prior assistant before prompt is persisted");
  assert.equal(completed, false);
});

test("poll hydration keeps reasoning parts out of assistant text", async () => {
  let assistantDelta = "";
  const provider = makeProvider({
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "item/agentMessage/delta") {
        assistantDelta += payload.params.delta || "";
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      getMessages: async () => ({
        data: [
          {
            info: {
              id: "msg-assistant",
              role: "assistant",
              time: { created: Date.now(), completed: Date.now() },
            },
            parts: [
              { id: "part-reasoning", type: "reasoning", text: "The user said hello." },
              { id: "part-text", type: "text", text: "Hey. What's up?" },
            ],
          },
        ],
      }),
      prompt: () => new Promise(() => {}),
    }),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "200",
    },
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hey" },
  });
  await new Promise((resolve) => setTimeout(resolve, 350));

  assert.equal(assistantDelta, "Hey. What's up?");
});

test("threadArchive stub-only removes ownership and session", async () => {
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  sessionStore.set("opencode-thread-stub", "ses_stub", { title: "Stub chat" });
  ownershipStore.setOwnership("opencode-thread-stub", "opencode");
  const provider = makeProvider({ ownershipStore, sessionStore });
  await provider.handleRequest({
    id: 1,
    method: "thread/archive",
    params: { threadId: "opencode-thread-stub" },
  });
  assert.equal(ownershipStore.ownsThread("opencode-thread-stub", "opencode"), false);
  assert.equal(sessionStore.get("opencode-thread-stub"), null);
  const list = await provider.listThreads();
  assert.equal(
    list.data.find((thread) => thread.id === "opencode-thread-stub"),
    undefined,
  );
});

test("threadArchive in-memory excludes from default list", async () => {
  const provider = makeProvider();
  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { title: "Archived in memory" },
  });
  await provider.handleRequest({
    id: 2,
    method: "thread/archive",
    params: { threadId: start.thread.id },
  });
  const listDefault = await provider.listThreads();
  assert.equal(
    listDefault.data.find((thread) => thread.id === start.thread.id),
    undefined,
  );
  const listArchived = await provider.listThreads({ includeArchived: true });
  assert.ok(listArchived.data.find((thread) => thread.id === start.thread.id));
});

test("thread/start then list before turn lists in-memory thread without session record", async () => {
  const sessionStore = fakeSessionStore();
  const provider = makeProvider({ sessionStore });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const list = await provider.listThreads();
  assert.ok(list.data.some((thread) => thread.id === start.thread.id));
  assert.equal(sessionStore.get(start.thread.id), null);
});

test("startup prune removes session_without_ownership on default startup", async () => {
  const fs = fakeSessionStoreFs();
  const ownershipStore = createThreadOwnershipStore({
    storagePath: "/tmp/opencode-prune-ownership.json",
    fsImpl: fs,
  });
  const sessionStore = createOpenCodeSessionStore({
    storagePath: "/tmp/opencode-prune-sessions.json",
    fsImpl: fs,
  });
  sessionStore.set("opencode-thread-session-only", "ses_lonely", { cwd: "/tmp" });
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
    },
  });
  await provider.warmup();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(sessionStore.get("opencode-thread-session-only"), null);
});

test("startup prune removes invalid session and ownership when env flag set", async () => {
  const fs = fakeSessionStoreFs();
  const ownershipStore = createThreadOwnershipStore({
    storagePath: "/tmp/opencode-prune-invalid-ownership.json",
    fsImpl: fs,
  });
  const sessionStore = createOpenCodeSessionStore({
    storagePath: "/tmp/opencode-prune-invalid-sessions.json",
    fsImpl: fs,
  });
  sessionStore.set("opencode-thread-stale-startup", "ses_gone", { cwd: "/tmp" });
  ownershipStore.setOwnership("opencode-thread-stale-startup", "opencode");
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_PRUNE_OPENCODE_OWNERSHIP: "1",
    },
    clientFactory: async () => ({
      ...fakeClient(),
      getSession: async () => {
        const error = new Error("session not found");
        error.status = 404;
        throw error;
      },
    }),
  });
  await provider.warmup();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(sessionStore.get("opencode-thread-stale-startup"), null);
  assert.equal(ownershipStore.ownsThread("opencode-thread-stale-startup", "opencode"), false);
});

test("watchdog completes hung prompt with opencode_turn_watchdog_timeout", async () => {
  let completedPayload = null;
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "50",
    },
    send: (msg) => {
      const payload = JSON.parse(msg);
      if (payload.method === "turn/completed") {
        completedPayload = payload;
      }
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      getMessages: async () => [],
      prompt: () => new Promise(() => {}),
    }),
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hang" },
  });
  const deadline = Date.now() + 500;
  while (!completedPayload && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.ok(completedPayload);
  assert.equal(completedPayload.params.status, "failed");
  assert.match(
    completedPayload.params.turn?.error?.message || "",
    /timed out/i,
  );
});

test("late delta suppressed when active turn mismatches (kill mid-turn scenario)", async () => {
  const lateEvents = [];
  let sseHandler = null;
  const originalLog = console.log;
  console.log = (...args) => {
    for (const arg of args) {
      if (typeof arg !== "string") {
        continue;
      }
      try {
        const payload = JSON.parse(arg);
        if (payload.event === "bridge_late_delta_suppressed") {
          lateEvents.push(payload);
        }
      } catch {
        // ignore non-JSON log lines
      }
    }
    originalLog(...args);
  };
  try {
  let promptCalls = 0;
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "300000",
    },
    clientFactory: () => ({
      ...fakeClient(),
      subscribeToEvents: (cb) => {
        sseHandler = cb;
        return () => {};
      },
      prompt: async () => {
        promptCalls += 1;
        if (promptCalls > 1) {
          return new Promise(() => {});
        }
      },
      getMessages: async () => [],
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const threadId = start.thread.id;

  const firstTurn = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId, input: "first" },
  });
  const firstTurnId = firstTurn.turnId;
  const subscribeDeadline = Date.now() + 500;
  while (!sseHandler && Date.now() < subscribeDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.ok(sseHandler, "subscribeToEvents should register before turn events are replayed");

  const interrupted = await provider.handleRequest({
    id: 3,
    method: "turn/interrupt",
    params: { threadId, turnId: firstTurnId },
  });
  assert.equal(interrupted.interrupted, true);
  await new Promise((resolve) => setTimeout(resolve, 20));

  const secondTurn = await provider.handleRequest({
    id: 4,
    method: "turn/start",
    params: { threadId, input: "second" },
  });
  const secondTurnId = secondTurn.turnId;
  assert.notEqual(firstTurnId, secondTurnId);

  const secondTurnDeadline = Date.now() + 500;
  while (promptCalls < 2 && Date.now() < secondTurnDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.equal(promptCalls, 2);

  sseHandler("item/agentMessage/delta", {
    threadId,
    turnId: firstTurnId,
    delta: "late",
  });
  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(lateEvents.length, 1);
  assert.equal(lateEvents[0].reason, "active_turn_mismatch");
  assert.equal(lateEvents[0].turnId, firstTurnId);
  assert.equal(lateEvents[0].activeTurnId, secondTurnId);
  assert.equal(lateEvents[0].method, "item/agentMessage/delta");
  } finally {
    console.log = originalLog;
  }
});

test("kill mid-turn clears state without leak", async () => {
  const provider = makeProvider({
    env: { REMODEX_ENABLE_OPENCODE: "1", REMODEX_TEST: "1" },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: () => () => {},
      prompt: async () => {},
      abort: async () => {},
      getMessages: async () => [],
    }),
  });
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({ id: 2, method: "turn/start", params: { threadId: start.thread.id, input: "running" } });
  const intr = await provider.handleRequest({ id: 3, method: "turn/interrupt", params: { threadId: start.thread.id } });
  assert.equal(intr.interrupted, true);
});

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

for (const scenario of itemCompletedIdempotencyScenarios) {
  test(`item/completed idempotency: ${scenario.name}`, async () => {
    const messages = [];
    let subscribeHandler = null;
    const provider = makeProvider({
      send: (raw) => messages.push(JSON.parse(raw)),
      env: {
        REMODEX_ENABLE_OPENCODE: "1",
        REMODEX_TEST: "1",
        REMODEX_OPENCODE_TURN_WATCHDOG_MS: "500",
      },
      clientFactory: async () => ({
        ...fakeClient(),
        subscribeToEvents: (handler) => {
          subscribeHandler = handler;
          if (scenario.fireSseItemCompleted) {
            setImmediate(() => {
              handler("item/completed", {
                itemId: scenario.foreignItemId,
                message: ASSISTANT_REPLY,
                assistantPhase: "final_answer",
                item: {
                  id: scenario.foreignItemId,
                  type: "agentMessage",
                  phase: "final",
                  text: ASSISTANT_REPLY,
                },
              });
            });
          }
          if (scenario.fireTurnCompleted) {
            setImmediate(() => {
              handler("turn/completed", { status: "completed" });
            });
          }
          return () => {};
        },
        getMessages: async () => assistantMessagesSnapshot(ASSISTANT_REPLY, scenario.foreignItemId),
        prompt: async () => {
          if (scenario.hangPrompt) {
            return new Promise(() => {});
          }
          return Promise.resolve();
        },
      }),
    });

    const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
    const turn = await provider.handleRequest({
      id: 2,
      method: "turn/start",
      params: { threadId: start.thread.id, input: "hey" },
    });

    const bridgeItemId = `opencode-agent-${turn.turnId}`;
    const completed = await waitForItemCompleted(messages, { min: 1, timeoutMs: 1500 });

    assert.equal(completed.length, 1, `expected exactly one item/completed for ${scenario.name}`);
    assert.equal(completed[0].params.itemId, bridgeItemId);
    assert.equal(completed[0].params.item.id, bridgeItemId);
    assert.equal(completed[0].params.message, ASSISTANT_REPLY);
    assert.equal(completed[0].params.item.text, ASSISTANT_REPLY);
    assert.equal(completed[0].params.threadId, start.thread.id);
    assert.equal(completed[0].params.turnId, turn.turnId);
    assert.notEqual(completed[0].params.itemId, scenario.foreignItemId);

    if (scenario.fireSseItemCompleted && subscribeHandler) {
      subscribeHandler("item/completed", {
        itemId: scenario.foreignItemId,
        message: ASSISTANT_REPLY,
      });
      await new Promise((resolve) => setTimeout(resolve, 20));
      assert.equal(
        collectItemCompleted(messages).length,
        1,
        "duplicate SSE item/completed must not emit again",
      );
    }
  });
}

test("duplicate SSE item/completed logs opencode_item_completed_skipped telemetry", async () => {
  const messages = [];
  let subscribeHandler = null;
  const skippedTelemetry = captureTelemetryLogs("opencode_item_completed_skipped");
  try {
    const provider = makeProvider({
      send: (raw) => messages.push(JSON.parse(raw)),
      env: {
        REMODEX_ENABLE_OPENCODE: "1",
        REMODEX_TEST: "1",
        REMODEX_OPENCODE_TURN_WATCHDOG_MS: "300000",
      },
      clientFactory: async () => ({
        ...fakeClient(),
        subscribeToEvents: (handler) => {
          subscribeHandler = handler;
          setImmediate(() => {
            handler("item/completed", {
              itemId: "opencode-part-foreign-dup",
              message: ASSISTANT_REPLY,
              assistantPhase: "final_answer",
              item: {
                id: "opencode-part-foreign-dup",
                type: "agentMessage",
                phase: "final",
                text: ASSISTANT_REPLY,
              },
            });
          });
          return () => {};
        },
        getMessages: async () => [],
        prompt: async () => new Promise(() => {}),
      }),
    });

    const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
    const turn = await provider.handleRequest({
      id: 2,
      method: "turn/start",
      params: { threadId: start.thread.id, input: "hey" },
    });

    const subscribeDeadline = Date.now() + 500;
    while (!subscribeHandler && Date.now() < subscribeDeadline) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.ok(subscribeHandler, "subscribeToEvents should register before SSE replay");

    const completed = await waitForItemCompleted(messages, { min: 1, timeoutMs: 1500 });
    assert.equal(completed.length, 1);
    assert.equal(completed[0].params.itemId, `opencode-agent-${turn.turnId}`);

    subscribeHandler("item/completed", {
      itemId: "opencode-part-foreign-dup",
      message: ASSISTANT_REPLY,
    });
    await new Promise((resolve) => setTimeout(resolve, 20));

    assert.equal(collectItemCompleted(messages).length, 1);
    assert.equal(
      messages.filter((entry) => entry.method === "turn/completed").length,
      1,
      "duplicate SSE item/completed must not emit a second turn/completed",
    );
    assert.ok(
      skippedTelemetry.events.length <= 1,
      "duplicate SSE after completion should not spam item/completed telemetry",
    );
    if (skippedTelemetry.events.length === 1) {
      assert.equal(skippedTelemetry.events[0].source, "sse");
      assert.equal(skippedTelemetry.events[0].reason, "already_finalized");
      assert.equal(skippedTelemetry.events[0].threadId, start.thread.id);
      assert.equal(skippedTelemetry.events[0].turnId, turn.turnId);
    }
  } finally {
    skippedTelemetry.restore();
  }
});

test("sse foreign itemId is normalized before hydrate and completeTurn paths run", async () => {
  const messages = [];
  const provider = makeProvider({
    send: (raw) => messages.push(JSON.parse(raw)),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_TURN_WATCHDOG_MS: "500",
    },
    clientFactory: async () => ({
      ...fakeClient(),
      subscribeToEvents: (handler) => {
        setImmediate(() => {
          handler("item/agentMessage/delta", { delta: "partial " });
          handler("item/completed", {
            itemId: "foreign-sse-part-id",
            message: ASSISTANT_REPLY,
            assistantPhase: "final_answer",
          });
          handler("turn/completed", { status: "completed" });
        });
        return () => {};
      },
      getMessages: async () => assistantMessagesSnapshot(ASSISTANT_REPLY, "foreign-sse-part-id"),
      prompt: async () => {},
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turn = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hey" },
  });

  const completed = await waitForItemCompleted(messages);
  assert.equal(completed.length, 1);
  assert.equal(completed[0].params.itemId, `opencode-agent-${turn.turnId}`);
  assert.equal(completed[0].params.item.id, `opencode-agent-${turn.turnId}`);
  assert.equal(messages.filter((entry) => entry.method === "turn/completed").length, 1);
});

test("sseReconnectCount increments on SSE resubscribe", async () => {
  let onResubscribe;
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => ({
      ...fakeClient(),
      subscribeToEvents: (handler, options = {}) => {
        onResubscribe = options.onResubscribe;
        return () => {};
      },
      prompt: async () => {},
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hello" },
  });

  const subscribeDeadline = Date.now() + 500;
  while (!onResubscribe && Date.now() < subscribeDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }

  assert.equal(provider.getObservabilityMetrics().sseReconnectCount, 0);
  onResubscribe({ attempt: 1, reason: "error" });
  assert.equal(provider.getObservabilityMetrics().sseReconnectCount, 1);
});

test("REMODEX_OPENCODE_SSE_RECONNECT=0 disables SSE reconnect", async () => {
  let reconnectEnabled;
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
      REMODEX_OPENCODE_SSE_RECONNECT: "0",
    },
    clientFactory: () => ({
      ...fakeClient(),
      subscribeToEvents: (handler, options = {}) => {
        reconnectEnabled = options.reconnectEnabled;
        return () => {};
      },
      prompt: async () => {},
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hello" },
  });

  const subscribeDeadline = Date.now() + 500;
  while (reconnectEnabled === undefined && Date.now() < subscribeDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }

  assert.equal(reconnectEnabled, false);
});

test("getHandoffContext ignores untrusted client sessionId and directory", async () => {
  const provider = makeProvider();
  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: {
      title: "Handoff test",
      cwd: testProjectPath("owned-project"),
      sessionId: "ses_owned",
    },
  });

  const context = await provider.getHandoffContext(start.thread.id, {
    sessionId: "ses_untrusted",
    directory: "/etc/evil-path",
  });

  assert.equal(context.threadId, start.thread.id);
  assert.equal(context.sessionId, "ses_owned");
  assert.equal(context.cwd, testProjectPath("owned-project"));
});

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

test("listThreads includes external sessions when Remodex app discover param is on", async () => {
  const provider = makeProvider({
    env: { REMODEX_ENABLE_OPENCODE: "1" },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  const list = await provider.listThreads({ discoverOpenCodeSessions: true });
  const row = list.data.find((thread) => thread.id === "opencode-session-ses_external_mac");
  assert.ok(row, "external session should appear when app sends discoverOpenCodeSessions");
});

test("listThreads includes external sessions when discover flag is on", async () => {
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
    },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  const list = await provider.listThreads();
  const row = list.data.find((thread) => thread.id === "opencode-session-ses_external_mac");
  assert.ok(row, "external session should appear in listThreads");
  assert.equal(row.cwd, path.join(os.homedir(), "work", "mac-opencode"));
  assert.equal(row.modelProvider, "opencode");
  assert.equal(row.metadata.discoveredExternally, true);
  assert.equal(row.metadata.sessionId, "ses_external_mac");
});

test("listThreads discover merge does not fetch session messages", async () => {
  let getMessagesCalls = 0;
  let getSessionCalls = 0;
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
    },
    clientFactory: async () => ({
      ...discoveredListClient([externalDiscoveredRow()]),
      getMessages: async () => {
        getMessagesCalls += 1;
        return [];
      },
      getSession: async () => {
        getSessionCalls += 1;
        return {};
      },
    }),
  });

  await provider.listThreads();
  assert.equal(getMessagesCalls, 0);
  assert.equal(getSessionCalls, 0);
});

test("listThreads omits external sessions when discover flag is off", async () => {
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "0",
    },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  const list = await provider.listThreads();
  assert.equal(
    list.data.find((thread) => thread.id === "opencode-session-ses_external_mac"),
    undefined,
  );
});

test("adopt rejects discovered session cwd outside home allowlist", async () => {
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
    },
    clientFactory: async () =>
      discoveredListClient([
        externalDiscoveredRow({ cwd: "/etc/passwd", sessionId: "ses_blocked_cwd" }),
      ]),
  });

  await provider.listThreads();
  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 1,
        method: "thread/read",
        params: { threadId: "opencode-session-ses_blocked_cwd" },
      }),
    (error) => error.errorCode === "path_not_allowed",
  );
});

test("thread/start rejects cwd traversal outside home allowlist", async () => {
  const provider = makeProvider();
  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 1,
        method: "thread/start",
        params: { cwd: "/etc" },
      }),
    (error) => error.errorCode === "path_not_allowed",
  );
});

test("thread/start rejects cwd symlink that resolves outside home", async () => {
  const homeScratch = fs.mkdtempSync(path.join(os.homedir(), "remodex-thread-start-"));
  const outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-thread-outside-"));
  const linkPath = path.join(homeScratch, "escape-link");
  fs.symlinkSync(outsideDir, linkPath, "dir");

  try {
    const provider = makeProvider();
    await assert.rejects(
      () =>
        provider.handleRequest({
          id: 1,
          method: "thread/start",
          params: { cwd: linkPath },
        }),
      (error) => error.errorCode === "path_not_allowed",
    );
  } finally {
    fs.rmSync(homeScratch, { recursive: true, force: true });
    fs.rmSync(outsideDir, { recursive: true, force: true });
  }
});

test("command/execute rejects directory traversal outside home allowlist", async () => {
  const provider = makeProvider({
    clientFactory: ({ baseUrl, logPrefix }) =>
      createOpenCodeClient({
        baseUrl,
        logPrefix,
        createOpencodeClientImpl: () => ({
          session: {
            create: async () => ({ sessionID: "ses_path_guard" }),
            command: async () => ({ info: {}, parts: [] }),
          },
          command: {
            list: async () => [],
          },
        }),
      }),
  });

  const start = await provider.handleRequest({
    id: 1,
    method: "thread/start",
    params: { cwd: path.join(os.homedir(), "remodex-cmd-guard-project") },
  });

  await assert.rejects(
    () =>
      provider.commandExecute({
        id: 2,
        method: "command/execute",
        params: {
          threadId: start.thread.id,
          command: "/skills",
          directory: "/etc",
        },
      }),
    (error) => error.errorCode === "path_not_allowed",
  );
});

test("command/execute rejects rehydrated sdk directory when store cwd is empty", async () => {
  const sessionStore = fakeSessionStore();
  const ownershipStore = fakeOwnershipStore();
  sessionStore.set("opencode-thread-rehydrate-bad-cwd", "ses_rehydrate_bad", {
    cwd: "",
    model: "openai/gpt-5.5",
    agent: "build",
  });
  ownershipStore.setOwnership("opencode-thread-rehydrate-bad-cwd", "opencode");

  const provider = makeProvider({
    sessionStore,
    ownershipStore,
    clientFactory: ({ baseUrl, logPrefix }) =>
      createOpenCodeClient({
        baseUrl,
        logPrefix,
        createOpencodeClientImpl: () => ({
          session: {
            get: async () => ({
              sessionID: "ses_rehydrate_bad",
              directory: "/etc",
            }),
          },
          command: {
            list: async () => [],
          },
        }),
      }),
  });

  await assert.rejects(
    () =>
      provider.commandExecute({
        id: 1,
        method: "command/execute",
        params: {
          threadId: "opencode-thread-rehydrate-bad-cwd",
          command: "/skills",
        },
      }),
    (error) => error.errorCode === "path_not_allowed",
  );
});

test("command/execute rejects directory symlink that resolves outside home", async () => {
  const homeScratch = fs.mkdtempSync(path.join(os.homedir(), "remodex-cmd-exec-"));
  const outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-cmd-outside-"));
  const linkPath = path.join(homeScratch, "escape-link");
  fs.symlinkSync(outsideDir, linkPath, "dir");

  const provider = makeProvider({
    clientFactory: ({ baseUrl, logPrefix }) =>
      createOpenCodeClient({
        baseUrl,
        logPrefix,
        createOpencodeClientImpl: () => ({
          session: {
            create: async () => ({ sessionID: "ses_symlink_guard" }),
            command: async () => ({ info: {}, parts: [] }),
          },
          command: {
            list: async () => [],
          },
        }),
      }),
  });

  try {
    const start = await provider.handleRequest({
      id: 1,
      method: "thread/start",
      params: { cwd: path.join(homeScratch, "owned-project") },
    });

    await assert.rejects(
      () =>
        provider.commandExecute({
          id: 2,
          method: "command/execute",
          params: {
            threadId: start.thread.id,
            command: "/skills",
            directory: linkPath,
          },
        }),
      (error) => error.errorCode === "path_not_allowed",
    );
  } finally {
    fs.rmSync(homeScratch, { recursive: true, force: true });
    fs.rmSync(outsideDir, { recursive: true, force: true });
  }
});

test("thread/read adopts discovered session", async () => {
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
    },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  await provider.listThreads();
  const read = await provider.handleRequest({
    id: 1,
    method: "thread/read",
    params: { threadId: "opencode-session-ses_external_mac", includeTurns: true },
  });

  assert.equal(read.thread.id, "opencode-session-ses_external_mac");
  assert.equal(ownershipStore.ownsThread("opencode-session-ses_external_mac", "opencode"), true);
  assert.equal(sessionStore.get("opencode-session-ses_external_mac"), "ses_external_mac");
});

test("thread/resume adopts discovered session and thread/read succeeds", async () => {
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
    },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  await provider.listThreads();
  const read = await provider.handleRequest({
    id: 1,
    method: "thread/resume",
    params: { threadId: "opencode-session-ses_external_mac", includeTurns: true },
  });

  assert.equal(read.thread.id, "opencode-session-ses_external_mac");
  assert.equal(ownershipStore.ownsThread("opencode-session-ses_external_mac", "opencode"), true);
  assert.equal(sessionStore.get("opencode-session-ses_external_mac"), "ses_external_mac");
  assert.ok(Array.isArray(read.thread.turns));
  assert.equal(read.thread.turns.length, 1);
});

test("turn/start before adopt fails with thread_not_found", async () => {
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
    },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  await provider.listThreads();
  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 1,
        method: "turn/start",
        params: {
          threadId: "opencode-session-ses_external_mac",
          input: "hello",
        },
      }),
    (error) => error.errorCode === "thread_not_found",
  );
});

test("turn/start after adopt succeeds", async () => {
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  await provider.listThreads();
  await provider.handleRequest({
    id: 1,
    method: "thread/resume",
    params: { threadId: "opencode-session-ses_external_mac" },
  });

  const turn = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: {
      threadId: "opencode-session-ses_external_mac",
      input: "hello after adopt",
    },
  });
  assert.ok(turn.turnId);
});

test("second thread/resume on discovered id is idempotent", async () => {
  const ownershipStore = fakeOwnershipStore();
  const provider = makeProvider({
    ownershipStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
    },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  await provider.listThreads();
  await provider.handleRequest({
    id: 1,
    method: "thread/resume",
    params: { threadId: "opencode-session-ses_external_mac" },
  });
  const second = await provider.handleRequest({
    id: 2,
    method: "thread/resume",
    params: { threadId: "opencode-session-ses_external_mac" },
  });

  assert.equal(second.thread.id, "opencode-session-ses_external_mac");
  assert.equal(ownershipStore.ownsThread("opencode-session-ses_external_mac", "opencode"), true);
});

test("adopt failure leaves no ownership row", async () => {
  const ownershipStore = {
    setOwnership() {
      return false;
    },
    ownsThread() {
      return false;
    },
    removeOwnership() {
      return false;
    },
    getAllOwnedBy() {
      return [];
    },
  };
  const sessionStore = fakeSessionStore();
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
    },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  await provider.listThreads();
  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 1,
        method: "thread/read",
        params: { threadId: "opencode-session-ses_external_mac" },
      }),
    (error) => error.errorCode === "opencode_adopt_failed",
  );
  assert.equal(ownershipStore.ownsThread("opencode-session-ses_external_mac", "opencode"), false);
  assert.equal(sessionStore.get("opencode-session-ses_external_mac"), null);
});

test("owned sessionId omits discovered stub and adopt returns owned thread", async () => {
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  ownershipStore.setOwnership("opencode-thread-owned", "opencode");
  sessionStore.set("opencode-thread-owned", "ses_external_mac", {
    cwd: "/Users/me/work/phone-started",
    title: "Phone thread",
  });

  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
    },
    clientFactory: async () =>
      discoveredListClient([externalDiscoveredRow()]),
  });

  const list = await provider.listThreads();
  assert.equal(
    list.data.find((thread) => thread.id === "opencode-session-ses_external_mac"),
    undefined,
  );
  assert.ok(list.data.find((thread) => thread.id === "opencode-thread-owned"));

  const adopted = await provider.handleRequest({
    id: 1,
    method: "thread/resume",
    params: { threadId: "opencode-session-ses_external_mac" },
  });
  assert.equal(adopted.thread.id, "opencode-thread-owned");
});

test("owned sessionId omits discovered stub on discover cache hit", async () => {
  let listCalls = 0;
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
      REMODEX_OPENCODE_DISCOVER_TTL_MS: "60000",
    },
    clientFactory: async () => ({
      ...discoveredListClient([externalDiscoveredRow()]),
      listSessions: async () => {
        listCalls += 1;
        return { data: [externalDiscoveredRow()] };
      },
    }),
  });

  const first = await provider.listThreads();
  assert.ok(
    first.data.find((thread) => thread.id === "opencode-session-ses_external_mac"),
    "discovered stub should appear before ownership mapping",
  );
  assert.equal(listCalls, 1);

  ownershipStore.setOwnership("opencode-thread-owned", "opencode");
  sessionStore.set("opencode-thread-owned", "ses_external_mac", {
    cwd: "/Users/me/work/phone-started",
    title: "Phone thread",
  });

  const second = await provider.listThreads();
  assert.equal(
    second.data.find((thread) => thread.id === "opencode-session-ses_external_mac"),
    undefined,
    "discovered stub should be filtered on cache hit after ownership mapping",
  );
  assert.ok(second.data.find((thread) => thread.id === "opencode-thread-owned"));
  assert.equal(listCalls, 1, "cache hit should not call listSessions again");
});

test("discover uses stale cache when ensureStarted exceeds cap", async (t) => {
  let listCalls = 0;
  let blockStart = false;
  let running = false;
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
      REMODEX_OPENCODE_ENSURE_STARTED_MS: "25",
      REMODEX_OPENCODE_DISCOVER_TTL_MS: "1",
      REMODEX_TEST: "1",
    },
    serverFactory: () => ({
      get baseUrl() {
        return running ? "http://127.0.0.1:4291" : "";
      },
      get isRunning() {
        return running;
      },
      start: async () => {
        if (blockStart) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          throw new Error("blocked start for stale-cache test");
        }
        running = true;
      },
      stop: async () => {
        running = false;
      },
    }),
    clientFactory: async () => ({
      ...discoveredListClient([externalDiscoveredRow()]),
      listSessions: async () => {
        listCalls += 1;
        return { data: [externalDiscoveredRow()] };
      },
    }),
  });
  t.after(async () => {
    await new Promise((resolve) => setTimeout(resolve, 100));
    await provider.shutdown();
  });

  const first = await provider.listThreads();
  assert.equal(first.data.length, 1);
  assert.equal(listCalls, 1);

  blockStart = true;
  running = false;
  provider.__test.setHealthy(false);
  provider.__test.setClient(null);
  await new Promise((resolve) => setTimeout(resolve, 5));

  const second = await provider.listThreads();
  assert.equal(second.data.length, 1);
  assert.equal(listCalls, 1, "stale cache should avoid blocking refresh on ensureStarted timeout");
});

test("listThreads returns degraded ownership stubs when owned wake exceeds cap", async (t) => {
  let blockStart = false;
  let running = false;
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  ownershipStore.setOwnership("opencode-thread-degraded", "opencode");
  sessionStore.set("opencode-thread-degraded", "ses_degraded", {
    cwd: "/Users/me/work/degraded",
    title: "Degraded owned chat",
  });

  const logs = [];
  const originalLog = console.log;
  console.log = (...args) => {
    logs.push(args.map((entry) => String(entry)).join(" "));
  };

  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_ENSURE_STARTED_MS: "25",
      REMODEX_TEST: "1",
    },
    serverFactory: () => ({
      get baseUrl() {
        return running ? "http://127.0.0.1:4291" : "";
      },
      get isRunning() {
        return running;
      },
      start: async () => {
        if (blockStart) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          throw new Error("blocked start for degraded-owned test");
        }
        running = true;
      },
      stop: async () => {
        running = false;
      },
    }),
    clientFactory: async () => fakeClient(),
  });
  t.after(async () => {
    console.log = originalLog;
    await new Promise((resolve) => setTimeout(resolve, 100));
    await provider.shutdown();
  });

  await provider.listModels();
  blockStart = true;
  running = false;
  provider.__test.setHealthy(false);
  provider.__test.setClient(null);

  const list = await provider.listThreads();
  const row = list.data.find((thread) => thread.id === "opencode-thread-degraded");
  assert.ok(row, "owned stub should appear in degraded wake mode");
  assert.equal(row.metadata?.degradedWake, true);

  const parsedLogs = logs
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
  assert.ok(
    parsedLogs.some((entry) => entry.event === "opencode_list_threads_wake_timeout"),
    "wake timeout event expected",
  );
  assert.ok(
    parsedLogs.some((entry) => entry.event === "opencode_list_threads_degraded_stubs"),
    "degraded stub event expected",
  );
});

test("adopt degrades with empty turns when ensureStarted exceeds cap", async (t) => {
  let blockStart = false;
  let running = false;
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
      REMODEX_OPENCODE_SERVE_WAKE_MS: "25",
      REMODEX_OPENCODE_DISCOVER_TTL_MS: "60000",
      REMODEX_TEST: "1",
    },
    serverFactory: () => ({
      get baseUrl() {
        return running ? "http://127.0.0.1:4291" : "";
      },
      get isRunning() {
        return running;
      },
      start: async () => {
        if (blockStart) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          throw new Error("blocked start for adopt-timeout test");
        }
        running = true;
      },
      stop: async () => {
        running = false;
      },
    }),
    clientFactory: async () => discoveredListClient([externalDiscoveredRow()]),
  });
  t.after(async () => {
    await new Promise((resolve) => setTimeout(resolve, 100));
    await provider.shutdown();
  });

  await provider.listThreads();
  blockStart = true;
  running = false;
  provider.__test.setHealthy(false);
  provider.__test.setClient(null);

  const read = await provider.handleRequest({
    id: 1,
    method: "thread/resume",
    params: { threadId: "opencode-session-ses_external_mac", includeTurns: true },
  });

  assert.equal(read.thread.id, "opencode-session-ses_external_mac");
  assert.equal(ownershipStore.ownsThread("opencode-session-ses_external_mac", "opencode"), true);
  assert.equal(sessionStore.get("opencode-session-ses_external_mac"), "ses_external_mac");
  assert.deepEqual(read.thread.turns, []);
});

test("adopt times out and cleans up partial state when client.getMessages is slow", async (t) => {
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
      REMODEX_OPENCODE_ADOPT_TIMEOUT_MS: "50",
      REMODEX_TEST: "1",
    },
    clientFactory: async () => ({
      ...discoveredListClient([externalDiscoveredRow()]),
      getMessages: async () => {
        await new Promise((resolve) => setTimeout(resolve, 200));
        return [{ role: "assistant", text: "late message" }];
      },
    }),
  });
  t.after(async () => {
    await provider.shutdown();
  });

  await provider.listThreads();

  await assert.rejects(
    () =>
      provider.handleRequest({
        id: 1,
        method: "thread/read",
        params: { threadId: "opencode-session-ses_external_mac", includeTurns: true },
      }),
    (error) => {
      assert.equal(error.errorCode, "opencode_adopt_timeout");
      return true;
    },
  );

  // Allow background adoptPromise to reach its cancellation check.
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal(ownershipStore.ownsThread("opencode-session-ses_external_mac", "opencode"), false);
  assert.equal(sessionStore.get("opencode-session-ses_external_mac"), null);
});

test("listThreads surfaces materializationBlocked in response meta", async () => {
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  for (let index = 0; index < 6; index += 1) {
    const threadId = `opencode-thread-meta-${index}`;
    sessionStore.set(threadId, `ses_meta_${index}`);
    ownershipStore.setOwnership(threadId, "opencode");
  }

  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_LIST_THREADS_VALIDATE_CAP: "2",
    },
    clientFactory: async () => ({
      ...fakeClient(),
      getSession: async () => ({}),
      getMessages: async () => [{ role: "assistant", text: "activity" }],
    }),
  });
  await provider.warmup();

  const list = await provider.listThreads();
  assert.equal(list.meta.materializationBlocked, 4);
  assert.equal(list.meta.sdkValidationsCap, 2);
  assert.equal(list.meta.sdkValidations, 2);
  assert.equal(list.data.length, 2);
});

test("listThreads validation cache avoids repeat SDK calls within TTL", async () => {
  let getSessionCalls = 0;
  let getMessagesCalls = 0;
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  sessionStore.set("opencode-thread-cache", "ses_cache", { title: "Cached stub" });
  ownershipStore.setOwnership("opencode-thread-cache", "opencode");

  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_LIST_THREADS_VALIDATE_CACHE_TTL_MS: "60000",
    },
    clientFactory: async () => ({
      ...fakeClient(),
      getSession: async () => {
        getSessionCalls += 1;
        return {};
      },
      getMessages: async () => {
        getMessagesCalls += 1;
        return [{ role: "assistant", text: "activity" }];
      },
    }),
  });
  await provider.warmup();

  await provider.listThreads();
  await provider.listThreads();

  assert.equal(getSessionCalls, 1);
  assert.equal(getMessagesCalls, 1);
});

test("discover refresh coalesces concurrent listThreads polls", async () => {
  let listCalls = 0;
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_DISCOVER_SESSIONS: "1",
      REMODEX_OPENCODE_DISCOVER_TTL_MS: "1",
    },
    clientFactory: async () => ({
      ...discoveredListClient([externalDiscoveredRow()]),
      listSessions: async () => {
        listCalls += 1;
        await new Promise((resolve) => setTimeout(resolve, 40));
        return { data: [externalDiscoveredRow()] };
      },
    }),
  });
  await provider.warmup();
  await new Promise((resolve) => setTimeout(resolve, 5));

  const [first, second] = await Promise.all([
    provider.listThreads({ discoverOpenCodeSessions: true }),
    provider.listThreads({ discoverOpenCodeSessions: true }),
  ]);

  assert.equal(first.data.length, 1);
  assert.equal(second.data.length, 1);
  assert.equal(listCalls, 1, "concurrent discover refresh should share one in-flight mutex");
});

test("ownership stub includes cwd for sidebar grouping", async () => {
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  ownershipStore.setOwnership("opencode-thread-stub-cwd", "opencode");
  sessionStore.set("opencode-thread-stub-cwd", "ses_stub", {
    cwd: "/Users/me/work/stub-project",
    title: "Stub with cwd",
  });

  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: { REMODEX_ENABLE_OPENCODE: "1" },
    clientFactory: async () => ({
      ...fakeClient(),
      getSession: async () => ({}),
      getMessages: async () => [{ type: "user", text: "activity" }],
    }),
  });

  const list = await provider.listThreads();
  const row = list.data.find((thread) => thread.id === "opencode-thread-stub-cwd");
  assert.ok(row);
  assert.equal(row.cwd, "/Users/me/work/stub-project");
});

test("serve wake cap defaults to 8s while list wake cap stays 4s", () => {
  assert.equal(resolveEnsureStartedServeWakeCapMs({}), DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS);
  assert.equal(DEFAULT_ENSURE_STARTED_SERVE_WAKE_CAP_MS, 8_000);
  assert.equal(resolveEnsureStartedListCapMs({}), DEFAULT_ENSURE_STARTED_LIST_CAP_MS);
  assert.equal(DEFAULT_ENSURE_STARTED_LIST_CAP_MS, 4_000);
  assert.equal(resolveValidationRpcLimitPerMin({}), DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN);
  assert.equal(DEFAULT_VALIDATION_RPC_LIMIT_PER_MIN, 120);
});

test("turn/started emits only after ensureStartedWithCap succeeds", async () => {
  const messages = [];
  let blockStart = false;
  let running = false;
  const provider = makeProvider({
    send: (msg) => messages.push(JSON.parse(msg)),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_SERVE_WAKE_MS: "25",
      REMODEX_TEST: "1",
    },
    serverFactory: () => ({
      get baseUrl() {
        return running ? "http://127.0.0.1:4291" : "";
      },
      get isRunning() {
        return running;
      },
      start: async () => {
        if (blockStart) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          throw new Error("blocked start for turn-started ordering test");
        }
        running = true;
      },
      stop: async () => {
        running = false;
      },
    }),
    clientFactory: async () => ({
      ...fakeClient(),
      prompt: async () => {},
      subscribeToEvents: () => () => {},
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  blockStart = true;
  running = false;
  provider.__test.setHealthy(false);
  provider.__test.setClient(null);

  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hello after wake" },
  });

  await new Promise((resolve) => setTimeout(resolve, 120));
  assert.equal(messages.some((entry) => entry.method === "turn/started"), false);
  assert.ok(messages.some((entry) => entry.method === "turn/completed"));
});

test("validation RPC token bucket limits SDK validation calls", async () => {
  let getSessionCalls = 0;
  const ownershipStore = fakeOwnershipStore();
  const sessionStore = fakeSessionStore();
  for (let index = 0; index < 3; index += 1) {
    const threadId = `opencode-thread-rate-${index}`;
    sessionStore.set(threadId, `ses_rate_${index}`);
    ownershipStore.setOwnership(threadId, "opencode");
  }

  const provider = makeProvider({
    ownershipStore,
    sessionStore,
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_VALIDATION_RPC_LIMIT_PER_MIN: "2",
      REMODEX_LIST_THREADS_VALIDATE_CAP: "10",
    },
    clientFactory: async () => ({
      ...fakeClient(),
      getSession: async () => {
        getSessionCalls += 1;
        return {};
      },
      getMessages: async () => [{ role: "assistant", text: "activity" }],
    }),
  });
  await provider.warmup();
  provider.__test.resetValidationRpcTokenBucket();

  const list = await provider.listThreads();
  assert.equal(getSessionCalls, 1, "token bucket should allow one getSession before refill");
  assert.equal(list.meta.materializationBlocked, 2);
  assert.equal(list.data.length, 1);
});

test("SSE resubscribe hydrates active turn from session messages", async () => {
  const ASSISTANT_REPLY = "Recovered after SSE resubscribe.";
  let onResubscribe;
  const messages = [];
  const provider = makeProvider({
    send: (msg) => messages.push(JSON.parse(msg)),
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => ({
      ...fakeClient(),
      subscribeToEvents: (handler, options = {}) => {
        onResubscribe = options.onResubscribe;
        return () => {};
      },
      getMessages: async () => [
        { role: "user", text: "hello" },
        { role: "assistant", text: ASSISTANT_REPLY },
      ],
      prompt: async () => {},
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "hello" },
  });

  const subscribeDeadline = Date.now() + 500;
  while (!onResubscribe && Date.now() < subscribeDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.ok(onResubscribe);

  await onResubscribe({ attempt: 1, reason: "error" });
  const hydrateDeadline = Date.now() + 500;
  while (
    !messages.some((entry) => entry.method === "item/completed")
    && Date.now() < hydrateDeadline
  ) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }

  const completed = messages.filter((entry) => entry.method === "item/completed");
  assert.equal(completed.length, 1);
  assert.match(completed[0].params.message, /Recovered after SSE resubscribe/);
});

test("completedTurnIds Map prunes entries older than TTL", async () => {
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });

  // Access internal state for testing
  const internalState = provider.__test.getInternalState();
  const { completedTurnIds } = internalState;

  // Add some turn IDs with timestamps
  const now = Date.now();
  completedTurnIds.set("turn-1", now - 400_000); // 400 seconds ago (older than 300s TTL)
  completedTurnIds.set("turn-2", now - 200_000); // 200 seconds ago (within TTL)
  completedTurnIds.set("turn-3", now); // Just now

  assert.equal(completedTurnIds.size, 3, "should have 3 entries before pruning");

  // Trigger pruning by calling the internal prune function
  provider.__test.pruneCompletedTurnIds(now);

  assert.equal(completedTurnIds.size, 2, "should have 2 entries after pruning");
  assert.ok(!completedTurnIds.has("turn-1"), "old turn-1 should be pruned");
  assert.ok(completedTurnIds.has("turn-2"), "recent turn-2 should remain");
  assert.ok(completedTurnIds.has("turn-3"), "current turn-3 should remain");
});

test("internalCompleteTurn properly marks turn as completed", async () => {
  // This test verifies that the internalCompleteTurn function
  // correctly marks turns as completed (race condition fix)
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });

  // Start a thread
  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  assert.ok(start.thread.id);

  // Start a turn
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });
  assert.ok(turnStart.turn.id);
  assert.strictEqual(turnStart.turn.status, "running");

  // Get the active turn from internal state
  const internalState = provider.__test.getInternalState();
  const { activeTurns } = internalState;
  const activeTurn = activeTurns.get(turnStart.turn.id);
  assert.ok(activeTurn, "turn should be in activeTurns");
  assert.strictEqual(activeTurn.completed, false, "turn should not be completed yet");

  // Use the exposed completeTurn hook to mark it as failed
  provider.__test.completeTurn({
    status: "failed",
    errorMessage: "Test error",
    errorCode: "test_error",
    action: "retry",
    active: activeTurn,
    source: "test",
  });

  // Verify the turn is now marked as completed
  assert.strictEqual(activeTurn.completed, true, "turn should be marked as completed");

  // Verify it's in completedTurnIds
  const updatedState = provider.__test.getInternalState();
  const { completedTurnIds } = updatedState;
  assert.ok(completedTurnIds.has(turnStart.turn.id), "turn should be in completedTurnIds");
});

test("internalCompleteTurn is idempotent", async () => {
  // Test that calling internalCompleteTurn multiple times doesn't cause issues
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });

  const internalState = provider.__test.getInternalState();
  const { activeTurns } = internalState;
  const activeTurn = activeTurns.get(turnStart.turn.id);

  // Call completeTurn multiple times
  const result1 = provider.__test.completeTurn({
    status: "completed",
    active: activeTurn,
    source: "test",
  });
  const result2 = provider.__test.completeTurn({
    status: "completed",
    active: activeTurn,
    source: "test",
  });
  const result3 = provider.__test.completeTurn({
    status: "failed",
    active: activeTurn,
    source: "test",
  });

  // First call should succeed, subsequent calls should return false
  assert.strictEqual(result1, true, "first completeTurn should succeed");
  assert.strictEqual(result2, false, "second completeTurn should return false (already completed)");
  assert.strictEqual(result3, false, "third completeTurn should return false (already completed)");

  // Turn should still be marked as completed from first call
  assert.strictEqual(activeTurn.completed, true, "turn should be completed");
});

test("internalCompleteTurn clears watchdog timer", async () => {
  // Test that internalCompleteTurn clears the watchdog timer
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });

  const internalState = provider.__test.getInternalState();
  const { activeTurns } = internalState;
  const activeTurn = activeTurns.get(turnStart.turn.id);

  // Manually set a watchdog timer (simulating it was set)
  activeTurn.watchdogTimer = setTimeout(() => {}, 10000);
  assert.ok(activeTurn.watchdogTimer, "watchdog timer should be set");

  // Complete the turn
  provider.__test.completeTurn({
    status: "completed",
    active: activeTurn,
    source: "test",
  });

  // Watchdog timer should be cleared
  assert.strictEqual(activeTurn.watchdogTimer, null, "watchdog timer should be null after completion");
});

test("internalCompleteTurn with different status values", async () => {
  // Test that internalCompleteTurn handles different status values correctly
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });

  const statuses = ["completed", "failed", "stopped"];
  const results = [];

  for (const status of statuses) {
    const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
    const turnStart = await provider.handleRequest({
      id: 2,
      method: "turn/start",
      params: { threadId: start.thread.id, input: "test" },
    });

    const internalState = provider.__test.getInternalState();
    const { activeTurns } = internalState;
    const activeTurn = activeTurns.get(turnStart.turn.id);

    const result = provider.__test.completeTurn({
      status,
      active: activeTurn,
      source: "test",
    });

    results.push({ status, result, completed: activeTurn.completed });
  }

  // All statuses should complete successfully
  for (const { status, result, completed } of results) {
    assert.strictEqual(result, true, `completeTurn with status '${status}' should succeed`);
    assert.strictEqual(completed, true, `turn should be completed with status '${status}'`);
  }
});

test("internalCompleteTurn removes from activeTurns after completion", async () => {
  // Test that completed turns are marked completed in activeTurns
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });

  const internalState = provider.__test.getInternalState();
  const { activeTurns } = internalState;
  const activeTurn = activeTurns.get(turnStart.turn.id);

  assert.ok(activeTurn, "turn should be in activeTurns before completion");

  // Complete the turn
  provider.__test.completeTurn({
    status: "completed",
    active: activeTurn,
    source: "test",
  });

  // Turn should be marked as completed (not removed from activeTurns - that happens in internalCompleteTurn)
  assert.strictEqual(activeTurn.completed, true, "turn should be marked completed");
});

test("internalCompleteTurn with error details", async () => {
  // Test that internalCompleteTurn properly stores error details
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });

  const internalState = provider.__test.getInternalState();
  const { activeTurns } = internalState;
  const activeTurn = activeTurns.get(turnStart.turn.id);

  const errorMessage = "Test error message";
  const errorCode = "test_error_code";
  const action = "retry_action";

  provider.__test.completeTurn({
    status: "failed",
    errorMessage,
    errorCode,
    action,
    active: activeTurn,
    source: "test",
  });

  // Verify error details are stored in turn.error
  assert.strictEqual(activeTurn.completed, true);
  assert.ok(activeTurn.turn.error, "turn.error should be set");
  assert.strictEqual(activeTurn.turn.error.message, errorMessage, "error message should match");
  assert.strictEqual(activeTurn.turn.error.errorCode, errorCode, "error code should match");
  assert.strictEqual(activeTurn.turn.error.action, action, "action should match");
});

test("internalCompleteTurn handles already-completed turn gracefully", async () => {
  // Test that internalCompleteTurn handles the case where turn is already completed
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });

  const internalState = provider.__test.getInternalState();
  const { activeTurns } = internalState;
  const activeTurn = activeTurns.get(turnStart.turn.id);

  // Manually mark as completed
  activeTurn.completed = true;

  // Try to complete again
  const result = provider.__test.completeTurn({
    status: "completed",
    active: activeTurn,
    source: "test",
  });

  // Should return false (already completed)
  assert.strictEqual(result, false, "should return false for already-completed turn");
});

test("internalCompleteTurn prunes completedTurnIds before adding", async () => {
  // Test that internalCompleteTurn prunes old entries before adding new ones
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });

  const internalState = provider.__test.getInternalState();
  const { completedTurnIds } = internalState;

  // Add an old entry
  const now = Date.now();
  completedTurnIds.set("old-turn", now - 400_000); // 400 seconds ago

  assert.equal(completedTurnIds.size, 1, "should have 1 entry before completion");

  // Complete the turn (should trigger pruning)
  const { activeTurns } = internalState;
  const activeTurn = activeTurns.get(turnStart.turn.id);
  provider.__test.completeTurn({
    status: "completed",
    active: activeTurn,
    source: "test",
  });

  // Old entry should be pruned, new entry added
  assert.equal(completedTurnIds.size, 1, "should have 1 entry after pruning");
  assert.ok(!completedTurnIds.has("old-turn"), "old entry should be pruned");
  assert.ok(completedTurnIds.has(turnStart.turn.id), "new turn should be in completedTurnIds");
});

test("turn/start handles executeTurn errors gracefully", async () => {
  // Test that errors in executeTurn are caught and turn is marked as failed
  let executeTurnCalled = false;
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => ({
      ...fakeClient(),
      prompt: async () => {
        executeTurnCalled = true;
        throw new Error("executeTurn failed");
      },
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });

  // Turn should start as running
  assert.strictEqual(turnStart.turn.status, "running");

  // Wait for executeTurn to run and fail (using setImmediate to ensure the promise chain runs)
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));

  assert.ok(executeTurnCalled, "executeTurn should have been called");

  // Turn should be marked as failed and removed from activeTurns
  const internalState = provider.__test.getInternalState();
  const { activeTurns, completedTurnIds } = internalState;

  // Turn should be removed from activeTurns after completion
  assert.ok(!activeTurns.has(turnStart.turn.id), "turn should be removed from activeTurns after error");
  // But should be in completedTurnIds
  assert.ok(completedTurnIds.has(turnStart.turn.id), "turn should be in completedTurnIds");
});

test("turn/start with custom error code and action", async () => {
  // Test that custom error codes and actions are preserved
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => ({
      ...fakeClient(),
      prompt: async () => {
        const error = new Error("custom error");
        error.errorCode = "custom_error_code";
        error.action = "custom_action";
        throw error;
      },
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });

  // Wait for executeTurn to run and fail (using setImmediate to ensure the promise chain runs)
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));

  const internalState = provider.__test.getInternalState();
  const { completedTurnIds } = internalState;

  // Turn should be in completedTurnIds
  assert.ok(completedTurnIds.has(turnStart.turn.id), "turn should be in completedTurnIds");

  // Read the thread to check the turn status
  const threadRead = await provider.handleRequest({
    id: 3,
    method: "thread/read",
    params: { threadId: start.thread.id, includeTurns: true },
  });

  assert.ok(threadRead.thread.turns);
  const failedTurn = threadRead.thread.turns.find((t) => t.id === turnStart.turn.id);
  assert.ok(failedTurn, "turn should be in thread turns");
  assert.strictEqual(failedTurn.status, "failed", "turn should be marked as failed");
  assert.ok(failedTurn.error, "turn should have error details");
  assert.strictEqual(failedTurn.error.errorCode, "custom_error_code", "error code should be preserved");
  assert.strictEqual(failedTurn.error.action, "custom_action", "action should be preserved");
});

test("turn/start with synchronous executeTurn error", async () => {
  // Test that synchronous errors in executeTurn are caught
  const provider = makeProvider({
    send: () => {},
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_TEST: "1",
    },
    clientFactory: () => ({
      ...fakeClient(),
      prompt: async () => {
        throw new Error("synchronous error");
      },
    }),
  });

  const start = await provider.handleRequest({ id: 1, method: "thread/start", params: {} });
  const turnStart = await provider.handleRequest({
    id: 2,
    method: "turn/start",
    params: { threadId: start.thread.id, input: "test" },
  });

  // Wait for executeTurn to run and fail (using setImmediate to ensure the promise chain runs)
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));

  const internalState = provider.__test.getInternalState();
  const { completedTurnIds } = internalState;

  // Turn should be in completedTurnIds
  assert.ok(completedTurnIds.has(turnStart.turn.id), "turn should be in completedTurnIds");
});


