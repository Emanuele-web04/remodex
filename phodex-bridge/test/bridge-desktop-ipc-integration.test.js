// FILE: bridge-desktop-ipc-integration.test.js
// Purpose: Verifies the bridge wires phone-origin replies to Codex Desktop IPC actions.
// Layer: Integration test
// Exports: node:test suite
// Depends on: node:test, ws, net, ../src/bridge with mocked runtime transports

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const Module = require("node:module");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { setTimeout: wait } = require("node:timers/promises");
const WebSocket = require("ws");

test("bridge forwards desktop IPC actions to the phone and routes replies back to Codex Desktop", async (t) => {
  const { tempDir, socketPath: ipcSocketPath } = createIpcTestSocket("remodex-bridge-ipc-");
  const relayServer = new WebSocket.Server({ port: 0 });
  const relayMessages = [];
  const ipcFrames = [];
  let relaySocket = null;
  let ipcServerSocket = null;
  let bridge = null;
  let fakeCodex = null;

  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
    socket.on("message", (data) => {
      const parsed = safeParseJSON(data.toString("utf8"));
      if (parsed) {
        relayMessages.push(parsed);
      }
    });
  });

  const ipcServer = net.createServer((socket) => {
    ipcServerSocket = socket;
    attachFrameReader(socket, (frame) => {
      ipcFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "desktop-test" },
        });
      }
      if (frame.method === "thread-follower-submit-user-input") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: frame.method,
          handledByClientId: "desktop",
          result: { ok: true },
        });
      }
    });
  });
  await new Promise((resolve) => ipcServer.listen(ipcSocketPath, resolve));

  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl() {
      fakeCodex = createFakeCodexTransport();
      return fakeCodex;
    },
  });

  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
    ipcServer.close();
    ipcServerSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  bridge = startBridge({
    printPairingQr: false,
    config: {
      relayUrl: `ws://127.0.0.1:${relayServer.address().port}`,
      pushServiceUrl: "",
      pushPreviewMaxChars: 160,
      refreshEnabled: false,
      refreshDebounceMs: 1,
      keepMacAwakeEnabled: false,
      codexEndpoint: "",
      refreshCommand: "",
      codexBundleId: "",
      codexAppPath: "",
      desktopIpcSocketPath: ipcSocketPath,
      desktopIpcLiveSyncEnabled: false,
    },
  });

  await waitFor(() => relaySocket && relaySocket.readyState === WebSocket.OPEN);
  relaySocket.send(JSON.stringify({
    id: "resume-from-phone",
    method: "thread/resume",
    params: { threadId: "thread-ipc" },
  }));

  await waitFor(() => ipcServerSocket, 2_000);
  await wait(25);
  assert.equal(
    fakeCodex.sent.some((message) => message.method === "thread/read"),
    false
  );

  writeFrame(ipcServerSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 1,
    params: {
      conversationId: "thread-ipc",
      change: {
        type: "snapshot",
        conversationState: {
          requests: [{
            id: 36,
            method: "item/tool/requestUserInput",
            params: {
              threadId: "thread-ipc",
              turnId: "turn-ipc",
              itemId: "item-ipc",
              questions: [{ id: "q1", question: "Continue?" }],
            },
          }],
        },
      },
    },
  });

  const actionMessage = await waitForMessage(relayMessages, (message) => message.id === 36);
  assert.equal(actionMessage.method, "item/tool/requestUserInput");

  relaySocket.send(JSON.stringify({
    id: 36,
    result: {
      answers: {
        q1: { answers: ["Yes"] },
      },
    },
  }));

  const ipcReply = await waitForMessage(
    ipcFrames,
    (frame) => frame.method === "thread-follower-submit-user-input"
  );
  assert.deepEqual(ipcReply.params, {
    conversationId: "thread-ipc",
    requestId: 36,
    response: {
      answers: {
        q1: { answers: ["Yes"] },
      },
    },
  });
  assert.equal(fakeCodex.sent.some((message) => message.id === 36), false);

  const resolvedMessage = await waitForMessage(
    relayMessages,
    (message) => message.method === "serverRequest/resolved"
      && message.params?.requestId === 36
  );
  assert.equal(resolvedMessage.params.threadId, "thread-ipc");
});

