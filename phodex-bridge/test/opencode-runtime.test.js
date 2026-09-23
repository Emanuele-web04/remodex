// FILE: opencode-runtime.test.js
// Purpose: Verifies the released OpenCode server adapter without starting OpenCode.
// Layer: Unit test
// Depends on: node:test, node:assert/strict, ../src/opencode-runtime

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const {
  createOpenCodeRuntime,
  decodeThreadId,
  encodeThreadId,
  normalizeModels,
  normalizeTurns,
} = require("../src/opencode-runtime");

function response(body, { status = 200, contentType = "application/json", headers = {} } = {}) {
  return new Response(body === null ? null : contentType.includes("json") ? JSON.stringify(body) : body, {
    status,
    headers: { "content-type": contentType, ...headers },
  });
}

function createMockServer(overrides = {}) {
  const calls = [];
  const session = {
    id: "ses_test",
    projectID: "prj_test",
    slug: "test",
    directory: "/repo/app",
    title: "Existing title",
    version: "1.18.32",
    model: { providerID: "opencode", id: "big-pickle-free" },
    time: { created: 10, updated: 20 },
  };
  const routes = {
    "GET /global/health": () => response({ healthy: true, version: "1.18.32" }),
    "GET /provider": () => response({ all: [], default: {}, connected: [] }),
    "GET /project": () => response([{ id: "prj_test", worktree: "/repo" }]),
    "GET /session?scope=project&directory=%2Frepo&limit=1000000": () => response([session]),
    "GET /session/ses_test?directory=%2Frepo%2Fapp": () => response(session),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp": () => response([]),
    "GET /global/event": () => new Response(new ReadableStream({ start(controller) { controller.close(); } }), {
      headers: { "content-type": "text/event-stream" },
    }),
    ...overrides,
  };
  return {
    calls,
    session,
    async fetch(url, options = {}) {
      const parsed = new URL(url);
      const method = options.method || "GET";
      const key = `${method} ${parsed.pathname}${parsed.search}`;
      calls.push({ key, url, options, body: options.body ? JSON.parse(options.body) : undefined });
      const handler = routes[key];
      if (!handler) return response({ error: `missing mock ${key}` }, { status: 404 });
      return handler({ url: parsed, options, calls });
    },
  };
}

test("OpenCode thread ids are reversible and namespaced", () => {
  assert.equal(encodeThreadId("ses_123"), "opencode:ses_123");
  assert.equal(decodeThreadId("opencode:ses_123"), "ses_123");
  assert.equal(decodeThreadId("codex-thread"), null);
});

test("model catalog exposes Zen, Go, and locally priced free models", () => {
  assert.deepEqual(normalizeModels({ all: [
    { id: "opencode", name: "OpenCode Zen", models: {
      zen: { name: "Zen", cost: { input: 1, output: 2 } },
      "small-free": { name: "Small", cost: { input: 1, output: 2 } },
      pickle: { name: "Big Pickle", cost: { input: 0, output: 0 } },
    } },
    { id: "opencode-go", name: "OpenCode Go", models: { fast: { name: "Fast" } } },
    { id: "anthropic", name: "Anthropic", models: { hidden: {} } },
  ] }), [
    { id: "opencode/zen", name: "Zen", providerID: "opencode", providerName: "OpenCode Zen", tier: "zen", variants: [] },
    { id: "opencode/small-free", name: "Small", providerID: "opencode", providerName: "OpenCode Zen", tier: "free", variants: [] },
    { id: "opencode/pickle", name: "Big Pickle", providerID: "opencode", providerName: "OpenCode Zen", tier: "free", variants: [] },
    { id: "opencode-go/fast", name: "Fast", providerID: "opencode-go", providerName: "OpenCode Go", tier: "go", variants: [] },
  ]);
});

test("model variants use OpenCode's wire keys and respect an empty normalized catalog", () => {
  const models = normalizeModels({ all: [{ id: "opencode", models: {
    custom: { name: "Custom", variants: {
      fast: { reasoningEffort: "low" },
      deep: { reasoningEffort: "high" },
      creative: { temperature: 0.9 },
    }, options: { reasoningEffort: "high" } },
    disabled: { name: "Disabled", variants: {}, reasoning_options: [
      { type: "effort", values: ["low", "high"] },
    ] },
    fallback: { name: "Fallback", reasoning_options: [
      { type: "budget_tokens", values: [1024, 2048] },
      { type: "effort", values: [null, "low", "high"] },
    ] },
  } }] });
  assert.deepEqual(models[0].variants, [
    { id: "fast", reasoningEffort: "low" },
    { id: "deep", reasoningEffort: "high" },
  ]);
  assert.equal(models[0].defaultVariant, "deep");
  assert.deepEqual(models[1].variants, []);
  assert.deepEqual(models[2].variants, [
    { id: "none", reasoningEffort: "none" },
    { id: "low", reasoningEffort: "low" },
    { id: "high", reasoningEffort: "high" },
  ]);
  assert.equal(Object.hasOwn(models[2], "defaultVariant"), false);
});

test("history preserves message and part order with stable ids", () => {
  const turns = normalizeTurns([
    { info: { id: "msg_user", role: "user", time: { created: 1_790_000_000_000 } }, parts: [
      { id: "prt_u", messageID: "msg_user", type: "text", text: "Hello" },
      { id: "prt_image", messageID: "msg_user", type: "file", mime: "image/png", url: "data:image/png;base64,cG5n" },
    ] },
    { info: { id: "msg_assistant", role: "assistant", time: { created: 1_790_000_000_100 } }, parts: [
      { id: "prt_r", messageID: "msg_assistant", type: "reasoning", text: "Think" },
      { id: "prt_t", messageID: "msg_assistant", type: "text", text: "Hi", time: { start: 1_790_000_000_110 } },
      { id: "prt_ignored", messageID: "msg_assistant", type: "snapshot" },
    ] },
  ]);
  assert.equal(turns[0].id, "opencode-turn:msg_user");
  assert.deepEqual(turns[0].items.map((item) => item.id), ["prt_u", "prt_image", "prt_r", "prt_t"]);
  assert.equal(turns[0].items[0].role, "user");
  assert.equal(turns[0].items[1].content[0].type, "input_image");
  assert.equal(turns[0].items[3].text, "Hi");
  assert.equal(turns[0].createdAt, 1_790_000_000_000);
  assert.deepEqual(turns[0].items.map((item) => item.createdAt), [
    1_790_000_000_000, 1_790_000_000_000, 1_790_000_000_100, 1_790_000_000_110,
  ]);
});

