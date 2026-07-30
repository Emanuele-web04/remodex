// FILE: desktop-ipc-owner-transport.test.js
// Purpose: Unit tests for the stream-owner IPC client's fallback router, especially when it may replace a socket file.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:fs, node:net, node:os, node:path, ../src/desktop-ipc-owner-transport, ../src/desktop-ipc-shared
/* eslint-env node, mocha */

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");

const { createDesktopOwnerIpcClient } = require("../src/desktop-ipc-owner-transport");
const { createFrameReader, writeFrame } = require("../src/desktop-ipc-shared");

const skipOnWindows = { skip: process.platform === "win32" };

function createSocketPath(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-owner-ipc-"));
  t.after(() => {
    fs.rmSync(directory, { recursive: true, force: true });
  });
  return path.join(directory, "ipc.sock");
}

// Reproduces the race the probe guards against: the first connect is refused,
// and whatever happens on the path afterwards is up to the real socket.
function createRefusingNetModule({ refusedAttempts }) {
  let attempts = 0;
  return {
    createServer: (...args) => net.createServer(...args),
    createConnection: (...args) => {
      attempts += 1;
      if (attempts > refusedAttempts) {
        return net.createConnection(...args);
      }
      const socket = new net.Socket();
      setImmediate(() => {
        socket.emit("error", Object.assign(new Error("connect ECONNREFUSED"), { code: "ECONNREFUSED" }));
        socket.emit("close");
      });
      return socket;
    },
  };
}

function listenOnSocket(t, socketPath, onConnection) {
  const server = net.createServer(onConnection || (() => {}));
  t.after(() => {
    server.close();
  });
  return new Promise((resolve) => {
    server.listen(socketPath, () => resolve(server));
  });
}

function connectOnce(socketPath) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    socket.once("connect", () => resolve(socket));
    socket.once("error", reject);
  });
}

async function waitFor(condition, { attempts = 50, delayMs = 20 } = {}) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (await condition()) {
      return true;
    }
    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
  return false;
}

