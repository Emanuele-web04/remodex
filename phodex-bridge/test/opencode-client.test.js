// FILE: opencode-client.test.js
// Purpose: Verifies OpenCode SDK client wrapper without a live server (injected mock SDK).
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-client

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  buildModelFromAny,
  buildStaticSlashCommands,
  createOpenCodeClient,
  dispatchEvent,
  flattenProviderModels,
  normalizeCommandNameForSdk,
  normalizeCommandTokenForAllowlist,
  resolveAgentsList,
  resolveSessionIdFromCreateResponse,
  resolveSessionList,
} = require("../src/opencode-client");
const { sessionV2InfoToDiscoveredThread } = require("../src/opencode-models");

const TEST_BASE_URL = "http://127.0.0.1:4291";

function createMockOpencodeClientImpl() {
  return function createOpencodeClient() {
    return {
      provider: {
        list: async () => ({
          all: [
            {
              id: "anthropic",
              name: "Anthropic",
              source: "api",
              models: { "claude-sonnet-4": { id: "claude-sonnet-4", name: "Claude Sonnet 4" } },
            },
          ],
          connected: ["anthropic"],
          default: {},
        }),
      },
      app: {
        agents: async () => ({
          data: [{ name: "build", description: "Default agent" }],
        }),
        skills: async () => [],
      },
      session: {
        create: async () => ({ sessionID: "ses_test" }),
        get: async () => ({}),
        list: async () => ({
          data: [
            {
              id: "ses_external",
              title: "Mac CLI session",
              location: { directory: "/Users/me/work/repo" },
              time: { created: "2026-06-08T10:00:00.000Z", updated: "2026-06-08T11:00:00.000Z" },
            },
          ],
          limit: 50,
          limited: false,
        }),
        prompt: async () => ({}),
        command: async () => ({}),
        setConfig: async () => ({}),
        abort: async () => ({}),
        messages: async () => ({ messages: [] }),
        fork: async () => ({ sessionID: "ses_fork" }),
      },
      permission: {
        reply: async () => ({}),
      },
      command: {
        list: async () => [{ token: "/build", title: "Build" }, { token: "/compact", title: "Compact" }],
      },
      event: {
        subscribe: async () => ({
          stream: (async function* eventStream() {
            yield { type: "turn.started", turnID: "turn-1" };
          })(),
          close: () => {},
        }),
      },
      tui: {
        selectSession: async () => ({}),
      },
    };
  };
}

async function createTestClient() {
  return createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: createMockOpencodeClientImpl(),
  });
}

test("throws when baseUrl is empty", async () => {
  await assert.rejects(() => createOpenCodeClient({ baseUrl: "" }), { message: /baseUrl/ });
});

test("throws when baseUrl is missing", async () => {
  await assert.rejects(() => createOpenCodeClient({}), { message: /baseUrl/ });
});

test("creates client when baseUrl is provided", async () => {
  const client = await createTestClient();
  assert.ok(client, "client object exists");
  assert.equal(typeof client.listModels, "function");
  assert.equal(typeof client.listAgents, "function");
  assert.equal(typeof client.createSession, "function");
  assert.equal(typeof client.getSession, "function");
  assert.equal(typeof client.prompt, "function");
  assert.equal(typeof client.abort, "function");
  assert.equal(typeof client.getMessages, "function");
  assert.equal(typeof client.replyToPermission, "function");
  assert.equal(typeof client.subscribeToEvents, "function");
  assert.equal(typeof client.fork, "function");
  assert.equal(typeof client.sessionCommand, "function");
  assert.equal(typeof client.listCommands, "function");
  assert.equal(typeof client.listSkills, "function");
});

test("listModels returns connected-only models with meta", async () => {
  const client = await createTestClient();
  const result = await client.listModels();
  assert.equal(result.models.length, 1);
  assert.equal(result.models[0].upstreamProviderId, "anthropic");
  assert.equal(result.models[0].upstreamProviderDisplayName, "Anthropic");
  assert.equal(result.meta.reasonCode, "ok");
  assert.deepEqual(result.meta.connectedProviderIds, ["anthropic"]);
});

test("flattenProviderModels preserves upstream provider metadata", () => {
  const models = flattenProviderModels({
    providers: [
      {
        id: "anthropic",
        models: [{ id: "claude-sonnet-4", name: "Claude Sonnet 4" }],
      },
      {
        id: "openai",
        models: [{ id: "gpt-5.5", displayName: "GPT-5.5" }],
      },
    ],
  });

  assert.equal(models.length, 2);
  assert.equal(models[0].modelProvider, "opencode");
  assert.equal(models[0].upstreamProviderId, "anthropic");
  assert.equal(models[0].id, "anthropic/claude-sonnet-4");
  assert.equal(models[1].upstreamProviderId, "openai");
  assert.equal(models[1].upstreamProviderDisplayName, "OpenAI");
});