test("metadata-only resume and read skip transcript loading and project scans", async (t) => {
  const session = { ...createMockServer().session,
    model: { providerID: "opencode", id: "big-pickle-free", variant: "high" } };
  const server = createMockServer({
    "GET /session/ses_test": () => response(session),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const resumed = await runtime.handleRequest({ method: "thread/resume", params: {
    threadId: "opencode:ses_test", excludeTurns: true,
  } });
  const read = await runtime.handleRequest({ method: "thread/read", params: {
    threadId: "opencode:ses_test", includeTurns: false,
  } });
  assert.equal(resumed.thread.model, "opencode/big-pickle-free");
  assert.equal(resumed.thread.reasoningEffort, "high");
  assert.equal(Object.hasOwn(resumed.thread, "turns"), false);
  assert.equal(Object.hasOwn(read.thread, "turns"), false);
  assert.equal(server.calls.some((call) => call.key.includes("/message")), false);
  assert.equal(server.calls.some((call) => call.key.includes("scope=project")), false);
});

test("resume refuses a folder change that the released OpenCode session API cannot apply", async (t) => {
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  await assert.rejects(runtime.handleRequest({ method: "thread/resume", params: {
    threadId: "opencode:ses_test", cwd: "/repo/other-worktree", excludeTurns: true,
  } }), /cannot move an existing chat/);
  assert.equal(server.calls.some((call) => call.key.includes("other-worktree")), false);
});

test("session model variant outranks an older message variant", async (t) => {
  const session = { ...createMockServer().session,
    model: { providerID: "opencode", id: "big-pickle-free", variant: "low" } };
  const server = createMockServer({
    "GET /session/ses_test": () => response(session),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp": () => response([
      { info: { id: "msg_user", role: "user", variant: "low" }, parts: [] },
      { info: { id: "msg_assistant", role: "assistant", variant: "high" }, parts: [] },
    ]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const read = await runtime.handleRequest({ method: "thread/read", params: { threadId: "opencode:ses_test" } });
  assert.equal(read.thread.reasoningEffort, "low");
});

test("full thread read recovers a message variant when the session has no variant", async (t) => {
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp": () => response([
      { info: { id: "msg_user", role: "user", model: { variant: "high" } }, parts: [] },
    ]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const read = await runtime.handleRequest({ method: "thread/read", params: { threadId: "opencode:ses_test" } });
  assert.equal(read.thread.reasoningEffort, "high");
});

test("metadata-only resume gets only the latest message when the session has no model", async (t) => {
  const session = { ...createMockServer().session, model: undefined };
  const server = createMockServer({
    "GET /session/ses_test": () => response(session),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=1": () => response([
      { info: { id: "msg_latest", role: "assistant", providerID: "opencode-go", modelID: "mac-fast" }, parts: [] },
    ]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const resumed = await runtime.handleRequest({ method: "thread/resume", params: {
    threadId: "opencode:ses_test", excludeTurns: true,
  } });
  assert.equal(resumed.thread.model, "opencode-go/mac-fast");
  assert.equal(Object.hasOwn(resumed.thread, "turns"), false);
  assert.equal(server.calls.some((call) => call.key === "GET /session/ses_test/message?directory=%2Frepo%2Fapp"), false);
});

test("turn/start infers a Mac session model from one message, without fetching history", async (t) => {
  const session = { ...createMockServer().session, model: undefined };
  const server = createMockServer({
    "GET /session/ses_test": () => response(session),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=1": () => response([
      { info: { id: "msg_latest", role: "assistant", providerID: "opencode-go", modelID: "mac-fast" }, parts: [] },
    ]),
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": () => response(null, { status: 204 }),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: "opencode:ses_test", input: [{ text: "Continue" }],
  } });
  assert.equal(server.calls.some((call) => call.key === "GET /session/ses_test/message?directory=%2Frepo%2Fapp"), false);
  assert.deepEqual(server.calls.find((call) => call.key.includes("prompt_async")).body.model, {
    providerID: "opencode-go", modelID: "mac-fast",
  });
});

test("phone turn polling streams a Mac-created session when serve emits no turn events", async (t) => {
  let reads = 0;
  let userMessageID;
  const outbound = [];
  const session = { ...createMockServer().session };
  const server = createMockServer({
    "GET /session/ses_test": () => response(session),
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": ({ options }) => {
      userMessageID = JSON.parse(options.body).messageID;
      return response(null, { status: 204 });
    },
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=20": () => {
      reads += 1;
      return response([
        { info: { id: userMessageID, role: "user" }, parts: [] },
        { info: { id: "msg_reply", role: "assistant", parentID: userMessageID,
          time: reads > 1 ? { completed: 123 } : {} },
          parts: [{ id: "prt_reply", type: "text", text: reads > 1 ? "Hello" : "Hel",
            ...(reads > 1 ? { time: { end: 123 } } : {}) }] },
      ]);
    },
    "GET /session/status?directory=%2Frepo%2Fapp": () => response({ ses_test: { type: reads > 1 ? "idle" : "busy" } }),
  });
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), turnPollIntervalMs: 5,
    idleCompletionGraceMs: 10, reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: "opencode:ses_test", input: [{ text: "Continue" }],
  } });
  await waitUntil(() => outbound.some((message) => message.method === "turn/completed"));
  assert.deepEqual(outbound.filter((message) => message.method === "item/agentMessage/delta")
    .map((message) => message.params.delta), ["lo"]);
  assert.equal(outbound.filter((message) => message.method === "item/started"
    && message.params.item.id === "prt_reply").length, 1);
  assert.equal(outbound.at(-1).params.turn.status, "completed");
});

test("phone turn polling follows older message pages when a tool-heavy turn exceeds 20 messages", async (t) => {
  let userMessageID;
  let reads = 0;
  const outbound = [];
  const session = { ...createMockServer().session };
  const assistantMessage = (index) => ({
    info: { id: `msg_reply_${index}`, role: "assistant", parentID: userMessageID, time: { completed: 123 } },
    parts: [{ id: `prt_reply_${index}`, type: "text", text: `step ${index}`, time: { end: 123 } }],
  });
  const server = createMockServer({
    "GET /session/ses_test": () => response(session),
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": ({ options }) => {
      userMessageID = JSON.parse(options.body).messageID;
      return response(null, { status: 204 });
    },
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=20": () => {
      reads += 1;
      return response(Array.from({ length: 20 }, (_, index) => assistantMessage(index + 6)), {
        headers: { "x-next-cursor": "older" },
      });
    },
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=20&before=older": () => response([
      { info: { id: userMessageID, role: "user" }, parts: [] },
      ...Array.from({ length: 5 }, (_, index) => assistantMessage(index + 1)),
    ]),
    "GET /session/status?directory=%2Frepo%2Fapp": () => response({
      ses_test: { type: reads > 1 ? "idle" : "busy" },
    }),
  });
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), turnPollIntervalMs: 5, reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: "opencode:ses_test", input: [{ text: "Continue" }],
  } });
  await waitUntil(() => outbound.some((message) => message.method === "turn/completed"));
  assert.equal(outbound.filter((message) => message.method === "item/started"
    && message.params.item.id === "prt_reply_1").length, 1);
  assert.ok(server.calls.some((call) => call.key.endsWith("before=older")));
});