test("bridge recovers desktop IPC state when the first live update is patch-only", async (t) => {
  const { tempDir, socketPath: ipcSocketPath } = createIpcTestSocket("remodex-bridge-ipc-recovery-");
  const relayServer = new WebSocket.Server({ port: 0 });
  const relayMessages = [];
  let relaySocket = null;
  let ipcServerSocket = null;
  let bridge = null;
  let fakeCodex = null;

  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
    socket.on("message", (data) => {
      const parsed = safeParseJSON(data.toString("utf8"));
      if (parsed) {
        relayMessages.push(parsed);
      }
    });
  });

  const ipcServer = net.createServer((socket) => {
    ipcServerSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "desktop-test" },
        });
      }
    });
  });
  await new Promise((resolve) => ipcServer.listen(ipcSocketPath, resolve));

  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl() {
      fakeCodex = createFakeCodexTransport({
        threadReadResult: {
          conversationState: {
            turns: [],
            requests: [{
              id: "req-recovered",
              method: "item/tool/requestUserInput",
              completed: true,
              params: {
                threadId: "thread-ipc-recovery",
                turnId: "turn-ipc-recovery",
                itemId: "item-ipc-recovery",
                questions: [{ id: "q1", question: "Continue?" }],
              },
            }],
          },
        },
      });
      return fakeCodex;
    },
  });

  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
    ipcServer.close();
    ipcServerSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  bridge = startBridge({
    printPairingQr: false,
    config: {
      relayUrl: `ws://127.0.0.1:${relayServer.address().port}`,
      pushServiceUrl: "",
      pushPreviewMaxChars: 160,
      refreshEnabled: false,
      refreshDebounceMs: 1,
      keepMacAwakeEnabled: false,
      codexEndpoint: "",
      refreshCommand: "",
      codexBundleId: "",
      codexAppPath: "",
      desktopIpcSocketPath: ipcSocketPath,
      desktopIpcLiveSyncEnabled: false,
    },
  });

  await waitFor(() => relaySocket && relaySocket.readyState === WebSocket.OPEN);
  relaySocket.send(JSON.stringify({
    id: "resume-for-recovery",
    method: "thread/resume",
    params: { threadId: "thread-ipc-recovery" },
  }));

  await waitFor(() => ipcServerSocket, 2_000);
  writeFrame(ipcServerSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 1,
    params: {
      conversationId: "thread-ipc-recovery",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["requests", 0, "completed"],
          value: false,
        }],
      },
    },
  });

  const recoveredRequest = await waitForMessage(
    relayMessages,
    (message) => message.id === "req-recovered"
  );
  assert.equal(recoveredRequest.method, "item/tool/requestUserInput");
  assert.equal(
    fakeCodex.sent.some((message) => message.method === "thread/read"),
    true
  );
});

test("bridge forwards live desktop assistant deltas to the phone", async (t) => {
  const { tempDir, socketPath: ipcSocketPath } = createIpcTestSocket("remodex-bridge-ipc-delta-");
  const relayServer = new WebSocket.Server({ port: 0 });
  const relayMessages = [];
  let relaySocket = null;
  let ipcServerSocket = null;
  let bridge = null;
  let fakeCodex = null;

  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
    socket.on("message", (data) => {
      const parsed = safeParseJSON(data.toString("utf8"));
      if (parsed) {
        relayMessages.push(parsed);
      }
    });
  });

  const ipcServer = net.createServer((socket) => {
    ipcServerSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "desktop-test" },
        });
      }
    });
  });
  await new Promise((resolve) => ipcServer.listen(ipcSocketPath, resolve));

  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl() {
      fakeCodex = createFakeCodexTransport();
      return fakeCodex;
    },
  });

  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
    ipcServer.close();
    ipcServerSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  bridge = startBridge({
    printPairingQr: false,
    config: {
      relayUrl: `ws://127.0.0.1:${relayServer.address().port}`,
      pushServiceUrl: "",
      pushPreviewMaxChars: 160,
      refreshEnabled: false,
      refreshDebounceMs: 1,
      keepMacAwakeEnabled: false,
      codexEndpoint: "",
      refreshCommand: "",
      codexBundleId: "",
      codexAppPath: "",
      desktopIpcSocketPath: ipcSocketPath,
      desktopIpcLiveSyncEnabled: false,
    },
  });

  await waitFor(() => relaySocket && relaySocket.readyState === WebSocket.OPEN);
  relaySocket.send(JSON.stringify({
    id: "resume-from-phone-delta",
    method: "thread/resume",
    params: { threadId: "thread-ipc-delta" },
  }));

  await waitFor(() => ipcServerSocket, 2_000);
  writeFrame(ipcServerSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 1,
    params: {
      conversationId: "thread-ipc-delta",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            id: "turn-ipc-delta",
            status: "inProgress",
            items: [{
              id: "assistant-ipc-delta",
              type: "assistant_message",
              text: "Hello",
            }],
          }],
        },
      },
    },
  });
  writeFrame(ipcServerSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 1,
    params: {
      conversationId: "thread-ipc-delta",
      change: {
        type: "patches",
        patches: [{
          op: "replace",
          path: ["turns", 0, "items", 0, "text"],
          value: "Hello world",
        }],
      },
    },
  });

  const deltaMessage = await waitForMessage(
    relayMessages,
    (message) => message.method === "item/agentMessage/delta"
  );
  assert.equal(deltaMessage.params.threadId, "thread-ipc-delta");
  assert.equal(deltaMessage.params.turnId, "turn-ipc-delta");
  assert.equal(deltaMessage.params.itemId, "assistant-ipc-delta");
  assert.equal(deltaMessage.params.delta, " world");
  assert.equal(deltaMessage.params.remodexDesktopMirror, true);
  assert.equal(deltaMessage.params.remodexDesktopIpcMirror, true);
});

