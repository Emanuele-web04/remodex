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
  assert.equal(broadcast.params.version, 6);
  assert.equal(broadcast.params.conversationId, "thread-live-owner");
  assert.equal(broadcast.params.hostId, "local");
  assert.equal(broadcast.params.remodexOwnerSource, "desktop-ipc-live-owner");
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
  assert.equal(turnPatchBroadcast.params.version, 6);

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
  assert.equal(snapshot.params.version, 6);
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
  assert.deepEqual(codexRequests.filter((request) => request.method === "turn/start"), [{
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

test("live owner does not rewind live state from a stale cached thread on later turns", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-stale-cache-");
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
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "read-stale-cache",
    method: "thread/read",
    params: { threadId: "thread-stale-cache" },
  }));
  owner.observeOutbound(JSON.stringify({
    id: "read-stale-cache",
    result: {
      thread: {
        id: "thread-stale-cache",
        createdAt: 1,
        updatedAt: 2,
        cwd: "/tmp/stale-cache",
        name: "Stale cache",
        turns: [{
          id: "turn-stale-cache",
          items: [{
            id: "assistant-stale-cache",
            type: "agentMessage",
            text: "cached text",
          }],
          status: "inProgress",
          startedAt: 1,
        }],
      },
    },
  }));

  owner.observeInbound(JSON.stringify({
    id: "turn-start-stale-cache-1",
    method: "turn/start",
    params: {
      threadId: "thread-stale-cache",
      cwd: "/tmp/stale-cache",
      input: [{ type: "input_text", text: "continue" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "item/completed",
    params: {
      threadId: "thread-stale-cache",
      turnId: "turn-stale-cache",
      item: {
        id: "assistant-stale-cache",
        type: "agentMessage",
        text: "live updated text",
      },
    },
  }));
  assert.equal(
    owner._debugSnapshot("thread-stale-cache").turns[0].items[0].text,
    "live updated text"
  );

  owner.observeInbound(JSON.stringify({
    id: "turn-start-stale-cache-2",
    method: "turn/start",
    params: {
      threadId: "thread-stale-cache",
      cwd: "/tmp/stale-cache",
      input: [{ type: "input_text", text: "continue again" }],
    },
  }));

  assert.equal(
    owner._debugSnapshot("thread-stale-cache").turns[0].items[0].text,
    "live updated text"
  );
});

test("live owner keeps phone turn input in snapshots when turn/started has no items", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-user-input-");
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
    id: "turn-start-user-input",
    method: "turn/start",
    params: {
      threadId: "thread-user-input",
      cwd: "/tmp/user-input",
      input: [{ type: "input_text", text: "build the feature" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-user-input",
      turn: {
        id: "turn-user-input",
        items: [],
        status: "inProgress",
        error: null,
        startedAt: 2,
        completedAt: null,
        durationMs: null,
      },
    },
  }));

  const broadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-user-input"
      && frame.params?.change?.type === "snapshot"
  );
  const turn = broadcast.params.change.conversationState.turns[0];
  assert.equal(turn.turnId, "turn-user-input");
  assert.deepEqual(turn.params.input, [{ type: "input_text", text: "build the feature" }]);
  assert.deepEqual(turn.items[0], {
    id: "user-message-turn-user-input",
    type: "userMessage",
    remodexSyntheticUserMessage: true,
    content: [{ type: "text", text: "build the feature" }],
  });
});

