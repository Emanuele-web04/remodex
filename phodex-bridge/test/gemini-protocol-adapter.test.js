const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { createGeminiProtocolAdapter } = require("../src/gemini-protocol-adapter");

function createFakeGeminiTransport() {
  let messageHandler = null;
  const sent = [];

  return {
    sent,
    transport: {
      mode: "test",
      describe() {
        return "fake gemini transport";
      },
      send(rawMessage) {
        sent.push(JSON.parse(rawMessage));
      },
      onMessage(handler) {
        messageHandler = handler;
      },
      onClose() {},
      onError() {},
      onStarted() {},
      shutdown() {},
    },
    emit(message) {
      messageHandler?.(JSON.stringify(message));
    },
  };
}

function responseById(messages, id) {
  return messages.find((message) => message.id === id && message.result);
}

test("Gemini adapter returns paginated thread turns instead of an RPC error", async (t) => {
  const previousHome = process.env.HOME;
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-gemini-adapter-"));
  process.env.HOME = tempHome;
  t.after(() => {
    process.env.HOME = previousHome;
    fs.rmSync(tempHome, { recursive: true, force: true });
  });

  const fake = createFakeGeminiTransport();
  const adapter = createGeminiProtocolAdapter({
    transport: fake.transport,
    logPrefix: "[test-gemini]",
  });
  const outbound = [];
  adapter.onMessage((rawMessage) => outbound.push(JSON.parse(rawMessage)));

  fake.emit({
    jsonrpc: "2.0",
    id: "gemini-init-1",
    result: {
      protocolVersion: 1,
      agentInfo: { name: "Gemini CLI", version: "test" },
    },
  });

  fake.emit({
    jsonrpc: "2.0",
    id: "gemini-adapter-1000",
    result: {
      sessionId: "gemini-session-1",
      models: {
        currentModelId: "gemini-2.5-pro",
        availableModels: ["gemini-2.5-pro"],
      },
      modes: {
        currentModeId: "default",
        availableModes: [{ id: "default", name: "Default" }],
      },
    },
  });

  adapter.send(JSON.stringify({
    id: "thread-start-1",
    method: "thread/start",
    params: { cwd: "/Users/developer/remodex" },
  }));
  const threadId = responseById(outbound, "thread-start-1").result.threadId;

  adapter.send(JSON.stringify({
    id: "turn-start-1",
    method: "turn/start",
    params: {
      threadId,
      prompt: "Кто ты?",
    },
  }));
  const turnId = responseById(outbound, "turn-start-1").result.turnId;

  fake.emit({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      update: {
        sessionUpdate: "message_start",
      },
    },
  });
  fake.emit({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      update: {
        sessionUpdate: "message_part",
        text: "Я Gemini CLI.",
      },
    },
  });
  fake.emit({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      update: {
        sessionUpdate: "message_complete",
      },
    },
  });
  fake.emit({
    jsonrpc: "2.0",
    id: "gemini-adapter-1001",
    result: { stopReason: "end_turn" },
  });

  adapter.send(JSON.stringify({
    id: "turns-list-1",
    method: "thread/turns/list",
    params: {
      threadId,
      limit: 10,
      sortDirection: "desc",
    },
  }));

  const response = responseById(outbound, "turns-list-1");
  assert.ok(response, "expected thread/turns/list response");
  assert.equal(response.error, undefined);
  assert.equal(response.result.data.length, 1);
  assert.equal(response.result.data[0].id, turnId);
  assert.deepEqual(
    response.result.data[0].items.map((item) => item.type),
    ["user_message", "agent_message"]
  );
  assert.equal(response.result.data[0].items[0].text, "Кто ты?");
  assert.equal(response.result.data[0].items[1].text, "Я Gemini CLI.");
});