test("bridge serves Desktop-owned thread history from cached IPC state", async (t) => {
  const { tempDir, socketPath: ipcSocketPath } = createIpcTestSocket("remodex-bridge-ipc-read-");
  const relayServer = new WebSocket.Server({ port: 0 });
  const relayMessages = [];
  let relaySocket = null;
  let ipcServerSocket = null;
  let bridge = null;

  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
    socket.on("message", (data) => {
      const parsed = safeParseJSON(data.toString("utf8"));
      if (parsed) {
        relayMessages.push(parsed);
      }
    });
  });

  const ipcServer = net.createServer((socket) => {
    ipcServerSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "desktop-test" },
        });
      }
    });
  });
  await new Promise((resolve) => ipcServer.listen(ipcSocketPath, resolve));

  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl() {
      return createFakeCodexTransport();
    },
  });

  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
    ipcServer.close();
    ipcServerSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  bridge = startBridge({
    printPairingQr: false,
    config: {
      relayUrl: `ws://127.0.0.1:${relayServer.address().port}`,
      pushServiceUrl: "",
      pushPreviewMaxChars: 160,
      refreshEnabled: false,
      refreshDebounceMs: 1,
      keepMacAwakeEnabled: false,
      codexEndpoint: "",
      refreshCommand: "",
      codexBundleId: "",
      codexAppPath: "",
      desktopIpcSocketPath: ipcSocketPath,
      desktopIpcLiveSyncEnabled: false,
    },
  });

  await waitFor(() => relaySocket && relaySocket.readyState === WebSocket.OPEN);
  relaySocket.send(JSON.stringify({
    id: "resume-before-read",
    method: "thread/resume",
    params: { threadId: "thread-ipc-read" },
  }));
  await waitFor(() => ipcServerSocket, 2_000);
  writeFrame(ipcServerSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 5,
    params: {
      conversationId: "thread-ipc-read",
      change: {
        type: "snapshot",
        conversationState: {
          title: "Cached Desktop Thread",
          cwd: "/repo",
          turns: [{
            turnId: "turn-ipc-read",
            status: "completed",
            params: {
              input: [{ type: "text", text: "read me" }],
            },
            items: [{ id: "assistant-ipc-read", type: "agentMessage", text: "cached reply" }],
          }],
        },
      },
    },
  });

  await waitForMessage(relayMessages, (message) => message.method === "thread/started");
  relaySocket.send(JSON.stringify({
    id: "read-cached-desktop-thread",
    method: "thread/read",
    params: { threadId: "thread-ipc-read" },
  }));

  const readResponse = await waitForMessage(
    relayMessages,
    (message) => message.id === "read-cached-desktop-thread"
  );
  assert.equal(readResponse.result.thread.id, "thread-ipc-read");
  assert.equal(readResponse.result.thread.name, "Cached Desktop Thread");
  assert.deepEqual(
    readResponse.result.thread.turns[0].items.map((item) => item.type),
    ["userMessage", "agentMessage"]
  );
});

test("bridge maps Desktop IPC archive broadcasts to phone notifications", async (t) => {
  const { tempDir, socketPath: ipcSocketPath } = createIpcTestSocket("remodex-bridge-ipc-archive-");
  const relayServer = new WebSocket.Server({ port: 0 });
  const relayMessages = [];
  let relaySocket = null;
  let ipcServerSocket = null;
  let bridge = null;

  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
    socket.on("message", (data) => {
      const parsed = safeParseJSON(data.toString("utf8"));
      if (parsed) {
        relayMessages.push(parsed);
      }
    });
  });

  const ipcServer = net.createServer((socket) => {
    ipcServerSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "desktop-test" },
        });
      }
    });
  });
  await new Promise((resolve) => ipcServer.listen(ipcSocketPath, resolve));

  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl() {
      return createFakeCodexTransport();
    },
  });

  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
    ipcServer.close();
    ipcServerSocket?.destroy();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  bridge = startBridge({
    printPairingQr: false,
    config: {
      relayUrl: `ws://127.0.0.1:${relayServer.address().port}`,
      pushServiceUrl: "",
      pushPreviewMaxChars: 160,
      refreshEnabled: false,
      refreshDebounceMs: 1,
      keepMacAwakeEnabled: false,
      codexEndpoint: "",
      refreshCommand: "",
      codexBundleId: "",
      codexAppPath: "",
      desktopIpcSocketPath: ipcSocketPath,
      desktopIpcLiveSyncEnabled: false,
    },
  });

  await waitFor(() => relaySocket && relaySocket.readyState === WebSocket.OPEN);
  relaySocket.send(JSON.stringify({
    id: "resume-before-archive",
    method: "thread/resume",
    params: { threadId: "thread-ipc-archive" },
  }));
  await waitFor(() => ipcServerSocket, 2_000);
  writeFrame(ipcServerSocket, {
    type: "broadcast",
    method: "thread-archived",
    sourceClientId: "desktop",
    version: 2,
    params: {
      hostId: "desktop",
      conversationId: "thread-ipc-archive",
      cwd: "/repo",
    },
  });

  const archiveMessage = await waitForMessage(
    relayMessages,
    (message) => message.method === "thread/archived"
  );
  assert.equal(archiveMessage.params.threadId, "thread-ipc-archive");
  assert.equal(archiveMessage.params.cwd, "/repo");
  assert.equal(archiveMessage.params.remodexDesktopIpcMirror, true);

  writeFrame(ipcServerSocket, {
    type: "broadcast",
    method: "thread-unarchived",
    sourceClientId: "desktop",
    version: 2,
    params: {
      hostId: "desktop",
      conversationId: "thread-ipc-archive",
      cwd: "/repo",
    },
  });

  const unarchiveMessage = await waitForMessage(
    relayMessages,
    (message) => message.method === "thread/unarchived"
  );
  assert.equal(unarchiveMessage.params.threadId, "thread-ipc-archive");
  assert.equal(unarchiveMessage.params.cwd, "/repo");
  assert.equal(unarchiveMessage.params.remodexDesktopIpcMirror, true);
});

