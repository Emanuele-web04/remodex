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
  buildConversationStateFromThread,
  createDesktopIpcLiveOwner,
} = require("../src/desktop-ipc-live-owner");
const {
  applyAppServerMessageToConversationState,
} = require("../src/desktop-ipc-conversation-adapter");

test("conversation adapter ignores empty plan updates but keeps explanation-only updates", () => {
  const threadId = "thread-plan-visibility";
  const turnId = "turn-plan-visibility";
  const conversations = new Map();
  const apply = (message) => applyAppServerMessageToConversationState({
    conversations,
    message,
    shouldOwnThread: (candidate) => candidate === threadId,
    now: () => 1_000,
  });

  apply({
    method: "thread/started",
    params: {
      thread: {
        id: threadId,
        cwd: "/tmp/project",
        turns: [{ id: turnId, status: "inProgress", items: [] }],
      },
    },
  });

  const emptyUpdate = apply({
    method: "turn/plan/updated",
    params: { threadId, turnId, plan: [] },
  });
  assert.deepEqual(emptyUpdate, { threadId, changed: false });
  assert.deepEqual(conversations.get(threadId).turns[0].items, []);

  const explanationUpdate = apply({
    method: "turn/plan/updated",
    params: { threadId, turnId, explanation: "Keep the last meaningful plan visible.", plan: [] },
  });
  assert.deepEqual(explanationUpdate, { threadId, changed: true });
  assert.equal(conversations.get(threadId).turns[0].items.length, 1);
  assert.equal(
    conversations.get(threadId).turns[0].items[0].explanation,
    "Keep the last meaningful plan visible."
  );
  assert.equal(
    conversations.get(threadId).turns[0].items[0].remodexProgressPlan,
    true
  );
});

test("conversation adapter mirrors phone auto-approval review lifecycle into Desktop state", () => {
  const threadId = "thread-review-owner";
  const turnId = "turn-review-owner";
  const conversations = new Map();
  const apply = (message) => applyAppServerMessageToConversationState({
    conversations,
    message,
    shouldOwnThread: (candidate) => candidate === threadId,
    now: () => 1_000,
  });
  apply({
    method: "thread/started",
    params: { thread: { id: threadId, turns: [{ id: turnId, status: "inProgress", items: [] }] } },
  });

  apply({
    method: "item/autoApprovalReview/started",
    params: {
      threadId,
      turnId,
      reviewId: "review-owner-1",
      startedAtMs: 100,
      review: { status: "inProgress", riskLevel: null, userAuthorization: null, rationale: null },
      action: { type: "command", command: "git status", cwd: "/repo" },
    },
  });
  apply({
    method: "item/autoApprovalReview/completed",
    params: {
      threadId,
      turnId,
      reviewId: "review-owner-1",
      startedAtMs: 100,
      completedAtMs: 200,
      decisionSource: "agent",
      review: { status: "denied", riskLevel: "high", userAuthorization: "low", rationale: "Risky" },
      action: { type: "command", command: "git status", cwd: "/repo" },
    },
  });

  const items = conversations.get(threadId).turns[0].items;
  assert.equal(items.length, 1);
  assert.equal(items[0].id, "automatic-approval-review:review-owner-1");
  assert.equal(items[0].status, "denied");
  assert.equal(items[0].remodexGuardianRetrySupported, false);
});

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
  assert.equal(broadcast.version, 11);
  assert.equal(broadcast.params.version, 11);
  assert.equal(broadcast.params.conversationId, "thread-live-owner");
    assert.equal(broadcast.params.remodexOwnerSource, "desktop-ipc-live-owner");
  assert.equal(broadcast.params.change.type, "snapshot");
  assert.equal(broadcast.params.change.conversationState.id, "thread-live-owner");
  assert.equal(broadcast.params.change.conversationState.turns[0].turnId, "turn-live-owner");
  assert.equal(broadcast.params.change.conversationState.turns[0].items[0].text, "Hello");
});

test("live owner confirms Desktop follow handshakes and sends an immediate baseline", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-follow-");
  const frames = [];
  const followerChanges = [];
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
          result: { clientId: "remodex-owner-follow" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    snapshotDebounceMs: 1,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
    onFollowerStateChanged(threadId, following) {
      followerChanges.push({ threadId, following });
    },
  });
  t.after(() => {
    owner.stopAll();
    server.close();
    serverSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  owner.observeInbound(JSON.stringify({
    id: "thread-follow-start",
    method: "thread/start",
    params: {
      cwd: "/tmp/project",
    },
  }));
  owner.observeOutbound(JSON.stringify({
    id: "thread-follow-start",
    result: {
      thread: {
        id: "thread-follow-handshake",
        sessionId: "thread-follow-handshake",
        preview: "hello",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 1,
        status: { type: "idle" },
        cwd: "/tmp/project",
        turns: [],
      },
    },
  }));
  await waitForMessage(frames, (frame) => frame.method === "initialize");
  await waitForMessage(
    frames,
    (frame) => frame.method === "thread-stream-following-status-requested"
      && frame.params?.conversationId === "thread-follow-handshake"
  );

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-following-changed",
    sourceClientId: "desktop-follower",
    version: 1,
    params: {
      hostId: "local",
      conversationId: "thread-follow-handshake",
      following: true,
    },
  });

  await waitFor(() => followerChanges.length === 1);
  assert.deepEqual(followerChanges, [{
    threadId: "thread-follow-handshake",
    following: true,
  }]);
  await waitForMessage(
    frames,
    (frame) => frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-follow-handshake"
  );

  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-following-changed",
    sourceClientId: "desktop-follower",
    version: 1,
    params: {
      hostId: "local",
      conversationId: "thread-follow-handshake",
      following: false,
    },
  });

  await waitFor(() => followerChanges.length === 2);
  assert.deepEqual(followerChanges[1], {
    threadId: "thread-follow-handshake",
    following: false,
  });
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
  assert.equal(turnPatchBroadcast.version, 11);
  assert.equal(turnPatchBroadcast.params.version, 11);

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
  assert.equal(snapshot.version, 11);
  assert.equal(snapshot.params.version, 11);
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
        approvalPolicy: "on-request",
        approvalsReviewer: "auto_review",
        sandboxPolicy: {
          type: "workspaceWrite",
          networkAccess: true,
        },
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
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      sandboxPolicy: {
        type: "workspaceWrite",
        networkAccess: true,
      },
    },
  }]);
});

