// FILE: opencode-permission.test.js
// Purpose: Verifies OpenCode provider permission/reply handler (allow, deny, missing ID,
//          client error, snake_case field).
// Layer: Unit test
// Exports: node:test suite
// Depends on: node:test, node:assert/strict, ../src/opencode-provider

const test = require("node:test");
const assert = require("node:assert/strict");
const { createOpenCodeProvider } = require("../src/opencode-provider");

function fakeServer() {
  let running = false;
  return {
    get baseUrl() {
      return running ? "http://127.0.0.1:4291" : "";
    },
    get isRunning() {
      return running;
    },
    start() {
      running = true;
      return Promise.resolve();
    },
    stop() {
      running = false;
      return Promise.resolve();
    },
  };
}

function fakeOwnershipStore() {
  const store = new Map();
  return {
    setOwnership(threadId, providerId) {
      store.set(threadId, { providerId, assignedAt: new Date().toISOString() });
      return true;
    },
    ownsThread(threadId, providerId) {
      const entry = store.get(threadId);
      return entry ? entry.providerId === providerId : false;
    },
    removeOwnership(threadId) {
      return store.delete(threadId);
    },
    getAllOwnedBy(providerId) {
      return Array.from(store.entries())
        .filter(([, entry]) => entry.providerId === providerId)
        .map(([threadId, entry]) => ({ threadId, ...entry }));
    },
  };
}

function fakeClient(replyBehavior) {
  return {
    listModels: async () => [],
    listAgents: async () => [],
    createSession: async () => "ses_fake",
    getSession: async () => ({}),
    prompt: async () => Promise.resolve(),

    abort: async () => {},
    getMessages: async () => [],
    replyToPermission:
      replyBehavior ||
      (async (permissionId, allow) => {
        return { success: true };
      }),
    subscribeToEvents: () => () => {},
  };
}

function makeProvider(opts = {}) {
  return createOpenCodeProvider({
    sendApplicationMessage: opts.send || (() => {}),
    env: { REMODEX_ENABLE_OPENCODE: "1", ...opts.env },
    serverFactory: opts.serverFactory || (() => fakeServer()),
    clientFactory: opts.clientFactory,
    ownershipStore: opts.ownershipStore || fakeOwnershipStore(),
  });
}

test("permission/reply rejects unknown permissionId", async () => {
  const provider = makeProvider({ clientFactory: () => fakeClient() });
  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { permissionId: "perm_missing", allow: true },
  });
  assert.equal(result.success, false);
  assert.match(result.reason, /unknown|expired/i);
  await provider.shutdown();
});

test("permission/reply allows a permission", async () => {
  let receivedId = null;
  let receivedAllow = null;
  const replyClient = fakeClient(async (id, allow) => {
    receivedId = id;
    receivedAllow = allow;
    return { success: true };
  });
  const provider = makeProvider({ clientFactory: () => replyClient });
  provider.testSeedPendingPermission("perm_abc123", { threadId: "thread-1" });

  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { permissionId: "perm_abc123", threadId: "thread-1", allow: true },
  });

  assert.equal(result.success, true);
  assert.equal(result.permissionId, "perm_abc123");
  assert.equal(result.allow, true);
  assert.equal(receivedId, "perm_abc123");
  assert.equal(receivedAllow, true);

  await provider.shutdown();
});

test("permission/reply denies a permission", async () => {
  let receivedAllow = null;
  const replyClient = fakeClient(async (id, allow) => {
    receivedAllow = allow;
    return { success: true };
  });
  const provider = makeProvider({ clientFactory: () => replyClient });
  provider.testSeedPendingPermission("perm_deny", { threadId: "thread-1" });

  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { permissionId: "perm_deny", threadId: "thread-1", allow: false },
  });

  assert.equal(result.success, true);
  assert.equal(result.allow, false);
  assert.equal(receivedAllow, false);

  await provider.shutdown();
});

test("permission/reply rejects with missing permission ID", async () => {
  const provider = makeProvider({ clientFactory: () => fakeClient() });

  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { allow: true },
  });

  assert.equal(result.success, false);
  assert.equal(result.reason, "Missing permission ID");
});