test("bridge observes held desktop IPC turns only after local fallback", async (t) => {
  const relayServer = new WebSocket.Server({ port: 0 });
  let relaySocket = null;
  let bridge = null;
  let fakeCodex = null;
  let followerOptions = null;
  let heldTurnStart = null;
  let liveOwnerOptions = null;
  const liveOwnerInbound = [];

  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
  });

  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl() {
      fakeCodex = createFakeCodexTransport();
      return fakeCodex;
    },
    desktopIpcActionFollowerModule: {
      createDesktopIpcActionFollower(options) {
        followerOptions = options;
        return {
          observeInbound(rawMessage) {
            const parsed = safeParseJSON(rawMessage);
            if (parsed?.method !== "turn/start") {
              return false;
            }
            heldTurnStart = rawMessage;
            return true;
          },
          stopAll() {},
        };
      },
      seedConversationStateFromThreadRead() {
        return null;
      },
    },
    desktopIpcLiveOwnerModule: {
      createDesktopIpcLiveOwner(options) {
        liveOwnerOptions = options;
        return {
          observeInbound(rawMessage) {
            liveOwnerInbound.push(JSON.parse(rawMessage));
          },
          observeOutbound() {},
          stopAll() {},
        };
      },
    },
  });

  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
  });

  bridge = startBridge({
    printPairingQr: false,
    config: {
      relayUrl: `ws://127.0.0.1:${relayServer.address().port}`,
      pushServiceUrl: "",
      pushPreviewMaxChars: 160,
      refreshEnabled: false,
      refreshDebounceMs: 1,
      keepMacAwakeEnabled: false,
      codexEndpoint: "",
      refreshCommand: "",
      codexBundleId: "",
      codexAppPath: "",
      desktopIpcLiveSyncEnabled: true,
    },
  });

  await waitFor(() => relaySocket && relaySocket.readyState === WebSocket.OPEN);
  assert.equal(typeof liveOwnerOptions?.onFollowerStateChanged, "function");
  await followerOptions.readConversationState("thread-complete-baseline");
  assert.deepEqual(
    fakeCodex.sent.find((message) => message.method === "thread/read")?.params,
    {
      threadId: "thread-complete-baseline",
      includeTurns: true,
    }
  );
  relaySocket.send(JSON.stringify({
    id: "held-turn-start",
    method: "turn/start",
    params: {
      threadId: "thread-held-live-owner",
      input: [{ type: "input_text", text: "start locally if unowned" }],
    },
  }));

  await waitFor(() => heldTurnStart);
  await wait(25);
  assert.equal(liveOwnerInbound.length, 0);
  assert.equal(fakeCodex.sent.some((message) => message.id === "held-turn-start"), false);

  followerOptions.forwardToLocalCodex(heldTurnStart);
  await waitFor(() => liveOwnerInbound.some((message) => message.id === "held-turn-start"));
  assert.equal(
    liveOwnerInbound.filter((message) => message.id === "held-turn-start").length,
    1
  );
  assert.equal(fakeCodex.sent.filter((message) => message.id === "held-turn-start").length, 1);
});

test("bridge preserves catalog request limits and excludes archived or cursor pages", async (t) => {
  const relayServer = new WebSocket.Server({ port: 0 });
  const relayMessages = [];
  const catalogs = [];
  let relaySocket = null;
  let bridge = null;
  let fakeCodex = null;
  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
    socket.on("message", (data) => relayMessages.push(JSON.parse(data.toString("utf8"))));
  });
  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl() {
      fakeCodex = createFakeCodexTransport();
      return fakeCodex;
    },
    desktopIpcActionFollowerModule: {
      createDesktopIpcActionFollower() {
        return {
          observeInbound() { return false; },
          observeThreadListResponse(result, options) { catalogs.push({ result, options }); },
          stopAll() {},
        };
      },
    },
  });
  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
  });
  bridge = startBridge({ printPairingQr: false, config: bridgeTestConfig(relayServer) });
  await waitFor(() => relaySocket?.readyState === WebSocket.OPEN);

  const requests = [
    { id: "catalog", params: { limit: 70, cursor: null } },
    { id: "probe", params: { limit: 1, cursor: null } },
    { id: "archived", params: { limit: 70, archived: true } },
    { id: "page", params: { limit: 70, cursor: "next-page" } },
  ];
  for (const request of requests) {
    relaySocket.send(JSON.stringify({ ...request, method: "thread/list" }));
    await waitFor(() => fakeCodex.sent.some((message) => message.id === request.id));
    fakeCodex.emitMessage({ id: request.id, result: { data: [{ id: request.id }], nextCursor: "next-page" } });
    await waitForMessage(relayMessages, (message) => message.id === request.id);
  }
  assert.deepEqual(catalogs.map(({ result, options }) => ({ id: result.data[0].id, limit: options?.limit })), [
    { id: "catalog", limit: 70 },
    { id: "probe", limit: 1 },
  ]);
});