test("live owner replays a pending sidebar announcement when Desktop joins its fallback router", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-sidebar-replay-");
  const desktopFrames = [];
  let desktopSocket = null;

  const owner = createDesktopIpcLiveOwner({
    socketPath,
    sidebarRefreshDelayMs: 5,
    snapshotDebounceMs: 1,
    reconnectMs: 10,
    requestTimeoutMs: 500,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
  });
  t.after(() => {
    owner.stopAll();
    desktopSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: {
      threadId: "thread-sidebar-replay",
      input: [],
    },
  }));

  await waitFor(() => fs.existsSync(socketPath));
  // Let the first announcement attempt run while only the bridge-owned router
  // is present. It must remain pending rather than count that write as delivery.
  await wait(30);
  owner.observeInbound(JSON.stringify({
    method: "thread/unsubscribe",
    params: { threadId: "thread-sidebar-replay" },
  }));
  assert.equal(
    owner.isThreadOwned("thread-sidebar-replay"),
    false,
    "sidebar metadata must outlive released stream ownership"
  );

  desktopSocket = net.createConnection(socketPath);
  attachFrameReader(desktopSocket, (frame) => desktopFrames.push(frame));
  await new Promise((resolve) => desktopSocket.once("connect", resolve));
  writeFrame(desktopSocket, {
    type: "request",
    requestId: "desktop-sidebar-replay-init",
    sourceClientId: "initializing-client",
    version: 1,
    method: "initialize",
    params: { clientType: "vscode" },
  });
  await waitFor(() => desktopFrames.some(
    (frame) => frame.type === "response"
      && frame.requestId === "desktop-sidebar-replay-init"
  ));

  const announcement = await waitForMessage(
    desktopFrames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-unarchived"
      && frame.params?.conversationId === "thread-sidebar-replay"
  );
  assert.equal(announcement.version, 1);
  assert.equal(announcement.params.hostId, "local");
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
    sendCodexRequest: async (method) => {
      if (method === "thread/read") {
        return {
          thread: {
            id: "thread-user-input",
            cwd: "/tmp/user-input",
            turns: [],
          },
        };
      }
      return { ok: true };
    },
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
      && frame.params.change.conversationState.turns?.[0]?.turnId === "turn-user-input"
  );
  const turn = broadcast.params.change.conversationState.turns[0];
  assert.equal(turn.turnId, "turn-user-input");
  // Desktop renders the user bubble from params.input; a duplicate userMessage
  // item would be labelled "Steered conversation", so items must stay empty.
  assert.deepEqual(turn.params.input, [{ type: "input_text", text: "build the feature" }]);
  assert.deepEqual(turn.items, []);
});

test("live owner broadcasts phone image turns before turn/started arrives", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-image-pending-");
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
    sendCodexRequest: async (method) => {
      if (method === "thread/read") {
        return {
          thread: {
            id: "thread-image-pending",
            cwd: "/tmp/image-pending",
            turns: [],
          },
        };
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });
  const imageDataURL = `data:image/jpeg;base64,${Buffer.from("fake-image").toString("base64")}`;

  owner.observeInbound(JSON.stringify({
    id: "turn-start-image-pending",
    method: "turn/start",
    params: {
      threadId: "thread-image-pending",
      cwd: "/tmp/image-pending",
      input: [
        { type: "text", text: "look at this" },
        { type: "image", url: imageDataURL },
      ],
    },
  }));

  const pendingSnapshot = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-image-pending"
      && frame.params?.change?.type === "snapshot"
      && frame.params.change.conversationState.turns.length === 1
  );
  const pendingTurn = pendingSnapshot.params.change.conversationState.turns[0];
  assert.match(pendingTurn.turnId, /^remodex-pending-turn:/);
  assert.equal(pendingTurn.remodexOptimisticPendingTurn, true);
  assert.deepEqual(pendingTurn.params.input, [
    { type: "text", text: "look at this" },
    { type: "image", url: imageDataURL },
  ]);
  assert.deepEqual(pendingTurn.items, []);

  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-image-pending",
      turn: {
        id: "turn-image-pending",
        items: [],
        status: "inProgress",
        startedAt: 2,
      },
    },
  }));

  await waitFor(() => owner._debugSnapshot("thread-image-pending")?.turns?.[0]?.turnId === "turn-image-pending");
  const promotedState = owner._debugSnapshot("thread-image-pending");
  assert.equal(promotedState.turns.length, 1);
  assert.equal(promotedState.turns[0].remodexOptimisticPendingTurn, undefined);
  assert.deepEqual(promotedState.turns[0].params.input, pendingTurn.params.input);
});