test("desktop owner IPC fallback router", { concurrency: false }, async (t) => {
  await t.test("tries the legacy bus before starting a fallback for a refused current socket", skipOnWindows, async (t) => {
    const currentSocketPath = createSocketPath(t);
    const legacySocketPath = createSocketPath(t);
    let acceptedByLegacyBus = 0;
    await listenOnSocket(t, legacySocketPath, (socket) => {
      acceptedByLegacyBus += 1;
      const frameReader = createFrameReader({
        onFrame: (envelope) => {
          if (envelope?.method !== "initialize") {
            return;
          }
          writeFrame(socket, JSON.stringify({
            type: "response",
            requestId: envelope.requestId,
            resultType: "success",
            method: "initialize",
            result: { clientId: "legacy-client" },
          }));
        },
      });
      socket.on("data", (chunk) => frameReader.push(chunk));
    });

    let connectedClientId = "";
    const client = createDesktopOwnerIpcClient({
      socketPath: () => [currentSocketPath, legacySocketPath],
      netModule: createRefusingNetModule({ refusedAttempts: 1 }),
      now: () => 1,
      requestTimeoutMs: 200,
      reconnectMs: 10_000,
      logPrefix: "[test]",
      onConnected: (clientId) => {
        connectedClientId = clientId;
      },
    });
    t.after(() => client.close());

    client.ensureConnected();
    const connected = await waitFor(async () => connectedClientId === "legacy-client");

    assert.equal(connected, true, "the client should initialize against the legacy bus");
    assert.equal(acceptedByLegacyBus, 1);
    await assert.rejects(connectOnce(currentSocketPath), /ENOENT|ECONNREFUSED/);
  });

  await t.test("keeps a bus that came back between the refusal and the probe", skipOnWindows, async (t) => {
    const socketPath = createSocketPath(t);
    let acceptedByOwner = 0;
    await listenOnSocket(t, socketPath, () => {
      acceptedByOwner += 1;
    });

    const client = createDesktopOwnerIpcClient({
      socketPath,
      netModule: createRefusingNetModule({ refusedAttempts: 1 }),
      now: () => 1,
      requestTimeoutMs: 200,
      reconnectMs: 10_000,
      logPrefix: "[test]",
    });
    t.after(() => client.close());

    client.ensureConnected();
    // The probe is the second connect, so it reaches the live listener.
    await waitFor(async () => acceptedByOwner > 0);

    assert.equal(acceptedByOwner > 0, true, "probe should reach the live bus");
    const socket = await connectOnce(socketPath);
    socket.destroy();
    assert.equal(acceptedByOwner, 2, "the original bus should still own the socket path");
  });

  await t.test("replaces a socket path nobody is serving", skipOnWindows, async (t) => {
    const socketPath = createSocketPath(t);
    // A listener that answers nothing leaves exactly the stale socket file the
    // fallback router is allowed to remove.
    await listenOnSocket(t, socketPath, (socket) => socket.destroy());

    const client = createDesktopOwnerIpcClient({
      socketPath,
      netModule: createRefusingNetModule({ refusedAttempts: Number.MAX_SAFE_INTEGER }),
      now: () => 1,
      requestTimeoutMs: 200,
      reconnectMs: 10_000,
      logPrefix: "[test]",
    });
    t.after(() => client.close());

    client.ensureConnected();

    let routerClientId = "";
    const started = await waitFor(async () => {
      let socket = null;
      try {
        socket = await connectOnce(socketPath);
      } catch {
        return false;
      }
      const initialized = await new Promise((resolve) => {
        const timeout = setTimeout(() => resolve(""), 200);
        const frameReader = createFrameReader({
          onFrame: (envelope) => {
            clearTimeout(timeout);
            resolve(envelope?.result?.clientId || "");
          },
        });
        socket.on("data", (chunk) => frameReader.push(chunk));
        writeFrame(socket, JSON.stringify({
          type: "request",
          requestId: "probe-1",
          sourceClientId: "initializing-client",
          version: 1,
          method: "initialize",
          params: { clientType: "test-client" },
        }));
      });
      socket.destroy();
      routerClientId = initialized;
      return Boolean(initialized);
    });

    assert.equal(started, true, "the fallback router should answer on the replaced path");
    assert.match(routerClientId, /^remodex-router-/);
  });

  await t.test("keeps broadcasts pending until a fallback-router peer connects", skipOnWindows, async (t) => {
    const socketPath = createSocketPath(t);
    const peerFrames = [];
    let connectedClientId = "";
    let peerSocket = null;
    const client = createDesktopOwnerIpcClient({
      socketPath,
      netModule: net,
      now: () => 1,
      requestTimeoutMs: 200,
      reconnectMs: 10,
      logPrefix: "[test]",
      onConnected: (clientId) => {
        connectedClientId = clientId;
      },
    });
    t.after(() => {
      client.close();
      peerSocket?.destroy();
    });

    client.ensureConnected();
    const ownerConnected = await waitFor(async () => connectedClientId.startsWith("remodex-router-"));
    assert.equal(ownerConnected, true);
    assert.equal(
      client.sendBroadcast("thread-unarchived", { conversationId: "thread-pending" }),
      false,
      "the fallback router alone must not count as a recipient"
    );

    peerSocket = await connectOnce(socketPath);
    const frameReader = createFrameReader({
      onFrame: (envelope) => peerFrames.push(envelope),
    });
    peerSocket.on("data", (chunk) => frameReader.push(chunk));
    writeFrame(peerSocket, JSON.stringify({
      type: "request",
      requestId: "desktop-init",
      sourceClientId: "initializing-client",
      version: 1,
      method: "initialize",
      params: { clientType: "vscode" },
    }));
    const peerInitialized = await waitFor(async () => peerFrames.some(
      (frame) => frame.type === "response" && frame.requestId === "desktop-init"
    ));
    assert.equal(peerInitialized, true);

    assert.equal(
      client.sendBroadcast("thread-unarchived", { conversationId: "thread-pending" }),
      true
    );
    const peerReceived = await waitFor(async () => peerFrames.some(
      (frame) => frame.type === "broadcast"
        && frame.method === "thread-unarchived"
        && frame.params?.conversationId === "thread-pending"
    ));
    assert.equal(peerReceived, true);
  });
});