test("bridge Activity is opt-in and canonical-only endpoints need no Desktop IPC", async (t) => {
  const relayServer = new WebSocket.Server({ port: 0 });
  const relayMessages = [];
  let relaySocket = null;
  let bridge = null;
  let fakeCodex = null;

  await new Promise((resolve) => relayServer.once("listening", resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
    socket.on("message", (data) => relayMessages.push(JSON.parse(data.toString("utf8"))));
  });
  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl() {
      fakeCodex = createFakeCodexTransport();
      return fakeCodex;
    },
  });
  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
  });

  bridge = startBridge({
    printPairingQr: false,
    config: bridgeTestConfig(relayServer, { codexEndpoint: "ws://fake-codex" }),
  });
  await waitFor(() => relaySocket?.readyState === WebSocket.OPEN);

  fakeCodex.emitMessage({
    method: "thread/started",
    params: {
      thread: {
        id: "canonical-thread",
        name: "Canonical task",
        cwd: "/repo/canonical",
        status: { type: "idle" },
      },
    },
  });
  await waitFor(() => relayMessages.some((message) => message.method === "thread/started"));
  assert.equal(
    relayMessages.some((message) => message.method === "remodex/activity/updated"),
    false
  );

  relaySocket.send(JSON.stringify({
    id: 91,
    method: "remodex/activity/subscribe",
    params: { schemaVersion: 1 },
  }));
  const snapshot = await waitForMessage(relayMessages, (message) => message.id === 91);
  assert.equal(snapshot.result.entries[0].threadId, "canonical-thread");
  assert.equal(snapshot.result.entries[0].source, "app-server");
  assert.equal(fakeCodex.sent.some((message) => message.id === 91), false);

  fakeCodex.emitMessage({
    method: "turn/started",
    params: {
      threadId: "canonical-thread",
      turn: { id: "canonical-turn", status: "inProgress", startedAt: 1_700_000_000 },
    },
  });
  const update = await waitForMessage(
    relayMessages,
    (message) => message.method === "remodex/activity/updated"
  );
  assert.equal(update.params.baseRevision, snapshot.result.revision);
  assert.deepEqual(update.params.upserts[0].activeTurnIds, ["canonical-turn"]);

  relaySocket.send(JSON.stringify({
    id: "stop-activity",
    method: "remodex/activity/unsubscribe",
  }));
  await waitForMessage(relayMessages, (message) => message.id === "stop-activity");
  const activityCount = relayMessages.filter(
    (message) => message.method === "remodex/activity/updated"
  ).length;
  fakeCodex.emitMessage({
    method: "item/started",
    params: {
      threadId: "canonical-thread",
      turnId: "canonical-turn",
      item: { id: "reasoning", type: "reasoning", content: ["private"] },
      startedAtMs: 1_700_000_000_100,
    },
  });
  await wait(250);
  assert.equal(
    relayMessages.filter((message) => message.method === "remodex/activity/updated").length,
    activityCount
  );
});

