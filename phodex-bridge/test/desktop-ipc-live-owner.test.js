// FILE: desktop-ipc-live-owner.test.js
// Purpose: Verifies Remodex-owned Codex streams are exposed to Desktop/VSCode through the local IPC bus.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, net, ../src/desktop-ipc-live-owner

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { setTimeout: wait } = require("node:timers/promises");
const {
  applyAppServerMessageToConversationState,
  buildConversationStatePatches,
  createDesktopIpcLiveOwner,
} = require("../src/desktop-ipc-live-owner");

test("live owner broadcasts Remodex-owned thread snapshots over Desktop IPC", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-");
  const frames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      frames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-owner-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    owner.stopAll();
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    snapshotDebounceMs: 1,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "thread-start-1",
    method: "thread/start",
    params: { cwd: "/tmp/project" },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "thread/started",
    params: {
      thread: {
        id: "thread-live-owner",
        sessionId: "session-live-owner",
        preview: "Build it",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 1,
        status: { type: "active" },
        path: null,
        cwd: "/tmp/project",
        cliVersion: "test",
        source: "app-server",
        threadSource: null,
        gitInfo: null,
        name: "Live owner",
        turns: [],
      },
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-live-owner",
      turn: {
        id: "turn-live-owner",
        items: [],
        status: "inProgress",
        error: null,
        startedAt: 2,
        completedAt: null,
        durationMs: null,
      },
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "item/agentMessage/delta",
    params: {
      threadId: "thread-live-owner",
      turnId: "turn-live-owner",
      itemId: "assistant-live-owner",
      delta: "Hello",
    },
  }));

  const broadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast" && frame.method === "thread-stream-state-changed"
  );
  assert.equal(broadcast.version, 6);
  assert.equal(broadcast.params.conversationId, "thread-live-owner");
  assert.equal(broadcast.params.hostId, "local");
  assert.equal(broadcast.params.change.type, "snapshot");
  assert.equal(broadcast.params.change.conversationState.id, "thread-live-owner");
  assert.equal(broadcast.params.change.conversationState.turns[0].turnId, "turn-live-owner");
  assert.equal(broadcast.params.change.conversationState.turns[0].items[0].text, "Hello");
});

test("live owner broadcasts patches after the first owned thread snapshot", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-patches-");
  const frames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      frames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-owner-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    owner.stopAll();
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    snapshotDebounceMs: 1,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "thread-start-patch-1",
    method: "thread/start",
    params: { cwd: "/tmp/project" },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "thread/started",
    params: {
      thread: {
        id: "thread-live-patches",
        sessionId: "session-live-patches",
        preview: "Build it",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 1,
        status: { type: "active" },
        path: null,
        cwd: "/tmp/project",
        cliVersion: "test",
        source: "app-server",
        threadSource: null,
        gitInfo: null,
        name: "Live patches",
        turns: [],
      },
    },
  }));

  const snapshot = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-live-patches"
      && frame.params?.change?.type === "snapshot"
  );
  assert.equal(snapshot.params.change.conversationState.turns.length, 0);

  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-live-patches",
      turn: {
        id: "turn-live-patches",
        items: [],
        status: "inProgress",
        error: null,
        startedAt: 2,
        completedAt: null,
        durationMs: null,
      },
    },
  }));

  const turnPatchBroadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-live-patches"
      && frame.params?.change?.type === "patches"
      && frame.params.change.patches.some((patch) => (
        patch.op === "add"
        && JSON.stringify(patch.path) === JSON.stringify(["turns", 0])
      ))
  );
  assert.equal(turnPatchBroadcast.version, 6);

  owner.observeOutbound(JSON.stringify({
    method: "item/agentMessage/delta",
    params: {
      threadId: "thread-live-patches",
      turnId: "turn-live-patches",
      itemId: "assistant-live-patches",
      delta: "Hello",
    },
  }));

  const itemPatchBroadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-live-patches"
      && frame.params?.change?.type === "patches"
      && frame.params.change.patches.some((patch) => (
        patch.op === "add"
        && JSON.stringify(patch.path) === JSON.stringify(["turns", 0, "items", 0])
        && patch.value?.text === "Hello"
      ))
  );
  assert.ok(itemPatchBroadcast.params.change.patches.length > 0);
});

