// FILE: opencode-runtime-adapter.test.js
// Purpose: Verifies OpenCode runtime request mapping to server calls and canonical bridge events.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-runtime-adapter, ../src/thread-agent-state

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  createOpenCodeRuntimeAdapter,
  hasOpenCodeAuthConfigured,
  mapOpenCodeRuntimeStatus,
  mapServerStatus,
} = require("../src/opencode-runtime-adapter");
const { createThreadAgentStateStore } = require("../src/thread-agent-state");

test("OpenCode runtime maps missing auth.json to needs_auth", () => {
  const fsImpl = {
    existsSync: () => false,
    readFileSync: () => "",
  };
  assert.equal(hasOpenCodeAuthConfigured(fsImpl), false);
  assert.equal(mapOpenCodeRuntimeStatus("ready", fsImpl).status, "needs_auth");
});

test("OpenCode runtime adapter maps server status into runtime status", async () => {
  const adapter = createAdapter({
    serverStatus: { state: "ready", baseUrl: "http://127.0.0.1:1" },
    modelCatalog: {
      defaultModelId: "opencode-go/deepseek-v4-flash",
      models: [],
    },
  }).adapter;
  const entry = await adapter.getRuntimeListEntry();
  assert.equal(entry.id, "opencode");
  assert.equal(entry.status, "ready");
  assert.equal(entry.capabilities.planMode, true);
  assert.equal(entry.modelCatalog.defaultModelId, "opencode-go/deepseek-v4-flash");
  assert.deepEqual(mapServerStatus("stopped"), {
    status: "degraded",
    statusMessage: "OpenCode server is not running; it will start on first use.",
  });
});

test("OpenCode runtime adapter passes defaultBuildAgentName from agent catalog", async () => {
  const adapter = createOpenCodeRuntimeAdapter({
    serverManager: {
      getStatus() {
        return { state: "stopped" };
      },
    },
    threadAgentState: createThreadAgentStateStore(),
    fsImpl: {
      existsSync: () => true,
      readFileSync: () => JSON.stringify({}),
    },
    agentCatalogProvider: {
      async get() {
        return {
          agents: [
            {
              id: "Sisyphus - Ultraworker",
              displayName: "Sisyphus - Ultraworker",
              isDefaultBuild: true,
              isDefaultPlan: false,
            },
          ],
          defaultBuildAgentName: "Sisyphus - Ultraworker",
          defaultPlanAgentName: "plan",
        };
      },
    },
    modelCatalogProvider: {
      async get() {
        return {
          defaultModelId: "opencode-go/deepseek-v4-flash",
          models: [],
        };
      },
    },
  });

  const entry = await adapter.getRuntimeListEntry();
  assert.equal(entry.defaultBuildAgentName, "Sisyphus - Ultraworker");
  assert.equal(entry.defaultPlanAgentName, "plan");
  assert.equal(entry.openCodeAgents[0].id, "Sisyphus - Ultraworker");
});

test("OpenCode thread/start creates a session, locks state, and emits canonical thread_started", async () => {
  const { adapter, stateStore, requests } = createAdapter({
    requestImpl: async () => ({ id: "ses_123", title: "OpenCode session" }),
  });
  const outbound = [];

  await adapter.handleRuntimeRequest({
    parsed: {
      id: "thread-start-1",
      method: "thread/start",
      params: {
        threadId: "thread-opencode",
        agentRuntime: "opencode",
        title: "Build it",
        cwd: "/repo",
      },
    },
    threadId: "thread-opencode",
    sendResponse(rawMessage) {
      outbound.push(JSON.parse(rawMessage));
    },
  });

  assert.deepEqual(requests[0], {
    method: "POST",
    path: "/session",
    body: { title: "Build it" },
  });
  assert.equal(outbound[0].id, "thread-start-1");
  assert.equal(outbound[0].result.thread.agentRuntime, "opencode");
  assert.equal(outbound[1].method, "remodex/event/thread_started");
  assert.equal(outbound[1].params.agentSessionId, "ses_123");
  const record = stateStore.get("thread-opencode");
  assert.equal(record.agentRuntime, "opencode");
  assert.equal(record.agentSessionId, "ses_123");
  assert.equal(record.runtimeLocked, true);
});

