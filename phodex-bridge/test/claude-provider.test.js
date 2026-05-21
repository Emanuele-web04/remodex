// FILE: claude-provider.test.js
// Purpose: Verifies Claude provider request handling without launching Claude Code.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, fs, os, path, ../src/claude-provider

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createClaudeProvider, permissionModeFromParams } = require("../src/claude-provider");
const { createClaudeThreadStore } = require("../src/claude-thread-store");

test("permissionModeFromParams maps Remodex access payloads to Claude modes", () => {
  assert.equal(permissionModeFromParams({ approvalPolicy: "never" }), "bypassPermissions");
  assert.equal(permissionModeFromParams({ sandbox: "danger-full-access" }), "bypassPermissions");
  assert.equal(permissionModeFromParams({ collaborationMode: { mode: "plan" } }), "plan");
  assert.equal(permissionModeFromParams({ approvalPolicy: "on-request" }), "default");
});

test("Claude provider starts a thread and records a turn from SDK stream messages", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-claude-provider-"));
  const sent = [];
  const store = createClaudeThreadStore({
    stateDir: tempDir,
    now: fixedClock([
      "2026-01-01T00:00:00.000Z",
      "2026-01-01T00:00:01.000Z",
      "2026-01-01T00:00:02.000Z",
      "2026-01-01T00:00:03.000Z",
      "2026-01-01T00:00:04.000Z",
    ]),
  });
  const provider = createClaudeProvider({
    store,
    sendApplicationMessage(message) {
      sent.push(JSON.parse(message));
    },
    executableResolver: () => ({ available: true, path: "/usr/local/bin/claude", reason: "" }),
    sdkLoader: () => ({
      query() {
        return makeQuery([
          {
            type: "system",
            subtype: "init",
            session_id: "session-1",
          },
          {
            type: "stream_event",
            event: {
              type: "content_block_delta",
              delta: { type: "text_delta", text: "hello" },
            },
          },
          {
            type: "result",
            subtype: "success",
            is_error: false,
            session_id: "session-1",
          },
        ]);
      },
    }),
  });

  const startResult = await provider.handleRequest({
    method: "thread/start",
    params: {
      model: "claude-opus-4-7",
      cwd: tempDir,
    },
  });
  const turnResult = await provider.handleRequest({
    method: "turn/start",
    params: {
      threadId: startResult.thread.id,
      model: "claude-opus-4-7",
      input: [{ type: "text", text: "Say hello" }],
    },
  });

  await waitFor(() => sent.some((message) => message.method === "turn/completed"));

  assert.equal(turnResult.turn.status, "running");
  assert.equal(sent.some((message) => message.method === "item/agentMessage/delta"), true);

  const readResult = store.readThread(startResult.thread.id);
  assert.equal(readResult.thread.turns[0].items[0].text, "Say hello");
  assert.equal(readResult.thread.turns[0].items[1].text, "hello");
  assert.equal(readResult.thread.turns[0].status, "completed");
});

test("Claude provider skips consolidated thinking after streamed thinking deltas", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-claude-thinking-"));
  const sent = [];
  const store = createClaudeThreadStore({ stateDir: tempDir });
  const provider = createClaudeProvider({
    store,
    sendApplicationMessage(message) {
      sent.push(JSON.parse(message));
    },
    executableResolver: () => ({ available: true, path: "/usr/local/bin/claude", reason: "" }),
    sdkLoader: () => ({
      query() {
        return makeQuery([
          {
            type: "stream_event",
            event: {
              type: "content_block_delta",
              index: 0,
              delta: { type: "thinking_delta", thinking: "think" },
            },
          },
          {
            type: "assistant",
            message: {
              content: [
                { type: "thinking", thinking: "think" },
              ],
            },
          },
          {
            type: "result",
            subtype: "success",
            is_error: false,
          },
        ]);
      },
    }),
  });

  const startResult = await provider.handleRequest({ method: "thread/start", params: { cwd: tempDir } });
  await provider.handleRequest({
    method: "turn/start",
    params: {
      threadId: startResult.thread.id,
      input: [{ type: "text", text: "Think once" }],
    },
  });
  await waitFor(() => sent.some((message) => message.method === "turn/completed"));

  const reasoningDeltas = sent.filter((message) => message.method === "item/reasoning/textDelta");
  assert.equal(reasoningDeltas.length, 1);
  const readResult = store.readThread(startResult.thread.id);
  assert.equal(readResult.thread.turns[0].items.find((item) => item.type === "reasoning").text, "think");
});