test("flattenProviderModels unwraps SDK provider.list envelope with object models", () => {
  const models = flattenProviderModels({
    data: {
      all: [
        {
          id: "anthropic",
          models: {
            "claude-sonnet-4": { id: "claude-sonnet-4", name: "Claude Sonnet 4" },
          },
        },
        {
          id: "openai",
          models: {
            "gpt-5.5": { id: "gpt-5.5", displayName: "GPT-5.5" },
          },
        },
      ],
    },
  });

  assert.equal(models.length, 2);
  assert.equal(models[0].upstreamProviderId, "anthropic");
  assert.equal(models[1].upstreamProviderId, "openai");
});

test("resolveAgentsList unwraps SDK app.agents envelope", () => {
  const agents = resolveAgentsList({
    data: [
      { name: "build", description: "Default agent" },
      { name: "plan", description: "Plan mode", hidden: true },
    ],
  });

  assert.equal(agents.length, 2);
  assert.equal(agents[0].name, "build");
});

test("listAgents returns agent array", async () => {
  const client = await createTestClient();
  const agents = await client.listAgents();
  assert.equal(agents.length, 1);
  assert.equal(agents[0].id, "build");
});

test("resolveSessionIdFromCreateResponse reads nested and top-level envelopes", () => {
  assert.equal(
    resolveSessionIdFromCreateResponse({ data: { id: "ses_test" } }),
    "ses_test",
  );
  assert.equal(
    resolveSessionIdFromCreateResponse({ data: { sessionID: "ses_nested" } }),
    "ses_nested",
  );
  assert.equal(
    resolveSessionIdFromCreateResponse({ data: { sessionId: "ses_data_sessionId" } }),
    "ses_data_sessionId",
  );
  assert.equal(
    resolveSessionIdFromCreateResponse({ sessionID: "ses_top" }),
    "ses_top",
  );
  assert.equal(
    resolveSessionIdFromCreateResponse({ sessionId: "ses_top_sessionId" }),
    "ses_top_sessionId",
  );
  assert.equal(
    resolveSessionIdFromCreateResponse({ id: "ses_top_id" }),
    "ses_top_id",
  );
  assert.equal(resolveSessionIdFromCreateResponse(null), "");
  assert.equal(resolveSessionIdFromCreateResponse(undefined), "");
  assert.equal(resolveSessionIdFromCreateResponse({}), "");
  assert.equal(resolveSessionIdFromCreateResponse({ data: {} }), "");
  assert.equal(resolveSessionIdFromCreateResponse({ data: { id: "" } }), "");
});

test("createSession requires cwd", async () => {
  const client = await createTestClient();
  const sessionId = await client.createSession({ cwd: "/tmp/project" });
  assert.equal(sessionId, "ses_test");
});

test("createSession fails fast when response has no session id", async () => {
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      provider: {
        list: async () => ({ all: [], connected: [], default: {} }),
      },
      app: { agents: async () => ({ data: [] }), skills: async () => [] },
      session: {
        create: async () => ({ data: {} }),
        get: async () => ({}),
        prompt: async () => ({}),
        abort: async () => ({}),
        messages: async () => ({ messages: [] }),
        fork: async () => ({ data: {} }),
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

  await assert.rejects(
    () => client.createSession({ cwd: "/tmp/project" }),
    /returned no session id/,
  );
  await assert.rejects(() => client.fork("ses_parent"), /returned no session id/);
});

test("createSession resolves session id from SDK data.id envelope", async () => {
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      provider: {
        list: async () => ({ all: [], connected: [], default: {} }),
      },
      app: { agents: async () => ({ data: [] }), skills: async () => [] },
      session: {
        create: async () => ({ data: { id: "ses_data_envelope" } }),
        get: async () => ({}),
        prompt: async () => ({}),
        abort: async () => ({}),
        messages: async () => ({ messages: [] }),
        fork: async () => ({ data: { id: "ses_fork_data" } }),
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
  const sessionId = await client.createSession({ cwd: "/tmp/project" });
  assert.equal(sessionId, "ses_data_envelope");
  const forkId = await client.fork("ses_data_envelope");
  assert.equal(forkId, "ses_fork_data");
});

test("subscribeToEvents returns unsubscribe and exits cleanly", async () => {
  const client = await createTestClient();
  const events = [];

  const unsubscribe = client.subscribeToEvents((method, payload) => {
    events.push(method);
  });

  assert.equal(typeof unsubscribe, "function");

  await new Promise((resolve) => setTimeout(resolve, 10));
  unsubscribe();
  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.deepEqual(events, ["turn/started"]);
});

test("abort sends session abort", async () => {
  const client = await createTestClient();
  await assert.doesNotReject(() => client.abort("ses_test"));
});

test("getMessages returns message array", async () => {
  const client = await createTestClient();
  const messages = await client.getMessages("ses_test");
  assert.deepEqual(messages, []);
});

test("replyToPermission sends permission reply", async () => {
  const client = await createTestClient();
  await assert.doesNotReject(() => client.replyToPermission("perm-1", true));
});

test("normalizeCommandNameForSdk strips leading slash", () => {
  assert.equal(normalizeCommandNameForSdk("/skills"), "skills");
  assert.equal(normalizeCommandNameForSdk("skills"), "skills");
});

test("normalizeCommandTokenForAllowlist lowercases slash token", () => {
  assert.equal(normalizeCommandTokenForAllowlist("/Skills"), "/skills");
  assert.equal(normalizeCommandTokenForAllowlist("skills"), "/skills");
});

test("buildStaticSlashCommands marks builtins requiresArguments false", () => {
  const builtins = buildStaticSlashCommands();
  assert.ok(builtins.length >= 15);
  assert.ok(builtins.every((entry) => entry.requiresArguments === false));
});

test("sessionCommand strips leading slash for SDK session.command", async () => {
  const sdkCalls = [];
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      session: {
        command: async (body) => {
          sdkCalls.push(body);
          return {};
        },
      },
    }),
  });

  await client.sessionCommand({
    sessionID: "ses_cmd",
    command: "/skills",
    arguments: "",
    cwd: "/tmp/project",
  });

  assert.equal(sdkCalls.length, 1);
  assert.equal(sdkCalls[0].command, "skills");
  assert.equal(sdkCalls[0].arguments, "");
  assert.equal(sdkCalls[0].directory, "/tmp/project");
});