test("live owner router keeps same-id requests from different clients separate", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-routed-ids-");
  let handlerSocket = null;
  let firstSenderSocket = null;
  let secondSenderSocket = null;

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    snapshotDebounceMs: 1,
    reconnectMs: 10,
    requestTimeoutMs: 500,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
  });
  t.after(() => {
    owner.stopAll();
    handlerSocket?.destroy();
    firstSenderSocket?.destroy();
    secondSenderSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-router-ids", input: [] },
  }));
  await waitFor(() => fs.existsSync(socketPath));

  const handlerFrames = [];
  handlerSocket = net.createConnection(socketPath);
  attachFrameReader(handlerSocket, (frame) => {
    handlerFrames.push(frame);
    if (frame.type === "client-discovery-request") {
      writeFrame(handlerSocket, {
        type: "client-discovery-response",
        requestId: frame.requestId,
        response: { canHandle: frame.request?.method === "desktop-owned-action" },
      });
      return;
    }
    if (frame.type === "request" && frame.method === "desktop-owned-action") {
      writeFrame(handlerSocket, {
        type: "response",
        requestId: frame.requestId,
        resultType: "success",
        method: frame.method,
        handledByClientId: "handler",
        result: { tag: frame.params?.tag },
      });
    }
  });
  await new Promise((resolve) => handlerSocket.once("connect", resolve));
  writeFrame(handlerSocket, {
    type: "request",
    requestId: "handler-init",
    sourceClientId: "initializing-client",
    version: 1,
    method: "initialize",
    params: { clientType: "desktop" },
  });
  await waitFor(() => handlerFrames.find((frame) => frame.requestId === "handler-init"));

  const connectSender = async (initId) => {
    const frames = [];
    const socket = net.createConnection(socketPath);
    attachFrameReader(socket, (frame) => {
      frames.push(frame);
      if (frame.type === "client-discovery-request") {
        writeFrame(socket, {
          type: "client-discovery-response",
          requestId: frame.requestId,
          response: { canHandle: false },
        });
      }
    });
    await new Promise((resolve) => socket.once("connect", resolve));
    writeFrame(socket, {
      type: "request",
      requestId: initId,
      sourceClientId: "initializing-client",
      version: 1,
      method: "initialize",
      params: { clientType: "vscode" },
    });
    await waitFor(() => frames.find((frame) => frame.requestId === initId));
    return { socket, frames };
  };

  const firstSender = await connectSender("sender-one-init");
  const secondSender = await connectSender("sender-two-init");
  firstSenderSocket = firstSender.socket;
  secondSenderSocket = secondSender.socket;

  // Both clients reuse the same connection-scoped request id concurrently.
  writeFrame(firstSender.socket, {
    type: "request",
    requestId: "1",
    sourceClientId: "sender-one",
    version: 1,
    method: "desktop-owned-action",
    params: { tag: "first" },
  });
  writeFrame(secondSender.socket, {
    type: "request",
    requestId: "1",
    sourceClientId: "sender-two",
    version: 1,
    method: "desktop-owned-action",
    params: { tag: "second" },
  });

  const firstResponse = await waitForMessage(
    firstSender.frames,
    (frame) => frame.type === "response" && frame.requestId === "1"
  );
  const secondResponse = await waitForMessage(
    secondSender.frames,
    (frame) => frame.type === "response" && frame.requestId === "1"
  );
  assert.equal(firstResponse.resultType, "success");
  assert.deepEqual(firstResponse.result, { tag: "first" });
  assert.equal(secondResponse.resultType, "success");
  assert.deepEqual(secondResponse.result, { tag: "second" });

  const routedRequests = handlerFrames.filter((frame) => (
    frame.type === "request" && frame.method === "desktop-owned-action"
  ));
  assert.equal(routedRequests.length, 2);
  assert.notEqual(routedRequests[0].requestId, routedRequests[1].requestId);
});

test("live owner router prefers Remodex handler when multiple clients can handle", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-router-priority-");
  let desktopSocket = null;
  let remodexSocket = null;
  let senderSocket = null;

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    snapshotDebounceMs: 1,
    reconnectMs: 10,
    requestTimeoutMs: 500,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
  });
  t.after(() => {
    owner.stopAll();
    desktopSocket?.destroy();
    remodexSocket?.destroy();
    senderSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-router-priority", input: [] },
  }));
  await waitFor(() => fs.existsSync(socketPath));

  const connectHandler = async (initId, clientType, resultTag) => {
    const frames = [];
    const socket = net.createConnection(socketPath);
    attachFrameReader(socket, (frame) => {
      frames.push(frame);
      if (frame.type === "client-discovery-request") {
        writeFrame(socket, {
          type: "client-discovery-response",
          requestId: frame.requestId,
          response: { canHandle: frame.request?.method === "desktop-owned-action" },
        });
        return;
      }
      if (frame.type === "request" && frame.method === "desktop-owned-action") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: resultTag,
          result: { handledBy: resultTag },
        });
      }
    });
    await new Promise((resolve) => socket.once("connect", resolve));
    writeFrame(socket, {
      type: "request",
      requestId: initId,
      sourceClientId: "initializing-client",
      version: 1,
      method: "initialize",
      params: { clientType },
    });
    await waitFor(() => frames.find((frame) => frame.requestId === initId));
    return { socket, frames };
  };

  const desktop = await connectHandler("desktop-priority-init", "desktop", "desktop");
  desktopSocket = desktop.socket;
  const remodex = await connectHandler("remodex-priority-init", "remodex-bridge", "remodex");
  remodexSocket = remodex.socket;

  const senderFrames = [];
  senderSocket = net.createConnection(socketPath);
  attachFrameReader(senderSocket, (frame) => {
    senderFrames.push(frame);
    if (frame.type === "client-discovery-request") {
      writeFrame(senderSocket, {
        type: "client-discovery-response",
        requestId: frame.requestId,
        response: { canHandle: false },
      });
    }
  });
  await new Promise((resolve) => senderSocket.once("connect", resolve));
  writeFrame(senderSocket, {
    type: "request",
    requestId: "sender-priority-init",
    sourceClientId: "initializing-client",
    version: 1,
    method: "initialize",
    params: { clientType: "vscode" },
  });
  await waitFor(() => senderFrames.find((frame) => frame.requestId === "sender-priority-init"));

  writeFrame(senderSocket, {
    type: "request",
    requestId: "priority-request",
    sourceClientId: "sender",
    version: 1,
    method: "desktop-owned-action",
    params: { tag: "priority" },
  });

  const response = await waitForMessage(
    senderFrames,
    (frame) => frame.type === "response" && frame.requestId === "priority-request"
  );
  assert.equal(response.resultType, "success");
  assert.deepEqual(response.result, { handledBy: "remodex" });
  assert.equal(
    desktop.frames.some((frame) => frame.type === "request" && frame.method === "desktop-owned-action"),
    false
  );
  assert.equal(
    remodex.frames.some((frame) => frame.type === "request" && frame.method === "desktop-owned-action"),
    true
  );
});