test("permission/reply handles client error", async () => {
  const errorClient = fakeClient(async () => {
    throw new Error("SDK permission error");
  });
  const provider = makeProvider({ clientFactory: () => errorClient });
  provider.testSeedPendingPermission("perm_err", { threadId: "thread-1" });

  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { permissionId: "perm_err", threadId: "thread-1", allow: true },
  });

  assert.equal(result.success, false);
  assert.equal(result.reason, "SDK permission error");
  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 1);

  await provider.shutdown();
});

test("permission/reply success clears pending and second reply is unknown", async () => {
  const provider = makeProvider({ clientFactory: () => fakeClient() });
  provider.testSeedPendingPermission("perm_once", { threadId: "thread-1" });

  const first = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { permissionId: "perm_once", threadId: "thread-1", allow: true },
  });
  assert.equal(first.success, true);
  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 0);

  const second = await provider.handleRequest({
    id: 2,
    method: "permission/reply",
    params: { permissionId: "perm_once", threadId: "thread-1", allow: true },
  });
  assert.equal(second.success, false);
  assert.match(second.reason, /unknown|expired/i);

  await provider.shutdown();
});

test("permission/reply rejects sessionId mismatch", async () => {
  const provider = makeProvider({ clientFactory: () => fakeClient() });
  provider.testSeedPendingPermission("perm_session", {
    threadId: "thread-1",
    sessionId: "ses_expected",
  });

  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: {
      permissionId: "perm_session",
      threadId: "thread-1",
      allow: true,
      sessionId: "ses_other",
    },
  });

  assert.equal(result.success, false);
  assert.match(result.reason, /session id does not match/i);
  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 1);

  await provider.shutdown();
});

test("permission/reply re-arms watchdog on SDK failure when permissions UI disabled", async () => {
  const errorClient = fakeClient(async () => {
    throw new Error("SDK permission error");
  });
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_PERMISSIONS_UI: "0",
      REMODEX_TEST: "1",
    },
    clientFactory: () => errorClient,
  });
  provider.testSeedPendingPermission("perm_watchdog", {
    threadId: "thread-1",
    turnId: "turn-1",
  });

  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { permissionId: "perm_watchdog", threadId: "thread-1", allow: true },
  });

  assert.equal(result.success, false);
  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 1);
  assert.equal(provider.__test.hasPendingPermissionWatchdog("perm_watchdog"), true);

  await provider.shutdown();
});

test("shutdown clears pending permissions and watchdogs", async () => {
  const provider = makeProvider({
    env: {
      REMODEX_ENABLE_OPENCODE: "1",
      REMODEX_OPENCODE_PERMISSIONS_UI: "0",
      REMODEX_TEST: "1",
    },
    clientFactory: () => fakeClient(),
  });
  provider.__test.handlePermissionRequestEvent(
    { thread: { id: "thread-1", cwd: "/tmp" }, turn: { id: "turn-1" }, sessionId: "ses-1" },
    { permissionId: "perm_shutdown", tool: "bash", args: { command: "ls" } },
  );

  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 1);
  assert.equal(provider.__test.hasPendingPermissionWatchdog("perm_shutdown"), true);

  await provider.shutdown();

  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 0);
});

test("permission/request evicts oldest pending entry at cap 20 (B-17)", async () => {
  const deniedIds = [];
  const replyClient = fakeClient(async (permissionId, allow) => {
    if (!allow) {
      deniedIds.push(permissionId);
    }
    return { success: true };
  });
  const provider = makeProvider({
    env: { REMODEX_ENABLE_OPENCODE: "1", REMODEX_OPENCODE_PERMISSIONS_UI: "1", REMODEX_TEST: "1" },
    clientFactory: () => replyClient,
  });

  for (let index = 0; index < 20; index += 1) {
    provider.testSeedPendingPermission(`perm-cap-${index}`, { threadId: "thread-1" });
  }
  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 20);

  provider.__test.handlePermissionRequestEvent(
    { thread: { id: "thread-1", cwd: "/tmp" }, turn: { id: "turn-1" }, sessionId: "ses-1" },
    { permissionId: "perm-cap-new", tool: "bash", args: { command: "ls" } },
  );

  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 20);
  assert.equal(provider.__test.hasPendingPermissionWatchdog("perm-cap-0"), false);
  assert.equal(provider.__test.hasPendingPermissionWatchdog("perm-cap-new"), true);

  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(deniedIds, ["perm-cap-0"]);

  await provider.shutdown();
});