test("listCommands maps SDK template hints and requiresArguments", async () => {
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      command: {
        list: async () => [
          {
            name: "plan",
            title: "Plan",
            description: "Plan work",
            template: "Focus:\n$ARGUMENTS",
            hints: ["$ARGUMENTS"],
            source: "command",
          },
          {
            name: "lint",
            title: "Lint",
            description: "Lint project",
            template: "Run lint",
            hints: [],
          },
        ],
      },
    }),
  });

  const commands = await client.listCommands("/tmp/project");
  const plan = commands.find((entry) => entry.token === "/plan");
  const lint = commands.find((entry) => entry.token === "/lint");
  assert.ok(plan, "includes SDK /plan");
  assert.equal(plan.requiresArguments, true);
  assert.equal(plan.template, "Focus:\n$ARGUMENTS");
  assert.deepEqual(plan.hints, ["$ARGUMENTS"]);
  assert.equal(plan.source, "command");
  assert.ok(lint, "includes SDK /lint");
  assert.equal(lint.requiresArguments, false);
});

test("listCommands API surface is exposed", async () => {
  const client = await createTestClient();
  const commands = await client.listCommands("/tmp/project");
  // command/list includes CLI builtins (/undo etc) + agent-derived + count
  const tokens = commands.map((c) => c.token);
  assert.ok(commands.length === 16, `expected 15 builtins + 1 agent-derived (/build), got ${commands.length}`);
  assert.ok(tokens.includes("/undo"), "includes CLI builtin /undo");
  assert.ok(tokens.includes("/redo"), "includes CLI builtin /redo");
  assert.ok(tokens.includes("/compact"), "includes CLI builtin /compact");
  assert.ok(tokens.includes("/build"), "includes agent-derived /build");
  assert.ok(tokens.includes("/exit"), "includes CLI builtin /exit");
  // dedup + precede verified explicitly (overlap /compact collapsed to 1; first derived at/after index 15)
  assert.equal(tokens.filter((t) => t === "/compact").length, 1, "dedup on overlap");
  const firstDerivedIdx = tokens.findIndex((t) => t === "/build");
  assert.ok(firstDerivedIdx >= 15, "builtins precede any derived");
});

test("dispatchEvent maps session.next.text.delta to agent message delta", () => {
  const events = [];
  dispatchEvent(
    {
      type: "session.next.text.delta",
      properties: {
        sessionID: "ses-1",
        delta: "Hello ",
      },
    },
    (method, payload) => events.push([method, payload]),
  );

  assert.equal(events.length, 1);
  assert.equal(events[0][0], "item/agentMessage/delta");
  assert.equal(events[0][1].delta, "Hello");
  assert.equal(events[0][1].textDelta, "Hello");
});

test("dispatchEvent maps session.next.text.delta.1 suffix events", () => {
  const events = [];
  dispatchEvent(
    {
      type: "session.next.text.delta.1",
      properties: { sessionID: "ses-1", delta: "partial" },
    },
    (method) => events.push(method),
  );
  assert.deepEqual(events, ["item/agentMessage/delta"]);
});