test("Activity subscribe performs no reads and snapshots an unopened Desktop thread", async (t) => {
  const { tempDir, socketPath: ipcSocketPath } = createIpcTestSocket("remodex-activity-ipc-");
  const relayServer = new WebSocket.Server({ port: 0 });
  const ipcServer = net.createServer();
  const relayMessages = [];
  const ipcFrames = [];
  let relaySocket = null;
  let ipcSocket = null;
  let bridge = null;
  let fakeCodex = null;

  await new Promise((resolve) => relayServer.once("listening", resolve));
  await new Promise((resolve) => ipcServer.listen(ipcSocketPath, resolve));
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
    socket.on("message", (data) => relayMessages.push(JSON.parse(data.toString("utf8"))));
  });
  ipcServer.on("connection", (socket) => {
    ipcSocket = socket;
    attachFrameReader(socket, (frame) => {
      ipcFrames.push(frame);
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response",
          requestId: frame.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "desktop",
          result: { clientId: "activity-test" },
        });
      }
    });
  });
  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl() {
      fakeCodex = createFakeCodexTransport();
      return fakeCodex;
    },
  });
  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    ipcSocket?.destroy();
    ipcServer.close();
    relayServer.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  bridge = startBridge({
    printPairingQr: false,
    config: bridgeTestConfig(relayServer, {
      desktopIpcSocketPath: ipcSocketPath,
      desktopIpcLiveSyncEnabled: false,
    }),
  });
  await waitFor(() => relaySocket?.readyState === WebSocket.OPEN);
  relaySocket.send(JSON.stringify({ id: "activity-first", method: "remodex/activity/subscribe" }));
  await waitForMessage(relayMessages, (message) => message.id === "activity-first");
  await wait(20);
  assert.equal(ipcSocket, null, "Activity subscription must not connect to Desktop IPC");
  assert.equal(fakeCodex.sent.some((message) => message.id === "activity-first"), false);

  relaySocket.send(JSON.stringify({ id: "existing-sidebar", method: "thread/list", params: {} }));
  await waitFor(() => fakeCodex.sent.some((message) => message.id === "existing-sidebar"));
  fakeCodex.emitMessage({
    id: "existing-sidebar",
    result: { data: [{ id: "unopened-desktop-thread", cwd: "/repo/desktop" }] },
  });
  await waitFor(() => ipcFrames.some((frame) => (
    frame.method === "thread-stream-following-changed"
      && frame.params?.conversationId === "unopened-desktop-thread"
      && frame.params.following
  )));
  writeFrame(ipcSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 11,
    params: {
      conversationId: "unopened-desktop-thread",
      change: {
        type: "snapshot",
        conversationState: {
          title: "Unopened Desktop task",
          cwd: "/repo/desktop",
          threadRuntimeStatus: { type: "active", activeFlags: [] },
          hasUnreadTurn: true,
          unreadMessageCount: 2,
          requests: [],
          turns: [{
            id: "desktop-turn",
            status: "inProgress",
            turnStartedAtMs: 1_700_000_000_500,
            items: [{
              id: "desktop-tool",
              type: "mcpToolCall",
              arguments: { secret: "not relayed" },
            }],
          }],
        },
      },
    },
  });
  const update = await waitForMessage(
    relayMessages,
    (message) => message.method === "remodex/activity/updated"
      && message.params?.upserts?.[0]?.threadId === "unopened-desktop-thread"
  );
  assert.equal(update.params.upserts[0].source, "desktop-ipc");
  assert.equal(update.params.upserts[0].runtime, "active");
  assert.equal(JSON.stringify(update).includes("not relayed"), false);
  assert.deepEqual(
    ipcFrames.map((frame) => frame.method).filter(Boolean),
    ["initialize", "thread-stream-following-changed"]
  );
  relaySocket.send(JSON.stringify({ id: "archived-sidebar", method: "thread/list", params: { archived: true } }));
  await waitFor(() => fakeCodex.sent.some((message) => message.id === "archived-sidebar"));
  fakeCodex.emitMessage({ id: "archived-sidebar", result: { data: [{ id: "archived-thread" }] } });
  await waitForMessage(relayMessages, (message) => message.id === "archived-sidebar");
  assert.equal(ipcFrames.length, 2, "archived lists must not change active subscriptions");
  fakeCodex.emitMessage({
    method: "thread/name/updated",
    params: { threadId: "unopened-desktop-thread", threadName: "Renamed task" },
  });
  fakeCodex.emitMessage({
    method: "thread/status/changed",
    params: { threadId: "unopened-desktop-thread", status: { type: "notLoaded" } },
  });
  const renamed = await waitForMessage(relayMessages, (message) => (
    message.method === "remodex/activity/updated"
      && message.params?.upserts?.[0]?.title === "Renamed task"
  ));
  assert.equal(renamed.params.upserts[0].source, "desktop-ipc");
  assert.equal(renamed.params.upserts[0].runtime, "active");
  assert.equal(renamed.params.upserts[0].desktopUnread.hasUnreadTurn, true);
});