test("Claude provider attaches tool results to the originating tool item", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-claude-tool-result-"));
  const sent = [];
  const store = createClaudeThreadStore({ stateDir: tempDir });
  const provider = createClaudeProvider({
    store,
    sendApplicationMessage(message) {
      sent.push(JSON.parse(message));
    },
    executableResolver: () => ({ available: true, path: "/usr/local/bin/claude", reason: "" }),
    sdkLoader: () => ({
      query() {
        return makeQuery([
          {
            type: "assistant",
            message: {
              content: [
                { type: "tool_use", id: "tool-1", name: "Bash", input: { command: "npm test" } },
              ],
            },
          },
          {
            type: "user",
            message: {
              content: [
                { type: "tool_result", tool_use_id: "tool-1", content: "ok" },
              ],
            },
          },
          {
            type: "result",
            subtype: "success",
            is_error: false,
          },
        ]);
      },
    }),
  });

  const startResult = await provider.handleRequest({ method: "thread/start", params: { cwd: tempDir } });
  await provider.handleRequest({
    method: "turn/start",
    params: {
      threadId: startResult.thread.id,
      input: [{ type: "text", text: "Run tests" }],
    },
  });
  await waitFor(() => sent.some((message) => message.method === "turn/completed"));

  const commandDeltas = sent.filter((message) => message.method === "item/commandExecution/outputDelta");
  assert.equal(commandDeltas.length, 2);
  assert.equal(commandDeltas[0].params.itemId, commandDeltas[1].params.itemId);
  const readResult = store.readThread(startResult.thread.id);
  const commandItem = readResult.thread.turns[0].items.find((item) => item.type === "commandExecution");
  assert.equal(commandItem.text, "$ npm test\nok");
});

test("Claude provider keeps post-tool assistant text in a later item when stream indexes reset", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-claude-multistep-"));
  const sent = [];
  const store = createClaudeThreadStore({ stateDir: tempDir });
  const provider = createClaudeProvider({
    store,
    sendApplicationMessage(message) {
      sent.push(JSON.parse(message));
    },
    executableResolver: () => ({ available: true, path: "/usr/local/bin/claude", reason: "" }),
    sdkLoader: () => ({
      query() {
        return makeQuery([
          {
            type: "stream_event",
            event: { type: "message_start" },
          },
          {
            type: "stream_event",
            event: { type: "content_block_start", index: 0 },
          },
          {
            type: "stream_event",
            event: {
              type: "content_block_delta",
              index: 0,
              delta: { type: "text_delta", text: "before" },
            },
          },
          {
            type: "assistant",
            message: {
              content: [
                { type: "text", text: "before" },
                { type: "tool_use", id: "tool-1", name: "Bash", input: { command: "npm test" } },
              ],
            },
          },
          {
            type: "user",
            message: {
              content: [
                { type: "tool_result", tool_use_id: "tool-1", content: "ok" },
              ],
            },
          },
          {
            type: "stream_event",
            event: { type: "message_start" },
          },
          {
            type: "stream_event",
            event: { type: "content_block_start", index: 0 },
          },
          {
            type: "stream_event",
            event: {
              type: "content_block_delta",
              index: 0,
              delta: { type: "text_delta", text: "after" },
            },
          },
          {
            type: "assistant",
            message: {
              content: [
                { type: "text", text: "after" },
              ],
            },
          },
          {
            type: "result",
            subtype: "success",
            is_error: false,
          },
        ]);
      },
    }),
  });

  const startResult = await provider.handleRequest({ method: "thread/start", params: { cwd: tempDir } });
  await provider.handleRequest({
    method: "turn/start",
    params: {
      threadId: startResult.thread.id,
      input: [{ type: "text", text: "Run tests then summarize" }],
    },
  });
  await waitFor(() => sent.some((message) => message.method === "turn/completed"));

  const agentDeltas = sent.filter((message) => message.method === "item/agentMessage/delta");
  assert.equal(agentDeltas.length, 2);
  assert.notEqual(agentDeltas[0].params.itemId, agentDeltas[1].params.itemId);

  const readResult = store.readThread(startResult.thread.id);
  assert.deepEqual(readResult.thread.turns[0].items.map((item) => item.type), [
    "userMessage",
    "agentMessage",
    "commandExecution",
    "agentMessage",
  ]);
  assert.equal(readResult.thread.turns[0].items[1].text, "before");
  assert.equal(readResult.thread.turns[0].items[2].text, "$ npm test\nok");
  assert.equal(readResult.thread.turns[0].items[3].text, "after");
});