test("dispatchEvent maps session.next.tool.called and tool.success", () => {
  const events = [];
  dispatchEvent(
    {
      type: "session.next.tool.called",
      properties: {
        sessionID: "ses-1",
        callID: "call-1",
        tool: "bash",
        input: { command: "ls" },
      },
    },
    (method, payload) => events.push([method, payload]),
  );
  dispatchEvent(
    {
      type: "session.next.tool.success",
      properties: {
        sessionID: "ses-1",
        callID: "call-1",
        content: [{ type: "text", text: "done" }],
      },
    },
    (method, payload) => events.push([method, payload]),
  );

  assert.equal(events[0][0], "item/toolCall");
  assert.equal(events[0][1].toolName, "bash");
  assert.equal(events[1][0], "item/toolCallUpdate");
  assert.equal(events[1][1].status, "completed");
  assert.equal(events[2][0], "item/completed");
});

test("dispatchEvent maps session.next.reasoning.delta", () => {
  const events = [];
  dispatchEvent(
    {
      type: "session.next.reasoning.delta",
      properties: {
        sessionID: "ses-1",
        reasoningID: "reason-1",
        delta: "thinking",
      },
    },
    (method) => events.push(method),
  );
  assert.deepEqual(events, ["item/reasoning/textDelta"]);
});

test("dispatchEvent maps session.idle to turn/completed", () => {
  const events = [];
  dispatchEvent(
    { type: "session.idle", properties: { sessionID: "ses-1", turnID: "turn-9" } },
    (method, payload) => events.push([method, payload]),
  );
  assert.equal(events.length, 1);
  assert.equal(events[0][0], "turn/completed");
  assert.equal(events[0][1].status, "completed");
  assert.equal(events[0][1].completionSource, "session.idle");
});

test("dispatchEvent maps message.part.delta properties to agentMessage delta", () => {
  const events = [];
  dispatchEvent(
    {
      type: "message.part.delta",
      properties: {
        sessionID: "ses-1",
        messageID: "msg-1",
        partID: "part-1",
        field: "text",
        delta: "Hello",
      },
    },
    (method, payload) => events.push([method, payload]),
  );
  assert.equal(events.length, 1);
  assert.equal(events[0][0], "item/agentMessage/delta");
  assert.equal(events[0][1].delta, "Hello");
  assert.equal(events[0][1].itemId, "part-1");
});

function createProbeMockClient({ connected = [], auth = {} } = {}) {
  return function createOpencodeClient() {
    return {
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
    };
  };
}

test("probeConnectedProviders returns false when connected list is empty", async () => {
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: createProbeMockClient({ connected: [] }),
  });
  assert.equal(await client.probeConnectedProviders(), false);
});

test("probeConnectedProviders returns true when connected providers exist", async () => {
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: createProbeMockClient({ connected: ["anthropic"] }),
  });
  assert.equal(await client.probeConnectedProviders(), true);
});

test("probeProviderAuthState returns true when auth methods are configured", async () => {
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: createProbeMockClient({
      auth: { anthropic: ["oauth"], openai: ["api"] },
    }),
  });
  assert.equal(await client.probeProviderAuthState(), true);
});

test("prompt passes parsed model agent and variant to session.prompt", async () => {
  const captured = [];
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      provider: {
        list: async () => ({
          all: [{ id: "opencode-go", name: "OpenCode Go", models: {} }],
          connected: ["opencode-go"],
          default: {},
        }),
        auth: async () => ({}),
      },
      app: { agents: async () => ({ data: [] }), skills: async () => [] },
      session: {
        create: async () => ({ sessionID: "ses_prompt" }),
        get: async () => ({}),
        prompt: async (body) => {
          captured.push(body);
          return {};
        },
        abort: async () => ({}),
        messages: async () => ({ messages: [] }),
        fork: async () => ({ sessionID: "ses_fork" }),
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

  const promptLogs = [];
  const originalLog = console.log;
  console.log = (value) => {
    if (typeof value === "string") {
      try {
        const parsed = JSON.parse(value);
        if (parsed?.event === "opencode_turn_prompt") {
          promptLogs.push(parsed);
        }
      } catch {
        // Ignore non-JSON console output.
      }
    }
    originalLog(value);
  };

  try {
    await client.prompt({
      sessionID: "ses_prompt",
      prompt: "hi",
      model: "opencode-go/deepseek-v4-flash",
      agent: "build",
      variant: "max",
      threadId: "thread-42",
      turnId: "turn-42",
    });
  } finally {
    console.log = originalLog;
  }

  assert.equal(captured.length, 1);
  assert.deepEqual(captured[0].model, {
    providerID: "opencode-go",
    modelID: "deepseek-v4-flash",
  });
  assert.equal(captured[0].agent, "build");
  assert.equal(captured[0].variant, "max");
  assert.equal(promptLogs.length, 1);
  assert.equal(promptLogs[0].threadId, "thread-42");
  assert.equal(promptLogs[0].turnId, "turn-42");
  assert.equal(promptLogs[0].sessionId, "ses_prompt");
});

test("probeProviderAuthState returns false when auth payload has no methods", async () => {
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: createProbeMockClient({ auth: { anthropic: [] } }),
  });
  assert.equal(await client.probeProviderAuthState(), false);
});