test("bridge recovers a growing rollout behind a connected stale Desktop stream", async (t) => {
  const { tempDir, socketPath } = createIpcTestSocket("remodex-stale-stream-");
  const threadId = "thread-stale-stream";
  const turnId = "turn-stale-stream";
  let fakeNow = Date.now();
  const snapshotAt = fakeNow;
  const sessionsDir = path.join(tempDir, "sessions", "2026", "09", "11");
  fs.mkdirSync(sessionsDir, { recursive: true });
  const rolloutPath = path.join(sessionsDir, `rollout-${threadId}.jsonl`);
  const record = (type, payload) => JSON.stringify({
    timestamp: new Date(fakeNow).toISOString(), type, payload,
  });
  fs.writeFileSync(rolloutPath, [
    record("session_meta", { id: threadId, cwd: "/repo", originator: "Codex Desktop", source: "desktop" }),
    record("event_msg", { type: "task_started", turn_id: turnId }),
    record("event_msg", { type: "user_message", message: "Continue this chat" }),
    "",
  ].join("\n"));
  fs.utimesSync(rolloutPath, new Date(snapshotAt - 1_000), new Date(snapshotAt - 1_000));
  const previousCodexHome = process.env.CODEX_HOME;
  process.env.CODEX_HOME = tempDir;

  const messages = [];
  let relaySocket = null;
  let ipcSocket = null;
  let bridge = null;
  let follower = null;
  let mirror = null;
  let tick = null;
  let directoryReads = 0;
  let contentReads = 0;
  const relayServer = new WebSocket.Server({ port: 0 });
  relayServer.on("connection", (socket) => {
    relaySocket = socket;
    socket.on("message", (data) => messages.push(JSON.parse(data.toString())));
  });
  const ipcServer = net.createServer((socket) => {
    ipcSocket = socket;
    attachFrameReader(socket, (frame) => {
      if (frame.method === "initialize") {
        writeFrame(socket, {
          type: "response", requestId: frame.requestId, resultType: "success",
          method: "initialize", result: { clientId: "remodex-test" },
        });
      }
    });
  });
  t.after(() => {
    bridge?.stop();
    relaySocket?.close();
    relayServer.close();
    ipcSocket?.destroy();
    ipcServer.close();
    if (previousCodexHome === undefined) delete process.env.CODEX_HOME;
    else process.env.CODEX_HOME = previousCodexHome;
    fs.rmSync(tempDir, { recursive: true, force: true });
  });
  await new Promise((resolve) => relayServer.once("listening", resolve));
  await new Promise((resolve) => ipcServer.listen(socketPath, resolve));

  const followerModule = require("../src/desktop-ipc-action-follower");
  const mirrorModule = require("../src/rollout-live-mirror");
  const { startBridge } = loadBridgeWithTestDoubles({
    createCodexTransportImpl: () => createFakeCodexTransport(),
    desktopIpcActionFollowerModule: {
      ...followerModule,
      createDesktopIpcActionFollower(options) {
        follower = followerModule.createDesktopIpcActionFollower({ ...options, now: () => fakeNow });
        return follower;
      },
    },
    rolloutLiveMirrorModule: {
      createRolloutLiveMirrorController(options) {
        mirror = mirrorModule.createRolloutLiveMirrorController({
          ...options,
          now: () => fakeNow,
          fsModule: {
            ...fs,
            readdirSync(...args) { directoryReads += 1; return fs.readdirSync(...args); },
            readSync(...args) { contentReads += 1; return fs.readSync(...args); },
          },
          setIntervalFn(callback) { tick = callback; return 1; },
          clearIntervalFn() {},
          setImmediateFn() { return 2; },
          clearImmediateFn() {},
        });
        return mirror;
      },
    },
  });
  bridge = startBridge({
    printPairingQr: false,
    config: {
      relayUrl: `ws://127.0.0.1:${relayServer.address().port}`,
      pushServiceUrl: "", pushPreviewMaxChars: 160,
      refreshEnabled: false, refreshDebounceMs: 1, keepMacAwakeEnabled: false,
      codexEndpoint: "", refreshCommand: "", codexBundleId: "", codexAppPath: "",
      desktopIpcSocketPath: socketPath, desktopIpcLiveSyncEnabled: false,
    },
  });
  await waitFor(() => relaySocket?.readyState === WebSocket.OPEN);
  relaySocket.send(JSON.stringify({ id: "resume-stale-stream", method: "thread/resume", params: { threadId } }));
  await waitFor(() => ipcSocket && tick);
  writeFrame(ipcSocket, {
    type: "broadcast", method: "thread-stream-state-changed", sourceClientId: "desktop", version: 11,
    params: {
      conversationId: threadId,
      change: { type: "snapshot", conversationState: {
        turns: [{ turnId, status: "inProgress", items: [] }], requests: [],
      } },
    },
  });
  await waitFor(() => follower.hasLiveThreadState(threadId));
  tick();
  assert.equal(directoryReads, 0, "fresh Desktop state must not scan the rollout");
  assert.equal(mirror.getActiveTurnId(threadId), null);

  fakeNow += 21_000;
  tick();
  assert.ok(directoryReads > 0, "stale Desktop state must check for newer file activity");
  assert.equal(contentReads, 0, "quiet work must not replay an older rollout");
  assert.equal(mirror.getActiveTurnId(threadId), null);
  const firstLookupReads = directoryReads;
  tick();
  assert.equal(directoryReads, firstLookupReads, "retain the resolved path during quiet work");

  fs.appendFileSync(rolloutPath, `${record("event_msg", {
    type: "agent_message", message: "New output while Desktop is stale", phase: "commentary",
  })}\n`);
  fs.utimesSync(rolloutPath, new Date(fakeNow), new Date(fakeNow));
  tick();
  await waitForMessage(messages, (message) => (
    message.method === "codex/event/agent_message"
      && message.params?.message === "New output while Desktop is stale"
  ));
  assert.equal(mirror.getActiveTurnId(threadId), turnId);
  assert.ok(contentReads > 0);

  // A fresh Desktop snapshot takes over again without a second file replay.
  fakeNow += 1_000;
  writeFrame(ipcSocket, {
    type: "broadcast", method: "thread-stream-state-changed", sourceClientId: "desktop", version: 11,
    params: {
      conversationId: threadId,
      change: { type: "snapshot", conversationState: {
        turns: [{ turnId, status: "inProgress", items: [{
          id: "desktop-output", type: "agentMessage", text: "New output while Desktop is stale",
        }] }], requests: [],
      } },
    },
  });
  await waitFor(() => follower.hasFreshLiveThreadState(threadId, { probeFallbackActivity: true }));
  const readsBeforeDesktopRecovery = contentReads;
  tick();
  assert.equal(contentReads, readsBeforeDesktopRecovery);
  assert.equal(mirror.getActiveTurnId(threadId), null);
});