test("Claude provider emits one terminal event when an interrupted query rejects", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-claude-interrupt-"));
  const sent = [];
  let capturedAbortController;
  const provider = createClaudeProvider({
    store: createClaudeThreadStore({ stateDir: tempDir }),
    sendApplicationMessage(message) {
      sent.push(JSON.parse(message));
    },
    executableResolver: () => ({ available: true, path: "/usr/local/bin/claude", reason: "" }),
    sdkLoader: () => ({
      query({ options }) {
        capturedAbortController = options.abortController;
        return {
          async *[Symbol.asyncIterator]() {
            await new Promise((resolve) => {
              capturedAbortController.signal.addEventListener("abort", resolve, { once: true });
            });
            throw new Error("aborted");
          },
          async interrupt() {},
        };
      },
    }),
  });

  const startResult = await provider.handleRequest({ method: "thread/start", params: { cwd: tempDir } });
  const turnResult = await provider.handleRequest({
    method: "turn/start",
    params: {
      threadId: startResult.thread.id,
      input: [{ type: "text", text: "Stop me" }],
    },
  });
  await waitFor(() => capturedAbortController);
  await provider.handleRequest({
    method: "turn/interrupt",
    params: {
      threadId: startResult.thread.id,
      turnId: turnResult.turnId,
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 20));

  const completions = sent.filter((message) => message.method === "turn/completed");
  assert.equal(completions.length, 1);
  assert.equal(completions[0].params.status, "stopped");
});

test("Claude provider sends data URL images as SDK image content blocks", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-claude-image-"));
  let capturedPrompt;
  const provider = createClaudeProvider({
    store: createClaudeThreadStore({ stateDir: tempDir }),
    sendApplicationMessage() {},
    executableResolver: () => ({ available: true, path: "/usr/local/bin/claude", reason: "" }),
    sdkLoader: () => ({
      query({ prompt }) {
        capturedPrompt = prompt;
        return makeQuery([
          {
            type: "result",
            subtype: "success",
            is_error: false,
          },
        ]);
      },
    }),
  });

  const startResult = await provider.handleRequest({ method: "thread/start", params: { cwd: tempDir } });
  await provider.handleRequest({
    method: "turn/start",
    params: {
      threadId: startResult.thread.id,
      input: [
        { type: "image", image_url: "data:image/png;base64,aGVsbG8=" },
        { type: "text", text: "Describe it" },
      ],
    },
  });
  await waitFor(() => capturedPrompt);
  const messages = [];
  for await (const message of capturedPrompt) {
    messages.push(message);
  }

  assert.equal(messages[0].type, "user");
  assert.equal(messages[0].message.content[0].type, "image");
  assert.equal(messages[0].message.content[0].source.media_type, "image/png");
  assert.equal(messages[0].message.content[0].source.data, "aGVsbG8=");
  assert.deepEqual(messages[0].message.content[1], { type: "text", text: "Describe it" });
});