test("live owner withholds optimistic image turns on IPC connect during initial hydration", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("rlo-image-connect-");
  const frames = [];
  let serverSocket = null;
  let initializeFrame = null;

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      frames.push(frame);
      if (frame.method === "initialize") {
        initializeFrame = frame;
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
    sendCodexRequest: async (method) => {
      if (method === "thread/read") {
        return new Promise(() => {});
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });
  const imageDataURL = `data:image/png;base64,${Buffer.from("connect-image").toString("base64")}`;

  owner.observeInbound(JSON.stringify({
    id: "turn-start-image-connect",
    method: "turn/start",
    params: {
      threadId: "thread-image-connect",
      cwd: "/tmp/image-connect",
      input: [
        { type: "text", text: "show immediately on reconnect" },
        { type: "image", url: imageDataURL },
      ],
    },
  }));

  await waitFor(() => initializeFrame && serverSocket);
  writeFrame(serverSocket, {
    type: "response",
    requestId: initializeFrame.requestId,
    resultType: "success",
    method: "initialize",
    handledByClientId: "router",
    result: { clientId: "remodex-owner-test" },
  });

  await wait(25);
  assert.equal(
    frames.some((frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-image-connect"),
    false
  );
});

test("live owner promotes rapid pending turns in FIFO order", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-pending-fifo-");
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
    id: "turn-start-fifo-1",
    method: "turn/start",
    params: {
      threadId: "thread-pending-fifo",
      input: [{ type: "text", text: "first" }],
    },
  }));
  owner.observeInbound(JSON.stringify({
    id: "turn-start-fifo-2",
    method: "turn/start",
    params: {
      threadId: "thread-pending-fifo",
      input: [{ type: "text", text: "second" }],
    },
  }));

  await waitFor(() => owner._debugSnapshot("thread-pending-fifo")?.turns?.length === 2);
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-pending-fifo",
      turn: { id: "turn-fifo-1", items: [], status: "inProgress", startedAt: 1 },
    },
  }));

  await waitFor(() => owner._debugSnapshot("thread-pending-fifo")?.turns?.[0]?.turnId === "turn-fifo-1");
  let turns = owner._debugSnapshot("thread-pending-fifo").turns;
  assert.equal(turns.length, 2);
  assert.equal(turns[0].params.input[0].text, "first");
  assert.match(turns[1].turnId, /^remodex-pending-turn:/);
  assert.equal(turns[1].params.input[0].text, "second");

  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-pending-fifo",
      turn: { id: "turn-fifo-2", items: [], status: "inProgress", startedAt: 2 },
    },
  }));

  await waitFor(() => owner._debugSnapshot("thread-pending-fifo")?.turns?.[1]?.turnId === "turn-fifo-2");
  turns = owner._debugSnapshot("thread-pending-fifo").turns;
  assert.deepEqual(turns.map((turn) => turn.turnId), ["turn-fifo-1", "turn-fifo-2"]);
  assert.deepEqual(turns.map((turn) => turn.params.input[0].text), ["first", "second"]);
});

test("live owner promotes rapid turn-less pending starts in FIFO order", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("rlo-turnless-fifo-");
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
    id: "turnless-start-fifo-1",
    method: "turn/start",
    params: {
      threadId: "thread-turnless-pending-fifo",
      input: [{ type: "text", text: "first turnless" }],
    },
  }));
  owner.observeInbound(JSON.stringify({
    id: "turnless-start-fifo-2",
    method: "turn/start",
    params: {
      threadId: "thread-turnless-pending-fifo",
      input: [{ type: "text", text: "second turnless" }],
    },
  }));

  await waitFor(() => owner._debugSnapshot("thread-turnless-pending-fifo")?.turns?.length === 2);
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-turnless-pending-fifo",
      turn: { items: [], status: "inProgress", startedAt: 1 },
    },
  }));

  await waitFor(() => {
    const turns = owner._debugSnapshot("thread-turnless-pending-fifo")?.turns || [];
    return turns[0]?.params?.input?.[0]?.text === "first turnless"
      && turns[1]?.params?.input?.[0]?.text === "second turnless";
  });

  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-turnless-pending-fifo",
      turn: { items: [], status: "inProgress", startedAt: 2 },
    },
  }));

  await waitFor(() => {
    const turns = owner._debugSnapshot("thread-turnless-pending-fifo")?.turns || [];
    return turns.length === 2
      && turns.every((turn) => !turn.remodexOptimisticPendingTurn)
      && turns[0].params.input[0].text === "first turnless"
      && turns[1].params.input[0].text === "second turnless";
  });
  const turns = owner._debugSnapshot("thread-turnless-pending-fifo").turns;
  assert.notEqual(turns[0].turnId, turns[1].turnId);
  assert.deepEqual(turns.map((turn) => turn.params.input[0].text), [
    "first turnless",
    "second turnless",
  ]);
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
    params: {
      threadId: "thread-hydrate",
      includeTurns: true,
    },
  });
  assert.equal(
    frames.some((frame) => (
      frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
    )),
    false
  );

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

test("live owner hydrates unknown threads before prompt-less owner actions publish", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-hydrate-compact-");
  const frames = [];
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
    sendCodexRequest() {
      return new Promise((resolve) => {
        resolveThreadRead = resolve;
      });
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "compact-hydrate",
    method: "thread/compact/start",
    params: { threadId: "thread-hydrate-compact" },
  }));

  await waitFor(() => resolveThreadRead != null);
  await wait(25);
  assert.equal(
    frames.some((frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-hydrate-compact"),
    false
  );

  resolveThreadRead({
    thread: {
      id: "thread-hydrate-compact",
      turns: [{
        id: "turn-existing",
        items: [{
          id: "assistant-existing",
          type: "agentMessage",
          text: "Existing content survives compaction startup",
        }],
        status: "completed",
        startedAt: 1,
        completedAt: 2,
      }],
    },
  });

  const broadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-hydrate-compact"
      && frame.params?.change?.type === "snapshot"
  );
  assert.equal(
    broadcast.params.change.conversationState.turns[0].items[0].text,
    "Existing content survives compaction startup"
  );
});