test("polled OpenCode assistant errors finish the phone turn as failed", async (t) => {
  let userMessageID;
  const outbound = [];
  const session = { ...createMockServer().session };
  const server = createMockServer({
    "GET /session/ses_test": () => response(session),
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": ({ options }) => {
      userMessageID = JSON.parse(options.body).messageID;
      return response(null, { status: 204 });
    },
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=20": () => response([
      { info: { id: userMessageID, role: "user" }, parts: [] },
      { info: { id: "msg_failed", role: "assistant", parentID: userMessageID,
        error: { name: "ProviderError", data: { message: "Model unavailable" } },
        time: { completed: 123 } }, parts: [] },
    ]),
    "GET /session/status?directory=%2Frepo%2Fapp": () => response({}),
  });
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), turnPollIntervalMs: 5, reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: "opencode:ses_test", input: [{ text: "Continue" }],
  } });
  await waitUntil(() => outbound.some((message) => message.method === "turn/completed"));
  const terminal = outbound.find((message) => message.method === "turn/completed");
  assert.equal(terminal.params.turn.status, "failed");
  assert.equal(terminal.params.turn.error.message, "Model unavailable");
});

test("polled turns settle after repeated idle snapshots without a busy or completed marker", async (t) => {
  let userMessageID;
  let reads = 0;
  const outbound = [];
  const session = { ...createMockServer().session };
  const server = createMockServer({
    "GET /session/ses_test": () => response(session),
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": ({ options }) => {
      userMessageID = JSON.parse(options.body).messageID;
      return response(null, { status: 204 });
    },
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=20": () => {
      reads += 1;
      return response([{ info: { id: userMessageID, role: "user" }, parts: [] }]);
    },
    "GET /session/status?directory=%2Frepo%2Fapp": () => response({}),
  });
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), turnPollIntervalMs: 5,
    idleCompletionGraceMs: 10, reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: "opencode:ses_test", input: [{ text: "Continue" }],
  } });
  await waitUntil(() => outbound.some((message) => message.method === "turn/completed"));
  assert.ok(reads >= 2);
  assert.equal(outbound.find((message) => message.method === "turn/completed").params.turn.status, "completed");
});

test("turn paging follows requested order and stays anchored when Mac adds a turn", async (t) => {
  const message = (number, role) => ({
    info: { id: `msg_${number}_${role}`, role },
    parts: [{ id: `prt_${number}_${role}`, type: "text", text: `${number} ${role}` }],
  });
  const pair = (number) => [message(number, "user"), message(number, "assistant")];
  let messages = [1, 2, 3, 4].flatMap(pair);
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=50": () => response(messages),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp": () => response(messages),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const requestPage = (sortDirection, cursor) => runtime.handleRequest({ method: "thread/turns/list", params: {
    threadId: "opencode:ses_test", sortDirection, limit: 2, ...(cursor ? { cursor } : {}),
  } });
  const newest = await requestPage("desc");
  assert.deepEqual(newest.data.map((turn) => turn.id), ["opencode-turn:msg_4_user", "opencode-turn:msg_3_user"]);
  messages = [1, 2, 3, 4, 5].flatMap(pair);
  const older = await requestPage("desc", newest.nextCursor);
  assert.deepEqual(older.data.map((turn) => turn.id), ["opencode-turn:msg_2_user", "opencode-turn:msg_1_user"]);
  assert.equal(older.nextCursor, null);
  const oldest = await requestPage("asc");
  assert.deepEqual(oldest.data.map((turn) => turn.id), ["opencode-turn:msg_1_user", "opencode-turn:msg_2_user"]);
  const newer = await requestPage("asc", oldest.nextCursor);
  assert.deepEqual(newer.data.map((turn) => turn.id), ["opencode-turn:msg_3_user", "opencode-turn:msg_4_user"]);
});

test("native message pages extend to a complete user turn before slicing", async (t) => {
  const message = (id, role) => ({ info: { id, role }, parts: [{ id: `prt_${id}`, type: "text", text: id }] });
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=50": () => response([
      message("msg_2_assistant", "assistant"), message("msg_3_user", "user"), message("msg_3_assistant", "assistant"),
    ], { headers: { "x-next-cursor": "older" } }),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=50&before=older": () => response([
      message("msg_1_user", "user"), message("msg_1_assistant", "assistant"), message("msg_2_user", "user"),
    ]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const page = await runtime.handleRequest({ method: "thread/turns/list", params: {
    threadId: "opencode:ses_test", sortDirection: "desc", limit: 2,
  } });
  assert.deepEqual(page.data.map((turn) => turn.id), ["opencode-turn:msg_3_user", "opencode-turn:msg_2_user"]);
  assert.equal(page.data[1].items.length, 2);
  assert.ok(server.calls.some((call) => call.key.endsWith("&before=older")));
});

test("older turn pages reuse an opaque native cursor aligned to the last returned user", async (t) => {
  const message = (number, role) => ({
    info: { id: `msg_${number}_${role}`, role },
    parts: [{ id: `prt_${number}_${role}`, type: "text", text: `${number} ${role}` }],
  });
  const pair = (number) => [message(number, "user"), message(number, "assistant")];
  let all = [1, 2, 3, 4, 5, 6].flatMap(pair);
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=50": () => response(all),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=4": () => response([5, 6].flatMap(pair), {
      headers: { "x-next-cursor": "opaque-before-5" },
    }),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=50&before=opaque-before-5": () => response([1, 2, 3, 4].flatMap(pair)),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=4&before=opaque-before-5": () => response([3, 4].flatMap(pair), {
      headers: { "x-next-cursor": "opaque-before-3" },
    }),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=50&before=opaque-before-3": () => response([1, 2].flatMap(pair)),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const readPage = (cursor) => runtime.handleRequest({ method: "thread/turns/list", params: {
    threadId: "opencode:ses_test", sortDirection: "desc", limit: 2, ...(cursor ? { cursor } : {}),
  } });
  const first = await readPage();
  all = [1, 2, 3, 4, 5, 6, 7].flatMap(pair);
  const second = await readPage(first.nextCursor);
  const third = await readPage(second.nextCursor);
  assert.deepEqual([first, second, third].map((page) => page.data.map((turn) => turn.id)), [
    ["opencode-turn:msg_6_user", "opencode-turn:msg_5_user"],
    ["opencode-turn:msg_4_user", "opencode-turn:msg_3_user"],
    ["opencode-turn:msg_2_user", "opencode-turn:msg_1_user"],
  ]);
  assert.equal(third.nextCursor, null);
  assert.equal(server.calls.filter((call) => call.key === "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=50").length, 1);
  assert.ok(server.calls.some((call) => call.key.endsWith("&before=opaque-before-5")));
  assert.ok(server.calls.some((call) => call.key.endsWith("&before=opaque-before-3")));
});