test("Claude provider caches executable availability checks", () => {
  let resolveCount = 0;
  const provider = createClaudeProvider({
    sendApplicationMessage() {},
    executableResolver: () => {
      resolveCount += 1;
      return { available: true, path: "/usr/local/bin/claude", reason: "" };
    },
  });

  assert.equal(provider.listModels().length > 0, true);
  assert.equal(provider.listModels().length > 0, true);
  assert.equal(resolveCount, 1);
});

test("Claude provider rejects concurrent turns on the same thread", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-claude-concurrent-"));
  let capturedAbortController;
  const provider = createClaudeProvider({
    store: createClaudeThreadStore({ stateDir: tempDir }),
    sendApplicationMessage() {},
    executableResolver: () => ({ available: true, path: "/usr/local/bin/claude", reason: "" }),
    sdkLoader: () => ({
      query({ options }) {
        capturedAbortController = options.abortController;
        return {
          async *[Symbol.asyncIterator]() {
            await new Promise((resolve) => {
              capturedAbortController.signal.addEventListener("abort", resolve, { once: true });
            });
            throw new Error("aborted");
          },
          async interrupt() {},
        };
      },
    }),
  });

  const startResult = await provider.handleRequest({ method: "thread/start", params: { cwd: tempDir } });
  const firstTurn = await provider.handleRequest({
    method: "turn/start",
    params: {
      threadId: startResult.thread.id,
      input: [{ type: "text", text: "First" }],
    },
  });
  await waitFor(() => capturedAbortController);

  await assert.rejects(
    provider.handleRequest({
      method: "turn/start",
      params: {
        threadId: startResult.thread.id,
        input: [{ type: "text", text: "Second" }],
      },
    }),
    /already has an active turn/
  );

  await provider.handleRequest({
    method: "turn/interrupt",
    params: {
      threadId: startResult.thread.id,
      turnId: firstTurn.turnId,
    },
  });
});

test("Claude provider bridges tool approval responses to SDK permission results", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-claude-approval-"));
  const sent = [];
  const provider = createClaudeProvider({
    store: createClaudeThreadStore({ stateDir: tempDir }),
    sendApplicationMessage(message) {
      sent.push(JSON.parse(message));
    },
  });

  const approvalPromise = provider.requestToolApproval({
    threadId: "thread-1",
    turnId: "turn-1",
    toolName: "Bash",
    input: { command: "npm test" },
    approvalOptions: {},
  });

  assert.equal(sent[0].method, "item/commandExecution/requestApproval");
  assert.equal(provider.handleApplicationResponse({
    id: sent[0].id,
    result: { decision: "accept" },
  }), true);

  assert.deepEqual(await approvalPromise, {
    behavior: "allow",
    updatedInput: { command: "npm test" },
  });
});

test("Claude provider carries session approval suggestions back to the SDK", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-claude-session-approval-"));
  const sent = [];
  const provider = createClaudeProvider({
    store: createClaudeThreadStore({ stateDir: tempDir }),
    sendApplicationMessage(message) {
      sent.push(JSON.parse(message));
    },
  });
  const suggestion = {
    toolName: "Bash",
    ruleContent: "Bash(npm test)",
    destination: "session",
  };

  const approvalPromise = provider.requestToolApproval({
    threadId: "thread-1",
    turnId: "turn-1",
    toolName: "Bash",
    input: { command: "npm test" },
    approvalOptions: { suggestions: [suggestion] },
  });

  assert.equal(provider.handleApplicationResponse({
    id: sent[0].id,
    result: { decision: "acceptForSession" },
  }), true);

  assert.deepEqual(await approvalPromise, {
    behavior: "allow",
    updatedInput: { command: "npm test" },
    updatedPermissions: [suggestion],
  });
});

function makeQuery(messages) {
  return {
    async *[Symbol.asyncIterator]() {
      for (const message of messages) {
        await Promise.resolve();
        yield message;
      }
    },
    async interrupt() {},
  };
}

function fixedClock(values) {
  let index = 0;
  return () => new Date(values[Math.min(index++, values.length - 1)]);
}

async function waitFor(predicate, timeoutMs = 500) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (predicate()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail("Timed out waiting for predicate");
}