test("buildModelFromAny sets logoProviderId for OpenCode Zen upstream", () => {
  const zenModel = buildModelFromAny(
    { id: "free", name: "Free" },
    { id: "opencode", name: "OpenCode Zen" },
  );
  assert.equal(zenModel.logoProviderId, "opencode-zen");
  assert.equal(zenModel.upstreamProviderId, "opencode");
  assert.equal(zenModel.upstreamProviderDisplayName, "OpenCode Zen");
});

test("buildModelFromAny includes logoProviderId for generic OpenCode upstream", () => {
  const model = buildModelFromAny(
    { id: "free", name: "Free" },
    { id: "opencode", name: "OpenCode" },
  );
  assert.equal(model.logoProviderId, "opencode");
});

test("subscribeToEvents resets attempt after first event", async () => {
  let subscribeCalls = 0;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      event: {
        subscribe: async () => {
          subscribeCalls += 1;
          if (subscribeCalls === 1) {
            return {
              stream: (async function* failingStream() {
                yield { type: "turn.started", turnID: "turn-1" };
                throw new Error("stream dropped");
              })(),
              close: () => {},
            };
          }
          return {
            stream: (async function* stableStream() {
              yield { type: "turn.started", turnID: "turn-2" };
              await new Promise(() => {});
            })(),
            close: () => {},
          };
        },
      },
    }),
  });

  const resubscribes = [];
  const unsubscribe = client.subscribeToEvents(
    () => {},
    {
      reconnectBaseDelayMs: 1,
      maxReconnectAttempts: 2,
      onResubscribe: (details) => {
        resubscribes.push(details);
      },
    },
  );

  await new Promise((resolve) => setTimeout(resolve, 30));
  unsubscribe();
  await new Promise((resolve) => setTimeout(resolve, 10));

  assert.equal(resubscribes.length, 1);
  assert.equal(resubscribes[0].attempt, 1);
  assert.equal(resubscribes[0].reason, "error");
  assert.equal(subscribeCalls, 2);
});

test("subscribeToEvents clears reconnect timer on unsubscribe", async () => {
  // This test verifies that the reconnect timer is properly cleared
  // when unsubscribe is called (race condition fix)
  let subscribeCalls = 0;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      event: {
        subscribe: async () => {
          subscribeCalls += 1;
          return {
            stream: (async function* failingStream() {
              yield { type: "turn.started", turnID: "turn-1" };
              throw new Error("stream dropped");
            })(),
            close: () => {},
          };
        },
      },
    }),
  });

  const unsubscribe = client.subscribeToEvents(
    () => {},
    {
      reconnectBaseDelayMs: 100,
      maxReconnectAttempts: 10,
    },
  );

  // Wait for the stream to fail and enter reconnect delay
  await new Promise((resolve) => setTimeout(resolve, 20));

  // Unsubscribe while reconnect timer is active
  unsubscribe();

  // Wait longer than the reconnect delay
  await new Promise((resolve) => setTimeout(resolve, 150));

  // Should not have attempted another subscribe after unsubscribe
  assert.equal(subscribeCalls, 1, "should not resubscribe after unsubscribe");
});

test("subscribeToEvents unsubscribe before reconnect delay", async () => {
  // Test that unsubscribe called immediately after stream failure
  // before the delay timer fires prevents resubscription
  let subscribeCalls = 0;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      event: {
        subscribe: async () => {
          subscribeCalls += 1;
          return {
            stream: (async function* failingStream() {
              throw new Error("immediate failure");
            })(),
            close: () => {},
          };
        },
      },
    }),
  });

  const unsubscribe = client.subscribeToEvents(
    () => {},
    {
      reconnectBaseDelayMs: 200,
      maxReconnectAttempts: 5,
    },
  );

  // Unsubscribe immediately (before delay timer would fire)
  await new Promise((resolve) => setTimeout(resolve, 5));
  unsubscribe();

  // Wait past the delay period
  await new Promise((resolve) => setTimeout(resolve, 250));

  // Should only have the initial subscribe call
  assert.equal(subscribeCalls, 1, "should not resubscribe when unsubscribed before delay");
});