// Loads bridge.js with plaintext test transports while leaving the production module untouched.
function loadBridgeWithTestDoubles({
  createCodexTransportImpl,
  desktopIpcActionFollowerModule = null,
  desktopIpcLiveOwnerModule = null,
  rolloutLiveMirrorModule = null,
}) {
  const bridgePath = require.resolve("../src/bridge");
  const originalLoad = Module._load;
  delete require.cache[bridgePath];
  Module._load = function loadWithBridgeDoubles(request, parent, isMain) {
    if (parent?.filename === bridgePath && request === "./codex-transport") {
      return { createCodexTransport: createCodexTransportImpl };
    }
    if (parent?.filename === bridgePath && request === "./rollout-live-mirror" && rolloutLiveMirrorModule) {
      return rolloutLiveMirrorModule;
    }
    if (parent?.filename === bridgePath
      && request === "./desktop-ipc-action-follower"
      && desktopIpcActionFollowerModule) {
      return desktopIpcActionFollowerModule;
    }
    if (parent?.filename === bridgePath
      && request === "./desktop-ipc-live-owner"
      && desktopIpcLiveOwnerModule) {
      return desktopIpcLiveOwnerModule;
    }
    if (parent?.filename === bridgePath && request === "./secure-transport") {
      return { createBridgeSecureTransport: createPlaintextSecureTransport };
    }
    if (parent?.filename === bridgePath && request === "./secure-device-state") {
      return createSecureDeviceStateDouble();
    }
    if (parent?.filename === bridgePath && request === "./session-state") {
      return {
        rememberActiveThread() {
          return true;
        },
      };
    }
    return originalLoad.call(this, request, parent, isMain);
  };

  try {
    return require("../src/bridge");
  } finally {
    Module._load = originalLoad;
    delete require.cache[bridgePath];
  }
}

// Uses plaintext relay messages so this test can focus on bridge routing, not encryption.
function createPlaintextSecureTransport() {
  return {
    createPairingPayload() {
      return { v: 1, expiresAt: Date.now() + 60_000 };
    },
    bindLiveSendWireMessage() {},
    handleIncomingWireMessage(message, { onApplicationMessage }) {
      onApplicationMessage(message);
      return true;
    },
    queueOutboundApplicationMessage(message, sendWireMessage) {
      sendWireMessage(message);
    },
  };
}

function createSecureDeviceStateDouble() {
  return {
    loadOrCreateBridgeDeviceState() {
      return {
        macDeviceId: "mac-test",
        macIdentityPublicKey: "mac-key-test",
        trustedPhones: {},
      };
    },
    rememberLastSeenPhoneAppVersion(deviceState) {
      return deviceState;
    },
    resolveBridgeRelaySession(deviceState) {
      return {
        sessionId: "session-test",
        deviceState,
      };
    },
  };
}

function createFakeCodexTransport({
  threadReadResult = {
    conversationState: {
      turns: [],
      requests: [],
    },
  },
} = {}) {
  const listeners = {};
  const sent = [];
  return {
    sent,
    describe() {
      return "fake codex app-server";
    },
    send(message) {
      const parsed = JSON.parse(message);
      sent.push(parsed);
      if (parsed.method === "thread/read") {
        listeners.message?.(JSON.stringify({
          id: parsed.id,
          result: threadReadResult,
        }));
      }
    },
    onMessage(handler) {
      listeners.message = handler;
    },
    onClose(handler) {
      listeners.close = handler;
    },
    onError(handler) {
      listeners.error = handler;
    },
    onStarted(handler) {
      listeners.started = handler;
      setImmediate(() => handler({ mode: "test" }));
    },
    emitMessage(message) {
      listeners.message?.(JSON.stringify(message));
    },
    shutdown() {
      this.emitClose();
    },
    emitClose() {
      listeners.close?.();
    },
  };
}

function bridgeTestConfig(relayServer, overrides = {}) {
  return {
    relayUrl: `ws://127.0.0.1:${relayServer.address().port}`,
    pushServiceUrl: "",
    pushPreviewMaxChars: 160,
    refreshEnabled: false,
    desktopAutoFollowEnabled: false,
    refreshDebounceMs: 1,
    keepMacAwakeEnabled: false,
    codexEndpoint: "",
    refreshCommand: "",
    codexBundleId: "",
    codexAppPath: "",
    desktopIpcLiveSyncEnabled: false,
    ...overrides,
  };
}

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

async function waitForMessage(messages, predicate, timeoutMs = 500) {
  await waitFor(() => messages.find(predicate), timeoutMs);
  return messages.find(predicate);
}

async function waitFor(predicate, timeoutMs = 500) {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > timeoutMs) {
      throw new Error("Timed out waiting for condition");
    }
    await wait(5);
  }
}

function safeParseJSON(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function createIpcTestSocket(prefix) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  const socketPath = process.platform === "win32"
    ? `\\\\.\\pipe\\${path.basename(tempDir)}-ipc`
    : path.join(tempDir, "ipc.sock");
  return { tempDir, socketPath };
}