test("live owner hydrates existing threads before first mobile-owned snapshot", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-hydrate-");
  const frames = [];
  const codexRequests = [];
  let serverSocket = null;
  let resolveThreadRead = null;

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
    sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      return new Promise((resolve) => {
        resolveThreadRead = resolve;
      });
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "turn-start-hydrate",
    method: "turn/start",
    params: {
      threadId: "thread-hydrate",
      cwd: "/tmp/hydrate",
      input: [{ type: "input_text", text: "continue" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-hydrate",
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

  await wait(25);
  assert.equal(codexRequests.length, 1);
  assert.deepEqual(codexRequests[0], {
    method: "thread/read",
    params: { threadId: "thread-hydrate" },
  });
  assert.equal(frames.some((frame) => frame.type === "broadcast"), false);

  resolveThreadRead({
    thread: {
      id: "thread-hydrate",
      sessionId: "session-hydrate",
      preview: "Hydrate",
      ephemeral: false,
      modelProvider: "openai",
      createdAt: 1,
      updatedAt: 2,
      status: { type: "idle" },
      path: null,
      cwd: "/tmp/hydrate",
      cliVersion: "test",
      source: "app-server",
      threadSource: null,
      gitInfo: null,
      name: "Hydrated thread",
      turns: [{
        id: "turn-old",
        items: [{
          id: "assistant-old",
          type: "agentMessage",
          text: "Existing Desktop content",
        }],
        status: "completed",
        error: null,
        startedAt: 1,
        completedAt: 2,
        durationMs: 1000,
      }],
    },
  });

  const broadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-hydrate"
      && frame.params?.change?.type === "snapshot"
  );
  const state = broadcast.params.change.conversationState;
  assert.equal(state.title, "Hydrated thread");
  assert.equal(state.turns.length, 2);
  assert.equal(state.turns[0].turnId, "turn-old");
  assert.equal(state.turns[0].items[0].text, "Existing Desktop content");
  assert.equal(state.turns[1].turnId, "turn-new");
});

test("live owner resumes snapshots when existing thread hydration fails", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-hydrate-fail-");
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
    sendCodexRequest: async () => {
      throw new Error("read failed");
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "turn-start-hydrate-fail",
    method: "turn/start",
    params: {
      threadId: "thread-hydrate-fail",
      cwd: "/tmp/hydrate-fail",
      input: [{ type: "input_text", text: "continue" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-hydrate-fail",
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
      && frame.params?.conversationId === "thread-hydrate-fail"
      && frame.params?.change?.type === "snapshot"
  );
  const state = broadcast.params.change.conversationState;
  assert.equal(state.turns.length, 1);
  assert.equal(state.turns[0].turnId, "turn-new");
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
  assert.deepEqual(codexRequests.filter((request) => request.method === "turn/start"), [{
    method: "turn/start",
    params: {
      threadId: "thread-owned",
      input: [{ type: "text", text: "continue" }],
      model: "gpt-test",
    },
  }]);
});

test("live owner dedupes held phone turn starts routed back through follower IPC", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-held-dedupe-");
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
    async sendCodexRequest(method) {
      if (method === "turn/start") {
        return { turn: { id: "turn-from-held-follower" } };
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  const input = [{ type: "input_text", text: "held prompt" }];
  owner.observeInbound(JSON.stringify({
    id: "phone-held-start",
    method: "turn/start",
    params: {
      threadId: "thread-held-dedupe",
      cwd: "/tmp/held-dedupe",
      input,
    },
  }));
  await waitFor(() => serverSocket);

  writeFrame(serverSocket, {
    type: "request",
    requestId: "start-held-dedupe",
    sourceClientId: "desktop",
    method: "thread-follower-start-turn",
    params: {
      conversationId: "thread-held-dedupe",
      senderRequestId: "phone-held-start",
      turnStartParams: {
        cwd: "/tmp/held-dedupe",
        input,
      },
    },
  });
  const response = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "start-held-dedupe"
  );
  assert.equal(response.resultType, "success");

  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-held-dedupe",
      turn: {
        id: "turn-one",
        items: [],
        status: "inProgress",
        startedAt: 1,
      },
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-held-dedupe",
      turn: {
        id: "turn-two",
        items: [],
        status: "inProgress",
        startedAt: 2,
      },
    },
  }));

  const snapshot = owner._debugSnapshot("thread-held-dedupe");
  const firstTurn = snapshot.turns.find((turn) => turn.turnId === "turn-one");
  const secondTurn = snapshot.turns.find((turn) => turn.turnId === "turn-two");
  assert.deepEqual(firstTurn.params.input, input);
  assert.deepEqual(secondTurn.params.input, []);
  assert.equal(secondTurn.items.some((item) => item.type === "userMessage"), false);
});