test("a rejected native message cursor falls back to the durable turn anchor", async (t) => {
  const message = (number, role) => ({
    info: { id: `msg_${number}_${role}`, role },
    parts: [{ id: `prt_${number}_${role}`, type: "text", text: `${number} ${role}` }],
  });
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=50&before=stale": () => response({ error: "bad cursor" }, { status: 400 }),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=50": () => response([1, 2, 3, 4]
      .flatMap((number) => [message(number, "user"), message(number, "assistant")])),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const page = await runtime.handleRequest({ method: "thread/turns/list", params: {
    threadId: "opencode:ses_test", sortDirection: "desc", limit: 2,
    cursor: "opencode-turn-cursor:desc:opencode-turn%3Amsg_3_user:stale",
  } });
  assert.deepEqual(page.data.map((turn) => turn.id), ["opencode-turn:msg_2_user", "opencode-turn:msg_1_user"]);
  assert.equal(page.nextCursor, null);
});

test("lists project-scoped active and archived roots separately, while full safety listing includes children", async (t) => {
  const server = createMockServer({
    "GET /project": () => response([{ worktree: "/a" }, { worktree: "/b" }]),
    "GET /session?scope=project&directory=%2Fa&limit=1000000": () => response([
      { ...createMockServer().session, id: "ses_old", directory: "/a/sub", time: { created: 1, updated: 2 } },
      { ...createMockServer().session, id: "ses_child", parentID: "ses_old", directory: "/a", time: { created: 1, updated: 5 } },
    ]),
    "GET /session?scope=project&directory=%2Fb&limit=1000000": () => response([
      { ...createMockServer().session, id: "ses_new", directory: "/b", time: { created: 2, updated: 9 } },
      { ...createMockServer().session, id: "ses_archived", directory: "/b", time: { created: 1, updated: 8, archived: 8 } },
    ]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const threads = await runtime.listThreads();
  assert.deepEqual(threads.map((thread) => thread.id), ["opencode:ses_new", "opencode:ses_old"]);
  const archived = await runtime.listThreads({ archived: true });
  assert.deepEqual(archived.map((thread) => thread.id), ["opencode:ses_archived"]);
  assert.equal(archived[0].runtimeProvider, "opencode");
  assert.equal(archived[0].syncState, "archivedLocal");
  const allSessions = await runtime.listAllSessions();
  assert.deepEqual(allSessions.map((session) => session.id), ["ses_new", "ses_archived", "ses_child", "ses_old"]);
  assert.equal(allSessions.find((session) => session.id === "ses_child").directory, "/a");
  assert.ok(server.calls.some((call) => call.key.includes("scope=project")));
  assert.ok(server.calls.every((call) => !call.key.startsWith("GET /session?") || call.key.includes("limit=1000000")));
});

test("creates a model-pinned session and prompts with the pinned session model", async (t) => {
  const server = createMockServer({
    "POST /session?directory=%2Frepo%2Fapp": ({ options }) => {
      const body = JSON.parse(options.body);
      return response({ ...createMockServer().session, model: body.model, metadata: body.metadata });
    },
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": () => response(null, { status: 204 }),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const created = await runtime.handleRequest({ method: "thread/start", params: {
    runtimeProvider: "opencode", model: "opencode-go/fast", cwd: "/repo/app",
  } });
  assert.equal(created.thread.model, "opencode-go/fast");
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: created.thread.id,
    model: "codex-model-that-must-be-ignored",
    input: [{ type: "text", text: "Hello" }],
  } });
  const createCall = server.calls.find((call) => call.key.startsWith("POST /session?"));
  assert.deepEqual(createCall.body.model, { id: "fast", providerID: "opencode-go" });
  const promptCall = server.calls.find((call) => call.key.includes("prompt_async"));
  assert.deepEqual(promptCall.body.model, { providerID: "opencode-go", modelID: "fast" });
  assert.deepEqual(promptCall.body.parts, [{ type: "text", text: "Hello" }]);
});

test("forwards a selected model variant on creation and each turn without changing the pinned model", async (t) => {
  const server = createMockServer({
    "GET /provider": () => response({ all: [{ id: "opencode", models: {
      custom: { name: "Custom", variants: {
        fast: { reasoningEffort: "low" }, deep: { reasoningEffort: "high" },
      } },
    } }] }),
    "POST /session?directory=%2Frepo%2Fapp": ({ options }) => {
      const body = JSON.parse(options.body);
      return response({ ...createMockServer().session, model: body.model, metadata: body.metadata });
    },
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": () => response(null, { status: 204 }),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const created = await runtime.handleRequest({ method: "thread/start", params: {
    runtimeProvider: "opencode", model: "opencode/custom", effort: "fast", cwd: "/repo/app",
  } });
  assert.equal(created.thread.reasoningEffort, "fast");
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: created.thread.id, model: "opencode/other", effort: "deep", input: [{ text: "Hello" }],
  } });
  const createCall = server.calls.find((call) => call.key.startsWith("POST /session?"));
  assert.deepEqual(createCall.body.model, { id: "custom", providerID: "opencode", variant: "fast" });
  const promptCall = server.calls.find((call) => call.key.includes("prompt_async"));
  assert.deepEqual(promptCall.body.model, { providerID: "opencode", modelID: "custom" });
  assert.equal(promptCall.body.variant, "deep");
  await assert.rejects(runtime.handleRequest({ method: "turn/start", params: {
    threadId: created.thread.id, effort: "unknown", input: [{ text: "No" }],
  } }), /variant unknown is unavailable/);
  assert.equal(server.calls.filter((call) => call.key.includes("prompt_async")).length, 1);
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: created.thread.id, input: [{ text: "Continue without an effort field" }],
  } });
  const inheritedPrompt = server.calls.filter((call) => call.key.includes("prompt_async"))[1];
  assert.equal(inheritedPrompt.body.variant, "deep");
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: created.thread.id, effort: null, input: [{ text: "Use provider default" }],
  } });
  const defaultPrompt = server.calls.filter((call) => call.key.includes("prompt_async"))[2];
  assert.equal(Object.hasOwn(defaultPrompt.body, "variant"), false);
});