test("Gemini adapter opens a Gemini session in the turn cwd selected by iOS", async (t) => {
  const previousHome = process.env.HOME;
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-gemini-adapter-"));
  process.env.HOME = tempHome;
  t.after(() => {
    process.env.HOME = previousHome;
    fs.rmSync(tempHome, { recursive: true, force: true });
  });

  const fake = createFakeGeminiTransport();
  const adapter = createGeminiProtocolAdapter({
    transport: fake.transport,
    logPrefix: "[test-gemini]",
  });
  const outbound = [];
  adapter.onMessage((rawMessage) => outbound.push(JSON.parse(rawMessage)));

  fake.emit({
    jsonrpc: "2.0",
    id: "gemini-init-1",
    result: {
      protocolVersion: 1,
      agentInfo: { name: "Gemini CLI", version: "test" },
    },
  });
  fake.emit({
    jsonrpc: "2.0",
    id: "gemini-adapter-1000",
    result: {
      sessionId: "root-session",
      models: {
        currentModelId: "gemini-2.5-pro",
        availableModels: ["gemini-2.5-pro"],
      },
      modes: {
        currentModeId: "default",
        availableModes: [{ id: "default", name: "Default" }],
      },
    },
  });

  adapter.send(JSON.stringify({
    id: "turn-start-documents",
    method: "turn/start",
    params: {
      threadId: "gemini-documents-thread",
      cwd: "/Users/developer/Documents",
      input: [{ type: "text", text: "Где ты?" }],
    },
  }));

  const sessionRequest = fake.sent.find((message) =>
    message.method === "session/new"
    && message.params?.cwd === "/Users/developer/Documents"
  );
  assert.ok(sessionRequest, "expected Gemini session/new to use the iOS-selected cwd");

  fake.emit({
    jsonrpc: "2.0",
    id: sessionRequest.id,
    result: {
      sessionId: "documents-session",
      models: {
        currentModelId: "gemini-2.5-pro",
        availableModels: ["gemini-2.5-pro"],
      },
      modes: {
        currentModeId: "default",
        availableModes: [{ id: "default", name: "Default" }],
      },
    },
  });
  await new Promise((resolve) => setImmediate(resolve));

  const promptRequest = fake.sent.find((message) =>
    message.method === "session/prompt"
    && message.params?.sessionId === "documents-session"
  );
  assert.ok(promptRequest, "expected turn prompt to use the cwd-scoped Gemini session");
  assert.ok(responseById(outbound, "turn-start-documents"));
});