test("live owner broadcasts a removed snapshot before archive cleanup", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-archive-remove-");
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
    id: "turn-start-archive-remove",
    method: "turn/start",
    params: {
      threadId: "thread-archive-remove",
      input: [{ type: "input_text", text: "work to archive" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-archive-remove",
      turn: {
        id: "turn-archive-remove",
        items: [{
          id: "assistant-archive-remove",
          type: "agentMessage",
          text: "visible before archive",
        }],
        status: "inProgress",
        startedAt: 1,
      },
    },
  }));
  await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-archive-remove"
      && frame.params?.change?.type === "snapshot"
      && !frame.params?.remodexOwnerReleased
  );

  owner.observeInbound(JSON.stringify({
    id: "archive-thread-remove",
    method: "thread/archive",
    params: { threadId: "thread-archive-remove" },
  }));

  const archived = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-archived"
      && frame.params?.conversationId === "thread-archive-remove"
  );
  assert.equal(archived.version, 2);
  assert.equal(archived.params.hostId, "local");

  const removed = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-archive-remove"
      && frame.params?.remodexOwnerReleased === true
  );
  assert.equal(removed.params.remodexOwnerSource, "desktop-ipc-live-owner");
  assert.equal(removed.params.version, 6);
  assert.equal(removed.params.change.type, "snapshot");
  assert.deepEqual(removed.params.change.conversationState.turns, []);
  assert.deepEqual(removed.params.change.conversationState.requests, []);
  assert.equal(removed.params.change.conversationState.archived, true);
  assert.equal(removed.params.change.conversationState.remodexRemoved, true);
  assert.equal(owner._debugSnapshot("thread-archive-remove"), null);
});

test("live owner normalizes follower start-turn params before app-server requests", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-normalize-");
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
    normalizeTurnStartParams(params) {
      return { ...params, summary: "none" };
    },
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-normalize", input: [] },
  }));
  await waitFor(() => serverSocket);
  writeFrame(serverSocket, {
    type: "request",
    requestId: "start-turn-normalize-1",
    sourceClientId: "desktop",
    method: "thread-follower-start-turn",
    params: {
      conversationId: "thread-normalize",
      turnStartParams: {
        input: [{ type: "text", text: "continue" }],
        model: "gpt-5.3-codex-spark",
        summary: "auto",
      },
    },
  });

  const response = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "start-turn-normalize-1"
  );
  assert.equal(response.resultType, "success");
  assert.deepEqual(codexRequests.filter((request) => request.method === "turn/start"), [{
    method: "turn/start",
    params: {
      threadId: "thread-normalize",
      input: [{ type: "text", text: "continue" }],
      model: "gpt-5.3-codex-spark",
      summary: "none",
    },
  }]);
});