test("accepted variants stay coherent until OpenCode's session snapshot catches up", async (t) => {
  let session = createMockServer().session;
  let nextServerVariant = null;
  const server = createMockServer({
    "GET /provider": () => response({ all: [{ id: "opencode", models: {
      custom: { name: "Custom", variants: { low: {}, medium: {}, high: {} } },
    } }] }),
    "POST /session?directory=%2Frepo%2Fapp": ({ options }) => {
      const body = JSON.parse(options.body);
      session = { ...session, model: body.model, metadata: body.metadata };
      return response(session);
    },
    "GET /session/ses_test": () => {
      // prompt_async can acknowledge before the durable session update lands.
      const snapshot = session;
      if (nextServerVariant !== null) {
        session = { ...session, model: { ...session.model, variant: nextServerVariant } };
        nextServerVariant = null;
      }
      return response(snapshot);
    },
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": ({ options }) => {
      const body = JSON.parse(options.body);
      nextServerVariant = body.variant || "default";
      return response(null, { status: 204 });
    },
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const { thread } = await runtime.handleRequest({ method: "thread/start", params: {
    runtimeProvider: "opencode", model: "opencode/custom", effort: "low", cwd: "/repo/app",
  } });
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: thread.id, effort: "high", input: [{ text: "Choose high" }],
  } });
  const earlyRead = await runtime.handleRequest({ method: "thread/read", params: {
    threadId: thread.id, includeTurns: false,
  } });
  assert.equal(earlyRead.thread.reasoningEffort, "high");
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: thread.id, input: [{ text: "Keep high" }],
  } });
  const prompts = server.calls.filter((call) => call.key.includes("prompt_async"));
  assert.equal(prompts[1].body.variant, "high");
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: thread.id, effort: null, input: [{ text: "Use default" }],
  } });
  const defaultPrompt = server.calls.filter((call) => call.key.includes("prompt_async"))[2];
  assert.equal(Object.hasOwn(defaultPrompt.body, "variant"), false);
  const defaultRead = await runtime.handleRequest({ method: "thread/read", params: {
    threadId: thread.id, includeTurns: false,
  } });
  assert.equal(defaultRead.thread.reasoningEffort, undefined);
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: thread.id, input: [{ text: "Keep default" }],
  } });
  const inheritedDefault = server.calls.filter((call) => call.key.includes("prompt_async"))[3];
  assert.equal(Object.hasOwn(inheritedDefault.body, "variant"), false);
});

test("a server-side variant change wins once the brief prompt acknowledgement window ends", async (t) => {
  let session = { ...createMockServer().session,
    model: { providerID: "opencode", id: "custom", variant: "low" } };
  const server = createMockServer({
    "GET /provider": () => response({ all: [{ id: "opencode", models: {
      custom: { name: "Custom", variants: { low: {}, medium: {}, high: {} } },
    } }] }),
    "GET /session/ses_test": () => response(session),
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": () => response(null, { status: 204 }),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    reconnectDelayMs: 60_000, variantCatchupMs: 0 });
  t.after(() => runtime.shutdown());
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: "opencode:ses_test", effort: "high", input: [{ text: "Choose high" }],
  } });
  session = { ...session, model: { ...session.model, variant: "medium" } };
  const read = await runtime.handleRequest({ method: "thread/read", params: {
    threadId: "opencode:ses_test", includeTurns: false,
  } });
  assert.equal(read.thread.reasoningEffort, "medium");
});

test("forwards iPhone image attachments as OpenCode file parts", async (t) => {
  const server = createMockServer({
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": () => response(null, { status: 204 }),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  await runtime.handleRequest({ method: "turn/start", params: {
    threadId: "opencode:ses_test",
    input: [
      { type: "image", url: "data:image/png;base64,cG5n" },
      { type: "text", text: "Describe this" },
    ],
  } });
  const promptCall = server.calls.find((call) => call.key.includes("prompt_async"));
  assert.deepEqual(promptCall.body.parts, [
    { type: "file", mime: "image/png", url: "data:image/png;base64,cG5n" },
    { type: "text", text: "Describe this" },
  ]);
});

test("a quick OpenCode turn cannot restart after finishing before prompt acknowledgement", async (t) => {
  let runtime;
  const server = createMockServer({
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": ({ options }) => {
      const messageID = JSON.parse(options.body).messageID;
      runtime.processEvent({ payload: { type: "message.updated", properties: {
        info: { id: messageID, sessionID: "ses_test", role: "user" },
      } } });
      runtime.processEvent({ payload: { type: "session.status", properties: {
        sessionID: "ses_test", status: { type: "idle" },
      } } });
      runtime.processEvent({ payload: { type: "message.updated", properties: {
        info: { id: messageID, sessionID: "ses_test", role: "user" },
      } } });
      return response(null, { status: 204 });
    },
  });
  const outbound = [];
  runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const result = await runtime.handleRequest({ method: "turn/start", params: {
    threadId: "opencode:ses_test", input: [{ type: "text", text: "Hello" }],
  } });
  assert.equal(result.turn.status, "completed");
  assert.deepEqual(outbound.filter((message) => message.method.startsWith("turn/")).map((message) => message.method),
    ["turn/started", "turn/completed"]);
});

test("OpenCode provider failures settle the turn with a readable error", () => {
  const outbound = [];
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: async () => response({}),
    onNotification: (message) => outbound.push(message) });
  runtime.processEvent({ payload: { type: "message.updated", properties: {
    info: { id: "msg_failed", sessionID: "ses_test", role: "user" },
  } } });
  runtime.processEvent({ payload: { type: "session.error", properties: {
    sessionID: "ses_test", error: { name: "ProviderAuthError", data: { message: "Sign in to OpenCode Zen" } },
  } } });
  runtime.processEvent({ payload: { type: "session.status", properties: {
    sessionID: "ses_test", status: { type: "idle" },
  } } });
  const completion = outbound.filter((message) => message.method === "turn/completed");
  assert.equal(completion.length, 1);
  assert.equal(completion[0].params.turn.status, "failed");
  assert.equal(completion[0].params.turn.error.message, "Sign in to OpenCode Zen");
});

test("routes permission and structured-question replies by exact OpenCode request id", async (t) => {
  const server = createMockServer({
    "POST /permission/per_1/reply": () => response(true),
    "POST /question/que_1/reply": () => response(true),
  });
  const outbound = [];
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, onNotification: (message) => outbound.push(message), reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  await runtime.ensureStarted();
  runtime.processEvent({ payload: { type: "permission.asked", properties: {
    id: "per_1", sessionID: "ses_test", permission: "bash", patterns: ["git status"],
  } } });
  runtime.processEvent({ payload: { type: "question.asked", properties: {
    id: "que_1", sessionID: "ses_test", questions: [
      { id: "q1", header: "One", question: "First?", options: [] },
      { id: "q2", header: "Two", question: "Second?", options: [] },
    ],
  } } });
  const permission = outbound.find((message) => message.method === "item/commandExecution/requestApproval");
  const question = outbound.find((message) => message.method === "item/tool/requestUserInput");
  assert.ok(permission.id.startsWith("opencode-"));
  assert.ok(question.id.startsWith("opencode-"));
  await runtime.handleClientResponse({ id: permission.id, result: { decision: "acceptForSession" } });
  await runtime.handleClientResponse({ id: question.id, result: { answers: {
    q2: { answers: ["B"] }, q1: { answers: ["A"] },
  } } });
  assert.equal(server.calls.find((call) => call.key.includes("/permission/")).body.reply, "always");
  assert.deepEqual(server.calls.find((call) => call.key.includes("/question/")).body.answers, [["A"], ["B"]]);
});

