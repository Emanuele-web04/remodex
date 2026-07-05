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