test("live owner applies Desktop runtime overrides to later follower turn starts", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-runtime-overrides-");
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
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-overrides", input: [] },
  }));
  await waitFor(() => serverSocket);

  writeFrame(serverSocket, {
    type: "request",
    requestId: "set-model-1",
    sourceClientId: "desktop",
    method: "thread-follower-set-model-and-reasoning",
    params: {
      conversationId: "thread-overrides",
      model: "gpt-desktop-pick",
      reasoningEffort: "high",
    },
  });
  const setModelResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "set-model-1"
  );
  assert.equal(setModelResponse.resultType, "success");

  writeFrame(serverSocket, {
    type: "request",
    requestId: "start-turn-overrides-1",
    sourceClientId: "desktop",
    method: "thread-follower-start-turn",
    params: {
      conversationId: "thread-overrides",
      turnStartParams: {
        input: [{ type: "text", text: "use my desktop model" }],
      },
    },
  });
  const startResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "start-turn-overrides-1"
  );
  assert.equal(startResponse.resultType, "success");
  assert.deepEqual(codexRequests.filter((request) => request.method === "turn/start"), [{
    method: "turn/start",
    params: {
      threadId: "thread-overrides",
      input: [{ type: "text", text: "use my desktop model" }],
      model: "gpt-desktop-pick",
      effort: "high",
    },
  }]);
});

test("live owner refuses queued follow-ups instead of silently dropping them", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-queued-followups-");
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
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-queued", input: [] },
  }));
  await waitFor(() => serverSocket);

  writeFrame(serverSocket, {
    type: "request",
    requestId: "queued-followups-1",
    sourceClientId: "desktop",
    method: "thread-follower-set-queued-follow-ups-state",
    params: {
      conversationId: "thread-queued",
      queuedFollowUps: [{ input: [{ type: "text", text: "later" }] }],
    },
  });
  const response = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "queued-followups-1"
  );
  assert.equal(response.resultType, "error");
  assert.match(response.error, /not supported/i);
});

test("live owner keeps ownership when peer sends non-owner patch broadcasts", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-peer-patch-");
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
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-peer-patch", input: [] },
  }));
  await waitFor(() => serverSocket);

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-follower",
    version: 6,
    params: {
      conversationId: "thread-peer-patch",
      change: {
        type: "patches",
        patches: [{ op: "add", path: ["requests", 0], value: { id: "peer-request" } }],
      },
    },
  });
  await wait(25);

  writeFrame(serverSocket, {
    type: "request",
    requestId: "peer-patch-start-1",
    sourceClientId: "desktop",
    method: "thread-follower-start-turn",
    params: {
      conversationId: "thread-peer-patch",
      turnStartParams: {
        input: [{ type: "text", text: "still bridge-owned" }],
      },
    },
  });
  const response = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "peer-patch-start-1"
  );
  assert.equal(response.resultType, "success");
  assert.deepEqual(codexRequests.filter((request) => request.method === "turn/start").at(-1), {
    method: "turn/start",
    params: {
      threadId: "thread-peer-patch",
      input: [{ type: "text", text: "still bridge-owned" }],
    },
  });
});

test("live owner yields ownership when a peer sends an untagged snapshot", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-peer-snapshot-");
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
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-peer-snapshot", input: [] },
  }));
  await waitFor(() => serverSocket);

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-owner",
    version: 6,
    params: {
      conversationId: "thread-peer-snapshot",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);

  writeFrame(serverSocket, {
    type: "request",
    requestId: "peer-snapshot-start-1",
    sourceClientId: "desktop",
    method: "thread-follower-start-turn",
    params: {
      conversationId: "thread-peer-snapshot",
      turnStartParams: {
        input: [{ type: "text", text: "should not route" }],
      },
    },
  });
  const response = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "peer-snapshot-start-1"
  );
  assert.equal(response.resultType, "error");
  assert.equal(codexRequests.filter((request) => request.method === "turn/start").length, 0);
});

test("live owner drops cached conversation state when yielding to a peer owner", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-yield-state-");
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
    method: "turn/start",
    params: {
      threadId: "thread-yield-state",
      input: [{ type: "input_text", text: "first prompt" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-yield-state",
      turn: {
        id: "turn-stale",
        items: [],
        status: "inProgress",
        error: null,
        startedAt: 1,
        completedAt: null,
        durationMs: null,
      },
    },
  }));
  await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.params?.conversationId === "thread-yield-state"
      && frame.params?.change?.type === "snapshot"
  );

  // A peer owner claims the stream with an untagged snapshot.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-owner",
    version: 6,
    params: {
      conversationId: "thread-yield-state",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);
  assert.equal(owner._debugSnapshot("thread-yield-state"), null);

  // Re-claiming from the phone must rebuild fresh state, not republish turn-stale.
  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: {
      threadId: "thread-yield-state",
      input: [{ type: "input_text", text: "fresh prompt" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-yield-state",
      turn: {
        id: "turn-fresh",
        items: [],
        status: "inProgress",
        error: null,
        startedAt: 2,
        completedAt: null,
        durationMs: null,
      },
    },
  }));

  const reclaimBroadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.params?.conversationId === "thread-yield-state"
      && frame.params?.change?.type === "snapshot"
      && frame.params.change.conversationState.turns.some((turn) => turn.turnId === "turn-fresh")
  );
  const turnIds = reclaimBroadcast.params.change.conversationState.turns.map((turn) => turn.turnId);
  assert.deepEqual(turnIds, ["turn-fresh"]);
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