test("updated OpenCode prompts keep one request id and remote replies dismiss the card", async (t) => {
  const outbound = [];
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: createMockServer().fetch,
    onNotification: (message) => outbound.push(message), reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  const properties = { id: "que_1", sessionID: "ses_test", questions: [
    { id: "q1", header: "Name", question: "What name?", options: [] },
  ] };
  runtime.processEvent({ payload: { type: "question.asked", properties } });
  runtime.processEvent({ payload: { type: "question.updated", properties } });
  const prompts = outbound.filter((message) => message.method === "item/tool/requestUserInput");
  assert.equal(prompts.length, 2);
  assert.equal(prompts[0].id, prompts[1].id);
  runtime.processEvent({ payload: { type: "question.replied", properties } });
  assert.equal(outbound.at(-1).method, "serverRequest/resolved");
  assert.equal(outbound.at(-1).params.requestId, prompts[0].id);
  assert.equal(runtime.ownsClientResponse({ id: prompts[0].id }), false);
});

test("failed OpenCode approval reply keeps its request retryable", async (t) => {
  const server = createMockServer({
    "POST /permission/per_1/reply": () => response({ error: "temporary" }, { status: 503 }),
  });
  const outbound = [];
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  runtime.processEvent({ payload: { type: "permission.asked", properties: {
    id: "per_1", sessionID: "ses_test", permission: "bash", patterns: ["git status"],
  } } });
  const approval = outbound.find((message) => message.method === "item/commandExecution/requestApproval");
  await assert.rejects(runtime.handleClientResponse({ id: approval.id, result: { decision: "decline" } }), /503/);
  assert.equal(runtime.ownsClientResponse({ id: approval.id }), true);
});

test("archives and restores a session with OpenCode's numeric archived field", async (t) => {
  const server = createMockServer({
    "PATCH /session/ses_test?directory=%2Frepo%2Fapp": ({ options }) => response({
      ...createMockServer().session,
      time: { created: 10, updated: 20, archived: JSON.parse(options.body).time.archived },
    }),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  await runtime.handleRequest({ method: "thread/archive", params: { threadId: "opencode:ses_test" } });
  await runtime.handleRequest({ method: "thread/unarchive", params: { threadId: "opencode:ses_test" } });
  const updates = server.calls.filter((call) => call.key.startsWith("PATCH /session/"));
  assert.ok(updates[0].body.time.archived > 0);
  assert.equal(updates[1].body.time.archived, 0);
});

test("derives and reuses the latest model for a session created on the Mac", async (t) => {
  const macSession = { ...createMockServer().session };
  delete macSession.model;
  const server = createMockServer({
    "GET /session?scope=project&directory=%2Frepo&limit=1000000": () => response([macSession]),
    "GET /session/ses_test?directory=%2Frepo%2Fapp": () => response(macSession),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp": () => response([
      { info: { id: "msg_user", role: "user", model: { providerID: "opencode-go", modelID: "mac-fast" } }, parts: [] },
      { info: { id: "msg_assistant", role: "assistant", providerID: "opencode-go", modelID: "mac-fast" }, parts: [] },
    ]),
    "POST /session/ses_test/prompt_async?directory=%2Frepo%2Fapp": () => response(null, { status: 204 }),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const resumed = await runtime.handleRequest({ method: "thread/resume", params: { threadId: "opencode:ses_test" } });
  assert.equal(resumed.thread.model, "opencode-go/mac-fast");
  await runtime.handleRequest({ method: "turn/start", params: { threadId: "opencode:ses_test", input: [{ text: "Continue" }] } });
  const promptCall = server.calls.find((call) => call.key.includes("prompt_async"));
  assert.deepEqual(promptCall.body.model, { providerID: "opencode-go", modelID: "mac-fast" });
});

test("parses CRLF global SSE frames and keeps user parts user-scoped", async (t) => {
  const outbound = [];
  let eventReads = 0;
  const server = createMockServer({
    "GET /global/event": () => {
      eventReads += 1;
      const payload = [
        { payload: { type: "message.updated", properties: { sessionID: "ses_test", info: { id: "msg_mac", role: "user" } } } },
        { payload: { type: "message.part.updated", properties: { sessionID: "ses_test", part: { id: "prt_mac", sessionID: "ses_test", messageID: "msg_mac", type: "text", text: "From Mac" } } } },
      ].map((event) => `data: ${JSON.stringify(event)}\r\n\r\n`).join("");
      return new Response(new ReadableStream({ start(controller) {
        controller.enqueue(new TextEncoder().encode(payload));
        controller.close();
      } }), { headers: { "content-type": "text/event-stream" } });
    },
  });
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  await runtime.ensureStarted();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(eventReads, 1);
  const item = outbound.find((message) => message.method === "item/started")?.params?.item;
  assert.equal(item.role, "user");
  assert.equal(item.content[0].text, "From Mac");
});

test("a part arriving after joining a terminal turn resolves its role and durable parent turn", async (t) => {
  const outbound = [];
  const server = createMockServer({
    "GET /session/ses_test/message/msg_assistant": () => response({
      info: { id: "msg_assistant", role: "assistant", parentID: "msg_user" }, parts: [],
    }),
  });
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  runtime.processEvent({ type: "message.part.updated", properties: { part: {
    id: "prt_assistant", sessionID: "ses_test", messageID: "msg_assistant", type: "text", text: "From terminal",
  } } });
  assert.equal(outbound.length, 0);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(outbound.find((event) => event.method === "turn/started")?.params.turnId, "opencode-turn:msg_user");
  const item = outbound.find((event) => event.method === "item/started");
  assert.equal(item?.params.turnId, "opencode-turn:msg_user");
  assert.equal(item?.params.item.type, "agentMessage");
  assert.equal(outbound.some((event) => event.params?.turnId === "opencode-turn:msg_assistant"), false);
});

test("an unknown terminal user part never becomes an assistant row", async (t) => {
  const outbound = [];
  const server = createMockServer({
    "GET /session/ses_test/message/msg_user": () => response({
      info: { id: "msg_user", role: "user" }, parts: [],
    }),
  });
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), reconnectDelayMs: 60_000,
  });
  t.after(() => runtime.shutdown());
  runtime.processEvent({ type: "message.part.updated", properties: { part: {
    id: "prt_user", sessionID: "ses_test", messageID: "msg_user", type: "text", text: "From terminal",
  } } });
  await new Promise((resolve) => setImmediate(resolve));
  const item = outbound.find((event) => event.method === "item/started");
  assert.equal(item?.params.item.role, "user");
  assert.equal(item?.params.turnId, "opencode-turn:msg_user");
});