test("live owner does not publish partial existing-thread snapshots when hydration fails", async (t) => {
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

  await wait(25);
  assert.equal(
    frames.some((frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-hydrate-fail"),
    false
  );
});

test("live owner retries failed initial hydration without another owner event", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-hydrate-retry-");
  const frames = [];
  let serverSocket = null;
  let readAttempts = 0;

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
    initialHistoryRetryMs: 5,
    async sendCodexRequest(method) {
      if (method !== "thread/read") {
        return { ok: true };
      }
      readAttempts += 1;
      if (readAttempts === 1) {
        throw new Error("first read failed");
      }
      return {
        thread: {
          id: "thread-hydrate-retry",
          sessionId: "session-hydrate-retry",
          preview: "Hydrate retry",
          ephemeral: false,
          modelProvider: "openai",
          createdAt: 1,
          updatedAt: 2,
          status: { type: "idle" },
          path: null,
          cwd: "/tmp/hydrate-retry",
          cliVersion: "test",
          source: "app-server",
          threadSource: null,
          gitInfo: null,
          name: "Hydrated retry thread",
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
      };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "turn-start-hydrate-retry",
    method: "turn/start",
    params: {
      threadId: "thread-hydrate-retry",
      cwd: "/tmp/hydrate-retry",
      input: [{ type: "input_text", text: "continue" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-hydrate-retry",
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
      && frame.params?.conversationId === "thread-hydrate-retry"
      && frame.params?.change?.type === "snapshot",
    500
  );
  const state = broadcast.params.change.conversationState;
  assert.equal(readAttempts, 2);
  assert.equal(state.turns.length, 2);
  assert.equal(state.turns[0].turnId, "turn-old");
  assert.equal(state.turns[1].turnId, "turn-new");
});

test("live owner releases ownership after bounded initial hydration failures", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-hydrate-bounded-");
  const frames = [];
  let serverSocket = null;
  let readAttempts = 0;

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
    initialHistoryRetryMs: 5,
    initialHistoryMaxAttempts: 2,
    async sendCodexRequest(method) {
      if (method === "thread/read") {
        readAttempts += 1;
        throw new Error("thread is permanently unavailable");
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "compact-hydrate-bounded",
    method: "thread/compact/start",
    params: { threadId: "thread-hydrate-bounded" },
  }));

  await waitFor(() => readAttempts === 2);
  await waitFor(() => !owner.isThreadOwned("thread-hydrate-bounded"), 500);
  const attemptsAfterRelease = readAttempts;
  await wait(25);

  assert.equal(readAttempts, attemptsAfterRelease);
  assert.equal(
    frames.some((frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-hydrate-bounded"),
    false
  );
});

test("live owner cancels initial hydration when the originating turn is rejected", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-hydrate-rejected-");
  let serverSocket = null;
  let readAttempts = 0;

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
    initialHistoryRetryMs: 5,
    async sendCodexRequest(method) {
      if (method === "thread/read") {
        readAttempts += 1;
        throw new Error("thread not found");
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "turn-start-hydrate-rejected",
    method: "turn/start",
    params: {
      threadId: "thread-hydrate-rejected",
      input: [{ type: "input_text", text: "will fail" }],
    },
  }));
  await waitFor(() => readAttempts === 1);
  owner.observeOutbound(JSON.stringify({
    id: "turn-start-hydrate-rejected",
    error: { code: -32000, message: "thread not found" },
  }));

  await waitFor(() => !owner.isThreadOwned("thread-hydrate-rejected"));
  await wait(25);
  assert.equal(readAttempts, 1);
});

test("live owner handles discovery and start-turn follower requests for owned threads", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-follower-");
  const codexRequests = [];
  const appNotifications = [];
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
      assert.equal(appNotifications.length, 0);
      return {
        turn: {
          id: "turn-from-follower",
          status: "inProgress",
        },
      };
    },
    sendApplicationResponse(message) {
      appNotifications.push(JSON.parse(message));
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
        input: [
          { type: "text", text: "# AGENTS.md instructions for /tmp/project\n<INSTRUCTIONS>rules</INSTRUCTIONS>" },
          { type: "input_text", text: "continue" },
        ],
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
  // Desktop's follower reads response.result.turn off the { result } wrapper its
  // own owner handler produces; the raw turn/start result would make it read
  // `.turn` on undefined ("Error creating task").
  assert.deepEqual(response.result, {
    result: {
      turn: {
        id: "turn-from-follower",
        status: "inProgress",
      },
    },
  });
  assert.deepEqual(codexRequests.filter((request) => request.method === "turn/start"), [{
    method: "turn/start",
    params: {
      threadId: "thread-owned",
      input: [
        { type: "text", text: "# AGENTS.md instructions for /tmp/project\n<INSTRUCTIONS>rules</INSTRUCTIONS>" },
        { type: "input_text", text: "continue" },
      ],
      model: "gpt-test",
    },
  }]);
  assert.equal(appNotifications.length, 1);
  assert.equal(appNotifications[0].method, "codex/event/user_message");
  assert.equal(appNotifications[0].params.threadId, "thread-owned");
  assert.equal(appNotifications[0].params.turnId, "turn-from-follower");
  // The synthetic prompt identity must match the conversation projector's
  // "<turnId>:input" scheme so the phone can dedupe later projected mirrors.
  assert.equal(appNotifications[0].params.id, "turn-from-follower:input");
  assert.equal(appNotifications[0].params.message, "continue");
  assert.equal(appNotifications[0].params.remodexDesktopMirror, true);
  assert.equal(appNotifications[0].params.remodexDesktopIpcMirror, true);
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
  writeFrame(serverSocket, {
    type: "request",
    requestId: "start-held-dedupe-late",
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
  const lateResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "start-held-dedupe-late"
  );
  assert.equal(lateResponse.resultType, "success");
  assert.equal(owner._debugSnapshot("thread-held-dedupe").turns.length, 1);
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
    sendCodexRequest: async (method) => {
      if (method === "thread/read") {
        return { thread: { id: "thread-archive-remove", cwd: "/tmp/archive-remove", turns: [] } };
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "turn-start-archive-remove",
    method: "turn/start",
    params: {
      threadId: "thread-archive-remove",
      cwd: "/tmp/archive-remove",
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
  assert.equal(archived.params.cwd, "/tmp/archive-remove");

  const removed = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-archive-remove"
      && frame.params?.remodexOwnerReleased === true
  );
  assert.equal(removed.params.remodexOwnerSource, "desktop-ipc-live-owner");
  assert.equal(removed.params.version, 11);
  assert.equal(removed.params.change.type, "snapshot");
  assert.deepEqual(removed.params.change.conversationState.turns, []);
  assert.deepEqual(removed.params.change.conversationState.requests, []);
  assert.equal(removed.params.change.conversationState.archived, true);
  assert.equal(removed.params.change.conversationState.remodexRemoved, true);
  assert.equal(owner._debugSnapshot("thread-archive-remove"), null);
});

test("live owner broadcasts phone archive requests for unowned threads over Desktop IPC", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-archive-unowned-");
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
    id: "archive-thread-unowned",
    method: "thread/archive",
    params: {
      threadId: "thread-archive-unowned",
      cwd: "/tmp/unowned",
    },
  }));

  const archived = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-archived"
      && frame.params?.conversationId === "thread-archive-unowned"
  );
  assert.equal(archived.version, 2);
  assert.equal(archived.params.hostId, "local");
  assert.equal(archived.params.cwd, "/tmp/unowned");
  assert.equal(owner._debugSnapshot("thread-archive-unowned"), null);
});