test("live owner replies to follower approvals with the original app-server id", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-approval-id-");
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
    snapshotDebounceMs: 1,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage(rawMessage) {
      rawCodexMessages.push(JSON.parse(rawMessage));
    },
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-approval-id", input: [] },
  }));
  // The app-server issued this pending approval with a numeric JSON-RPC id.
  owner.observeOutbound(JSON.stringify({
    id: 42,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: "thread-approval-id",
      turnId: "turn-approval-id",
      itemId: "item-approval-id",
      command: "git status",
    },
  }));
  await waitFor(() => serverSocket);

  // Desktop echoes the id back as a string.
  writeFrame(serverSocket, {
    type: "request",
    requestId: "approval-id-1",
    sourceClientId: "desktop",
    method: "thread-follower-command-approval-decision",
    params: {
      conversationId: "thread-approval-id",
      requestId: "42",
      decision: "accept",
    },
  });
  const response = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "approval-id-1"
  );
  assert.equal(response.resultType, "success");
  assert.deepEqual(rawCodexMessages.at(-1), {
    id: 42,
    result: { decision: "accept" },
  });
});

test("live owner pairs notification-only thread starts by requested cwd", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-start-cwd-");
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
    id: "start-a",
    method: "thread/start",
    params: { cwd: "/tmp/project-a" },
  }));

  // A thread/started from a different cwd must not consume the pending start.
  owner.observeOutbound(JSON.stringify({
    method: "thread/started",
    params: {
      thread: {
        id: "thread-other-cwd",
        cwd: "/tmp/project-other",
        createdAt: 1,
        updatedAt: 1,
        turns: [],
      },
    },
  }));
  await wait(50);
  assert.equal(
    frames.some((frame) => frame.type === "broadcast"
      && frame.params?.conversationId === "thread-other-cwd"),
    false
  );

  owner.observeOutbound(JSON.stringify({
    method: "thread/started",
    params: {
      thread: {
        id: "thread-matching-cwd",
        cwd: "/tmp/project-a",
        createdAt: 1,
        updatedAt: 1,
        turns: [],
      },
    },
  }));
  const broadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-matching-cwd"
      && frame.params?.change?.type === "snapshot"
  );
  assert.equal(broadcast.params.change.conversationState.id, "thread-matching-cwd");
});

test("live owner converts desktop permission approvals into grant payloads", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-permissions-");
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
    snapshotDebounceMs: 1,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage(rawMessage) {
      rawCodexMessages.push(JSON.parse(rawMessage));
    },
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-permissions", input: [] },
  }));
  owner.observeOutbound(JSON.stringify({
    id: "permission-request-1",
    method: "item/permissions/requestApproval",
    params: {
      threadId: "thread-permissions",
      turnId: "turn-permissions",
      itemId: "item-permissions",
      permissions: {
        network: { enabled: true },
      },
    },
  }));
  await waitFor(() => serverSocket);

  writeFrame(serverSocket, {
    type: "request",
    requestId: "permission-approval-1",
    sourceClientId: "desktop",
    method: "thread-follower-file-approval-decision",
    params: {
      conversationId: "thread-permissions",
      requestId: "permission-request-1",
      decision: "accept",
    },
  });
  const acceptResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "permission-approval-1"
  );
  assert.equal(acceptResponse.resultType, "success");
  assert.deepEqual(rawCodexMessages.at(-1), {
    id: "permission-request-1",
    result: {
      permissions: {
        network: { enabled: true },
      },
      scope: "turn",
    },
  });

  writeFrame(serverSocket, {
    type: "request",
    requestId: "permission-approval-2",
    sourceClientId: "desktop",
    method: "thread-follower-file-approval-decision",
    params: {
      conversationId: "thread-permissions",
      requestId: "permission-request-1",
      decision: "acceptForSession",
    },
  });
  const acceptForSessionResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "permission-approval-2"
  );
  assert.equal(acceptForSessionResponse.resultType, "success");
  assert.deepEqual(rawCodexMessages.at(-1), {
    id: "permission-request-1",
    result: {
      permissions: {
        network: { enabled: true },
      },
      scope: "session",
    },
  });

  writeFrame(serverSocket, {
    type: "request",
    requestId: "permission-approval-3",
    sourceClientId: "desktop",
    method: "thread-follower-file-approval-decision",
    params: {
      conversationId: "thread-permissions",
      requestId: "permission-request-1",
      decision: "decline",
    },
  });
  const declineResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "permission-approval-3"
  );
  assert.equal(declineResponse.resultType, "success");
  assert.deepEqual(rawCodexMessages.at(-1), {
    id: "permission-request-1",
    result: {
      permissions: {},
      scope: "turn",
    },
  });
});