test("OpenCode thread/resume rebinds an existing session without POST /session", async () => {
  const { adapter, stateStore, requests } = createAdapter({
    requestImpl: async (method, path) => {
      if (method === "GET" && path === "/session/ses_existing") {
        return { id: "ses_existing", title: "Resumed session" };
      }
      throw new Error(`unexpected request ${method} ${path}`);
    },
  });
  stateStore.upsert("thread-opencode", {
    agentRuntime: "opencode",
    agentSessionId: "ses_existing",
    runtimeLocked: true,
  });
  const outbound = [];

  await adapter.handleRuntimeRequest({
    parsed: {
      id: "thread-resume-1",
      method: "thread/resume",
      params: { threadId: "thread-opencode" },
    },
    threadId: "thread-opencode",
    sendResponse(rawMessage) {
      outbound.push(JSON.parse(rawMessage));
    },
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].method, "GET");
  assert.equal(requests[0].path, "/session/ses_existing");
  assert.equal(outbound[0].result.thread.agentSessionId, "ses_existing");
  assert.equal(stateStore.get("thread-opencode")?.agentSessionId, "ses_existing");
});

test("OpenCode turn/start posts prompt_async and emits canonical turn_started", async () => {
  const { adapter, stateStore, requests } = createAdapter();
  stateStore.upsert("thread-opencode", {
    agentRuntime: "opencode",
    agentSessionId: "ses_123",
    opencodeBuildAgentName: "build",
    opencodePlanAgentName: "plan",
    runtimeLocked: true,
  });
  const outbound = [];

  await adapter.handleRuntimeRequest({
    parsed: {
      id: "turn-start-1",
      method: "turn/start",
      params: {
        threadId: "thread-opencode",
        turnId: "turn-123",
        prompt: "Fix the tests",
        mode: "plan",
      },
    },
    threadId: "thread-opencode",
    sendResponse(rawMessage) {
      outbound.push(JSON.parse(rawMessage));
    },
  });

  assert.deepEqual(requests[0], {
    method: "POST",
    path: "/session/ses_123/prompt_async",
    body: {
      parts: [{ type: "text", text: "Fix the tests" }],
      agent: "plan",
      model: { providerID: "opencode-go", modelID: "deepseek-v4-flash" },
    },
  });
  assert.equal(outbound[0].result.agentSessionId, "ses_123");
  assert.equal(outbound[1].method, "remodex/event/turn_started");
  assert.equal(outbound[1].params.turnId, "turn-123");
});

test("OpenCode turn/start converts iOS structured input items into prompt parts", async () => {
  const { adapter, stateStore, requests } = createAdapter();
  stateStore.upsert("thread-opencode", {
    agentRuntime: "opencode",
    agentSessionId: "ses_123",
    opencodeBuildAgentName: "build",
    opencodePlanAgentName: "planner",
    runtimeLocked: true,
  });

  await adapter.handleRuntimeRequest({
    parsed: {
      id: "turn-start-structured",
      method: "turn/start",
      params: {
        threadId: "thread-opencode",
        turnId: "turn-structured",
        input: [
          { type: "text", text: "Hey" },
          { type: "mention", name: "README", path: "/repo/README.md" },
          { type: "skill", name: "diagnose" },
        ],
        collaborationMode: {
          mode: "plan",
        },
      },
    },
    threadId: "thread-opencode",
    sendResponse() {},
  });

  assert.deepEqual(requests[0], {
    method: "POST",
    path: "/session/ses_123/prompt_async",
    body: {
      parts: [
        { type: "text", text: "Hey\n@README /repo/README.md\n$diagnose" },
      ],
      agent: "planner",
      model: { providerID: "opencode-go", modelID: "deepseek-v4-flash" },
    },
  });
});

test("OpenCode turn/start passes selected runtime model to prompt_async", async () => {
  const { adapter, stateStore, requests } = createAdapter();
  stateStore.upsert("thread-opencode", {
    agentRuntime: "opencode",
    agentSessionId: "ses_123",
    runtimeLocked: true,
  });

  await adapter.handleRuntimeRequest({
    parsed: {
      id: "turn-start-model",
      method: "turn/start",
      params: {
        threadId: "thread-opencode",
        turnId: "turn-model",
        prompt: "Use qwen",
        model: "opencode-go/qwen3.6-plus",
      },
    },
    threadId: "thread-opencode",
    sendResponse() {},
  });

  assert.equal(requests[0].path, "/session/ses_123/prompt_async");
  assert.deepEqual(requests[0].body.model, {
    providerID: "opencode-go",
    modelID: "qwen3.6-plus",
  });
});