test("live owner starts a local IPC router when no Codex IPC socket exists", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-router-");
  const codexRequests = [];
  const desktopFrames = [];
  let desktopSocket = null;

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    snapshotDebounceMs: 1,
    reconnectMs: 10,
    requestTimeoutMs: 500,
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  t.after(() => {
    owner.stopAll();
    desktopSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-router-owned", input: [] },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "thread/started",
    params: {
      thread: {
        id: "thread-router-owned",
        sessionId: "session-router-owned",
        preview: "Router fallback",
        createdAt: 1,
        updatedAt: 1,
        cwd: "/tmp/router-project",
        status: { type: "active" },
        turns: [],
      },
    },
  }));

  await waitFor(() => fs.existsSync(socketPath));

  desktopSocket = net.createConnection(socketPath);
  attachFrameReader(desktopSocket, (frame) => desktopFrames.push(frame));
  await new Promise((resolve) => desktopSocket.once("connect", resolve));
  writeFrame(desktopSocket, {
    type: "request",
    requestId: "desktop-init-1",
    sourceClientId: "initializing-client",
    version: 1,
    method: "initialize",
    params: { clientType: "vscode" },
  });
  await waitFor(() => desktopFrames.find((frame) => frame.requestId === "desktop-init-1"));

  const snapshot = await waitForMessage(
    desktopFrames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-router-owned"
      && frame.params?.change?.type === "snapshot"
  );
  assert.equal(snapshot.version, 6);
  assert.equal(snapshot.params.change.conversationState.id, "thread-router-owned");

  writeFrame(desktopSocket, {
    type: "request",
    requestId: "desktop-start-1",
    sourceClientId: "desktop-client",
    method: "thread-follower-start-turn",
    params: {
      conversationId: "thread-router-owned",
      turnStartParams: {
        input: [{ type: "text", text: "continue from desktop" }],
        cwd: "/tmp/router-project",
      },
    },
  });

  const routedResponse = await waitForMessage(
    desktopFrames,
    (frame) => frame.type === "response" && frame.requestId === "desktop-start-1"
  );
  assert.equal(routedResponse.resultType, "success");
  assert.deepEqual(codexRequests, [{
    method: "turn/start",
    params: {
      threadId: "thread-router-owned",
      input: [{ type: "text", text: "continue from desktop" }],
      cwd: "/tmp/router-project",
    },
  }]);
});

test("conversation state patch builder falls back when patches are too large", () => {
  assert.deepEqual(
    buildConversationStatePatches(
      { turns: [] },
      { turns: [{ id: "turn-1" }], updatedAt: 1 },
      { maxPatchCount: 10, maxPatchBytes: 1024 }
    ),
    [
      { op: "add", path: ["turns", 0], value: { id: "turn-1" } },
      { op: "add", path: ["updatedAt"], value: 1 },
    ]
  );
  assert.equal(
    buildConversationStatePatches(
      { turns: [] },
      { turns: [{ id: "turn-1" }], updatedAt: 1 },
      { maxPatchCount: 1, maxPatchBytes: 1024 }
    ),
    null
  );
});

test("live owner seeds existing thread snapshots from thread reads before ownership", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-existing-");
  const frames = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      frames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-owner-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    owner.stopAll();
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    snapshotDebounceMs: 1,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "read-existing-1",
    method: "thread/read",
    params: { threadId: "thread-existing" },
  }));
  owner.observeOutbound(JSON.stringify({
    id: "read-existing-1",
    result: {
      thread: {
        id: "thread-existing",
        sessionId: "session-existing",
        preview: "Existing",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 2,
        status: { type: "idle" },
        path: null,
        cwd: "/tmp/existing",
        cliVersion: "test",
        source: "app-server",
        threadSource: null,
        gitInfo: null,
        name: "Existing thread",
        turns: [{
          id: "turn-old",
          items: [{
            id: "assistant-old",
            type: "agentMessage",
            text: "Previous answer",
          }],
          status: "completed",
          error: null,
          startedAt: 1,
          completedAt: 2,
          durationMs: 1000,
        }],
      },
    },
  }));
  owner.observeInbound(JSON.stringify({
    id: "turn-start-existing",
    method: "turn/start",
    params: {
      threadId: "thread-existing",
      cwd: "/tmp/existing",
      input: [{ type: "input_text", text: "continue" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-existing",
      turn: {
        id: "turn-new",
        items: [],
        status: "inProgress",
        error: null,
        startedAt: 3,
        completedAt: null,
        durationMs: null,
      },
    },
  }));

  const broadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.change?.conversationState?.turns?.some((turn) => turn.turnId === "turn-new")
  );
  const state = broadcast.params.change.conversationState;
  assert.equal(state.title, "Existing thread");
  assert.equal(state.turns[0].turnId, "turn-old");
  assert.equal(state.turns[0].items[0].text, "Previous answer");
  assert.equal(state.turns[1].turnId, "turn-new");
});