test("subscribeToEvents unsubscribe after successful resubscribe", async () => {
  // Test that unsubscribe works correctly after a successful resubscribe
  let subscribeCalls = 0;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      event: {
        subscribe: async () => {
          subscribeCalls += 1;
          if (subscribeCalls === 1) {
            return {
              stream: (async function* failingStream() {
                yield { type: "turn.started", turnID: "turn-1" };
                throw new Error("first stream failed");
              })(),
              close: () => {},
            };
          }
          return {
            stream: (async function* stableStream() {
              yield { type: "turn.started", turnID: "turn-2" };
              await new Promise(() => {});
            })(),
            close: () => {},
          };
        },
      },
    }),
  });

  const unsubscribe = client.subscribeToEvents(
    () => {},
    {
      reconnectBaseDelayMs: 10,
      maxReconnectAttempts: 3,
    },
  );

  // Wait for first failure and resubscribe
  await new Promise((resolve) => setTimeout(resolve, 30));

  // Should have resubscribed once
  assert.equal(subscribeCalls, 2, "should have resubscribed once");

  // Now unsubscribe
  unsubscribe();

  // Wait to ensure no further resubscribes
  await new Promise((resolve) => setTimeout(resolve, 50));

  // Should still only have 2 subscribe calls
  assert.equal(subscribeCalls, 2, "should not resubscribe after unsubscribe");
});

test("subscribeToEvents multiple rapid unsubscribe calls", async () => {
  // Test that multiple rapid unsubscribe calls don't cause issues
  let subscribeCalls = 0;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      event: {
        subscribe: async () => {
          subscribeCalls += 1;
          return {
            stream: (async function* failingStream() {
              yield { type: "turn.started", turnID: "turn-1" };
              throw new Error("stream dropped");
            })(),
            close: () => {},
          };
        },
      },
    }),
  });

  const unsubscribe = client.subscribeToEvents(
    () => {},
    {
      reconnectBaseDelayMs: 100,
      maxReconnectAttempts: 10,
    },
  );

  // Wait for stream to fail
  await new Promise((resolve) => setTimeout(resolve, 20));

  // Call unsubscribe multiple times rapidly
  unsubscribe();
  unsubscribe();
  unsubscribe();

  // Wait past delay
  await new Promise((resolve) => setTimeout(resolve, 150));

  // Should still only have 1 subscribe call
  assert.equal(subscribeCalls, 1, "multiple unsubscribe calls should be safe");
});

test("subscribeToEvents unsubscribe with reconnect disabled", async () => {
  // Test that unsubscribe works when reconnect is disabled
  let subscribeCalls = 0;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      event: {
        subscribe: async () => {
          subscribeCalls += 1;
          return {
            stream: (async function* failingStream() {
              yield { type: "turn.started", turnID: "turn-1" };
              throw new Error("stream dropped");
            })(),
            close: () => {},
          };
        },
      },
    }),
  });

  const unsubscribe = client.subscribeToEvents(
    () => {},
    {
      reconnectEnabled: false,
      reconnectBaseDelayMs: 100,
      maxReconnectAttempts: 10,
    },
  );

  // Wait for stream to fail
  await new Promise((resolve) => setTimeout(resolve, 20));

  // Unsubscribe
  unsubscribe();

  // Wait past what would be the delay
  await new Promise((resolve) => setTimeout(resolve, 150));

  // Should only have 1 subscribe call (reconnect disabled)
  assert.equal(subscribeCalls, 1, "should not resubscribe when reconnect disabled");
});

test("subscribeToEvents respects maxReconnectAttempts", async () => {
  // Test that maxReconnectAttempts is respected and stops after limit
  let subscribeCalls = 0;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      event: {
        subscribe: async () => {
          subscribeCalls += 1;
          // After max attempts, return a stable stream to stop reconnection
          if (subscribeCalls > 3) {
            return {
              stream: (async function* stableStream() {
                await new Promise(() => {});
              })(),
              close: () => {},
            };
          }
          return {
            stream: (async function* failingStream() {
              yield { type: "turn.started", turnID: `turn-${subscribeCalls}` };
              throw new Error("stream dropped");
            })(),
            close: () => {},
          };
        },
      },
    }),
  });

  const resubscribes = [];
  const unsubscribe = client.subscribeToEvents(
    () => {},
    {
      reconnectBaseDelayMs: 5,
      maxReconnectAttempts: 3,
      onResubscribe: (details) => {
        resubscribes.push(details);
      },
    },
  );

  // Wait for all attempts to exhaust
  await new Promise((resolve) => setTimeout(resolve, 50));

  // Should have attempted initial + 3 retries = 4 total
  assert.equal(subscribeCalls, 4, "should attempt initial + maxReconnectAttempts");
  assert.equal(resubscribes.length, 3, "should have 3 resubscribe callbacks");

  unsubscribe();
});

