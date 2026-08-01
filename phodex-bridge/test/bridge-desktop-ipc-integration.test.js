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

// Loads bridge.js with plaintext test transports while leaving the production module untouched.
function loadBridgeWithTestDoubles({
  createCodexTransportImpl,
  desktopIpcActionFollowerModule = null,
  desktopIpcLiveOwnerModule = null,
}) {
  const bridgePath = require.resolve("../src/bridge");
  const originalLoad = Module._load;
  delete require.cache[bridgePath];
  Module._load = function loadWithBridgeDoubles(request, parent, isMain) {
    if (parent?.filename === bridgePath && request === "./codex-transport") {
      return { createCodexTransport: createCodexTransportImpl };
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
    shutdown() {
      this.emitClose();
    },
    emitClose() {
      listeners.close?.();
    },
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
