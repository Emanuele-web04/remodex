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
            id: "req-ipc",
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
  const actionMessage = await waitForMessage(relayMessages, (message) => message.id === "req-ipc");
  assert.equal(actionMessage.method, "item/tool/requestUserInput");

  relaySocket.send(JSON.stringify({
    id: "req-ipc",
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
    requestId: "req-ipc",
    response: {
      answers: {
        q1: { answers: ["Yes"] },
      },
    },
  });
  assert.equal(fakeCodex.sent.some((message) => message.id === "req-ipc"), false);

  const resolvedMessage = await waitForMessage(
    relayMessages,
    (message) => message.method === "serverRequest/resolved"
      && message.params?.requestId === "req-ipc"
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
            items: [{
              id: "user-ipc-delta",
              type: "user_message",
              text: "Please mirror me first",
            }, {
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
          path: ["turns", 0, "items", 1, "text"],
          value: "Hello world",
        }],
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
          path: ["turns", 0, "status"],
          value: "completed",
        }],
      },
    },
  });

  const deltaMessage = await waitForMessage(
    relayMessages,
    (message) => message.method === "item/agentMessage/delta"
  );
  const userMessage = relayMessages.find((message) => message.method === "codex/event/user_message");
  assert.deepEqual(userMessage.params, {
    threadId: "thread-ipc-delta",
    turnId: "turn-ipc-delta",
    message: "Please mirror me first",
    id: "user-ipc-delta",
    remodexDesktopMirror: true,
    remodexDesktopIpcMirror: true,
  });
  assert.ok(relayMessages.indexOf(userMessage) < relayMessages.indexOf(deltaMessage));
  assert.deepEqual(deltaMessage.params, {
    threadId: "thread-ipc-delta",
    turnId: "turn-ipc-delta",
    itemId: "assistant-ipc-delta",
    delta: " world",
  });
  const completedMessage = await waitForMessage(
    relayMessages,
    (message) => message.method === "turn/completed"
  );
  assert.deepEqual(completedMessage.params, {
    threadId: "thread-ipc-delta",
    turnId: "turn-ipc-delta",
    id: "turn-ipc-delta",
    status: "completed",
    remodexDesktopMirror: true,
    remodexDesktopIpcMirror: true,
  });
  assert.ok(relayMessages.indexOf(deltaMessage) < relayMessages.indexOf(completedMessage));
});

test("bridge forwards live desktop IPC tool calls to the phone", async (t) => {
  const { tempDir, socketPath: ipcSocketPath } = createIpcTestSocket("remodex-bridge-ipc-tools-");
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
    },
  });

  await waitFor(() => relaySocket && relaySocket.readyState === WebSocket.OPEN);
  relaySocket.send(JSON.stringify({
    id: "resume-from-phone",
    method: "thread/resume",
    params: { threadId: "thread-ipc-tool" },
  }));

  await waitFor(() => ipcServerSocket, 2_000);
  writeFrame(ipcServerSocket, {
    type: "broadcast",
    method: "thread-stream-state-changed",
    sourceClientId: "desktop",
    version: 1,
    params: {
      conversationId: "thread-ipc-tool",
      change: {
        type: "snapshot",
        conversationState: {
          turns: [{
            id: "turn-ipc-tool",
            status: "running",
            items: [{
              id: "user-ipc-tool",
              type: "user_message",
              text: "Run git status",
            }, {
              id: "call-ipc-tool",
              type: "function_call",
              call_id: "call-ipc-tool",
              name: "exec_command",
              arguments: JSON.stringify({ cmd: "git status", workdir: "/repo" }),
            }],
          }],
        },
      },
    },
  });

  const userMessage = await waitForMessage(
    relayMessages,
    (message) => message.method === "codex/event/user_message"
  );
  const toolMessage = await waitForMessage(
    relayMessages,
    (message) => message.method === "codex/event/exec_command_begin"
  );

  assert.ok(relayMessages.indexOf(userMessage) < relayMessages.indexOf(toolMessage));
  assert.deepEqual(toolMessage.params, {
    threadId: "thread-ipc-tool",
    turnId: "turn-ipc-tool",
    call_id: "call-ipc-tool",
    command: "git status",
    cwd: "/repo",
    status: "running",
    remodexDesktopMirror: true,
    remodexDesktopIpcMirror: true,
  });
});

// Loads bridge.js with plaintext test transports while leaving the production module untouched.
function loadBridgeWithTestDoubles({ createCodexTransportImpl }) {
  const bridgePath = require.resolve("../src/bridge");
  const originalLoad = Module._load;
  delete require.cache[bridgePath];
  Module._load = function loadWithBridgeDoubles(request, parent, isMain) {
    if (parent?.filename === bridgePath && request === "./codex-transport") {
      return { createCodexTransport: createCodexTransportImpl };
    }
    if (parent?.filename === bridgePath && request === "./secure-transport") {
      return { createBridgeSecureTransport: createPlaintextSecureTransport };
    }
    if (parent?.filename === bridgePath && request === "./secure-device-state") {
      return createSecureDeviceStateDouble();
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