test("OpenCode turn/start rejects empty prompt parts instead of starting a silent turn", async () => {
  const { adapter, stateStore, requests } = createAdapter();
  stateStore.upsert("thread-opencode", {
    agentRuntime: "opencode",
    agentSessionId: "ses_123",
    runtimeLocked: true,
  });

  await assert.rejects(
    () => adapter.handleRuntimeRequest({
      parsed: {
        id: "turn-start-empty",
        method: "turn/start",
        params: {
          threadId: "thread-opencode",
          turnId: "turn-empty",
          input: [],
        },
      },
      threadId: "thread-opencode",
      sendResponse() {},
    }),
    /non-empty prompt/
  );
  assert.equal(requests.length, 0);
});

test("OpenCode turn/start maps event stream deltas, completion, and diff refresh to canonical events", async () => {
  const { adapter, stateStore, requests, eventHandlers } = createAdapter({
    requestImpl: async (_method, path) => {
      if (path === "/session/ses_123/diff") {
        return [{ path: "README.md", type: "modified" }];
      }
      return null;
    },
  });
  stateStore.upsert("thread-opencode", {
    agentRuntime: "opencode",
    agentSessionId: "ses_123",
    opencodeBuildAgentName: "build",
    opencodePlanAgentName: "plan",
    runtimeLocked: true,
  });
  const outbound = [];

  await adapter.handleRuntimeRequest({
    parsed: {
      id: "turn-start-1",
      method: "turn/start",
      params: {
        threadId: "thread-opencode",
        turnId: "turn-123",
        prompt: "Say hello",
      },
    },
    threadId: "thread-opencode",
    sendResponse(rawMessage) {
      outbound.push(JSON.parse(rawMessage));
    },
  });

  assert.equal(eventHandlers.length, 1);
  eventHandlers[0]({
    type: "message.part.updated",
    properties: {
      sessionID: "ses_123",
      part: {
        id: "prt_text",
        sessionID: "ses_123",
        messageID: "msg_assistant",
        type: "text",
        text: "",
      },
      time: 1,
    },
  });
  eventHandlers[0]({
    type: "message.part.delta",
    properties: {
      sessionID: "ses_123",
      messageID: "msg_assistant",
      partID: "prt_text",
      field: "text",
      delta: "Hello from OpenCode",
    },
  });
  eventHandlers[0]({
    type: "message.updated",
    properties: {
      sessionID: "ses_123",
      info: {
        id: "msg_assistant",
        sessionID: "ses_123",
        role: "assistant",
        time: { created: 1, completed: 2 },
        finish: "stop",
      },
    },
  });
  await flushAsync();

  const methods = outbound.map((message) => message.method).filter(Boolean);
  assert.deepEqual(methods, [
    "remodex/event/turn_started",
    "remodex/event/assistant_delta",
    "remodex/event/assistant_completed",
    "remodex/event/diff_updated",
    "remodex/event/turn_completed",
  ]);
  assert.equal(outbound.find((message) => message.method === "remodex/event/assistant_delta").params.payload.delta, "Hello from OpenCode");
  assert.deepEqual(
    outbound.find((message) => message.method === "remodex/event/diff_updated").params.payload.diff,
    [{ path: "README.md", type: "modified" }]
  );
  assert.equal(requests.at(-1).method, "GET");
  assert.equal(requests.at(-1).path, "/session/ses_123/diff");
});