test("live owner broadcasts phone unarchive requests over Desktop IPC", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-unarchive-");
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
    id: "unarchive-thread-live-owner",
    method: "thread/unarchive",
    params: { threadId: "thread-unarchive-live-owner" },
  }));

  const unarchived = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-unarchived"
      && frame.params?.conversationId === "thread-unarchive-live-owner"
  );
  assert.equal(unarchived.version, 1);
  assert.equal(unarchived.params.hostId, "local");
});

test("live owner flushes only the final archive metadata state after IPC connects", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-archive-order-");
  const frames = [];
  let serverSocket = null;
  let initializeRequestId = "";

  const server = net.createServer((socket) => {
    serverSocket = socket;
    attachFrameReader(socket, (frame) => {
      frames.push(frame);
      if (frame.method === "initialize") {
        initializeRequestId = frame.requestId;
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
    id: "archive-thread-order",
    method: "thread/archive",
    params: { threadId: "thread-archive-order" },
  }));
  owner.observeInbound(JSON.stringify({
    id: "unarchive-thread-order",
    method: "thread/unarchive",
    params: { threadId: "thread-archive-order" },
  }));

  await waitFor(() => serverSocket && initializeRequestId);
  writeFrame(serverSocket, {
    type: "response",
    requestId: initializeRequestId,
    resultType: "success",
    method: "initialize",
    handledByClientId: "router",
    result: { clientId: "remodex-owner-test" },
  });

  const unarchived = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-unarchived"
      && frame.params?.conversationId === "thread-archive-order"
  );
  assert.equal(unarchived.params.hostId, "local");

  await wait(25);
  const archiveBroadcasts = frames.filter((frame) => frame.type === "broadcast"
    && frame.method === "thread-archived"
    && frame.params?.conversationId === "thread-archive-order");
  assert.equal(archiveBroadcasts.length, 0);
});

test("live owner yields ownership when a peer archives an owned thread", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-peer-archive-");
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
    sendCodexRequest: async (method) => {
      if (method === "thread/read") {
        return { thread: { id: "thread-peer-archive", turns: [] } };
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "turn-start-peer-archive",
    method: "turn/start",
    params: {
      threadId: "thread-peer-archive",
      input: [{ type: "input_text", text: "work before archive" }],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-peer-archive",
      turn: {
        id: "turn-peer-archive",
        items: [],
        status: "inProgress",
        startedAt: 1,
      },
    },
  }));

  await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-peer-archive"
      && frame.params?.change?.type === "snapshot"
  );

  writeFrame(serverSocket, {
    type: "broadcast",
    sourceClientId: "desktop-peer",
    method: "thread-archived",
    version: 2,
    params: {
      hostId: "desktop",
      conversationId: "thread-peer-archive",
    },
  });

  await waitFor(() => owner._debugSnapshot("thread-peer-archive") === null);
  assert.equal(owner._debugSnapshot("thread-peer-archive"), null);
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
    runtimeSettingsStore: {
      get(threadId) {
        return threadId === "thread-overrides"
          ? { model: "gpt-persisted", reasoningEffort: "medium", serviceTier: "fast" }
          : null;
      },
      commit() {
        return null;
      },
      attachToConversation() {},
    },
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
      serviceTier: "fast",
    },
  }]);
});