test("Gemini adapter restores persisted threads with Gemini metadata after adapter restart", async (t) => {
  const previousHome = process.env.HOME;
  const tempHome = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-gemini-adapter-"));
  process.env.HOME = tempHome;
  t.after(() => {
    process.env.HOME = previousHome;
    fs.rmSync(tempHome, { recursive: true, force: true });
  });

  const first = createFakeGeminiTransport();
  const firstAdapter = createGeminiProtocolAdapter({
    transport: first.transport,
    logPrefix: "[test-gemini]",
  });
  const firstOutbound = [];
  firstAdapter.onMessage((rawMessage) => firstOutbound.push(JSON.parse(rawMessage)));

  first.emit({
    jsonrpc: "2.0",
    id: "gemini-init-1",
    result: {
      protocolVersion: 1,
      agentInfo: { name: "Gemini CLI", version: "test" },
    },
  });
  first.emit({
    jsonrpc: "2.0",
    id: "gemini-adapter-1000",
    result: {
      sessionId: "root-session",
      models: {
        currentModelId: "gemini-2.5-pro",
        availableModels: ["gemini-2.5-pro"],
      },
      modes: {
        currentModeId: "default",
        availableModes: [{ id: "default", name: "Default" }],
      },
    },
  });

  firstAdapter.send(JSON.stringify({
    id: "thread-start-reconnect",
    method: "thread/start",
    params: { cwd: "/Users/developer/remodex" },
  }));
  const threadId = responseById(firstOutbound, "thread-start-reconnect").result.threadId;

  firstAdapter.send(JSON.stringify({
    id: "turn-start-reconnect",
    method: "turn/start",
    params: {
      threadId,
      prompt: "Восстанови меня после reconnect",
      cwd: "/Users/developer/remodex",
      model: "gemini-2.5-pro",
    },
  }));

  const sessionRequest = first.sent.find((message) =>
    message.method === "session/new"
    && message.params?.cwd === "/Users/developer/remodex"
  );
  assert.ok(sessionRequest, "expected a cwd-scoped Gemini session request");

  first.emit({
    jsonrpc: "2.0",
    id: sessionRequest.id,
    result: {
      sessionId: "reconnect-session",
      models: {
        currentModelId: "gemini-2.5-pro",
        availableModels: ["gemini-2.5-pro"],
      },
      modes: {
        currentModeId: "default",
        availableModes: [{ id: "default", name: "Default" }],
      },
    },
  });
  await new Promise((resolve) => setImmediate(resolve));

  first.emit({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      update: {
        sessionUpdate: "message_start",
      },
    },
  });
  first.emit({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      update: {
        sessionUpdate: "message_part",
        text: "Я вернулся после reconnect.",
      },
    },
  });
  first.emit({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      update: {
        sessionUpdate: "message_complete",
      },
    },
  });
  first.emit({
    jsonrpc: "2.0",
    id: "gemini-adapter-1002",
    result: { stopReason: "end_turn" },
  });

  const second = createFakeGeminiTransport();
  const secondAdapter = createGeminiProtocolAdapter({
    transport: second.transport,
    logPrefix: "[test-gemini]",
  });
  const secondOutbound = [];
  secondAdapter.onMessage((rawMessage) => secondOutbound.push(JSON.parse(rawMessage)));

  second.emit({
    jsonrpc: "2.0",
    id: "gemini-init-1",
    result: {
      protocolVersion: 1,
      agentInfo: { name: "Gemini CLI", version: "test" },
    },
  });
  second.emit({
    jsonrpc: "2.0",
    id: "gemini-adapter-1000",
    result: {
      sessionId: "second-root-session",
      models: {
        currentModelId: "gemini-2.5-pro",
        availableModels: ["gemini-2.5-pro"],
      },
      modes: {
        currentModeId: "default",
        availableModes: [{ id: "default", name: "Default" }],
      },
    },
  });

  secondAdapter.send(JSON.stringify({
    id: "thread-list-reconnect",
    method: "thread/list",
    params: {},
  }));
  secondAdapter.send(JSON.stringify({
    id: "thread-read-reconnect",
    method: "thread/read",
    params: { threadId },
  }));
  secondAdapter.send(JSON.stringify({
    id: "thread-resume-reconnect",
    method: "thread/resume",
    params: { threadId },
  }));

  const listResponse = responseById(secondOutbound, "thread-list-reconnect");
  const readResponse = responseById(secondOutbound, "thread-read-reconnect");
  const resumeResponse = responseById(secondOutbound, "thread-resume-reconnect");

  assert.ok(listResponse, "expected thread/list response after adapter restart");
  assert.ok(readResponse, "expected thread/read response after adapter restart");
  assert.ok(resumeResponse, "expected thread/resume response after adapter restart");

  assert.equal(listResponse.result.threads.length, 1);
  assert.equal(listResponse.result.threads[0].id, threadId);
  assert.equal(listResponse.result.threads[0].model, "gemini-2.5-pro");
  assert.equal(listResponse.result.threads[0].modelProvider, "gemini");
  assert.equal(listResponse.result.threads[0].backendType, "gemini");

  assert.equal(readResponse.result.thread.id, threadId);
  assert.equal(readResponse.result.thread.model, "gemini-2.5-pro");
  assert.equal(readResponse.result.thread.modelProvider, "gemini");
  assert.equal(readResponse.result.thread.backendType, "gemini");
  assert.equal(readResponse.result.turns.length, 1);
  assert.deepEqual(
    readResponse.result.turns[0].items.map((item) => item.text),
    ["Восстанови меня после reconnect", "Я вернулся после reconnect."]
  );

  assert.equal(resumeResponse.result.threadId, threadId);
  assert.equal(resumeResponse.result.thread.model, "gemini-2.5-pro");
  assert.equal(resumeResponse.result.thread.modelProvider, "gemini");
  assert.equal(resumeResponse.result.thread.backendType, "gemini");
});