test("conversation adapter streams fileChange output deltas into fileChange items", () => {
  const conversations = new Map();
  const owned = new Set(["thread-file-change"]);
  const now = () => 42;

  let update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/fileChange/outputDelta",
      params: {
        threadId: "thread-file-change",
        turnId: "turn-file-change",
        itemId: "item-file-change",
        delta: "diff --git a/a.txt",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-file-change", changed: true });

  update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/fileChange/outputDelta",
      params: {
        threadId: "thread-file-change",
        turnId: "turn-file-change",
        itemId: "item-file-change",
        delta: " b/a.txt",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-file-change", changed: true });

  const turn = conversations.get("thread-file-change").turns
    .find((candidate) => candidate.turnId === "turn-file-change");
  const item = turn.items.find((candidate) => candidate.id === "item-file-change");
  assert.equal(item.type, "fileChange");
  assert.equal(item.status, "inProgress");
  assert.equal(item.aggregatedOutput, "diff --git a/a.txt b/a.txt");
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

test("conversation adapter ignores thread started notifications for unowned threads", () => {
  const conversations = new Map();
  const owned = new Set();
  const update = applyAppServerMessageToConversationState({
    conversations,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "thread/started",
      params: {
        thread: {
          id: "thread-unowned-started",
          sessionId: "session-unowned-started",
          preview: "Desktop owned",
          turns: [],
        },
      },
    },
  });

  assert.equal(update, null);
  assert.equal(conversations.has("thread-unowned-started"), false);
});

test("conversation adapter replaces synthetic user prompt with canonical userMessage items", () => {
  const conversations = new Map();
  const pendingTurnStartParamsByThreadId = new Map([[
    "thread-canonical-user",
    [{
      params: {
        threadId: "thread-canonical-user",
        input: [{ type: "input_text", text: "build the canonical path" }],
        cwd: "/tmp/canonical-user",
      },
    }],
  ]]);
  const owned = new Set(["thread-canonical-user"]);
  const now = () => 42;

  let update = applyAppServerMessageToConversationState({
    conversations,
    pendingTurnStartParamsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-canonical-user",
        turn: {
          id: "turn-canonical-user",
          items: [],
          status: "inProgress",
          error: null,
          startedAt: 1,
        },
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-canonical-user", changed: true });
  assert.deepEqual(
    conversations.get("thread-canonical-user").turns[0].items.map((item) => item.id),
    ["user-message-turn-canonical-user"]
  );

  // A reasoning item streams in before the canonical user message arrives.
  update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/started",
      params: {
        threadId: "thread-canonical-user",
        turnId: "turn-canonical-user",
        item: {
          id: "reasoning-1",
          type: "reasoning",
          summary: [],
          content: [],
        },
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-canonical-user", changed: true });

  update = applyAppServerMessageToConversationState({
    conversations,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/started",
      params: {
        threadId: "thread-canonical-user",
        turnId: "turn-canonical-user",
        item: {
          id: "canonical-user-message",
          type: "userMessage",
          content: [{ type: "text", text: "build the canonical path" }],
        },
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-canonical-user", changed: true });
  // The canonical user message replaces the synthetic row in place, keeping the
  // prompt above the already-streamed reasoning item.
  assert.deepEqual(
    conversations.get("thread-canonical-user").turns[0].items.map((item) => item.id),
    ["canonical-user-message", "reasoning-1"]
  );
  const userMessages = conversations.get("thread-canonical-user").turns[0].items
    .filter((item) => item.type === "userMessage");
  assert.deepEqual(userMessages, [{
    id: "canonical-user-message",
    type: "userMessage",
    content: [{ type: "text", text: "build the canonical path" }],
  }]);
});

test("conversation adapter dedupes synthetic user prompt after fallback turn id promotion", () => {
  const conversations = new Map();
  const fallbackTurnIdsByThreadId = new Map();
  const pendingTurnStartParamsByThreadId = new Map([[
    "thread-promoted-user",
    [{
      params: {
        threadId: "thread-promoted-user",
        input: [{ type: "input_text", text: "prompt before promotion" }],
      },
    }],
  ]]);
  const owned = new Set(["thread-promoted-user"]);
  const now = () => 7;

  // turn/started arrives without a usable turn id, so the turn and the synthetic
  // user message are created under a fallback turn id.
  applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    pendingTurnStartParamsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-promoted-user",
        turn: {
          items: [],
          status: "inProgress",
          error: null,
          startedAt: 1,
        },
      },
    },
  });
  const syntheticItems = conversations.get("thread-promoted-user").turns[0].items;
  assert.equal(syntheticItems.length, 1);
  assert.equal(syntheticItems[0].type, "userMessage");

  // A later event promotes the fallback turn to its real id, then the canonical
  // user message arrives; the synthetic row must still be replaced.
  applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/started",
      params: {
        threadId: "thread-promoted-user",
        turnId: "turn-promoted-real",
        item: {
          id: "canonical-promoted-user-message",
          type: "userMessage",
          content: [{ type: "text", text: "prompt before promotion" }],
        },
      },
    },
  });

  const turn = conversations.get("thread-promoted-user").turns[0];
  assert.equal(turn.turnId, "turn-promoted-real");
  const userMessages = turn.items.filter((item) => item.type === "userMessage");
  assert.deepEqual(userMessages, [{
    id: "canonical-promoted-user-message",
    type: "userMessage",
    content: [{ type: "text", text: "prompt before promotion" }],
  }]);
});

test("conversation adapter consumes pending turn starts FIFO for rapid consecutive turns", () => {
  const conversations = new Map();
  const pendingTurnStartParamsByThreadId = new Map([[
    "thread-fifo",
    [
      { params: { threadId: "thread-fifo", input: [{ type: "input_text", text: "first prompt" }] } },
      { params: { threadId: "thread-fifo", input: [{ type: "input_text", text: "second prompt" }] } },
    ],
  ]]);
  const owned = new Set(["thread-fifo"]);
  const now = () => 11;

  for (const turnId of ["turn-fifo-1", "turn-fifo-2"]) {
    applyAppServerMessageToConversationState({
      conversations,
      pendingTurnStartParamsByThreadId,
      now,
      shouldOwnThread: (threadId) => owned.has(threadId),
      message: {
        method: "turn/started",
        params: {
          threadId: "thread-fifo",
          turn: {
            id: turnId,
            items: [],
            status: "inProgress",
            error: null,
            startedAt: 1,
          },
        },
      },
    });
  }

  const turns = conversations.get("thread-fifo").turns;
  assert.deepEqual(
    turns.map((turn) => turn.items[0].content[0].text),
    ["first prompt", "second prompt"]
  );
  assert.equal(pendingTurnStartParamsByThreadId.has("thread-fifo"), false);
});

test("conversation adapter keeps a stable fallback turn until a real turn id arrives", () => {
  const conversations = new Map();
  const fallbackTurnIdsByThreadId = new Map();
  const owned = new Set(["thread-turnless"]);
  let timestamp = 100;
  const now = () => {
    timestamp += 1;
    return timestamp;
  };

  let update = applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "turn/started",
      params: {
        threadId: "thread-turnless",
        turn: {
          items: [],
          status: "inProgress",
          error: null,
          startedAt: 1,
        },
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-turnless", changed: true });
  const syntheticTurnId = conversations.get("thread-turnless").turns[0].turnId;
  assert.match(syntheticTurnId, /^remodex-live-turn:thread-turnless:/);

  update = applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/agentMessage/delta",
      params: {
        threadId: "thread-turnless",
        itemId: "assistant-turnless",
        delta: "Hello",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-turnless", changed: true });
  assert.equal(conversations.get("thread-turnless").turns.length, 1);
  assert.equal(conversations.get("thread-turnless").turns[0].items[0].text, "Hello");

  update = applyAppServerMessageToConversationState({
    conversations,
    fallbackTurnIdsByThreadId,
    now,
    shouldOwnThread: (threadId) => owned.has(threadId),
    message: {
      method: "item/agentMessage/delta",
      params: {
        threadId: "thread-turnless",
        turnId: "turn-real",
        itemId: "assistant-turnless",
        delta: " world",
      },
    },
  });
  assert.deepEqual(update, { threadId: "thread-turnless", changed: true });
  const turns = conversations.get("thread-turnless").turns;
  assert.equal(turns.length, 1);
  assert.equal(turns[0].turnId, "turn-real");
  assert.equal(turns[0].items[0].text, "Hello world");
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