test("live owner serves follower load-complete-history with a fresh snapshot revision", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-load-history-");
  const frames = [];
  const codexRequests = [];
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
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      if (method === "thread/read") {
        return {
          thread: {
            id: params.threadId,
            name: "History thread",
            cwd: "/tmp/history",
            turns: [{
              id: "turn-history-1",
              status: "completed",
              items: [{ id: "assistant-history", type: "agentMessage", text: "done earlier" }],
              startedAt: 1,
            }],
          },
        };
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "history-turn-1",
    method: "turn/start",
    params: {
      threadId: "thread-history",
      input: [{ type: "text", text: "continue" }],
    },
  }));
  await waitFor(() => serverSocket);

  writeFrame(serverSocket, {
    type: "request",
    requestId: "load-history-1",
    sourceClientId: "desktop",
    version: 1,
    method: "thread-follower-load-complete-history",
    params: { conversationId: "thread-history" },
  });

  const response = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "load-history-1"
  );
  assert.equal(response.resultType, "success");
  assert.equal(typeof response.result.revision, "number");
  assert.ok(codexRequests.some((request) => (
    request.method === "thread/read"
    && request.params?.threadId === "thread-history"
    && request.params?.includeTurns === true
  )));

  // The snapshot carrying that revision must have been broadcast, complete
  // with hydrated history, so the Desktop follower can render it.
  const snapshot = frames.find((frame) => (
    frame.type === "broadcast"
    && frame.method === "thread-stream-state-changed"
    && frame.params?.conversationId === "thread-history"
    && frame.params?.change?.type === "snapshot"
    && frame.params?.change?.revision === response.result.revision
  ));
  assert.ok(snapshot, "expected snapshot broadcast with the returned revision");
  assert.equal(snapshot.params.hostId, "local");
  assert.equal(snapshot.version, 11);
  const turnIds = snapshot.params.change.conversationState.turns.map((turn) => turn.turnId);
  assert.ok(turnIds.includes("turn-history-1"));
});

test("live owner applies Desktop thread settings and broadcasts phone read state", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-settings-read-");
  const frames = [];
  const codexRequests = [];
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
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      if (method === "thread/read") {
        return { thread: { id: "thread-settings", turns: [] } };
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "settings-turn-1",
    method: "turn/start",
    params: { threadId: "thread-settings", input: [{ type: "text", text: "hi" }] },
  }));
  await waitFor(() => serverSocket);

  // Desktop updates the thread settings for the followed conversation.
  writeFrame(serverSocket, {
    type: "request",
    requestId: "update-settings-1",
    sourceClientId: "desktop",
    version: 1,
    method: "thread-follower-update-thread-settings",
    params: {
      conversationId: "thread-settings",
      threadSettings: {
        model: "gpt-desktop-settings",
        effort: "high",
        serviceTier: "fast",
      },
    },
  });
  const settingsResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "update-settings-1"
  );
  assert.equal(settingsResponse.resultType, "success");

  const settingsSnapshot = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-settings"
      && JSON.stringify(frame.params?.change ?? {}).includes("gpt-desktop-settings")
  );
  assert.ok(settingsSnapshot);

  // The next Desktop-origin turn inherits the settings.
  writeFrame(serverSocket, {
    type: "request",
    requestId: "settings-start-1",
    sourceClientId: "desktop",
    version: 1,
    method: "thread-follower-start-turn",
    params: {
      conversationId: "thread-settings",
      turnStartParams: { input: [{ type: "text", text: "run with settings" }] },
    },
  });
  await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "settings-start-1"
  );
  const startedTurn = codexRequests.filter((request) => request.method === "turn/start").at(-1);
  assert.equal(startedTurn.params.model, "gpt-desktop-settings");
  assert.equal(startedTurn.params.effort, "high");
  assert.equal(startedTurn.params.serviceTier, "fast");

  // Reading the thread from the phone broadcasts the read state to Desktop.
  owner.observeInbound(JSON.stringify({
    id: "read-1",
    method: "thread/read",
    params: { threadId: "thread-settings" },
  }));
  const readBroadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast" && frame.method === "thread-read-state-changed"
  );
  assert.deepEqual(readBroadcast.params, {
    conversationId: "thread-settings",
    hasUnreadTurn: false,
  });
  assert.equal(readBroadcast.version, 2);
});

test("live owner runs Desktop queued follow-ups between turns", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-queue-");
  const frames = [];
  const codexRequests = [];
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
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "queue-turn-1",
    method: "turn/start",
    params: { threadId: "thread-queue", input: [{ type: "text", text: "first" }] },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-queue",
      turn: { id: "turn-queue-1", items: [], status: "inProgress", startedAt: 1 },
    },
  }));
  await waitFor(() => serverSocket);

  // Desktop queues a follow-up while the turn is running.
  writeFrame(serverSocket, {
    type: "request",
    requestId: "queue-set-1",
    sourceClientId: "desktop",
    version: 1,
    method: "thread-follower-set-queued-follow-ups-state",
    params: {
      conversationId: "thread-queue",
      state: {
        "thread-queue": [{
          id: "queued-1",
          context: { text: "queued follow-up from desktop" },
        }],
      },
    },
  });
  const queueResponse = await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "queue-set-1"
  );
  assert.equal(queueResponse.resultType, "success");

  const queueBroadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-queued-followups-changed"
      && (frame.params?.messages?.length ?? 0) === 1
  );
  assert.equal(queueBroadcast.params.conversationId, "thread-queue");

  // No queued turn starts while the current one is still running.
  assert.equal(
    codexRequests.filter((request) => request.method === "turn/start").length,
    0
  );

  // The current turn completes: the owner must start the queued follow-up.
  owner.observeOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-queue",
      turn: { id: "turn-queue-1", items: [], status: "completed", startedAt: 1 },
    },
  }));

  await waitFor(() => codexRequests.some((request) => request.method === "turn/start"));
  const queuedStart = codexRequests.find((request) => request.method === "turn/start");
  assert.deepEqual(queuedStart.params.input, [{ type: "text", text: "queued follow-up from desktop" }]);
  assert.equal(queuedStart.params.threadId, "thread-queue");

  // The drained queue is rebroadcast as empty.
  await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-queued-followups-changed"
      && (frame.params?.messages?.length ?? 0) === 0
  );
});