test("live owner handles discovery and start-turn follower requests for owned threads", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-follower-");
  const codexRequests = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-owner-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    owner.stopAll();
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    snapshotDebounceMs: 1,
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      return {
        turn: {
          id: "turn-from-follower",
          status: "inProgress",
        },
      };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-owned", input: [] },
  }));
  await waitFor(() => serverSocket);

  writeFrame(serverSocket, {
    type: "client-discovery-request",
    requestId: "discovery-1",
    request: {
      type: "request",
      requestId: "inner-1",
      method: "thread-follower-start-turn",
      params: {
        conversationId: "thread-owned",
      },
    },
  });
  const discoveryResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "client-discovery-response"
  );
  assert.deepEqual(discoveryResponse.response, { canHandle: true });

  writeFrame(serverSocket, {
    type: "client-discovery-request",
    requestId: "discovery-unsupported",
    request: {
      type: "request",
      requestId: "inner-unsupported",
      method: "thread-follower-edit-last-user-turn",
      params: {
        conversationId: "thread-owned",
      },
    },
  });
  const unsupportedDiscoveryResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "client-discovery-response" && frame.requestId === "discovery-unsupported"
  );
  assert.deepEqual(unsupportedDiscoveryResponse.response, { canHandle: false });

  writeFrame(serverSocket, {
    type: "request",
    requestId: "start-turn-1",
    sourceClientId: "desktop",
    method: "thread-follower-start-turn",
    params: {
      conversationId: "thread-owned",
      turnStartParams: {
        input: [{ type: "text", text: "continue" }],
        model: "gpt-test",
        attachments: [{ id: "client-only" }],
      },
    },
  });
  const response = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "start-turn-1"
  );
  assert.equal(response.resultType, "success");
  assert.deepEqual(codexRequests, [{
    method: "turn/start",
    params: {
      threadId: "thread-owned",
      input: [{ type: "text", text: "continue" }],
      model: "gpt-test",
    },
  }]);
});

test("live owner routes follower approval responses back to app-server", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-approval-");
  const rawCodexMessages = [];
  let serverSocket = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "router",
          result: { clientId: "remodex-owner-test" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  t.after(() => {
    owner.stopAll();
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage(rawMessage) {
      rawCodexMessages.push(JSON.parse(rawMessage));
    },
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-approval", input: [] },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "request",
    requestId: "approval-1",
    sourceClientId: "desktop",
    method: "thread-follower-file-approval-decision",
    params: {
      conversationId: "thread-approval",
      requestId: "file-approval-1",
      decision: "accept",
    },
  });

  const response = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "approval-1"
  );
  assert.equal(response.resultType, "success");
  assert.deepEqual(rawCodexMessages, [{
    id: "file-approval-1",
    result: {
      decision: "accept",
    },
  }]);
});

test("conversation adapter tracks requests and resolved notifications", () => {
  const conversations = new Map();
  const owned = new Set(["thread-adapter"]);
  const now = () => 42;
  let update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      id: "request-1",
      method: "item/tool/requestUserInput",
      params: {
        threadId: "thread-adapter",
        turnId: "turn-adapter",
        itemId: "item-adapter",
        questions: [{ id: "q1", question: "Continue?" }],
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-adapter", changed: true });
  assert.equal(conversations.get("thread-adapter").requests.length, 1);

  update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "serverRequest/resolved",
      params: {
        threadId: "thread-adapter",
        requestId: "request-1",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-adapter", changed: true });
  assert.equal(conversations.get("thread-adapter").requests.length, 0);
});

function attachFrameReader(socket, onFrame) {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const frameLength = buffer.readUInt32LE(0);
      if (buffer.length < 4 + frameLength) {
        return;
      }
      const payload = buffer.slice(4, 4 + frameLength).toString("utf8");
      buffer = buffer.slice(4 + frameLength);
      onFrame(JSON.parse(payload));
    }
  });
}

function writeFrame(socket, payload) {
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  socket.write(Buffer.concat([header, body]));
}

async function waitForMessage(messages, predicate, timeoutMs = 1_000) {
  await waitFor(() => messages.find(predicate), timeoutMs);
  return messages.find(predicate);
}

async function waitForFrame(socket, predicate, timeoutMs = 1_000) {
  const frames = [];
  const onFrame = (frame) => frames.push(frame);
  attachFrameReader(socket, onFrame);
  await waitFor(() => frames.find(predicate), timeoutMs);
  socket.off("data", onFrame);
  return frames.find(predicate);
}

async function waitFor(predicate, timeoutMs = 1_000) {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > timeoutMs) {
      throw new Error("Timed out waiting for condition");
    }
    await wait(5);
  }
}

function createIpcTestSocket(prefix) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  const socketPath = process.platform === "win32"
    ? `\\\\.\\pipe\\${path.basename(tempDir)}-ipc`
    : path.join(tempDir, "ipc.sock");
  return { tempDir, socketPath };
}
