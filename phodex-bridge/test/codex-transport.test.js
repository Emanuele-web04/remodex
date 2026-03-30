// FILE: codex-transport.test.js
// Purpose: Verifies endpoint-backed Codex transport only sends after the websocket is open.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/codex-transport

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  createCodexLaunchPlan,
  createCodexTransport,
  detectSessionSourceFlagSupport,
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

test("detectSessionSourceFlagSupport returns true when the installed CLI advertises the flag", () => {
  const supported = detectSessionSourceFlagSupport({
    execFileSyncImpl() {
      return "Usage: codex app-server --session-source <SOURCE>";
    },
  });

  assert.equal(supported, true);
});

test("createCodexLaunchPlan omits --session-source when the installed CLI does not support it", () => {
  const launch = createCodexLaunchPlan({
    env: {},
    execFileSyncImpl() {
      return "Usage: codex app-server --ws-issuer <ISSUER>";
    },
  });

  assert.deepEqual(launch.args, ["app-server"]);
  assert.equal(launch.description, "`codex app-server`");
});

test("createCodexLaunchPlan includes --session-source when the installed CLI supports it", () => {
  const launch = createCodexLaunchPlan({
    env: {},
    execFileSyncImpl() {
      return "Usage: codex app-server --session-source <SOURCE>";
    },
  });

  assert.deepEqual(launch.args, ["app-server", "--session-source", "app-server"]);
  assert.equal(launch.description, "`codex app-server --session-source app-server`");
});