test("live owner pauses undecodable queued entries and halts the queue after interrupts", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-queue-guards-");
  const frames = [];
  const codexRequests = [];
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
    async sendCodexRequest(method, params) {
      codexRequests.push({ method, params });
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "guards-turn-1",
    method: "turn/start",
    params: { threadId: "thread-queue-guards", input: [{ type: "text", text: "go" }] },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-queue-guards",
      turn: { id: "turn-guards-1", items: [], status: "inProgress", startedAt: 1 },
    },
  }));
  await waitFor(() => serverSocket);

  // Queue one entry the bridge cannot decode and one runnable entry behind it.
  writeFrame(serverSocket, {
    type: "request",
    requestId: "queue-guards-set-1",
    sourceClientId: "desktop",
    version: 1,
    method: "thread-follower-set-queued-follow-ups-state",
    params: {
      conversationId: "thread-queue-guards",
      state: {
        "thread-queue-guards": [
          { id: "queued-opaque", context: { attachments: ["mystery"] } },
          { id: "queued-text", context: { text: "runnable" } },
        ],
      },
    },
  });
  await waitForFrame(
    serverSocket,
    (frame) => frame.type === "response" && frame.requestId === "queue-guards-set-1"
  );

  // An interrupted turn must not auto-run the queue.
  owner.observeOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-queue-guards",
      turn: { id: "turn-guards-1", items: [], status: "interrupted", startedAt: 1 },
    },
  }));
  await wait(50);
  assert.equal(codexRequests.filter((request) => request.method === "turn/start").length, 0);

  // A normally completed turn tries the queue: the opaque entry gets paused
  // (not dropped) and blocks the runnable one, mirroring Desktop's semantics.
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-queue-guards",
      turn: { id: "turn-guards-2", items: [], status: "inProgress", startedAt: 2 },
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-queue-guards",
      turn: { id: "turn-guards-2", items: [], status: "completed", startedAt: 2 },
    },
  }));

  const pausedBroadcast = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-queued-followups-changed"
      && frame.params?.messages?.[0]?.pausedReason === "remodex-unsupported-entry"
  );
  assert.equal(pausedBroadcast.params.messages.length, 2);
  assert.equal(codexRequests.filter((request) => request.method === "turn/start").length, 0);

  // The thread is idle but its queue still holds drafts: leaving the screen
  // must not release ownership, or the queued work is silently discarded.
  owner.observeInbound(JSON.stringify({
    method: "thread/unsubscribe",
    params: { threadId: "thread-queue-guards" },
  }));
  assert.equal(owner.isThreadOwned("thread-queue-guards"), true);
});

test("live owner dedupes read-state broadcasts for already-clean threads", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-read-dedupe-");
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
    id: "dedupe-turn-1",
    method: "turn/start",
    params: { threadId: "thread-read-dedupe", input: [{ type: "text", text: "hi" }] },
  }));
  await waitFor(() => serverSocket);

  const readCount = () => frames.filter((frame) => (
    frame.type === "broadcast" && frame.method === "thread-read-state-changed"
  )).length;

  owner.observeInbound(JSON.stringify({
    id: "read-1",
    method: "thread/read",
    params: { threadId: "thread-read-dedupe" },
  }));
  await waitFor(() => readCount() === 1);

  // A second read with nothing unread must stay silent.
  owner.observeInbound(JSON.stringify({
    id: "read-2",
    method: "thread/read",
    params: { threadId: "thread-read-dedupe" },
  }));
  await wait(40);
  assert.equal(readCount(), 1);
});

test("live owner normalizes image_url input entries for Desktop snapshots", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-image-");
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
    sendCodexRequest: async (method) => {
      if (method === "thread/read") {
        return { thread: { id: "thread-image", turns: [] } };
      }
      return { ok: true };
    },
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "image-turn-1",
    method: "turn/start",
    params: {
      threadId: "thread-image",
      input: [
        { type: "text", text: "look at this" },
        { type: "image_url", image_url: { url: "https://example.com/shot.png" } },
      ],
    },
  }));
  owner.observeOutbound(JSON.stringify({
    method: "turn/started",
    params: {
      threadId: "thread-image",
      turn: { id: "turn-image-1", items: [], status: "inProgress", startedAt: 1 },
    },
  }));

  const snapshot = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-stream-state-changed"
      && frame.params?.conversationId === "thread-image"
      && frame.params?.change?.type === "snapshot"
  );
  const turn = snapshot.params.change.conversationState.turns[0];
  assert.deepEqual(turn.params.input, [
    { type: "text", text: "look at this" },
    { type: "image", url: "https://example.com/shot.png" },
  ]);
});

test("live owner announces phone threads to the Desktop sidebar once", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-sidebar-");
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
    sidebarRefreshDelayMs: 5,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
  });

  owner.observeInbound(JSON.stringify({
    id: "sidebar-turn-1",
    method: "turn/start",
    params: {
      threadId: "thread-sidebar",
      input: [{ type: "text", text: "hello desktop" }],
    },
  }));

  const announcement = await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast" && frame.method === "thread-unarchived"
  );
  assert.equal(announcement.params.conversationId, "thread-sidebar");
  assert.equal(announcement.params.hostId, "local");
  assert.equal(announcement.version, 1);

  // A later turn on the same thread must not re-announce it.
  const announcementCount = () => frames.filter((frame) => (
    frame.type === "broadcast" && frame.method === "thread-unarchived"
  )).length;
  const before = announcementCount();
  owner.observeInbound(JSON.stringify({
    id: "sidebar-turn-2",
    method: "turn/start",
    params: {
      threadId: "thread-sidebar",
      input: [{ type: "text", text: "again" }],
    },
  }));
  await wait(30);
  assert.equal(announcementCount(), before);
});