test("subscribeToEvents exponential backoff", async () => {
  // Test that reconnect delay follows exponential backoff
  const delays = [];
  let subscribeCalls = 0;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: () => ({
      event: {
        subscribe: async () => {
          subscribeCalls += 1;
          // After max attempts, return a stable stream to stop reconnection
          if (subscribeCalls > 3) {
            return {
              stream: (async function* stableStream() {
                await new Promise(() => {});
              })(),
              close: () => {},
            };
          }
          return {
            stream: (async function* failingStream() {
              throw new Error("stream dropped");
            })(),
            close: () => {},
          };
        },
      },
    }),
  });

  const startTime = Date.now();
  const unsubscribe = client.subscribeToEvents(
    () => {},
    {
      reconnectBaseDelayMs: 10,
      maxReconnectAttempts: 3,
      onResubscribe: (details) => {
        delays.push(Date.now() - startTime);
      },
    },
  );

  // Wait for all attempts to exhaust
  await new Promise((resolve) => setTimeout(resolve, 100));
  unsubscribe();

  // Verify delays increase (exponential backoff)
  assert.ok(delays.length >= 2, "should have at least 2 resubscribe attempts");
  assert.ok(delays[1] > delays[0], "second delay should be longer than first");
});

test("buildModelFromAny sets logoProviderId for OpenCode Go upstream", () => {
  const goModel = buildModelFromAny(
    { id: "deepseek-v4-flash", name: "DeepSeek V4 Flash" },
    { id: "opencode-go", name: "OpenCode Go" },
  );
  assert.equal(goModel.logoProviderId, "opencode-go");
  assert.equal(goModel.upstreamProviderId, "opencode-go");
});

test("resolveSessionList maps external sessions to discovered thread rows", () => {
  const result = resolveSessionList({
    data: [
      {
        id: "ses_external",
        title: "Mac CLI session",
        location: { directory: "/Users/me/work/repo" },
        time: { created: "2026-06-08T10:00:00.000Z", updated: "2026-06-08T11:00:00.000Z" },
      },
      {
        id: "ses_child",
        parentID: "ses_parent",
        title: "Child",
        time: { created: "2026-06-08T09:00:00.000Z" },
      },
      {
        id: "ses_archived",
        title: "Archived",
        time: { created: "2026-06-08T08:00:00.000Z", archived: true },
      },
    ],
    limit: 50,
    limited: false,
  });

  assert.equal(result.data.length, 1);
  assert.equal(result.data[0].id, "opencode-session-ses_external");
  assert.equal(result.data[0].cwd, "/Users/me/work/repo");
  assert.equal(result.data[0].metadata.discoveredExternally, true);
  assert.equal(result.data[0].metadata.sessionId, "ses_external");
});

test("sessionV2InfoToDiscoveredThread includes fresh TUI sessions with created time only", () => {
  const discovered = sessionV2InfoToDiscoveredThread({
    id: "ses_fresh",
    location: { directory: "/Users/me/work/fresh" },
    time: { created: "2026-06-08T12:00:00.000Z" },
  });

  assert.equal(discovered.id, "opencode-session-ses_fresh");
  assert.equal(discovered.cwd, "/Users/me/work/fresh");
});

test("sessionV2InfoToDiscoveredThread includes SDK numeric millis and session.path cwd", () => {
  const createdMillis = Date.parse("2026-06-08T12:34:56.789Z");
  const discovered = sessionV2InfoToDiscoveredThread({
    id: "ses_numeric",
    path: "/Users/me/work/from-path",
    model: { providerID: "anthropic", id: "claude-sonnet-4" },
    time: { created: createdMillis },
  });

  assert.equal(discovered.id, "opencode-session-ses_numeric");
  assert.equal(discovered.title, "OpenCode chat");
  assert.equal(discovered.cwd, "/Users/me/work/from-path");
  assert.equal(discovered.model, "anthropic/claude-sonnet-4");
  assert.equal(discovered.createdAt, new Date(createdMillis).toISOString());
});

test("sessionV2InfoToDiscoveredThread reads project.worktree and project.name from global sessions", () => {
  const discovered = sessionV2InfoToDiscoveredThread({
    id: "ses_global_proj",
    title: "Auth refactor",
    time: { created: "2026-06-08T10:00:00.000Z", updated: "2026-06-08T11:00:00.000Z" },
    project: { id: "proj_1", name: "auth-service", worktree: "/Users/me/auth-service" },
  });

  assert.equal(discovered.id, "opencode-session-ses_global_proj");
  assert.equal(discovered.title, "Auth refactor");
  assert.equal(discovered.cwd, "/Users/me/auth-service");
  assert.equal(discovered.metadata.projectName, "auth-service");
});