test("OpenCode permission request waits for phone response and replies to OpenCode", async () => {
  const { adapter, stateStore, requests, eventHandlers } = createAdapter();
  stateStore.upsert("thread-opencode", {
    agentRuntime: "opencode",
    agentSessionId: "ses_123",
    runtimeLocked: true,
  });
  const outbound = [];

  await adapter.handleRuntimeRequest({
    parsed: {
      id: "turn-start-1",
      method: "turn/start",
      params: {
        threadId: "thread-opencode",
        turnId: "turn-123",
        prompt: "Edit a file",
      },
    },
    threadId: "thread-opencode",
    sendResponse(rawMessage) {
      outbound.push(JSON.parse(rawMessage));
    },
  });
  eventHandlers[0]({
    type: "permission.asked",
    properties: {
      id: "per_123",
      sessionID: "ses_123",
      permission: "edit",
      patterns: ["src/**"],
      metadata: {},
      always: ["edit"],
    },
  });

  const permission = outbound.find((message) => message.method === "remodex/request/permission");
  assert.equal(permission.id, "per_123");

  const handled = await adapter.handleRuntimeResponse({
    rawMessage: JSON.stringify({
      id: "per_123",
      result: {
        permissions: { edit: true },
      },
    }),
    sendResponse(rawMessage) {
      outbound.push(JSON.parse(rawMessage));
    },
  });

  assert.equal(handled, true);
  assert.deepEqual(requests.at(-1), {
    method: "POST",
    path: "/session/ses_123/permissions/per_123",
    body: { response: "once" },
  });
  assert.equal(outbound.at(-1).method, "serverRequest/resolved");
  assert.equal(outbound.at(-1).params.requestId, "per_123");
});

test("OpenCode stop posts abort for the runtime session", async () => {
  const { adapter, stateStore, requests } = createAdapter({
    requestImpl: async () => true,
  });
  stateStore.upsert("thread-opencode", {
    agentRuntime: "opencode",
    agentSessionId: "ses_123",
  });
  const outbound = [];

  await adapter.handleRuntimeRequest({
    parsed: {
      id: "turn-stop-1",
      method: "turn/interrupt",
      params: {
        threadId: "thread-opencode",
      },
    },
    threadId: "thread-opencode",
    sendResponse(rawMessage) {
      outbound.push(JSON.parse(rawMessage));
    },
  });

  assert.equal(requests[0].method, "POST");
  assert.equal(requests[0].path, "/session/ses_123/abort");
  assert.equal(outbound[0].result.aborted, true);
});

function createAuthedFsImpl() {
  return {
    existsSync: (filePath) => String(filePath).endsWith("auth.json"),
    readFileSync: () => JSON.stringify({ openai: { token: "test-token" } }),
  };
}

function createAdapter({
  serverStatus = { state: "ready", baseUrl: "http://127.0.0.1:49152" },
  requestImpl,
  fsImpl = createAuthedFsImpl(),
  modelCatalog = {
    defaultModelId: "opencode-go/deepseek-v4-flash",
    models: [
      {
        id: "opencode-go/deepseek-v4-flash",
        model: "opencode-go/deepseek-v4-flash",
        displayName: "DeepSeek V4 Flash",
        providerID: "opencode-go",
        modelID: "deepseek-v4-flash",
        isDefault: true,
      },
      {
        id: "opencode-go/qwen3.6-plus",
        model: "opencode-go/qwen3.6-plus",
        displayName: "Qwen 3.6 Plus",
        providerID: "opencode-go",
        modelID: "qwen3.6-plus",
        isDefault: false,
      },
    ],
  },
} = {}) {
  const requests = [];
  const eventHandlers = [];
  const stateStore = createThreadAgentStateStore({ stateFile: null });
  const serverManager = {
    getStatus() {
      return serverStatus;
    },
    start() {
      serverStatus = { state: "ready", baseUrl: "http://127.0.0.1:49152" };
      return serverStatus;
    },
    async request(method, path, options = {}) {
      requests.push({ method, path, body: options.body });
      if (requestImpl) {
        return requestImpl(method, path, options);
      }
      return path === "/session" ? { id: "ses_123" } : null;
    },
    subscribeEvents({ onEvent }) {
      eventHandlers.push(onEvent);
      return {
        close() {},
        closed: Promise.resolve(),
      };
    },
  };
  return {
    adapter: createOpenCodeRuntimeAdapter({
      serverManager,
      threadAgentState: stateStore,
      fsImpl,
      discoverAgents: () => [
        { id: "build", displayName: "Build", isDefaultBuild: true, isDefaultPlan: false },
        { id: "plan", displayName: "Plan", isDefaultBuild: false, isDefaultPlan: true },
      ],
      modelCatalogProvider: {
        async get() {
          return modelCatalog;
        },
      },
      completionGraceMs: 0,
    }),
    eventHandlers,
    requests,
    stateStore,
  };
}

function flushAsync() {
  return new Promise((resolve) => setImmediate(resolve));
}