test("live owner replays an early sidebar announcement after rollout materialization", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-sidebar-materialized-");
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
    sidebarRefreshDelayMs: 5,
    sendCodexRequest: async () => ({ ok: true }),
    sendRawCodexMessage() {},
  });
  const announcementCount = () => frames.filter((frame) => (
    frame.type === "broadcast"
      && frame.method === "thread-unarchived"
      && frame.params?.conversationId === "thread-sidebar-race"
  )).length;

  owner.observeInbound(JSON.stringify({
    id: "sidebar-race-turn-1",
    method: "turn/start",
    params: {
      threadId: "thread-sidebar-race",
      input: [{ type: "text", text: "hi" }],
    },
  }));
  await waitForMessage(
    frames,
    (frame) => frame.type === "broadcast"
      && frame.method === "thread-unarchived"
      && frame.params?.conversationId === "thread-sidebar-race"
  );
  assert.equal(announcementCount(), 1);

  owner.observeOutbound(JSON.stringify({
    method: "item/started",
    params: {
      threadId: "thread-sidebar-race",
      turnId: "turn-sidebar-race",
      item: { id: "user-sidebar-race", type: "userMessage", content: [{ type: "text", text: "hi" }] },
    },
  }));
  await waitFor(() => announcementCount() === 2);

  // item/completed for the same persisted user item must not create an
  // unbounded refresh loop.
  owner.observeOutbound(JSON.stringify({
    method: "item/completed",
    params: {
      threadId: "thread-sidebar-race",
      turnId: "turn-sidebar-race",
      item: { id: "user-sidebar-race", type: "userMessage", content: [{ type: "text", text: "hi" }] },
    },
  }));
  await wait(20);
  assert.equal(announcementCount(), 2);

  // Completion is the final bounded fallback for app-server/catalog write races.
  owner.observeOutbound(JSON.stringify({
    method: "turn/completed",
    params: {
      threadId: "thread-sidebar-race",
      turn: { id: "turn-sidebar-race", items: [], status: "completed" },
    },
  }));
  await waitFor(() => announcementCount() === 3);

  owner.observeInbound(JSON.stringify({
    id: "sidebar-race-turn-2",
    method: "turn/start",
    params: {
      threadId: "thread-sidebar-race",
      input: [{ type: "text", text: "again" }],
    },
  }));
  await wait(20);
  assert.equal(announcementCount(), 3);
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

test("live owner keeps mid-run threads when a peer sends an idle snapshot", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-idle-claim-");
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
    params: {
      threadId: "thread-idle-claim",
      input: [{ type: "text", text: "running prompt" }],
    },
  }));
  await waitFor(() => serverSocket);

  // Desktop re-broadcasts idle snapshots for threads the user merely viewed;
  // those must not steal a thread whose local turn is still in flight.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-owner",
    version: 6,
    params: {
      conversationId: "thread-idle-claim",
      change: {
        type: "snapshot",
        conversationState: { turns: [], requests: [] },
      },
    },
  });
  await wait(25);
  assert.equal(owner.isThreadOwned("thread-idle-claim"), true);

  // A snapshot proving the peer runtime is executing the turn is a real claim.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-owner",
    version: 6,
    params: {
      conversationId: "thread-idle-claim",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{ id: "turn-peer-1", status: "inProgress" }],
          requests: [],
        },
      },
    },
  });
  await waitFor(() => !owner.isThreadOwned("thread-idle-claim"));
});

test("live owner releases idle threads on unsubscribe but keeps running ones", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-live-owner-unsub-");
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

  // An owned thread with no turn in flight releases when the phone leaves it.
  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: { threadId: "thread-unsub-idle", input: [] },
  }));
  assert.equal(owner.isThreadOwned("thread-unsub-idle"), true);
  owner.observeInbound(JSON.stringify({
    method: "thread/unsubscribe",
    params: { threadId: "thread-unsub-idle" },
  }));
  assert.equal(owner.isThreadOwned("thread-unsub-idle"), false);

  // A thread whose local turn is still executing stays owned: releasing it
  // mid-run corrupts the timeline on the next reopen.
  owner.observeInbound(JSON.stringify({
    method: "turn/start",
    params: {
      threadId: "thread-unsub-running",
      input: [{ type: "text", text: "still running" }],
    },
  }));
  owner.observeInbound(JSON.stringify({
    method: "thread/unsubscribe",
    params: { threadId: "thread-unsub-running" },
  }));
  assert.equal(owner.isThreadOwned("thread-unsub-running"), true);
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
    sendCodexRequest: async (method) => {
      if (method === "thread/read") {
        return { thread: { id: "thread-yield-state", turns: [] } };
      }
      return { ok: true };
    },
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

  // A peer owner claims the stream with a snapshot proving it is executing the
  // turn; the local turn is still marked running, so an idle echo would not do.
  writeFrame(serverSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop-owner",
    version: 6,
    params: {
      conversationId: "thread-yield-state",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{ id: "turn-peer-claim", status: "inProgress" }],
          requests: [],
        },
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

test("hydrated turns adopt the leading userMessage item into params.input", () => {
  const state = buildConversationStateFromThread({
    id: "thread-hydrated-prompt",
    name: "Hydrated",
    cwd: "/tmp/hydrated",
    turns: [{
      id: "turn-hydrated-1",
      status: "completed",
      startedAt: 5,
      items: [
        {
          id: "disk-user-message",
          type: "userMessage",
          content: [{ type: "text", text: "prompt from disk" }],
        },
        { id: "disk-assistant", type: "agentMessage", text: "done" },
      ],
    }],
  }, { now: () => 99 });

  const turn = state.turns[0];
  // The prompt moves into params.input (Desktop's bubble source) and the item
  // is dropped so it cannot render as "Steered conversation".
  assert.deepEqual(turn.params.input, [{ type: "text", text: "prompt from disk" }]);
  assert.deepEqual(turn.items.map((item) => item.id), ["disk-assistant"]);
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