test("sessionV2InfoToDiscoveredThread falls back to project name in title when title is missing", () => {
  const discovered = sessionV2InfoToDiscoveredThread({
    id: "ses_no_title",
    time: { created: "2026-06-08T10:00:00.000Z" },
    project: { id: "proj_1", name: "payments", worktree: "/Users/me/payments" },
  });

  assert.equal(discovered.title, "payments · OpenCode chat");
  assert.equal(discovered.cwd, "/Users/me/payments");
});

test("resolveSessionList parses V2 response.items and cursor.next", () => {
  const result = resolveSessionList({
    items: [
      {
        id: "ses_items",
        title: "Items fixture",
        path: "/Users/me/work/items",
        time: { created: Date.parse("2026-06-08T13:00:00.000Z") },
      },
    ],
    cursor: { next: "opaque-cursor-2" },
  });

  assert.equal(result.data.length, 1);
  assert.equal(result.data[0].id, "opencode-session-ses_items");
  assert.equal(result.data[0].cwd, "/Users/me/work/items");
  assert.equal(result.nextCursor, "opaque-cursor-2");
});

test("listSessions uses experimental.session.list for global discovery", async () => {
  let experimentalCalled = false;
  let sessionCalled = false;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: function createOpencodeClient() {
      return {
        experimental: {
          session: {
            list: async (query) => {
              experimentalCalled = true;
              assert.equal(query.limit, 10);
              assert.equal(query.cursor, 5);
              return [
                {
                  id: "ses_global",
                  title: "Global session",
                  path: "/Users/me/work/global",
                  time: { created: Date.parse("2026-06-08T14:00:00.000Z") },
                },
              ];
            },
          },
        },
        session: {
          list: async () => {
            sessionCalled = true;
            return { data: [] };
          },
        },
      };
    },
  });

  const result = await client.listSessions({ limit: 10, cursor: 5 });
  assert.equal(experimentalCalled, true);
  assert.equal(sessionCalled, false);
  assert.equal(result.data.length, 1);
  assert.equal(result.data[0].id, "opencode-session-ses_global");
});

test("listSessions wraps SDK session.list with directory and start cursor", async () => {
  let sessionQuery = null;
  const client = await createOpenCodeClient({
    baseUrl: TEST_BASE_URL,
    createOpencodeClientImpl: function createOpencodeClient() {
      return {
        session: {
          list: async (query) => {
            sessionQuery = query;
            return {
              data: [
                {
                  id: "ses_external",
                  title: "Mac CLI session",
                  location: { directory: "/Users/me/work/repo" },
                  time: { created: "2026-06-08T10:00:00.000Z", updated: "2026-06-08T11:00:00.000Z" },
                },
              ],
              limit: 50,
              limited: false,
            };
          },
        },
      };
    },
  });

  const result = await client.listSessions({
    directory: "/Users/me/work/repo",
    limit: 10,
    cursor: 3,
  });
  assert.deepEqual(sessionQuery, {
    limit: 10,
    directory: "/Users/me/work/repo",
    start: 3,
  });
  assert.equal(result.data.length, 1);
  assert.equal(result.data[0].id, "opencode-session-ses_external");
});

test("listSessions falls back to direct fetch when SDK experimental.session.list is unavailable", async () => {
  const originalFetch = globalThis.fetch;
  let fetchUrl = null;
  globalThis.fetch = async (url) => {
    fetchUrl = String(url);
    return {
      ok: true,
      status: 200,
      headers: {
        get: (name) => (name.toLowerCase() === "x-next-cursor" ? "1719000000" : null),
      },
      json: async () => [
        {
          id: "ses_direct",
          title: "Direct fetch session",
          directory: "/Users/me/direct",
          time: { created: "2026-06-08T12:00:00.000Z", updated: "2026-06-08T13:00:00.000Z" },
        },
      ],
    };
  };

  try {
    const client = await createOpenCodeClient({
      baseUrl: TEST_BASE_URL,
      createOpencodeClientImpl: function createOpencodeClient() {
        return {
          session: {
            list: async () => ({ data: [] }),
          },
        };
      },
    });

    const result = await client.listSessions({ limit: 10 });
    assert.equal(fetchUrl, "http://127.0.0.1:4291/experimental/session?limit=10");
    assert.equal(result.data.length, 1);
    assert.equal(result.data[0].id, "opencode-session-ses_direct");
    assert.equal(result.data[0].cwd, "/Users/me/direct");
    assert.equal(result.nextCursor, "1719000000");
  } finally {
    globalThis.fetch = originalFetch;
  }
});