test("completed turn state retains late reasoning deltas briefly then evicts its maps", async (t) => {
  const outbound = [];
  const server = createMockServer({
    "GET /session/ses_test/message/msg_assistant": () => response({
      info: { id: "msg_assistant", role: "assistant", parentID: "msg_user" }, parts: [],
    }),
  });
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (message) => outbound.push(message), reconnectDelayMs: 60_000,
    completedTurnStateGraceMs: 10,
  });
  t.after(() => runtime.shutdown());
  runtime.processEvent({ type: "message.updated", properties: {
    sessionID: "ses_test", info: { id: "msg_user", role: "user" },
  } });
  runtime.processEvent({ type: "message.updated", properties: {
    sessionID: "ses_test", info: { id: "msg_assistant", role: "assistant", parentID: "msg_user" },
  } });
  const reasoning = (text) => runtime.processEvent({ type: "message.part.updated", properties: { part: {
    id: "prt_reasoning", sessionID: "ses_test", messageID: "msg_assistant", type: "reasoning", text,
  } } });
  reasoning("Think");
  runtime.processEvent({ type: "session.status", properties: { sessionID: "ses_test", status: { type: "idle" } } });
  reasoning("Thinking more");
  assert.deepEqual(outbound.filter((event) => event.method === "item/reasoning/textDelta")
    .map((event) => event.params.delta), ["ing more"]);
  await new Promise((resolve) => setTimeout(resolve, 25));
  const count = outbound.length;
  reasoning("Thinking more still");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(outbound.length, count);
  assert.equal(server.calls.filter((call) => call.key === "GET /session/ses_test/message/msg_assistant").length, 1);
  reasoning("Thinking more still later");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(server.calls.filter((call) => call.key === "GET /session/ses_test/message/msg_assistant").length, 2);
});

test("request ownership only claims OpenCode starts and namespaced thread methods", () => {
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: async () => response({}) });
  assert.equal(runtime.shouldHandleRequest({ method: "thread/start", params: { runtimeProvider: "opencode" } }), true);
  assert.equal(runtime.shouldHandleRequest({ method: "thread/start", params: { runtimeProvider: "codex" } }), false);
  assert.equal(runtime.shouldHandleRequest({ method: "turn/start", params: { threadId: "opencode:ses_x" } }), true);
  assert.equal(runtime.shouldHandleRequest({ method: "turn/start", params: { threadId: "codex-x" } }), false);
  assert.equal(runtime.shouldHandleRequest({ method: "thread/delete", params: { threadId: "opencode:ses_x" } }), true);
});

test("released text and reasoning deltas stream immediately without duplicating final snapshots", async (t) => {
  const outbound = [];
  const runtime = createOpenCodeRuntime({ onNotification: (event) => outbound.push(event) });
  t.after(() => runtime.shutdown());
  runtime.processEvent({ type: "message.updated", properties: { sessionID: "ses_test", info: {
    id: "msg_assistant", parentID: "msg_user", role: "assistant",
  } } });
  for (const type of ["text", "reasoning"]) {
    const part = { id: `prt_${type}`, messageID: "msg_assistant", sessionID: "ses_test", type, text: "" };
    runtime.processEvent({ type: "message.part.updated", properties: { part } });
    for (const delta of ["Hello", " world"]) {
      runtime.processEvent({ type: "message.part.delta", properties: {
        sessionID: part.sessionID, messageID: part.messageID, partID: part.id, field: "text", delta,
      } });
    }
    const method = type === "text" ? "item/agentMessage/delta" : "item/reasoning/textDelta";
    assert.deepEqual(outbound.filter((event) => event.method === method).map((event) => event.params.delta), ["Hello", " world"]);
    runtime.processEvent({ type: "message.part.updated", properties: { part: { ...part, text: "Hello world", time: { end: 123 } } } });
    assert.equal(outbound.filter((event) => event.method === method).length, 2);
    assert.equal(outbound.filter((event) => event.method === "item/completed" && event.params.item.id === part.id).length, 1);
  }
  runtime.processEvent({ type: "session.status", properties: { sessionID: "ses_test", status: { type: "idle" } } });
  runtime.processEvent({ type: "message.part.delta", properties: {
    sessionID: "ses_test", messageID: "msg_assistant", partID: "prt_reasoning", field: "text", delta: "!",
  } });
  assert.equal(outbound.at(-1).params.delta, "!");
  assert.equal(outbound.filter((event) => event.method === "turn/started").length, 1);
});

test("deltas received before message identity resolves preserve the complete part", async (t) => {
  let resolveMessage;
  const outbound = [];
  const server = createMockServer({
    "GET /session/ses_test/message/msg_assistant": () => new Promise((resolve) => { resolveMessage = resolve; }),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    onNotification: (event) => outbound.push(event) });
  t.after(() => runtime.shutdown());
  runtime.processEvent({ type: "message.part.updated", properties: { part: {
    id: "prt_text", sessionID: "ses_test", messageID: "msg_assistant", type: "text", text: "Hello",
  } } });
  runtime.processEvent({ type: "message.part.delta", properties: {
    sessionID: "ses_test", messageID: "msg_assistant", partID: "prt_text", field: "text", delta: " world",
  } });
  assert.equal(outbound.length, 0);
  resolveMessage(response({ info: { id: "msg_assistant", parentID: "msg_user", role: "assistant" } }));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(outbound.find((event) => event.method === "item/started").params.item.text, "Hello world");
});

test("a failed owned server startup retries with a new process and port", async (t) => {
  const children = [];
  const server = createMockServer();
  const runtime = createOpenCodeRuntime({
    opencodeBin: process.execPath, findPort: async () => 7777 + children.length, startupTimeoutMs: 10,
    reconnectDelayMs: 60_000,
    spawnImpl: () => {
      const child = { exitCode: null, killed: false, kill() { this.killed = true; } };
      children.push(child);
      return child;
    },
    fetchImpl: (url, options) => {
      if (children.length === 1) throw new Error("startup failed");
      return server.fetch(url, options);
    },
  });
  t.after(() => runtime.shutdown());
  await assert.rejects(runtime.ensureStarted(), /did not become ready/);
  assert.equal(children[0].killed, true);
  assert.deepEqual(await runtime.ensureStarted(), { baseUrl: "http://127.0.0.1:7778" });
  assert.equal(children.length, 2);
  assert.equal(children[1].killed, false);
});

test("an owned OpenCode server exit fails its turn and the next request respawns it", async (t) => {
  const children = [];
  const outbound = [];
  const server = createMockServer();
  const runtime = createOpenCodeRuntime({
    opencodeBin: process.execPath, findPort: async () => 7777 + children.length,
    fetchImpl: server.fetch, reconnectDelayMs: 60_000,
    onNotification: (message) => outbound.push(message),
    spawnImpl: () => {
      const child = new EventEmitter();
      child.exitCode = null;
      child.kill = () => {};
      children.push(child);
      return child;
    },
  });
  t.after(() => runtime.shutdown());
  await runtime.ensureStarted();
  runtime.processEvent({ type: "message.updated", properties: {
    sessionID: "ses_test", info: { id: "msg_user", role: "user" },
  } });
  children[0].exitCode = 1;
  children[0].emit("exit", 1, null);
  assert.equal(outbound.at(-1).method, "turn/completed");
  assert.equal(outbound.at(-1).params.turn.status, "failed");
  assert.deepEqual(await runtime.ensureStarted(), { baseUrl: "http://127.0.0.1:7778" });
  assert.equal(children.length, 2);
});