test("permission/reply rejects missing threadId (SEC-04)", async () => {
  const provider = makeProvider({ clientFactory: () => fakeClient() });
  provider.testSeedPendingPermission("perm_missing_thread", { threadId: "thread-1" });

  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { permissionId: "perm_missing_thread", allow: true },
  });

  assert.equal(result.success, false);
  assert.equal(result.reason, "Missing thread ID");
  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 1);

  await provider.shutdown();
});

test("permission/reply rejects threadId mismatch", async () => {
  const provider = makeProvider({ clientFactory: () => fakeClient() });
  provider.testSeedPendingPermission("perm_thread", { threadId: "thread-1" });

  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { permissionId: "perm_thread", allow: true, threadId: "thread-2" },
  });

  assert.equal(result.success, false);
  assert.match(result.reason, /thread id does not match/i);
  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 1);

  await provider.shutdown();
});

test("redactPermissionArgs redacts sensitive keys and truncates", () => {
  const provider = makeProvider({ clientFactory: () => fakeClient() });
  const summary = provider.__test.redactPermissionArgs({
    command: "rm -rf /",
    script: "evil.sh",
    token: "abc123",
    PATH: "/bin",
    note: "ok",
    filler: "x".repeat(600),
  });
  assert.match(summary, /command=\*\*\*/);
  assert.match(summary, /script=\*\*\*/);
  assert.match(summary, /token=\*\*\*/);
  assert.match(summary, /PATH=\*\*\*/);
  assert.match(summary, /note=ok/);
  assert.ok(summary.length <= 520);
  assert.match(summary, /truncated/);
});

test("permission/request arms watchdog when permissions UI enabled", () => {
  const provider = makeProvider({
    env: { REMODEX_ENABLE_OPENCODE: "1", REMODEX_OPENCODE_PERMISSIONS_UI: "1", REMODEX_TEST: "1" },
    clientFactory: () => fakeClient(),
  });

  provider.__test.handlePermissionRequestEvent(
    { thread: { id: "thread-1", cwd: "/tmp" }, turn: { id: "turn-1" }, sessionId: "ses-1" },
    { permissionId: "perm-watchdog-ui", tool: "bash", args: { command: "ls" } },
  );

  assert.equal(provider.getObservabilityMetrics().permissionPendingCount, 1);
  assert.equal(provider.__test.hasPendingPermissionWatchdog("perm-watchdog-ui"), true);

  void provider.shutdown();
});

test("permission/request emit omits raw args and includes argsSummary", () => {
  const messages = [];
  const provider = makeProvider({
    env: { REMODEX_ENABLE_OPENCODE: "1", REMODEX_OPENCODE_PERMISSIONS_UI: "1" },
    send: (message) => messages.push(JSON.parse(message)),
    clientFactory: () => fakeClient(),
  });

  provider.__test.handlePermissionRequestEvent(
    { thread: { id: "thread-1", cwd: "/tmp" }, turn: { id: "turn-1" }, sessionId: "ses-1" },
    {
      permissionId: "perm-emit",
      tool: "bash",
      args: { command: "npm test", note: "safe" },
    },
  );

  const permissionMessage = messages.find((message) => message.method === "permission/request");
  assert.ok(permissionMessage);
  assert.equal(permissionMessage.params.args, undefined);
  assert.match(permissionMessage.params.argsSummary, /command=\*\*\*/);
  assert.match(permissionMessage.params.argsSummary, /note=safe/);
});

test("permission/reply accepts permission_id snake_case", async () => {
  let receivedId = null;
  const replyClient = fakeClient(async (id, allow) => {
    receivedId = id;
    return { success: true };
  });
  const provider = makeProvider({ clientFactory: () => replyClient });
  provider.testSeedPendingPermission("perm_snake", { threadId: "thread-1" });

  const result = await provider.handleRequest({
    id: 1,
    method: "permission/reply",
    params: { permission_id: "perm_snake", threadId: "thread-1", allow: true },
  });

  assert.equal(result.success, true);
  assert.equal(result.permissionId, "perm_snake");
  assert.equal(receivedId, "perm_snake");

  await provider.shutdown();
});
