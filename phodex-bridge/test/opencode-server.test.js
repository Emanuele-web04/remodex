// FILE: opencode-server.test.js
// Purpose: Verifies OpenCode server spawn, auth, status, and endpoint allowlist behavior.
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, events, ../src/opencode-server

const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");

const {
  buildBasicAuthHeader,
  buildOpenCodeServeArgs,
  createOpenCodeServerManager,
  isAllowedOpenCodeRequest,
  parseOpenCodeServerUrl,
  redactOpenCodeServerSecret,
} = require("../src/opencode-server");

test("buildOpenCodeServeArgs binds loopback on an ephemeral port without mdns", () => {
  assert.deepEqual(buildOpenCodeServeArgs(), [
    "serve",
    "--hostname",
    "127.0.0.1",
    "--port",
    "0",
    "--pure",
    "--print-logs",
  ]);
});

test("OpenCode allowlist permits runtime API endpoints and denies auth mutation", () => {
  assert.equal(isAllowedOpenCodeRequest("GET", "/event"), true);
  assert.equal(isAllowedOpenCodeRequest("GET", "/global/event"), true);
  assert.equal(isAllowedOpenCodeRequest("GET", "/agent"), true);
  assert.equal(isAllowedOpenCodeRequest("GET", "/skill"), true);
  assert.equal(isAllowedOpenCodeRequest("GET", "/provider"), true);
  assert.equal(isAllowedOpenCodeRequest("GET", "/config/providers"), true);
  assert.equal(isAllowedOpenCodeRequest("GET", "/session"), true);
  assert.equal(isAllowedOpenCodeRequest("POST", "/session"), true);
  assert.equal(isAllowedOpenCodeRequest("GET", "/session/status"), true);
  assert.equal(isAllowedOpenCodeRequest("POST", "/session/ses_1/prompt_async"), true);
  assert.equal(isAllowedOpenCodeRequest("POST", "/session/ses_1/abort"), true);
  assert.equal(isAllowedOpenCodeRequest("GET", "/session/ses_1/diff"), true);
  assert.equal(isAllowedOpenCodeRequest("POST", "/session/ses_1/permissions/perm_1"), true);
  assert.equal(isAllowedOpenCodeRequest("POST", "/permission/perm_1/reply"), true);
  assert.equal(isAllowedOpenCodeRequest("PUT", "/auth"), false);
  assert.equal(isAllowedOpenCodeRequest("POST", "/session/ses_1/share"), false);
});

test("OpenCode manager spawns with basic auth and marks ready from loopback output", () => {
  const spawned = [];
  const child = createFakeChildProcess({ pid: 1234 });
  const manager = createOpenCodeServerManager({
    randomBytesImpl: () => Buffer.from("test-password-seed"),
    spawnImpl(command, args, options) {
      spawned.push({ command, args, options });
      return child;
    },
  });

  const starting = manager.start({ cwd: "/tmp/remodex-opencode" });
  assert.equal(starting.state, "starting");
  assert.equal(spawned[0].command, "opencode");
  assert.deepEqual(spawned[0].args, buildOpenCodeServeArgs());
  assert.equal(spawned[0].options.cwd, "/tmp/remodex-opencode");
  assert.equal(spawned[0].options.env.OPENCODE_SERVER_USERNAME, "opencode");
  assert.ok(spawned[0].options.env.OPENCODE_SERVER_PASSWORD);

  child.stderr.emit("data", "server listening at http://127.0.0.1:49152\n");

  const ready = manager.getStatus();
  assert.equal(ready.state, "ready");
  assert.equal(ready.baseUrl, "http://127.0.0.1:49152");
  assert.equal(ready.hasPassword, true);
});

test("OpenCode manager request enforces allowlist and sends basic auth", async () => {
  const child = createFakeChildProcess({ pid: 1234 });
  const fetchCalls = [];
  const manager = createOpenCodeServerManager({
    randomBytesImpl: () => Buffer.from("test-password-seed"),
    spawnImpl() {
      return child;
    },
    async fetchImpl(url, options) {
      fetchCalls.push({ url: String(url), options });
      return {
        ok: true,
        status: 200,
        async text() {
          return JSON.stringify({ id: "ses_1" });
        },
      };
    },
  });

  manager.start();
  child.stderr.emit("data", "http://127.0.0.1:49152\n");

  const session = await manager.request("POST", "/session", {
    body: { title: "Remodex" },
  });
  assert.deepEqual(session, { id: "ses_1" });
  assert.equal(fetchCalls[0].url, "http://127.0.0.1:49152/session");
  assert.equal(
    fetchCalls[0].options.headers.Authorization,
    buildBasicAuthHeader("opencode", Buffer.from("test-password-seed").toString("base64url"))
  );

  await assert.rejects(
    () => manager.request("PUT", "/auth", { body: {} }),
    /not allowed/
  );
});

test("OpenCode manager subscribes to SSE events with basic auth", async () => {
  const child = createFakeChildProcess({ pid: 1234 });
  const fetchCalls = [];
  const manager = createOpenCodeServerManager({
    randomBytesImpl: () => Buffer.from("test-password-seed"),
    spawnImpl() {
      return child;
    },
    async fetchImpl(url, options) {
      fetchCalls.push({ url: String(url), options });
      return {
        ok: true,
        status: 200,
        body: new ReadableStream({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("event: message\n"));
            controller.enqueue(new TextEncoder().encode("data: {\"type\":\"server.connected\",\"properties\":{}}\n\n"));
            controller.close();
          },
        }),
      };
    },
  });

  manager.start();
  child.stderr.emit("data", "http://127.0.0.1:49152\n");

  const events = [];
  const subscription = manager.subscribeEvents({
    onEvent(event) {
      events.push(event);
    },
  });
  await subscription.closed;

  assert.equal(fetchCalls[0].url, "http://127.0.0.1:49152/event");
  assert.equal(
    fetchCalls[0].options.headers.Authorization,
    buildBasicAuthHeader("opencode", Buffer.from("test-password-seed").toString("base64url"))
  );
  assert.deepEqual(events, [{ type: "server.connected", properties: {} }]);
});

test("OpenCode helpers parse loopback URLs and redact bearer-like secrets", () => {
  assert.equal(
    parseOpenCodeServerUrl("listening on http://127.0.0.1:4096"),
    "http://127.0.0.1:4096"
  );
  assert.equal(parseOpenCodeServerUrl("listening on http://0.0.0.0:4096"), "");
  assert.equal(
    redactOpenCodeServerSecret("OPENCODE_SERVER_PASSWORD=secret Authorization: Basic abc123"),
    "OPENCODE_SERVER_PASSWORD=[redacted] Authorization: Basic [redacted]"
  );
});

function createFakeChildProcess({ pid }) {
  const child = new EventEmitter();
  child.pid = pid;
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.kill = () => {
    child.killed = true;
  };
  return child;
}
