// FILE: codex-transport.test.js
// Purpose: Verifies endpoint-backed Codex transport only sends after the websocket is open.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/codex-transport

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");

const {
  createCodexLaunchPlans,
  createCodexTransport,
} = require("../src/codex-transport");

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSED = 3;
  static latestInstance = null;

  constructor(endpoint) {
    this.endpoint = endpoint;
    this.readyState = FakeWebSocket.CONNECTING;
    this.handlers = {};
    this.sentMessages = [];
    FakeWebSocket.latestInstance = this;
  }

  on(eventName, handler) {
    this.handlers[eventName] = handler;
  }

  send(message) {
    this.sentMessages.push(message);
  }

  close() {
    this.readyState = FakeWebSocket.CLOSED;
  }

  emit(eventName, ...args) {
    this.handlers[eventName]?.(...args);
  }
}

test("endpoint transport only sends outbound messages after the websocket opens", () => {
  const transport = createCodexTransport({
    endpoint: "ws://127.0.0.1:4321/codex",
    WebSocketImpl: FakeWebSocket,
  });

  const socket = FakeWebSocket.latestInstance;
  assert.ok(socket);
  assert.equal(socket.endpoint, "ws://127.0.0.1:4321/codex");

  transport.send('{"id":"init-1","method":"initialize"}');
  transport.send('{"id":"list-1","method":"thread/list"}');
  assert.deepEqual(socket.sentMessages, []);

  socket.readyState = FakeWebSocket.OPEN;
  socket.emit("open");

  assert.deepEqual(socket.sentMessages, []);

  transport.send('{"id":"list-2","method":"thread/list"}');
  assert.deepEqual(socket.sentMessages, ['{"id":"list-2","method":"thread/list"}']);
});

test("spawn launch plans add the bundled Codex app binary as a fallback on macOS", () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-app-"));
  const appPath = path.join(tempDir, "Codex.app");
  const bundledCodexPath = path.join(appPath, "Contents", "Resources", "codex");
  fs.mkdirSync(path.dirname(bundledCodexPath), { recursive: true });
  fs.writeFileSync(bundledCodexPath, "#!/bin/sh\nexit 0\n", { mode: 0o755 });

  try {
    const launches = createCodexLaunchPlans({
      env: { PATH: "/usr/bin:/bin" },
      appPath,
      platform: "darwin",
    });

    assert.deepEqual(
      launches.map((launch) => launch.command),
      ["codex", bundledCodexPath]
    );
    assert.equal(launches[1].description, `\`${bundledCodexPath} app-server\``);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("spawn launch plans keep the default codex command first even when a bundled fallback exists", () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-path-"));
  const appPath = path.join(tempDir, "Codex.app");
  const bundledCodexPath = path.join(appPath, "Contents", "Resources", "codex");
  fs.mkdirSync(path.dirname(bundledCodexPath), { recursive: true });
  fs.writeFileSync(bundledCodexPath, "#!/bin/sh\nexit 0\n", { mode: 0o755 });

  try {
    const launches = createCodexLaunchPlans({
      env: { PATH: "/usr/bin:/bin" },
      appPath,
      platform: "darwin",
    });

    assert.equal(launches[0].command, "codex");
    assert.equal(launches[1].command, bundledCodexPath);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("spawn transport retries with the bundled Codex binary after an ENOENT launch error", async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "remodex-codex-fallback-"));
  const appPath = path.join(tempDir, "Codex.app");
  const bundledCodexPath = path.join(appPath, "Contents", "Resources", "codex");
  fs.mkdirSync(path.dirname(bundledCodexPath), { recursive: true });
  fs.writeFileSync(bundledCodexPath, "#!/bin/sh\nexit 0\n", { mode: 0o755 });

  const spawnCalls = [];
  const children = [];
  const spawnImpl = (command, args, options) => {
    spawnCalls.push({ command, args, options });
    const child = createFakeChild();
    children.push(child);
    return child;
  };

  try {
    let startedInfo = null;
    const transport = createCodexTransport({
      env: { PATH: "/usr/bin:/bin" },
      appPath,
      spawnImpl,
    });
    transport.onStarted((info) => {
      startedInfo = info;
    });

    assert.equal(spawnCalls.length, 1);
    assert.equal(spawnCalls[0].command, "codex");

    const firstError = new Error("spawn codex ENOENT");
    firstError.code = "ENOENT";
    children[0].emit("error", firstError);
    await new Promise((resolve) => setImmediate(resolve));

    assert.equal(spawnCalls.length, 2);
    assert.equal(spawnCalls[1].command, bundledCodexPath);
    children[1].emit("spawn");
    assert.deepEqual(startedInfo, {
      mode: "spawn",
      launchDescription: `\`${bundledCodexPath} app-server\``,
    });
    assert.equal(transport.describe(), `\`${bundledCodexPath} app-server\``);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

function createFakeChild() {
  const handlers = new Map();
  const stdinHandlers = new Map();

  return {
    killed: false,
    exitCode: null,
    pid: 123,
    stdin: {
      writable: true,
      destroyed: false,
      writableEnded: false,
      on(eventName, handler) {
        stdinHandlers.set(eventName, handler);
      },
      write() {},
    },
    stdout: {
      on(eventName, handler) {
        handlers.set(`stdout:${eventName}`, handler);
      },
    },
    stderr: {
      on(eventName, handler) {
        handlers.set(`stderr:${eventName}`, handler);
      },
    },
    on(eventName, handler) {
      handlers.set(eventName, handler);
    },
    kill() {
      this.killed = true;
    },
    emit(eventName, ...args) {
      handlers.get(eventName)?.(...args);
    },
    emitStdout(eventName, ...args) {
      handlers.get(`stdout:${eventName}`)?.(...args);
    },
    emitStderr(eventName, ...args) {
      handlers.get(`stderr:${eventName}`)?.(...args);
    },
    emitStdin(eventName, ...args) {
      stdinHandlers.get(eventName)?.(...args);
    },
  };
}