test("retrying a configured OpenCode endpoint never starts an owned server", async (t) => {
  let healthy = false;
  const server = createMockServer();
  const runtime = createOpenCodeRuntime({
    baseUrl: "http://127.0.0.1:8888", startupTimeoutMs: 10, reconnectDelayMs: 60_000,
    spawnImpl: () => assert.fail("must not spawn for a configured endpoint"),
    fetchImpl: (url, options) => {
      if (!healthy) throw new Error("temporarily unavailable");
      return server.fetch(url, options);
    },
  });
  t.after(() => runtime.shutdown());
  await assert.rejects(runtime.ensureStarted(), /did not become ready/);
  healthy = true;
  assert.deepEqual(await runtime.ensureStarted(), { baseUrl: "http://127.0.0.1:8888" });
});

async function waitUntil(predicate) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail("expected runtime state was not reached");
}

test("SSE reconnect recovers a missed idle event using each session's directory", async (t) => {
  const controllers = [];
  const outbound = [];
  const server = createMockServer({
    "GET /global/event": ({ options }) => new Response(new ReadableStream({ start(controller) {
      controllers.push(controller);
      options.signal.addEventListener("abort", () => { try { controller.close(); } catch {} }, { once: true });
    } })),
    "GET /session/status?directory=%2Fa": () => response({}),
    "GET /session/status?directory=%2Fb": () => response({ ses_b: { type: "busy" } }),
    "GET /session/ses_b/message?directory=%2Fb&limit=1": () => response([
      { info: { id: "msg_b", role: "user" } },
    ]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    reconnectDelayMs: 1, onNotification: (event) => outbound.push(event) });
  t.after(() => runtime.shutdown());
  await runtime.ensureStarted();
  for (const id of ["a", "b"]) {
    runtime.processEvent({ type: "session.created", properties: { info: { id: `ses_${id}`, directory: `/${id}` } } });
    runtime.processEvent({ type: "message.updated", properties: { sessionID: `ses_${id}`, info: { id: `msg_${id}`, role: "user" } } });
  }
  controllers[0].close();
  await waitUntil(() => outbound.some((event) => event.method === "turn/completed"));
  assert.equal(controllers.length, 2);
  assert.deepEqual(outbound.filter((event) => event.method === "turn/completed").map((event) => event.params.threadId), ["opencode:ses_a"]);
  assert.ok(server.calls.some((call) => call.key === "GET /session/status?directory=%2Fb"));
});

test("a stale idle status snapshot cannot complete a newer live turn", async (t) => {
  let releaseStatus;
  const outbound = [];
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
    "GET /session/status?directory=%2Frepo%2Fapp": () => new Promise((resolve) => { releaseStatus = resolve; }),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp": () => response([{ info: { id: "msg_new", role: "user" }, parts: [] }]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    reconnectDelayMs: 60_000, onNotification: (event) => outbound.push(event) });
  t.after(() => runtime.shutdown());
  const read = runtime.handleRequest({ method: "thread/read", params: { threadId: "opencode:ses_test", includeTurns: true } });
  await waitUntil(() => releaseStatus);
  runtime.processEvent({ type: "message.updated", properties: { sessionID: "ses_test", info: { id: "msg_new", role: "user" } } });
  releaseStatus(response({}));
  assert.equal((await read).thread.turns.at(-1).status, "inProgress");
  assert.equal(outbound.some((event) => event.method === "turn/completed"), false);
});

test("reading history recovers the current busy turn after missing its user event", async (t) => {
  const outbound = [];
  const latest = { info: { id: "msg_assistant", parentID: "msg_new", role: "assistant" }, parts: [] };
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
    "GET /session/status?directory=%2Frepo%2Fapp": () => response({ ses_test: { type: "busy" } }),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=1": () => response([latest]),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp": () => response([
      { info: { id: "msg_new", role: "user" }, parts: [] }, latest,
    ]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    reconnectDelayMs: 60_000, onNotification: (event) => outbound.push(event) });
  t.after(() => runtime.shutdown());
  await runtime.ensureStarted();
  runtime.processEvent({ type: "message.updated", properties: { sessionID: "ses_test", info: { id: "msg_old", role: "user" } } });
  const read = await runtime.handleRequest({ method: "thread/read", params: { threadId: "opencode:ses_test", includeTurns: true } });
  assert.equal(read.thread.turns.at(-1).status, "inProgress");
  assert.deepEqual(outbound.filter((event) => event.method === "turn/started").map((event) => event.params.turnId), ["opencode-turn:msg_old", "opencode-turn:msg_new"]);
  runtime.processEvent({ type: "message.part.updated", properties: { part: {
    id: "prt_new", sessionID: "ses_test", messageID: "msg_assistant", type: "text", text: "Continued",
  } } });
  assert.equal(outbound.at(-1).params.turnId, "opencode-turn:msg_new");
});

test("a failed status read is not evidence that a running turn finished", async (t) => {
  const outbound = [];
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
    "GET /session/status?directory=%2Frepo%2Fapp": () => response({}, { status: 503 }),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp": () => response([{ info: { id: "msg_user", role: "user" }, parts: [] }]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch,
    reconnectDelayMs: 60_000, onNotification: (event) => outbound.push(event) });
  t.after(() => runtime.shutdown());
  await runtime.ensureStarted();
  runtime.processEvent({ type: "message.updated", properties: { sessionID: "ses_test", info: { id: "msg_user", role: "user" } } });
  const read = await runtime.handleRequest({ method: "thread/read", params: { threadId: "opencode:ses_test", includeTurns: true } });
  assert.equal(read.thread.turns.at(-1).status, "inProgress");
  assert.equal(outbound.some((event) => event.method === "turn/completed"), false);
});

test("an older busy snapshot cannot overwrite a newer idle history read", async (t) => {
  let releaseFirst;
  let statusReads = 0;
  const server = createMockServer({
    "GET /session/ses_test": () => response(createMockServer().session),
    "GET /session/status?directory=%2Frepo%2Fapp": () => {
      if (++statusReads === 1) return new Promise((resolve) => { releaseFirst = resolve; });
      return response({});
    },
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp&limit=1": () => response([
      { info: { id: "msg_user", role: "user" } },
    ]),
    "GET /session/ses_test/message?directory=%2Frepo%2Fapp": () => response([
      { info: { id: "msg_user", role: "user" }, parts: [] },
    ]),
  });
  const runtime = createOpenCodeRuntime({ baseUrl: "http://127.0.0.1:7777", fetchImpl: server.fetch, reconnectDelayMs: 60_000 });
  t.after(() => runtime.shutdown());
  const read = () => runtime.handleRequest({ method: "thread/read", params: { threadId: "opencode:ses_test", includeTurns: true } });
  const first = read();
  await waitUntil(() => releaseFirst);
  assert.equal((await read()).thread.turns.at(-1).status, "completed");
  releaseFirst(response({ ses_test: { type: "busy" } }));
  assert.equal((await first).thread.turns.at(-1).status, "completed");
});
